/// Flashcards made from a lesson's notes: a question to recall, the answer to
/// check against, and a Leitner box that sets when the card is asked again.
library;

import 'dart:math';

/// How long until a card is asked again after it was known, by the box it
/// moves into (box 1 = one day ... box 5 = thirty days).
const cardIntervals = [
  Duration(days: 1),
  Duration(days: 3),
  Duration(days: 7),
  Duration(days: 14),
  Duration(days: 30),
];

class Flashcard {
  const Flashcard({
    required this.front,
    required this.back,
    this.topic,
    this.box = 0,
    this.dueAt,
  });

  /// The question / prompt side; may contain inline LaTeX in `$...$`.
  final String front;

  /// The answer side.
  final String back;

  /// Title of the lesson the card comes from.
  final String? topic;

  /// Leitner box: 0 = new or missed last time.
  final int box;

  /// When to ask again; null = never shown yet.
  final DateTime? dueAt;

  bool isDue(DateTime now) {
    final due = dueAt;
    return due == null || !due.isAfter(now);
  }

  /// The card after the student graded it: a known card moves up one box,
  /// a missed one goes back to box 0 and is due at once.
  Flashcard graded({required bool known, required DateTime now}) {
    if (!known) {
      return Flashcard(front: front, back: back, topic: topic, dueAt: now);
    }
    final newBox = max(1, min(box + 1, cardIntervals.length));
    return Flashcard(
      front: front,
      back: back,
      topic: topic,
      box: newBox,
      dueAt: now.add(cardIntervals[newBox - 1]),
    );
  }

  Map<String, Object?> toJson() => {
        'front': front,
        'back': back,
        if (topic != null) 'topic': topic,
        'box': box,
        if (dueAt != null) 'dueAt': dueAt!.millisecondsSinceEpoch,
      };

  factory Flashcard.fromJson(Map<String, Object?> j) => Flashcard(
        front: j['front'] as String? ?? '',
        back: j['back'] as String? ?? '',
        topic: j['topic'] as String?,
        box: (j['box'] as num?)?.toInt() ?? 0,
        dueAt: switch (j['dueAt']) {
          num ms => DateTime.fromMillisecondsSinceEpoch(ms.toInt()),
          _ => null,
        },
      );
}

/// The cards to ask now: those that are due, in their stored order.
/// Returns the indexes into [cards].
List<int> dueCardIndexes(List<Flashcard> cards, DateTime now) => [
      for (var i = 0; i < cards.length; i++)
        if (cards[i].isDue(now)) i,
    ];
