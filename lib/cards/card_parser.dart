/// Tolerant parser for the line-based flashcard format, and for the
/// `<<<CARDS` block that follows a model's notes.
library;

import 'card_models.dart';

const cardsOpen = '<<<CARDS';
const cardsClose = 'CARDS>>>';

final _key = RegExp(
  r'^\s*(?:[-*•>#]+\s*)*(?:\*\*|__)?\s*'
  r'(QUESTION|FRONT|ANSWER|BACK|TOPIC|Q|A)'
  r'\s*(?:\*\*|__)?\s*:\s*(?:\*\*|__)?\s*(.*)$',
  caseSensitive: false,
);

class _Draft {
  String front = '';
  String back = '';
  String topic = '';
}

/// Parses flashcards in the format
///
///     FRONT: <question>
///     BACK: <answer>
///     TOPIC: <lesson title>      (optional)
///
/// with a blank line between cards. Keys are case-insensitive, may be
/// decorated with Markdown, and `Q:` / `A:` are accepted as synonyms. Text
/// around the cards (a code fence, a greeting) is ignored, and a card without
/// a front or a back is dropped. Returns an empty list when there are none.
List<Flashcard> parseCards(String raw) {
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
      append = null;
      if (key == 'FRONT' || key == 'Q' || key == 'QUESTION') {
        final d = cur = _Draft()..front = value;
        drafts.add(d);
        append = (s) => d.front = '${d.front} $s'.trim();
        continue;
      }
      final d = cur;
      if (d == null) continue;
      switch (key) {
        case 'BACK' || 'A' || 'ANSWER':
          d.back = value;
          append = (s) => d.back = '${d.back} $s'.trim();
        case 'TOPIC':
          d.topic = value;
          append = (s) => d.topic = '${d.topic} $s'.trim();
      }
      continue;
    }
    append?.call(t);
  }

  return [
    for (final d in drafts)
      if (d.front.isNotEmpty && d.back.isNotEmpty)
        Flashcard(
          front: d.front,
          back: d.back,
          topic: d.topic.isEmpty ? null : d.topic,
        ),
  ];
}

/// Splits a model answer into the notes document and the flashcards that
/// follow it in a `<<<CARDS` ... `CARDS>>>` block. A missing end marker is
/// tolerated: the block is parsed to the end of the text.
({String notes, List<Flashcard> cards}) splitNotesAndCards(String raw) {
  final start = raw.lastIndexOf(cardsOpen);
  if (start < 0) return (notes: raw.trim(), cards: const []);
  var block = raw.substring(start + cardsOpen.length);
  final end = block.indexOf(cardsClose);
  if (end >= 0) block = block.substring(0, end);
  return (
    notes: raw.substring(0, start).trim(),
    cards: parseCards(block),
  );
}
