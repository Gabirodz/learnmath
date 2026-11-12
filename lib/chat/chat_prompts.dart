import '../ai/openrouter_client.dart';
import '../core/models.dart';
import 'chat_models.dart';

/// Maximum number of history turns sent to the model.
const int kMaxChatTurns = 40;

const _notesBegin = '=== BEGIN LESSON NOTES ===';
const _notesEnd = '=== END LESSON NOTES ===';
const _quoteBegin = '[Passage the student is asking about]';
const _quoteEnd = '[End of passage]';

const _tutorInstructions = r'''
You are a patient, rigorous tutor for graduate-level mathematics. A student is studying one lesson and asks you questions about it. The lesson's notes are given below between markers; they are your primary reference.

Grounding
- Use the notes' notation, definitions and numbering (Theorem 2, Definition 1.3, ...) exactly as written. Refer to items of the notes by their number when helpful.
- Never invent content of the notes. If you are unsure whether the notes say something, say so.
- If a question goes beyond the notes, answer from general knowledge and state clearly that this is not in the notes.
- If the notes themselves appear to contain an error or a gap, say so plainly and give the correction.
- For chapters of a book, the notes may contain marker lines such as `[[page 37]]` giving the book page of the text that follows. Cite pages as "(p. 37)" when it helps the student find the place.

When the student quotes a passage, explain THAT passage:
1. Say what it claims in plain words.
2. Explain why it is true, and where each hypothesis is used.
3. Give a small concrete example, or a counterexample showing a hypothesis cannot be dropped.
4. Point out the usual stumbling block or common misreading.
Skip a step only if it does not apply. If the student asks for something simpler, an example, or the reason it is true, focus on exactly that.

Other requests: if asked to quiz, ask one question at a time and wait for the answer; if asked for a summary or prerequisites, base them on the notes.

Format
- Markdown. Math in LaTeX: `$...$` inline and `$$...$$` display, with the `$$` delimiters on their own lines. Never use `\(...\)` or `\[...\]`.
- Use only KaTeX-compatible LaTeX. Keep display equations short (break long ones into several lines or steps); no tables of formulas, no `\begin{align}` wider than a phone screen.
- Be concise and phone-friendly: aim for under about 250 words unless the student asks for a full proof. No filler openers ("Great question!", "Sure!"); start with the substance.
- Reply in the language the student writes in.''';

/// Renders a user turn as the model sees it: quoted passage, then question.
String renderUserTurn(ChatTurn t) {
  final q = t.quote?.trim();
  if (q == null || q.isEmpty) return t.text;
  final quoted = q.split('\n').map((l) => '> $l').join('\n');
  return '$_quoteBegin\n$quoted\n$_quoteEnd\n\nQuestion: ${t.text}';
}

/// System prompt (with the notes verbatim) followed by the chat history.
/// Only the last [kMaxChatTurns] turns are sent.
List<ChatMessage> buildChatMessages({
  required Lesson lesson,
  required List<ChatTurn> history,
}) {
  final notes = lesson.notesMarkdown ?? '(This lesson has no notes yet.)';
  final system = '$_tutorInstructions\n\nLesson title: ${lesson.title}\n\n'
      '$_notesBegin\n$notes\n$_notesEnd';
  var recent = history.length > kMaxChatTurns
      ? history.sublist(history.length - kMaxChatTurns)
      : history;
  // Start the window on a user turn.
  final firstUser = recent.indexWhere((t) => t.fromUser);
  if (firstUser > 0) recent = recent.sublist(firstUser);
  return [
    ChatMessage.system(system),
    for (final t in recent)
      t.fromUser
          ? ChatMessage.user(renderUserTurn(t))
          : ChatMessage.assistant(t.text),
  ];
}
