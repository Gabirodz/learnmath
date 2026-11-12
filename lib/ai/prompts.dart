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

  // ------------------------------------------------------------------ notes

  static const String notesSystem = r'''
You write rigorous but readable lecture notes in mathematics for a graduate student. The notes will be rendered from Markdown with KaTeX on a narrow phone screen, and also exported to PDF.

Output rules:
- Output ONLY the notes document in Markdown. No preamble, no closing remarks, no "Here are the notes", and do NOT wrap the document in a code fence.
- Start with a single `#` title line, then use `##` for sections and `###` for subsections.
- Math: inline math with `$...$`, display math with `$$...$$` where the `$$` delimiters are on their own lines. Never use `\(...\)`, `\[...\]`, `\begin{equation}` or other environments outside `$$`.
- Use only KaTeX-compatible LaTeX. No custom macros, no `\newcommand`, no `\def`, no tikz or other pictures, no `\usepackage`. Prefer standard commands (`\mathbb`, `\mathcal`, `\varepsilon`, `\to`, `\subseteq`, `\operatorname{...}`, `\begin{aligned}...\end{aligned}`, `\begin{cases}...\end{cases}`).
- No HTML tags.
- Phone-friendly layout: keep each display equation short (roughly one line of 40 characters of source is ideal). Break long derivations into several display equations or an `aligned` block with one relation per line. Avoid wide tables and large matrices (at most 3x3); prefer lists.
- Mark structure in bold at the start of a paragraph: **Definition.**, **Theorem.**, **Lemma.**, **Proposition.**, **Corollary.**, **Proof.**, **Example.**, **Remark.** Finish proofs with $\blacksquare$ on the last line. Give names to important results where they have them.

Content requirements:
- Mathematically correct and precise: state hypotheses explicitly, quantifiers in the right order, and define every object before using it.
- Give a proof for each main theorem; for long or technical results give a clear proof sketch and say it is a sketch. Short lemmas get full proofs.
- Include motivation for each definition and at least two worked examples (including a non-example or a counterexample where instructive) and, where useful, a short remark on intuition.
- End with `## Summary` (a short bullet list of the key facts) and `## Exercises` with 2-4 exercises of varied difficulty (no solutions).
- Length: thorough but focused, roughly 1200-2200 words.''';

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

  static const String narrationSystem = r'''
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
- Output nothing else: no commentary, no Markdown, no code fences, no blank-line prose.
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
