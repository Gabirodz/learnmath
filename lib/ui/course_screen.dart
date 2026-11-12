import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/models.dart';
import '../core/providers.dart';
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

    return Scaffold(
      body: CustomScrollView(
        slivers: [
          SliverAppBar.large(title: Text(course.title)),
          SliverToBoxAdapter(
            child: ContentWidth(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
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
                    const SizedBox(height: 16),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: FilledButton.tonalIcon(
                        onPressed: remaining.isEmpty
                            ? null
                            : () => _generateAll(context, ref, remaining),
                        icon: const Icon(Icons.auto_awesome),
                        label: const Text('Generate all remaining'),
                      ),
                    ),
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
        content: Text(
            '$n ${n == 1 ? 'lesson' : 'lessons'} will be generated one after '
            'another. This uses OpenRouter API credits.'),
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
