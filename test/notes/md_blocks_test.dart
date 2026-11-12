import 'package:flutter_test/flutter_test.dart';
import 'package:learnmath/notes/md_blocks.dart';

import 'sample.dart';

void main() {
  test('inline vs display math', () {
    final b = parseMarkdownBlocks('Text \$x^2\$ more.\n\n\$\$\\int f\$\$\n');
    expect(b.length, 2);
    final p = b[0] as ParagraphBlock;
    expect(p.inlines.map((e) => e.kind), [InlineKind.text, InlineKind.math, InlineKind.text]);
    expect(p.inlines[1].text, 'x^2');
    expect((b[1] as DisplayMathBlock).tex, '\\int f');
  });

  test('multi-line \$\$ block keeps newlines and ends paragraph', () {
    final b = parseMarkdownBlocks('before\n\$\$\na &= b \\\\\n&= c\n\$\$\nafter');
    expect(b.length, 3);
    expect(b[0], isA<ParagraphBlock>());
    expect((b[1] as DisplayMathBlock).tex, 'a &= b \\\\\n&= c');
    expect(b[2], isA<ParagraphBlock>());
  });

  test('dollar inside code is not math', () {
    final i = parseInlines('use `\$x\$ and \$y\$` here');
    expect(i.where((e) => e.kind == InlineKind.math), isEmpty);
    expect(i[1], const Inline.code('\$x\$ and \$y\$'));
    final b = parseMarkdownBlocks('```\n\$\$ not math \$\$\n```');
    expect((b.single as CodeBlock).code, '\$\$ not math \$\$');
  });

  test('escaped dollar and prices', () {
    final i = parseInlines(r'costs \$5 and \$6');
    expect(i.single.text, r'costs $5 and $6');
    expect(i.single.kind, InlineKind.text);
    final j = parseInlines(r'it costs $5 and then');
    expect(j.where((e) => e.kind == InlineKind.math), isEmpty);
  });

  test('display math inline in paragraph splits it', () {
    final b = parseMarkdownBlocks(r'so $$x=1$$ done');
    expect(b.map((e) => e.runtimeType), [ParagraphBlock, DisplayMathBlock, ParagraphBlock]);
  });

  test('headings', () {
    final b = parseMarkdownBlocks('# A *b*\n### C ##');
    expect((b[0] as HeadingBlock).level, 1);
    expect((b[1] as HeadingBlock).level, 3);
    expect((b[1] as HeadingBlock).inlines.single.text, 'C');
  });

  test('lists, nested and numbered', () {
    final b = parseMarkdownBlocks('- a\n- b\n  - c\n  - d\n- e\n\n3. x\n4. y');
    final l = b[0] as ListBlock;
    expect(l.ordered, isFalse);
    expect(l.items.length, 3);
    expect((l.items[1].children.single as ListBlock).items.length, 2);
    final o = b[1] as ListBlock;
    expect(o.ordered, isTrue);
    expect(o.start, 3);
    expect(o.items.length, 2);
  });

  test('bullet directly followed by ordered list yields two lists', () {
    final b = parseMarkdownBlocks('- Item\n1. Num');
    expect(b.length, 2);
  });

  test('nested emphasis', () {
    final i = parseInlines('**bold *both* bold** and ***all***');
    expect(i[0], const Inline.text('bold ', bold: true));
    expect(i[1], const Inline.text('both', bold: true, italic: true));
    expect(i[2], const Inline.text(' bold', bold: true));
    expect(i[3], const Inline.text(' and '));
    expect(i[4], const Inline.text('all', bold: true, italic: true));
  });

  test('math is not eaten by emphasis and underscores in math are safe', () {
    final i = parseInlines(r'a $x_1 * y_2$ b *c*');
    expect(i[1], const Inline.math(r'x_1 * y_2'));
    expect(i.last, const Inline.text('c', italic: true));
    expect(parseInlines('snake_case_name').single.text, 'snake_case_name');
    expect(parseInlines('2 * 3 * 4').single.text, '2 * 3 * 4');
  });

  test('quote, rule, table, links', () {
    final b = parseMarkdownBlocks('> q \$x\$\n\n---\n\n| a | b |\n|---|:-:|\n| 1 | \$a|b\$ |\n\n[t](http://x) y');
    expect(b[0], isA<QuoteBlock>());
    expect(b[1], isA<RuleBlock>());
    final t = b[2] as TableBlock;
    expect(t.header.length, 2);
    expect(t.rows.single[1].single, const Inline.math('a|b'));
    expect(((b[3] as ParagraphBlock).inlines.first).text, 't y');
  });

  test('sample document', () {
    final b = parseMarkdownBlocks(sampleNotes);
    expect(b.whereType<HeadingBlock>().length, 2);
    expect(b.whereType<DisplayMathBlock>().length, 1);
    expect(b.whereType<ListBlock>().length, 2);
    final def = b[2] as ParagraphBlock;
    expect(def.inlines.first, const Inline.text('Definition 1.1.', bold: true));
    expect(def.inlines.where((e) => e.kind == InlineKind.math).length, 3);
    expect(def.inlines.any((e) => e.text == 'compact' && e.italic), isTrue);
  });
}
