import '../ai/openrouter_client.dart';
import '../ai/prompts.dart';

const _notesBegin = '=== BEGIN LESSON NOTES ===';
const _notesEnd = '=== END LESSON NOTES ===';

/// The format rules of the notes, so hints and solutions render the same way
/// (KaTeX on a narrow phone screen).
const _formatRules = r'''
Format:
- Markdown. Inline math with `$...$`, display math with `$$...$$` where the `$$` delimiters are on their own lines. Never use `\(...\)`, `\[...\]`, `\begin{equation}` or other environments outside `$$`.
- Only KaTeX-compatible LaTeX; no custom macros, no HTML, no pictures.
- Phone-friendly: keep each display equation short; break long derivations into several display equations or an `aligned` block with one relation per line. No wide tables, no large matrices.
- Use the notation, definitions and numbering of the notes (Theorem 2, Definition 1.3, ...) exactly as written. Reply in the language of the notes.''';

const _groundingRules = r'''
The lecture notes are given between markers; they are your primary reference. Never invent content of the notes. If a result you need is not in the notes, say that it is a standard result from outside them.''';

/// Prompts for the hint and solution of one exercise.
class ExercisePrompts {
  const ExercisePrompts._();

  static const String hintSystem = '''
You are a patient, rigorous tutor for graduate-level mathematics. A student is working on an exercise from lecture notes and is stuck. Give a hint, not the solution.
$_groundingRules

The hint:
- is 2 to 4 sentences;
- points to the right idea, or to the relevant definition or result of the notes (cite it by its number or name), and may say what to try first;
- does NOT carry out the solution, state the final answer, or give the key computation;
- starts with the substance: no greeting, no "Great question", no restating the exercise.
$_formatRules''';

  static const String solutionSystem = '''
You are a rigorous tutor for graduate-level mathematics. A student asks for the full worked solution of an exercise from lecture notes.
$_groundingRules

The solution:
- is complete and rigorous, and every step is justified;
- states explicitly which results of the notes it uses (by number or name) and checks that their hypotheses hold at that point; a standard result from outside the notes is named as such;
- handles every sub-part (a), (b), ... of the exercise, in order, under its own bold label;
- ends the proof with \$\\blacksquare\$ on the last line;
- starts with the substance: no greeting and no restating of the exercise.

Output only the solution as Markdown, not wrapped in a code fence.
$_formatRules
${Prompts.checksAddendum}

For the checks above, "the notes" means your solution: write a check for every concrete computation it states as a fact, and do not mention the block in the solution.''';

  static String _user(
      String task, String title, String notes, String exercise) {
    return '$task\n\nLesson title: ${title.trim()}\n\n'
        '$_notesBegin\n${notes.trim()}\n$_notesEnd\n\n'
        'Exercise:\n${exercise.trim()}';
  }

  static String hintUser({
    required String title,
    required String notesMarkdown,
    required String exercise,
  }) =>
      _user('Give a hint for the exercise below.', title, notesMarkdown,
          exercise);

  static String solutionUser({
    required String title,
    required String notesMarkdown,
    required String exercise,
  }) =>
      _user('Write the complete worked solution of the exercise below.', title,
          notesMarkdown, exercise);

  static List<ChatMessage> hintMessages({
    required String title,
    required String notesMarkdown,
    required String exercise,
  }) =>
      [
        const ChatMessage.system(hintSystem),
        ChatMessage.user(hintUser(
            title: title, notesMarkdown: notesMarkdown, exercise: exercise)),
      ];

  static List<ChatMessage> solutionMessages({
    required String title,
    required String notesMarkdown,
    required String exercise,
  }) =>
      [
        const ChatMessage.system(solutionSystem),
        ChatMessage.user(solutionUser(
            title: title, notesMarkdown: notesMarkdown, exercise: exercise)),
      ];
}
