import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:learnmath/checks/proof_review.dart';
import 'package:learnmath/checks/review_banner.dart';

Future<void> _pump(WidgetTester tester, ProofReview? review,
    {double width = 320}) async {
  tester.view.physicalSize = Size(width, 640);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(
    theme: ThemeData(colorSchemeSeed: Colors.indigo),
    home: Scaffold(body: Column(children: [ReviewBanner(review: review)])),
  ));
}

void main() {
  testWidgets('nothing without a review', (tester) async {
    await _pump(tester, null);
    expect(find.byType(Text), findsNothing);
    expect(find.byType(ExpansionTile), findsNothing);
  });

  testWidgets('a quiet line while the review is running', (tester) async {
    for (final s in [
      ProofReviewState.toVerify,
      ProofReviewState.raw,
      ProofReviewState.confirmed,
    ]) {
      await _pump(tester, ProofReview(state: s, issues: const [
        ProofIssue(summary: 'not shown yet'),
      ]));
      expect(find.text('A second model is reviewing the proofs…'),
          findsOneWidget);
      expect(find.textContaining('not shown yet'), findsNothing);
      expect(find.byType(ExpansionTile), findsNothing);
    }
  });

  testWidgets('done without issues, with and without a correction',
      (tester) async {
    await _pump(tester, const ProofReview(state: ProofReviewState.done));
    expect(find.text('Proofs reviewed by a second model: no errors found'),
        findsOneWidget);
    await _pump(
        tester, const ProofReview(state: ProofReviewState.done, round: 1));
    expect(
        find.text('Proofs reviewed by a second model: no errors found, '
            'after one correction'),
        findsOneWidget);
    expect(find.byType(ExpansionTile), findsNothing);
  });

  testWidgets('done with issues: expandable warning with details',
      (tester) async {
    await _pump(
        tester,
        const ProofReview(state: ProofReviewState.done, issues: [
          ProofIssue(
              summary: 'Lemma 1 lacks compactness',
              where: 'Lemma 1',
              why: 'Fails on R.',
              fix: 'Assume K compact.'),
          ProofIssue(summary: 'Bare issue'),
        ]));
    expect(find.text('2 possible errors found by a second model'),
        findsOneWidget);
    expect(find.text('Verify these against a textbook before relying on them.'),
        findsOneWidget);
    expect(find.textContaining('Lemma 1 lacks compactness'), findsNothing,
        reason: 'collapsed');

    await tester.tap(find.byType(ExpansionTile));
    await tester.pumpAndSettle();

    final rich = tester
        .widgetList<RichText>(find.byType(RichText))
        .map((r) => r.text.toPlainText())
        .toList();
    expect(rich, contains('Lemma 1 lacks compactness\nWhere: Lemma 1\n'
        'Why: Fails on R.\nFix: Assume K compact.'));
    expect(rich, contains('Bare issue'), reason: 'empty fields are omitted');
    TextSpan? summary;
    for (final r in tester.widgetList<RichText>(find.byType(RichText))) {
      r.text.visitChildren((span) {
        if (span is TextSpan && span.text == 'Lemma 1 lacks compactness') {
          summary = span;
        }
        return true;
      });
    }
    expect(summary?.style?.fontWeight, FontWeight.bold);
  });

  testWidgets('singular title and the rewritten subtitle', (tester) async {
    await _pump(
        tester,
        const ProofReview(
            state: ProofReviewState.done,
            round: 1,
            issues: [ProofIssue(summary: 'x')]));
    expect(find.text('1 possible error found by a second model'),
        findsOneWidget);
    expect(find.text('The notes were corrected once; these remain.'),
        findsOneWidget);
    expect(find.textContaining('textbook'), findsNothing);
  });

  testWidgets('no overflow at 320 px in any state, even expanded',
      (tester) async {
    final long = 'a very long statement ' * 12;
    final states = <ProofReview?>[
      null,
      const ProofReview(state: ProofReviewState.raw),
      const ProofReview(state: ProofReviewState.done, round: 1),
      ProofReview(state: ProofReviewState.done, round: 1, issues: [
        ProofIssue(summary: long, where: long, why: long, fix: long),
        ProofIssue(summary: long),
      ]),
    ];
    for (final r in states) {
      await _pump(tester, r);
      if (find.byType(ExpansionTile).evaluate().isNotEmpty) {
        await tester.tap(find.byType(ExpansionTile));
        await tester.pumpAndSettle();
      }
      expect(tester.takeException(), isNull);
    }
  });
}
