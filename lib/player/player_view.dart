import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:just_audio/just_audio.dart';

import '../core/models.dart';
import '../core/providers.dart';
import 'lecture_player.dart';
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
  const PlayerView({super.key, required this.lesson});

  /// Must have audio.
  final Lesson lesson;

  @override
  ConsumerState<PlayerView> createState() => _PlayerViewState();
}

class _PlayerViewState extends ConsumerState<PlayerView> {
  late final LecturePlayer _player = ref.read(lecturePlayerProvider);
  Object? _loadError;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(PlayerView old) {
    super.didUpdateWidget(old);
    // A re-recorded lecture has a new duration; LecturePlayer.load ignores
    // calls for the recording it already has.
    if (old.lesson.audioDurationMs != widget.lesson.audioDurationMs) _load();
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
      if (mounted) setState(() => _loadError = null);
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
                    formatClock(Duration(milliseconds: segments[i].startMs ?? 0))),
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
    final skipSeconds = ref.watch(settingsProvider.select((s) => s.skipSeconds));
    return Column(
      children: [
        Expanded(
          child: _SubtitleStage(
            player: _player,
            skipSeconds: skipSeconds,
            onShowChapters: _showChapters,
          ),
        ),
        _Transport(
          player: _player,
          skipSeconds: skipSeconds,
          onSpeed: _setSpeed,
          onShowChapters: _showChapters,
        ),
      ],
    );
  }
}

/// Subtitles plus the tap / double-tap gesture surface.
class _SubtitleStage extends StatefulWidget {
  const _SubtitleStage({
    required this.player,
    required this.skipSeconds,
    required this.onShowChapters,
  });

  final LecturePlayer player;
  final int skipSeconds;
  final VoidCallback onShowChapters;

  @override
  State<_SubtitleStage> createState() => _SubtitleStageState();
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
    return LayoutBuilder(builder: (context, box) {
      final wide = box.maxWidth >= 600;
      final current = (wide
              ? theme.textTheme.headlineMedium
              : theme.textTheme.headlineSmall)!
          .copyWith(color: scheme.onSurface, height: 1.35);
      final context_ = theme.textTheme.bodyLarge!
          .copyWith(color: scheme.onSurfaceVariant.withValues(alpha: 0.6));

      return Semantics(
        label: 'Lecture subtitles. Tap to play or pause, double tap the left '
            'or right side to skip ${widget.skipSeconds} seconds.',
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.player.toggle,
          onDoubleTapDown: (d) => _doubleTapAt = d.localPosition,
          onDoubleTap: () => _onDoubleTap(box.maxWidth),
          child: Stack(
            children: [
              Positioned.fill(
                child: Padding(
                  padding: EdgeInsets.symmetric(
                      horizontal: wide ? 40 : 20, vertical: 12),
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
                              avatar:
                                  const Icon(Icons.bookmark_outline, size: 18),
                              label: Text(section,
                                  overflow: TextOverflow.ellipsis),
                              onPressed: widget.onShowChapters,
                            ),
                          Expanded(
                            flex: 2,
                            child: Align(
                              alignment: Alignment.bottomCenter,
                              child: i > 0
                                  ? SubtitleText(segs[i - 1].subtitle,
                                      style: context_, maxLines: 3)
                                  : null,
                            ),
                          ),
                          const SizedBox(height: 16),
                          Expanded(
                            flex: 5,
                            child: Center(
                              child: SingleChildScrollView(
                                child: AnimatedSwitcher(
                                  duration: const Duration(milliseconds: 180),
                                  child: SubtitleText(
                                    segs[i].subtitle,
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
                                  ? SubtitleText(segs[i + 1].subtitle,
                                      style: context_, maxLines: 3)
                                  : null,
                            ),
                          ),
                        ],
                      );
                    },
                  ),
                ),
              ),
              for (final dir in const [-1, 1])
                Align(
                  alignment:
                      dir < 0 ? Alignment.centerLeft : Alignment.centerRight,
                  child: IgnorePointer(
                    child: AnimatedOpacity(
                      opacity: _feedbackDir == dir ? 1 : 0,
                      duration: const Duration(milliseconds: 150),
                      child: Container(
                        margin: const EdgeInsets.all(20),
                        padding: const EdgeInsets.symmetric(
                            horizontal: 16, vertical: 12),
                        decoration: BoxDecoration(
                          color: scheme.inverseSurface.withValues(alpha: 0.85),
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
                              style: theme.textTheme.titleMedium!
                                  .copyWith(color: scheme.onInverseSurface),
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
    });
  }
}

class _Transport extends StatelessWidget {
  const _Transport({
    required this.player,
    required this.skipSeconds,
    required this.onSpeed,
    required this.onShowChapters,
  });

  final LecturePlayer player;
  final int skipSeconds;
  final ValueChanged<double> onSpeed;
  final VoidCallback onShowChapters;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _SeekBar(player: player),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                StreamBuilder<double>(
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
                            style: Theme.of(context)
                                .textTheme
                                .titleMedium!
                                .copyWith(color: scheme.primary),
                          ),
                        ),
                      ),
                    );
                  },
                ),
                IconButton(
                  tooltip: 'Previous section',
                  iconSize: 32,
                  icon: const Icon(Icons.skip_previous_rounded),
                  onPressed: player.previousSection,
                ),
                StreamBuilder<PlayerState>(
                  stream: player.stateStream,
                  builder: (context, snap) {
                    final state = snap.data;
                    final busy = state?.processingState ==
                            ProcessingState.loading ||
                        state?.processingState == ProcessingState.buffering;
                    final playing = (state?.playing ?? false) &&
                        state?.processingState != ProcessingState.completed;
                    return IconButton.filled(
                      tooltip: playing ? 'Pause' : 'Play',
                      iconSize: 44,
                      padding: const EdgeInsets.all(12),
                      onPressed: busy ? null : player.toggle,
                      icon: Icon(playing
                          ? Icons.pause_rounded
                          : Icons.play_arrow_rounded),
                    );
                  },
                ),
                IconButton(
                  tooltip: 'Next section',
                  iconSize: 32,
                  icon: const Icon(Icons.skip_next_rounded),
                  onPressed: player.nextSection,
                ),
                IconButton(
                  tooltip: 'Sections',
                  iconSize: 28,
                  icon: const Icon(Icons.format_list_bulleted_rounded),
                  onPressed: onShowChapters,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _SeekBar extends StatefulWidget {
  const _SeekBar({required this.player});
  final LecturePlayer player;

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
        final posMs = (_dragMs ?? (snap.data ?? widget.player.position).inMilliseconds.toDouble())
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
