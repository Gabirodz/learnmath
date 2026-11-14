import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:learnmath/checks/proof_review.dart';

void main() {
  group('parseIssues', () {
    test('NO ISSUES gives an empty list', () {
      expect(parseIssues('NO ISSUES'), isEmpty);
      expect(parseIssues('  NO ISSUES\n'), isEmpty);
      expect(parseIssues(''), isEmpty);
    });

    test('several issues with all four fields', () {
      final issues = parseIssues('ISSUE: Lemma 1 lacks compactness\n'
          'WHERE: Lemma 1\n'
          'WHY: Counterexample on R.\n'
          'FIX: Assume K compact.\n'
          '\n'
          'ISSUE: Step 3 is circular\n'
          'WHERE: Proof of Theorem 2\n'
          'WHY: Uses the claim.\n'
          'FIX: Prove it first.');
      expect(issues, hasLength(2));
      expect(issues[0].summary, 'Lemma 1 lacks compactness');
      expect(issues[0].where, 'Lemma 1');
      expect(issues[0].why, 'Counterexample on R.');
      expect(issues[0].fix, 'Assume K compact.');
      expect(issues[1].summary, 'Step 3 is circular');
      expect(issues[1].fix, 'Prove it first.');
    });

    test('continuation lines extend the last field', () {
      final issues = parseIssues('ISSUE: Wrong bound\n'
          'WHERE: Theorem 1\n'
          'WHY: The estimate gives\n'
          '  n/2, not n,\n'
          'so the claim fails.\n'
          'FIX: Use n/2.');
      expect(issues.single.why, 'The estimate gives n/2, not n, so the claim fails.');
      expect(issues.single.fix, 'Use n/2.');
    });

    test('numbered, bold and bulleted keys', () {
      final issues = parseIssues('**ISSUE 1:** First\n'
          '**WHERE:** here\n'
          '- ISSUE: Second\n'
          '- WHY: because\n'
          '3. ISSUE: Third\n'
          '   FIX: do this');
      expect(issues.map((i) => i.summary), ['First', 'Second', 'Third']);
      expect(issues[0].where, 'here');
      expect(issues[1].why, 'because');
      expect(issues[2].fix, 'do this');
    });

    // SUSPECTED BUG (lib/checks/proof_review.dart:134, the `key` regex): the
    // bold markers may not close before the colon, so `**ISSUE 4**: text`
    // is not recognised and the whole issue is silently dropped.
    test('bold key closed before the colon', () {
      final issues = parseIssues('**ISSUE 4**: Fourth\n**WHERE**: here');
      expect(issues.map((i) => i.summary), ['Fourth']);
    });

    test('text before the first ISSUE is ignored', () {
      final issues = parseIssues('Here is my report.\nIt is long.\n\n'
          'ISSUE: Only one\nWHY: reason');
      expect(issues.single.summary, 'Only one');
      expect(issues.single.why, 'reason');
    });

    test('an issue without WHERE, WHY and FIX', () {
      final issues = parseIssues('ISSUE: Bare\nISSUE: Also bare');
      expect(issues, hasLength(2));
      expect(issues[0].where, '');
      expect(issues[0].why, '');
      expect(issues[0].fix, '');
    });

    test('fields without any ISSUE give nothing', () {
      expect(parseIssues('WHERE: x\nWHY: y'), isEmpty);
    });
  });

  group('formatIssues', () {
    test('numbers the issues and skips empty fields', () {
      final text = formatIssues(const [
        ProofIssue(summary: 'A', where: 'w', why: 'y', fix: 'f'),
        ProofIssue(summary: 'B'),
      ]);
      expect(text, '1. ISSUE: A\n   WHERE: w\n   WHY: y\n   FIX: f\n2. ISSUE: B');
    });

    test('empty list is empty text', () {
      expect(formatIssues(const []), '');
    });

    test('round trips through parseIssues', () {
      const issues = [
        ProofIssue(summary: 'A', where: 'w', why: 'y', fix: 'f'),
        ProofIssue(summary: 'B', why: 'only why'),
      ];
      final back = parseIssues(formatIssues(issues));
      expect(back.map((i) => i.toJson()), issues.map((i) => i.toJson()));
    });
  });

  group('keepRealIssues', () {
    const issues = [
      ProofIssue(summary: 'one'),
      ProofIssue(summary: 'two'),
      ProofIssue(summary: 'three'),
    ];
    List<String> kept(String v) =>
        keepRealIssues(issues, v).map((i) => i.summary).toList();

    test('drops false alarms and keeps real ones', () {
      expect(
          kept('VERDICT 1: REAL - yes\n'
              'VERDICT 2: FALSE ALARM - no\n'
              'VERDICT 3: REAL - yes'),
          ['one', 'three']);
    });

    test('case-insensitive and tolerant of # and bold', () {
      expect(
          kept('verdict 1: false alarm - x\nVerdict #2: **Real** - y\n'
              'VERDICT 3 - **FALSE ALARM**'),
          ['two']);
    });

    test('a missing verdict keeps the issue', () {
      expect(kept('VERDICT 2: FALSE ALARM - x'), ['one', 'three']);
      expect(kept('no verdicts at all'), ['one', 'two', 'three']);
    });

    test('out-of-range numbers are ignored', () {
      expect(kept('VERDICT 0: FALSE ALARM - x\nVERDICT 9: FALSE ALARM - y'),
          ['one', 'two', 'three']);
    });
  });

  group('ProofReview', () {
    test('JSON round trip', () {
      const review = ProofReview(
        state: ProofReviewState.confirmed,
        issues: [ProofIssue(summary: 's', where: 'w', why: 'y', fix: 'f')],
        round: 1,
        reportOnly: true,
        dismissed: 2,
      );
      final back = ProofReview.fromJson(
          jsonDecode(jsonEncode(review.toJson())))!;
      expect(back.state, ProofReviewState.confirmed);
      expect(back.issues.single.summary, 's');
      expect(back.issues.single.where, 'w');
      expect(back.issues.single.why, 'y');
      expect(back.issues.single.fix, 'f');
      expect(back.round, 1);
      expect(back.reportOnly, isTrue);
      expect(back.dismissed, 2);
      expect(back.rewritten, isTrue);
      expect(back.isDone, isFalse);
    });

    test('fromJson rejects junk and unknown states', () {
      expect(ProofReview.fromJson(null), isNull);
      expect(ProofReview.fromJson('x'), isNull);
      expect(ProofReview.fromJson({'state': 'bogus'}), isNull);
    });

    test('fromJson fills defaults', () {
      final r = ProofReview.fromJson({'state': 'done'})!;
      expect(r.isDone, isTrue);
      expect(r.issues, isEmpty);
      expect(r.round, 0);
      expect(r.reportOnly, isFalse);
      expect(r.dismissed, 0);
    });

    test('copyWith keeps reportOnly', () {
      const r = ProofReview(state: ProofReviewState.toVerify, reportOnly: true);
      expect(r.copyWith(state: ProofReviewState.done).reportOnly, isTrue);
    });
  });
}
