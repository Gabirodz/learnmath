import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:learnmath/ai/openrouter_client.dart';
import 'package:learnmath/checks/math_check.dart';
import 'package:learnmath/core/models.dart';
import 'package:learnmath/core/providers.dart';
import 'package:learnmath/core/storage.dart';
import 'package:learnmath/exercises/exercise_controller.dart';
import 'package:learnmath/exercises/exercise_help.dart';
import 'package:sembast/sembast_memory.dart';

const notes = '# Calc\n\n## Results\n\nText.\n\n## Exercises\n\n'
    '1. Differentiate \$x^2\$.\n2. Integrate \$x\$.\n';

class _Settings extends SettingsNotifier {
  _Settings(this.s);
  final AppSettings s;
  @override
  AppSettings build() => s;
}

class _Runner implements MathCheckRunner {
  _Runner({this.throws = false});
  final bool throws;
  int runs = 0;
  bool disposed = false;
  @override
  Future<List<CheckOutcome>> run(List<MathCheck> checks,
      {Duration perCheckTimeout = const Duration(seconds: 20),
      void Function(int, int)? onProgress}) async {
    runs++;
    if (throws) throw MathCheckException('no sympy');
    return [
      for (final c in checks)
        CheckOutcome(title: c.title, status: CheckStatus.passed)
    ];
  }

  @override
  Future<void> dispose() async => disposed = true;
}

const _solution = 'We differentiate: \$2x\$.\n\n\$\$\n(x^2)\' = 2x\n\$\$\n\n'
    '<<<CHECKS\nCHECK: derivative\nx = symbols("x")\nassert diff(x**2, x) == 2*x\nCHECKS>>>';

void main() {
  late Database db;
  late LibraryRepository repo;
  late Directory tmp;
  var n = 0;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('ex_test');
    db = await newDatabaseFactoryMemory().openDatabase('ex${n++}');
    repo = LibraryRepository(
        db, AppPaths(docs: '${tmp.path}/d', support: '${tmp.path}/s'));
    await repo.saveLesson(Lesson(
        id: 'l1',
        title: 'Calc',
        brief: '',
        createdAt: DateTime(2026),
        notesMarkdown: notes));
  });
  tearDown(() async {
    await db.close();
    await tmp.delete(recursive: true);
  });

  final calls = <({String model, String? effort, String user})>[];
  late String Function(int call) answer;

  ProviderContainer make({
    AppSettings settings = const AppSettings(apiKey: 'k'),
    _Runner? runner,
  }) {
    calls.clear();
    final c = ProviderContainer(overrides: [
      repositoryProvider.overrideWithValue(repo),
      settingsProvider.overrideWith(() => _Settings(settings)),
      checkRunnerFactoryProvider
          .overrideWithValue(runner == null ? null : () => runner),
      exerciseModelProvider.overrideWithValue(({
        required apiKey,
        required model,
        required messages,
        reasoningEffort,
        required onDelta,
      }) async {
        calls.add((
          model: model,
          effort: reasoningEffort,
          user: messages.last.content
        ));
        final a = answer(calls.length);
        onDelta(a);
        return a;
      }),
    ]);
    addTearDown(c.dispose);
    return c;
  }

  Future<List<ExerciseHelp>> stored() async =>
      (await repo.getLesson('l1'))!.exerciseHelp;

  test('hint is stored, fast (no effort), and asked about the right exercise',
      () async {
    answer = (_) => 'Think about the power rule.';
    final c = make();
    await c.read(exerciseControllerProvider('l1').notifier).requestHint(1);
    expect(calls.single.effort, isNull);
    expect(calls.single.user, endsWith('Exercise:\nIntegrate \$x\$.'));
    final h = await stored();
    expect(h.single.index, 1);
    expect(h.single.hint, 'Think about the power rule.');
    expect(c.read(exerciseControllerProvider('l1')).busy, isFalse);
  });

  test('solution: checks split off, report saved', () async {
    answer = (_) => _solution;
    final r = _Runner();
    final c = make(runner: r);
    await c.read(exerciseControllerProvider('l1').notifier).requestSolution(0);
    final h = (await stored()).single;
    expect(h.solution, isNot(contains('CHECKS')));
    expect(h.solution, contains('2x'));
    expect(h.checks.single.title, 'derivative');
    expect(h.checkReport!.passed, 1);
    expect(r.disposed, isTrue);
  });

  test('hint and solution merge into one entry', () async {
    answer = (i) => i == 1 ? 'A hint.' : _solution;
    final c = make(runner: _Runner());
    final ctl = c.read(exerciseControllerProvider('l1').notifier);
    await ctl.requestHint(0);
    await ctl.requestSolution(0);
    final h = await stored();
    expect(h.length, 1);
    expect(h.single.hint, 'A hint.');
    expect(h.single.solution, isNotNull);
    expect(h.single.checks, hasLength(1));
  });

  test('stored help is not requested again', () async {
    answer = (_) => 'Hint';
    final c = make();
    final ctl = c.read(exerciseControllerProvider('l1').notifier);
    await ctl.requestHint(0);
    await ctl.requestHint(0);
    expect(calls, hasLength(1));
  });

  test('model error surfaces and nothing is stored', () async {
    final c = make();
    answer = (_) => throw OpenRouterException('Rate limited.');
    final ctl = c.read(exerciseControllerProvider('l1').notifier);
    await ctl.requestHint(0);
    final s = c.read(exerciseControllerProvider('l1'));
    expect(s.busy, isFalse);
    expect(s.errors[0]!.message, 'Rate limited.');
    expect(s.errors[0]!.kind, HelpKind.hint);
    expect(await stored(), isEmpty);
    // A retry clears the error.
    answer = (_) => 'ok';
    await ctl.requestHint(0);
    expect(c.read(exerciseControllerProvider('l1')).errors, isEmpty);
    expect((await stored()).single.hint, 'ok');
  });

  test('no API key: error, no call', () async {
    answer = (_) => 'x';
    final c = make(settings: const AppSettings());
    await c.read(exerciseControllerProvider('l1').notifier).requestHint(0);
    expect(calls, isEmpty);
    expect(c.read(exerciseControllerProvider('l1')).errors[0]!.message,
        contains('API key'));
  });

  test('checks skipped when mathChecks is off or there is no runner', () async {
    answer = (_) => _solution;
    final r = _Runner();
    var c = make(settings: const AppSettings(apiKey: 'k', mathChecks: false), runner: r);
    await c.read(exerciseControllerProvider('l1').notifier).requestSolution(0);
    expect(r.runs, 0);
    var h = (await stored()).single;
    expect(h.checks, hasLength(1));
    expect(h.checkReport, isNull);

    await repo.updateLesson('l1', (l) => l.copyWith(exerciseHelp: const []));
    c = make();
    await c.read(exerciseControllerProvider('l1').notifier).requestSolution(0);
    h = (await stored()).single;
    expect(h.solution, isNotNull);
    expect(h.checkReport, isNull);
  });

  test('MathCheckException leaves the solution stored without a report',
      () async {
    answer = (_) => _solution;
    final c = make(runner: _Runner(throws: true));
    await c.read(exerciseControllerProvider('l1').notifier).requestSolution(0);
    final h = (await stored()).single;
    expect(h.solution, isNotNull);
    expect(h.checkReport, isNull);
    expect(c.read(exerciseControllerProvider('l1')).errors, isEmpty);
  });

  test('cancel drops the answer', () async {
    final c = make();
    answer = (_) => 'late';
    final ctl = c.read(exerciseControllerProvider('l1').notifier);
    final f = ctl.requestHint(0);
    ctl.cancel();
    await f;
    expect(await stored(), isEmpty);
    expect(c.read(exerciseControllerProvider('l1')).busy, isFalse);
  });
}
