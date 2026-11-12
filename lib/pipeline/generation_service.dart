import 'dart:async';
import 'dart:io';

import 'package:uuid/uuid.dart';

import '../ai/lesson_generator.dart';
import '../ai/narration_parts.dart';
import '../ai/openrouter_client.dart';
import '../ai/prompts.dart';
import '../books/mathpix_client.dart';
import '../books/transcriber.dart';
import '../core/models.dart';
import '../core/storage.dart';
import '../tts/kokoro_engine.dart';
import '../tts/lecture_audio_builder.dart';
import '../tts/tts_engine.dart';

/// Live progress of a lesson being generated (not persisted).
class JobProgress {
  const JobProgress(this.label, [this.fraction]);

  /// Short human-readable status, e.g. "Recording lecture 12/140".
  final String label;

  /// 0..1, or null when indeterminate.
  final double? fraction;
}

/// Orchestrates lesson creation: notes -> narration script -> audio.
/// For a chapter of an imported book the "notes" are a transcription of its
/// pages, and recording the lecture is a separate, optional step.
///
/// Jobs run one at a time (on-device TTS is CPU-bound and model calls cost
/// money), and every stage persists its result, so a failed or interrupted
/// lesson resumes from the last finished stage instead of starting over.
class GenerationService {
  GenerationService({
    required this.repo,
    required this.paths,
    required this.readSettings,
    required this.kokoro,
    required this.onProgress,
  });

  final LibraryRepository repo;
  final AppPaths paths;
  final AppSettings Function() readSettings;
  final KokoroModelManager kokoro;

  /// Called with null when a job ends.
  final void Function(String lessonId, JobProgress? progress) onProgress;

  static const _uuid = Uuid();
  final _queue = <String>[];
  final _cancelled = <String>{};

  /// Explicit per-job choice of whether to go on to record audio.
  final _audioWanted = <String, bool>{};
  bool _running = false;

  bool isQueued(String lessonId) => _queue.contains(lessonId);

  /// Lessons left mid-generation by a previous app run can be resumed, so
  /// mark them failed-but-resumable instead of spinning forever.
  Future<void> recoverInterrupted() async {
    for (final l in await repo.getAllLessons()) {
      if (l.stage.isWorking) {
        await repo.updateLesson(
          l.id,
          (x) => x.copyWith(
            stage: LessonStage.failed,
            error: 'Generation was interrupted. Tap retry to continue.',
          ),
        );
      }
    }
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

  /// Plans a course and stores it with all its lessons pending.
  /// Returns the course id. Lessons are generated on demand.
  Future<String> createCourse(String topic, {int? lessonCount}) async {
    final settings = _requireKey();
    final client = OpenRouterClient(apiKey: settings.apiKey);
    try {
      final outline = await LessonGenerator(client, model: settings.chatModel)
          .generateOutline(topic.trim(), lessonCount: lessonCount);
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
    } finally {
      client.close();
    }
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
    unawaited(_drain());
  }

  void cancel(String lessonId) {
    _cancelled.add(lessonId);
    if (_queue.isNotEmpty && _queue.first != lessonId) {
      _queue.remove(lessonId);
      onProgress(lessonId, null);
    }
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

  Future<void> _drain() async {
    if (_running) return;
    _running = true;
    try {
      while (_queue.isNotEmpty) {
        final id = _queue.first;
        try {
          await _run(id);
        } on GenerationCancelled {
          await repo.updateLesson(
            id,
            (l) => l.copyWith(stage: LessonStage.failed, error: 'Cancelled.'),
          );
        } catch (e) {
          await repo.updateLesson(
            id,
            (l) => l.copyWith(stage: LessonStage.failed, error: _describe(e)),
          );
        } finally {
          _queue.remove(id);
          _cancelled.remove(id);
          _audioWanted.remove(id);
          onProgress(id, null);
        }
      }
    } finally {
      _running = false;
    }
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

    // Mathpix-only transcription is the one job that needs no OpenRouter key.
    final needsKey = wantAudio ||
        !lesson.isBookChapter ||
        settings.transcriptionBackend != TranscriptionBackend.mathpix;
    if (needsKey && !settings.hasApiKey) throw const MissingApiKey();

    final client = OpenRouterClient(apiKey: settings.apiKey);
    TtsEngine? engine;
    try {
      final generator = LessonGenerator(client, model: settings.chatModel);
      final course = await _courseContext(lesson);

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
        onProgress(id, const JobProgress('Writing lecture notes…'));
        final notes = await generator.generateNotes(
          title: lesson.title,
          brief: lesson.brief,
          course: course,
          onProgress: (chars) => onProgress(
              id, JobProgress('Writing lecture notes… ${_kChars(chars)}')),
        );
        check();
        final heading = _firstHeading(notes);
        lesson = await update((l) => l.copyWith(
              notesMarkdown: notes,
              // Standalone lessons start with the raw request as title.
              title: l.courseId == null && heading != null ? heading : null,
              clearPdf: true,
            ));
      }

      if (!wantAudio) {
        await update(
            (l) => l.copyWith(stage: LessonStage.ready, clearError: true));
        return;
      }

      if (lesson.segments.isEmpty) {
        lesson = await update((l) => l.copyWith(
            stage: LessonStage.generatingNarration, clearError: true));
        final fromBook = lesson.isBookChapter;
        // A book chapter is far longer than one model answer can narrate, so
        // it is scripted in consecutive parts.
        final parts = fromBook
            ? splitForNarration(stripPageMarkers(lesson.notesMarkdown!))
            : [SourcePart(lesson.notesMarkdown!, const [])];
        final segments = <NarrationSegment>[];
        final covered = <String>[];
        for (var i = 0; i < parts.length; i++) {
          final label = parts.length == 1
              ? 'Preparing the lecture script…'
              : 'Preparing the lecture script… part ${i + 1} of ${parts.length}';
          onProgress(id, JobProgress(label, i / parts.length));
          segments.addAll(await generator.generateNarration(
            title: lesson.title,
            notesMarkdown: parts[i].text,
            course: course,
            fromBook: fromBook,
            part: NarrationPart(
              index: i,
              count: parts.length,
              previousSections: List.of(covered),
            ),
            onProgress: (chars) => onProgress(
                id, JobProgress('$label ${_kChars(chars)}', i / parts.length)),
          ));
          covered.addAll(parts[i].sections);
          check();
        }
        lesson = await update((l) => l.copyWith(segments: segments));
      }

      if (lesson.audioPath == null) {
        lesson = await update((l) => l.copyWith(
            stage: LessonStage.synthesizingAudio, clearError: true));
        if (settings.ttsBackend == TtsBackend.kokoro) {
          if (!await kokoro.isInstalled()) {
            await kokoro.install(
              onProgress: (f) => onProgress(
                id,
                JobProgress(
                    f == null
                        ? 'Unpacking voice model…'
                        : 'Downloading voice model (one time)…',
                    f),
              ),
            );
          }
          engine = KokoroTtsEngine(
              manager: kokoro, speakerId: settings.kokoroVoice);
        } else {
          engine = OpenRouterTtsEngine(
            client: client,
            model: settings.openRouterTtsModel,
            voice: settings.openRouterTtsVoice,
          );
        }
        onProgress(id, const JobProgress('Recording lecture…', 0));
        final outPath = paths.lessonAudio(id);
        final audio = await LectureAudioBuilder.build(
          segments: lesson.segments,
          engine: engine,
          outPath: outPath,
          pauseScale: settings.pauseScale,
          isCancelled: () => _cancelled.contains(id),
          onProgress: (done, total) => onProgress(
              id, JobProgress('Recording lecture $done/$total', done / total)),
        );
        lesson = await update((l) => l.copyWith(
              segments: audio.segments,
              audioPath: outPath,
              audioDurationMs: audio.durationMs,
              lastPositionMs: 0,
            ));
      }

      await update(
          (l) => l.copyWith(stage: LessonStage.ready, clearError: true));
    } finally {
      await engine?.dispose();
      client.close();
    }
  }

  AppSettings _requireKey() {
    final s = readSettings();
    if (!s.hasApiKey) {
      throw const MissingApiKey();
    }
    return s;
  }

  Future<CourseContext?> _courseContext(Lesson lesson) async {
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

class MissingApiKey implements Exception {
  const MissingApiKey();
  @override
  String toString() => 'Add your OpenRouter API key in Settings first.';
}
