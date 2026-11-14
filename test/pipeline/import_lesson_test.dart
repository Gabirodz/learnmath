import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:learnmath/ai/lesson_import.dart';
import 'package:learnmath/ai/narration_parser.dart';
import 'package:learnmath/checks/math_check.dart';
import 'package:learnmath/core/models.dart';
import 'package:learnmath/pipeline/generation_service.dart';

import 'fakes.dart';

const _answer = '<<<NOTES\n'
    '# Banach Fixed-Point Theorem\n\n'
    r'A contraction on a complete space has one fixed point $x^*$.'
    '\nNOTES>>>\n'
    '<<<CHECKS\n'
    'CHECK: Example A\nassert 2 + 2 == 4\n'
    'CHECK: Example B\nassert 3 * 3 == 9\n'
    'CHECKS>>>\n'
    '<<<SCRIPT\n'
    'SECTION: Intro\nSAY: One.\nSAY: Two.\nSAY: Three.\n'
    'SCRIPT>>>';

void main() {
  late Env env;
  tearDown(() => env.dispose());

  test('an imported lesson is checked and recorded without a key or a '
      'model request', () async {
    final runner = FakeRunner([passed(2)]);
    env = Env();
    await env.init(runner: runner);
    env.settings = const AppSettings();

    final id = await env.service.importLesson(parseImportedLesson(_answer));
    await env.settle();
    final l = await env.lesson(id);

    expect(l.stage, LessonStage.ready);
    expect(l.error, isNull);
    expect(l.title, 'Banach Fixed-Point Theorem');
    expect(l.checkReport!.outcomes, hasLength(2));
    expect(l.checkReport!.failed, isEmpty);
    expect(l.segments, hasLength(3));
    expect(l.segments.first.startMs, isNotNull);
    expect(File(l.audioPath!).existsSync(), isTrue);
    expect(env.fake.requests, isEmpty);
    expect(env.notifications.ready.single.id, id);
  });

  test('failed checks are reported; the imported notes are not rewritten',
      () async {
    final runner = FakeRunner([
      [CheckStatus.passed, CheckStatus.failed],
    ]);
    env = Env();
    await env.init(runner: runner);
    env.settings = const AppSettings(apiKey: 'k', lessonPreset: 'luna');

    final imported = parseImportedLesson(_answer);
    final id = await env.service.importLesson(imported);
    await env.settle();
    final l = await env.lesson(id);

    expect(l.stage, LessonStage.ready);
    expect(l.checkReport!.failed, hasLength(1));
    expect(l.notesMarkdown, imported.notes);
    expect(env.fake.requests, isEmpty);
  });

  test('notes without a script: the script is written here, with a key',
      () async {
    env = Env();
    await env.init(runner: FakeRunner([passed(2)]));
    env.settings = const AppSettings(apiKey: 'k', lessonPreset: 'luna');

    final id = await env.service.importLesson(parseImportedLesson(
        _answer.substring(0, _answer.indexOf('<<<SCRIPT'))));
    await env.settle();
    final l = await env.lesson(id);

    expect(l.stage, LessonStage.ready);
    expect(l.segments, hasLength(3));
    expect(env.fake.requests, hasLength(1), reason: 'only the script');
    expect(l.notesMarkdown, startsWith('# Banach'));
  });

  test('notes without a script and without a key fail asking for the key',
      () async {
    env = Env();
    await env.init();
    env.settings = const AppSettings();

    final id = await env.service.importLesson(parseImportedLesson(
        _answer.substring(0, _answer.indexOf('<<<CHECKS'))));
    await env.settle();
    final l = await env.lesson(id);

    expect(l.stage, LessonStage.failed);
    expect(l.error, const MissingApiKey().toString());
  });

  test('an imported course has its lessons pending, in order; a lesson '
      'imported into one keeps its title and place', () async {
    env = Env();
    await env.init(runner: FakeRunner([passed(2)]));
    env.settings = const AppSettings();

    final courseId = await env.service.importCourse(parseOutline(
        'COURSE: Fixed Points\nDESCRIPTION: Contractions and beyond.\n'
        'LESSON: Metric spaces\nBRIEF: Completeness.\n'
        'LESSON: Contractions\nBRIEF: The Banach theorem.\n'));
    final course = (await env.repo.getCourse(courseId))!;
    expect(course.title, 'Fixed Points');
    expect(course.description, 'Contractions and beyond.');
    var lessons = await env.repo.getCourseLessons(courseId);
    expect(lessons.map((l) => l.title), ['Metric spaces', 'Contractions']);
    expect(lessons.every((l) => l.stage == LessonStage.pending), isTrue);
    expect(env.fake.requests, isEmpty);

    final second = lessons[1];
    final context = (await env.service.courseContext(second))!;
    expect(context.lessonIndex, 1);
    expect(context.lessonTitles, hasLength(2));

    final id = await env.service
        .importLesson(parseImportedLesson(_answer), into: second.id);
    await env.settle();
    expect(id, second.id);
    final l = await env.lesson(id);
    expect(l.stage, LessonStage.ready);
    expect(l.title, 'Contractions', reason: 'the planned title stays');
    expect(l.courseId, courseId);
    expect(l.order, 1);
    expect(l.notesMarkdown, startsWith('# Banach'));
    expect(l.checkReport!.outcomes, hasLength(2));
    expect(l.audioPath, isNotNull);
    expect(env.fake.requests, isEmpty);
    lessons = await env.repo.getCourseLessons(courseId);
    expect(lessons, hasLength(2));
    expect(lessons.first.stage, LessonStage.pending);
  });

  test('importing into a lesson that was deleted fails', () async {
    env = Env();
    await env.init();
    expect(
        env.service.importLesson(parseImportedLesson(_answer), into: 'gone'),
        throwsStateError);
  });

  test('a lecture remembers the voice it was recorded with, and a new '
      'recording the new one', () async {
    env = Env();
    await env.init();
    env.settings = const AppSettings(voiceModel: 'kokoro', voiceSpeaker: 7);
    final id = await env.service.importLesson(parseImportedLesson(_answer));
    await env.settle();
    expect((await env.lesson(id)).voice, 'Kokoro · Emma (UK, female)');

    env.settings = const AppSettings(voiceModel: 'piper-lessac');
    await env.service.rerecord(id);
    await env.settle();
    final l = await env.lesson(id);
    expect(l.voice, 'Piper Lessac · Lessac (US, female)');
    expect(Lesson.fromJson(l.toJson()).voice, l.voice);

    env.settings = const AppSettings(
        ttsBackend: TtsBackend.openRouter,
        apiKey: 'k',
        openRouterTtsModel: 'some/voice-model',
        openRouterTtsVoice: 'gareth');
    await env.service.rerecord(id);
    await env.settle();
    expect((await env.lesson(id)).voice, 'some/voice-model · gareth');
  });

  test('recording a finished lesson again needs no key', () async {
    env = Env();
    await env.init();
    env.settings = const AppSettings(apiKey: 'k', lessonPreset: 'luna');
    final id = await env.create();
    final requests = env.fake.requests.length;

    env.settings = const AppSettings();
    await env.service.rerecord(id);
    await env.settle();
    final l = await env.lesson(id);

    expect(l.stage, LessonStage.ready);
    expect(l.audioPath, isNotNull);
    expect(env.fake.requests, hasLength(requests));
  });
}
