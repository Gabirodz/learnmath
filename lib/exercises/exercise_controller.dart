import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../ai/narration_parser.dart';
import '../ai/openrouter_client.dart';
import '../checks/check_parser.dart';
import '../checks/math_check.dart';
import '../core/providers.dart';
import 'exercise_help.dart';
import 'exercise_parser.dart';
import 'exercise_prompts.dart';

enum HelpKind { hint, solution }

/// One immediate, streaming model call. A provider so tests can fake it.
typedef ExerciseModelCall = Future<String> Function({
  required String apiKey,
  required String model,
  required List<ChatMessage> messages,
  String? reasoningEffort,
  required void Function(String delta) onDelta,
});

final exerciseModelProvider = Provider<ExerciseModelCall>((ref) => ({
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

class ExerciseState {
  const ExerciseState({
    this.busyIndex,
    this.busyKind,
    this.checking = false,
    this.streaming = '',
    this.errors = const {},
  });

  /// The exercise being answered, or null. Only one request runs per lesson.
  final int? busyIndex;
  final HelpKind? busyKind;

  /// The solution is written and SymPy is running its checks.
  final bool checking;

  /// Partial text while streaming.
  final String streaming;

  /// Last failure per exercise index, kept until that exercise is asked again.
  final Map<int, ({HelpKind kind, String message})> errors;

  bool get busy => busyIndex != null;

  ExerciseState copyWith({
    int? busyIndex,
    HelpKind? busyKind,
    bool clearBusy = false,
    bool? checking,
    String? streaming,
    Map<int, ({HelpKind kind, String message})>? errors,
  }) =>
      ExerciseState(
        busyIndex: clearBusy ? null : (busyIndex ?? this.busyIndex),
        busyKind: clearBusy ? null : (busyKind ?? this.busyKind),
        checking: checking ?? this.checking,
        streaming: streaming ?? this.streaming,
        errors: errors ?? this.errors,
      );
}

const _deltaThrottle = Duration(milliseconds: 50);

/// Hints and worked solutions for the exercises of one lesson, asked for on
/// demand and kept with the lesson ([Lesson.exerciseHelp]).
class ExerciseController extends Notifier<ExerciseState> {
  ExerciseController(this.lessonId);

  final String lessonId;

  bool _disposed = false;
  int _generation = 0; // bumped by cancel(); stale answers are dropped
  Timer? _timer;
  final _acc = StringBuffer();

  @override
  ExerciseState build() {
    ref.onDispose(() {
      _disposed = true;
      _timer?.cancel();
    });
    return const ExerciseState();
  }

  Future<void> requestHint(int index) => _request(index, HelpKind.hint);
  Future<void> requestSolution(int index) =>
      _request(index, HelpKind.solution);

  /// Stops waiting for the running request; nothing is stored.
  void cancel() {
    if (!state.busy) return;
    _generation++;
    _timer?.cancel();
    _timer = null;
    _acc.clear();
    state = state.copyWith(clearBusy: true, checking: false, streaming: '');
  }

  void _setError(int index, HelpKind kind, String message) {
    state = state.copyWith(
      clearBusy: true,
      checking: false,
      streaming: '',
      errors: {...state.errors, index: (kind: kind, message: message)},
    );
  }

  void _flush(int gen) {
    _timer = null;
    if (_disposed || gen != _generation) return;
    state = state.copyWith(streaming: _acc.toString());
  }

  Future<void> _request(int index, HelpKind kind) async {
    if (state.busy) return;
    final errors = {...state.errors}..remove(index);
    final gen = _generation;
    _acc.clear();
    state = ExerciseState(
        busyIndex: index, busyKind: kind, errors: errors);
    try {
      final settings = ref.read(settingsProvider);
      if (!settings.hasApiKey) {
        _setError(index, kind, 'Add your OpenRouter API key in Settings first.');
        return;
      }
      final repo = ref.read(repositoryProvider);
      final lesson = await repo.getLesson(lessonId);
      if (_disposed || gen != _generation) return;
      if (lesson == null || !lesson.hasNotes) {
        _setError(index, kind, 'This lesson no longer has notes.');
        return;
      }
      final stored = lesson.exerciseHelp.where((h) => h.index == index);
      if (stored.isNotEmpty) {
        final h = stored.first;
        final have = kind == HelpKind.hint ? h.hint : h.solution;
        if (have != null && have.trim().isNotEmpty) {
          state = state.copyWith(clearBusy: true);
          return;
        }
      }
      final exercises = parseExercises(lesson.notesMarkdown!);
      if (index < 0 || index >= exercises.length) {
        _setError(index, kind, 'This exercise is not in the notes any more.');
        return;
      }
      final messages = kind == HelpKind.hint
          ? ExercisePrompts.hintMessages(
              title: lesson.title,
              notesMarkdown: lesson.notesMarkdown!,
              exercise: exercises[index])
          : ExercisePrompts.solutionMessages(
              title: lesson.title,
              notesMarkdown: lesson.notesMarkdown!,
              exercise: exercises[index]);

      final reply = await ref.read(exerciseModelProvider)(
        apiKey: settings.apiKey,
        model: settings.tutorModel.model,
        messages: messages,
        reasoningEffort:
            kind == HelpKind.hint ? null : settings.tutorModel.effort,
        onDelta: (d) {
          if (_disposed || gen != _generation) return;
          _acc.write(d);
          _timer ??= Timer(_deltaThrottle, () => _flush(gen));
        },
      );
      _timer?.cancel();
      _timer = null;
      if (_disposed || gen != _generation) return;

      String text;
      var checks = <MathCheck>[];
      if (kind == HelpKind.solution) {
        final split = splitNotesAndChecks(reply);
        text = cleanNotes(split.notes);
        checks = split.checks;
      } else {
        text = cleanNotes(reply);
      }
      if (text.isEmpty) {
        _setError(index, kind,
            'The model returned an empty answer. Please retry.');
        return;
      }

      await _store(index, kind, text, checks);
      if (_disposed || gen != _generation) return;
      if (kind == HelpKind.solution && checks.isNotEmpty) {
        state = state.copyWith(checking: true, streaming: text);
        final report = await _check(settings.mathChecks, checks);
        if (_disposed || gen != _generation) return;
        if (report != null) {
          await _store(index, kind, text, checks, report: report);
        }
      }
      if (_disposed || gen != _generation) return;
      state = state.copyWith(clearBusy: true, checking: false, streaming: '');
    } catch (e) {
      _timer?.cancel();
      _timer = null;
      if (_disposed || gen != _generation) return;
      _setError(
        index,
        kind,
        e is OpenRouterException
            ? e.message
            : 'Something went wrong. Please try again. ($e)',
      );
    }
  }

  /// Runs the checks if the user wants that and this platform can. A failure
  /// to check never fails the solution.
  Future<CheckReport?> _check(bool enabled, List<MathCheck> checks) async {
    if (!enabled) return null;
    final factory = ref.read(checkRunnerFactoryProvider);
    if (factory == null) return null;
    MathCheckRunner? runner;
    try {
      runner = factory();
      final outcomes = await runner.run(checks);
      return CheckReport(outcomes: outcomes);
    } on MathCheckException {
      return null;
    } catch (_) {
      return null;
    } finally {
      try {
        await runner?.dispose();
      } catch (_) {}
    }
  }

  Future<void> _store(
    int index,
    HelpKind kind,
    String text,
    List<MathCheck> checks, {
    CheckReport? report,
  }) async {
    await ref.read(repositoryProvider).updateLesson(lessonId, (l) {
      final list = [...l.exerciseHelp];
      final at = list.indexWhere((h) => h.index == index);
      final current = at >= 0 ? list[at] : ExerciseHelp(index: index);
      final next = kind == HelpKind.hint
          ? current.copyWith(hint: text)
          : ExerciseHelp(
              index: index,
              hint: current.hint,
              solution: text,
              checks: checks,
              checkReport: report,
            );
      if (at >= 0) {
        list[at] = next;
      } else {
        list.add(next);
        list.sort((a, b) => a.index.compareTo(b.index));
      }
      return l.copyWith(exerciseHelp: list);
    });
  }
}

final exerciseControllerProvider =
    NotifierProvider.family<ExerciseController, ExerciseState, String>(
        ExerciseController.new);
