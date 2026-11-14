import 'package:flutter_test/flutter_test.dart';
import 'package:learnmath/ai/prompts.dart';
import 'package:learnmath/exercises/exercise_prompts.dart';

void main() {
  const notes = '# Banach\n\n**Theorem 2.** A contraction has a fixed point.';
  const ex = r'Show that $x \mapsto x/2$ has a fixed point.';

  test('hint prompt has title, notes, exercise, and no checks format', () {
    final m = ExercisePrompts.hintMessages(
        title: 'Banach', notesMarkdown: notes, exercise: ex);
    expect(m.first.role, 'system');
    expect(m.first.content, contains('2 to 4 sentences'));
    expect(m.first.content, isNot(contains('<<<CHECKS')));
    expect(m.last.content, contains('Lesson title: Banach'));
    expect(m.last.content, contains('**Theorem 2.**'));
    expect(m.last.content, contains(ex));
  });

  test('solution prompt carries the checks format', () {
    final m = ExercisePrompts.solutionMessages(
        title: 'Banach', notesMarkdown: notes, exercise: ex);
    expect(m.first.content, contains(Prompts.checksAddendum));
    expect(m.first.content, contains('<<<CHECKS'));
    expect(m.first.content, contains('CHECKS>>>'));
    expect(m.last.content, contains('**Theorem 2.**'));
    expect(m.last.content, contains(ex));
    expect(m.first.content, contains(r'$\blacksquare$'));
  });
}
