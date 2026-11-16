/// Everything the student has made, as one zip file: for moving to another
/// phone or keeping a copy.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:archive/archive_io.dart';
import 'package:path/path.dart' as p;
import 'package:sembast/sembast.dart';

import 'models.dart';
import 'storage.dart';

/// What a backup held, or what an import brought in.
class BackupSummary {
  const BackupSummary({
    required this.courses,
    required this.lessons,
    required this.recordings,
    required this.books,
    this.settings,
  });

  final int courses;
  final int lessons;

  /// Lecture recordings included.
  final int recordings;

  /// Imported textbooks (their PDF files).
  final int books;

  /// The settings in the backup, without the keys (they are never
  /// exported); null when it has none.
  final Map<String, Object?>? settings;
}

/// Not a LearnMath backup, or one this version cannot read.
class BackupException implements Exception {
  const BackupException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Writes and reads backups.
///
/// A backup is a zip with `learnmath-backup.json` (every database record:
/// courses, lessons with their notes and scripts, chats, quizzes,
/// flashcards, listening positions, settings) plus the files that cannot be
/// made again: the PDFs of imported books and, when asked for, the lecture
/// recordings. API keys are not in it. A lesson without its recording is
/// recorded again from its script on the device it is imported to.
class BackupService {
  BackupService(this._db, this._paths);

  final Database _db;
  final AppPaths _paths;

  static const dataFile = 'learnmath-backup.json';
  static const _format = 'learnmath-backup';
  static const _version = 1;

  /// Stores whose records are maps keyed by an id.
  static const _mapStores = ['courses', 'lessons', 'chats', 'quizzes', 'cards'];

  static const _interrupted =
      'This lesson was being made when the backup was taken. Tap retry to '
      'continue.';

  /// Writes a backup to [outPath]. With [recordings] the lecture audio is
  /// included, which makes the file large (about 3 MB per minute).
  Future<BackupSummary> export(String outPath,
      {required bool recordings}) async {
    final data = <String, Object?>{
      'format': _format,
      'version': _version,
      'exportedAt': DateTime.now().toUtc().toIso8601String(),
    };
    for (final name in _mapStores) {
      final store = stringMapStoreFactory.store(name);
      data[name] = {
        for (final r in await store.find(_db)) r.key: r.value,
      };
    }
    data['positions'] = {
      for (final r in await StoreRef<String, int>('positions').find(_db))
        r.key: r.value,
    };
    data['settings'] = await StoreRef<String, Map<String, Object?>>('app')
        .record('settings')
        .get(_db);

    // (file on this device, name inside the zip)
    final files = <(String, String)>[];
    final lessons = (data['lessons'] as Map).cast<String, Map>();
    var audio = 0;
    if (recordings) {
      for (final e in lessons.entries) {
        final path = e.value['audioPath'];
        if (path is String && await File(path).exists()) {
          files.add((path, 'lessons/${e.key}/lecture.wav'));
          audio++;
        }
      }
    }
    final courses = (data['courses'] as Map).cast<String, Map>();
    var books = 0;
    for (final e in courses.entries) {
      final path = e.value['bookPath'];
      if (path is String && await File(path).exists()) {
        files.add((path, 'books/${e.key}/book.pdf'));
        books++;
      }
    }

    await File(outPath).parent.create(recursive: true);
    final json = jsonEncode(data);
    await Isolate.run(() => _writeZip(outPath, json, files));
    return BackupSummary(
      courses: courses.length,
      lessons: lessons.length,
      recordings: audio,
      books: books,
    );
  }

  static Future<void> _writeZip(
      String outPath, String json, List<(String, String)> files) async {
    final zip = ZipFileEncoder()..create(outPath);
    zip.addArchiveFile(ArchiveFile.string(dataFile, json));
    for (final (source, name) in files) {
      // Audio and PDFs hardly compress; storing them is much faster.
      await zip.addFile(File(source), name, ZipFileEncoder.store);
    }
    await zip.close();
  }

  /// Brings the backup at [zipPath] into the library. Records are merged by
  /// id: what the backup holds replaces the record with the same id, and
  /// everything else on this device stays. The settings are returned in the
  /// summary for the caller to apply.
  ///
  /// Throws [BackupException] when the file is not a backup.
  Future<BackupSummary> import(String zipPath) async {
    final tmp = Directory(p.join(_paths.support, 'backup-import'));
    if (await tmp.exists()) await tmp.delete(recursive: true);
    await tmp.create(recursive: true);
    try {
      final out = tmp.path;
      try {
        await Isolate.run(() => extractFileToDisk(zipPath, out));
      } catch (_) {
        throw const BackupException('This file is not a LearnMath backup.');
      }
      final file = File(p.join(out, dataFile));
      if (!await file.exists()) {
        throw const BackupException('This file is not a LearnMath backup.');
      }
      final Object? decoded;
      try {
        decoded = jsonDecode(await file.readAsString());
      } on FormatException {
        throw const BackupException('This backup is damaged.');
      }
      if (decoded is! Map || decoded['format'] != _format) {
        throw const BackupException('This file is not a LearnMath backup.');
      }
      final Map data = decoded;
      final version = data['version'];
      if (version is! int || version > _version) {
        throw const BackupException(
            'This backup was made by a newer version of LearnMath. Update '
            'the app, then import it again.');
      }

      Map<String, Map<String, Object?>> records(String name) => {
            for (final e in (data[name] as Map? ?? const {}).entries)
              if (e.value is Map)
                '${e.key}': (e.value as Map).cast<String, Object?>(),
          };
      final lessons = records('lessons');
      final courses = records('courses');

      // Files first, so the records can say whether theirs came along.
      var audio = 0;
      for (final e in lessons.entries) {
        final moved = await _place(
            p.join(out, 'lessons', e.key, 'lecture.wav'),
            _paths.lessonAudio(e.key));
        final l = Map<String, Object?>.of(e.value);
        // Made again when the notes are opened.
        l['pdfPath'] = null;
        if (moved) {
          l['audioPath'] = _paths.lessonAudio(e.key);
          audio++;
        } else {
          l
            ..['audioPath'] = null
            ..['audioDurationMs'] = null
            ..['voice'] = null
            ..['lastPositionMs'] = 0;
        }
        // Work in flight cannot be picked up from another device, except a
        // batch, which is waited for by its id.
        final stage = LessonStage.values.asNameMap()[l['stage']];
        if (stage != null && stage.isWorking && l['batch'] == null) {
          l
            ..['stage'] = LessonStage.failed.name
            ..['error'] = _interrupted;
        }
        lessons[e.key] = l;
      }
      var books = 0;
      for (final e in courses.entries) {
        if (e.value['bookPath'] == null) continue;
        final moved = await _place(
            p.join(out, 'books', e.key, 'book.pdf'), _paths.bookPdf(e.key));
        if (moved) books++;
        courses[e.key] = Map<String, Object?>.of(e.value)
          ..['bookPath'] = _paths.bookPdf(e.key);
      }

      await _db.transaction((txn) async {
        for (final name in _mapStores) {
          final store = stringMapStoreFactory.store(name);
          final all = name == 'lessons'
              ? lessons
              : name == 'courses'
                  ? courses
                  : records(name);
          for (final e in all.entries) {
            await store.record(e.key).put(txn, e.value);
          }
        }
        final positions = StoreRef<String, int>('positions');
        for (final e in (data['positions'] as Map? ?? const {}).entries) {
          final ms = e.value;
          // Only where the recording it belongs to came along.
          if (ms is int && lessons['${e.key}']?['audioPath'] != null) {
            await positions.record('${e.key}').put(txn, ms);
          }
        }
      });

      final settings = data['settings'];
      return BackupSummary(
        courses: courses.length,
        lessons: lessons.length,
        recordings: audio,
        books: books,
        settings: settings is Map ? settings.cast<String, Object?>() : null,
      );
    } finally {
      if (await tmp.exists()) await tmp.delete(recursive: true);
    }
  }

  /// Moves an extracted file to where the app keeps it. False when the
  /// backup did not contain it.
  static Future<bool> _place(String from, String to) async {
    final source = File(from);
    if (!await source.exists()) return false;
    await File(to).parent.create(recursive: true);
    try {
      await source.rename(to);
    } on FileSystemException {
      // Another volume: copy instead.
      await source.copy(to);
    }
    return true;
  }
}
