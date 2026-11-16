import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../cards/cards_pane.dart';
import '../chat/chat_controller.dart';
import '../chat/chat_pane.dart';
import '../checks/check_banner.dart';
import '../checks/review_banner.dart';
import '../core/models.dart';
import '../core/providers.dart';
import '../platform/files.dart';
import '../exercises/exercise_parser.dart';
import '../exercises/exercises_sheet.dart';
import '../notes/notes_view.dart';
import '../notes/pdf_exporter.dart';
import '../notes/pdf_view.dart';
import '../player/mini_player.dart';
import '../player/player_view.dart';
import '../quiz/quiz_pane.dart';
import 'model_picker.dart';
import 'widgets.dart';

/// One lesson: Listen / Notes / PDF / Chat / Quiz. Phones get them as tabs;
/// wide screens show the player next to the others. A review of studied
/// lessons has its flashcards where the PDF would be.
class LessonScreen extends ConsumerWidget {
  const LessonScreen({super.key, required this.lessonId, this.quizTab = false});

  final String lessonId;

  /// Opens on the Quiz tab (from a "quiz ready" notification).
  final bool quizTab;

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
    // Index of the Chat tab in the tab controller of each layout.
    final chatTab = wide ? 2 : 3;
    final pdfLabel = lesson.isReview
        ? 'Cards'
        : lesson.isBookChapter
            ? 'Book'
            : 'PDF';

    // Attaches an excerpt to the next chat message and shows the chat.
    Widget withAsk(Widget Function(void Function(String quote) ask) build) =>
        Builder(builder: (context) {
          return build((quote) {
            ref.read(chatQuoteProvider(lessonId).notifier).set(quote);
            DefaultTabController.of(context).animateTo(chatTab);
          });
        });

    final listen =
        withAsk((ask) => _ListenPane(lesson: lesson, onAsk: ask));
    final notes =
        withAsk((ask) => _NotesPane(lessonId: lessonId, onAsk: ask));
    final pdf = lesson.isReview
        ? CardsPane(lessonId: lessonId)
        : lesson.isBookChapter
            ? _BookPane(lesson: lesson)
            : _PdfPane(lessonId: lessonId);
    final chat = ChatPane(lessonId: lessonId);
    final quiz = QuizPane(lessonId: lessonId);

    final jobRunning =
        ref.watch(jobProgressProvider.select((m) => m[lessonId] != null));
    final actions = [
      PopupMenuButton<String>(
        onSelected: (v) {
          if (v == 'rerecord') ref.read(generationProvider).rerecord(lessonId);
          if (v == 'verify') _confirmVerify(context, ref);
          if (v == 'studied') {
            ref.read(repositoryProvider).updateLesson(
                lessonId,
                (l) => l.completed
                    ? l.copyWith(completed: false)
                    : l.copyWith(
                        completed: true,
                        completedAt: l.completedAt ?? DateTime.now()));
          }
        },
        itemBuilder: (_) => [
          PopupMenuItem(
            value: 'rerecord',
            enabled: lesson.stage == LessonStage.ready && lesson.hasAudio,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text('Re-record with current voice settings'),
                // Which voice this recording has, to compare with Settings.
                if (lesson.hasAudio && lesson.voice != null)
                  Text('Recorded with ${lesson.voice}',
                      style: Theme.of(context).textTheme.bodySmall),
              ],
            ),
          ),
          PopupMenuItem(
            value: 'verify',
            enabled: lesson.stage == LessonStage.ready &&
                lesson.hasNotes &&
                !lesson.isBookChapter &&
                !jobRunning,
            child: const Text('Verify proofs with a second model'),
          ),
          // Studied lessons are what a review can cover. Listening to the
          // end marks a lesson too; this is for lessons that were read.
          if (!lesson.isReview && !lesson.isRecap)
            PopupMenuItem(
              value: 'studied',
              enabled: lesson.hasNotes,
              child: Text(lesson.completed
                  ? 'Mark as not studied'
                  : 'Mark as studied'),
            ),
        ],
      ),
    ];

    if (wide) {
      return DefaultTabController(
        length: 4,
        initialIndex: quizTab ? 3 : 0,
        child: Scaffold(
          appBar: AppBar(
            leading: homeButtonIfRoot(context),
            title: Text(lesson.title),
            actions: actions,
          ),
          bottomNavigationBar:
              _LessonMiniPlayer(lessonId: lesson.id, wide: true),
          body: Row(
            children: [
              Expanded(flex: 5, child: listen),
              const VerticalDivider(width: 1),
              Expanded(
                flex: 6,
                child: Column(
                  children: [
                    TabBar(tabs: [
                      const Tab(text: 'Notes'),
                      Tab(text: pdfLabel),
                      const Tab(text: 'Chat'),
                      const Tab(text: 'Quiz'),
                    ]),
                    Expanded(
                      child: TabBarView(
                        physics: const NeverScrollableScrollPhysics(),
                        children: [notes, pdf, chat, quiz],
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      );
    }
    return DefaultTabController(
      length: 5,
      initialIndex: quizTab ? 4 : 0,
      child: Scaffold(
        appBar: AppBar(
          leading: homeButtonIfRoot(context),
          title: Text(lesson.title),
          actions: actions,
          bottom: TabBar(tabs: [
            const Tab(text: 'Listen'),
            const Tab(text: 'Notes'),
            Tab(text: pdfLabel),
            const Tab(text: 'Chat'),
            const Tab(text: 'Quiz'),
          ]),
        ),
        bottomNavigationBar:
            _LessonMiniPlayer(lessonId: lesson.id, wide: false),
        // Horizontal swipes belong to the player's double-tap surface and to
        // wide formulas, so tabs switch by tapping only.
        body: TabBarView(
          physics: const NeverScrollableScrollPhysics(),
          children: [listen, notes, pdf, chat, quiz],
        ),
      ),
    );
  }
}

/// The mini-player on a lesson screen: shown while a lecture is loaded,
/// except where this lesson's own player is on screen (its Listen tab, or
/// beside the notes on a wide screen).
class _LessonMiniPlayer extends ConsumerWidget {
  const _LessonMiniPlayer({required this.lessonId, required this.wide});
  final String lessonId;
  final bool wide;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final player = ref.watch(lecturePlayerProvider);
    final gap = SizedBox(height: MediaQuery.paddingOf(context).bottom);
    return ValueListenableBuilder<Lesson?>(
      valueListenable: player.lesson,
      builder: (context, loaded, _) {
        if (loaded == null || loaded.id != lessonId) {
          return const MiniPlayerBar();
        }
        if (wide) return gap;
        final tabs = DefaultTabController.of(context);
        return ListenableBuilder(
          listenable: tabs,
          builder: (context, _) => tabs.index == 0
              ? gap
              : MiniPlayerBar(onOpen: (_) => tabs.animateTo(0)),
        );
      },
    );
  }
}

extension on LessonScreen {
  Future<void> _confirmVerify(BuildContext context, WidgetRef ref) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Verify proofs with a second model'),
        content: const Text(
            'A second model reads the proofs and reports possible errors. '
            'This costs several times what writing the lesson did. The notes '
            'and the recording are not changed.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Verify')),
        ],
      ),
    );
    if (ok == true) await ref.read(generationProvider).verify(lessonId);
  }
}

class _ListenPane extends ConsumerWidget {
  const _ListenPane({required this.lesson, required this.onAsk});
  final Lesson lesson;
  final void Function(String quote) onAsk;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final progress =
        ref.watch(jobProgressProvider.select((m) => m[lesson.id]));
    if (lesson.stage == LessonStage.ready && lesson.hasAudio) {
      return PlayerView(lesson: lesson, onAsk: onAsk);
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
            lesson.isWaitingForBatch && lesson.hasNotes
                ? 'The notes are ready to read. The lecture script is a '
                    'second request to the model and is in the batch queue '
                    'now, at about half the price; it usually arrives '
                    'within minutes, at most a day. After that the lecture '
                    'is recorded on this device. You can leave the app: '
                    'LearnMath tells you when the lesson is finished.'
                : lesson.isWaitingForBatch
                    ? 'The notes are being written in the batch queue, at '
                        'about half the price; they usually arrive within '
                        'minutes, at most a day. Then the lecture script is '
                        'written the same way and the lecture is recorded '
                        'on this device. You can leave the app: LearnMath '
                        'tells you when the lesson is finished.'
                : lesson.hasNotes
                    ? 'The notes are ready to read while the lecture is '
                        'recorded. You can leave the app; a notification '
                        'shows the progress.'
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
              if (canWriteOutside(lesson))
                OutlinedButton(
                  onPressed: () =>
                      context.push('/import-lesson?lesson=${lesson.id}'),
                  child: const Text('Write it with your own AI'),
                ),
            ],
          ),
          // A retry can go to another model.
          if (!lesson.hasNotes && !lesson.isBookChapter)
            _LessonModelButton(lesson: lesson),
        ],
      );
    } else if (lesson.isBookChapter) {
      // Not read in yet, or read in but without a recording.
      final muted = theme.textTheme.bodyMedium!
          .copyWith(color: theme.colorScheme.onSurfaceVariant);
      content = Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(lesson.brief, style: theme.textTheme.titleMedium),
          const SizedBox(height: 8),
          Text(
            lesson.hasNotes
                ? 'This chapter has been read in. You can read it under Notes '
                    'and ask about it under Chat, or record an audio lecture '
                    'that explains it.'
                : 'The original pages are under Book. Reading the chapter in '
                    'sends its pages to the AI service and lets you read it '
                    'as text, ask questions about it and record a lecture.',
            style: muted,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 20),
          if (!lesson.hasNotes) ...[
            FilledButton.icon(
              onPressed: () =>
                  generateLesson(context, ref, lesson.id, audio: false),
              icon: const Icon(Icons.document_scanner_outlined),
              label: const Text('Read this chapter in'),
            ),
            const SizedBox(height: 8),
          ],
          FilledButton.tonalIcon(
            onPressed: () =>
                generateLesson(context, ref, lesson.id, audio: true),
            icon: const Icon(Icons.headphones_outlined),
            label: Text(lesson.hasNotes
                ? 'Record an audio lecture'
                : 'Read in and record a lecture'),
          ),
          const SizedBox(height: 8),
          Text('A long chapter makes a long lecture and takes a while to record.',
              style: muted, textAlign: TextAlign.center),
        ],
      );
    } else if (lesson.hasNotes && lesson.segments.isNotEmpty) {
      // Written and scripted, but with no recording on this device: one
      // brought over in a backup without its recordings.
      content = Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            'The notes and the lecture script are here, but the lecture has '
            'not been recorded on this device.',
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: () =>
                generateLesson(context, ref, lesson.id, lesson: lesson),
            icon: const Icon(Icons.headphones_outlined),
            label: const Text('Record the lecture'),
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
            onPressed: () =>
                generateLesson(context, ref, lesson.id, lesson: lesson),
            icon: const Icon(Icons.auto_awesome),
            label: const Text('Generate lesson'),
          ),
          _LessonModelButton(lesson: lesson),
          if (canWriteOutside(lesson)) ...[
            const SizedBox(height: 8),
            OutlinedButton(
              onPressed: () =>
                  context.push('/import-lesson?lesson=${lesson.id}'),
              child: const Text('Write it with your own AI'),
            ),
          ],
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

/// Names the model a lesson that is not written yet will be written with,
/// and lets the student pick another.
class _LessonModelButton extends ConsumerWidget {
  const _LessonModelButton({required this.lesson});
  final Lesson lesson;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(settingsProvider);
    if (!settings.hasApiKey) return const SizedBox.shrink();
    return ModelButton(
      title: 'Model for this lesson',
      allowBatch: true,
      alignment: Alignment.center,
      value: lesson.model ?? settings.lessonChoice,
      onChanged: (c) => ref
          .read(repositoryProvider)
          .updateLesson(lesson.id, (l) => l.copyWith(model: c)),
    );
  }
}

class _NotesPane extends ConsumerWidget {
  const _NotesPane({required this.lessonId, required this.onAsk});
  final String lessonId;
  final void Function(String quote) onAsk;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Select only what is shown so position saves don't re-render the notes.
    final (markdown, checks, report, idle, review, writtenBy) = ref.watch(
        lessonProvider(lessonId).select((a) => (
              a.value?.notesMarkdown,
              a.value?.checks,
              a.value?.checkReport,
              a.value?.stage == LessonStage.ready,
              a.value?.review,
              a.value?.writtenBy,
            )));
    if (markdown == null || markdown.isEmpty) {
      return const _Placeholder('The text appears here once it is ready.');
    }
    final busy =
        ref.watch(jobProgressProvider.select((m) => m[lessonId] != null));
    final canCheck = ref.watch(checkRunnerFactoryProvider) != null;
    final exerciseCount = parseExercises(markdown).length;
    return Column(
      children: [
        CheckBanner(
          checks: checks ?? const [],
          report: report,
          onCheckNow: canCheck && idle && !busy
              ? () => ref.read(generationProvider).recheck(lessonId)
              : null,
        ),
        ReviewBanner(review: review),
        if (writtenBy != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                'Written by $writtenBy',
                style: Theme.of(context).textTheme.labelMedium?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant),
              ),
            ),
          ),
        Expanded(
          child: Stack(
            children: [
              Positioned.fill(
                child: NotesView(
                  markdown: markdown,
                  onAskAbout: onAsk,
                  // Room for the button below the last line of the notes.
                  padding: exerciseCount > 0
                      ? const EdgeInsets.fromLTRB(16, 12, 16, 96)
                      : null,
                ),
              ),
              if (exerciseCount > 0)
                Positioned(
                  right: 16,
                  bottom: 16,
                  child: FloatingActionButton.extended(
                    heroTag: 'exercises-$lessonId',
                    onPressed: () => showExercisesSheet(context, lessonId),
                    icon: const Icon(Icons.edit_note),
                    label: Text('Exercises ($exerciseCount)'),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

/// The original pages of a book chapter.
class _BookPane extends ConsumerWidget {
  const _BookPane({required this.lesson});
  final Lesson lesson;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final path = ref.watch(
        courseProvider(lesson.courseId ?? '').select((a) => a.value?.bookPath));
    if (path == null) {
      return const _Placeholder('The book file is not available.');
    }
    return NotesPdfView(
        filePath: path, initialPage: lesson.sourceStartPage ?? 1);
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
    if (filesAreBlobs) {
      return const _Placeholder(
          'The PDF of the notes is not available in the browser yet. '
          'The Notes tab has the same content.');
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
