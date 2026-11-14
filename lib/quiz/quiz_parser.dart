/// Tolerant parsers for the line-based quiz and grading formats (see
/// `QuizPrompts`).
library;

import 'dart:math';

import 'quiz_models.dart';

final _key = RegExp(
  r'^\s*(?:[-*•>#]+\s*)*(?:\*\*|__)?\s*'
  r'(QUESTION(?:\s+\d+)?|TYPE|CORRECT|EXPLAIN|EXPLANATION|ANSWER|VERDICT|FEEDBACK)'
  r'\s*(?:\*\*|__)?\s*:\s*(?:\*\*|__)?\s*(.*)$',
  caseSensitive: false,
);
final _option = RegExp(r'^\s*(?:[-*•]\s*)?(?:\*\*)?([A-F])(?:\*\*)?\s*[:)]\s+(.*)$');

class _Draft {
  String prompt = '';
  String type = '';
  final options = <String, String>{};
  String correct = '';
  String answer = '';
}

/// Parses the questions of a quiz. Text around them (a code fence, a
/// greeting) is ignored, and a question that is not usable (a choice without
/// a valid key, a free question without a reference answer) is dropped.
///
/// With [shuffle] the options of each choice question are put in random
/// order, so the right one is not where the model likes to put it.
///
/// Throws [FormatException] when no usable question is found.
List<QuizQuestion> parseQuiz(String raw, {Random? shuffle}) {
  final drafts = <_Draft>[];
  _Draft? cur;
  // The field continuation lines are appended to.
  void Function(String more)? append;

  for (final line in raw.replaceAll('\r\n', '\n').split('\n')) {
    final t = line.trim();
    if (t.isEmpty || t.startsWith('```')) {
      append = null;
      continue;
    }
    final m = _key.firstMatch(line);
    if (m != null) {
      final key = m.group(1)!.toUpperCase();
      final value = m.group(2)!.trim();
      if (key.startsWith('QUESTION')) {
        final d = cur = _Draft()..prompt = value;
        drafts.add(d);
        append = (s) => d.prompt = '${d.prompt} $s'.trim();
        continue;
      }
      final d = cur;
      if (d == null) continue;
      switch (key) {
        case 'TYPE':
          d.type = value.toUpperCase();
          append = null;
        case 'CORRECT':
          d.correct = value.toUpperCase();
          append = null;
        case 'EXPLAIN' || 'EXPLANATION' || 'ANSWER':
          d.answer = value;
          append = (s) => d.answer = '${d.answer} $s'.trim();
        default:
          append = null;
      }
      continue;
    }
    final d = cur;
    if (d == null) continue;
    final o = _option.firstMatch(line);
    if (o != null && d.answer.isEmpty) {
      final letter = o.group(1)!;
      d.options[letter] = o.group(2)!.trim();
      append = (s) => d.options[letter] = '${d.options[letter]} $s'.trim();
      continue;
    }
    append?.call(t);
  }

  final out = <QuizQuestion>[];
  for (final d in drafts) {
    if (d.prompt.isEmpty) continue;
    final free = d.type.startsWith('FREE') ||
        (d.type.isEmpty && d.options.isEmpty);
    if (free) {
      if (d.answer.isEmpty) continue;
      out.add(QuizQuestion(prompt: d.prompt, answer: d.answer));
      continue;
    }
    final letters = d.options.keys.toList();
    // The letter on its own ("B", "B)", "Option B"), not one inside a word.
    final keyed = RegExp(r'\b[A-F]\b').firstMatch(d.correct)?.group(0);
    if (letters.length < 2 || keyed == null || !letters.contains(keyed)) {
      continue;
    }
    final order = [for (var i = 0; i < letters.length; i++) i];
    if (shuffle != null) order.shuffle(shuffle);
    out.add(QuizQuestion(
      prompt: d.prompt,
      options: [for (final i in order) d.options[letters[i]]!],
      correct: order.indexOf(letters.indexOf(keyed)),
      answer: d.answer,
    ));
  }
  if (out.isEmpty) {
    throw const FormatException('No quiz questions found.');
  }
  return out;
}

/// Parses the grader's `VERDICT:` / `FEEDBACK:` answer.
/// Throws [FormatException] when there is no verdict.
({Verdict verdict, String feedback}) parseGrade(String raw) {
  Verdict? verdict;
  var feedback = '';
  var inFeedback = false;
  for (final line in raw.split('\n')) {
    final m = _key.firstMatch(line);
    if (m == null) {
      if (inFeedback && line.trim().isNotEmpty) {
        feedback = '$feedback ${line.trim()}'.trim();
      }
      continue;
    }
    final key = m.group(1)!.toUpperCase();
    final value = m.group(2)!.trim();
    inFeedback = key == 'FEEDBACK';
    if (key == 'VERDICT') {
      final v = value.toUpperCase();
      verdict = v.startsWith('CORRECT')
          ? Verdict.correct
          : v.startsWith('PARTIAL')
              ? Verdict.partial
              : v.startsWith('WRONG') || v.startsWith('INCORRECT')
                  ? Verdict.wrong
                  : null;
    } else if (inFeedback) {
      feedback = value;
    }
  }
  if (verdict == null) {
    throw const FormatException('The grader gave no verdict.');
  }
  return (verdict: verdict, feedback: feedback);
}
