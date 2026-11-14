import 'dart:async';
import 'dart:io';

import 'package:uuid/uuid.dart';

import '../ai/lesson_generator.dart';
import '../ai/lesson_import.dart';
import '../ai/narration_parts.dart';
import '../ai/openrouter_client.dart';
import '../ai/prompts.dart';
import '../books/mathpix_client.dart';
import '../books/transcriber.dart';
import '../checks/math_check.dart';
import '../checks/proof_review.dart';
import '../core/models.dart';
import '../core/storage.dart';
import '../notify/notifications.dart';
import '../tts/engine_factory.dart';
import '../tts/lecture_audio_builder.dart';
import '../tts/on_device_tts.dart';
import '../tts/tts_engine.dart';
import '../tts/voice_install.dart';

/// Live progress of a lesson being generated (not persisted).
class JobProgress {
  const JobProgress(this.label, [this.fraction]);

  /// Short human-readable status, e.g. "Recording lecture 12/140".
  final String label;

  /// 0..1, or null when indeterminate.
  final double? fraction;
}

/// Orchestrates lesson creation: notes -> SymPy checks -> narration script ->
/// audio. For a chapter of an imported book the "notes" are a transcription
/// of its pages, and recording the lecture is a separate, optional step.
///
/// Jobs run one at a time (on-device TTS is CPU-bound and model calls cost
/// money), and every stage persists its result, so a failed or interrupted
/// lesson resumes from the last finished stage instead of starting over.
///
/// With a batch model the notes and the script are submitted to the Batch
/// API instead of being awaited. The job then leaves the queue; once the
/// queue is empty the requests of all such jobs go out together, one batch
/// per model, so a whole course is one submission per step. The batch id is
/// saved on each lesson; [pollBatches] re-queues the lessons once the answer
/// is there, and each job picks up where it stopped.
///
/// With proof review on, a second model referees the notes after the SymPy
/// checks; the lesson model judges its findings, rewrites the notes once if
/// any are real, and the rewrite is refereed again.
class GenerationService {
  GenerationService({
    required this.repo,
    required this.paths,
    required this.readSettings,
    required this.voices,
    required this.onProgress,
    this.notifications = const NoNotifications(),
    this.batchBackground = const NoBatchBackground(),
    this.keepAlive = const NoKeepAlive(),
    this.createCheckRunner,
    OpenRouterClient Function(String apiKey)? createClient,
    this.createEngine,
    this.autoPoll = true,
  }) : _createClient =
            createClient ?? ((apiKey) => OpenRouterClient(apiKey: apiKey));

  final LibraryRepository repo;
  final AppPaths paths;
  final AppSettings Function() readSettings;
  final VoiceModelManager voices;

  /// Called with null when a job ends.
  final void Function(String lessonId, JobProgress? progress) onProgress;
  final AppNotifications notifications;
  final BatchBackground batchBackground;
  final KeepAlive keepAlive;

  /// Makes the SymPy runner, or null where none is available (then lessons
  /// keep their checks but they are not run).
  final MathCheckRunner Function()? createCheckRunner;
  final OpenRouterClient Function(String apiKey) _createClient;

  /// Replaces the speech engine in tests.
  final TtsEngine Function(AppSettings settings)? createEngine;

  /// Whether waiting batches are polled on a timer. Tests call
  /// [pollBatches] themselves.
  final bool autoPoll;

  static const _uuid = Uuid();
  static const _waitingLabel = 'Waiting for the batch answer…';
  final _queue = <String>[];
  final _cancelled = <String>{};

  /// Explicit per-job choice of whether to go on to record audio.
  final _audioWanted = <String, bool>{};

  /// Lessons whose checks are re-run on request, without rewriting notes.
  final _checksOnly = <String>{};
  bool _running = false;
  MathCheckRunner? _checkRunner;

  /// Batch requests of jobs that have left the queue, not yet submitted.
  final _outbox = <_Outgoing>[];

  /// OpenRouter's limits on a batch are not published; stay well inside.
  static const _maxRequestsPerBatch = 100;

  /// Finished batches fetched by [pollBatches], kept for the job that
  /// collects them.
  final _fetched = <String, BatchInfo>{};
  Timer? _pollTimer;
  bool _polling = false;
  String _indexed = '';
  Completer<void>? _idle;

  bool isQueued(String lessonId) => _queue.contains(lessonId);

  /// Completes when the queue is empty (lessons waiting for a batch do not
  /// count).
  Future<void> get idle => _running ? (_idle ??= Completer()).future : Future.value();

  /// Lessons left mid-generation by a previous app run can be resumed, so
  /// mark them failed-but-resumable instead of spinning forever. Lessons that
  /// were waiting for a batch simply go on waiting.
  Future<void> recoverInterrupted() async {
    for (final l in await repo.getAllLessons()) {
      if (l.isWaitingForBatch) {
        onProgress(l.id, const JobProgress(_waitingLabel));
      } else if (l.stage.isWorking) {
        await repo.updateLesson(
          l.id,
          (x) => x.copyWith(
            stage: LessonStage.failed,
            error: 'Generation was interrupted. Tap retry to continue.',
          ),
        );
      }
    }
    await _syncWaiting();
    if (autoPoll) unawaited(pollBatches());
  }

  /// Creates a standalone lesson from a free-form request and starts
  /// generating it. Returns the lesson id.
  Future<String> createLesson(String request) async {
    final text = request.trim();
    final lesson = Lesson(
      id: _uuid.v4(),
      title: _provisionalTitle(text),
      brief: text,
      createdAt: DateTime.now(),
    );
    await repo.saveLesson(lesson);
    enqueue(lesson.id);
    return lesson.id;
  }

  /// Stores a lesson that was written outside the app and starts checking
  /// and recording it. With its script it needs no model request; without
  /// one the script is written here like that of any other lesson.
  ///
  /// With [into], the imported text becomes the content of that existing
  /// lesson (one planned in a course outline), which keeps its title and
  /// place in the course.
  Future<String> importLesson(ImportedLesson imported, {String? into}) async {
    if (into != null) {
      final updated = await repo.updateLesson(
        into,
        (l) => l.copyWith(
          stage: LessonStage.pending,
          notesMarkdown: imported.notes,
          checks: imported.checks,
          segments: imported.segments,
          clearCheckReport: true,
          clearAudio: true,
          clearPdf: true,
          clearError: true,
          clearBatch: true,
        ),
      );
      if (updated == null) throw StateError('This lesson no longer exists.');
      enqueue(into);
      return into;
    }
    final lesson = Lesson(
      id: _uuid.v4(),
      title: imported.title,
      brief: imported.title,
      createdAt: DateTime.now(),
      notesMarkdown: imported.notes,
      checks: imported.checks,
      segments: imported.segments,
    );
    await repo.saveLesson(lesson);
    enqueue(lesson.id);
    return lesson.id;
  }

  /// Whether queueing [lesson] sends nothing to a model: it has its notes
  /// and its script (an imported lesson, or one being recorded again), so
  /// what is left happens on this device.
  static bool runsOnDevice(Lesson lesson, AppSettings settings) =>
      lesson.hasNotes &&
      lesson.segments.isNotEmpty &&
      (lesson.review?.isDone ?? true) &&
      (lesson.audioPath != null ||
          settings.ttsBackend == TtsBackend.onDevice);

  /// Plans a course and stores it with all its lessons pending.
  /// Returns the course id. Lessons are generated on demand.
  Future<String> createCourse(String topic, {int? lessonCount}) async {
    final settings = _requireKey();
    final client = _createClient(settings.apiKey);
    try {
      // The user waits for the outline, so it is never batched.
      final outline = await LessonGenerator(client, model: settings.lessonModel)
          .generateOutline(topic.trim(), lessonCount: lessonCount);
      return await importCourse(outline);
    } finally {
      client.close();
    }
  }

  /// Stores a planned course with all its lessons pending: one the lesson
  /// model planned, or one planned outside the app. Returns the course id.
  Future<String> importCourse(CourseOutline outline) async {
    final course = Course(
      id: _uuid.v4(),
      title: outline.title,
      description: outline.description,
      createdAt: DateTime.now(),
    );
    await repo.saveCourse(course);
    for (var i = 0; i < outline.lessons.length; i++) {
      await repo.saveLesson(Lesson(
        id: _uuid.v4(),
        courseId: course.id,
        order: i,
        title: outline.lessons[i].title,
        brief: outline.lessons[i].brief,
        createdAt: DateTime.now(),
      ));
    }
    return course.id;
  }

  /// Queues a lesson for (continued) generation.
  ///
  /// [audio] says whether to go on to record the lecture. By default AI
  /// lessons are recorded, while a book chapter is first only transcribed
  /// (for reading and chat) and recorded when queued again.
  void enqueue(String lessonId, {bool? audio}) {
    if (audio != null) _audioWanted[lessonId] = audio;
    if (_queue.contains(lessonId)) return;
    _cancelled.remove(lessonId);
    _queue.add(lessonId);
    onProgress(lessonId, const JobProgress('Waiting…'));
    unawaited(notifications.requestPermission());
    unawaited(_refreshKeepAlive());
    unawaited(_drain());
  }

  void cancel(String lessonId) {
    _cancelled.add(lessonId);
    if (_queue.contains(lessonId)) {
      if (_queue.first != lessonId) {
        _queue.remove(lessonId);
        onProgress(lessonId, null);
      }
      return;
    }
    // Not running: it can only be waiting for a batch. OpenRouter cannot
    // cancel a submitted batch, so the answer is simply never collected.
    unawaited(_abandonBatch(lessonId));
  }

  Future<void> _abandonBatch(String lessonId) async {
    _cancelled.remove(lessonId);
    final before = _outbox.length;
    _outbox.removeWhere((o) => o.lessonId == lessonId);
    final unsent = _outbox.length != before;
    final batchId = (await repo.getLesson(lessonId))?.batch?.id;
    await repo.updateLesson(
      lessonId,
      (l) => l.isWaitingForBatch || unsent
          ? l.copyWith(
              stage: LessonStage.failed, error: 'Cancelled.', clearBatch: true)
          : l,
    );
    onProgress(lessonId, null);
    await _deleteIfUnused(batchId);
    await _syncWaiting();
  }

  /// Throws away the recording and re-synthesizes it with the current voice
  /// and pause settings; notes and script are kept.
  Future<void> rerecord(String lessonId) async {
    await repo.updateLesson(
      lessonId,
      (l) => l.copyWith(stage: LessonStage.pending, clearAudio: true),
    );
    enqueue(lessonId);
  }

  /// Runs the lesson's SymPy checks again (for example after they could not
  /// be run for lack of a connection). The notes are left as they are.
  Future<void> recheck(String lessonId) async {
    await repo.updateLesson(
        lessonId, (l) => l.copyWith(clearCheckReport: true));
    _checksOnly.add(lessonId);
    enqueue(lessonId);
  }

  /// How long after a lecture was listened to its review is made.
  static const reviewDelay = Duration(days: 3);

  /// Creates and queues the short review lecture of every lesson that was
  /// listened to the end at least [reviewDelay] ago. Returns how many.
  Future<int> makeDueRecaps({DateTime? now}) async {
    final settings = readSettings();
    if (!settings.spacedReview || !settings.hasApiKey) return 0;
    final time = now ?? DateTime.now();
    var made = 0;
    for (final l in await repo.getAllLessons()) {
      final done = l.completedAt;
      if (done == null ||
          l.recapMade ||
          l.isRecap ||
          !l.hasNotes ||
          time.difference(done) < reviewDelay) {
        continue;
      }
      final title = 'Review: ${l.title}';
      final recap = Lesson(
        id: _uuid.v4(),
        title: title,
        brief: 'A short review of "${l.title}".',
        createdAt: time,
        recapOf: l.id,
        // What the student reads along with the review: the summary.
        notesMarkdown: '# $title\n\n${summaryOf(l.notesMarkdown!)}',
      );
      await repo.saveLesson(recap);
      await repo.updateLesson(l.id, (x) => x.copyWith(recapMade: true));
      enqueue(recap.id);
      made++;
    }
    return made;
  }

  /// The body of the notes' Summary section, or the whole notes without
  /// their title when there is none.
  static String summaryOf(String notes) {
    final m = RegExp(r'^##\s+Summary\s*$\n([\s\S]*?)(?=^##\s|(?![\s\S]))',
            multiLine: true)
        .firstMatch(notes);
    final body = m?.group(1)?.trim();
    if (body != null && body.isNotEmpty) return body;
    return notes.replaceFirst(RegExp(r'^#\s+.*\n'), '').trim();
  }

  /// Has a second model referee the proofs of a finished lesson. What it
  /// finds is reported with the notes; the notes themselves, and the lecture
  /// recorded from them, are not changed.
  Future<void> verify(String lessonId) async {
    await repo.updateLesson(
      lessonId,
      (l) => l.copyWith(
        review: const ProofReview(
            state: ProofReviewState.toVerify, reportOnly: true),
      ),
    );
    enqueue(lessonId);
  }

  // ------------------------------------------------------------- batches

  /// Asks OpenRouter about every batch a lesson is waiting for and re-queues
  /// the lessons whose batch has finished (or failed: the job reports why).
  Future<void> pollBatches() async {
    if (_polling) return;
    _polling = true;
    _pollTimer?.cancel();
    _pollTimer = null;
    try {
      final waiting = await _waitingLessons();
      final settings = readSettings();
      if (waiting.isNotEmpty && settings.hasApiKey) {
        final client = _createClient(settings.apiKey);
        try {
          final byBatch = <String, List<Lesson>>{};
          for (final l in waiting) {
            if (_queue.contains(l.id)) continue;
            byBatch.putIfAbsent(l.batch!.id, () => []).add(l);
          }
          for (final entry in byBatch.entries) {
            final BatchInfo info;
            try {
              info = await client.getBatch(entry.key);
            } catch (_) {
              continue; // offline or a hiccup: ask again next time
            }
            if (!info.isTerminal) continue;
            _fetched[info.id] = info;
            for (final l in entry.value) {
              enqueue(l.id);
            }
          }
        } finally {
          client.close();
        }
      }
    } finally {
      _polling = false;
      await _schedulePoll();
    }
  }

  Future<List<Lesson>> _waitingLessons() async => [
        for (final l in await repo.getAllLessons())
          if (l.isWaitingForBatch) l,
      ];

  /// Most batches finish within minutes, so ask often at first and back off
  /// for the ones that take hours.
  Future<void> _schedulePoll() async {
    if (!autoPoll || _pollTimer != null) return;
    final waiting = await _waitingLessons();
    if (waiting.isEmpty) return;
    final now = DateTime.now();
    var youngest = const Duration(days: 1);
    for (final l in waiting) {
      final age = now.difference(l.batch!.submittedAt);
      if (age < youngest) youngest = age;
    }
    final delay = youngest < const Duration(minutes: 3)
        ? const Duration(seconds: 15)
        : youngest < const Duration(minutes: 20)
            ? const Duration(seconds: 45)
            : const Duration(minutes: 3);
    _pollTimer ??= Timer(delay, () {
      _pollTimer = null;
      unawaited(pollBatches());
    });
  }

  /// Tells the background check which batches are being waited for.
  Future<void> _syncWaiting() async {
    final waiting = [
      for (final l in await _waitingLessons())
        WaitingBatch(
            batchId: l.batch!.id, lessonId: l.id, lessonTitle: l.title),
    ];
    final key = waiting.map((w) => '${w.batchId}/${w.lessonId}').join(',');
    await _refreshKeepAlive(waiting.length);
    if (key == _indexed) return;
    _indexed = key;
    await batchBackground.update(waiting);
  }

  /// Holds the app alive while lessons are being worked on or waited for.
  Future<void> _refreshKeepAlive([int? waiting]) async {
    String count(int n, String what) => '$n $what${n == 1 ? '' : 's'}';
    final working = _queue.length + _outbox.length;
    if (working > 0) {
      await keepAlive.hold('Working on ${count(working, 'lesson')}');
      return;
    }
    final n = waiting ?? (await _waitingLessons()).length;
    if (n > 0) {
      await keepAlive.hold('Waiting for ${count(n, 'batch answer')}');
    } else {
      await keepAlive.release();
    }
  }

  /// Submits what the finished jobs left in [_outbox]: one batch per model
  /// and reasoning effort, so a course generated at once is one submission
  /// per step instead of one per lesson.
  Future<void> _flushOutbox() async {
    final groups = <String, List<_Outgoing>>{};
    for (final o in _outbox) {
      groups.putIfAbsent(o.groupKey, () => []).add(o);
    }
    _outbox.clear();
    final client = _createClient(readSettings().apiKey);
    try {
      for (final group in groups.values) {
        // Whole lessons per batch, never a lesson split across two.
        final chunks = <List<_Outgoing>>[[]];
        var size = 0;
        for (final o in group) {
          if (size > 0 && size + o.prompts.length > _maxRequestsPerBatch) {
            chunks.add([]);
            size = 0;
          }
          chunks.last.add(o);
          size += o.prompts.length;
        }
        for (final chunk in chunks) {
          await _submit(client, chunk);
        }
      }
    } finally {
      client.close();
    }
    await _syncWaiting();
  }

  Future<void> _submit(OpenRouterClient client, List<_Outgoing> chunk) async {
    final first = chunk.first;
    try {
      final batch = await client.createBatch(
        model: first.model,
        temperature: first.temperature,
        reasoningEffort: first.effort,
        requests: [
          for (final o in chunk)
            for (var i = 0; i < o.prompts.length; i++)
              BatchRequest(
                customId: PendingBatch.customId(o.lessonId, i),
                messages: o.prompts[i],
              ),
        ],
      );
      final now = DateTime.now();
      for (final o in chunk) {
        await repo.updateLesson(
          o.lessonId,
          (l) => l.copyWith(
            batch: PendingBatch(
              id: batch.id,
              step: o.step,
              submittedAt: now,
              parts: o.prompts.length,
            ),
          ),
        );
      }
    } catch (e) {
      final reason = _describe(e);
      for (final o in chunk) {
        final failed = await repo.updateLesson(
          o.lessonId,
          (l) => l.copyWith(stage: LessonStage.failed, error: reason),
        );
        onProgress(o.lessonId, null);
        _audioWanted.remove(o.lessonId);
        if (failed != null) {
          await notifications.lessonFailed(o.lessonId, failed.title, reason);
        }
      }
    }
  }

  // --------------------------------------------------------------- queue

  Future<void> _drain() async {
    if (_running) return;
    _running = true;
    try {
      while (_queue.isNotEmpty || _outbox.isNotEmpty) {
        if (_queue.isEmpty) {
          await _flushOutbox();
          continue;
        }
        final id = _queue.first;
        var suspended = false;
        final before = await repo.getLesson(id);
        // Re-running checks on a finished lesson is not news, nor is a
        // review the user is watching (a batched one arrives much later).
        final quiet = _checksOnly.contains(id) ||
            ((before?.review?.reportOnly ?? false) &&
                !before!.isWaitingForBatch);
        try {
          await _run(id);
          if (!quiet) await _announce(id);
        } on _WaitingForBatch {
          suspended = true;
        } on GenerationCancelled {
          await repo.updateLesson(
            id,
            (l) => l.copyWith(
                stage: LessonStage.failed, error: 'Cancelled.', clearBatch: true),
          );
        } catch (e) {
          final reason = _describe(e);
          final failed = await repo.updateLesson(
            id,
            (l) => l.copyWith(
                stage: LessonStage.failed, error: reason, clearBatch: true),
          );
          if (failed != null) {
            await notifications.lessonFailed(id, failed.title, reason);
          }
        } finally {
          // A job that ended without collecting (failed or cancelled) may
          // have been the last one holding its batch.
          if (!suspended) unawaited(_deleteIfUnused(before?.batch?.id));
          _queue.remove(id);
          _collected.remove(id);
          _cancelled.remove(id);
          _checksOnly.remove(id);
          if (!suspended) _audioWanted.remove(id);
          await notifications.clearProgress(id);
          onProgress(id, suspended ? const JobProgress(_waitingLabel) : null);
        }
        await _syncWaiting();
      }
    } finally {
      _running = false;
      final runner = _checkRunner;
      _checkRunner = null;
      await runner?.dispose();
      _idle?.complete();
      _idle = null;
      await _schedulePoll();
    }
  }

  Future<void> _announce(String id) async {
    final lesson = await repo.getLesson(id);
    if (lesson == null || lesson.stage != LessonStage.ready) return;
    await notifications.lessonReady(id, lesson.title,
        hasAudio: lesson.hasAudio);
  }

  Future<void> _run(String id) async {
    var lesson = await repo.getLesson(id);
    if (lesson == null) return;
    final settings = readSettings();
    final wantAudio =
        _audioWanted[id] ?? (!lesson.isBookChapter || lesson.hasNotes);
    void check() {
      if (_cancelled.contains(id)) throw const GenerationCancelled();
    }

    Future<Lesson> update(Lesson Function(Lesson) change) async {
      final updated = await repo.updateLesson(id, change);
      if (updated == null) throw const GenerationCancelled(); // deleted
      return updated;
    }

    if (_checksOnly.contains(id)) {
      final stage = lesson.stage;
      await _runChecks(lesson, update, check);
      await update((l) => l.copyWith(stage: stage));
      return;
    }

    // Mathpix-only transcription is the one job that needs no OpenRouter key.
    final needsKey = !runsOnDevice(lesson, settings) &&
        (wantAudio ||
            !lesson.isBookChapter ||
            settings.transcriptionBackend != TranscriptionBackend.mathpix);
    if (needsKey && !settings.hasApiKey) throw const MissingApiKey();

    final client = _createClient(settings.apiKey);
    TtsEngine? engine;
    try {
      final generator = LessonGenerator(client,
          model: settings.lessonModel, effort: settings.lessonEffort);
      final course = await courseContext(lesson);

      // Sends the requests of one step and returns their answers in order.
      // In batch mode the first call submits them and ends the job; the call
      // made when the lesson is queued again collects the answers.
      Future<List<String>> ask(
        BatchStep step,
        List<List<ChatMessage>> prompts, {
        required double temperature,
        required String Function(int part) label,
        String? model,
        String? effort,
      }) async {
        final pending = lesson!.batch;
        if (pending != null && pending.step == step) {
          onProgress(id, const JobProgress('Collecting the batch answer…'));
          final answers = await _collect(client, lesson, pending);
          _collected[id] = pending.id;
          return answers;
        }
        if (!settings.lessonBatch) {
          final answers = <String>[];
          for (var i = 0; i < prompts.length; i++) {
            final text = label(i);
            final fraction = prompts.length == 1 ? null : i / prompts.length;
            onProgress(id, JobProgress(text, fraction));
            answers.add(await generator.ask(
              prompts[i],
              temperature: temperature,
              model: model,
              effort: effort,
              onProgress: (chars) => onProgress(
                  id, JobProgress('$text ${_kChars(chars)}', fraction)),
            ));
            check();
          }
          return answers;
        }
        // Sent together with the requests of the other queued lessons
        // once the queue is empty.
        _outbox.add(_Outgoing(
          lessonId: id,
          step: step,
          prompts: prompts,
          model: model ?? settings.lessonModel,
          effort: model == null ? settings.lessonEffort : effort,
          temperature: temperature,
        ));
        throw const _WaitingForBatch();
      }

      final withChecks = settings.mathChecks;

      if (!lesson.hasNotes && lesson.isBookChapter) {
        final book = await repo.getCourse(lesson.courseId ?? '');
        final bookPath = book?.bookPath;
        if (bookPath == null || !await File(bookPath).exists()) {
          throw TranscriptionException('The book file is missing.');
        }
        lesson = await update((l) =>
            l.copyWith(stage: LessonStage.transcribing, clearError: true));
        onProgress(id, const JobProgress('Reading the chapter…'));
        final text = await ChapterTranscriber.transcribe(
          settings: settings,
          pdfPath: bookPath,
          chapter: lesson,
          onProgress: (label, f) => onProgress(id, JobProgress(label, f)),
          isCancelled: () => _cancelled.contains(id),
        );
        check();
        lesson = await update((l) => l.copyWith(notesMarkdown: text));
      } else if (!lesson.hasNotes) {
        lesson = await update((l) =>
            l.copyWith(stage: LessonStage.generatingNotes, clearError: true));
        final answers = await ask(
          BatchStep.notes,
          [
            LessonGenerator.notesMessages(
              title: lesson.title,
              brief: lesson.brief,
              course: course,
              withChecks: withChecks,
            ),
          ],
          temperature: LessonGenerator.notesTemperature,
          label: (_) => 'Writing lecture notes…',
        );
        final draft = LessonGenerator.parseNotes(answers.single);
        final heading = _firstHeading(draft.notes);
        lesson = await update((l) => l.copyWith(
              notesMarkdown: draft.notes,
              checks: draft.checks,
              clearCheckReport: true,
              clearBatch: true,
              // Standalone lessons start with the raw request as title.
              title: l.courseId == null && heading != null ? heading : null,
              clearPdf: true,
            ));
        _forget(id);
      }

      // A lesson that came with its script (an imported one) is checked
      // too, but its notes are not rewritten: the script was made from them.
      final scripted = lesson.segments.isNotEmpty;
      if (withChecks &&
          lesson.checks.isNotEmpty &&
          (!scripted || lesson.checkReport == null)) {
        lesson = await _runChecks(lesson, update, check);
        final report = lesson.checkReport;
        if (report != null &&
            report.failed.isNotEmpty &&
            !report.repaired &&
            !scripted) {
          // The notes and SymPy disagree: one targeted rewrite, then the
          // checks of the rewrite decide.
          lesson = await update((l) =>
              l.copyWith(stage: LessonStage.generatingNotes, clearError: true));
          final answers = await ask(
            BatchStep.repair,
            [
              LessonGenerator.repairMessages(
                title: lesson.title,
                notesMarkdown: lesson.notesMarkdown!,
                checks: lesson.checks,
                outcomes: report.outcomes,
              ),
            ],
            temperature: LessonGenerator.notesTemperature,
            label: (_) => 'Correcting the notes…',
          );
          NotesDraft? draft;
          try {
            draft = LessonGenerator.parseNotes(answers.single);
          } on FormatException {
            // Keep the original notes; the failed checks stay on display.
          }
          final fixed = draft;
          lesson = await update((l) => fixed == null
              ? l.copyWith(
                  clearBatch: true,
                  checkReport:
                      CheckReport(outcomes: report.outcomes, repaired: true),
                )
              : l.copyWith(
                  notesMarkdown: fixed.notes,
                  checks: fixed.checks,
                  // Empty outcomes: the new checks have not been run yet.
                  checkReport:
                      const CheckReport(outcomes: [], repaired: true),
                  clearBatch: true,
                  clearPdf: true,
                ));
          _forget(id);
          lesson = await _runChecks(lesson, update, check);
        }
      }

      var review = lesson.review ??
          (settings.verifyProofs &&
                  !lesson.isBookChapter &&
                  !lesson.isRecap &&
                  lesson.segments.isEmpty
              ? const ProofReview(state: ProofReviewState.toVerify)
              : null);
      while (review != null && !review.isDone) {
        final current = review;
        lesson = await update((l) =>
            l.copyWith(stage: LessonStage.verifyingProofs, clearError: true));
        switch (current.state) {
          case ProofReviewState.toVerify:
            final answers = await ask(
              BatchStep.verify,
              [
                LessonGenerator.verifyMessages(
                    title: lesson.title, notesMarkdown: lesson.notesMarkdown!),
              ],
              temperature: LessonGenerator.reviewTemperature,
              model: settings.verifierModel,
              // The reviewer's default effort misses far more than high does.
              effort: 'high',
              label: (_) => 'A second model is reviewing the proofs…',
            );
            final issues = parseIssues(answers.single);
            review = current.copyWith(
              state: issues.isEmpty
                  ? ProofReviewState.done
                  : ProofReviewState.raw,
              issues: issues,
            );
          case ProofReviewState.raw:
            final answers = await ask(
              BatchStep.judge,
              [
                LessonGenerator.judgeMessages(
                  title: lesson.title,
                  notesMarkdown: lesson.notesMarkdown!,
                  issues: current.issues,
                ),
              ],
              temperature: LessonGenerator.reviewTemperature,
              model: settings.lessonModel,
              effort: settings.lessonEffort == null ? null : 'medium',
              label: (_) => 'Weighing the reviewer\'s findings…',
            );
            final real = keepRealIssues(current.issues, answers.single);
            review = current.copyWith(
              state: real.isEmpty
                  ? ProofReviewState.done
                  : ProofReviewState.confirmed,
              issues: real,
              dismissed:
                  current.dismissed + current.issues.length - real.length,
            );
          case ProofReviewState.confirmed:
            if (current.rewritten || current.reportOnly) {
              // One rewrite only; what is still wrong is shown to the reader.
              review = current.copyWith(state: ProofReviewState.done);
              break;
            }
            final answers = await ask(
              BatchStep.proofRepair,
              [
                LessonGenerator.proofRepairMessages(
                  title: lesson.title,
                  notesMarkdown: lesson.notesMarkdown!,
                  issues: current.issues,
                  withChecks: withChecks,
                ),
              ],
              temperature: LessonGenerator.notesTemperature,
              label: (_) => 'Correcting the notes…',
            );
            NotesDraft? draft;
            try {
              draft = LessonGenerator.parseNotes(answers.single);
            } on FormatException {
              // Keep the notes; the confirmed issues stay on display.
            }
            final fixed = draft;
            if (fixed == null) {
              review = current.copyWith(state: ProofReviewState.done);
              break;
            }
            lesson = await update((l) => l.copyWith(
                  notesMarkdown: fixed.notes,
                  checks: fixed.checks,
                  // Checked again below, but not rewritten again for SymPy.
                  checkReport: const CheckReport(outcomes: [], repaired: true),
                  clearBatch: true,
                  clearPdf: true,
                ));
            _forget(id);
            if (withChecks) lesson = await _runChecks(lesson, update, check);
            review = ProofReview(
              state: ProofReviewState.toVerify,
              round: 1,
              dismissed: current.dismissed,
            );
          case ProofReviewState.done:
            break;
        }
        final next = review;
        lesson =
            await update((l) => l.copyWith(review: next, clearBatch: true));
        _forget(id);
      }

      if (!wantAudio) {
        await update(
            (l) => l.copyWith(stage: LessonStage.ready, clearError: true));
        return;
      }

      if (lesson!.segments.isEmpty) {
        lesson = await update((l) => l.copyWith(
            stage: LessonStage.generatingNarration, clearError: true));
        final fromBook = lesson.isBookChapter;
        // A book chapter is far longer than one model answer can narrate, so
        // it is scripted in consecutive parts.
        final parts = fromBook
            ? splitForNarration(stripPageMarkers(lesson.notesMarkdown!))
            : [SourcePart(lesson.notesMarkdown!, const [])];
        final prompts = <List<ChatMessage>>[];
        final covered = <String>[];
        if (lesson.isRecap) {
          // Written from the full notes of the lesson it reviews, when that
          // lesson still exists.
          final original = await repo.getLesson(lesson.recapOf!);
          prompts.add(LessonGenerator.recapMessages(
            title: original?.title ?? lesson.title,
            notesMarkdown: original?.notesMarkdown ?? lesson.notesMarkdown!,
          ));
        }
        for (var i = 0; i < parts.length && !lesson.isRecap; i++) {
          prompts.add(LessonGenerator.narrationMessages(
            title: lesson.title,
            notesMarkdown: parts[i].text,
            course: course,
            fromBook: fromBook,
            recall: settings.recallQuestions,
            part: NarrationPart(
              index: i,
              count: parts.length,
              previousSections: List.of(covered),
            ),
          ));
          covered.addAll(parts[i].sections);
        }
        final answers = await ask(
          BatchStep.narration,
          prompts,
          temperature: LessonGenerator.narrationTemperature,
          label: (i) => parts.length == 1
              ? 'Preparing the lecture script…'
              : 'Preparing the lecture script… part ${i + 1} of ${parts.length}',
        );
        final segments = [
          for (final a in answers) ...LessonGenerator.parseScript(a),
        ];
        lesson = await update(
            (l) => l.copyWith(segments: segments, clearBatch: true));
        _forget(id);
      }

      if (lesson.audioPath == null) {
        lesson = await update((l) => l.copyWith(
            stage: LessonStage.synthesizingAudio, clearError: true));
        final custom = createEngine;
        if (custom != null) {
          engine = custom(settings);
        } else if (settings.ttsBackend == TtsBackend.onDevice) {
          final voice = VoiceModel.byId(settings.voiceModel);
          await installVoiceModel(
            voices,
            voice,
            notifications,
            onProgress: (f) => onProgress(
              id,
              JobProgress(
                  f == null
                      ? 'Unpacking voice model…'
                      : 'Downloading voice model (one time)…',
                  f),
            ),
          );
          engine = OnDeviceTtsEngine(
              manager: voices, model: voice, speakerId: settings.voiceSpeaker);
        } else {
          engine = OpenRouterTtsEngine(
            client: client,
            model: settings.openRouterTtsModel,
            voice: settings.openRouterTtsVoice,
          );
        }
        onProgress(id, const JobProgress('Recording lecture…', 0));
        final title = lesson.title;
        final outPath = paths.lessonAudio(id);
        final audio = await LectureAudioBuilder.build(
          segments: lesson.segments,
          engine: engine,
          outPath: outPath,
          pauseScale: settings.pauseScale,
          isCancelled: () => _cancelled.contains(id),
          onProgress: (done, total) {
            onProgress(id,
                JobProgress('Recording lecture $done/$total', done / total));
            notifications.progress(
              id,
              title: 'Recording lecture',
              body: '$title · $done of $total',
              fraction: done / total,
            );
          },
        );
        lesson = await update((l) => l.copyWith(
              segments: audio.segments,
              audioPath: outPath,
              audioDurationMs: audio.durationMs,
              voice: voiceLabel(settings),
              lastPositionMs: 0,
            ));
        await repo.clearPositionCheckpoint(id);
      }

      await update(
          (l) => l.copyWith(stage: LessonStage.ready, clearError: true));
    } finally {
      await engine?.dispose();
      client.close();
    }
  }

  /// Fetches the answers of [pending], one per request the lesson has in the
  /// batch. Throws [_WaitingForBatch] while the batch is still running.
  Future<List<String>> _collect(
      OpenRouterClient client, Lesson lesson, PendingBatch pending) async {
    // Kept until the batch is deleted: other lessons may share it.
    var info = _fetched[pending.id];
    if (info == null) {
      try {
        info = await client.getBatch(pending.id);
      } on OpenRouterException {
        // Keep waiting: the batch is paid for, so a network error must not
        // make the lesson start over.
        throw const _WaitingForBatch();
      }
    }
    if (!info.isTerminal) throw const _WaitingForBatch();
    _fetched[pending.id] = info;
    if (!info.isDone) {
      throw BatchFailed(switch (info.status) {
        'expired' => 'The batch was not finished within its time limit.',
        'cancelled' => 'The provider cancelled the batch.',
        _ => info.error ?? 'The batch failed.',
      });
    }
    final answers = <String>[];
    for (var i = 0; i < pending.parts; i++) {
      final result = info.results[PendingBatch.customId(lesson.id, i)];
      final text = result?.text;
      if (text == null) {
        throw BatchFailed(result?.error ?? 'The batch has no answer for this lesson.');
      }
      answers.add(text);
    }
    return answers;
  }

  /// Batch ids whose answers were just collected, by lesson id.
  final _collected = <String, String>{};

  /// Called once the answer collected for [lessonId] has been stored.
  void _forget(String lessonId) {
    final id = _collected.remove(lessonId);
    if (id != null) unawaited(_deleteIfUnused(id));
  }

  /// Deletes a finished batch from OpenRouter, which otherwise keeps the
  /// lesson text for 30 days, once no lesson still has an answer in it.
  /// Best effort. A batch that is still running cannot be deleted.
  Future<void> _deleteIfUnused(String? batchId) async {
    if (batchId == null || !(_fetched[batchId]?.isTerminal ?? false)) return;
    final shared =
        (await _waitingLessons()).any((l) => l.batch!.id == batchId);
    if (shared) return;
    _fetched.remove(batchId);
    // Its own client: the job's client is closed before this completes.
    final client = _createClient(readSettings().apiKey);
    try {
      await client.deleteBatch(batchId);
    } catch (_) {
    } finally {
      client.close();
    }
  }

  Future<Lesson> _runChecks(
    Lesson lesson,
    Future<Lesson> Function(Lesson Function(Lesson)) update,
    void Function() check,
  ) async {
    final previous = lesson.checkReport;
    final upToDate = previous != null &&
        previous.outcomes.length == lesson.checks.length;
    final factory = createCheckRunner;
    if (upToDate || factory == null || lesson.checks.isEmpty) return lesson;

    await update((l) => l.copyWith(stage: LessonStage.checkingMath));
    final total = lesson.checks.length;
    onProgress(lesson.id, JobProgress('Checking the computations…', 0));
    final List<CheckOutcome> outcomes;
    try {
      outcomes = await (_checkRunner ??= factory()).run(
        lesson.checks,
        onProgress: (done, _) => onProgress(
            lesson.id,
            JobProgress(
                'Checking the computations $done/$total', done / total)),
      );
    } on MathCheckException {
      // No checker right now (no connection for its first download, say).
      // The lesson is still usable; the notes screen offers to check again.
      return lesson;
    }
    check();
    return update((l) => l.copyWith(
          checkReport: CheckReport(
              outcomes: outcomes, repaired: previous?.repaired ?? false),
        ));
  }

  AppSettings _requireKey() {
    final s = readSettings();
    if (!s.hasApiKey) {
      throw const MissingApiKey();
    }
    return s;
  }

  /// Where [lesson] sits in its course; null for a standalone lesson.
  Future<CourseContext?> courseContext(Lesson lesson) async {
    final courseId = lesson.courseId;
    if (courseId == null) return null;
    final course = await repo.getCourse(courseId);
    if (course == null) return null;
    final lessons = await repo.getCourseLessons(courseId);
    final index = lessons.indexWhere((l) => l.id == lesson.id);
    return CourseContext(
      courseTitle: course.title,
      courseDescription: course.description,
      lessonTitles: [for (final l in lessons) l.title],
      lessonIndex: index < 0 ? 0 : index,
    );
  }

  static String _kChars(int chars) =>
      chars < 1000 ? '' : '${(chars / 1000).toStringAsFixed(1)}k chars';

  static String _provisionalTitle(String request) {
    final line = request.split('\n').first.trim();
    return line.length <= 60 ? line : '${line.substring(0, 57)}…';
  }

  static String? _firstHeading(String markdown) {
    final m = RegExp(r'^#\s+(.+)$', multiLine: true).firstMatch(markdown);
    final title = m?.group(1)?.replaceAll(RegExp(r'[\$\*_`]'), '').trim();
    if (title == null || title.isEmpty || title.length > 90) return null;
    return title;
  }

  static String _describe(Object e) {
    if (e is MissingApiKey) return e.toString();
    if (e is MathpixException || e is TranscriptionException) {
      return e.toString();
    }
    if (e is SocketException) return 'No network connection.';
    if (e is TimeoutException) return 'The request timed out.';
    if (e is FormatException) {
      return 'The model returned an unusable answer. Try again or pick '
          'another model in Settings.';
    }
    return e.toString();
  }
}

/// The requests of one lesson step, waiting to be submitted in a batch.
class _Outgoing {
  _Outgoing({
    required this.lessonId,
    required this.step,
    required this.prompts,
    required this.model,
    required this.effort,
    required this.temperature,
  });

  final String lessonId;
  final BatchStep step;
  final List<List<ChatMessage>> prompts;
  final String model;
  final String? effort;
  final double temperature;

  /// Requests that can share a batch: same model and same sampling. The
  /// temperature only matters when no reasoning effort replaces it.
  String get groupKey => '$model|${effort ?? 'temperature $temperature'}';
}

/// Ends a job whose model request is now in the batch queue. Not a failure.
class _WaitingForBatch implements Exception {
  const _WaitingForBatch();
}

/// A batch came back without a usable answer.
class BatchFailed implements Exception {
  BatchFailed(this.message);
  final String message;
  @override
  String toString() => message;
}

class MissingApiKey implements Exception {
  const MissingApiKey();
  @override
  String toString() => 'Add your OpenRouter API key in Settings first.';
}
