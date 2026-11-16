import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:learnmath/player/subtitle_text.dart';

void main() {
  testWidgets('current subtitle style is white and bold, math included', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SubtitleText(
              r'Let $x$ be a point',
              style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w700,
                fontSize: 20,
              ),
            ),
          ),
        ),
      ),
    );

    final richText = tester.widget<RichText>(
      find.descendant(
        of: find.byType(SubtitleText),
        matching: find.byType(RichText),
      ).first,
    );
    // Text.rich wraps the spans in a root span that carries the theme's
    // default style; the style passed to SubtitleText sits on its child.
    final root = richText.text as TextSpan;
    final styled = root.children!.whereType<TextSpan>().first;
    expect(styled.style?.color, Colors.white);
    expect(styled.style?.fontWeight, FontWeight.w700);
  });
}
