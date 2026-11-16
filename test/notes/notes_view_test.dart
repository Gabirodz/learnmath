import 'package:flutter/material.dart';
import 'package:flutter_math_fork/flutter_math.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:learnmath/notes/notes_view.dart';

import 'sample.dart';

Future<void> pump(WidgetTester tester, String md,
    {Size size = const Size(320, 640),
    ThemeMode mode = ThemeMode.light,
    double textScale = 1.0}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(
    themeMode: mode,
    theme: ThemeData(colorSchemeSeed: Colors.indigo),
    darkTheme: ThemeData(colorSchemeSeed: Colors.indigo, brightness: Brightness.dark),
    home: MediaQuery(
      data: MediaQueryData(size: size, textScaler: TextScaler.linear(textScale)),
      child: Scaffold(body: NotesView(markdown: md)),
    ),
  ));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('renders sample on 320px without exceptions', (tester) async {
    await pump(tester, sampleNotes);
    expect(tester.takeException(), isNull);
    expect(find.byType(Math), findsWidgets);
    expect(find.textContaining('Compactness'), findsOneWidget);
  });

  testWidgets('wide display, invalid formula, dark mode, large text scale',
      (tester) async {
    for (final mode in [ThemeMode.light, ThemeMode.dark]) {
      await pump(tester, sampleNotesHard, mode: mode, textScale: 1.6);
      expect(tester.takeException(), isNull);
    }
    // Wide display equation lives in a horizontal scroll view of its own.
    final scrolls = find.byWidgetPredicate((w) =>
        w is SingleChildScrollView && w.scrollDirection == Axis.horizontal);
    expect(scrolls, findsWidgets);
    // Page itself never scrolls sideways: horizontal extents stay within 320px.
    final root = tester.getRect(find.byType(NotesView));
    expect(root.width, 320);
    // Invalid formulas degrade to raw TeX text, no red error widgets.
    expect(find.textContaining('notacommand'), findsWidgets);
    expect(find.textContaining('ParseException'), findsNothing);
  });

  testWidgets('wide screen caps line length to 720', (tester) async {
    await pump(tester, sampleNotes, size: const Size(1400, 800));
    expect(tester.takeException(), isNull);
    final t = tester.getRect(find.textContaining('Compactness'));
    expect(t.width <= 720, isTrue);
  });

  group('colour-coded environments', () {
    List<(NoteKind?, int)> shape(String md) => [
          for (final g in groupNoteBlocks(splitSourceBlocks(md)))
            (g.kind, g.blocks.length)
        ];

    test('a definition keeps its formula and the sentence that goes on', () {
      const md = '**Definition.** A sequence is Cauchy if:\n\n'
          '\$\$\n|a_m - a_n| < \\varepsilon\n\$\$\n\n'
          'for all large \$m, n\$.\n\n'
          'A metric space is complete if every Cauchy sequence converges.';
      // The labelled paragraph and its formula are already one block.
      expect(shape(md), [(NoteKind.definition, 2), (null, 1)]);
    });

    test('a proof runs to its end mark, then prose follows', () {
      const md = '**Theorem 2 (Heine-Borel).** Closed and bounded is compact.'
          '\n\n**Proof.** Take a cover.\n\nRefine it.\n\n'
          'So it is finite. \$\\blacksquare\$\n\nNext we look at examples.';
      expect(shape(md), [
        (NoteKind.theorem, 1),
        (NoteKind.proof, 3),
        (null, 1),
      ]);
    });

    test('an example runs to the next heading; a heading ends anything', () {
      const md = '**Example.** Take \$x = 1\$.\n\nThen \$x^2 = 1\$.\n\n'
          '## Summary\n\n**Proof sketch.** Without an end mark.\n\n'
          'Still the proof.\n\n## Exercises';
      expect(shape(md), [
        (NoteKind.example, 2),
        (null, 1),
        (NoteKind.proof, 2),
        (null, 1),
      ]);
    });

    test('labels are recognised in their usual forms', () {
      expect(noteKindOf('**Lemma 3.1.** Text'), NoteKind.theorem);
      expect(noteKindOf('**Corollary.** Text'), NoteKind.theorem);
      expect(noteKindOf('__Proposition.__ Text'), NoteKind.theorem);
      expect(noteKindOf('**Non-example.** Text'), NoteKind.example);
      expect(noteKindOf('**Counterexample.** Text'), NoteKind.example);
      expect(noteKindOf('**Remark (intuition).** Text'), NoteKind.remark);
      expect(noteKindOf('**Notation.** Text'), NoteKind.definition);
      expect(noteKindOf('**Theorems** are useful.'), isNull);
      expect(noteKindOf('The theorem says.'), isNull);
      expect(noteKindOf('**Important.** Text'), isNull);
    });

    test('a statement ending in a colon keeps its list', () {
      const md = '**Theorem.** The following are equivalent:\n\n'
          '1. \$K\$ is compact.\n2. \$K\$ is closed and bounded.\n\n'
          'We prove it in two steps.';
      expect(shape(md), [(NoteKind.theorem, 2), (null, 1)]);
    });

    testWidgets('the notes show each environment in its box', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: NotesView(
            markdown: '# T\n\n**Definition.** A thing.\n\n**Theorem.** A '
                'fact.\n\n**Proof.** Easy. \$\\blacksquare\$\n\nProse.',
            onAskAbout: (_) {},
          ),
        ),
      ));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(
          tester.widgetList<NoteBox>(find.byType(NoteBox)).map((b) => b.kind),
          [NoteKind.definition, NoteKind.theorem, NoteKind.proof]);
    });
  });
}
