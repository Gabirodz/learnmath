/// Core data models. Plain Dart, JSON-serializable, no Flutter imports.
library;

/// Where a lesson is in the generation pipeline.
enum LessonStage {
  /// Created (e.g. as part of a course outline) but nothing generated yet.
  pending,
  generatingNotes,
  generatingNarration,
  synthesizingAudio,
  ready,
  failed;

  bool get isWorking =>
      this == generatingNotes ||
      this == generatingNarration ||
      this == synthesizingAudio;
}

/// One spoken unit of a lecture (roughly a sentence or two) plus the silence
/// that follows it. Timings are filled in once audio has been synthesized.
class NarrationSegment {
  const NarrationSegment({
    required this.say,
    this.show,
    this.pauseMs = 350,
    this.section,
    this.startMs,
    this.endMs,
  });

  /// Text sent to the TTS engine. Math is spelled out in words
  /// ("the integral from zero to one of f of x d x").
  final String say;

  /// Subtitle text; may contain inline LaTeX in `$...$`. Falls back to [say].
  final String? show;

  /// Silence after this segment, in ms, before applying the user's pause scale.
  final int pauseMs;

  /// Non-null on the first segment of a new section (chapter marker).
  final String? section;

  /// Position of the spoken audio within the lecture file (set after synthesis).
  final int? startMs;
  final int? endMs;

  String get subtitle => (show == null || show!.trim().isEmpty) ? say : show!;

  NarrationSegment copyWith({int? startMs, int? endMs}) => NarrationSegment(
        say: say,
        show: show,
        pauseMs: pauseMs,
        section: section,
        startMs: startMs ?? this.startMs,
        endMs: endMs ?? this.endMs,
      );

  Map<String, Object?> toJson() => {
        'say': say,
        if (show != null) 'show': show,
        'pauseMs': pauseMs,
        if (section != null) 'section': section,
        if (startMs != null) 'startMs': startMs,
        if (endMs != null) 'endMs': endMs,
      };

  factory NarrationSegment.fromJson(Map<String, Object?> j) => NarrationSegment(
        say: j['say'] as String,
        show: j['show'] as String?,
        pauseMs: (j['pauseMs'] as num?)?.toInt() ?? 350,
        section: j['section'] as String?,
        startMs: (j['startMs'] as num?)?.toInt(),
        endMs: (j['endMs'] as num?)?.toInt(),
      );
}

class Lesson {
  const Lesson({
    required this.id,
    required this.title,
    required this.brief,
    required this.createdAt,
    this.courseId,
    this.order = 0,
    this.stage = LessonStage.pending,
    this.notesMarkdown,
    this.segments = const [],
    this.audioPath,
    this.audioDurationMs,
    this.pdfPath,
    this.lastPositionMs = 0,
    this.completed = false,
    this.error,
  });

  final String id;

  /// Null for standalone lessons.
  final String? courseId;

  /// Position within the course (0-based).
  final int order;
  final String title;

  /// What the lesson should cover: the user's request, or the outline summary.
  final String brief;
  final DateTime createdAt;
  final LessonStage stage;

  /// Lecture notes: Markdown with LaTeX in `$...$` / `$$...$$`.
  final String? notesMarkdown;
  final List<NarrationSegment> segments;

  /// Absolute path of the synthesized lecture WAV.
  final String? audioPath;
  final int? audioDurationMs;

  /// Absolute path of the exported notes PDF (generated lazily).
  final String? pdfPath;

  /// Resume point for the player.
  final int lastPositionMs;
  final bool completed;

  /// Human-readable failure reason when [stage] is [LessonStage.failed].
  final String? error;

  bool get hasNotes => notesMarkdown != null && notesMarkdown!.isNotEmpty;
  bool get hasAudio => audioPath != null && segments.isNotEmpty;

  Lesson copyWith({
    String? title,
    String? brief,
    int? order,
    LessonStage? stage,
    String? notesMarkdown,
    List<NarrationSegment>? segments,
    String? audioPath,
    int? audioDurationMs,
    String? pdfPath,
    int? lastPositionMs,
    bool? completed,
    String? error,
    bool clearError = false,
    bool clearAudio = false,
    bool clearPdf = false,
  }) =>
      Lesson(
        id: id,
        courseId: courseId,
        createdAt: createdAt,
        title: title ?? this.title,
        brief: brief ?? this.brief,
        order: order ?? this.order,
        stage: stage ?? this.stage,
        notesMarkdown: notesMarkdown ?? this.notesMarkdown,
        segments: segments ?? this.segments,
        audioPath: clearAudio ? null : (audioPath ?? this.audioPath),
        audioDurationMs:
            clearAudio ? null : (audioDurationMs ?? this.audioDurationMs),
        pdfPath: clearPdf ? null : (pdfPath ?? this.pdfPath),
        lastPositionMs: lastPositionMs ?? this.lastPositionMs,
        completed: completed ?? this.completed,
        error: clearError ? null : (error ?? this.error),
      );

  Map<String, Object?> toJson() => {
        'id': id,
        'courseId': courseId,
        'order': order,
        'title': title,
        'brief': brief,
        'createdAt': createdAt.millisecondsSinceEpoch,
        'stage': stage.name,
        'notesMarkdown': notesMarkdown,
        'segments': [for (final s in segments) s.toJson()],
        'audioPath': audioPath,
        'audioDurationMs': audioDurationMs,
        'pdfPath': pdfPath,
        'lastPositionMs': lastPositionMs,
        'completed': completed,
        'error': error,
      };

  factory Lesson.fromJson(Map<String, Object?> j) => Lesson(
        id: j['id'] as String,
        courseId: j['courseId'] as String?,
        order: (j['order'] as num?)?.toInt() ?? 0,
        title: j['title'] as String,
        brief: j['brief'] as String? ?? '',
        createdAt: DateTime.fromMillisecondsSinceEpoch(
            (j['createdAt'] as num).toInt()),
        stage: LessonStage.values.asNameMap()[j['stage']] ?? LessonStage.pending,
        notesMarkdown: j['notesMarkdown'] as String?,
        segments: [
          for (final s in (j['segments'] as List? ?? const []))
            NarrationSegment.fromJson((s as Map).cast<String, Object?>()),
        ],
        audioPath: j['audioPath'] as String?,
        audioDurationMs: (j['audioDurationMs'] as num?)?.toInt(),
        pdfPath: j['pdfPath'] as String?,
        lastPositionMs: (j['lastPositionMs'] as num?)?.toInt() ?? 0,
        completed: j['completed'] as bool? ?? false,
        error: j['error'] as String?,
      );
}

class Course {
  const Course({
    required this.id,
    required this.title,
    required this.description,
    required this.createdAt,
  });

  final String id;
  final String title;
  final String description;
  final DateTime createdAt;

  Map<String, Object?> toJson() => {
        'id': id,
        'title': title,
        'description': description,
        'createdAt': createdAt.millisecondsSinceEpoch,
      };

  factory Course.fromJson(Map<String, Object?> j) => Course(
        id: j['id'] as String,
        title: j['title'] as String,
        description: j['description'] as String? ?? '',
        createdAt: DateTime.fromMillisecondsSinceEpoch(
            (j['createdAt'] as num).toInt()),
      );
}

/// Result of asking the model to plan a course.
class CourseOutline {
  const CourseOutline({
    required this.title,
    required this.description,
    required this.lessons,
  });

  final String title;
  final String description;
  final List<OutlineLesson> lessons;
}

class OutlineLesson {
  const OutlineLesson({required this.title, required this.brief});
  final String title;

  /// 1-3 sentences on what the lesson covers.
  final String brief;
}

/// Context handed to the generator when a lesson belongs to a course, so
/// lessons build on each other instead of re-deriving prerequisites.
class CourseContext {
  const CourseContext({
    required this.courseTitle,
    required this.courseDescription,
    required this.lessonTitles,
    required this.lessonIndex,
  });

  final String courseTitle;
  final String courseDescription;

  /// All lesson titles of the course, in order.
  final List<String> lessonTitles;

  /// Index of the lesson being generated within [lessonTitles].
  final int lessonIndex;
}

enum TtsBackend { kokoro, openRouter }

class AppSettings {
  const AppSettings({
    this.apiKey = '',
    this.chatModel = defaultChatModel,
    this.ttsBackend = TtsBackend.kokoro,
    this.kokoroVoice = 0,
    this.openRouterTtsModel = 'openai/gpt-4o-mini-tts-2025-12-15',
    this.openRouterTtsVoice = 'alloy',
    this.pauseScale = 1.0,
    this.playbackSpeed = 1.0,
    this.skipSeconds = 10,
  });

  static const defaultChatModel = 'openai/gpt-6-luna';

  /// OpenRouter API key (kept in secure storage, not in the database).
  final String apiKey;
  final String chatModel;
  final TtsBackend ttsBackend;

  /// Kokoro speaker id.
  final int kokoroVoice;
  final String openRouterTtsModel;
  final String openRouterTtsVoice;

  /// Multiplier on the pauses the lecturer leaves for thinking (0.5 - 2.5).
  final double pauseScale;
  final double playbackSpeed;

  /// Double-tap seek distance.
  final int skipSeconds;

  bool get hasApiKey => apiKey.trim().isNotEmpty;

  AppSettings copyWith({
    String? apiKey,
    String? chatModel,
    TtsBackend? ttsBackend,
    int? kokoroVoice,
    String? openRouterTtsModel,
    String? openRouterTtsVoice,
    double? pauseScale,
    double? playbackSpeed,
    int? skipSeconds,
  }) =>
      AppSettings(
        apiKey: apiKey ?? this.apiKey,
        chatModel: chatModel ?? this.chatModel,
        ttsBackend: ttsBackend ?? this.ttsBackend,
        kokoroVoice: kokoroVoice ?? this.kokoroVoice,
        openRouterTtsModel: openRouterTtsModel ?? this.openRouterTtsModel,
        openRouterTtsVoice: openRouterTtsVoice ?? this.openRouterTtsVoice,
        pauseScale: pauseScale ?? this.pauseScale,
        playbackSpeed: playbackSpeed ?? this.playbackSpeed,
        skipSeconds: skipSeconds ?? this.skipSeconds,
      );

  /// Everything except the API key.
  Map<String, Object?> toJson() => {
        'chatModel': chatModel,
        'ttsBackend': ttsBackend.name,
        'kokoroVoice': kokoroVoice,
        'openRouterTtsModel': openRouterTtsModel,
        'openRouterTtsVoice': openRouterTtsVoice,
        'pauseScale': pauseScale,
        'playbackSpeed': playbackSpeed,
        'skipSeconds': skipSeconds,
      };

  factory AppSettings.fromJson(Map<String, Object?> j, {String apiKey = ''}) {
    const d = AppSettings();
    return AppSettings(
      apiKey: apiKey,
      chatModel: j['chatModel'] as String? ?? d.chatModel,
      ttsBackend:
          TtsBackend.values.asNameMap()[j['ttsBackend']] ?? d.ttsBackend,
      kokoroVoice: (j['kokoroVoice'] as num?)?.toInt() ?? d.kokoroVoice,
      openRouterTtsModel:
          j['openRouterTtsModel'] as String? ?? d.openRouterTtsModel,
      openRouterTtsVoice:
          j['openRouterTtsVoice'] as String? ?? d.openRouterTtsVoice,
      pauseScale: (j['pauseScale'] as num?)?.toDouble() ?? d.pauseScale,
      playbackSpeed:
          (j['playbackSpeed'] as num?)?.toDouble() ?? d.playbackSpeed,
      skipSeconds: (j['skipSeconds'] as num?)?.toInt() ?? d.skipSeconds,
    );
  }
}
