/// Core data models. Plain Dart, JSON-serializable, no Flutter imports.
library;

import '../checks/math_check.dart';
import '../checks/proof_review.dart';
import '../exercises/exercise_help.dart';

/// Where a lesson is in the generation pipeline.
enum LessonStage {
  /// Created (e.g. as part of a course outline) but nothing generated yet.
  pending,

  /// Reading a chapter of an imported book into Markdown + LaTeX.
  transcribing,
  generatingNotes,

  /// Running the SymPy checks that came with the notes.
  checkingMath,

  /// A second model is reviewing the proofs.
  verifyingProofs,
  generatingNarration,
  synthesizingAudio,
  ready,
  failed;

  bool get isWorking =>
      this == transcribing ||
      this == generatingNotes ||
      this == checkingMath ||
      this == verifyingProofs ||
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

/// Which model request of the pipeline a batch carries.
enum BatchStep { notes, repair, verify, judge, proofRepair, narration }

/// A request submitted to OpenRouter's Batch API whose answer has not been
/// collected yet. Stored with the lesson so waiting survives app restarts.
class PendingBatch {
  const PendingBatch({
    required this.id,
    required this.step,
    required this.submittedAt,
    this.parts = 1,
  });

  /// OpenRouter batch id.
  final String id;
  final BatchStep step;
  final DateTime submittedAt;

  /// Number of requests the lesson has in the batch (a long book chapter is
  /// narrated in several parts). Their custom ids are `<lesson id>:<index>`.
  final int parts;

  static String customId(String lessonId, int part) => '$lessonId:$part';

  Map<String, Object?> toJson() => {
        'id': id,
        'step': step.name,
        'submittedAt': submittedAt.millisecondsSinceEpoch,
        'parts': parts,
      };

  static PendingBatch? fromJson(Object? j) {
    if (j is! Map) return null;
    final id = j['id'];
    final step = BatchStep.values.asNameMap()[j['step']];
    if (id is! String || step == null) return null;
    return PendingBatch(
      id: id,
      step: step,
      submittedAt: DateTime.fromMillisecondsSinceEpoch(
          (j['submittedAt'] as num?)?.toInt() ?? 0),
      parts: (j['parts'] as num?)?.toInt() ?? 1,
    );
  }
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
    this.voice,
    this.pdfPath,
    this.lastPositionMs = 0,
    this.completed = false,
    this.error,
    this.sourceStartPage,
    this.sourceEndPage,
    this.sourceStopBefore,
    this.batch,
    this.checks = const [],
    this.checkReport,
    this.review,
    this.completedAt,
    this.recapOf,
    this.recapMade = false,
    this.exerciseHelp = const [],
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

  /// The voice the lecture was recorded with, as shown to the student
  /// ("Piper Lessac · Lessac (US, female)"). Null for recordings made before
  /// this was kept.
  final String? voice;

  /// Absolute path of the exported notes PDF (generated lazily).
  final String? pdfPath;

  /// Resume point for the player.
  final int lastPositionMs;
  final bool completed;

  /// Human-readable failure reason when [stage] is [LessonStage.failed].
  final String? error;

  /// For a chapter of an imported book: its page range in the book PDF
  /// (1-based, inclusive). The notes are then a transcription of those pages.
  final int? sourceStartPage;
  final int? sourceEndPage;

  /// Title of the next chapter/section, which may begin on [sourceEndPage];
  /// transcription stops before it.
  final String? sourceStopBefore;

  /// Set while the lesson waits for a Batch API answer.
  final PendingBatch? batch;

  /// SymPy checks the model wrote for the computations in the notes.
  final List<MathCheck> checks;

  /// Result of running [checks]; null until they have been run.
  final CheckReport? checkReport;

  /// Proof review by a second model; null when none was asked for.
  final ProofReview? review;

  /// When the lecture was first listened to the end.
  final DateTime? completedAt;

  /// For a short review lecture: id of the lesson it recaps.
  final String? recapOf;

  /// Whether the review lecture of this lesson has been created.
  final bool recapMade;

  /// Hints and solutions asked for so far.
  final List<ExerciseHelp> exerciseHelp;

  bool get isRecap => recapOf != null;
  bool get isWaitingForBatch => batch != null;
  bool get isBookChapter => sourceStartPage != null;
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
    String? voice,
    String? pdfPath,
    int? lastPositionMs,
    bool? completed,
    String? error,
    PendingBatch? batch,
    List<MathCheck>? checks,
    CheckReport? checkReport,
    ProofReview? review,
    DateTime? completedAt,
    bool? recapMade,
    List<ExerciseHelp>? exerciseHelp,
    bool clearError = false,
    bool clearAudio = false,
    bool clearPdf = false,
    bool clearBatch = false,
    bool clearCheckReport = false,
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
        voice: clearAudio ? null : (voice ?? this.voice),
        pdfPath: clearPdf ? null : (pdfPath ?? this.pdfPath),
        lastPositionMs: lastPositionMs ?? this.lastPositionMs,
        completed: completed ?? this.completed,
        error: clearError ? null : (error ?? this.error),
        sourceStartPage: sourceStartPage,
        sourceEndPage: sourceEndPage,
        sourceStopBefore: sourceStopBefore,
        batch: clearBatch ? null : (batch ?? this.batch),
        checks: checks ?? this.checks,
        checkReport:
            clearCheckReport ? null : (checkReport ?? this.checkReport),
        review: review ?? this.review,
        completedAt: completedAt ?? this.completedAt,
        recapOf: recapOf,
        recapMade: recapMade ?? this.recapMade,
        exerciseHelp: exerciseHelp ?? this.exerciseHelp,
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
        'voice': voice,
        'pdfPath': pdfPath,
        'lastPositionMs': lastPositionMs,
        'completed': completed,
        'error': error,
        'sourceStartPage': sourceStartPage,
        'sourceEndPage': sourceEndPage,
        'sourceStopBefore': sourceStopBefore,
        'batch': batch?.toJson(),
        'checks': [for (final c in checks) c.toJson()],
        'checkReport': checkReport?.toJson(),
        'review': review?.toJson(),
        'completedAt': completedAt?.millisecondsSinceEpoch,
        'recapOf': recapOf,
        'recapMade': recapMade,
        'exerciseHelp': [for (final h in exerciseHelp) h.toJson()],
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
        voice: j['voice'] as String?,
        pdfPath: j['pdfPath'] as String?,
        lastPositionMs: (j['lastPositionMs'] as num?)?.toInt() ?? 0,
        completed: j['completed'] as bool? ?? false,
        error: j['error'] as String?,
        sourceStartPage: (j['sourceStartPage'] as num?)?.toInt(),
        sourceEndPage: (j['sourceEndPage'] as num?)?.toInt(),
        sourceStopBefore: j['sourceStopBefore'] as String?,
        batch: PendingBatch.fromJson(j['batch']),
        checks: [
          for (final c in (j['checks'] as List? ?? const []))
            MathCheck.fromJson((c as Map).cast<String, Object?>()),
        ],
        checkReport: j['checkReport'] is Map
            ? CheckReport.fromJson(
                (j['checkReport'] as Map).cast<String, Object?>())
            : null,
        review: ProofReview.fromJson(j['review']),
        completedAt: j['completedAt'] is num
            ? DateTime.fromMillisecondsSinceEpoch(
                (j['completedAt'] as num).toInt())
            : null,
        recapOf: j['recapOf'] as String?,
        recapMade: j['recapMade'] as bool? ?? false,
        exerciseHelp: [
          for (final h in (j['exerciseHelp'] as List? ?? const []))
            ExerciseHelp.fromJson((h as Map).cast<String, Object?>()),
        ],
      );
}

class Course {
  const Course({
    required this.id,
    required this.title,
    required this.description,
    required this.createdAt,
    this.bookPath,
    this.bookPageCount,
  });

  final String id;
  final String title;
  final String description;
  final DateTime createdAt;

  /// For an imported book: absolute path of the app's copy of the PDF.
  final String? bookPath;
  final int? bookPageCount;

  bool get isBook => bookPath != null;

  Map<String, Object?> toJson() => {
        'id': id,
        'title': title,
        'description': description,
        'createdAt': createdAt.millisecondsSinceEpoch,
        'bookPath': bookPath,
        'bookPageCount': bookPageCount,
      };

  factory Course.fromJson(Map<String, Object?> j) => Course(
        id: j['id'] as String,
        title: j['title'] as String,
        description: j['description'] as String? ?? '',
        createdAt: DateTime.fromMillisecondsSinceEpoch(
            (j['createdAt'] as num).toInt()),
        bookPath: j['bookPath'] as String?,
        bookPageCount: (j['bookPageCount'] as num?)?.toInt(),
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

/// Where lecture audio is synthesized.
enum TtsBackend {
  /// A downloaded model running on the device (see `lib/tts`).
  onDevice,
  openRouter;

  /// Settings saved before there was more than one on-device model call
  /// this backend "kokoro".
  static TtsBackend? parse(Object? name) =>
      name == 'kokoro' ? onDevice : values.asNameMap()[name];
}

/// How pages of an imported book are turned into Markdown + LaTeX.
enum TranscriptionBackend { openRouterVision, mathpix }

/// A ready-made choice of lesson model in Settings.
class LessonModelPreset {
  const LessonModelPreset({
    required this.id,
    required this.label,
    required this.model,
    required this.batch,
    required this.description,
    this.effort,
  });

  final String id;
  final String label;

  /// OpenRouter model slug.
  final String model;

  /// Whether lessons are written through the Batch API: about half the
  /// price, but the answer arrives minutes to hours later.
  final bool batch;

  /// `reasoning.effort` sent with lesson requests; null for the model's
  /// default.
  final String? effort;
  final String description;

  static const solBatch = LessonModelPreset(
    id: 'sol-batch',
    label: 'GPT-6.1 Sol (batch)',
    model: 'openai/gpt-6.1-sol',
    batch: true,
    effort: 'high',
    description:
        'Most accurate. Half price through the Batch API; a lesson is '
        'usually ready within minutes, at most a day.',
  );

  static const terraBatch = LessonModelPreset(
    id: 'terra-batch',
    label: 'GPT-6.1 Terra (batch)',
    model: 'openai/gpt-6.1-terra',
    batch: true,
    effort: 'high',
    description:
        'About half the cost of Sol and slightly less accurate. Batch API.',
  );

  static const luna = LessonModelPreset(
    id: 'luna',
    label: 'GPT-6 Luna',
    model: 'openai/gpt-6-luna',
    batch: false,
    description:
        'Cheapest and immediate, written while you wait. More mistakes in '
        'proofs.',
  );

  static const all = [solBatch, terraBatch, luna];

  /// Id of the "Custom model" choice, which uses [AppSettings.chatModel].
  static const customId = 'custom';

  static LessonModelPreset? byId(String id) {
    for (final p in all) {
      if (p.id == id) return p;
    }
    return null;
  }
}

/// `reasoning.effort` values offered for the lesson model ('' = the model's
/// own default), lowest first. OpenRouter maps a level a model does not
/// have to the nearest one it has.
const reasoningEfforts = [
  '',
  'minimal',
  'low',
  'medium',
  'high',
  'xhigh',
  'max',
];

/// The effort lessons are best written with: enough thinking to get proofs
/// right, without the cost of the levels above it.
const recommendedEffort = 'high';

class AppSettings {
  const AppSettings({
    this.apiKey = '',
    this.lessonPreset = defaultLessonPreset,
    this.chatModel = defaultChatModel,
    this.customBatch = false,
    this.customEffort = '',
    this.presetEffort,
    this.mathChecks = true,
    this.verifyProofs = false,
    this.verifierModel = defaultVerifierModel,
    this.recallQuestions = true,
    this.spacedReview = true,
    this.prerequisiteCheck = true,
    this.autoPlayNext = true,
    this.ttsBackend = TtsBackend.onDevice,
    this.voiceModel = defaultVoiceModel,
    this.voiceSpeaker = 0,
    this.openRouterTtsModel = 'heygen/heygen-voice-1-turbo',
    this.openRouterTtsVoice = 'gareth',
    this.pauseScale = 1.0,
    this.playbackSpeed = 1.0,
    this.skipSeconds = 10,
    this.transcriptionBackend = TranscriptionBackend.openRouterVision,
    this.visionModel = defaultVisionModel,
    this.mathpixAppId = '',
    this.mathpixAppKey = '',
  });

  static const defaultLessonPreset = 'sol-batch';
  static const defaultChatModel = 'openai/gpt-6.1-sol';
  static const defaultVisionModel = 'openai/gpt-6-luna';
  static const defaultVoiceModel = 'kokoro';
  static const defaultVerifierModel = 'anthropic/claude-opus-5.5';

  /// OpenRouter API key (kept in secure storage, not in the database).
  final String apiKey;

  /// Id of a [LessonModelPreset], or [LessonModelPreset.customId].
  final String lessonPreset;

  /// Model slug used with the custom preset.
  final String chatModel;

  /// Whether the custom model writes lessons through the Batch API.
  final bool customBatch;

  /// `reasoning.effort` for the custom model; empty for the model's default.
  final String customEffort;

  /// `reasoning.effort` chosen for the selected preset (empty for the
  /// model's default), or null to use the preset's own.
  final String? presetEffort;

  /// Whether lessons carry SymPy checks that are run on this device.
  final bool mathChecks;

  /// Whether a second model reviews the proofs of every new lesson. It costs
  /// several times what writing the lesson does, so it is off by default and
  /// can be asked for per lesson.
  final bool verifyProofs;

  /// The reviewer; best from another family than the lesson model, so the
  /// two do not share blind spots.
  final String verifierModel;

  /// Whether lectures end with a few questions to answer from memory.
  final bool recallQuestions;

  /// Whether a short review lecture is made a few days after a lesson has
  /// been listened to.
  final bool spacedReview;

  /// Whether creating a lesson first looks at what it assumes and whether
  /// the library covers it.
  final bool prerequisiteCheck;

  /// Whether the next lesson of a course starts when one ends.
  final bool autoPlayNext;
  final TtsBackend ttsBackend;

  /// Id of the on-device voice model (see `voiceModels` in `lib/tts`).
  final String voiceModel;

  /// Speaker id within [voiceModel].
  final int voiceSpeaker;
  final String openRouterTtsModel;
  final String openRouterTtsVoice;

  /// Multiplier on the pauses the lecturer leaves for thinking (0.5 - 2.5).
  final double pauseScale;
  final double playbackSpeed;

  /// Double-tap seek distance.
  final int skipSeconds;

  final TranscriptionBackend transcriptionBackend;

  /// OpenRouter model (image input) used to read book pages.
  final String visionModel;
  final String mathpixAppId;

  /// Kept in secure storage, like [apiKey].
  final String mathpixAppKey;

  bool get hasApiKey => apiKey.trim().isNotEmpty;
  bool get hasMathpix =>
      mathpixAppId.trim().isNotEmpty && mathpixAppKey.trim().isNotEmpty;

  LessonModelPreset? get _preset => LessonModelPreset.byId(lessonPreset);

  /// Model slug for lessons, course outlines and the tutor chat.
  String get lessonModel => _preset?.model ?? chatModel;

  /// Whether notes and lecture scripts go through the Batch API. Outlines
  /// and chat are always immediate.
  bool get lessonBatch => _preset?.batch ?? customBatch;

  /// `reasoning.effort` for notes and lecture scripts, or null.
  String? get lessonEffort {
    final p = _preset;
    final chosen = p == null ? customEffort : presetEffort;
    if (chosen == null) return p!.effort;
    return chosen.isEmpty ? null : chosen;
  }

  AppSettings copyWith({
    String? apiKey,
    String? lessonPreset,
    String? chatModel,
    bool? customBatch,
    String? customEffort,
    String? presetEffort,
    bool clearPresetEffort = false,
    bool? mathChecks,
    bool? verifyProofs,
    String? verifierModel,
    bool? recallQuestions,
    bool? spacedReview,
    bool? prerequisiteCheck,
    bool? autoPlayNext,
    TtsBackend? ttsBackend,
    String? voiceModel,
    int? voiceSpeaker,
    String? openRouterTtsModel,
    String? openRouterTtsVoice,
    double? pauseScale,
    double? playbackSpeed,
    int? skipSeconds,
    TranscriptionBackend? transcriptionBackend,
    String? visionModel,
    String? mathpixAppId,
    String? mathpixAppKey,
  }) =>
      AppSettings(
        apiKey: apiKey ?? this.apiKey,
        lessonPreset: lessonPreset ?? this.lessonPreset,
        chatModel: chatModel ?? this.chatModel,
        customBatch: customBatch ?? this.customBatch,
        customEffort: customEffort ?? this.customEffort,
        presetEffort:
            clearPresetEffort ? null : (presetEffort ?? this.presetEffort),
        mathChecks: mathChecks ?? this.mathChecks,
        verifyProofs: verifyProofs ?? this.verifyProofs,
        verifierModel: verifierModel ?? this.verifierModel,
        recallQuestions: recallQuestions ?? this.recallQuestions,
        spacedReview: spacedReview ?? this.spacedReview,
        prerequisiteCheck: prerequisiteCheck ?? this.prerequisiteCheck,
        autoPlayNext: autoPlayNext ?? this.autoPlayNext,
        ttsBackend: ttsBackend ?? this.ttsBackend,
        voiceModel: voiceModel ?? this.voiceModel,
        voiceSpeaker: voiceSpeaker ?? this.voiceSpeaker,
        openRouterTtsModel: openRouterTtsModel ?? this.openRouterTtsModel,
        openRouterTtsVoice: openRouterTtsVoice ?? this.openRouterTtsVoice,
        pauseScale: pauseScale ?? this.pauseScale,
        playbackSpeed: playbackSpeed ?? this.playbackSpeed,
        skipSeconds: skipSeconds ?? this.skipSeconds,
        transcriptionBackend: transcriptionBackend ?? this.transcriptionBackend,
        visionModel: visionModel ?? this.visionModel,
        mathpixAppId: mathpixAppId ?? this.mathpixAppId,
        mathpixAppKey: mathpixAppKey ?? this.mathpixAppKey,
      );

  /// Everything except the secrets.
  Map<String, Object?> toJson() => {
        'lessonPreset': lessonPreset,
        'chatModel': chatModel,
        'customBatch': customBatch,
        'customEffort': customEffort,
        'presetEffort': presetEffort,
        'mathChecks': mathChecks,
        'verifyProofs': verifyProofs,
        'verifierModel': verifierModel,
        'recallQuestions': recallQuestions,
        'spacedReview': spacedReview,
        'prerequisiteCheck': prerequisiteCheck,
        'autoPlayNext': autoPlayNext,
        'ttsBackend': ttsBackend.name,
        'voiceModel': voiceModel,
        'voiceSpeaker': voiceSpeaker,
        'openRouterTtsModel': openRouterTtsModel,
        'openRouterTtsVoice': openRouterTtsVoice,
        'pauseScale': pauseScale,
        'playbackSpeed': playbackSpeed,
        'skipSeconds': skipSeconds,
        'transcriptionBackend': transcriptionBackend.name,
        'visionModel': visionModel,
        'mathpixAppId': mathpixAppId,
      };

  factory AppSettings.fromJson(
    Map<String, Object?> j, {
    String apiKey = '',
    String mathpixAppKey = '',
  }) {
    const d = AppSettings();
    final chatModel = j['chatModel'] as String? ?? d.chatModel;
    // Settings saved before presets existed only have a model slug: keep a
    // model the user typed in as the custom choice, and move the old default
    // on to the new one.
    const legacyDefault = 'openai/gpt-6-luna';
    final preset = j['lessonPreset'] as String? ??
        (j['chatModel'] == null || chatModel == legacyDefault
            ? d.lessonPreset
            : LessonModelPreset.customId);
    return AppSettings(
      apiKey: apiKey,
      mathpixAppKey: mathpixAppKey,
      transcriptionBackend: TranscriptionBackend.values
              .asNameMap()[j['transcriptionBackend']] ??
          d.transcriptionBackend,
      visionModel: j['visionModel'] as String? ?? d.visionModel,
      mathpixAppId: j['mathpixAppId'] as String? ?? d.mathpixAppId,
      lessonPreset: preset,
      chatModel: j['lessonPreset'] == null && chatModel == legacyDefault
          ? d.chatModel
          : chatModel,
      customBatch: j['customBatch'] as bool? ?? d.customBatch,
      customEffort: reasoningEfforts.contains(j['customEffort'])
          ? j['customEffort'] as String
          : d.customEffort,
      presetEffort: reasoningEfforts.contains(j['presetEffort'])
          ? j['presetEffort'] as String
          : null,
      mathChecks: j['mathChecks'] as bool? ?? d.mathChecks,
      verifyProofs: j['verifyProofs'] as bool? ?? d.verifyProofs,
      verifierModel: j['verifierModel'] as String? ?? d.verifierModel,
      recallQuestions: j['recallQuestions'] as bool? ?? d.recallQuestions,
      spacedReview: j['spacedReview'] as bool? ?? d.spacedReview,
      prerequisiteCheck:
          j['prerequisiteCheck'] as bool? ?? d.prerequisiteCheck,
      autoPlayNext: j['autoPlayNext'] as bool? ?? d.autoPlayNext,
      ttsBackend: TtsBackend.parse(j['ttsBackend']) ?? d.ttsBackend,
      voiceModel: j['voiceModel'] as String? ?? d.voiceModel,
      voiceSpeaker: ((j['voiceSpeaker'] ?? j['kokoroVoice']) as num?)?.toInt() ??
          d.voiceSpeaker,
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
