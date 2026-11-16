import 'package:flutter_test/flutter_test.dart';
import 'package:learnmath/cards/card_models.dart';
import 'package:learnmath/cards/card_store.dart';
import 'package:sembast/sembast_memory.dart';

void main() {
  final now = DateTime(2026, 11, 14, 9);

  group('Flashcard', () {
    test('known walks boxes 1..5 with the matching intervals and stays at 5',
        () {
      var c = const Flashcard(front: 'f', back: 'b', topic: 'T');
      for (var box = 1; box <= 5; box++) {
        c = c.graded(known: true, now: now);
        expect(c.box, box);
        expect(c.dueAt, now.add(cardIntervals[box - 1]));
        expect(c.front, 'f');
        expect(c.back, 'b');
        expect(c.topic, 'T');
      }
      c = c.graded(known: true, now: now);
      expect(c.box, 5);
      expect(c.dueAt, now.add(const Duration(days: 30)));
    });

    test('missed resets to box 0 and is due at once', () {
      final c = const Flashcard(front: 'f', back: 'b', box: 4)
          .graded(known: false, now: now);
      expect(c.box, 0);
      expect(c.dueAt, now);
      expect(c.isDue(now), isTrue);
      expect(c.front, 'f');
      expect(c.back, 'b');
    });

    test('isDue: never shown, past, equal and future', () {
      expect(const Flashcard(front: 'f', back: 'b').isDue(now), isTrue);
      expect(
          Flashcard(front: 'f', back: 'b', dueAt: now.subtract(const Duration(minutes: 1)))
              .isDue(now),
          isTrue);
      expect(Flashcard(front: 'f', back: 'b', dueAt: now).isDue(now), isTrue);
      expect(
          Flashcard(front: 'f', back: 'b', dueAt: now.add(const Duration(minutes: 1)))
              .isDue(now),
          isFalse);
    });

    test('JSON round trip, with null topic and dueAt', () {
      const bare = Flashcard(front: 'f', back: 'b');
      final bareJson = bare.toJson();
      expect(bareJson.containsKey('topic'), isFalse);
      expect(bareJson.containsKey('dueAt'), isFalse);
      final bareBack = Flashcard.fromJson(bareJson);
      expect(bareBack.topic, isNull);
      expect(bareBack.dueAt, isNull);
      expect(bareBack.box, 0);

      final full = Flashcard(
          front: 'f', back: 'b', topic: 'T', box: 3, dueAt: now);
      final back = Flashcard.fromJson(full.toJson());
      expect(back.topic, 'T');
      expect(back.box, 3);
      expect(back.dueAt, now);
    });

    test('fromJson tolerates missing fields', () {
      final c = Flashcard.fromJson(const {});
      expect(c.front, '');
      expect(c.back, '');
      expect(c.box, 0);
    });
  });

  test('dueCardIndexes returns the indexes of the due cards in order', () {
    final cards = [
      Flashcard(front: 'a', back: 'a', dueAt: now.add(const Duration(days: 1))),
      const Flashcard(front: 'b', back: 'b'),
      Flashcard(front: 'c', back: 'c', dueAt: now),
      Flashcard(front: 'd', back: 'd', dueAt: now.subtract(const Duration(days: 2))),
    ];
    expect(dueCardIndexes(cards, now), [1, 2, 3]);
    expect(dueCardIndexes(const [], now), isEmpty);
  });

  group('CardStore', () {
    test('saves two cards and loads them back; an unknown lesson is empty',
        () async {
      final db = await newDatabaseFactoryMemory().openDatabase('t.db');
      final store = CardStore(db);
      await store.save('lesson-1', [
        const Flashcard(front: 'a', back: 'b', topic: 'T'),
        Flashcard(front: 'c', back: 'd', box: 2, dueAt: now),
      ]);
      final loaded = await store.load('lesson-1');
      expect(loaded, hasLength(2));
      expect(loaded[0].front, 'a');
      expect(loaded[0].topic, 'T');
      expect(loaded[1].box, 2);
      expect(loaded[1].dueAt, now);
      expect(await store.load('no-such-lesson'), isEmpty);
      await db.close();
    });
  });
}
