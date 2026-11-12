import 'package:flutter_test/flutter_test.dart';
import 'package:learnmath/ai/narration_parser.dart';

void main() {
  group('parseNarration', () {
    test('well-formed input', () {
      final segs = parseNarration('''
SECTION: Intro
SAY: Hello there.
SHOW: \$x\$
PAUSE: 2
SAY: Second one.
SECTION: Next
SAY: Third.
PAUSE: 0
''');
      expect(segs.length, 3);
      expect(segs[0].section, 'Intro');
      expect(segs[0].show, r'$x$');
      expect(segs[0].pauseMs, 2000);
      expect(segs[1].section, isNull);
      expect(segs[1].pauseMs, 350);
      expect(segs[2].section, 'Next');
      expect(segs[2].pauseMs, 0);
    });

    test('sloppy input: decoration, case, fences, continuation', () {
      final segs = parseNarration('''
```
**Section:** One
- **SAY:** First line
  continues here.
- say: Second.
  **SHOW:** \$a\$
  and more
Pause: 2.5s
```
''');
      expect(segs.length, 2);
      expect(segs[0].say, 'First line continues here.');
      expect(segs[0].section, 'One');
      expect(segs[1].show, r'$a$ and more');
      expect(segs[1].pauseMs, 2500);
    });

    test('pause formats and clamping', () {
      int p(String v) =>
          parseNarration('SAY: a\nPAUSE: $v').first.pauseMs;
      expect(p('2'), 2000);
      expect(p('2.5s'), 2500);
      expect(p('2 seconds'), 2000);
      expect(p('99'), 10000);
      expect(p('abc'), 350);
    });

    test('empty SAY dropped, section carried over', () {
      final segs = parseNarration('SECTION: A\nSAY:\nSAY: Real.');
      expect(segs.length, 1);
      expect(segs.single.section, 'A');
    });

    test('fallback to sentences', () {
      final segs = parseNarration('This is one. This is two! And three?');
      expect(segs.map((s) => s.say), ['This is one.', 'This is two!', 'And three?']);
    });

    test('long SAY is split, pause on last, show dropped', () {
      final sentence = List.filled(20, 'word').join(' ');
      final long = '$sentence. $sentence. $sentence.';
      final segs = parseNarration(
          'SECTION: S\nSAY: $long\nSHOW: \$x\$\nPAUSE: 3');
      expect(segs.length, greaterThan(1));
      expect(segs.first.section, 'S');
      expect(segs.last.section, isNull);
      expect(segs.last.pauseMs, 3000);
      expect(segs.first.pauseMs, 350);
      expect(segs.every((s) => s.show == null), isTrue);
      expect(segs.every((s) => s.say.split(' ').length <= 45), isTrue);
    });
  });

  group('parseOutline', () {
    test('well-formed', () {
      final o = parseOutline('''
COURSE: Measure Theory
DESCRIPTION: A course.
LESSON: Sigma algebras
BRIEF: Basics.
LESSON: Measures
BRIEF: More basics.
''');
      expect(o.title, 'Measure Theory');
      expect(o.description, 'A course.');
      expect(o.lessons.length, 2);
      expect(o.lessons[1].title, 'Measures');
      expect(o.lessons[1].brief, 'More basics.');
    });

    test('sloppy', () {
      final o = parseOutline('''
```
**COURSE:** X
**Description:** d
1. skip
**LESSON 1:** A
**BRIEF:** b1
 continued
- Lesson 2: B
''');
      expect(o.title, 'X');
      expect(o.lessons.map((l) => l.title), ['A', 'B']);
      expect(o.lessons[0].brief, 'b1 continued');
      expect(o.lessons[1].brief, '');
    });

    test('throws without lessons', () {
      expect(() => parseOutline('COURSE: X\nnothing'), throwsFormatException);
    });
  });

  group('cleanNotes', () {
    test('strips fence', () {
      expect(cleanNotes('```markdown\n# T\n\ntext\n```\n'), '# T\n\ntext');
    });
    test('converts delimiters', () {
      final out = cleanNotes(r'Let \(x\in A\). Then \[ x^2 \] holds.');
      expect(out, contains(r'$x\in A$'));
      expect(out, contains('\n\$\$\nx^2\n\$\$\n'));
    });
    test('leaves row spacing alone', () {
      expect(cleanNotes(r'$$a \\[2pt] b$$'), r'$$a \\[2pt] b$$');
    });
  });
}
