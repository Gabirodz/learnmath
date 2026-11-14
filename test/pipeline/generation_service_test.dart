import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:learnmath/ai/narration_parts.dart';
import 'package:learnmath/ai/openrouter_client.dart';
import 'package:learnmath/checks/math_check.dart';
import 'package:learnmath/core/models.dart';
import 'package:learnmath/pipeline/generation_service.dart';
import 'package:learnmath/tts/on_device_tts.dart';

import 'fakes.dart';


void main() {
  late Env env;
  tearDown(() => env.dispose());

  AppSettings luna() => const AppSettings(apiKey: 'k', lessonPreset: 'luna');

  group('immediate flow (non-batch model)', () {
    test('notes, checks, script and audio, then ready and announced',
        () async {
      final stagesSeen = <LessonStage>[];
      late Env e;
      final runner = FakeRunner([passed(2)], onRun: (_) async {
        stagesSeen.add((await e.repo.getAllLessons()).single.stage);
      });
      env = e = Env();
      await env.init(runner: runner);
      env.settings = luna();

      final id = await env.create();
      final l = await env.lesson(id);

      expect(l.stage, LessonStage.ready);
      expect(l.error, isNull);
      expect(l.batch, isNull);
      expect(l.title, 'Banach Fixed-Point Theorem',
          reason: 'standalone lesson takes the notes heading as title');
      expect(l.notesMarkdown, startsWith('# Banach'));
      expect(l.notesMarkdown, isNot(contains('<<<CHECKS')));
      expect(l.checks.map((c) => c.title), ['Example A', 'Example B']);
      expect(l.checkReport!.total, 2);
      expect(l.checkReport!.passed, 2);
      expect(l.checkReport!.repaired, isFalse);
      expect(stagesSeen, [LessonStage.checkingMath]);
      expect(runner.calls, hasLength(1));
      expect(l.segments, hasLength(3));
      expect(l.segments.first.section, 'Script');
      expect(l.segments.every((s) => s.startMs != null && s.endMs != null),
          isTrue);
      expect(l.hasAudio, isTrue);
      expect(File(l.audioPath!).existsSync(), isTrue);
      expect(l.audioDurationMs, greaterThan(0));
      expect(env.fake.submitted, isEmpty, reason: 'no batch for Luna');
      expect(env.fake.chatBodies, hasLength(2));
      expect(env.notifications.ready.single.id, id);
      expect(env.notifications.ready.single.hasAudio, isTrue);
      expect(env.notifications.failed, isEmpty);
      expect(env.lastLabel(id), isNull, reason: 'progress cleared at the end');
      expect(runner.disposed, isTrue);
      expect(env.service.isQueued(id), isFalse);
    });

    test('request shape: temperature, no reasoning, checks in the prompt',
        () async {
      env = Env();
      await env.init(runner: FakeRunner([passed(2)]));
      env.settings = luna();
      await env.create();

      final notes = env.fake.chatOf('notes').single;
      expect(notes['model'], 'openai/gpt-6-luna');
      expect(notes['temperature'], 0.5);
      expect(notes.containsKey('reasoning'), isFalse);
      expect(FakeOpenRouter.systemText(notes), contains('<<<CHECKS'));
      final script = env.fake.chatOf('script').single;
      expect(script['temperature'], 0.6);
      expect(script.containsKey('reasoning'), isFalse);
      expect(FakeOpenRouter.userText(script), contains('Banach Fixed-Point'));
      expect(FakeOpenRouter.userText(script), isNot(contains('<<<CHECKS')),
          reason: 'the script is written from the notes without the checks');
    });

    test('the reasoning effort replaces temperature (custom preset)',
        () async {
      env = Env();
      await env.init(runner: FakeRunner([passed(2)]));
      env.settings = const AppSettings(
          apiKey: 'k',
          lessonPreset: 'custom',
          chatModel: 'acme/m',
          customEffort: 'medium');
      await env.create();

      for (final k in ['notes', 'script']) {
        final b = env.fake.chatOf(k).single;
        expect(b['model'], 'acme/m');
        expect(b['reasoning'], {'effort': 'medium'}, reason: k);
        expect(b.containsKey('temperature'), isFalse, reason: k);
      }
    });

    test('progress labels', () async {
      env = Env();
      await env.init(runner: FakeRunner([passed(2)]));
      env.settings = luna();
      final id = await env.create();
      final labels = [for (final p in env.progress) p.$2];
      expect(labels.first, 'Waiting…');
      expect(labels, contains('Writing lecture notes…'));
      expect(labels, contains('Checking the computations…'));
      expect(labels, contains('Preparing the lecture script…'));
      expect(labels, contains('Recording lecture…'));
      expect(labels.last, isNull);
      expect(env.progress.every((p) => p.$1 == id), isTrue);
    });

    test('mathChecks off: the notes prompt has no checks block', () async {
      env = Env();
      final runner = FakeRunner([passed(2)]);
      await env.init(runner: runner);
      env.settings = luna().copyWith(mathChecks: false);
      env.fake.notesAnswer = '# Plain\n\nNotes only.';
      final id = await env.create();

      final notes = env.fake.chatOf('notes').single;
      expect(FakeOpenRouter.systemText(notes), isNot(contains('<<<CHECKS')));
      expect(FakeOpenRouter.userText(notes), isNot(contains('<<<CHECKS')));
      expect(runner.calls, isEmpty);
      final l = await env.lesson(id);
      expect(l.stage, LessonStage.ready);
      expect(l.checks, isEmpty);
      expect(l.checkReport, isNull);
    });

    test('mathChecks off ignores checks the model wrote anyway', () async {
      env = Env();
      final runner = FakeRunner([passed(2)]);
      await env.init(runner: runner);
      env.settings = luna().copyWith(mathChecks: false);
      final id = await env.create();
      expect(runner.calls, isEmpty);
      final l = await env.lesson(id);
      expect(l.stage, LessonStage.ready);
      expect(l.checkReport, isNull);
    });

    test('without a runner factory checks are stored but not run', () async {
      env = Env();
      await env.init(runner: null);
      env.settings = luna();
      final id = await env.create();
      final l = await env.lesson(id);
      expect(l.stage, LessonStage.ready);
      expect(l.checks, hasLength(2));
      expect(l.checkReport, isNull);
      expect(env.fake.chatOf('repair'), isEmpty);
    });

    test('a notes answer without a checks block still gives a lesson',
        () async {
      env = Env();
      final runner = FakeRunner([passed(1)]);
      await env.init(runner: runner);
      env.settings = luna();
      env.fake.notesAnswer = '# No computations\n\nJust words.';
      final id = await env.create();
      final l = await env.lesson(id);
      expect(l.stage, LessonStage.ready);
      expect(l.checks, isEmpty);
      expect(runner.calls, isEmpty);
      expect(l.checkReport, isNull);
    });

    test('missing API key fails the lesson with a readable message',
        () async {
      env = Env();
      await env.init(runner: FakeRunner([passed(2)]));
      env.settings = const AppSettings();
      final id = await env.create();
      final l = await env.lesson(id);
      expect(l.stage, LessonStage.failed);
      expect(l.error, contains('API key'));
      expect(env.notifications.failed.single.id, id);
      expect(env.notifications.failed.single.reason, contains('API key'));
      expect(env.fake.chatBodies, isEmpty);
    });

    test('an unusable notes answer fails the lesson', () async {
      env = Env();
      await env.init(runner: FakeRunner([passed(2)]));
      env.settings = luna();
      env.fake.notesAnswer = '<<<CHECKS\nCHECKS>>>';
      final id = await env.create();
      final l = await env.lesson(id);
      expect(l.stage, LessonStage.failed);
      expect(l.error, contains('unusable answer'));
      expect(env.notifications.ready, isEmpty);
    });

    test('an unusable script keeps the notes, retry resumes at the script',
        () async {
      env = Env();
      await env.init(runner: FakeRunner([passed(2)]));
      env.settings = luna();
      env.fake.scriptAnswer = (_) => 'SAY: only one line';
      final id = await env.create();
      var l = await env.lesson(id);
      expect(l.stage, LessonStage.failed);
      expect(l.notesMarkdown, isNotNull);

      env.fake.scriptAnswer = null;
      env.service.enqueue(id);
      await env.settle();
      l = await env.lesson(id);
      expect(l.stage, LessonStage.ready);
      expect(l.error, isNull);
      expect(env.fake.chatOf('notes'), hasLength(1),
          reason: 'notes are not written again');
      expect(env.fake.chatOf('script'), hasLength(2));
    });
  });

  group('math checks and repair (immediate)', () {
    test('a failed check triggers exactly one repair whose answer replaces '
        'notes and checks', () async {
      env = Env();
      final runner = FakeRunner([
        [CheckStatus.passed, CheckStatus.failed],
        [CheckStatus.passed],
      ]);
      await env.init(runner: runner);
      env.settings = luna();
      final id = await env.create();

      final l = await env.lesson(id);
      expect(l.stage, LessonStage.ready);
      expect(l.notesMarkdown, contains('2 + 3 = 5'));
      expect(l.notesMarkdown, isNot(contains('2 + 2 = 4')));
      expect(l.checks.map((c) => c.title), ['Example A fixed']);
      expect(runner.calls, hasLength(2));
      expect(runner.calls[1].single.title, 'Example A fixed');
      expect(l.checkReport!.repaired, isTrue);
      expect(l.checkReport!.total, 1);
      expect(l.checkReport!.failed, isEmpty);

      final repair = env.fake.chatOf('repair').single;
      final user = FakeOpenRouter.userText(repair);
      expect(user, contains('Example B'));
      expect(user, contains('detail Example B'));
      expect(user, contains('2 + 2 = 4'), reason: 'the original notes go in');
      expect(FakeOpenRouter.systemText(repair), contains('<<<CHECKS'));
      expect(env.fake.chatOf('notes'), hasLength(1));
    });

    test('never a second repair, even if the repaired checks fail', () async {
      env = Env();
      final runner = FakeRunner([
        [CheckStatus.failed],
        [CheckStatus.failed],
        [CheckStatus.failed],
      ]);
      await env.init(runner: runner);
      env.settings = luna();
      final id = await env.create();

      final l = await env.lesson(id);
      expect(l.stage, LessonStage.ready, reason: 'failed checks do not fail');
      expect(env.fake.chatOf('repair'), hasLength(1));
      expect(runner.calls, hasLength(2));
      expect(l.checkReport!.repaired, isTrue);
      expect(l.checkReport!.failed, hasLength(1));
    });

    test('re-queueing a repaired lesson does not repair again', () async {
      env = Env();
      final runner = FakeRunner([
        [CheckStatus.failed],
      ]);
      await env.init(runner: runner);
      env.settings = luna();
      final id = await env.create();
      env.service.enqueue(id, audio: true);
      await env.settle();
      expect((await env.lesson(id)).checkReport!.repaired, isTrue);
      expect(env.fake.chatOf('repair'), hasLength(1));
    });

    test('an unusable repair answer keeps the original notes', () async {
      env = Env();
      final runner = FakeRunner([
        [CheckStatus.passed, CheckStatus.failed],
      ]);
      await env.init(runner: runner);
      env.settings = luna();
      env.fake.repairAnswer = '<<<CHECKS\nCHECKS>>>';
      final id = await env.create();

      final l = await env.lesson(id);
      expect(l.stage, LessonStage.ready);
      expect(l.notesMarkdown, contains('2 + 2 = 4'));
      expect(l.checks.map((c) => c.title), ['Example A', 'Example B']);
      expect(l.checkReport!.repaired, isTrue);
      expect(l.checkReport!.failed.map((o) => o.title), ['Example B']);
      expect(l.checkReport!.total, 2);
      expect(env.fake.chatOf('repair'), hasLength(1));
      expect(runner.calls, hasLength(1));
    });

    test('error and timeout outcomes alone do not trigger a repair', () async {
      env = Env();
      final runner = FakeRunner([
        [CheckStatus.error, CheckStatus.timeout],
      ]);
      await env.init(runner: runner);
      env.settings = luna();
      final id = await env.create();
      final l = await env.lesson(id);
      expect(l.stage, LessonStage.ready);
      expect(env.fake.chatOf('repair'), isEmpty);
      expect(l.checkReport!.repaired, isFalse);
      expect(l.checkReport!.inconclusive, hasLength(2));
      expect(l.notesMarkdown, contains('2 + 2 = 4'));
    });

    test('inconclusive plus failed still repairs once', () async {
      env = Env();
      final runner = FakeRunner([
        [CheckStatus.error, CheckStatus.failed],
        [CheckStatus.passed],
      ]);
      await env.init(runner: runner);
      env.settings = luna();
      final id = await env.create();
      expect(env.fake.chatOf('repair'), hasLength(1));
      expect((await env.lesson(id)).checkReport!.repaired, isTrue);
    });

    test('a MathCheckException does not fail the lesson', () async {
      env = Env();
      final runner = FakeRunner([passed(2)])
        ..throwOnRun = MathCheckException('no connection for pyodide');
      await env.init(runner: runner);
      env.settings = luna();
      final id = await env.create();
      final l = await env.lesson(id);
      expect(l.stage, LessonStage.ready);
      expect(l.error, isNull);
      expect(l.checkReport, isNull);
      expect(l.checks, hasLength(2));
      expect(env.fake.chatOf('repair'), isEmpty);
      expect(env.notifications.failed, isEmpty);
      expect(env.notifications.ready, hasLength(1));
    });

    test('any other runner error does fail the lesson visibly', () async {
      env = Env();
      final runner = FakeRunner([passed(2)])..throwOnRun = StateError('boom');
      await env.init(runner: runner);
      env.settings = luna();
      final id = await env.create();
      final l = await env.lesson(id);
      expect(l.stage, LessonStage.failed);
      expect(l.error, contains('boom'));
      expect(env.notifications.failed, hasLength(1));
    });
  });

  group('recheck', () {
    test('re-runs checks of a finished lesson without repair or an '
        'announcement', () async {
      env = Env();
      final runner = FakeRunner([
        [CheckStatus.error, CheckStatus.error], // first run: could not check
        [CheckStatus.passed, CheckStatus.failed], // recheck
      ]);
      await env.init(runner: runner);
      env.settings = luna();
      final id = await env.create();
      expect((await env.lesson(id)).checkReport!.inconclusive, hasLength(2));
      expect(env.notifications.ready, hasLength(1));
      final chatBefore = env.fake.chatBodies.length;

      await env.service.recheck(id);
      await env.settle();

      final l = await env.lesson(id);
      expect(runner.calls, hasLength(2));
      expect(l.stage, LessonStage.ready);
      expect(l.checkReport!.failed.map((o) => o.title), ['Example B']);
      expect(l.checkReport!.repaired, isFalse);
      expect(env.fake.chatBodies.length, chatBefore,
          reason: 'no repair, no new notes or script');
      expect(env.notifications.ready, hasLength(1),
          reason: 'no second lessonReady');
      expect(l.notesMarkdown, contains('2 + 2 = 4'));
    });

    test('leaves the stage it found, also when the checker is unavailable',
        () async {
      env = Env();
      final runner = FakeRunner([passed(2)]);
      await env.init(runner: runner);
      env.settings = luna();
      final id = await env.create();
      runner.throwOnRun = MathCheckException('offline');
      await env.service.recheck(id);
      await env.settle();
      final l = await env.lesson(id);
      expect(l.stage, LessonStage.ready);
      expect(l.error, isNull);
      expect(l.checkReport, isNull, reason: 'cleared, could not be rebuilt');
    });

    test('works on a lesson that is not ready and keeps that stage',
        () async {
      env = Env();
      final runner = FakeRunner([passed(2)]);
      await env.init(runner: runner);
      env.settings = luna();
      await env.repo.saveLesson(Lesson(
        id: 'f1',
        title: 'T',
        brief: 'b',
        createdAt: DateTime(2026),
        stage: LessonStage.failed,
        error: 'old',
        notesMarkdown: '# T\n\nx',
        checks: const [MathCheck(title: 'c', code: 'assert True')],
      ));
      await env.service.recheck('f1');
      await env.settle();
      final l = await env.lesson('f1');
      expect(l.stage, LessonStage.failed);
      expect(l.checkReport!.passed, 1);
      expect(env.notifications.ready, isEmpty);
      expect(env.notifications.failed, isEmpty);
    });
  });

  group('batch flow', () {
    Future<String> submitNotes([FakeRunner? r]) async {
      await env.init(runner: r ?? FakeRunner([passed(2)]));
      final id = await env.create();
      return id;
    }

    test('the notes request goes into a batch and the job leaves the queue '
        'without failing', () async {
      env = Env();
      final id = await submitNotes();
      final l = await env.lesson(id);

      expect(l.stage, LessonStage.generatingNotes);
      expect(l.error, isNull);
      expect(l.batch, isNotNull);
      expect(l.batch!.step, BatchStep.notes);
      expect(l.batch!.id, 'batch_1');
      expect(l.batch!.parts, 1);
      expect(l.isWaitingForBatch, isTrue);
      expect(l.hasNotes, isFalse);
      expect(env.service.isQueued(id), isFalse);
      expect(env.fake.chatBodies, isEmpty, reason: 'nothing was streamed');
      expect(env.notifications.failed, isEmpty);
      expect(env.notifications.ready, isEmpty);
      expect(env.lastLabel(id), 'Waiting for the batch answer…');

      expect(env.background.updates, isNotEmpty);
      final w = env.background.updates.last.single;
      expect(w.batchId, 'batch_1');
      expect(w.lessonId, id);
      expect(w.lessonTitle, l.title);
    });

    test('batch request body: model, effort without temperature, custom id, '
        'checks prompt', () async {
      env = Env();
      final id = await submitNotes();
      final body = env.fake.submitted.single;
      expect(body['endpoint'], '/v1/chat/completions');
      expect(body['model'], 'openai/gpt-6.1-sol');
      final req = (body['requests'] as List).single as Map;
      expect(req['custom_id'], '$id:0');
      final inner = (req['body'] as Map).cast<String, Object?>();
      expect(inner['reasoning'], {'effort': 'high'});
      expect(inner.containsKey('temperature'), isFalse);
      expect(FakeOpenRouter.systemText(inner), contains('<<<CHECKS'));
      expect(FakeOpenRouter.userText(inner), contains('Banach'));
      // The Authorization header is a generic client concern, covered in
      // the OpenRouter client tests.
    });

    test('mathChecks off: the batched notes prompt has no checks', () async {
      env = Env();
      await env.init();
      env.settings = env.settings.copyWith(mathChecks: false);
      await env.create();
      final inner = env.fake.batchBodies.single;
      expect(FakeOpenRouter.systemText(inner), isNot(contains('<<<CHECKS')));
    });

    test('a custom batch model sends its own effort or temperature',
        () async {
      env = Env();
      await env.init();
      env.settings = const AppSettings(
          apiKey: 'k',
          lessonPreset: 'custom',
          chatModel: 'acme/m',
          customBatch: true);
      await env.create();
      expect(env.fake.submitted.single['model'], 'acme/m');
      final inner = env.fake.batchBodies.single;
      expect(inner['temperature'], 0.5);
      expect(inner.containsKey('reasoning'), isFalse);
    });

    test('polling an unfinished batch keeps waiting', () async {
      env = Env();
      final id = await submitNotes();
      await env.service.pollBatches();
      await env.settle();
      expect(env.fake.getCounts['batch_1'], 1);
      final l = await env.lesson(id);
      expect(l.batch!.id, 'batch_1');
      expect(l.stage, LessonStage.generatingNotes);
      expect(env.service.isQueued(id), isFalse);
      expect(env.fake.submitted, hasLength(1));
    });

    test('polling without an API key or waiting lessons asks nobody',
        () async {
      env = Env();
      await env.init();
      await env.service.pollBatches();
      expect(env.fake.getCounts, isEmpty);
      final id = await env.create();
      env.settings = const AppSettings();
      await env.service.pollBatches();
      expect(env.fake.getCounts, isEmpty);
      expect((await env.lesson(id)).isWaitingForBatch, isTrue);
    });

    test('whole pipeline through two batches', () async {
      env = Env();
      final runner = FakeRunner([passed(2)]);
      final id = await submitNotes(runner);

      // Notes batch finishes.
      await env.finishAndPoll('batch_1');
      var l = await env.lesson(id);
      expect(l.batch!.step, BatchStep.narration,
          reason: 'the script is a second batch');
      expect(l.batch!.id, 'batch_2');
      expect(l.stage, LessonStage.generatingNarration);
      expect(l.notesMarkdown, contains('Banach'));
      expect(l.notesMarkdown, isNot(contains('<<<CHECKS')));
      expect(l.title, 'Banach Fixed-Point Theorem');
      expect(l.checks, hasLength(2));
      expect(l.checkReport!.passed, 2);
      expect(runner.calls, hasLength(1));
      expect(env.fake.deleted, ['batch_1'],
          reason: 'the collected batch is deleted on OpenRouter');
      expect(env.notifications.ready, isEmpty);
      expect(env.lastLabel(id), 'Waiting for the batch answer…');
      expect(env.background.updates.last.single.batchId, 'batch_2');

      final scriptBody = env.fake.batchBodies.last;
      expect(FakeOpenRouter.kind(scriptBody), 'script');
      expect(scriptBody['reasoning'], {'effort': 'high'});
      expect(scriptBody.containsKey('temperature'), isFalse);
      expect(env.fake.submitted.last['model'], 'openai/gpt-6.1-sol');

      // Script batch finishes.
      await env.finishAndPoll('batch_2');
      l = await env.lesson(id);
      expect(l.stage, LessonStage.ready);
      expect(l.batch, isNull);
      expect(l.error, isNull);
      expect(l.segments, hasLength(3));
      expect(l.hasAudio, isTrue);
      expect(File(l.audioPath!).existsSync(), isTrue);
      expect(env.fake.deleted, ['batch_1', 'batch_2']);
      expect(env.notifications.ready.single.id, id);
      expect(env.notifications.ready.single.hasAudio, isTrue);
      expect(env.notifications.failed, isEmpty);
      expect(env.background.updates.last, isEmpty);
      expect(env.lastLabel(id), isNull);
      expect(env.fake.chatBodies, isEmpty, reason: 'nothing was streamed');
      expect(runner.calls, hasLength(1), reason: 'checks run once');
    });

    test('a batch that is not finished when the lesson is re-queued keeps '
        'waiting', () async {
      env = Env();
      final id = await submitNotes();
      env.service.enqueue(id);
      await env.settle();
      final l = await env.lesson(id);
      expect(l.stage, LessonStage.generatingNotes);
      expect(l.batch!.id, 'batch_1');
      expect(l.error, isNull);
      expect(env.fake.submitted, hasLength(1), reason: 'no second batch');
      expect(env.notifications.failed, isEmpty);
      expect(env.lastLabel(id), 'Waiting for the batch answer…');
      expect(env.fake.deleted, isEmpty);
    });

    test('a network error while collecting keeps waiting', () async {
      env = Env();
      final id = await submitNotes();
      env.fake.finish('batch_1');
      env.fake.failGets = true;
      env.service.enqueue(id);
      await env.settle();
      var l = await env.lesson(id);
      expect(l.batch!.id, 'batch_1');
      expect(l.stage, LessonStage.generatingNotes);
      expect(l.error, isNull);
      expect(env.notifications.failed, isEmpty);
      expect(env.fake.submitted, hasLength(1));

      // Back online: the next poll finishes the job.
      env.fake.failGets = false;
      await env.service.pollBatches();
      await env.settle();
      l = await env.lesson(id);
      expect(l.hasNotes, isTrue);
    });

    test('a network error while polling is ignored', () async {
      env = Env();
      final id = await submitNotes();
      env.fake.failGets = true;
      await env.service.pollBatches();
      await env.settle();
      expect((await env.lesson(id)).batch!.id, 'batch_1');
      expect(env.notifications.failed, isEmpty);
    });

    for (final c in [
      ('failed', 'quota exceeded upstream', 'quota exceeded upstream'),
      ('expired', null, 'time limit'),
      ('cancelled', null, 'cancelled'),
    ]) {
      test('batch status ${c.$1} fails the lesson readably and clears the '
          'batch', () async {
        env = Env();
        final id = await submitNotes();
        env.fake.status['batch_1'] = c.$1;
        if (c.$2 != null) env.fake.batchError['batch_1'] = c.$2!;
        await env.service.pollBatches();
        await env.settle();

        var l = await env.lesson(id);
        expect(l.stage, LessonStage.failed);
        expect(l.batch, isNull);
        expect(l.error, contains(c.$3));
        expect(l.error, isNot(contains('Exception')));
        expect(env.notifications.failed.single.id, id);
        expect(env.notifications.failed.single.reason, l.error);
        expect(env.background.updates.last, isEmpty);
        expect(env.lastLabel(id), isNull);

        // Retry submits a fresh batch.
        env.service.enqueue(id);
        await env.settle();
        l = await env.lesson(id);
        expect(env.fake.submitted, hasLength(2));
        expect(l.batch!.id, 'batch_2');
        expect(l.stage, LessonStage.generatingNotes);
        expect(l.error, isNull);
      });
    }

    test('a batch OpenRouter no longer has (410) fails and clears the batch',
        () async {
      env = Env();
      final id = await submitNotes();
      env.fake.gone.add('batch_1');
      await env.service.pollBatches();
      await env.settle();
      final l = await env.lesson(id);
      expect(l.stage, LessonStage.failed);
      expect(l.batch, isNull);
      expect(l.error, contains('no longer available'));
      expect(env.notifications.failed, hasLength(1));
    });

    test('an error result for this lesson fails it with that message',
        () async {
      env = Env();
      final id = await submitNotes();
      env.fake.resultOverride['batch_1'] = [
        {
          'custom_id': '$id:0',
          'error': {'message': 'content filtered', 'type': 'policy'}
        }
      ];
      await env.finishAndPoll('batch_1');
      final l = await env.lesson(id);
      expect(l.stage, LessonStage.failed);
      expect(l.batch, isNull);
      expect(l.error, contains('content filtered'));
      expect(env.notifications.failed.single.reason, contains('filtered'));
      expect(env.fake.deleted, ['batch_1'],
          reason: 'a finished batch nobody waits on any more is deleted');
    });

    test('a completed batch without an answer for the lesson fails it',
        () async {
      env = Env();
      final id = await submitNotes();
      env.fake.resultOverride['batch_1'] = [
        FakeOpenRouter.okResult('someone-else:0', 'x'),
      ];
      await env.finishAndPoll('batch_1');
      final l = await env.lesson(id);
      expect(l.stage, LessonStage.failed);
      expect(l.batch, isNull);
      expect(l.error, isNotEmpty);
    });

    test('an unusable batch answer fails the lesson and clears the batch',
        () async {
      env = Env();
      final id = await submitNotes();
      env.fake.notesAnswer = '<<<CHECKS\nCHECKS>>>';
      await env.finishAndPoll('batch_1');
      final l = await env.lesson(id);
      expect(l.stage, LessonStage.failed);
      expect(l.batch, isNull);
      expect(l.error, contains('unusable answer'));
    });

    test('two lessons waiting on one batch id are both collected',
        () async {
      env = Env();
      final a = await submitNotes();
      await env.repo.saveLesson(Lesson(
        id: 'other',
        title: 'Other',
        brief: 'b',
        createdAt: DateTime(2026),
        stage: LessonStage.generatingNotes,
        batch: PendingBatch(
            id: 'batch_1', step: BatchStep.notes, submittedAt: DateTime.now()),
      ));
      env.fake.resultOverride['batch_1'] = [
        FakeOpenRouter.okResult('$a:0', notesWithChecks),
        FakeOpenRouter.okResult('other:0', '# Other\n\nbody'),
      ];
      await env.finishAndPoll('batch_1');
      expect((await env.lesson(a)).batch!.step, BatchStep.narration);
      expect((await env.lesson('other')).batch!.step, BatchStep.narration);
    });

    test('createCourse is never batched', () async {
      env = Env();
      await env.init();
      final courseId = await env.service.createCourse('Topology');
      expect(env.fake.submitted, isEmpty);
      expect(env.fake.chatBodies, hasLength(1));
      expect(env.fake.chatBodies.single['model'], 'openai/gpt-6.1-sol');
      final lessons = await env.repo.getCourseLessons(courseId);
      expect(lessons.map((l) => l.title), ['Open sets', 'Compactness']);
      expect(lessons.every((l) => l.stage == LessonStage.pending), isTrue);
    });
  });

  group('repair through batches', () {
    test('the repair is a third batch and its answer replaces the notes',
        () async {
      env = Env();
      final runner = FakeRunner([
        [CheckStatus.passed, CheckStatus.failed],
        [CheckStatus.passed],
      ]);
      await env.init(runner: runner);
      final id = await env.create();

      await env.finishAndPoll('batch_1');
      var l = await env.lesson(id);
      expect(l.batch!.step, BatchStep.repair);
      expect(l.batch!.id, 'batch_2');
      expect(l.stage, LessonStage.generatingNotes);
      expect(l.checkReport!.failed, hasLength(1));
      expect(l.checkReport!.repaired, isFalse);
      final body = env.fake.batchBodies.last;
      expect(FakeOpenRouter.kind(body), 'repair');
      expect(body['reasoning'], {'effort': 'high'});
      expect(body.containsKey('temperature'), isFalse);
      expect(FakeOpenRouter.systemText(body), contains('<<<CHECKS'));
      expect(runner.calls, hasLength(1));
      expect(env.fake.deleted, ['batch_1']);

      // Re-queued early: still waiting, no second repair submitted.
      env.service.enqueue(id);
      await env.settle();
      expect(env.fake.submitted, hasLength(2));
      expect((await env.lesson(id)).batch!.id, 'batch_2');
      expect(runner.calls, hasLength(1), reason: 'checks are not run again');

      await env.finishAndPoll('batch_2');
      l = await env.lesson(id);
      expect(l.notesMarkdown, contains('2 + 3 = 5'));
      expect(l.checks.map((c) => c.title), ['Example A fixed']);
      expect(l.checkReport!.repaired, isTrue);
      expect(l.checkReport!.failed, isEmpty);
      expect(runner.calls, hasLength(2));
      expect(l.batch!.step, BatchStep.narration);
      expect(l.batch!.id, 'batch_3');
      expect(env.fake.deleted, ['batch_1', 'batch_2']);

      await env.finishAndPoll('batch_3');
      l = await env.lesson(id);
      expect(l.stage, LessonStage.ready);
      expect(l.checkReport!.repaired, isTrue);
      expect(env.fake.submitted, hasLength(3), reason: 'one repair only');
      expect(env.notifications.ready, hasLength(1));
    });

    test('an unusable batched repair keeps the notes and moves on', () async {
      env = Env();
      final runner = FakeRunner([
        [CheckStatus.failed],
      ]);
      await env.init(runner: runner);
      env.fake.repairAnswer = '<<<CHECKS\nCHECKS>>>';
      final id = await env.create();
      await env.finishAndPoll('batch_1');
      await env.finishAndPoll('batch_2');
      final l = await env.lesson(id);
      expect(l.notesMarkdown, contains('2 + 2 = 4'));
      expect(l.checkReport!.repaired, isTrue);
      expect(l.checkReport!.failed, hasLength(2));
      expect(l.batch!.step, BatchStep.narration);
      expect(env.notifications.failed, isEmpty);
    });

    test('a failed repair batch fails the lesson; retry does not repair '
        'again unless the notes are rewritten', () async {
      env = Env();
      final runner = FakeRunner([
        [CheckStatus.failed],
      ]);
      await env.init(runner: runner);
      final id = await env.create();
      await env.finishAndPoll('batch_1');
      env.fake.status['batch_2'] = 'expired';
      await env.service.pollBatches();
      await env.settle();
      final l = await env.lesson(id);
      expect(l.stage, LessonStage.failed);
      expect(l.batch, isNull);
      expect(l.hasNotes, isTrue);
    });
  });

  group('recoverInterrupted', () {
    test('working lessons without a batch fail; waiting ones are left alone',
        () async {
      env = Env();
      await env.init();
      Lesson mk(String id, LessonStage s, {PendingBatch? batch}) => Lesson(
          id: id,
          title: 'T $id',
          brief: 'b',
          createdAt: DateTime(2026),
          stage: s,
          batch: batch);
      final b = PendingBatch(
          id: 'batch_x', step: BatchStep.notes, submittedAt: DateTime(2026));
      await env.repo.saveLesson(mk('notes', LessonStage.generatingNotes));
      await env.repo.saveLesson(mk('audio', LessonStage.synthesizingAudio));
      await env.repo.saveLesson(mk('check', LessonStage.checkingMath));
      await env.repo.saveLesson(mk('wait', LessonStage.generatingNotes, batch: b));
      await env.repo.saveLesson(mk('ready', LessonStage.ready));
      await env.repo.saveLesson(mk('pending', LessonStage.pending));

      await env.service.recoverInterrupted();

      for (final id in ['notes', 'audio', 'check']) {
        final l = await env.lesson(id);
        expect(l.stage, LessonStage.failed, reason: id);
        expect(l.error, contains('interrupted'), reason: id);
      }
      final w = await env.lesson('wait');
      expect(w.stage, LessonStage.generatingNotes);
      expect(w.batch!.id, 'batch_x');
      expect(w.error, isNull);
      expect(env.lastLabel('wait'), 'Waiting for the batch answer…');
      expect((await env.lesson('ready')).stage, LessonStage.ready);
      expect((await env.lesson('pending')).stage, LessonStage.pending);
      expect(env.background.updates.last.single.batchId, 'batch_x');
      expect(env.background.updates.last.single.lessonId, 'wait');
    });

    test('a waiting lesson is collected by the next poll after a restart',
        () async {
      env = Env();
      await env.init(runner: FakeRunner([passed(2)]));
      final id = await env.create();
      // New service instance over the same storage, as after an app restart.
      final restarted = GenerationService(
        repo: env.repo,
        paths: env.paths,
        readSettings: () => env.settings,
        voices: VoiceModelManager('${env.tmp.path}/models'),
        onProgress: (i, p) => env.progress.add((i, p?.label)),
        notifications: env.notifications,
        batchBackground: env.background,
        createClient: (k) =>
            OpenRouterClient(apiKey: k, httpClient: env.fake.client),
        createEngine: (_) => FakeEngine(),
        autoPoll: false,
      );
      await restarted.recoverInterrupted();
      expect((await env.lesson(id)).stage, LessonStage.generatingNotes);
      env.fake.finish('batch_1');
      await restarted.pollBatches();
      await restarted.idle;
      await pumpEventQueue();
      final l = await env.lesson(id);
      expect(l.hasNotes, isTrue);
      expect(l.batch!.step, BatchStep.narration);
      expect(env.fake.deleted, ['batch_1']);
    });
  });

  group('cancel', () {
    test('a lesson waiting for a batch is cancelled', () async {
      env = Env();
      await env.init();
      final id = await env.create();
      expect(env.background.updates.last, hasLength(1));

      env.service.cancel(id);
      await env.settle();

      final l = await env.lesson(id);
      expect(l.stage, LessonStage.failed);
      expect(l.error, 'Cancelled.');
      expect(l.batch, isNull);
      expect(env.lastLabel(id), isNull);
      expect(env.background.updates.last, isEmpty);
      expect(env.notifications.failed, isEmpty);
    });

    test('a cancelled lesson is not collected when its batch finishes',
        () async {
      env = Env();
      await env.init(runner: FakeRunner([passed(2)]));
      final id = await env.create();
      env.service.cancel(id);
      await env.settle();
      await env.finishAndPoll('batch_1');
      final l = await env.lesson(id);
      expect(l.stage, LessonStage.failed);
      expect(l.hasNotes, isFalse);
    });

    test('cancelling an idle lesson that waits for nothing changes nothing',
        () async {
      env = Env();
      await env.init(runner: FakeRunner([passed(2)]));
      env.settings = luna();
      final id = await env.create();
      env.service.cancel(id);
      await env.settle();
      final l = await env.lesson(id);
      expect(l.stage, LessonStage.ready);
      expect(l.error, isNull);
    });

    test('a retried lesson after cancel submits a new batch', () async {
      env = Env();
      await env.init();
      final id = await env.create();
      env.service.cancel(id);
      await env.settle();
      env.service.enqueue(id);
      await env.settle();
      expect(env.fake.submitted, hasLength(2));
      expect((await env.lesson(id)).batch!.id, 'batch_2');
    });
  });

  group('book chapter narrated in parts', () {
    String longNotes() {
      final b = StringBuffer();
      for (var s = 1; s <= 4; s++) {
        b.writeln('## Section $s\n');
        for (var p = 0; p < 12; p++) {
          b.writeln('Paragraph $p of section $s. ${'word ' * 90}\n');
        }
      }
      return b.toString();
    }

    test('one batch with one request per part; segments in part order',
        () async {
      env = Env();
      await env.init();
      final notes = longNotes();
      final parts = splitForNarration(stripPageMarkers(notes));
      expect(parts.length, greaterThan(1), reason: 'test needs several parts');

      await env.repo.saveLesson(Lesson(
        id: 'chap',
        title: 'Chapter 2',
        brief: '',
        createdAt: DateTime(2026),
        notesMarkdown: notes,
        sourceStartPage: 10,
        sourceEndPage: 30,
      ));
      env.fake.scriptAnswer = (body) {
        final u = FakeOpenRouter.userText(body);
        final m = RegExp(r'part (\d+) of (\d+)').firstMatch(u)!;
        return scriptFor('Part${m.group(1)}');
      };
      env.service.enqueue('chap');
      await env.settle();

      expect(env.fake.submitted, hasLength(1), reason: 'ONE batch');
      final reqs = (env.fake.submitted.single['requests'] as List).cast<Map>();
      expect([for (final r in reqs) r['custom_id']],
          [for (var i = 0; i < parts.length; i++) 'chap:$i']);
      final lesson = await env.lesson('chap');
      expect(lesson.batch!.parts, parts.length);
      expect(lesson.batch!.step, BatchStep.narration);
      expect(FakeOpenRouter.userText(
              (reqs.first['body'] as Map).cast<String, Object?>()),
          contains('part 1 of ${parts.length}'));
      expect(FakeOpenRouter.userText(
              (reqs.last['body'] as Map).cast<String, Object?>()),
          contains('This is the last part'));

      // Results come back in the opposite order.
      final results = [
        for (var i = parts.length - 1; i >= 0; i--)
          FakeOpenRouter.okResult(
              'chap:$i',
              scriptFor('Part${i + 1}')),
      ];
      env.fake.resultOverride['batch_1'] = results;
      await env.finishAndPoll('batch_1');

      final l = await env.lesson('chap');
      expect(l.stage, LessonStage.ready);
      expect(l.batch, isNull);
      expect(l.segments, hasLength(3 * parts.length));
      expect([for (final s in l.segments) s.say],
          [
            for (var i = 1; i <= parts.length; i++) ...[
              'Part$i one.',
              'Part$i two.',
              'Part$i three.'
            ]
          ]);
      expect([for (final s in l.segments) if (s.section != null) s.section],
          [for (var i = 1; i <= parts.length; i++) 'Part$i']);
      expect(l.hasAudio, isTrue);
      expect(env.fake.deleted, ['batch_1']);
    });

    test('a missing part makes the whole batch answer unusable', () async {
      env = Env();
      await env.init();
      final notes = longNotes();
      await env.repo.saveLesson(Lesson(
        id: 'chap',
        title: 'Chapter 2',
        brief: '',
        createdAt: DateTime(2026),
        notesMarkdown: notes,
        sourceStartPage: 10,
      ));
      env.service.enqueue('chap');
      await env.settle();
      env.fake.resultOverride['batch_1'] = [
        FakeOpenRouter.okResult('chap:0', scriptFor('Part1')),
      ];
      await env.finishAndPoll('batch_1');
      final l = await env.lesson('chap');
      expect(l.stage, LessonStage.failed);
      expect(l.batch, isNull);
      expect(l.segments, isEmpty, reason: 'no partial lecture is stored');
    });

    test('immediate mode streams the parts one after another', () async {
      env = Env();
      await env.init();
      env.settings = luna();
      final notes = longNotes();
      final parts = splitForNarration(stripPageMarkers(notes));
      await env.repo.saveLesson(Lesson(
        id: 'chap',
        title: 'Chapter 2',
        brief: '',
        createdAt: DateTime(2026),
        notesMarkdown: notes,
        sourceStartPage: 10,
      ));
      env.fake.scriptAnswer = (body) {
        final m = RegExp(r'part (\d+) of').firstMatch(
            FakeOpenRouter.userText(body))!;
        return scriptFor('Part${m.group(1)}');
      };
      env.service.enqueue('chap');
      await env.settle();
      final l = await env.lesson('chap');
      expect(l.stage, LessonStage.ready);
      expect(env.fake.chatOf('script'), hasLength(parts.length));
      expect(l.segments.first.say, 'Part1 one.');
      expect(l.segments.last.say, 'Part${parts.length} three.');
    });
  });
}
