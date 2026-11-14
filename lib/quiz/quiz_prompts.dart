import '../ai/openrouter_client.dart';
import 'quiz_models.dart';

class QuizPrompts {
  const QuizPrompts._();

  static const _writer = r'''
You write quiz questions that test a graduate student's understanding of one mathematics lesson. The lesson's notes are given between markers. Every question must be answerable from them and uses their notation and definitions.

Output format, strictly line-based. A multiple-choice question:

QUESTION: <the question>
TYPE: CHOICE
A: <option>
B: <option>
C: <option>
D: <option>
CORRECT: <the letter of the right option>
EXPLAIN: <one to three sentences: why the right option is right and why the most tempting wrong one is wrong>

A free-answer question:

QUESTION: <the question>
TYPE: FREE
ANSWER: <the reference answer in two to five sentences, naming the key ideas a correct answer must contain>

Rules:
- Each field stays on one line, with a blank line between questions. Math is inline LaTeX in `$...$` (KaTeX-compatible); no display math, no Markdown lists.
- CHOICE: exactly four options, exactly one of them correct. The wrong ones are plausible: a typical misconception, a dropped hypothesis, a reversed implication, a near-miss computation. Options are of similar length; no "all of the above" or "none of the above". In EXPLAIN, do not refer to options by their letter (they are shown in another order); quote or describe them.
- FREE: something the student can answer by typing two to four sentences on a phone: explain why, give an example or a counterexample, say what fails without a hypothesis, outline the idea of a proof. Never a long computation or a full formal proof.
- Variety: each question is about a different definition, result, proof idea or example of the lesson, and the questions differ in kind (recall, why a hypothesis is needed, a concrete case, spotting an error, comparing two notions). No two questions test the same fact.
- Self-contained: a question names the result or object it is about; it does not say "in the notes" or rely on numbering the student may not remember.
- Correct: work out every keyed answer and every computation before you write it down.''';

  static const _difficulty = {
    QuizDifficulty.easy:
        'Easy: recall and recognition. The definitions, the statements of the main results and their hypotheses, direct one-step applications.',
    QuizDifficulty.medium:
        'Medium: understanding. Why each hypothesis is needed and what fails without it, applying the results to concrete examples, the key idea of each proof.',
    QuizDifficulty.hard:
        'Hard: transfer. Non-obvious consequences, combining two results of the lesson, subtle counterexamples and edge cases, finding the flaw in a plausible argument.',
  };

  static String _request({
    required String title,
    required String notesMarkdown,
    required QuizDifficulty difficulty,
    required QuizKind kind,
    required int count,
    List<String> avoid = const [],
  }) {
    final kinds = switch (kind) {
      QuizKind.choice => 'all of TYPE CHOICE',
      QuizKind.free => 'all of TYPE FREE',
      QuizKind.mixed => 'about half of TYPE CHOICE and half of TYPE FREE, mixed',
    };
    final b = StringBuffer()
      ..writeln('Write exactly $count ${count == 1 ? 'question' : 'questions'} '
          'on the lesson "${title.trim()}", $kinds.')
      ..writeln()
      ..writeln('Difficulty: ${_difficulty[difficulty]}');
    if (avoid.isNotEmpty) {
      b
        ..writeln()
        ..writeln('The student has already been asked these; do not repeat '
            'or rephrase them, and prefer parts of the lesson they leave out:');
      for (final q in avoid) {
        b.writeln('- $q');
      }
    }
    b
      ..writeln()
      ..writeln('Lesson notes (between the markers):')
      ..writeln('<<<NOTES')
      ..writeln(notesMarkdown.trim())
      ..write('NOTES>>>');
    return b.toString();
  }

  static List<ChatMessage> quizMessages({
    required String title,
    required String notesMarkdown,
    required QuizDifficulty difficulty,
    required QuizKind kind,
    required int count,
    List<String> avoid = const [],
  }) =>
      [
        const ChatMessage.system(
            '$_writer\n- Output only the questions: no preamble, no numbering, no code fences, no closing remark.'),
        ChatMessage.user(_request(
          title: title,
          notesMarkdown: notesMarkdown,
          difficulty: difficulty,
          kind: kind,
          count: count,
          avoid: avoid,
        )),
      ];

  /// One self-contained prompt for having an assistant outside the app write
  /// the quiz; its answer is read by `parseQuiz`.
  static String external({
    required String title,
    required String notesMarkdown,
    required QuizDifficulty difficulty,
    required QuizKind kind,
    required int count,
    List<String> avoid = const [],
  }) =>
      '$_writer\n'
      '- Put your whole answer in ONE code block fenced with four backticks (````), so that I can copy it without the LaTeX and the line structure being lost. Write nothing before or after the code block.\n\n'
      '${_request(title: title, notesMarkdown: notesMarkdown, difficulty: difficulty, kind: kind, count: count, avoid: avoid)}';

  static const _grader = r'''
You grade a student's typed answer to a quiz question on a mathematics lesson. The student types on a phone, so judge the ideas, not the wording, the notation, the level of detail or the rigor.

- CORRECT: the answer contains the key idea, even if it is brief or informal, or argues differently from the reference answer but validly.
- PARTIAL: part of the key idea is there, or the idea is right but comes with a real mistake.
- WRONG: the key idea is missing, or the answer asserts something false that matters.

Be honest: do not call a wrong answer correct to be kind, and do not mark a right answer down for being short. The reference answer is a guide, not the only acceptable answer; the lesson notes decide what is true.

Output exactly two lines, nothing else:

VERDICT: CORRECT, PARTIAL or WRONG
FEEDBACK: <one to three sentences to the student: what was right, and what was missing or wrong. Math in `$...$`.>''';

  static List<ChatMessage> gradeMessages({
    required String title,
    required String notesMarkdown,
    required QuizQuestion question,
    required String reply,
  }) =>
      [
        const ChatMessage.system(_grader),
        ChatMessage.user('Lesson: "${title.trim()}"\n\n'
            'Lesson notes (between the markers):\n'
            '<<<NOTES\n${notesMarkdown.trim()}\nNOTES>>>\n\n'
            'Question: ${question.prompt}\n\n'
            'Reference answer: ${question.answer}\n\n'
            'The student\'s answer (between the markers):\n'
            '<<<ANSWER\n${reply.trim()}\nANSWER>>>'),
      ];
}
