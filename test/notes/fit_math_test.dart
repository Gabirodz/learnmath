import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:learnmath/notes/fit_math.dart';
import 'package:learnmath/player/subtitle_text.dart';

const _long = r'E \neq \emptyset,\ E \text{ bounded above} \Longrightarrow '
    r'\sup E \text{ exists} = a + b + c';
const _style = TextStyle(fontSize: 20);

Future<Size> _size(WidgetTester tester, double? width) async {
  await tester.pumpWidget(MaterialApp(
    home: Align(
      alignment: Alignment.topLeft,
      child: SizedBox(
        width: width,
        child: Align(
          alignment: Alignment.topLeft,
          child: FitMath(_long, textStyle: _style, textScaleFactor: 1),
        ),
      ),
    ),
  ));
  expect(tester.takeException(), isNull);
  return tester.getSize(find.byType(FitMath));
}

void main() {
  testWidgets('a formula that fits is drawn at full size', (tester) async {
    final natural = await _size(tester, null);
    final roomy = await _size(tester, natural.width + 50);
    expect(roomy.width, closeTo(natural.width, 0.5));
    expect(roomy.height, closeTo(natural.height, 0.5));
  });

  testWidgets('a little too wide: shrunk onto one line', (tester) async {
    final natural = await _size(tester, null);
    final w = natural.width * 0.85;
    final s = await _size(tester, w);
    expect(s.width, lessThanOrEqualTo(w + 0.01));
    expect(s.height, closeTo(natural.height * 0.85, 1));
  });

  testWidgets('far too wide: smallest size, broken into lines',
      (tester) async {
    final natural = await _size(tester, null);
    final w = natural.width * 0.4;
    final s = await _size(tester, w);
    expect(s.width, lessThanOrEqualTo(w + 0.01));
    // Several lines at 70 %: taller than one line at full size.
    expect(s.height, greaterThan(natural.height * 1.2));
  });

  testWidgets('a formula that does not parse shows the fallback',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: FitMath(r'\frac{a', textStyle: _style,
          onErrorFallback: (_) => const Text('raw')),
    ));
    expect(find.text('raw'), findsOneWidget);
  });

  testWidgets('a long formula in a subtitle stays inside its width',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Center(
        child: SizedBox(
          width: 280,
          child: SubtitleText('Then \$$_long\$ follows.', style: _style),
        ),
      ),
    ));
    expect(tester.takeException(), isNull);
    final fit = tester.getRect(find.byType(FitMath));
    final text = tester.getRect(find.byType(SubtitleText));
    expect(fit.left, greaterThanOrEqualTo(text.left - 0.5));
    expect(fit.right, lessThanOrEqualTo(text.right + 0.5));
  });

  testWidgets('a screen reader gets the formula once', (tester) async {
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(MaterialApp(
      home: Center(
        child: SizedBox(
            width: 2000,
            child: FitMath(r'x = 1', textStyle: _style, textScaleFactor: 1)),
      ),
    ));
    // Each symbol is its own node: the whole formula and its pieces would
    // give two "=".
    expect(find.bySemanticsLabel('='), findsOneWidget);
    handle.dispose();
  });
}
