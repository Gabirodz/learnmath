import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:learnmath/core/models.dart';

import 'fakes.dart';

Future<List<String>> _course(Env env, int n) async {
  await env.repo.saveCourse(Course(
      id: 'c', title: 'Topology', description: 'd', createdAt: DateTime(2026)));
  final ids = <String>[];
  for (var i = 1; i <= n; i++) {
    ids.add('l$i');
    await env.repo.saveLesson(Lesson(
      id: 'l$i',
      courseId: 'c',
      order: i,
      title: 'Lesson $i',
      brief: 'brief $i',
      createdAt: DateTime(2026),
    ));
  }
  return ids;
}

void main() {
  late Env env;
  tearDown(() => env.dispose());

  const luna = AppSettings(apiKey: 'k', lessonPreset: 'luna');

  test('a course generated at once is announced once, when its last lesson '
      'is ready', () async {
    env = Env();
    await env.init();
    env.settings = luna;
    final ids = await _course(env, 3);
    for (final id in ids) {
      env.service.enqueue(id);
    }
    await env.settle();

    expect(env.notifications.ready, isEmpty);
    final c = env.notifications.courses.single;
    expect(c.id, 'c');
    expect(c.title, 'Topology');
    expect(c.lessons, 3);
  });

  test('one lesson of a course is announced as that lesson', () async {
    env = Env();
    await env.init();
    env.settings = luna;
    final ids = await _course(env, 3);
    env.service.enqueue(ids[1]);
    await env.settle();

    expect(env.notifications.courses, isEmpty);
    expect(env.notifications.ready.single.id, 'l2');
  });

  test('when the last lesson fails, the ones that are ready are still '
      'announced', () async {
    env = Env();
    await env.init();
    env.settings = luna;
    // Only the script of lesson 3 is unusable. (Every request names all
    // three lessons in its course outline.)
    env.fake.scriptAnswer = (body) =>
        jsonEncode(body).contains(r'for the lesson \"Lesson 3\"')
            ? 'Sorry.'
            : scriptFor('S');
    final ids = await _course(env, 3);
    for (final id in ids) {
      env.service.enqueue(id);
    }
    await env.settle();

    expect((await env.lesson('l3')).stage, LessonStage.failed);
    expect(env.notifications.failed.single.id, 'l3');
    expect(env.notifications.courses.single.lessons, 2);
    expect(env.notifications.ready, isEmpty);
  });

  test('the waiting label says which answer is being waited for', () async {
    env = Env();
    await env.init();
    env.settings = const AppSettings(apiKey: 'k');
    final ids = await _course(env, 1);
    env.service.enqueue(ids.single);
    await env.settle();
    expect(env.lastLabel('l1'), 'Waiting for the notes (batch queue)…');

    await env.finishAndPoll('batch_1');
    final l = await env.lesson('l1');
    expect(l.hasNotes, isTrue);
    expect(l.batch!.step, BatchStep.narration);
    expect(env.lastLabel('l1'),
        'Waiting for the lecture script (batch queue)…');
    expect(env.notifications.ready, isEmpty,
        reason: 'notes alone are not the finished lesson');

    await env.finishAndPoll('batch_2');
    expect((await env.lesson('l1')).stage, LessonStage.ready);
    expect(env.notifications.ready.single.id, 'l1');
  });
}
