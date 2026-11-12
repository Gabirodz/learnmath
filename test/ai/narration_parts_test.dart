import 'package:flutter_test/flutter_test.dart';
import 'package:learnmath/ai/narration_parts.dart';
import 'package:learnmath/books/transcriber.dart';

void main() {
  test('stripPageMarkers removes marker lines only', () {
    const md = '[[page 12]]\n\nText with [[page 3]] inline.\n\n[[page 13]]\n\nMore.';
    expect(stripPageMarkers(md).trim(),
        'Text with [[page 3]] inline.\n\nMore.');
  });

  test('short text is one part with its headings', () {
    final parts = splitForNarration('# Title\n\nIntro.\n\n## 1.1 Sets\n\nBody.');
    expect(parts, hasLength(1));
    expect(parts.single.sections, ['Title', '1.1 Sets']);
  });

  test('long text is cut at headings and never inside display math', () {
    final para = '${'word ' * 60}\n\n';
    final md = StringBuffer();
    for (var s = 1; s <= 6; s++) {
      md.write('## Section $s\n\n');
      md.write(para * 4);
      md.write('\$\$\na = b\n\nc = d\n\$\$\n\n');
    }
    final parts = splitForNarration(md.toString(), maxChars: 3000);
    expect(parts.length, greaterThan(2));
    for (final p in parts) {
      expect(p.text.length, lessThan(4500));
      expect(r'$$'.allMatches(p.text).length.isEven, isTrue,
          reason: 'display math kept whole');
      expect(p.text.trimLeft().startsWith('## Section'), isTrue);
    }
    expect(parts.expand((p) => p.sections).toList(),
        [for (var s = 1; s <= 6; s++) 'Section $s']);
    // Nothing lost.
    final words = RegExp('word').allMatches(md.toString()).length;
    expect(
        parts.fold<int>(
            0, (n, p) => n + RegExp('word').allMatches(p.text).length),
        words);
  });

  test('text without headings is cut between paragraphs', () {
    final md = List.filled(40, 'word ' * 50).join('\n\n');
    final parts = splitForNarration(md, maxChars: 2000);
    expect(parts.length, greaterThan(3));
    expect(parts.every((p) => p.text.length <= 2000 * 1.3), isTrue);
  });

  test('cutAtHeading drops the next chapter only near the end', () {
    final body = List.filled(30, 'Some paragraph.').join('\n\n');
    final md = '# 2 Compactness\n\nSee Chapter 3 Connectedness later.\n\n'
        '$body\n\n## 3 Connectedness\n\nShould go.';
    final cut = cutAtHeading(md, '3 Connectedness');
    expect(cut.contains('Should go'), isFalse);
    expect(cut.contains('See Chapter 3 Connectedness later'), isTrue);
    expect(cutAtHeading(md, null), md);
    expect(cutAtHeading(md, 'Not there'), md);
  });
}
