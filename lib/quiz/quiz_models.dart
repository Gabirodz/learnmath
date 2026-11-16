/// Quizzes on a lesson: questions written by the model from the lesson's
/// notes, answered by tapping an option or typing a few sentences.
library;

import '../core/models.dart' show PendingBatch;

enum QuizDifficulty {
  easy('Easy'),
  medium('Medium'),
  hard('Hard');

  const QuizDifficulty(this.label);
  final String label;
}

/// What kinds of question a quiz is asked to contain.
enum QuizKind {
  choice('Multiple choice'),
  free('Free answer'),
  mixed('Mixed');

  const QuizKind(this.label);
  final String label;
}

enum Verdict { correct, partial, wrong }

class QuizQuestion {
  const QuizQuestion({
    required this.prompt,
    this.options = const [],
    this.correct,
    required this.answer,
    this.chosen,
    this.reply,
    this.verdict,
    this.feedback,
  });

  /// The question; may contain inline LaTeX in `$...$`.
  final String prompt;

  /// The options of a multiple-choice question; empty for a free answer.
  final List<String> options;

  /// Index of the right option.
  final int? correct;

  /// Why the right option is right, or the reference answer of a free
  /// question.
  final String answer;

  /// The option the student tapped.
  final int? chosen;

  /// What the student typed.
  final String? reply;

  /// Null until answered (and, for a free answer, graded).
  final Verdict? verdict;

  /// The grader's comment on a free answer.
  final String? feedback;

  bool get isChoice => options.isNotEmpty;
  bool get answered => verdict != null;

  QuizQuestion copyWith({
    int? chosen,
    String? reply,
    Verdict? verdict,
    String? feedback,
  }) =>
      QuizQuestion(
        prompt: prompt,
        options: options,
        correct: correct,
        answer: answer,
        chosen: chosen ?? this.chosen,
        reply: reply ?? this.reply,
        verdict: verdict ?? this.verdict,
        feedback: feedback ?? this.feedback,
      );

  Map<String, Object?> toJson() => {
        'prompt': prompt,
        if (options.isNotEmpty) 'options': options,
        if (correct != null) 'correct': correct,
        'answer': answer,
        if (chosen != null) 'chosen': chosen,
        if (reply != null) 'reply': reply,
        if (verdict != null) 'verdict': verdict!.name,
        if (feedback != null) 'feedback': feedback,
      };

  factory QuizQuestion.fromJson(Map<String, Object?> j) => QuizQuestion(
        prompt: j['prompt'] as String? ?? '',
        options: [for (final o in (j['options'] as List? ?? const [])) '$o'],
        correct: (j['correct'] as num?)?.toInt(),
        answer: j['answer'] as String? ?? '',
        chosen: (j['chosen'] as num?)?.toInt(),
        reply: j['reply'] as String?,
        verdict: Verdict.values.asNameMap()[j['verdict']],
        feedback: j['feedback'] as String?,
      );
}

/// What was asked for when a quiz was ordered, so a failed one can be
/// ordered again.
class QuizRequest {
  const QuizRequest({
    required this.difficulty,
    required this.kind,
    required this.count,
  });

  final QuizDifficulty difficulty;
  final QuizKind kind;
  final int count;

  Map<String, Object?> toJson() =>
      {'difficulty': difficulty.name, 'kind': kind.name, 'count': count};

  static QuizRequest? fromJson(Object? j) {
    if (j is! Map) return null;
    final d = QuizDifficulty.values.asNameMap()[j['difficulty']];
    final k = QuizKind.values.asNameMap()[j['kind']];
    final n = (j['count'] as num?)?.toInt();
    if (d == null || k == null || n == null) return null;
    return QuizRequest(difficulty: d, kind: k, count: n);
  }
}

class Quiz {
  const Quiz({
    required this.id,
    required this.createdAt,
    required this.questions,
    this.difficulty,
    this.imported = false,
    this.batch,
    this.request,
    this.error,
  });

  final String id;
  final DateTime createdAt;

  /// Empty while the quiz is waiting for its batch answer or has failed.
  final List<QuizQuestion> questions;

  /// The Batch API request a quiz ordered for later is waiting for.
  final PendingBatch? batch;

  /// What was ordered (for a quiz from the Batch API).
  final QuizRequest? request;

  /// Why an ordered quiz could not be written.
  final String? error;

  bool get isWaiting => batch != null;
  bool get isFailed => batch == null && error != null && questions.isEmpty;

  /// Has questions to answer.
  bool get isReady => questions.isNotEmpty;

  /// Null when unknown (an imported quiz pasted without one).
  final QuizDifficulty? difficulty;

  /// Written by an assistant outside the app.
  final bool imported;

  int get answered => questions.where((q) => q.answered).length;
  bool get finished => answered == questions.length;

  /// Points so far: a partly right free answer counts half.
  double get score => questions.fold(
      0,
      (s, q) => s +
          switch (q.verdict) {
            Verdict.correct => 1,
            Verdict.partial => 0.5,
            _ => 0,
          });

  Quiz withQuestion(int index, QuizQuestion q) => Quiz(
        id: id,
        createdAt: createdAt,
        difficulty: difficulty,
        imported: imported,
        request: request,
        questions: [
          for (var i = 0; i < questions.length; i++)
            i == index ? q : questions[i],
        ],
      );

  Map<String, Object?> toJson() => {
        'id': id,
        'createdAt': createdAt.millisecondsSinceEpoch,
        'difficulty': difficulty?.name,
        'imported': imported,
        'questions': [for (final q in questions) q.toJson()],
        if (batch != null) 'batch': batch!.toJson(),
        if (request != null) 'request': request!.toJson(),
        if (error != null) 'error': error,
      };

  factory Quiz.fromJson(Map<String, Object?> j) => Quiz(
        id: j['id'] as String,
        createdAt: DateTime.fromMillisecondsSinceEpoch(
            (j['createdAt'] as num?)?.toInt() ?? 0),
        difficulty: QuizDifficulty.values.asNameMap()[j['difficulty']],
        imported: j['imported'] as bool? ?? false,
        questions: [
          for (final q in (j['questions'] as List? ?? const []))
            if (q is Map) QuizQuestion.fromJson(Map<String, Object?>.from(q)),
        ],
        batch: PendingBatch.fromJson(j['batch']),
        request: QuizRequest.fromJson(j['request']),
        error: j['error'] as String?,
      );
}

/// Questions of the last four quizzes that have questions, so a new quiz
/// asks something else.
List<String> askedQuestions(List<Quiz> quizzes) => [
      for (final quiz in quizzes.where((q) => q.isReady).take(4))
        for (final q in quiz.questions) q.prompt,
    ];
