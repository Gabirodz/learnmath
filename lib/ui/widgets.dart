import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/models.dart';
import '../core/providers.dart';
import '../pipeline/generation_service.dart';

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
/// A way back to the library for a screen with nothing beneath it (one opened
/// from a notification, say); null where the usual back arrow is shown.
Widget? homeButtonIfRoot(BuildContext context) => Navigator.of(context).canPop()
    ? null
    : IconButton(
        tooltip: 'Library',
        icon: const Icon(Icons.home_outlined),
        onPressed: () => context.go('/'),
      );

/// Whether [lesson] is a planned or failed lesson with nothing written yet,
/// which an assistant outside the app can write.
bool canWriteOutside(Lesson lesson) =>
    (lesson.stage == LessonStage.pending ||
        lesson.stage == LessonStage.failed) &&
    !lesson.hasNotes &&
    !lesson.isBookChapter &&
    !lesson.isRecap &&
    !lesson.isReview;

void generateLesson(BuildContext context, WidgetRef ref, String lessonId,
    {bool? audio, Lesson? lesson}) {
  final settings = ref.read(settingsProvider);
  // Reading a book chapter with Mathpix is the one job that needs no key;
  // the pipeline reports a missing key itself in that mode.
  final mathpix =
      settings.transcriptionBackend == TranscriptionBackend.mathpix;
  // Nor does recording a lesson that already has its script.
  final onDevice =
      lesson != null && GenerationService.runsOnDevice(lesson, settings);
  if (!settings.hasApiKey && !mathpix && !onDevice) {
    // A planned lesson can still be written by the student's own assistant.
    if (lesson != null && canWriteOutside(lesson)) {
      GoRouter.of(context).push('/import-lesson?lesson=$lessonId');
      return;
    }
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
  ref.read(generationProvider).enqueue(lessonId, audio: audio);
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
    // Only this lesson's progress: a recording ticks once per sentence.
    final progress =
        ref.watch(jobProgressProvider.select((m) => m[lesson.id]));
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
      subtitle = progress?.label ??
          (lesson.isWaitingForBatch
              ? GenerationService.waitingLabel(lesson)
              : 'Working…');
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
        onPressed: () =>
            generateLesson(context, ref, lesson.id, lesson: lesson),
      );
    } else if (lesson.stage == LessonStage.pending) {
      subtitle = lesson.brief.isEmpty ? 'Not generated yet' : lesson.brief;
      subtitleLines = 2;
      trailing = IconButton.filledTonal(
        tooltip: lesson.isBookChapter ? 'Read this chapter in' : 'Generate',
        icon: Icon(lesson.isBookChapter
            ? Icons.document_scanner_outlined
            : Icons.auto_awesome),
        onPressed: () =>
            generateLesson(context, ref, lesson.id, lesson: lesson),
      );
      // A book chapter can already be opened: its pages are in the PDF tab.
      if (!lesson.isBookChapter) {
        onTap = () => generateLesson(context, ref, lesson.id, lesson: lesson);
      }
    } else {
      final ms = lesson.audioDurationMs;
      final mins = ms == null ? null : (ms / 60000).ceil();
      subtitle = mins == null ? 'Ready to read and ask' : '$mins min';
      // The voice model of the recording ("Piper LJSpeech").
      final voice = lesson.voice?.split(' · ').first;
      if (mins != null && voice != null) subtitle = '$subtitle · $voice';
      // The model that wrote it ("GPT-6.1 Sol (batch)"), without the effort.
      final writer = lesson.writtenBy?.split(' · ').first;
      if (writer != null) {
        subtitle = '$subtitle · $writer';
        subtitleLines = 2;
      }
      if (!lesson.hasAudio) {
        trailing = Icon(Icons.menu_book_outlined, color: scheme.onSurfaceVariant);
      } else if (lesson.completed) {
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

/// [padding] widened at the sides so that content in a scroll view spanning
/// [width] sits centred in a column of at most [maxWidth].
EdgeInsets centredPadding(double width, EdgeInsets padding, double maxWidth) {
  final side = (width - maxWidth) / 2;
  return side <= 0 ? padding : padding + EdgeInsets.symmetric(horizontal: side);
}

/// A [ListView] as wide as its parent, with its content centred in a column
/// of at most [maxWidth]. Unlike a list inside [ContentWidth], the empty
/// margins of a wide screen scroll it too.
class CentredListView extends StatelessWidget {
  const CentredListView({
    super.key,
    required this.children,
    this.padding = EdgeInsets.zero,
    this.maxWidth = kMaxContentWidth,
  });

  final List<Widget> children;
  final EdgeInsets padding;
  final double maxWidth;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
        builder: (context, c) => ListView(
          padding: centredPadding(c.maxWidth, padding, maxWidth),
          children: children,
        ),
      );
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
