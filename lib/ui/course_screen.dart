import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/models.dart';
import '../core/providers.dart';
import '../player/mini_player.dart';
import 'continue_sheet.dart';
import 'widgets.dart';

class CourseScreen extends ConsumerWidget {
  const CourseScreen({super.key, required this.courseId});

  final String courseId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final courseAsync = ref.watch(courseProvider(courseId));
    final lessonsAsync = ref.watch(courseLessonsProvider(courseId));

    if (!courseAsync.hasValue) {
      return Scaffold(
        appBar: AppBar(),
        body: Center(
            child: courseAsync.hasError
                ? Text('${courseAsync.error}')
                : const CircularProgressIndicator()),
      );
    }
    final course = courseAsync.requireValue;
    if (course == null) {
      return Scaffold(
        appBar: AppBar(),
        body: const Center(
          child: Padding(
            padding: EdgeInsets.all(24),
            child: Text('This course was not found. It may have been deleted.',
                textAlign: TextAlign.center),
          ),
        ),
      );
    }

    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    final lessons = lessonsAsync.value ?? const <Lesson>[];
    final ready = lessons.where((l) => l.stage == LessonStage.ready).length;
    final remaining = lessons
        .where((l) =>
            l.stage == LessonStage.pending || l.stage == LessonStage.failed)
        .toList();
    final unwritten = [
      for (final l in remaining)
        if (!l.hasNotes && !l.isBookChapter) l,
    ];
    // The parts of this course's series, in order.
    final parts = [
      for (final c in ref.watch(coursesProvider).value ?? const <Course>[])
        if (c.series == course.series) c,
    ]..sort((a, b) => a.part.compareTo(b.part));
    final inSeries = parts.length > 1 || course.part > 1;
    Course? previous, following;
    for (final c in parts) {
      if (c.part < course.part) previous = c;
      if (c.part > course.part && following == null) following = c;
    }
    final nextNumber = (parts.isEmpty ? course.part : parts.last.part) + 1;

    return Scaffold(
      bottomNavigationBar: const MiniPlayerBar(),
      body: CustomScrollView(
        slivers: [
          // The title in the bar is one line; in full it heads the page,
          // where a long one has room to wrap.
          SliverAppBar(
            pinned: true,
            leading: homeButtonIfRoot(context),
            title: Text(course.title),
          ),
          SliverToBoxAdapter(
            child: ContentWidth(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (inSeries)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 4),
                        child: Text(
                          'Part ${course.part}'
                          '${parts.isNotEmpty && parts.first.id != course.id ? ' · ${parts.first.title}' : ''}',
                          style: text.labelLarge
                              ?.copyWith(color: scheme.primary),
                        ),
                      ),
                    Text(course.title, style: text.headlineMedium),
                    const SizedBox(height: 8),
                    if (course.description.isNotEmpty)
                      Text(course.description,
                          style: text.bodyLarge
                              ?.copyWith(color: scheme.onSurfaceVariant)),
                    const SizedBox(height: 16),
                    Text('$ready of ${lessons.length} lessons ready',
                        style: text.labelLarge),
                    const SizedBox(height: 6),
                    LinearProgressIndicator(
                      value: lessons.isEmpty ? 0 : ready / lessons.length,
                      minHeight: 4,
                      borderRadius: BorderRadius.circular(2),
                    ),
                    if (previous != null || following != null) ...[
                      const SizedBox(height: 8),
                      Wrap(spacing: 8, children: [
                        if (previous case final p?)
                          TextButton.icon(
                            onPressed: () => context.push('/course/${p.id}'),
                            icon: const Icon(Icons.arrow_back, size: 18),
                            label: Text('Part ${p.part}'),
                          ),
                        if (following case final f?)
                          TextButton.icon(
                            onPressed: () => context.push('/course/${f.id}'),
                            icon: const Icon(Icons.arrow_forward, size: 18),
                            label: Text('Part ${f.part}'),
                          ),
                      ]),
                    ],
                    const SizedBox(height: 16),
                    Wrap(spacing: 8, runSpacing: 8, children: [
                      FilledButton.tonalIcon(
                        onPressed: remaining.isEmpty
                            ? null
                            : () => _generateAll(context, ref, remaining),
                        icon: const Icon(Icons.auto_awesome),
                        label: const Text('Generate all remaining'),
                      ),
                      // The next lesson that is still to be written.
                      if (unwritten.isNotEmpty)
                        OutlinedButton.icon(
                          onPressed: () => context.push(
                              '/import-lesson?lesson=${unwritten.first.id}'),
                          icon: const Icon(Icons.content_paste_go),
                          label: Text('Write lesson '
                              '${unwritten.first.order + 1} with your own AI'),
                        ),
                      // A book's chapters are its own; its parts cannot be
                      // planned on.
                      if (!course.isBook)
                        OutlinedButton.icon(
                          onPressed: () => showContinueSheet(context,
                              course: course, nextPart: nextNumber),
                          icon: const Icon(Icons.playlist_add),
                          label: Text('Continue with part $nextNumber'),
                        ),
                    ]),
                  ],
                ),
              ),
            ),
          ),
          SliverToBoxAdapter(
            child: ContentWidth(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 96),
                child: lessonsAsync.isLoading && lessons.isEmpty
                    ? const Center(child: CircularProgressIndicator())
                    : AdaptiveCards(children: [
                        for (var i = 0; i < lessons.length; i++)
                          Card(
                            margin: EdgeInsets.zero,
                            clipBehavior: Clip.antiAlias,
                            child: LessonTile(lesson: lessons[i], index: i + 1),
                          ),
                      ]),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _generateAll(
      BuildContext context, WidgetRef ref, List<Lesson> remaining) async {
    if (!ref.read(settingsProvider).hasApiKey) {
      generateLesson(context, ref, remaining.first.id);
      return;
    }
    final n = remaining.length;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Generate all remaining?'),
        content: Text((remaining.first.model ??
                    ref.read(settingsProvider).lessonChoice)
                .batch
            ? '$n ${n == 1 ? 'lesson' : 'lessons'} will be sent to the batch '
                'queue. They usually arrive within minutes, at most a day, '
                'and you get a notification for each. This uses OpenRouter '
                'API credits.'
            : '$n ${n == 1 ? 'lesson' : 'lessons'} will be generated one '
                'after another. This uses OpenRouter API credits.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Generate')),
        ],
      ),
    );
    if (ok != true) return;
    final gen = ref.read(generationProvider);
    for (final l in remaining) {
      gen.enqueue(l.id);
    }
  }
}
