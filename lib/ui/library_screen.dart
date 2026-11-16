import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/models.dart';
import '../core/providers.dart';
import '../player/mini_player.dart';
import 'create_sheet.dart';
import 'review_sheet.dart';
import 'widgets.dart';

class LibraryScreen extends ConsumerWidget {
  const LibraryScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(settingsProvider);
    final courses = ref.watch(coursesProvider);
    final lessons = ref.watch(standaloneLessonsProvider);
    final text = Theme.of(context).textTheme;

    Widget body;
    if (courses.hasError || lessons.hasError) {
      body = Center(
          child: Padding(
        padding: const EdgeInsets.all(24),
        child: Text('Could not load your library.\n${courses.error ?? lessons.error}',
            textAlign: TextAlign.center),
      ));
    } else if (!courses.hasValue || !lessons.hasValue) {
      body = const Center(child: CircularProgressIndicator());
    } else {
      final cs = courses.requireValue;
      final ls = lessons.requireValue;
      final empty = cs.isEmpty && ls.isEmpty;
      body = CustomScrollView(
        slivers: [
          SliverToBoxAdapter(
            child: ContentWidth(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (!settings.hasApiKey) const _ApiKeyBanner(),
                    if (empty) const _EmptyState(),
                  ],
                ),
              ),
            ),
          ),
          if (cs.isNotEmpty) ...[
            _header('Courses', text),
            SliverToBoxAdapter(
              child: ContentWidth(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: AdaptiveCards(children: [
                    for (final g in seriesGroups(cs))
                      g.length == 1 && g.single.part == 1
                          ? _CourseCard(course: g.single)
                          : _SeriesCard(parts: g),
                  ]),
                ),
              ),
            ),
          ],
          if (ls.isNotEmpty) ...[
            _header('Lessons', text),
            SliverToBoxAdapter(
              child: ContentWidth(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: AdaptiveCards(children: [
                    for (final l in ls)
                      Card(
                        margin: EdgeInsets.zero,
                        clipBehavior: Clip.antiAlias,
                        child: LessonTile(
                          lesson: l,
                          onDelete: () => _deleteLesson(context, ref, l),
                        ),
                      ),
                  ]),
                ),
              ),
            ),
          ],
          const SliverToBoxAdapter(child: SizedBox(height: 96)),
        ],
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('LearnMath'),
        actions: [
          IconButton(
            tooltip: 'Review what you studied',
            icon: const Icon(Icons.style_outlined),
            onPressed: () => showReviewSheet(context),
          ),
          IconButton(
            tooltip: 'Settings',
            icon: const Icon(Icons.settings_outlined),
            onPressed: () => context.push('/settings'),
          ),
        ],
      ),
      body: SafeArea(child: body),
      bottomNavigationBar: const MiniPlayerBar(),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => showCreateSheet(context),
        icon: const Icon(Icons.add),
        label: const Text('New'),
      ),
    );
  }

  Widget _header(String title, TextTheme text) => SliverToBoxAdapter(
        child: ContentWidth(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 20, 16, 8),
            child: Semantics(
                header: true, child: Text(title, style: text.titleLarge)),
          ),
        ),
      );

  Future<void> _deleteLesson(
      BuildContext context, WidgetRef ref, Lesson l) async {
    if (!await confirmDelete(context, what: 'the lesson "${l.title}"')) return;
    ref.read(generationProvider).cancel(l.id);
    await ref.read(repositoryProvider).deleteLesson(l.id);
  }
}

class _ApiKeyBanner extends StatelessWidget {
  const _ApiKeyBanner();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      color: scheme.tertiaryContainer,
      margin: const EdgeInsets.only(bottom: 8),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Icon(Icons.key, color: scheme.onTertiaryContainer),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  'Add your OpenRouter API key to start generating lessons.',
                  style: Theme.of(context)
                      .textTheme
                      .bodyLarge
                      ?.copyWith(color: scheme.onTertiaryContainer),
                ),
              ),
            ]),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerRight,
              child: FilledButton.tonal(
                onPressed: () => context.push('/settings'),
                child: const Text('Open settings'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 48, horizontal: 8),
      child: Column(
        children: [
          Text('Your personal math lecturer',
              style: text.headlineSmall, textAlign: TextAlign.center),
          const SizedBox(height: 12),
          Text(
            'Describe any topic and LearnMath writes graduate-level lecture '
            'notes and records them as audio you can listen to anywhere. '
            'Make a single lesson, or plan a whole course.',
            style: text.bodyLarge?.copyWith(color: scheme.onSurfaceVariant),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 24),
          FilledButton.icon(
            onPressed: () => showCreateSheet(context),
            icon: const Icon(Icons.add),
            label: const Text('Create your first lesson'),
          ),
        ],
      ),
    );
  }
}

/// [courses] grouped by series: each group's parts in part order, the
/// groups in the order of their newest part (newest first).
List<List<Course>> seriesGroups(List<Course> courses) {
  final groups = <String, List<Course>>{};
  for (final c in courses) {
    groups.putIfAbsent(c.series, () => []).add(c);
  }
  DateTime newest(List<Course> g) => g
      .map((c) => c.createdAt)
      .reduce((a, b) => a.isAfter(b) ? a : b);
  return [
    for (final g in groups.values) g..sort((a, b) => a.part.compareTo(b.part)),
  ]..sort((a, b) => newest(b).compareTo(newest(a)));
}

/// The parts of a series together in one box.
class _SeriesCard extends StatelessWidget {
  const _SeriesCard({required this.parts});
  final List<Course> parts;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: scheme.primaryContainer.withValues(alpha: 0.35),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: scheme.primary.withValues(alpha: 0.4)),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(8, 10, 8, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
              child: Row(children: [
                Icon(Icons.collections_bookmark_outlined,
                    size: 18, color: scheme.primary),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '${parts.first.title} · ${parts.length} '
                    '${parts.length == 1 ? 'part' : 'parts'}',
                    style: text.labelLarge?.copyWith(color: scheme.primary),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ]),
            ),
            for (var i = 0; i < parts.length; i++) ...[
              if (i > 0) const SizedBox(height: 8),
              _CourseCard(course: parts[i], showPart: true),
            ],
          ],
        ),
      ),
    );
  }
}

class _CourseCard extends ConsumerWidget {
  const _CourseCard({required this.course, this.showPart = false});
  final Course course;

  /// Inside a series: says which part this is.
  final bool showPart;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    final lessons = ref.watch(courseLessonsProvider(course.id)).value;
    final total = lessons?.length ?? 0;
    final ready = lessons?.where((l) => l.stage == LessonStage.ready).length ?? 0;

    return Card(
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => context.push('/course/${course.id}'),
        onLongPress: () => _delete(context, ref),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 4, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          if (showPart)
                            Text('Part ${course.part}',
                                style: text.labelMedium
                                    ?.copyWith(color: scheme.primary)),
                          Text(course.title,
                              style: text.titleMedium,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis),
                        ],
                      ),
                    ),
                  ),
                  PopupMenuButton<String>(
                    tooltip: 'More options',
                    onSelected: (_) => _delete(context, ref),
                    itemBuilder: (_) => const [
                      PopupMenuItem(value: 'delete', child: Text('Delete')),
                    ],
                  ),
                ],
              ),
              if (course.description.isNotEmpty) ...[
                Padding(
                  padding: const EdgeInsets.only(right: 12),
                  child: Text(course.description,
                      style: text.bodyMedium
                          ?.copyWith(color: scheme.onSurfaceVariant),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis),
                ),
              ],
              const SizedBox(height: 12),
              Padding(
                padding: const EdgeInsets.only(right: 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('$ready of $total lessons ready',
                        style: text.labelMedium),
                    const SizedBox(height: 6),
                    LinearProgressIndicator(
                      value: total == 0 ? 0 : ready / total,
                      minHeight: 4,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _delete(BuildContext context, WidgetRef ref) async {
    if (!await confirmDelete(context,
        what: 'the course "${course.title}" and all its lessons')) {
      return;
    }
    final gen = ref.read(generationProvider);
    final lessons = ref.read(courseLessonsProvider(course.id)).value ?? const [];
    for (final l in lessons) {
      gen.cancel(l.id);
    }
    await ref.read(repositoryProvider).deleteCourse(course.id);
  }
}
