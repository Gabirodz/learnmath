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
}
