import 'package:sembast/sembast.dart';

import 'chat_models.dart';

/// Persists one chat thread per lesson (record key = lesson id).
class ChatStore {
  ChatStore(this._db);

  final Database _db;
  final _store = stringMapStoreFactory.store('chats');

  Future<List<ChatTurn>> load(String lessonId) async {
    final rec = await _store.record(lessonId).get(_db);
    final list = rec?['turns'];
    if (list is! List) return [];
    return [
      for (final t in list)
        if (t is Map) ChatTurn.fromJson(Map<String, Object?>.from(t)),
    ];
  }

  Future<void> save(String lessonId, List<ChatTurn> turns) =>
      _store.record(lessonId).put(_db, {
        'turns': [for (final t in turns) t.toJson()],
      });

  Future<void> clear(String lessonId) => _store.record(lessonId).delete(_db);
}
