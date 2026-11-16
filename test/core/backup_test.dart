import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:learnmath/core/backup.dart';
import 'package:learnmath/core/models.dart';
import 'package:learnmath/core/storage.dart';
import 'package:learnmath/quiz/quiz_models.dart';
import 'package:learnmath/quiz/quiz_store.dart';
import 'package:sembast/sembast_memory.dart';

/// One phone: its own database and its own folders.
class _Phone {
  late Database db;
  late AppPaths paths;
  late LibraryRepository repo;
  late BackupService backup;
  static var _n = 0;

  Future<void> open(Directory root, String name) async {
    paths = AppPaths(
        docs: '${root.path}/$name/docs', support: '${root.path}/$name/support');
    db = await newDatabaseFactoryMemory().openDatabase('backup${_n++}');
    repo = LibraryRepository(db, paths);
    backup = BackupService(db, paths);
  }
}

void main() {
  late Directory root;
  late _Phone old;
  late _Phone fresh;
  late String zip;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('backup_test');
    old = _Phone();
    fresh = _Phone();
    await old.open(root, 'old');
    await fresh.open(root, 'new');
    zip = '${root.path}/out/backup.zip';

    // A book course with its PDF, and a standalone lesson with a recording.
    final book = File(old.paths.bookPdf('c1'));
    await book.parent.create(recursive: true);
    await book.writeAsString('%PDF book');
    await old.repo.saveCourse(Course(
        id: 'c1',
        title: 'Rudin',
        description: 'd',
        createdAt: DateTime(2026),
        bookPath: book.path,
        bookPageCount: 3));
    final audio = File(old.paths.lessonAudio('l1'));
    await audio.parent.create(recursive: true);
    await audio.writeAsBytes(List.filled(2000, 7));
    await old.repo.saveLesson(Lesson(
      id: 'l1',
      title: 'Compactness',
      brief: 'b',
      createdAt: DateTime(2026),
      stage: LessonStage.ready,
      notesMarkdown: '# Compactness',
      segments: const [NarrationSegment(say: 'Hello.', startMs: 0, endMs: 900)],
      audioPath: audio.path,
      audioDurationMs: 900,
      voice: 'Piper LJSpeech',
      pdfPath: '${old.paths.docs}/lessons/l1/notes.pdf',
      lastPositionMs: 300,
    ));
    // One that was being written, and one waiting for a batch.
    await old.repo.saveLesson(Lesson(
        id: 'l2',
        title: 'In flight',
        brief: 'b',
        createdAt: DateTime(2026),
        stage: LessonStage.generatingNarration,
        notesMarkdown: '# N'));
    await old.repo.saveLesson(Lesson(
        id: 'l3',
        courseId: 'c1',
        title: 'Waiting',
        brief: 'b',
        createdAt: DateTime(2026),
        stage: LessonStage.generatingNotes,
        batch: PendingBatch(
            id: 'batch_9', step: BatchStep.notes, submittedAt: DateTime(2026))));
    await old.repo.checkpointPosition('l1', 450);
    await QuizStore(old.db).save('l1', [
      Quiz(id: 'q1', createdAt: DateTime(2026), questions: const [
        QuizQuestion(prompt: 'Why?', answer: 'Because.'),
      ]),
    ]);
    // What SettingsStore keeps in the database: everything but the keys,
    // which live in secure storage.
    await StoreRef<String, Map<String, Object?>>('app').record('settings').put(
        old.db,
        const AppSettings(
                apiKey: 'secret-key', mathpixAppKey: 'secret-2', skipSeconds: 30)
            .toJson());
  });

  tearDown(() async {
    await old.db.close();
    await fresh.db.close();
    await root.delete(recursive: true);
  });

  test('without recordings: everything but the audio moves, and the lesson '
      'is left to be recorded again', () async {
    final out = await old.backup.export(zip, recordings: false);
    expect(out.lessons, 3);
    expect(out.courses, 1);
    expect(out.recordings, 0);
    expect(out.books, 1);

    final summary = await fresh.backup.import(zip);
    expect(summary.lessons, 3);
    expect(summary.recordings, 0);
    expect(summary.books, 1);

    final l1 = (await fresh.repo.getLesson('l1'))!;
    expect(l1.notesMarkdown, '# Compactness');
    expect(l1.segments.single.say, 'Hello.');
    expect(l1.stage, LessonStage.ready);
    expect(l1.audioPath, isNull);
    expect(l1.hasAudio, isFalse);
    expect(l1.voice, isNull);
    expect(l1.pdfPath, isNull);
    expect(l1.lastPositionMs, 0);
    expect(await fresh.repo.positionCheckpoint('l1'), isNull);

    // In-flight work cannot continue elsewhere; a batch can.
    final l2 = (await fresh.repo.getLesson('l2'))!;
    expect(l2.stage, LessonStage.failed);
    expect(l2.error, contains('retry'));
    final l3 = (await fresh.repo.getLesson('l3'))!;
    expect(l3.stage, LessonStage.generatingNotes);
    expect(l3.batch!.id, 'batch_9');

    final course = (await fresh.repo.getCourse('c1'))!;
    expect(course.bookPath, fresh.paths.bookPdf('c1'));
    expect(await File(course.bookPath!).readAsString(), '%PDF book');
    expect((await QuizStore(fresh.db).load('l1')).single.questions.single.prompt,
        'Why?');

    // Settings come back for the caller to apply, never with the keys.
    final settings = AppSettings.fromJson(summary.settings!);
    expect(settings.skipSeconds, 30);
    expect(settings.apiKey, isEmpty);
    expect(await File(zip).readAsBytes().then(String.fromCharCodes),
        isNot(contains('secret')));
  });

  test('with recordings: the audio and the listening position come along',
      () async {
    final out = await old.backup.export(zip, recordings: true);
    expect(out.recordings, 1);

    final summary = await fresh.backup.import(zip);
    expect(summary.recordings, 1);
    final l1 = (await fresh.repo.getLesson('l1'))!;
    expect(l1.audioPath, fresh.paths.lessonAudio('l1'));
    expect(await File(l1.audioPath!).length(), 2000);
    expect(l1.hasAudio, isTrue);
    expect(l1.voice, 'Piper LJSpeech');
    expect(l1.lastPositionMs, 300);
    expect(await fresh.repo.positionCheckpoint('l1'), 450);
  });

  test('importing merges: what is already here and not in the backup stays',
      () async {
    await fresh.repo.saveLesson(Lesson(
        id: 'mine', title: 'Mine', brief: '', createdAt: DateTime(2026)));
    await fresh.repo.saveLesson(Lesson(
        id: 'l1', title: 'Older copy', brief: '', createdAt: DateTime(2026)));
    await old.backup.export(zip, recordings: false);
    await fresh.backup.import(zip);

    expect((await fresh.repo.getLesson('mine'))!.title, 'Mine');
    expect((await fresh.repo.getLesson('l1'))!.title, 'Compactness');
    expect(await fresh.repo.getAllLessons(), hasLength(4));
  });

  test('a file that is no backup is refused and changes nothing', () async {
    final other = File('${root.path}/notes.zip');
    await other.writeAsString('not a zip at all');
    await expectLater(
        fresh.backup.import(other.path), throwsA(isA<BackupException>()));
    expect(await fresh.repo.getAllLessons(), isEmpty);
    expect(Directory('${fresh.paths.support}/backup-import').existsSync(),
        isFalse);
  });
}
