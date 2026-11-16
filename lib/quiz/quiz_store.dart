import 'package:sembast/sembast.dart';

import 'quiz_models.dart';

/// Persists the quizzes of each lesson (record key = lesson id), newest
/// first. Kept out of the lesson record, which is large and watched by the
/// library.
///
/// Both the Quiz tab and the pipeline (a quiz ordered through the Batch API
/// arrives later) write here, so changes go through [update], which reads
/// and writes in one transaction, and readers follow [watch].
class QuizStore {
  QuizStore(this._db);

  final Database _db;
  static final store = stringMapStoreFactory.store('quizzes');

  static List<Quiz> _decode(Map<String, Object?>? rec) {
    final list = rec?['quizzes'];
    if (list is! List) return [];
    return [
      for (final q in list)
        if (q is Map) Quiz.fromJson(Map<String, Object?>.from(q)),
    ];
  }

  static Map<String, Object?> _encode(List<Quiz> quizzes) => {
        'quizzes': [for (final q in quizzes) q.toJson()],
      };

  Future<List<Quiz>> load(String lessonId) async =>
      _decode(await store.record(lessonId).get(_db));

  /// The quizzes of [lessonId], now and after every change.
  Stream<List<Quiz>> watch(String lessonId) => store
      .record(lessonId)
      .onSnapshot(_db)
      .map((snap) => _decode(snap?.value));

  Future<void> save(String lessonId, List<Quiz> quizzes) =>
      store.record(lessonId).put(_db, _encode(quizzes));

  /// Replaces the quizzes of [lessonId] by `change(current)`, atomically.
  Future<List<Quiz>> update(
          String lessonId, List<Quiz> Function(List<Quiz> current) change) =>
      _db.transaction((txn) async {
        final next =
            change(_decode(await store.record(lessonId).get(txn)));
        await store.record(lessonId).put(txn, _encode(next));
        return next;
      });

  /// Every quiz that waits for a Batch API answer, with its lesson.
  Future<List<({String lessonId, Quiz quiz})>> waiting() async => [
        for (final rec in await store.find(_db))
          for (final q in _decode(rec.value))
            if (q.isWaiting) (lessonId: rec.key, quiz: q),
      ];
}
