import 'package:flutter_test/flutter_test.dart';
import 'package:learnmath/exercises/exercise_parser.dart';

const _head = '# Compactness\n\n## Definitions\n\nText with a list:\n\n1. not an exercise\n\n';

void main() {
  test('no exercises section', () {
    expect(parseExercises('# T\n\n## Intro\n\n1. a\n2. b'), isEmpty);
    expect(parseExercises(''), isEmpty);
  });

  test('numbered list, "1." and "1)", heading case-insensitive', () {
    final md = '$_head## EXERCISES\n\n1. Show that \$[0,1]\$ is compact.\n2. Is \$\\mathbb{R}\$ compact?\n';
    expect(parseExercises(md), [
      r'Show that $[0,1]$ is compact.',
      r'Is $\mathbb{R}$ compact?',
    ]);
    expect(parseExercises('## Exercise\n\n1) A\n2) B'), ['A', 'B']);
    expect(parseExercises('### Problems\n\n1. A'), ['A']);
  });

  test('bulleted list', () {
    expect(parseExercises('## Exercises\n\n- First\n* Second\n+ Third'),
        ['First', 'Second', 'Third']);
  });

  test('bold labels with text on following paragraphs', () {
    final md = '## Exercises\n\n**Exercise 1.** Prove it.\n\nSecond paragraph.\n\n'
        '**2.** Another one.\n\n**Exercise 3 (Cantor).** Last.';
    final r = parseExercises(md);
    expect(r.length, 3);
    expect(r[0], '**Exercise 1.** Prove it.\n\nSecond paragraph.');
    expect(r[1], '**2.** Another one.');
    expect(r[2], startsWith('**Exercise 3 (Cantor).**'));
  });

  test('multi-paragraph exercise with display math and numbered-looking lines', () {
    final md = '## Exercises\n\n1. Let \$f\$ be given by\n\n   \$\$\n   1. x\n   f(x) = x^2\n   \$\$\n\n   Compute \$f\'\$.\n2. Next.\n';
    final r = parseExercises(md);
    expect(r.length, 2);
    expect(r[0], contains(r'f(x) = x^2'));
    expect(r[0], contains('1. x'));
    expect(r[0], contains("Compute \$f'\$."));
    expect(r[1], 'Next.');
  });

  test('sub-parts belong to their exercise', () {
    final md = '## Exercises\n\n1. Let \$A\$ be a matrix.\n   (a) Compute \$\\det A\$.\n   (b) Find the eigenvalues.\n2. Show:\n   - (a) one\n   - (b) two\n3. Done.\n';
    final r = parseExercises(md);
    expect(r.length, 3);
    expect(r[0], contains('(a) Compute'));
    expect(r[0], contains('(b) Find'));
    expect(r[1], contains('(b) two'));
    expect(r[2], 'Done.');
  });

  test('stops at the next section', () {
    final md = '## Exercises\n\n1. A\n2. B\n\n## References\n\n1. Rudin\n';
    expect(parseExercises(md), ['A', 'B']);
  });

  test('introductory sentence is not an exercise', () {
    expect(parseExercises('## Exercises\n\nSolve these.\n\n1. A\n2. B'), ['A', 'B']);
  });
}
