import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:learnmath/core/models.dart';

import 'fakes.dart';

/// A [FakeEngine] whose recordings wait for [open], so a test can look at
/// the service while a lecture is being recorded.
class _GatedEngine extends FakeEngine {
  _GatedEngine(this.gate, this.recorded);
  final Completer<void> gate;
  final List<String> recorded;

  @override
  Future<Int16List> synthesize(String text) async {
    recorded.add(text);
    await gate.future;
    return super.synthesize(text);
  }
}

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

/// Waits (in real time) until [done] holds.
Future<void> _until(Future<bool> Function() done) async {
  for (var i = 0; i < 500; i++) {
    if (await done()) return;
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  fail('timed out');
}

void main() {
  late Env env;
  late Completer<void> gate;
  late List<String> recorded;

  setUp(() async {
    env = Env();
    gate = Completer<void>();
    recorded = <String>[];
    env.engine = () => _GatedEngine(gate, recorded);
    await env.init();
    env.settings = const AppSettings(apiKey: 'k', lessonPreset: 'luna');
  });
  tearDown(() async {
    if (!gate.isCompleted) gate.complete();
    await env.settle();
    await env.dispose();
  });

  /// Lesson 1 is being recorded and lesson 2, written meanwhile, waits for
  /// its turn.
  Future<List<String>> secondWaitingToRecord() async {
    final ids = await _course(env, 2);
    for (final id in ids) {
      env.service.enqueue(id);
    }
    await _until(() async => recorded.isNotEmpty);
    await _until(() async =>
        (await env.lesson('l2')).stage == LessonStage.synthesizingAudio);
    return ids;
  }

  test('the next lesson is written while the previous one is recorded',
      () async {
    await secondWaitingToRecord();

    final l1 = await env.lesson('l1');
    final l2 = await env.lesson('l2');
    expect(l1.stage, LessonStage.synthesizingAudio);
    expect(l1.hasAudio, isFalse);
    expect(l2.hasNotes, isTrue);
    expect(l2.segments, isNotEmpty);
    expect(l2.hasAudio, isFalse);
    expect(recorded, hasLength(1), reason: 'only lesson 1 is being recorded');
    expect(env.service.isQueued('l2'), isTrue);
    expect(env.progress.last, ('l2', 'Waiting to record…'));
    expect(env.keepAlive.calls.last, startsWith('hold'));
    expect(env.notifications.courses, isEmpty);

    gate.complete();
    await env.settle();
    for (final id in ['l1', 'l2']) {
      final l = await env.lesson(id);
      expect(l.stage, LessonStage.ready, reason: id);
      expect(l.hasAudio, isTrue, reason: id);
      expect(env.service.isQueued(id), isFalse);
    }
    // One at a time: lesson 1's three sentences, then lesson 2's.
    expect(recorded, hasLength(6));
    expect(env.notifications.courses.single.lessons, 2);
    expect(env.notifications.ready, isEmpty);
    expect(env.keepAlive.calls.last, 'release');
  });

  test('a lesson waiting to be recorded can be cancelled', () async {
    await secondWaitingToRecord();
    env.service.cancel('l2');
    await _until(
        () async => (await env.lesson('l2')).stage == LessonStage.failed);
    expect((await env.lesson('l2')).error, 'Cancelled.');
    expect(env.service.isQueued('l2'), isFalse);

    gate.complete();
    await env.settle();
    expect((await env.lesson('l1')).stage, LessonStage.ready);
    expect((await env.lesson('l2')).hasAudio, isFalse);
    expect(recorded, hasLength(3), reason: 'lesson 2 was never recorded');
    // Only lesson 1 became ready, so it is announced on its own.
    expect(env.notifications.ready.single.id, 'l1');
  });

  test('cancelling the lesson being recorded stops it, and the next one is '
      'recorded', () async {
    await secondWaitingToRecord();
    env.service.cancel('l1');
    gate.complete();
    await env.settle();

    final l1 = await env.lesson('l1');
    expect(l1.stage, LessonStage.failed);
    expect(l1.error, 'Cancelled.');
    expect(l1.hasAudio, isFalse);
    expect(l1.segments, isNotEmpty, reason: 'the script is kept');
    final l2 = await env.lesson('l2');
    expect(l2.stage, LessonStage.ready);
    expect(l2.hasAudio, isTrue);
  });

  test('a recording that fails is reported and the next one goes on',
      () async {
    var calls = 0;
    env.engine = () {
      calls++;
      return calls == 1 ? _FailingEngine() : _GatedEngine(gate, recorded);
    };
    gate.complete();
    final ids = await _course(env, 2);
    for (final id in ids) {
      env.service.enqueue(id);
    }
    await env.settle();

    final l1 = await env.lesson('l1');
    expect(l1.stage, LessonStage.failed);
    expect(l1.segments, isNotEmpty);
    expect(env.notifications.failed.single.id, 'l1');
    expect((await env.lesson('l2')).hasAudio, isTrue);

    // Retrying it records it, without asking the model again.
    final requests = env.fake.requests.length;
    env.service.enqueue('l1');
    await env.settle();
    expect((await env.lesson('l1')).hasAudio, isTrue);
    expect(env.fake.requests.length, requests);
  });
}

class _FailingEngine extends FakeEngine {
  @override
  Future<Int16List> synthesize(String text) async =>
      throw Exception('voice model broke');
}
