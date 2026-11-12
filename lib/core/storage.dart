import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sembast/sembast_io.dart';

import 'models.dart';

/// Filesystem layout:
///   `<docs>/learnmath.db`              sembast database
///   `<docs>/lessons/<id>/lecture.wav`  synthesized narration
///   `<docs>/lessons/<id>/notes.pdf`    exported notes
///   `<support>/models/`                downloaded TTS models
class AppPaths {
  AppPaths({required this.docs, required this.support});

  final String docs;
  final String support;

  static Future<AppPaths> resolve() async {
    final docs = await getApplicationDocumentsDirectory();
    final support = await getApplicationSupportDirectory();
    return AppPaths(docs: docs.path, support: support.path);
  }

  String get dbPath => p.join(docs, 'learnmath.db');
  String get modelsDir => p.join(support, 'models');
  String lessonDir(String lessonId) => p.join(docs, 'lessons', lessonId);
  String lessonAudio(String lessonId) =>
      p.join(lessonDir(lessonId), 'lecture.wav');
  String lessonPdf(String lessonId) => p.join(lessonDir(lessonId), 'notes.pdf');
}

Future<Database> openAppDatabase(AppPaths paths) =>
    databaseFactoryIo.openDatabase(paths.dbPath);

/// Courses and lessons.
class LibraryRepository {
  LibraryRepository(this._db, this._paths);

  final Database _db;
  final AppPaths _paths;
  final _courses = stringMapStoreFactory.store('courses');
  final _lessons = stringMapStoreFactory.store('lessons');

  Stream<List<Course>> watchCourses() => _courses
      .query(finder: Finder(sortOrders: [SortOrder('createdAt', false)]))
      .onSnapshots(_db)
      .map((snaps) => [for (final s in snaps) Course.fromJson(s.value)]);

  Stream<Course?> watchCourse(String id) => _courses
      .record(id)
      .onSnapshot(_db)
      .map((s) => s == null ? null : Course.fromJson(s.value));

  /// Lessons of a course in order, or standalone lessons (newest first) when
  /// [courseId] is null.
  Stream<List<Lesson>> watchLessons({String? courseId}) => _lessons
      .query(
        finder: Finder(
          filter: courseId == null
              ? Filter.isNull('courseId')
              : Filter.equals('courseId', courseId),
          sortOrders: [
            if (courseId == null)
              SortOrder('createdAt', false)
            else
              SortOrder('order'),
          ],
        ),
      )
      .onSnapshots(_db)
      .map((snaps) => [for (final s in snaps) Lesson.fromJson(s.value)]);

  Stream<Lesson?> watchLesson(String id) => _lessons
      .record(id)
      .onSnapshot(_db)
      .map((s) => s == null ? null : Lesson.fromJson(s.value));

  Future<Lesson?> getLesson(String id) async {
    final v = await _lessons.record(id).get(_db);
    return v == null ? null : Lesson.fromJson(v);
  }

  Future<Course?> getCourse(String id) async {
    final v = await _courses.record(id).get(_db);
    return v == null ? null : Course.fromJson(v);
  }

  Future<List<Lesson>> getCourseLessons(String courseId) async {
    final snaps = await _lessons.find(
      _db,
      finder: Finder(
        filter: Filter.equals('courseId', courseId),
        sortOrders: [SortOrder('order')],
      ),
    );
    return [for (final s in snaps) Lesson.fromJson(s.value)];
  }

  Future<List<Lesson>> getAllLessons() async {
    final snaps = await _lessons.find(_db);
    return [for (final s in snaps) Lesson.fromJson(s.value)];
  }

  Future<void> saveCourse(Course c) => _courses.record(c.id).put(_db, c.toJson());

  Future<void> saveLesson(Lesson l) => _lessons.record(l.id).put(_db, l.toJson());

  /// Read-modify-write inside a transaction. Returns the updated lesson, or
  /// null if it was deleted meanwhile.
  Future<Lesson?> updateLesson(String id, Lesson Function(Lesson) change) =>
      _db.transaction((txn) async {
        final rec = _lessons.record(id);
        final v = await rec.get(txn);
        if (v == null) return null;
        final updated = change(Lesson.fromJson(v));
        await rec.put(txn, updated.toJson());
        return updated;
      });

  Future<void> deleteLesson(String id) async {
    await _lessons.record(id).delete(_db);
    await _deleteDir(_paths.lessonDir(id));
  }

  Future<void> deleteCourse(String id) async {
    final lessons = await getCourseLessons(id);
    await _db.transaction((txn) async {
      await _courses.record(id).delete(txn);
      await _lessons.delete(txn,
          finder: Finder(filter: Filter.equals('courseId', id)));
    });
    for (final l in lessons) {
      await _deleteDir(_paths.lessonDir(l.id));
    }
  }

  Future<void> _deleteDir(String path) async {
    final dir = Directory(path);
    if (await dir.exists()) await dir.delete(recursive: true);
  }
}

/// Settings live in the database, except the API key (secure storage).
class SettingsStore {
  SettingsStore(this._db);

  final Database _db;
  final _record = StoreRef<String, Map<String, Object?>>('app').record('settings');
  static const _secure = FlutterSecureStorage();
  static const _apiKeyName = 'openrouter_api_key';

  Future<AppSettings> load() async {
    final json = await _record.get(_db) ?? const <String, Object?>{};
    String apiKey = '';
    try {
      apiKey = await _secure.read(key: _apiKeyName) ?? '';
    } catch (_) {
      // Keystore can become unreadable (e.g. after a restore); treat as unset.
    }
    return AppSettings.fromJson(json, apiKey: apiKey);
  }

  Future<void> save(AppSettings s) async {
    await _record.put(_db, s.toJson());
    await _secure.write(key: _apiKeyName, value: s.apiKey.trim());
  }
}
