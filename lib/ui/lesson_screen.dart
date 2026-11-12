import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/models.dart';
import '../core/providers.dart';
import '../notes/notes_view.dart';
import '../notes/pdf_exporter.dart';
import '../notes/pdf_view.dart';
import '../player/player_view.dart';

/// One lesson: Listen / Notes / PDF. Phones get three tabs; wide screens show
/// the player next to the notes.
class LessonScreen extends ConsumerWidget {
  const LessonScreen({super.key, required this.lessonId});

  final String lessonId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(lessonProvider(lessonId));
    final lesson = async.value;
    if (lesson == null) {
      return Scaffold(
        appBar: AppBar(),
        body: Center(
          child: async.isLoading
              ? const CircularProgressIndicator()
              : const Text('This lesson no longer exists.'),
        ),
      );
    }

    final wide = MediaQuery.sizeOf(context).width >= 840;
    final listen = _ListenPane(lesson: lesson);
    final notes = _NotesPane(lessonId: lessonId);
    final pdf = _PdfPane(lessonId: lessonId);

    final actions = [
      PopupMenuButton<String>(
        onSelected: (v) {
          if (v == 'rerecord') ref.read(generationProvider).rerecord(lessonId);
        },
        itemBuilder: (_) => [
          PopupMenuItem(
            value: 'rerecord',
            enabled: lesson.stage == LessonStage.ready,
            child: const Text('Re-record with current voice settings'),
          ),
        ],
      ),
    ];

    if (wide) {
      return DefaultTabController(
        length: 2,
        child: Scaffold(
          appBar: AppBar(title: Text(lesson.title), actions: actions),
          body: Row(
            children: [
              Expanded(flex: 5, child: listen),
              const VerticalDivider(width: 1),
              Expanded(
                flex: 6,
                child: Column(
                  children: [
                    const TabBar(tabs: [Tab(text: 'Notes'), Tab(text: 'PDF')]),
                    Expanded(child: TabBarView(children: [notes, pdf])),
                  ],
                ),
              ),
            ],
          ),
        ),
      );
    }
    return DefaultTabController(
      length: 3,
      child: Scaffold(
        appBar: AppBar(
          title: Text(lesson.title),
          actions: actions,
          bottom: const TabBar(tabs: [
            Tab(text: 'Listen'),
            Tab(text: 'Notes'),
            Tab(text: 'PDF'),
          ]),
        ),
        // Horizontal swipes belong to the player's double-tap surface and to
        // wide formulas, so tabs switch by tapping only.
        body: TabBarView(
          physics: const NeverScrollableScrollPhysics(),
          children: [listen, notes, pdf],
        ),
      ),
    );
  }
}

class _ListenPane extends ConsumerWidget {
  const _ListenPane({required this.lesson});
  final Lesson lesson;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final progress =
        ref.watch(jobProgressProvider.select((m) => m[lesson.id]));
    if (lesson.stage == LessonStage.ready && lesson.hasAudio) {
      return PlayerView(lesson: lesson);
    }

    final theme = Theme.of(context);
    final generation = ref.read(generationProvider);
    final working = progress != null || lesson.stage.isWorking;
    final Widget content;
    if (working) {
      content = Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 240,
            child: LinearProgressIndicator(value: progress?.fraction),
          ),
          const SizedBox(height: 20),
          Text(progress?.label ?? 'Working…',
              style: theme.textTheme.titleMedium, textAlign: TextAlign.center),
          const SizedBox(height: 8),
          Text(
            lesson.hasNotes
                ? 'The notes are ready to read while the lecture is recorded. '
                    'Keep the app open.'
                : 'This takes a few minutes. Keep the app open.',
            style: theme.textTheme.bodyMedium!
                .copyWith(color: theme.colorScheme.onSurfaceVariant),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 16),
          TextButton(
            onPressed: () => generation.cancel(lesson.id),
            child: const Text('Cancel'),
          ),
        ],
      );
    } else if (lesson.stage == LessonStage.failed) {
      content = Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.error_outline, size: 40, color: theme.colorScheme.error),
          const SizedBox(height: 12),
          Text(lesson.error ?? 'Something went wrong.',
              textAlign: TextAlign.center),
          const SizedBox(height: 16),
          Wrap(
            spacing: 12,
            alignment: WrapAlignment.center,
            children: [
              FilledButton.icon(
                onPressed: () => generation.enqueue(lesson.id),
                icon: const Icon(Icons.refresh),
                label: const Text('Retry'),
              ),
              OutlinedButton(
                onPressed: () => context.push('/settings'),
                child: const Text('Settings'),
              ),
            ],
          ),
        ],
      );
    } else {
      content = Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(lesson.brief, textAlign: TextAlign.center),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: () => generation.enqueue(lesson.id),
            icon: const Icon(Icons.auto_awesome),
            label: const Text('Generate lesson'),
          ),
        ],
      );
    }
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: content,
      ),
    );
  }
}

class _NotesPane extends ConsumerWidget {
  const _NotesPane({required this.lessonId});
  final String lessonId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Select only the text so position saves don't re-render the notes.
    final markdown = ref.watch(
        lessonProvider(lessonId).select((a) => a.value?.notesMarkdown));
    if (markdown == null || markdown.isEmpty) {
      return const _Placeholder('Notes appear here once they are written.');
    }
    return NotesView(markdown: markdown);
  }
}

class _PdfPane extends ConsumerStatefulWidget {
  const _PdfPane({required this.lessonId});
  final String lessonId;

  @override
  ConsumerState<_PdfPane> createState() => _PdfPaneState();
}

class _PdfPaneState extends ConsumerState<_PdfPane>
    with AutomaticKeepAliveClientMixin {
  bool _building = false;
  Object? _error;

  @override
  bool get wantKeepAlive => true;

  Future<void> _build() async {
    setState(() {
      _building = true;
      _error = null;
    });
    try {
      final repo = ref.read(repositoryProvider);
      final lesson = await repo.getLesson(widget.lessonId);
      if (lesson == null || !lesson.hasNotes) return;
      final course = lesson.courseId == null
          ? null
          : await repo.getCourse(lesson.courseId!);
      final bytes = await PdfExporter.build(
        title: lesson.title,
        markdown: lesson.notesMarkdown!,
        subtitle: course?.title,
      );
      final path = ref.read(appPathsProvider).lessonPdf(lesson.id);
      final file = File(path);
      await file.parent.create(recursive: true);
      await file.writeAsBytes(bytes, flush: true);
      await repo.updateLesson(lesson.id, (l) => l.copyWith(pdfPath: path));
    } catch (e) {
      if (mounted) setState(() => _error = e);
    } finally {
      if (mounted) setState(() => _building = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final (hasNotes, pdfPath) = ref.watch(lessonProvider(widget.lessonId)
        .select((a) => (a.value?.hasNotes ?? false, a.value?.pdfPath)));
    if (!hasNotes) {
      return const _Placeholder('The PDF is available once notes are written.');
    }
    if (_building) {
      return const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(),
            SizedBox(height: 16),
            Text('Typesetting the PDF…'),
          ],
        ),
      );
    }
    if (pdfPath != null && File(pdfPath).existsSync()) {
      return Stack(
        children: [
          Positioned.fill(child: NotesPdfView(filePath: pdfPath)),
          Positioned(
            right: 16,
            bottom: 16,
            child: SafeArea(
              child: FloatingActionButton.small(
                heroTag: null,
                tooltip: 'Share PDF',
                onPressed: () => sharePdf(pdfPath),
                child: const Icon(Icons.share),
              ),
            ),
          ),
        ],
      );
    }
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (_error != null) ...[
              Text('Could not create the PDF.\n$_error',
                  textAlign: TextAlign.center),
              const SizedBox(height: 16),
            ],
            FilledButton.icon(
              onPressed: _build,
              icon: const Icon(Icons.picture_as_pdf_outlined),
              label: Text(_error == null ? 'Create PDF' : 'Try again'),
            ),
          ],
        ),
      ),
    );
  }
}

class _Placeholder extends StatelessWidget {
  const _Placeholder(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            text,
            textAlign: TextAlign.center,
            style: TextStyle(
                color: Theme.of(context).colorScheme.onSurfaceVariant),
          ),
        ),
      );
}
