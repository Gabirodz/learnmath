import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path/path.dart' as p;

import '../ai/openrouter_client.dart';
import '../core/models.dart';
import '../core/providers.dart';
import '../platform/files.dart';
import '../tts/engine_factory.dart';
import 'lecture_player.dart';
import 'reexplain.dart';
import 'subtitle_text.dart';

const _speeds = [0.75, 0.9, 1.0, 1.1, 1.25, 1.5, 1.75, 2.0];

String formatClock(Duration d) {
  final h = d.inHours;
  final m = d.inMinutes.remainder(60);
  final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
  return h > 0 ? '$h:${m.toString().padLeft(2, '0')}:$s' : '$m:$s';
}

/// The listening screen: subtitles in the middle (tap = play/pause,
/// double-tap left/right = skip back/forward), transport controls below.
class PlayerView extends ConsumerStatefulWidget {
  const PlayerView({super.key, required this.lesson, this.onAsk});

  /// Must have audio.
  final Lesson lesson;

  /// Called with the last few spoken sentences when the listener wants to
  /// ask about what was just said.
  final void Function(String quote)? onAsk;

  @override
  ConsumerState<PlayerView> createState() => _PlayerViewState();
}

class _PlayerViewState extends ConsumerState<PlayerView> {
  late final LecturePlayer _player = ref.read(lecturePlayerProvider);
  late final ReexplainController _reexplain = ReexplainController(
    pauseLecture: _player.pause,
    askModel: _askModel,
    synthesize: _synthesize,
    playClip: (path) =>
        _player.playClip(path, resumeSegment: _reexplainSegment),
    stopClip: _player.abortClip,
    resumeLecture: _player.resumeFromSegment,
  );
  Object? _loadError;

  /// Set once this screen has loaded its lesson into the player. After that
  /// the player may legitimately move on (auto-advance, another screen) and
  /// this screen must not pull it back.
  bool _loaded = false;
  int _reexplainSegment = 0;

  @override
  void initState() {
    super.initState();
    _player.lesson.addListener(_onPlayerLesson);
    _load();
  }

  @override
  void dispose() {
    _player.lesson.removeListener(_onPlayerLesson);
    // Leaving the screen ends a running explanation; the lecture stays paused.
    _reexplain.dispose();
    super.dispose();
  }

  void _onPlayerLesson() {
    if (_player.lesson.value?.id != widget.lesson.id) _reexplain.cancel();
  }

  @override
  void didUpdateWidget(PlayerView old) {
    super.didUpdateWidget(old);
    // A re-recorded lecture has a new duration; LecturePlayer.load ignores
    // calls for the recording it already has. Only while this lesson is the
    // one loaded: if the player has moved on to the next lesson of the course,
    // the still-open screen must not undo that.
    if (old.lesson.audioDurationMs != widget.lesson.audioDurationMs &&
        _player.lesson.value?.id == widget.lesson.id) {
      _load();
    }
  }

  Future<void> _load() async {
    try {
      String? album;
      final courseId = widget.lesson.courseId;
      if (courseId != null) {
        album = (await ref.read(repositoryProvider).getCourse(courseId))?.title;
      }
      await _player.load(
        widget.lesson,
        album: album,
        speed: ref.read(settingsProvider).playbackSpeed,
      );
      if (mounted) {
        setState(() {
          _loadError = null;
          _loaded = true;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _loadError = e);
    }
  }

  void _setSpeed(double speed) {
    _player.setSpeed(speed);
    ref
        .read(settingsProvider.notifier)
        .update((s) => s.copyWith(playbackSpeed: speed));
  }

  void _ask() {
    final segs = _player.segments;
    if (segs.isEmpty) return;
    final i = _player.segmentIndex.value.clamp(0, segs.length - 1);
    final from = i - 2 < 0 ? 0 : i - 2;
    _player.pause();
    widget.onAsk!([for (var k = from; k <= i; k++) segs[k].subtitle].join(' '));
  }

  Future<String> _askModel(ReexplainContext c) async {
    final settings = ref.read(settingsProvider);
    if (!settings.hasApiKey) {
      throw OpenRouterException(
        'Add your OpenRouter API key in Settings first.',
      );
    }
    final client = OpenRouterClient(apiKey: settings.apiKey);
    return client.chat(
      model: settings.tutorModel.model,
      messages: [
        const ChatMessage.system(ReexplainPrompt.system),
        ChatMessage.user(ReexplainPrompt.user(c)),
      ],
      temperature: 0.6,
      maxTokens: 600,
    );
  }

  Future<String> _synthesize(String text) async {
    final settings = ref.read(settingsProvider);
    final engine = createTtsEngine(
      settings,
      ref.read(voiceModelsProvider),
      OpenRouterClient(apiKey: settings.apiKey),
    );
    try {
      return await synthesizeToWav(
        engine: engine,
        text: text,
        // In a browser the clip is a blob: any name will do.
        outPath: p.join(
          filesAreBlobs ? '/tmp' : Directory.systemTemp.path,
          'learnmath_again_${DateTime.now().microsecondsSinceEpoch}.wav',
        ),
      );
    } finally {
      await engine.dispose();
    }
  }

  void _explainAgain() {
    final segs = _player.segments;
    if (segs.isEmpty) return;
    final i = _player.segmentIndex.value.clamp(0, segs.length - 1);
    _reexplainSegment = i;
    HapticFeedback.selectionClick();
    _reexplain.start(
      ReexplainContext.fromSegments(segs, i, section: _player.currentSection),
      segmentIndex: i,
    );
  }

  /// Play/pause for the lecture. While an explanation is running, play means
  /// "back to the lecture".
  void _toggle() {
    final s = _reexplain.state.value;
    if (s is ReexplainSpeaking) {
      _reexplain.backToLecture();
      return;
    }
    if (s is ReexplainThinking) _reexplain.cancel();
    if (s is ReexplainError) _reexplain.dismissError();
    _player.toggle();
  }

  void _showChapters() {
    final starts = _player.sectionStarts;
    final segments = _player.segments;
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            for (final i in starts)
              ListTile(
                leading: const Icon(Icons.bookmark_outline),
                title: Text(segments[i].section!),
                trailing: Text(
                  formatClock(Duration(milliseconds: segments[i].startMs ?? 0)),
                ),
                onTap: () {
                  Navigator.pop(context);
                  _player.seekToSegment(i);
                },
              ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_loadError != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            'Could not open the recording.\n$_loadError',
            textAlign: TextAlign.center,
          ),
        ),
      );
    }
    final skipSeconds = ref.watch(
      settingsProvider.select((s) => s.skipSeconds),
    );
    return ValueListenableBuilder<Lesson?>(
      valueListenable: _player.lesson,
      builder: (context, current, _) {
        if (_loaded && current?.id != widget.lesson.id) {
          return _ElsewhereView(
            lesson: widget.lesson,
            playing: current,
            onOpen: () => context.pushReplacement('/lesson/${current!.id}'),
            onPlayHere: _load,
          );
        }
        return Column(
          children: [
            Expanded(
              child: _SubtitleStage(
                player: _player,
                skipSeconds: skipSeconds,
                onShowChapters: _showChapters,
                reexplain: _reexplain,
                onToggle: _toggle,
              ),
            ),
            _Transport(
              player: _player,
              skipSeconds: skipSeconds,
              onSpeed: _setSpeed,
              onAsk: widget.onAsk == null ? null : _ask,
              onToggle: _toggle,
              reexplain: _reexplain,
              onExplainAgain: _explainAgain,
            ),
          ],
        );
      },
    );
  }
}

/// Subtitles plus the tap / double-tap gesture surface.
class _SubtitleStage extends StatefulWidget {
  const _SubtitleStage({
    required this.player,
    required this.skipSeconds,
    required this.onShowChapters,
    required this.reexplain,
    required this.onToggle,
  });

  final LecturePlayer player;
  final int skipSeconds;
  final VoidCallback onShowChapters;
  final ReexplainController reexplain;
  final VoidCallback onToggle;

  @override
  State<_SubtitleStage> createState() => _SubtitleStageState();
}

/// Coloured rounded backing for the current subtitle line. Hugs its text.
class _SubtitleBubble extends StatelessWidget {
  const _SubtitleBubble({
    super.key,
    required this.text,
    required this.style,
  });

  final String text;
  final TextStyle style;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // The text is white in both themes; the dark theme's primary is too
    // light to carry it.
    final primary = scheme.brightness == Brightness.dark
        ? scheme.primaryContainer
        : scheme.primary;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: primary,
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(
            color: primary.withValues(alpha: 0.25),
            blurRadius: 16,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
        child: SubtitleText(text, style: style),
      ),
    );
  }
}

class _SubtitleStageState extends State<_SubtitleStage> {
  Offset? _doubleTapAt;

  /// -1 / +1 while the skip feedback is visible, with the accumulated amount.
  int _feedbackDir = 0;
  int _feedbackSeconds = 0;
  Timer? _feedbackTimer;

  @override
  void dispose() {
    _feedbackTimer?.cancel();
    super.dispose();
  }

  void _onDoubleTap(double width) {
    final at = _doubleTapAt;
    if (at == null) return;
    final dir = at.dx < width / 2 ? -1 : 1;
    HapticFeedback.selectionClick();
    widget.player.skip(dir * widget.skipSeconds);
    setState(() {
      // Repeated double-taps in the same direction add up on screen.
      _feedbackSeconds =
          (_feedbackDir == dir ? _feedbackSeconds : 0) + widget.skipSeconds;
      _feedbackDir = dir;
    });
    _feedbackTimer?.cancel();
    _feedbackTimer = Timer(const Duration(milliseconds: 700), () {
      if (mounted) setState(() => _feedbackDir = 0);
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return LayoutBuilder(
      builder: (context, box) {
        final wide = box.maxWidth >= 600;
        final current =
            (wide
                    ? theme.textTheme.headlineMedium
                    : theme.textTheme.headlineSmall)!
                .copyWith(
                  color: Colors.white,
                  fontWeight: FontWeight.w700,
                  height: 1.35,
                );
        final context_ = theme.textTheme.bodyLarge!.copyWith(
          color: scheme.onSurfaceVariant.withValues(alpha: 0.6),
        );

        return Semantics(
          label:
              'Lecture subtitles. Tap to play or pause, double tap the left '
              'or right side to skip ${widget.skipSeconds} seconds.',
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: widget.onToggle,
            onDoubleTapDown: (d) => _doubleTapAt = d.localPosition,
            onDoubleTap: () => _onDoubleTap(box.maxWidth),
            child: Stack(
              children: [
                Positioned.fill(
                  child: ValueListenableBuilder<ReexplainState>(
                    valueListenable: widget.reexplain.state,
                    builder: (context, rs, lecture) => rs is ReexplainIdle
                        ? lecture!
                        : _ReexplainPanel(
                            state: rs,
                            controller: widget.reexplain,
                            wide: wide,
                          ),
                    child: Padding(
                      padding: EdgeInsets.symmetric(
                        horizontal: wide ? 40 : 20,
                        vertical: 12,
                      ),
                      child: ValueListenableBuilder<int>(
                        valueListenable: widget.player.segmentIndex,
                        builder: (context, index, _) {
                          final segs = widget.player.segments;
                          if (segs.isEmpty) return const SizedBox.shrink();
                          final i = index.clamp(0, segs.length - 1);
                          final section = widget.player.currentSection;
                          return Column(
                            children: [
                              if (section != null)
                                ActionChip(
                                  avatar: const Icon(
                                    Icons.bookmark_outline,
                                    size: 18,
                                  ),
                                  label: Text(
                                    section,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  onPressed: widget.onShowChapters,
                                ),
                              Expanded(
                                flex: 2,
                                child: Align(
                                  alignment: Alignment.bottomCenter,
                                  child: i > 0
                                      ? SubtitleText(
                                          segs[i - 1].subtitle,
                                          style: context_,
                                          maxLines: 3,
                                        )
                                      : null,
                                ),
                              ),
                              const SizedBox(height: 16),
                              Expanded(
                                flex: 5,
                                child: Center(
                                  child: SingleChildScrollView(
                                    child: AnimatedSwitcher(
                                      duration: const Duration(
                                        milliseconds: 180,
                                      ),
                                      child: _SubtitleBubble(
                                        text: segs[i].subtitle,
                                        key: ValueKey(i),
                                        style: current,
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                              const SizedBox(height: 16),
                              Expanded(
                                flex: 2,
                                child: Align(
                                  alignment: Alignment.topCenter,
                                  child: i + 1 < segs.length
                                      ? SubtitleText(
                                          segs[i + 1].subtitle,
                                          style: context_,
                                          maxLines: 3,
                                        )
                                      : null,
                                ),
                              ),
                            ],
                          );
                        },
                      ),
                    ),
                  ),
                ),
                for (final dir in const [-1, 1])
                  Align(
                    alignment: dir < 0
                        ? Alignment.centerLeft
                        : Alignment.centerRight,
                    child: IgnorePointer(
                      child: AnimatedOpacity(
                        opacity: _feedbackDir == dir ? 1 : 0,
                        duration: const Duration(milliseconds: 150),
                        child: Container(
                          margin: const EdgeInsets.all(20),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 12,
                          ),
                          decoration: BoxDecoration(
                            color: scheme.inverseSurface.withValues(
                              alpha: 0.85,
                            ),
                            borderRadius: BorderRadius.circular(28),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                dir < 0
                                    ? Icons.fast_rewind_rounded
                                    : Icons.fast_forward_rounded,
                                color: scheme.onInverseSurface,
                              ),
                              const SizedBox(width: 6),
                              Text(
                                '${_feedbackSeconds}s',
                                style: theme.textTheme.titleMedium!.copyWith(
                                  color: scheme.onInverseSurface,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _Transport extends StatelessWidget {
  const _Transport({
    required this.player,
    required this.skipSeconds,
    required this.onSpeed,
    required this.onAsk,
    required this.onToggle,
    required this.reexplain,
    required this.onExplainAgain,
  });

  final LecturePlayer player;
  final int skipSeconds;
  final ValueChanged<double> onSpeed;
  final VoidCallback? onAsk;
  final VoidCallback onToggle;
  final ReexplainController reexplain;
  final VoidCallback onExplainAgain;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _SeekBar(player: player, onSpeed: onSpeed),
            TransportButtons(
              stateStream: player.stateStream,
              onPrevious: player.previousSection,
              onToggle: onToggle,
              onNext: player.nextSection,
              onAsk: onAsk,
              reexplain: reexplain.state,
              onExplainAgain: onExplainAgain,
            ),
          ],
        ),
      ),
    );
  }
}

/// The button row under the seek bar: five buttons of at least 48 dp, which
/// fit a 320 dp wide phone (speed lives next to the seek bar instead).
class TransportButtons extends StatelessWidget {
  const TransportButtons({
    super.key,
    required this.stateStream,
    required this.onPrevious,
    required this.onToggle,
    required this.onNext,
    required this.onAsk,
    required this.reexplain,
    required this.onExplainAgain,
  });

  final Stream<PlayerState> stateStream;
  final VoidCallback onPrevious;
  final VoidCallback onToggle;
  final VoidCallback onNext;
  final VoidCallback? onAsk;
  final ValueListenable<ReexplainState> reexplain;
  final VoidCallback onExplainAgain;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: [
        IconButton(
          tooltip: 'Previous section',
          iconSize: 32,
          icon: const Icon(Icons.skip_previous_rounded),
          onPressed: onPrevious,
        ),
        StreamBuilder<PlayerState>(
          stream: stateStream,
          builder: (context, snap) {
            final state = snap.data;
            final busy =
                state?.processingState == ProcessingState.loading ||
                state?.processingState == ProcessingState.buffering;
            final playing =
                (state?.playing ?? false) &&
                state?.processingState != ProcessingState.completed;
            return IconButton.filled(
              tooltip: playing ? 'Pause' : 'Play',
              iconSize: 44,
              padding: const EdgeInsets.all(12),
              onPressed: busy ? null : onToggle,
              icon: Icon(
                playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
              ),
            );
          },
        ),
        IconButton(
          tooltip: 'Next section',
          iconSize: 32,
          icon: const Icon(Icons.skip_next_rounded),
          onPressed: onNext,
        ),
        IconButton(
          tooltip: 'Ask about what was just said',
          iconSize: 28,
          icon: const Icon(Icons.question_answer_outlined),
          onPressed: onAsk,
        ),
        ValueListenableBuilder<ReexplainState>(
          valueListenable: reexplain,
          builder: (context, rs, _) {
            final busy = rs is ReexplainThinking;
            final speaking = rs is ReexplainSpeaking;
            return IconButton(
              tooltip: busy
                  ? 'Cancel'
                  : speaking
                  ? 'Back to the lecture'
                  : 'Explain this again differently',
              iconSize: 28,
              isSelected: busy || speaking,
              icon: const Icon(Icons.replay_circle_filled_outlined),
              selectedIcon: Icon(busy ? Icons.close : Icons.undo),
              onPressed: onExplainAgain,
            );
          },
        ),
      ],
    );
  }
}

class _SeekBar extends StatefulWidget {
  const _SeekBar({required this.player, required this.onSpeed});
  final LecturePlayer player;
  final ValueChanged<double> onSpeed;

  @override
  State<_SeekBar> createState() => _SeekBarState();
}

class _SeekBarState extends State<_SeekBar> {
  /// Non-null while the user drags the thumb.
  double? _dragMs;

  @override
  Widget build(BuildContext context) {
    final style = Theme.of(context).textTheme.labelMedium;
    return StreamBuilder<Duration>(
      stream: widget.player.positionStream,
      builder: (context, snap) {
        final totalMs = widget.player.duration.inMilliseconds.toDouble();
        final posMs =
            (_dragMs ??
                    (snap.data ?? widget.player.position).inMilliseconds
                        .toDouble())
                .clamp(0.0, totalMs <= 0 ? 0.0 : totalMs);
        final pos = Duration(milliseconds: posMs.round());
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Slider(
              value: posMs,
              max: totalMs <= 0 ? 1 : totalMs,
              semanticFormatterCallback: (v) =>
                  formatClock(Duration(milliseconds: v.round())),
              onChanged: totalMs <= 0
                  ? null
                  : (v) => setState(() => _dragMs = v),
              onChangeEnd: (v) {
                widget.player.seek(Duration(milliseconds: v.round()));
                setState(() => _dragMs = null);
              },
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(formatClock(pos), style: style),
                  _SpeedButton(player: widget.player, onSpeed: widget.onSpeed),
                  Text(formatClock(widget.player.duration), style: style),
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}

/// Playback speed, in the time row under the seek bar so the transport row
/// keeps room for five 48 dp buttons on a 320 dp wide phone.
class _SpeedButton extends StatelessWidget {
  const _SpeedButton({required this.player, required this.onSpeed});
  final LecturePlayer player;
  final ValueChanged<double> onSpeed;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return StreamBuilder<double>(
      stream: player.speedStream,
      builder: (context, snap) {
        final speed = snap.data ?? player.speed;
        return PopupMenuButton<double>(
          tooltip: 'Playback speed',
          initialValue: speed,
          onSelected: onSpeed,
          itemBuilder: (_) => [
            for (final s in _speeds)
              PopupMenuItem(value: s, child: Text('$s×')),
          ],
          child: SizedBox(
            width: 56,
            height: 48,
            child: Center(
              child: Text(
                '$speed×',
                style: theme.textTheme.titleMedium!.copyWith(
                  color: theme.colorScheme.primary,
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// Replaces the subtitles while an "explain differently" request runs.
class _ReexplainPanel extends StatelessWidget {
  const _ReexplainPanel({
    required this.state,
    required this.controller,
    required this.wide,
  });

  final ReexplainState state;
  final ReexplainController controller;
  final bool wide;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final Widget content;
    switch (state) {
      case ReexplainThinking():
        content = Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CircularProgressIndicator(),
            const SizedBox(height: 20),
            Text(
              'Finding another way to explain it…',
              style: theme.textTheme.titleMedium,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 12),
            OutlinedButton(
              onPressed: controller.cancel,
              child: const Text('Cancel'),
            ),
          ],
        );
      case ReexplainSpeaking(:final text):
        content = Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Chip(
              avatar: Icon(
                Icons.lightbulb_outline,
                size: 18,
                color: scheme.onTertiaryContainer,
              ),
              label: const Text('Explained differently'),
              backgroundColor: scheme.tertiaryContainer,
              labelStyle: TextStyle(color: scheme.onTertiaryContainer),
              side: BorderSide.none,
            ),
            const SizedBox(height: 16),
            Text(
              text,
              style:
                  (wide
                          ? theme.textTheme.headlineSmall
                          : theme.textTheme.titleLarge)!
                      .copyWith(height: 1.4),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 12),
            TextButton.icon(
              onPressed: controller.backToLecture,
              icon: const Icon(Icons.undo),
              label: const Text('Back to the lecture'),
            ),
          ],
        );
      case ReexplainError(:final message):
        content = Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.error_outline, size: 40, color: scheme.error),
            const SizedBox(height: 12),
            Text(
              message,
              style: theme.textTheme.bodyLarge,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 4),
            Text(
              'The lecture is paused where it was.',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 12),
            FilledButton.tonal(
              onPressed: controller.dismissError,
              child: const Text('OK'),
            ),
          ],
        );
      case ReexplainIdle():
        content = const SizedBox.shrink();
    }
    return Semantics(
      liveRegion: true,
      child: Center(
        child: SingleChildScrollView(
          padding: EdgeInsets.symmetric(
            horizontal: wide ? 40 : 20,
            vertical: 12,
          ),
          child: content,
        ),
      ),
    );
  }
}

/// Shown when the player has moved on from this screen's lesson, e.g. it
/// went on to the next lesson of the course by itself.
class _ElsewhereView extends StatelessWidget {
  const _ElsewhereView({
    required this.lesson,
    required this.playing,
    required this.onOpen,
    required this.onPlayHere,
  });

  final Lesson lesson;
  final Lesson? playing;
  final VoidCallback onOpen;
  final VoidCallback onPlayHere;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final now = playing;
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (now != null)
              Card(
                color: scheme.secondaryContainer,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
                  child: Row(
                    children: [
                      Icon(
                        Icons.graphic_eq,
                        color: scheme.onSecondaryContainer,
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          'Now playing: ${now.title}',
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.titleSmall?.copyWith(
                            color: scheme.onSecondaryContainer,
                          ),
                        ),
                      ),
                      TextButton(onPressed: onOpen, child: const Text('Open')),
                    ],
                  ),
                ),
              ),
            const SizedBox(height: 24),
            Text(
              lesson.title,
              style: theme.textTheme.titleLarge,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            OutlinedButton.icon(
              onPressed: onPlayHere,
              icon: const Icon(Icons.play_arrow_rounded),
              label: const Text('Play this lesson instead'),
            ),
          ],
        ),
      ),
    );
  }
}
