import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:learnmath/quiz/quiz_models.dart';
import 'package:learnmath/quiz/quiz_parser.dart';
import 'package:learnmath/quiz/quiz_prompts.dart';

const quizText = 'QUESTION: What is the order of a Sylow \$p\$-subgroup of a group of order \$p^k m\$?\n'
    'TYPE: CHOICE\n'
    'A: \$p\$\n'
    'B: \$p^k\$\n'
    'C: \$m\$\n'
    'D: \$p^k m\$\n'
    'CORRECT: B\n'
    'EXPLAIN: It is the largest power of \$p\$ dividing the order.\n'
    '\n'
    'QUESTION: Why are all Sylow \$p\$-subgroups isomorphic?\n'
    'TYPE: FREE\n'
    'ANSWER: They are conjugate, and conjugation is an isomorphism.\n';

void main() {
  group('parseQuiz', () {
    test('reads a choice and a free question', () {
      final qs = parseQuiz(quizText);
      expect(qs, hasLength(2));
      expect(qs[0].isChoice, isTrue);
      expect(qs[0].options, [r'$p$', r'$p^k$', r'$m$', r'$p^k m$']);
      expect(qs[0].correct, 1);
      expect(qs[0].answer, startsWith('It is the largest'));
      expect(qs[1].isChoice, isFalse);
      expect(qs[1].answer, startsWith('They are conjugate'));
      expect(qs.every((q) => !q.answered), isTrue);
    });

    test('shuffling keeps the key on the right option', () {
      for (var seed = 0; seed < 20; seed++) {
        final q = parseQuiz(quizText, shuffle: Random(seed)).first;
        expect(q.options, hasLength(4));
        expect(q.options[q.correct!], r'$p^k$');
      }
    });

    test('tolerates a code fence, chat text, numbering and decoration', () {
      final qs = parseQuiz('Here is your quiz!\n\n````\n'
          '**QUESTION 1:** Is every group of prime order cyclic?\n'
          'TYPE: choice\n'
          '- A) Yes\n'
          '- B) No\n'
          'Correct: A (by Lagrange)\n'
          'Explanation: Any non-identity element\n'
          'generates the group.\n'
          '````\nGood luck!');
      expect(qs.single.prompt, 'Is every group of prime order cyclic?');
      expect(qs.single.options, ['Yes', 'No']);
      expect(qs.single.correct, 0);
      expect(qs.single.answer,
          'Any non-identity element generates the group.');
    });

    test('drops unusable questions and keeps the rest', () {
      final qs = parseQuiz('QUESTION: No key\nTYPE: CHOICE\nA: x\nB: y\n\n'
          'QUESTION: Bad key\nTYPE: CHOICE\nA: x\nB: y\nCORRECT: D\n\n'
          'QUESTION: No reference\nTYPE: FREE\n\n'
          'QUESTION: Fine\nTYPE: FREE\nANSWER: Because.\n');
      expect(qs.single.prompt, 'Fine');
    });

    test('the key is a letter on its own, not one inside a word', () {
      String quiz(String key) =>
          'QUESTION: Q\nTYPE: CHOICE\nA: w\nB: x\nC: y\nD: z\nCORRECT: $key\n';
      expect(parseQuiz(quiz('The answer is C')).single.correct, 2);
      expect(parseQuiz(quiz('Option D.')).single.correct, 3);
      expect(parseQuiz(quiz('b)')).single.correct, 1);
      // The format description itself, pasted back, is no question.
      expect(() => parseQuiz(quiz('<the letter of the right option>')),
          throwsFormatException);
    });

    test('nothing usable throws', () {
      expect(() => parseQuiz('Sorry, I cannot do that.'),
          throwsFormatException);
    });
  });

  group('parseGrade', () {
    test('verdict and feedback', () {
      final g = parseGrade(
          'VERDICT: PARTIAL\nFEEDBACK: Right idea,\nbut \$p\$ must be prime.');
      expect(g.verdict, Verdict.partial);
      expect(g.feedback, r'Right idea, but $p$ must be prime.');
      expect(parseGrade('**Verdict:** Correct.').verdict, Verdict.correct);
      expect(parseGrade('VERDICT: INCORRECT').verdict, Verdict.wrong);
    });

    test('no verdict throws', () {
      expect(() => parseGrade('Looks good to me'), throwsFormatException);
    });
  });

  group('QuizPrompts', () {
    test('the request carries count, kind, difficulty, notes and what to avoid',
        () {
      final m = QuizPrompts.quizMessages(
        title: 'Sylow',
        notesMarkdown: '# Sylow\n\nNOTES BODY',
        difficulty: QuizDifficulty.hard,
        kind: QuizKind.mixed,
        count: 5,
        avoid: ['Old question?'],
      );
      expect(m.first.content, contains('TYPE: CHOICE'));
      expect(m.last.content, contains('exactly 5 questions'));
      expect(m.last.content, contains('half of TYPE CHOICE'));
      expect(m.last.content, contains('Hard: transfer'));
      expect(m.last.content, contains('NOTES BODY'));
      expect(m.last.content, contains('- Old question?'));
    });

    test('the external prompt is self-contained and asks for a code block',
        () {
      final p = QuizPrompts.external(
        title: 'Sylow',
        notesMarkdown: 'NOTES BODY',
        difficulty: QuizDifficulty.easy,
        kind: QuizKind.choice,
        count: 3,
      );
      expect(p, contains('ONE code block'));
      expect(p, contains('exactly 3 questions'));
      expect(p, contains('all of TYPE CHOICE'));
      expect(p, contains('NOTES BODY'));
      expect(p, isNot(contains('no code fences')));
    });
  });

  test('Quiz round-trips through JSON and scores partial answers as half', () {
    final quiz = Quiz(
      id: 'q',
      createdAt: DateTime(2026, 11, 13),
      difficulty: QuizDifficulty.medium,
      imported: true,
      questions: [
        parseQuiz(quizText)[0].copyWith(chosen: 1, verdict: Verdict.correct),
        parseQuiz(quizText)[1].copyWith(
            reply: 'conjugate', verdict: Verdict.partial, feedback: 'ok'),
      ],
    );
    final back = Quiz.fromJson(quiz.toJson());
    expect(back.difficulty, QuizDifficulty.medium);
    expect(back.imported, isTrue);
    expect(back.questions[0].chosen, 1);
    expect(back.questions[1].feedback, 'ok');
    expect(back.finished, isTrue);
    expect(back.score, 1.5);
  });
}
