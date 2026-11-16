import 'package:sembast/sembast.dart';

import 'card_models.dart';

/// Persists the flashcards of each lesson (record key = lesson id). Kept out
/// of the lesson record, which is large and watched by the library.
class CardStore {
  CardStore(this._db);

  final Database _db;
  static final store = stringMapStoreFactory.store('cards');

  Future<List<Flashcard>> load(String lessonId) async {
    final rec = await store.record(lessonId).get(_db);
    final list = rec?['cards'];
    if (list is! List) return [];
    return [
      for (final c in list)
        if (c is Map) Flashcard.fromJson(Map<String, Object?>.from(c)),
    ];
  }

  Future<void> save(String lessonId, List<Flashcard> cards) =>
      store.record(lessonId).put(_db, {
        'cards': [for (final c in cards) c.toJson()],
      });
}
