import 'package:flutter_test/flutter_test.dart';
import 'package:learnmath/checks/check_parser.dart';
import 'package:learnmath/checks/math_check.dart';

void main() {
  group('splitNotesAndChecks', () {
    test('notes without a block are returned untouched', () {
      const raw = '# Title\n\nSome text.\n';
      final r = splitNotesAndChecks(raw);
      expect(r.notes, raw);
      expect(r.checks, isEmpty);
    });

    test('block with several checks', () {
      const raw = '# T\n\nBody.\n\n'
          '<<<CHECKS\n'
          'CHECK: Example 1\n'
          'x = symbols("x")\n'
          'assert diff(x**2, x) == 2*x\n'
          'CHECK: Example 2\n'
          'assert 1 + 1 == 2\n'
          'CHECKS>>>\n';
      final r = splitNotesAndChecks(raw);
      expect(r.notes, '# T\n\nBody.');
      expect(r.checks.map((c) => c.title), ['Example 1', 'Example 2']);
      expect(r.checks[0].code,
          'x = symbols("x")\nassert diff(x**2, x) == 2*x');
      expect(r.checks[1].code, 'assert 1 + 1 == 2');
    });

    test('missing end marker still parses everything after the start', () {
      const raw = '# T\n\nBody.\n<<<CHECKS\nCHECK: A\nassert True\nCHECK: B\nassert 2 > 1';
      final r = splitNotesAndChecks(raw);
      expect(r.notes, '# T\n\nBody.');
      expect(r.checks.map((c) => c.code), ['assert True', 'assert 2 > 1']);
    });

    test('block wrapped in a ```python fence', () {
      const raw = '# T\n\nBody.\n\n```python\n<<<CHECKS\nCHECK: A\nassert True\nCHECKS>>>\n```\n';
      final r = splitNotesAndChecks(raw);
      expect(r.notes, '# T\n\nBody.');
      expect(r.notes, isNot(contains('```')));
      expect(r.checks, hasLength(1));
      expect(r.checks.single.code, 'assert True');
    });

    test('block wrapped in a bare ``` fence', () {
      const raw = '# T\n\nBody.\n```\n<<<CHECKS\nCHECK: A\nassert True\nCHECKS>>>\n```';
      final r = splitNotesAndChecks(raw);
      expect(r.notes, '# T\n\nBody.');
      expect(r.checks.single.code, 'assert True');
    });

    test('fences inside checks are dropped', () {
      const raw = '# T\n<<<CHECKS\n'
          'CHECK: A\n```python\nassert True\n```\n'
          'CHECK: B\n```\nassert 1 == 1\n```\n'
          'CHECKS>>>';
      final r = splitNotesAndChecks(raw);
      expect(r.checks.map((c) => c.code), ['assert True', 'assert 1 == 1']);
    });

    test('text between the marker and the first CHECK is ignored', () {
      const raw = '# T\n<<<CHECKS\nHere are the checks:\nassert False\n\n'
          'CHECK: A\nassert True\nCHECKS>>>';
      final r = splitNotesAndChecks(raw);
      expect(r.checks, hasLength(1));
      expect(r.checks.single.code, 'assert True');
    });

    test('empty block gives no checks and clean notes', () {
      const raw = '# T\n\nBody.\n\n<<<CHECKS\nCHECKS>>>\n';
      final r = splitNotesAndChecks(raw);
      expect(r.notes, '# T\n\nBody.');
      expect(r.checks, isEmpty);
    });

    test('a check with no code is dropped', () {
      const raw = '<<<CHECKS\nCHECK: empty\nCHECK: blank\n\n   \nCHECK: real\nassert True\nCHECKS>>>';
      final r = splitNotesAndChecks('# T\n$raw');
      expect(r.checks.map((c) => c.title), ['real']);
    });

    test('CRLF line endings', () {
      const raw = '# T\r\n\r\nBody.\r\n<<<CHECKS\r\nCHECK: A\r\nassert True\r\n'
          'if True:\r\n    assert 1\r\nCHECKS>>>\r\n';
      final r = splitNotesAndChecks(raw);
      expect(r.checks, hasLength(1));
      expect(r.checks.single.title, 'A');
      expect(r.checks.single.code, 'assert True\nif True:\n    assert 1');
      expect(r.checks.single.code, isNot(contains('\r')));
    });

    test('CRLF with a fence before the marker', () {
      const raw = '# T\r\n\r\nBody.\r\n```python\r\n<<<CHECKS\r\nCHECK: A\r\nassert True\r\nCHECKS>>>\r\n```\r\n';
      final r = splitNotesAndChecks(raw);
      expect(r.notes, isNot(contains('```')));
      expect(r.checks, hasLength(1));
    });

    test('text after the end marker is ignored', () {
      const raw = '# T\n<<<CHECKS\nCHECK: A\nassert True\nCHECKS>>>\nThanks!\nCHECK: ghost\nassert False';
      final r = splitNotesAndChecks(raw);
      expect(r.checks, hasLength(1));
    });

    test('a closed code fence that ends the notes keeps its closing fence', () {
      // The fence before the marker is only the checks block's own when it is
      // an opening one; here it closes a fence that belongs to the notes.
      const raw = '# T\n\n```python\nprint(1)\n```\n\n<<<CHECKS\nCHECK: A\nassert True\nCHECKS>>>';
      final r = splitNotesAndChecks(raw);
      expect(r.notes, endsWith('```'));
      expect(r.notes, '# T\n\n```python\nprint(1)\n```');
    });

    test('notes containing a code fence of their own are kept', () {
      const raw = '# T\n\n```python\nprint(1)\n```\n\nMore text.\n<<<CHECKS\nCHECK: A\nassert True\nCHECKS>>>';
      final r = splitNotesAndChecks(raw);
      expect(r.notes, contains('print(1)'));
      expect(r.notes, contains('More text.'));
    });
  });

  group('parseChecks', () {
    test('indentation inside a check is preserved', () {
      const block = 'CHECK: loop\n'
          'x = symbols("x")\n'
          'for v in [1, 2]:\n'
          '    if v > 1:\n'
          '        assert v == 2\n';
      final c = parseChecks(block).single;
      expect(c.code.split('\n'), [
        'x = symbols("x")',
        'for v in [1, 2]:',
        '    if v > 1:',
        '        assert v == 2',
      ]);
    });

    test('indentation of the first code line is preserved', () {
      final c = parseChecks('CHECK: a\n    assert True\n').single;
      expect(c.code, '    assert True');
    });

    test('indented CHECK line is not a header', () {
      final c = parseChecks('CHECK: a\nx = 1\n  CHECK: b\nassert x\n').single;
      expect(c.code, contains('CHECK: b'));
    });

    test('missing title gets a numbered default', () {
      final r = parseChecks('CHECK: first\nassert True\nCHECK:\nassert 1\n');
      expect(r[1].title, 'Check 2');
    });

    test('blank lines inside code are kept, outer ones trimmed', () {
      final c = parseChecks('CHECK: a\n\na = 1\n\nassert a\n\n').single;
      expect(c.code, 'a = 1\n\nassert a');
    });
  });

  group('formatChecks', () {
    const checks = [
      MathCheck(title: 'One', code: 'x = 1\nassert x == 1'),
      MathCheck(
          title: 'Two', code: 'for i in range(2):\n    assert i < 2'),
    ];

    test('round trip parseChecks(formatChecks(x))', () {
      final back = parseChecks(formatChecks(checks)
          .replaceFirst(checksOpen, '')
          .replaceFirst(checksClose, ''));
      expect(back.length, 2);
      for (var i = 0; i < 2; i++) {
        expect(back[i].title, checks[i].title);
        expect(back[i].code, checks[i].code);
      }
    });

    test('round trip through splitNotesAndChecks', () {
      final raw = '# T\n\nBody\n\n${formatChecks(checks)}';
      final r = splitNotesAndChecks(raw);
      expect(r.notes, '# T\n\nBody');
      expect(r.checks.map((c) => c.code), checks.map((c) => c.code));
      expect(r.checks.map((c) => c.title), checks.map((c) => c.title));
    });

    test('has both markers', () {
      final s = formatChecks(checks);
      expect(s, startsWith('<<<CHECKS\n'));
      expect(s, endsWith('CHECKS>>>'));
    });

    test('empty list parses back to nothing', () {
      expect(splitNotesAndChecks('# T\n${formatChecks(const [])}').checks,
          isEmpty);
    });
  });

  group('formatFailures', () {
    const checks = [
      MathCheck(title: 'A', code: 'assert 1 == 1'),
      MathCheck(title: 'B', code: 'assert 1 == 2'),
      MathCheck(title: 'C', code: 'bad syntax'),
      MathCheck(title: 'D', code: 'assert 2 == 3'),
    ];
    const outcomes = [
      CheckOutcome(title: 'A', status: CheckStatus.passed),
      CheckOutcome(
          title: 'B',
          status: CheckStatus.failed,
          detail: 'assertion failed at `assert 1 == 2`'),
      CheckOutcome(
          title: 'C', status: CheckStatus.error, detail: 'SyntaxError'),
      CheckOutcome(title: 'D', status: CheckStatus.failed),
    ];

    test('lists only failed checks with their result text', () {
      final s = formatFailures(checks, outcomes);
      expect(s, contains('CHECK: B'));
      expect(s, contains('assert 1 == 2'));
      expect(s, contains('RESULT: assertion failed at `assert 1 == 2`'));
      expect(s, contains('CHECK: D'));
      expect(s, contains('RESULT: assertion failed'));
      expect(s, isNot(contains('CHECK: A')));
      expect(s, isNot(contains('CHECK: C')));
      expect(s, isNot(contains('SyntaxError')));
    });

    test('nothing failed gives an empty string', () {
      expect(
          formatFailures(
              checks.take(1).toList(), outcomes.take(1).toList()),
          '');
    });

    test('mismatched lengths do not throw', () {
      expect(() => formatFailures(checks, outcomes.take(2).toList()),
          returnsNormally);
    });
  });
}
