import 'package:flutter_test/flutter_test.dart';
import 'package:learnmath/checks/math_check.dart';
import 'package:learnmath/checks/process_runner.dart';

MathCheck _c(String title, String code) => MathCheck(title: title, code: code);

void main() async {
  final available = await ProcessCheckRunner.isAvailable();
  final skip = available ? null : 'python3 with sympy is not installed';

  group('ProcessCheckRunner', () {
    late ProcessCheckRunner runner;
    setUp(() => runner = ProcessCheckRunner());

    test('a true identity passes', () async {
      final out = await runner.run([
        _c('square', 'x = symbols("x")\nassert simplify((x+1)**2 - (x**2+2*x+1)) == 0'),
      ]);
      expect(out.single.status, CheckStatus.passed);
      expect(out.single.detail, isNull);
      expect(out.single.title, 'square');
    }, skip: skip);

    test('a false assertion fails with the assertion in the detail', () async {
      final out = await runner.run([_c('bad', 'assert 1 + 1 == 3, "sum"')]);
      expect(out.single.status, CheckStatus.failed);
      expect(out.single.detail, contains('assertion failed'));
      expect(out.single.detail, contains('sum'));
    }, skip: skip);

    test('a NameError is an error, not a failure', () async {
      final out = await runner.run([_c('n', 'assert nope == 1')]);
      expect(out.single.status, CheckStatus.error);
      expect(out.single.detail, contains('NameError'));
    }, skip: skip);

    test('a syntax error is an error', () async {
      final out = await runner.run([_c('s', 'def (:')]);
      expect(out.single.status, CheckStatus.error);
      expect(out.single.detail, contains('SyntaxError'));
    }, skip: skip);

    test('an infinite loop times out and the next check still runs', () async {
      final out = await runner.run(
        [_c('loop', 'while True:\n    pass'), _c('ok', 'assert 2 + 2 == 4')],
        perCheckTimeout: const Duration(seconds: 2),
      );
      expect(out.map((o) => o.status), [CheckStatus.timeout, CheckStatus.passed]);
    }, skip: skip);

    test('checks do not share a namespace', () async {
      final out = await runner.run([
        _c('define', 'leaked = 5'),
        _c('use', 'assert "leaked" not in dir()'),
        _c('use2', 'leaked'),
      ]);
      expect(out.map((o) => o.status),
          [CheckStatus.passed, CheckStatus.passed, CheckStatus.error]);
    }, skip: skip);

    test('order, count and progress are preserved', () async {
      final progress = <int>[];
      final out = await runner.run(
        [
          _c('a', 'assert True'),
          _c('b', 'assert False'),
          _c('c', 'raise ValueError("x")'),
          _c('d', 'assert True'),
        ],
        onProgress: (done, total) {
          expect(total, 4);
          progress.add(done);
        },
      );
      expect(out.map((o) => o.title), ['a', 'b', 'c', 'd']);
      expect(out.map((o) => o.status), [
        CheckStatus.passed,
        CheckStatus.failed,
        CheckStatus.error,
        CheckStatus.passed,
      ]);
      expect(progress, [1, 2, 3, 4]);
    }, skip: skip);
  });
}
