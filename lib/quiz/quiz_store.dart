import 'package:sembast/sembast.dart';

import 'quiz_models.dart';

/// Persists the quizzes of each lesson (record key = lesson id), newest
/// first. Kept out of the lesson record, which is large and watched by the
/// library.
class QuizStore {
  QuizStore(this._db);

  final Database _db;
  static final store = stringMapStoreFactory.store('quizzes');

  Future<List<Quiz>> load(String lessonId) async {
    final rec = await store.record(lessonId).get(_db);
    final list = rec?['quizzes'];
    if (list is! List) return [];
    return [
      for (final q in list)
        if (q is Map) Quiz.fromJson(Map<String, Object?>.from(q)),
    ];
  }

  Future<void> save(String lessonId, List<Quiz> quizzes) =>
      store.record(lessonId).put(_db, {
        'quizzes': [for (final q in quizzes) q.toJson()],
      });
}
