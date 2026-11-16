import 'dart:async';
import 'dart:math';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../ai/openrouter_client.dart';
import '../core/providers.dart';
import '../exercises/exercise_controller.dart' show ExerciseModelCall;
import 'quiz_models.dart';
import 'quiz_parser.dart';
import 'quiz_prompts.dart';
import 'quiz_store.dart';

/// One immediate model call. A provider so tests can fake it.
final quizModelProvider = Provider<ExerciseModelCall>((ref) => ({
      required apiKey,
      required model,
      required messages,
      reasoningEffort,
      required onDelta,
    }) =>
        OpenRouterClient(apiKey: apiKey).chat(
          model: model,
          messages: messages,
          reasoningEffort: reasoningEffort,
          onDelta: onDelta,
        ));

/// Order of the options of new questions; tests fix the seed.
final quizShuffleProvider = Provider<Random>((ref) => Random());

class QuizState {
  const QuizState({
    this.quizzes = const [],
    this.loaded = false,
    this.writing = false,
    this.grading,
    this.error,
    this.ungraded,
  });

  /// Newest first.
  final List<Quiz> quizzes;
  final bool loaded;

  /// A new quiz is being written.
  final bool writing;

  /// The free answer being graded.
  final ({String quizId, int index})? grading;

  /// Why the last request failed.
  final String? error;

  /// The free answer whose grading failed with [error].
  final ({String quizId, int index})? ungraded;

  Quiz? byId(String? id) {
    for (final q in quizzes) {
      if (q.id == id) return q;
    }
    return null;
  }

  QuizState copyWith({
    List<Quiz>? quizzes,
    bool? loaded,
    bool? writing,
    ({String quizId, int index})? grading,
    String? error,
    ({String quizId, int index})? ungraded,
    bool clearGrading = false,
    bool clearError = false,
  }) =>
      QuizState(
        quizzes: quizzes ?? this.quizzes,
        loaded: loaded ?? this.loaded,
        writing: writing ?? this.writing,
        grading: clearGrading ? null : (grading ?? this.grading),
        error: clearError ? null : (error ?? this.error),
        ungraded: clearError ? null : (ungraded ?? this.ungraded),
      );
}

/// The quizzes of one lesson: writing them, answering and grading.
class QuizController extends Notifier<QuizState> {
  QuizController(this.lessonId);

  final String lessonId;
  static const _uuid = Uuid();
  bool _disposed = false;

  QuizStore get _store => QuizStore(ref.read(databaseProvider));

  @override
  QuizState build() {
    // The store is the truth: a quiz ordered through the Batch API is
    // stored by the pipeline when its answer arrives.
    final sub = _store.watch(lessonId).listen((quizzes) {
      if (!_disposed) state = state.copyWith(quizzes: quizzes, loaded: true);
    });
    ref.onDispose(() {
      _disposed = true;
      unawaited(sub.cancel());
    });
    return const QuizState();
  }

  /// Applies [change] to the stored quizzes (and at once to the state).
  Future<void> _update(List<Quiz> Function(List<Quiz>) change) async {
    state = state.copyWith(quizzes: change(state.quizzes));
    await _store.update(lessonId, change);
  }

  /// Questions of earlier quizzes, so a new one asks something else.
  List<String> get asked => askedQuestions(state.quizzes);

  /// Orders a quiz through the Batch API: about half the price, answered
  /// within minutes to a day. Returns false (with [QuizState.error]) when
  /// it could not be ordered.
  Future<bool> order({
    required QuizDifficulty difficulty,
    required QuizKind kind,
    required int count,
  }) async {
    if (state.writing) return false;
    state = state.copyWith(writing: true, clearError: true);
    try {
      await ref.read(generationProvider).orderQuiz(lessonId,
          QuizRequest(difficulty: difficulty, kind: kind, count: count));
      if (!_disposed) state = state.copyWith(writing: false);
      return true;
    } catch (e) {
      if (!_disposed) {
        state = state.copyWith(writing: false, error: _describe(e));
      }
      return false;
    }
  }

  /// Stops waiting for an ordered quiz and removes it.
  Future<void> cancelOrder(String quizId) =>
      ref.read(generationProvider).cancelQuiz(lessonId, quizId);

  /// Orders a failed quiz again, with what was asked for the first time.
  Future<void> retryOrder(String quizId) async {
    final request = state.byId(quizId)?.request;
    if (request == null) return;
    await delete(quizId);
    await order(
        difficulty: request.difficulty,
        kind: request.kind,
        count: request.count);
  }

  static String _describe(Object e) => e is OpenRouterException
      ? e.message
      : e is FormatException
          ? 'The model returned an unusable answer. Please try again.'
          : 'Something went wrong. Please try again. ($e)';

  /// Has the quiz model write a quiz. Returns its id, or null on failure
  /// (then [QuizState.error] says why).
  Future<String?> generate({
    required QuizDifficulty difficulty,
    required QuizKind kind,
    required int count,
  }) async {
    if (state.writing) return null;
    final settings = ref.read(settingsProvider);
    if (!settings.hasApiKey) {
      state = state.copyWith(
          error: 'Add your OpenRouter API key in Settings first.');
      return null;
    }
    state = state.copyWith(writing: true, clearError: true);
    try {
      final lesson = await ref.read(repositoryProvider).getLesson(lessonId);
      if (lesson == null || !lesson.hasNotes) {
        throw OpenRouterException('This lesson has no notes yet.');
      }
      final reply = await ref.read(quizModelProvider)(
        apiKey: settings.apiKey,
        model: settings.quizModel.model,
        messages: QuizPrompts.quizMessages(
          title: lesson.title,
          notesMarkdown: lesson.studyText!,
          difficulty: difficulty,
          kind: kind,
          count: count,
          avoid: asked,
        ),
        reasoningEffort: settings.quizModel.effort,
        onDelta: (_) {},
      );
      if (_disposed) return null;
      final id = await _add(reply, difficulty: difficulty, imported: false);
      state = state.copyWith(writing: false);
      return id;
    } catch (e) {
      if (_disposed) return null;
      state = state.copyWith(writing: false, error: _describe(e));
      return null;
    }
  }

  /// Stores a quiz written outside the app. Returns its id.
  /// Throws [FormatException] when [text] holds no questions.
  Future<String> import(String text, {QuizDifficulty? difficulty}) =>
      _add(text, difficulty: difficulty, imported: true);

  Future<String> _add(String raw,
      {required QuizDifficulty? difficulty, required bool imported}) async {
    final quiz = Quiz(
      id: _uuid.v4(),
      createdAt: DateTime.now(),
      difficulty: difficulty,
      imported: imported,
      questions: parseQuiz(raw, shuffle: ref.read(quizShuffleProvider)),
    );
    await _update((list) => [quiz, ...list]);
    return quiz.id;
  }

  Future<void> delete(String quizId) =>
      _update((list) => [for (final q in list) if (q.id != quizId) q]);

  Future<void> _put(String quizId, int index, QuizQuestion q) =>
      _update((list) => [
            for (final quiz in list)
              quiz.id == quizId ? quiz.withQuestion(index, q) : quiz,
          ]);

  /// Answers a multiple-choice question; the first tap counts.
  Future<void> choose(String quizId, int index, int option) async {
    final q = state.byId(quizId)?.questions[index];
    if (q == null || !q.isChoice || q.answered) return;
    await _put(
      quizId,
      index,
      q.copyWith(
        chosen: option,
        verdict: option == q.correct ? Verdict.correct : Verdict.wrong,
      ),
    );
  }

  /// Has the quiz model judge a typed answer against the lesson.
  Future<void> grade(String quizId, int index, String reply) async {
    final q = state.byId(quizId)?.questions[index];
    if (q == null || q.isChoice || q.answered || state.grading != null) return;
    final settings = ref.read(settingsProvider);
    if (!settings.hasApiKey) return;
    state = state.copyWith(
        grading: (quizId: quizId, index: index), clearError: true);
    try {
      await _put(quizId, index, q.copyWith(reply: reply));
      final lesson = await ref.read(repositoryProvider).getLesson(lessonId);
      final answer = await ref.read(quizModelProvider)(
        apiKey: settings.apiKey,
        model: settings.quizModel.model,
        messages: QuizPrompts.gradeMessages(
          title: lesson?.title ?? '',
          notesMarkdown: lesson?.studyText ?? '',
          question: q,
          reply: reply,
        ),
        reasoningEffort: settings.quizModel.effort == null ? null : 'medium',
        onDelta: (_) {},
      );
      if (_disposed) return;
      final result = parseGrade(answer);
      await _put(
        quizId,
        index,
        q.copyWith(
            reply: reply, verdict: result.verdict, feedback: result.feedback),
      );
      state = state.copyWith(clearGrading: true);
    } catch (e) {
      if (_disposed) return;
      state = state.copyWith(
        clearGrading: true,
        error: _describe(e),
        ungraded: (quizId: quizId, index: index),
      );
    }
  }

  /// The student compares their answer with the reference answer and says
  /// how it went (no key, or the grader failed).
  Future<void> selfGrade(
      String quizId, int index, String reply, Verdict verdict) async {
    final q = state.byId(quizId)?.questions[index];
    if (q == null || q.isChoice || q.answered) return;
    state = state.copyWith(clearError: true);
    await _put(quizId, index, q.copyWith(reply: reply, verdict: verdict));
  }
}

final quizControllerProvider =
    NotifierProvider.family<QuizController, QuizState, String>(
        QuizController.new);
