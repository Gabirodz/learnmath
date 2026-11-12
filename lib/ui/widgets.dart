import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/models.dart';
import '../core/providers.dart';

/// "1:02:03" or "12:34".
String formatDuration(Duration d) {
  final h = d.inHours;
  final m = d.inMinutes.remainder(60);
  final s = d.inSeconds.remainder(60);
  String two(int n) => n.toString().padLeft(2, '0');
  return h > 0 ? '$h:${two(m)}:${two(s)}' : '$m:${two(s)}';
}

/// Asks for confirmation before deleting [what]. Resolves to false if dismissed.
Future<bool> confirmDelete(BuildContext context, {required String what}) async {
  final result = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('Delete?'),
      content: Text('Delete $what? This cannot be undone.'),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel')),
        FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(ctx).colorScheme.error,
              foregroundColor: Theme.of(ctx).colorScheme.onError,
            ),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete')),
      ],
    ),
  );
  return result ?? false;
}

/// Starts generation for [lessonId], or points the user to settings when no
/// API key is configured.
void generateLesson(BuildContext context, WidgetRef ref, String lessonId) {
  if (!ref.read(settingsProvider).hasApiKey) {
    final messenger = ScaffoldMessenger.of(context);
    final router = GoRouter.of(context);
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(SnackBar(
      content: const Text('Add your OpenRouter API key first.'),
      action: SnackBarAction(
          label: 'Settings', onPressed: () => router.push('/settings')),
    ));
    return;
  }
  ref.read(generationProvider).enqueue(lessonId);
}

class LessonTile extends ConsumerWidget {
  const LessonTile({super.key, required this.lesson, this.index, this.onDelete});

  final Lesson lesson;

  /// 1-based position within a course.
  final int? index;
  final VoidCallback? onDelete;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final progress = ref.watch(jobProgressProvider)[lesson.id];
    final generation = ref.read(generationProvider);
    final working = lesson.stage.isWorking || progress != null;

    String subtitle;
    TextStyle? subtitleStyle = text.bodyMedium?.copyWith(
        color: scheme.onSurfaceVariant);
    int subtitleLines = 1;
    Widget trailing;
    Widget? bottom;
    VoidCallback onTap = () => context.push('/lesson/${lesson.id}');

    if (working) {
      subtitle = progress?.label ?? 'Working…';
      trailing = IconButton(
        tooltip: 'Cancel generation',
        icon: const Icon(Icons.close),
        onPressed: () => generation.cancel(lesson.id),
      );
      bottom = Padding(
        padding: const EdgeInsets.only(top: 6),
        child: LinearProgressIndicator(
            value: progress?.fraction, borderRadius: BorderRadius.circular(4)),
      );
    } else if (lesson.stage == LessonStage.failed) {
      subtitle = lesson.error ?? 'Generation failed';
      subtitleLines = 2;
      subtitleStyle = text.bodyMedium?.copyWith(color: scheme.error);
      trailing = IconButton(
        tooltip: 'Retry',
        icon: const Icon(Icons.refresh),
        onPressed: () => generateLesson(context, ref, lesson.id),
      );
    } else if (lesson.stage == LessonStage.pending) {
      subtitle = lesson.brief.isEmpty ? 'Not generated yet' : lesson.brief;
      subtitleLines = 2;
      trailing = IconButton.filledTonal(
        tooltip: 'Generate',
        icon: const Icon(Icons.auto_awesome),
        onPressed: () => generateLesson(context, ref, lesson.id),
      );
      onTap = () => generateLesson(context, ref, lesson.id);
    } else {
      final ms = lesson.audioDurationMs;
      final mins = ms == null ? null : (ms / 60000).ceil();
      subtitle = mins == null ? 'Ready' : '$mins min';
      if (lesson.completed) {
        trailing = Icon(Icons.check_circle, color: scheme.primary, semanticLabel: 'Completed');
      } else if (lesson.lastPositionMs > 0 && ms != null && ms > 0) {
        trailing = SizedBox(
          width: 24,
          height: 24,
          child: CircularProgressIndicator(
            value: (lesson.lastPositionMs / ms).clamp(0.0, 1.0),
            strokeWidth: 3,
            semanticsLabel: 'Resume progress',
          ),
        );
        subtitle = '$subtitle · in progress';
      } else {
        trailing = Icon(Icons.play_circle_outline, color: scheme.onSurfaceVariant);
      }
    }

    final badge = index == null
        ? null
        : CircleAvatar(
            radius: 16,
            backgroundColor: scheme.secondaryContainer,
            foregroundColor: scheme.onSecondaryContainer,
            child: Text('$index', style: text.labelLarge),
          );

    return InkWell(
      onTap: onTap,
      onLongPress: onDelete,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 64),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
          child: Row(
            children: [
              if (badge != null) ...[badge, const SizedBox(width: 12)],
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(lesson.title,
                        style: text.titleMedium,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis),
                    const SizedBox(height: 2),
                    Text(subtitle,
                        style: subtitleStyle,
                        maxLines: subtitleLines,
                        overflow: TextOverflow.ellipsis),
                    ?bottom,
                  ],
                ),
              ),
              const SizedBox(width: 8),
              trailing,
              if (onDelete != null)
                PopupMenuButton<String>(
                  tooltip: 'More options',
                  onSelected: (_) => onDelete!(),
                  itemBuilder: (_) => const [
                    PopupMenuItem(value: 'delete', child: Text('Delete')),
                  ],
                ),
            ],
          ),
        ),
      ),
    );
  }
}

const double kWideBreakpoint = 840;
const double kMaxContentWidth = 1200;

/// Lays [children] out as a single column on phones and as a wrapping grid
/// (cells up to ~420 wide) on wide screens. Meant to sit inside a sliver list.
class AdaptiveCards extends StatelessWidget {
  const AdaptiveCards({super.key, required this.children});
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, c) {
      final width = c.maxWidth;
      if (MediaQuery.sizeOf(context).width < kWideBreakpoint) {
        return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch, children: children);
      }
      const spacing = 12.0;
      final cols = (width / (420 + spacing)).ceil().clamp(1, 6);
      final cell = (width - spacing * (cols - 1)) / cols;
      return Wrap(
        spacing: spacing,
        runSpacing: spacing,
        children: [for (final w in children) SizedBox(width: cell, child: w)],
      );
    });
  }
}

/// Centres [child] with a max width, with horizontal padding.
class ContentWidth extends StatelessWidget {
  const ContentWidth({super.key, required this.child, this.maxWidth = kMaxContentWidth});
  final Widget child;
  final double maxWidth;

  @override
  Widget build(BuildContext context) => Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: maxWidth), child: child),
      );
}
