import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/models.dart';
import '../core/providers.dart';
import 'player_controls.dart';

/// The mini-player docked at the bottom of the library, course and lesson
/// screens (use it as `bottomNavigationBar`, so the floating action button
/// moves up). Shows nothing but the bottom safe-area gap while no lesson is
/// loaded.
class MiniPlayerBar extends ConsumerWidget {
  const MiniPlayerBar({super.key, this.onOpen});

  /// What tapping the title does; by default it opens the lesson.
  final void Function(Lesson lesson)? onOpen;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return MiniPlayer(
      controls: ref.watch(lecturePlayerProvider),
      skipSeconds: ref.watch(settingsProvider.select((s) => s.skipSeconds)),
      onOpen: onOpen ?? (lesson) => context.push('/lesson/${lesson.id}'),
    );
  }
}

class MiniPlayer extends StatelessWidget {
  const MiniPlayer({
    super.key,
    required this.controls,
    required this.onOpen,
    this.skipSeconds = 10,
  });

  final PlayerControls controls;
  final void Function(Lesson lesson) onOpen;
  final int skipSeconds;

  IconData get _backIcon => switch (skipSeconds) {
        5 => Icons.replay_5_rounded,
        10 => Icons.replay_10_rounded,
        30 => Icons.replay_30_rounded,
        _ => Icons.fast_rewind_rounded,
      };

  IconData get _forwardIcon => switch (skipSeconds) {
        5 => Icons.forward_5_rounded,
        10 => Icons.forward_10_rounded,
        30 => Icons.forward_30_rounded,
        _ => Icons.fast_forward_rounded,
      };

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<Lesson?>(
      valueListenable: controls.lesson,
      builder: (context, lesson, _) {
        // Even when empty this occupies the safe area: a Scaffold removes the
        // body's bottom padding once it has a bottom bar.
        if (lesson == null) {
          return SizedBox(height: MediaQuery.paddingOf(context).bottom);
        }
        final scheme = Theme.of(context).colorScheme;
        return Material(
          color: scheme.surfaceContainerHigh,
          elevation: 3,
          child: SafeArea(
            top: false,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _Progress(controls: controls),
                Row(
                  children: [
                    Expanded(
                      child: InkWell(
                        onTap: () => onOpen(lesson),
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(minHeight: 56),
                          child: Padding(
                            padding: const EdgeInsets.only(left: 16),
                            child: Align(
                              alignment: Alignment.centerLeft,
                              child: Text(
                                lesson.title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: Theme.of(context).textTheme.titleSmall,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                    IconButton(
                      tooltip: 'Back $skipSeconds seconds',
                      icon: Icon(_backIcon),
                      onPressed: () => controls.skipBy(forward: false),
                    ),
                    StreamBuilder<bool>(
                      stream: controls.playingStream,
                      initialData: controls.playing,
                      builder: (context, snap) {
                        final playing = snap.data ?? false;
                        return IconButton(
                          tooltip: playing ? 'Pause' : 'Play',
                          iconSize: 32,
                          icon: Icon(
                            playing
                                ? Icons.pause_rounded
                                : Icons.play_arrow_rounded,
                          ),
                          onPressed: controls.toggle,
                        );
                      },
                    ),
                    IconButton(
                      tooltip: 'Forward $skipSeconds seconds',
                      icon: Icon(_forwardIcon),
                      onPressed: () => controls.skipBy(forward: true),
                    ),
                    IconButton(
                      tooltip: 'Stop and close the player',
                      icon: const Icon(Icons.close),
                      onPressed: controls.stop,
                    ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _Progress extends StatelessWidget {
  const _Progress({required this.controls});
  final PlayerControls controls;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<Duration>(
      stream: controls.positionStream,
      initialData: controls.position,
      builder: (context, snap) {
        final total = controls.duration.inMilliseconds;
        final pos = (snap.data ?? Duration.zero).inMilliseconds;
        return LinearProgressIndicator(
          minHeight: 2,
          value: total <= 0 ? 0 : (pos / total).clamp(0.0, 1.0),
        );
      },
    );
  }
}
