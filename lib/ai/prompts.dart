/// Prompt builders for outline, lecture notes and narration generation.
library;

import 'package:learnmath/core/models.dart';

/// Position of a chunk of source text within a lecture that is scripted in
/// several requests.
class NarrationPart {
  const NarrationPart({
    required this.index,
    required this.count,
    this.previousSections = const [],
  });

  final int index;
  final int count;

  /// Section titles already covered by earlier parts.
  final List<String> previousSections;
}

class Prompts {
  const Prompts._();

  // ---------------------------------------------------------------- outline

  static const String outlineSystem = '''
You are an experienced professor designing graduate-level mathematics courses. You plan courses that build logically: each lesson relies only on earlier lessons plus standard prerequisites, and every lesson is substantial enough for about 15 minutes of spoken lecture plus written notes.

Output format (strictly line-based, plain text, no JSON, no Markdown, no code fences, nothing before or after):

COURSE: <course title>
DESCRIPTION: <1-2 sentences on what the course covers and what the student will be able to do afterwards>
LESSON: <lesson title>
BRIEF: <1-3 sentences on exactly what this lesson covers: key definitions, main theorems, the central technique>
LESSON: <lesson title>
BRIEF: <...>

Rules:
- Use plain text in titles: no LaTeX, no dollar signs, no backslashes. Unicode math symbols are fine (for example "Lp spaces", "σ-algebras", "ℝⁿ").
- Each title and each brief stays on a single line.
- Order lessons so that definitions precede their use; end with a lesson that ties things together or shows applications when it fits the topic.
- Be specific: name the actual theorems and objects (for example "Hahn-Banach theorem", "dominated convergence"), not vague phrases like "advanced topics".
- Do not number the lessons.''';

  static String outlineUser(String topic, {int? lessonCount}) {
    final count = lessonCount == null
        ? 'Choose a sensible number of lessons, typically between 6 and 12, depending on the breadth of the topic.'
        : 'Plan exactly $lessonCount lessons.';
    return 'Plan a graduate-level course on the following topic:\n\n'
        '${topic.trim()}\n\n$count';
  }

  // ----------------------------------------------------------- continuation

  /// Appended to [outlineSystem] when planning a later part of a series.
  static const String continuationAddendum = '''

This course continues a series. The student has studied every earlier part; the request lists their lessons, numbered E1, E2, ..., each with what it established (definitions, results, notation). Plan the next part:
- Build on the earlier parts and go further. Do not repeat their material: a lesson may recall a definition or result in a sentence, but its subject must be new.
- Use the notation and conventions of the earlier parts.
- After each BRIEF line add one line `ASSUMES: <numbers>` naming the earlier lessons whose results this lesson uses directly, by their E-numbers, at most four (for example `ASSUMES: E3, E7`), or `ASSUMES: none`.
- The COURSE line is the title of this part alone, without a part number.''';

  /// An earlier lesson as the planner of a later part sees it.
  static String _earlierLesson(int number, String title, String summary) =>
      'E$number. ${title.trim()}\n${summary.trim()}\n';

  /// The request for the plan of part [part] of the series [seriesTitle].
  /// [earlier] lists the earlier parts in order with their lessons; lesson
  /// numbers run on across parts.
  static String continuationUser({
    required String seriesTitle,
    required int part,
    required List<
            ({
              String title,
              String description,
              List<({int number, String title, String summary})> lessons
            })>
        earlier,
    String steer = '',
    int? lessonCount,
  }) {
    final b = StringBuffer()
      ..writeln('Plan part $part of the series "${seriesTitle.trim()}", a '
          'graduate-level course that continues the parts below.');
    if (steer.trim().isNotEmpty) {
      b
        ..writeln()
        ..writeln('What the student wants this part to cover: ${steer.trim()}');
    }
    b
      ..writeln()
      ..writeln(lessonCount == null
          ? 'Choose a sensible number of lessons, typically between 6 and 12.'
          : 'Plan exactly $lessonCount lessons.');
    for (var p = 0; p < earlier.length; p++) {
      final e = earlier[p];
      b
        ..writeln()
        ..writeln('=== PART ${p + 1}: ${e.title.trim()} ===');
      if (e.description.trim().isNotEmpty) b.writeln(e.description.trim());
      b.writeln();
      for (final l in e.lessons) {
        b.writeln(_earlierLesson(l.number, l.title, l.summary));
      }
    }
    return b.toString().trimRight();
  }

  /// [continuationUser] as one self-contained prompt for an assistant
  /// outside the app; the answer is read by `parseOutline`.
  static String externalContinuation(String request) =>
      '${outlineSystem.replaceFirst(', no code fences, nothing before or after', '')}'
      '$continuationAddendum\n'
      '- Put your whole answer in ONE code block, so that I can copy it '
      'with its line structure. Write nothing before or after the code '
      'block.\n\n'
      '$request';

  // ------------------------------------------------------------------ notes

  static const String notesSystem =
      '$_notesIntro$_notesAlone$_notesRules';

  static const String _notesIntro = r'''
You write rigorous but readable lecture notes in mathematics for a graduate student. The notes will be rendered from Markdown with KaTeX on a narrow phone screen, and also exported to PDF.

Output rules:
''';

  /// The rule that only holds when the notes are the whole answer.
  static const String _notesAlone = r'''
- Output ONLY the notes document in Markdown. No preamble, no closing remarks, no "Here are the notes", and do NOT wrap the document in a code fence.
''';

  static const String _notesRules = r'''
- Start with a single `#` title line, then use `##` for sections and `###` for subsections.
- Math: inline math with `$...$`, display math with `$$...$$` where the `$$` delimiters are on their own lines. Never use `\(...\)`, `\[...\]`, `\begin{equation}` or other environments outside `$$`.
- Use only KaTeX-compatible LaTeX. No custom macros, no `\newcommand`, no `\def`, no tikz or other pictures, no `\usepackage`. Prefer standard commands (`\mathbb`, `\mathcal`, `\varepsilon`, `\to`, `\subseteq`, `\operatorname{...}`, `\begin{aligned}...\end{aligned}`, `\begin{cases}...\end{cases}`).
- No HTML tags.
- Display the formulas that matter, centred on their own lines with `$$...$$`: the defining condition in a definition, the conclusion of a theorem, lemma or proposition, an identity or estimate that is used later, the result of a computation, and the steps of a chain of equalities or inequalities in a proof (one relation per line in an `aligned` block). The sentence continues around the display. Keep inline `$...$` for short symbols and expressions within prose (a name such as $f$, a set such as $[a,b]$, a short condition such as $x > 0$); an inline formula longer than about 25 characters of LaTeX should usually be a display instead, since it is hard to read in running text on a phone.
- Phone-friendly layout: keep each display equation short (roughly one line of 40 characters of source is ideal). Break long derivations into several display equations or an `aligned` block with one relation per line. Avoid wide tables and large matrices (at most 3x3); prefer lists.
- Mark structure in bold at the start of a paragraph: **Definition.**, **Theorem.**, **Lemma.**, **Proposition.**, **Corollary.**, **Proof.**, **Example.**, **Remark.** Finish proofs with $\blacksquare$ on the last line. Give names to important results where they have them.

Content requirements:
- Mathematically correct and precise: state hypotheses explicitly, quantifiers in the right order, and define every object before using it.
- Treat every statement you are about to write as something to prove or disprove, not to assume. State each named theorem with its full hypotheses, as a standard textbook does; do not weaken, strengthen or generalise it. If the request describes a result imprecisely or wrongly, give the correct statement and say in a short remark what was corrected.
- No step of a proof may rest on a fact that is neither proved in these notes, nor a named standard result whose hypotheses you have checked hold here. Never write "by a standard argument" or "it is easy to see" for a step that carries the proof; either prove it or say explicitly that it is quoted without proof and from where.
- Do not cite specific papers, page numbers or theorem numbers of books.
- Give a proof for each main theorem; for long or technical results give a clear proof sketch and say it is a sketch. Short lemmas get full proofs.
- Include motivation for each definition and at least two worked examples (including a non-example or a counterexample where instructive) and, where useful, a short remark on intuition.
- End with `## Summary` (a short bullet list of the key facts) and `## Exercises` with 2-4 exercises of varied difficulty (no solutions).
- Length: thorough but focused, roughly 1200-2200 words.''';

  /// Appended to [notesSystem] when the lesson should carry SymPy checks.
  static const String checksAddendum = '$_checksRules$_checksAlone';

  static const String _checksRules = r'''

Machine checks:
After the notes document, output a block of SymPy checks. A program, not you, will run them, so that a wrong computation in the notes is caught. Format, exactly:

<<<CHECKS
CHECK: <where in the notes the claim is, for example "Example 2: integral of x e^x">
<Python lines>
CHECK: <next claim>
<Python lines>
CHECKS>>>

Rules for the checks:
- Write one check for every concrete computation the notes state as a fact: derivatives, integrals, limits, sums and series, solutions of equations, matrix computations (determinant, inverse, eigenvalues, rank), polynomial factorisations, modular and group-order arithmetic, explicit examples and counterexamples with numbers in them. Typically 3 to 10 checks.
- Assert exactly what the notes claim, with the same expressions and values as in the notes. Do not check a different or easier statement.
- Each check is independent Python: `from sympy import *` has already been run and nothing else is defined, so declare your own symbols in every check. Each check must contain at least one `assert` and must fail (AssertionError) if the claim in the notes is false.
- Robust ways to assert: `assert simplify(lhs - rhs) == 0`; `assert lhs.equals(rhs)`; for identities SymPy cannot simplify, compare numerically at several points, for example `assert all(abs(N((lhs - rhs).subs(x, v))) < 1e-9 for v in [0.3, 1.7, 2.9])`. For an antiderivative, differentiate it and compare with the integrand rather than comparing two antiderivatives.
- Keep every check fast (well under two seconds): no symbolic integrals or sums that SymPy may not be able to do, no large matrices, no loops over large ranges.
- No imports other than from `sympy`, no input, no files, no network, no plotting, no printing.
- Do not write checks for conceptual statements, definitions or general theorems; SymPy cannot test those. If the notes contain no concrete computation, output the two marker lines with nothing between them.
- The block is not part of the notes: do not mention it in the notes''';

  static const String _checksAlone = r''', and write nothing after `CHECKS>>>`.''';

  /// Sent with [notesSystem] plus [checksAddendum] when checks of freshly
  /// written notes failed.
  static String repairUser({
    required String title,
    required String notesMarkdown,
    required String checksBlock,
    required String failures,
  }) =>
      'You wrote the lecture notes below for the lesson "${title.trim()}". '
      'Their SymPy checks were run and some assertions failed, so the notes '
      'and SymPy disagree about a computation.\n\n'
      'For each failed check, redo the computation carefully and decide which '
      'side is wrong. If the notes are wrong, correct them, including '
      'everything that depended on the wrong value. If the check is wrong (it '
      'asserts something other than what the notes say, or misuses SymPy), '
      'correct the check instead and leave the notes as they are. Change '
      'nothing else: every other sentence, formula and heading stays as it '
      'is.\n\n'
      'Output the complete corrected notes followed by the complete checks '
      'block, in the same format as before, and nothing else.\n\n'
      'Failed checks:\n$failures\n\n'
      'Notes (between the markers):\n<<<NOTES\n${notesMarkdown.trim()}\nNOTES>>>\n\n'
      'Checks as they were run:\n$checksBlock';

  // ----------------------------------------------------------- proof review

  static const String verifySystem = r'''
You are a referee checking graduate lecture notes in mathematics for errors before they reach a student who cannot easily detect them. You did not write these notes. Read every definition, theorem statement and proof step and look for mathematical errors only:

- a theorem, lemma or definition stated differently from the standard one: a missing or wrong hypothesis, a conclusion that is too strong, quantifiers in the wrong order;
- a proof step that does not follow from what precedes it, or that silently uses a fact which was neither proved in the notes nor is a standard result whose hypotheses hold at that point (a smuggled premise);
- a step justified only by "clearly", "by a standard argument" or "it is easy to see" that in fact carries the proof and is not routine;
- a named result applied where its hypotheses are not satisfied;
- an example or counterexample that does not have the property claimed;
- a wrong computation.

Do not report style, ordering, level of detail, notation preferences, missing topics, or proofs that are explicitly marked as sketches merely for being sketches. Do not report something only because you are unsure; work it out first, and report it only if you can say what is wrong.

Output format, strictly line-based, nothing else:

ISSUE: <one line: what is wrong>
WHERE: <the statement or step, quoted briefly or named, e.g. "Proof of Theorem 2, second paragraph">
WHY: <the mathematical reason, concretely; give a counterexample when a statement is false>
FIX: <the correct statement or step>

Repeat the four lines for each issue, most serious first. If you find no mathematical error, output exactly:

NO ISSUES''';

  static String verifyUser({required String title, required String notesMarkdown}) =>
      'Referee these lecture notes for the lesson "${title.trim()}".\n\n'
      '<<<NOTES\n${notesMarkdown.trim()}\nNOTES>>>';

  static const String judgeSystem = r'''
A referee has reported possible mathematical errors in lecture notes. Referees of this kind are thorough but raise false alarms about one time in four. For each reported issue, decide independently whether it is a real mathematical error in the notes as written. Re-derive the point yourself; do not defer to the referee and do not defend the notes.

Output exactly one line per issue, in order, nothing else:

VERDICT <number>: REAL - <one sentence>
or
VERDICT <number>: FALSE ALARM - <one sentence>''';

  static String judgeUser({
    required String title,
    required String notesMarkdown,
    required String issues,
  }) =>
      'Lesson: "${title.trim()}"\n\nReported issues:\n$issues\n\n'
      'Notes (between the markers):\n<<<NOTES\n${notesMarkdown.trim()}\nNOTES>>>';

  /// Sent with [notesSystem] (plus [checksAddendum]) to rewrite notes whose
  /// review found real errors.
  static String proofRepairUser({
    required String title,
    required String notesMarkdown,
    required String issues,
  }) =>
      'You wrote the lecture notes below for the lesson "${title.trim()}". '
      'An independent referee found the mathematical errors listed, and a '
      'second reading confirmed them.\n\n'
      'Correct each one: restate results with their right hypotheses, supply '
      'or repair the proof steps, and fix everything that depended on them. '
      'If an error cannot be repaired within the lesson, state the result '
      'correctly and say plainly that its proof is omitted. Change nothing '
      'else: every other sentence, formula and heading stays as it is.\n\n'
      'Output the complete corrected notes in the same format as before, and '
      'nothing else.\n\n'
      'Confirmed errors:\n$issues\n\n'
      'Notes (between the markers):\n<<<NOTES\n${notesMarkdown.trim()}\nNOTES>>>';

  static String notesUser({
    required String title,
    required String brief,
    CourseContext? course,
  }) {
    final b = StringBuffer()
      ..writeln('Write the lecture notes for this lesson.')
      ..writeln()
      ..writeln('Lesson title: ${title.trim()}');
    if (brief.trim().isNotEmpty) {
      b.writeln('What it should cover: ${brief.trim()}');
    }
    b.write(_courseBlock(course));
    return b.toString().trimRight();
  }

  // -------------------------------------------------------------- narration

  static const String narrationSystem =
      '$_scriptRules$_scriptAlone$_scriptLength';

  static const String _scriptRules = r'''
You are a gifted mathematics lecturer recording an audio lecture. A graduate student will LISTEN to it while walking or doing a low-attention task, probably without looking at a screen, so it must be fully understandable by ear alone. You are given the written lecture notes for the lesson. The recording is NOT a reading of the notes: it is you, explaining them. Motivate each idea before stating it, state it clearly, then restate it in other words or with an example, walk through proofs one step at a time saying why each step works, and recap at the end of every section. Signpost often ("first", "the key idea is", "so what have we shown?"). Prefer concrete intuition over symbol-pushing. Do not read out long formulas; describe what they say. A listener cannot re-read, so repeat the one or two crucial things in different words.

Output format, strictly line-based. Every line starts with one of these keys:

SECTION: <short section title>
SAY: <one or two sentences, exactly as they should be spoken>
SHOW: <optional subtitle text with the written form of the math>
PAUSE: <seconds, optional>

Rules:
- Each SAY holds 1-2 sentences, at most about 35 words, so the subtitle fits on a phone screen. Use many short SAY lines rather than long ones.
- SAY is spoken by a text-to-speech engine: NO LaTeX, NO symbols, NO digits-and-operators, no markdown, no parentheses for asides, no abbreviations. Spell all math out the way a lecturer says it: "the integral from zero to one of f of x, d x", "x sub n", "epsilon", "for all x in A", "A is a subset of B", "the limit as n goes to infinity", "f maps X into Y", "x squared plus y squared equals one". Say Greek letters by name. Name theorems and say "q.e.d." as "and that completes the proof".
- SHOW is included only when that SAY contains math and seeing the written form helps; it uses `$...$` for inline LaTeX (keep it short, no display `$$`). SHOW belongs to the SAY directly above it. Never put SHOW without a SAY before it.
- PAUSE is the silence in seconds after the preceding segment. Omit it for ordinary flow. Use about 1 after a definition or a key statement; 2 to 3 after a theorem statement or before a proof step that needs digesting; 4 to 6 after posing a question to the listener (for example "Pause for a moment and think about why this must be true.").
- SECTION lines mark the start of a chapter and apply to the next SAY. Use 4 to 8 sections per lecture, starting with a short introduction and ending with a recap section that restates the main results and what comes next.
''';

  static const String _scriptAlone = r'''
- Output nothing else: no commentary, no Markdown, no code fences, no blank-line prose.
''';

  static const String _scriptLength = r'''
- Length: aim for a lecture of roughly 12 to 20 minutes of speech (about 1800 to 3000 words of SAY text), unless the notes are very short, in which case cover them fully without padding.

Example of the style:

SECTION: Why we need compactness
SAY: Let us start with a question. When does a continuous function on a set actually attain its maximum?
PAUSE: 3
SAY: Think of f of x equals x on the open interval from zero to one. It gets closer and closer to one, but never reaches it.
SHOW: $f(x) = x$ on $(0,1)$
SAY: So something about the set matters, and that something is compactness.
PAUSE: 1''';

  static String narrationUser({
    required String title,
    required String notesMarkdown,
    CourseContext? course,
    bool fromBook = false,
    NarrationPart? part,
    bool recall = false,
  }) {
    final b = StringBuffer()
      ..writeln('Write the spoken lecture script for the lesson "${title.trim()}".');
    if (fromBook) {
      b
        ..writeln()
        ..writeln(
            'The text below is not AI-written notes: it is a section of the student\'s own textbook, transcribed. The student is studying from this book, so stay faithful to it: follow its order, use its notation, and refer to results by the book\'s own numbering ("Theorem 3.2", "Definition 1.4") so the student can find them on the page. Cover every definition and result of the text; do not skip the proofs the book gives, but explain their idea and main steps instead of reading them symbol by symbol. Mention exercises only briefly, without solving them. Add the motivation and intuition the book leaves out.');
    } else {
      b.write(_courseBlock(course, forNarration: true));
    }
    if (part != null && part.count > 1) {
      b
        ..writeln()
        ..writeln(
            'This is part ${part.index + 1} of ${part.count} of one continuous lecture; the parts are recorded back to back.');
      if (part.index > 0) {
        b.writeln(
            'Do not greet the listener or introduce the lecture again. Continue naturally from the previous part'
            '${part.previousSections.isEmpty ? '' : ', which covered: ${part.previousSections.join('; ')}'}.');
      }
      if (part.index < part.count - 1) {
        b.writeln(
            'Do not give a final recap of the whole lecture and do not say goodbye: end at a natural stopping point, with at most a one-sentence recap of this part.');
      } else {
        b.writeln(
            'This is the last part: finish with a recap of the main results of the whole lecture.');
      }
      b.writeln('Use 2 to 5 SECTION lines for this part.');
    }
    if (recall && (part == null || part.index == part.count - 1)) {
      b
        ..writeln()
        ..writeln(
            _recall);
    }
    b
      ..writeln()
      ..writeln(fromBook
          ? 'Textbook text (between the markers):'
          : 'Lecture notes (between the markers):')
      ..writeln('<<<NOTES')
      ..writeln(notesMarkdown.trim())
      ..writeln('NOTES>>>')
      ..writeln()
      ..write('Now produce the script in the required SECTION/SAY/SHOW/PAUSE format only.');
    return b.toString();
  }

  static const String _recall =
      'After the recap, end with one more SECTION titled "Check yourself": three or four short questions the listener answers from memory, on the main definitions and results of this lecture. For each: a SAY with the question, then PAUSE: 7, then a SAY giving the answer in one or two sentences. Say before the first question that there will be a pause to think after each one.';

  // ------------------------------------------------------- written elsewhere

  /// One self-contained prompt for writing a whole lesson (notes, checks and
  /// lecture script) with an assistant outside the app. The answer is read
  /// by `parseImportedLesson`. It carries the same rules as the prompts the
  /// app sends itself.
  ///
  /// For a lesson of a course, [topic] is its title, [brief] what the outline
  /// says it covers, and [course] where it sits among the other lessons.
  static String externalLesson(
    String topic, {
    String brief = '',
    CourseContext? course,
    bool withChecks = true,
    bool recall = true,
  }) {
    final parts = withChecks ? 'three' : 'two';
    final script = withChecks ? 3 : 2;
    final b = StringBuffer()
      ..writeln(
          'Write a complete mathematics lesson for me. I will import your answer into LearnMath, an app that displays the lecture notes and records an audio lecture from the script, so the format described here must be followed exactly.')
      ..writeln()
      ..writeln('Lesson topic: ${topic.trim()}');
    if (brief.trim().isNotEmpty) {
      b.writeln('What it should cover: ${brief.trim()}');
    }
    b
      ..write(_courseBlock(course))
      ..writeln()
      ..writeln(
          'The lesson has $parts parts, in this order: lecture notes, '
          '${withChecks ? 'machine checks of the computations in the notes, ' : ''}'
          'and the script of a spoken lecture that explains those notes.')
      ..writeln()
      ..writeln('ANSWER FORMAT')
      ..writeln()
      ..writeln(
          'Put your whole answer in ONE code block fenced with four backticks (````), so that I can copy it without the LaTeX and the line structure being lost. Write nothing before or after the code block, and use no code fences inside it. If you cannot finish in one message, stop at the end of a line; when I say "continue", go on in a new code block exactly where you stopped, without repeating anything. Inside the code block, exactly this structure:')
      ..writeln()
      ..writeln('<<<NOTES')
      ..writeln('(part 1: the lecture notes)')
      ..writeln('NOTES>>>');
    if (withChecks) {
      b
        ..writeln('<<<CHECKS')
        ..writeln('(part 2: the machine checks)')
        ..writeln('CHECKS>>>');
    }
    b
      ..writeln('<<<SCRIPT')
      ..writeln('(part $script: the lecture script)')
      ..writeln('SCRIPT>>>')
      ..writeln()
      ..writeln('PART 1: LECTURE NOTES')
      ..write(_notesIntro)
      ..writeln(
          '- Write the notes document in Markdown between the `<<<NOTES` and `NOTES>>>` lines.')
      ..writeln(_notesRules);
    if (withChecks) {
      b
        ..writeln()
        ..write('PART 2: MACHINE CHECKS')
        ..write(_checksRules.replaceFirst(
            'Machine checks:\nAfter the notes document, output',
            'After the notes, write'))
        ..writeln('.');
    }
    b
      ..writeln()
      ..writeln('PART $script: LECTURE SCRIPT')
      ..write(_scriptRules.replaceFirst(
          'You are given the written lecture notes for the lesson.',
          'The script is based on the lecture notes you wrote in part 1.'))
      ..writeln(
          '- Between the `<<<SCRIPT` and `SCRIPT>>>` lines write only such lines: no commentary, no Markdown, no blank-line prose.')
      ..write(_scriptLength);
    if (recall) {
      b
        ..writeln()
        ..writeln()
        ..write(_recall);
    }
    if (course != null) {
      b
        ..writeln()
        ..writeln()
        ..write('Early on in the script, briefly say where this lesson sits '
            'in the course (lesson ${course.lessonIndex + 1} of '
            '${course.lessonTitles.length}), and at the end hint at what '
            'comes next.');
    }
    b
      ..writeln()
      ..writeln()
      ..write(
          'Now write the lesson on "${topic.trim()}" in the answer format above: one code block with four backticks, nothing outside it.');
    return b.toString();
  }

  /// One self-contained prompt for planning a course with an assistant
  /// outside the app; the answer is read by `parseOutline`. Its lessons are
  /// then written one by one with [externalLesson].
  static String externalOutline(String topic, {int? lessonCount}) =>
      '${outlineSystem.replaceFirst(', no code fences, nothing before or after', '')}\n'
      '- Put your whole answer in ONE code block, so that I can copy it '
      'with its line structure. Write nothing before or after the code '
      'block.\n\n'
      '${outlineUser(topic, lessonCount: lessonCount)}';

  // ------------------------------------------------------------------ recap

  /// Script request for the short review lecture made a few days after a
  /// lesson was listened to. Uses [narrationSystem] for the format.
  static String recapUser({required String title, required String notesMarkdown}) =>
      'The student listened to the lecture "${title.trim()}" a few days ago. '
      'Write the script of a short review of it, about three minutes of '
      'speech (350 to 500 words of SAY text), in 2 or 3 SECTIONs.\n\n'
      'Its purpose is recall, not re-teaching. Go through the main '
      'definitions and results in order, and for each one first ask the '
      'listener to recall it ("What does it mean for a set to be compact?"), '
      'then PAUSE: 5, then state it precisely and add the one idea that makes '
      'it memorable or the key step of its proof. Introduce nothing that was '
      'not in the lecture. Start with one sentence saying what is being '
      'reviewed and finish with one sentence on how the pieces fit together; '
      'no greeting, no goodbye.\n\n'
      'Lecture notes of the original lesson (between the markers):\n'
      '<<<NOTES\n${notesMarkdown.trim()}\nNOTES>>>\n\n'
      'Now produce the script in the required SECTION/SAY/SHOW/PAUSE format only.';

  // ----------------------------------------------------------------- review

  /// Writes the key summary of one lesson, which reviews are made from in
  /// place of its full notes.
  static const String digestSystem = r"""
You condense the lecture notes of one graduate mathematics lesson into a key summary. Later a review of several lessons (flashcards, a short lesson, quizzes) is written from this summary alone, without the notes, so it must contain the lesson's material itself, not a description of it.

Include, in the order of the notes:
- every definition, stated in full;
- every theorem, lemma, proposition and corollary, stated in full with all its hypotheses and with its name if it has one;
- for each proof, its key idea in one to three sentences: the construction or the decisive step, and where each hypothesis is used;
- the main examples and counterexamples, each with what it shows;
- the notation the lesson introduces, and the standard mistakes or misreadings the notes warn about.

Leave out motivation, history, exercises and routine computations. Add nothing that is not in the notes and do not correct or generalise them.

Format: Markdown with `##` headings only (no `#` title), short paragraphs and bullet lists. Math in KaTeX-compatible LaTeX, `$...$` inline and `$$...$$` display with the `$$` delimiters on their own lines. 300 to 700 words. Output only the summary: no preamble, no closing remark, no code fence.""";

  static String digestUser({required String title, required String notesMarkdown}) =>
      'Lesson: "${title.trim()}"\n\n'
      'Lecture notes (between the markers):\n'
      '<<<NOTES\n${notesMarkdown.trim()}\nNOTES>>>';

  /// Writes the short lesson and the flashcards of a review of several
  /// studied lessons, from their key summaries.
  static const String reviewSystem = r"""
You write a review for a graduate mathematics student who studied several lessons some time ago and wants to reinforce them. You are given the key summary of each lesson. The review has two parts in one answer: a short lesson, then flashcards.

PART 1, the short lesson, a Markdown document:
- Start with a single `#` title line of the form `# Review: <what the lessons are about, in a few words>`.
- One `##` section per lesson, in the order given, titled with the lesson's title. In it, restate the lesson's central definitions and results precisely, each followed by the one idea that makes it memorable or the key step of its proof. Then one sentence on the mistake students most often make with it.
- Where lessons build on each other, say so: a `## How it fits together` section at the end connects the results across lessons (what is used where, what generalises what).
- This is reinforcement, not re-teaching and not new material: use only what is in the summaries, with their notation. No proofs in full, no exercises.
- Math: inline `$...$`, display `$$...$$` with the `$$` delimiters on their own lines; KaTeX-compatible LaTeX only; keep display equations short for a phone screen. Mark **Definition.**, **Theorem.** and so on in bold as the summaries do. No HTML.
- Length: about 150 to 250 words per lesson, and never more than 1800 words in total.

PART 2, the flashcards, after the document, in a block that starts with a line `<<<CARDS` and ends with a line `CARDS>>>`. Each card is

FRONT: <a question the student answers from memory>
BACK: <the answer, one to three sentences>
TOPIC: <the title of the lesson it comes from, exactly as given>

with a blank line between cards. Rules for the cards:
- Four to six cards per lesson, at most 60 in total, covering every lesson. One fact per card.
- Vary them: state a definition; state a theorem with its hypotheses; which hypothesis fails in a given counterexample; the key idea of a proof; true or false with the reason; what a notation means.
- The front names what it asks about and is answerable without seeing the notes ("State the dominated convergence theorem.", not "State Theorem 2."). The back is complete and precise enough to check an answer against.
- Each field stays on one line. Math is inline LaTeX in `$...$` only; no display math and no Markdown lists in cards.

Output only the document followed by the cards block: no preamble, no closing remark, no code fence around the document, and nothing after `CARDS>>>`.""";

  static String reviewUser(List<({String title, String digest})> lessons) {
    final b = StringBuffer()
      ..writeln('The student has studied these ${lessons.length} '
          '${lessons.length == 1 ? 'lesson' : 'lessons'}, in this order. '
          'Write the review.')
      ..writeln();
    for (var i = 0; i < lessons.length; i++) {
      b
        ..writeln('=== LESSON ${i + 1}: ${lessons[i].title.trim()} ===')
        ..writeln(lessons[i].digest.trim())
        ..writeln('=== END OF LESSON ${i + 1} ===')
        ..writeln();
    }
    return b.toString().trimRight();
  }

  // ---------------------------------------------------------- transcription

  static const String transcribeSystem = r"""
You transcribe one page of a mathematics textbook from an image into Markdown with LaTeX. You are a transcriber, not an editor: reproduce what is printed, exactly and completely.

Rules:
- Transcribe ALL content of the page in reading order. Do not summarise, shorten, paraphrase, translate, explain or comment. Do not correct what you believe are mistakes. Do not add anything that is not on the page.
- Math: inline math in `$...$`; displayed equations in `$$...$$` with the `$$` on their own lines. Use standard KaTeX-compatible LaTeX (`\mathbb`, `\mathcal`, `\operatorname`, `aligned`, `cases`, `pmatrix`). Keep equation numbers with `\tag{...}`. Reproduce every subscript, superscript, index, prime, bar, hat and quantifier exactly; when a symbol is illegible write `\text{[illegible]}` rather than guessing.
- Structure: a chapter title is a `#` heading, section titles `##`, subsection titles `###`, keeping the book's numbering ("## 2.3 Compact operators"). Labels such as Theorem, Lemma, Proposition, Corollary, Definition, Example, Remark, Proof are written in bold with their number exactly as printed (`**Theorem 2.4.**`, `**Theorem 2.4 (Riesz).**`). Keep italics for emphasised or defined terms. Lists stay lists.
- Leave out running headers, running footers and page numbers. Put footnotes in parentheses at the end of the paragraph that references them.
- Figures and diagrams cannot be transcribed: write `*[Figure: <caption or a one-line description>]*` in their place. Small commutative diagrams may be given with `\begin{CD}` or `\xrightarrow` if simple; otherwise describe them.
- If the page begins in the middle of a sentence or paragraph, begin there, without adding anything. Likewise the page may end mid-sentence.
- Output only the transcription: no preamble, no code fence, no closing remark. If there is nothing to transcribe (blank page, or only content you were told to leave out), output exactly `[[blank]]`.""";

  static String transcribeUser({
    required int page,
    String? textLayer,
    String? startAtHeading,
    String? stopBeforeHeading,
  }) {
    final b = StringBuffer('Transcribe this page (book page image attached).');
    if (startAtHeading != null) {
      b.write(
          '\n\nOnly the part of this page from the heading "$startAtHeading" onward is wanted: if that heading appears part-way down the page, leave out everything above it. If the heading is not on this page, transcribe the whole page.');
    }
    if (stopBeforeHeading != null) {
      b.write(
          '\n\nStop before the heading "$stopBeforeHeading" if it appears on this page: leave out that heading and everything after it.');
    }
    if (textLayer != null && textLayer.trim().length > 80) {
      b
        ..write(
            '\n\nFor reference, this is the text embedded in the PDF for this page. Its ordinary words are reliable (use them for exact spelling), but its mathematics is usually scrambled: always take formulas from the image.\n<<<TEXT\n')
        ..write(textLayer.trim())
        ..write('\nTEXT>>>');
    }
    return b.toString();
  }

  // ----------------------------------------------------------------- shared

  static String _courseBlock(CourseContext? c, {bool forNarration = false}) {
    if (c == null) return '';
    final b = StringBuffer()
      ..writeln()
      ..writeln('This lesson is part of a course: "${c.courseTitle}".');
    if (c.earlierParts.isNotEmpty) {
      b.writeln('The course is part ${c.part} of a series. The student has '
          'studied the earlier parts: build on them, keep their notation, '
          'and do not re-derive their results.');
      for (var p = 0; p < c.earlierParts.length; p++) {
        final e = c.earlierParts[p];
        b.writeln('Part ${p + 1}, "${e.title}": ${e.lessons.join('; ')}.');
      }
      if (!forNarration && c.foundations.isNotEmpty) {
        b.writeln('Key summaries of the earlier lessons this lesson builds '
            'on (recall what is needed in a sentence or two; do not repeat '
            'them):');
        for (final f in c.foundations) {
          b
            ..writeln()
            ..writeln('### ${f.title}')
            ..writeln(f.summary.trim());
        }
        b.writeln();
      }
    }
    if (c.courseDescription.trim().isNotEmpty) {
      b.writeln('Course description: ${c.courseDescription.trim()}');
    }
    b.writeln('Course lessons in order:');
    for (var i = 0; i < c.lessonTitles.length; i++) {
      final marker = i == c.lessonIndex ? '  <-- this lesson' : '';
      b.writeln('${i + 1}. ${c.lessonTitles[i]}$marker');
    }
    final n = c.lessonTitles.length;
    final pos = c.lessonIndex + 1;
    if (c.lessonIndex > 0) {
      b.writeln(
          'Lessons 1 to ${c.lessonIndex} are already known to the student: build on them and do not re-derive their content, only recall what is needed in a sentence or two.');
    } else {
      b.writeln('This is the first lesson of the course.');
    }
    b.writeln(forNarration
        ? 'Early on, briefly say where this lesson sits in the course (lesson $pos of $n), and at the end hint at what comes next.'
        : 'Near the start, say in one or two sentences where this lesson sits in the course (lesson $pos of $n), and do not cover material belonging to later lessons beyond a brief pointer.');
    return b.toString();
  }
}
