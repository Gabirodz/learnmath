import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:learnmath/ai/narration_parts.dart';
import 'package:learnmath/checks/math_check.dart';
import 'package:learnmath/checks/proof_review.dart';
import 'package:learnmath/core/models.dart';

import 'fakes.dart';

const _reviewer = 'anthropic/claude-opus-5.5';
const _sol = 'openai/gpt-6.1-sol';
const _luna = 'openai/gpt-6-luna';
const _issue = 'ISSUE: Lemma 1 needs compactness\n'
    'WHERE: Lemma 1\nWHY: False on R.\nFIX: Assume K compact.';
const _twoIssues = '$_issue\n\nISSUE: Step 3 is circular\nWHERE: Theorem 2\n'
    'WHY: Uses the claim.\nFIX: Prove it first.';

AppSettings _lunaSettings({bool verify = true, String? verifier}) => AppSettings(
    apiKey: 'k',
    lessonPreset: 'luna',
    verifyProofs: verify,
    verifierModel: verifier ?? AppSettings.defaultVerifierModel);

AppSettings _solSettings({bool verify = false}) =>
    AppSettings(apiKey: 'k', verifyProofs: verify);

/// A course of [n] lessons `l1`..`ln`, not yet queued.
Future<List<String>> _course(Env env, int n, {String prefix = 'l'}) async {
  await env.repo.saveCourse(Course(
      id: 'c', title: 'Topology', description: 'd', createdAt: DateTime(2026)));
  final ids = <String>[];
  for (var i = 1; i <= n; i++) {
    ids.add('$prefix$i');
    await env.repo.saveLesson(Lesson(
      id: '$prefix$i',
      courseId: 'c',
      order: i,
      title: 'Lesson $i',
      brief: 'brief $i',
      createdAt: DateTime(2026),
    ));
  }
  return ids;
}

/// model + effort + kinds of every submitted batch.
List<String> _batches(Env env) => [
      for (final b in env.fake.submitted)
        () {
          final reqs = (b['requests'] as List)
              .map((r) => ((r as Map)['body'] as Map).cast<String, Object?>())
              .toList();
          final effort = (reqs.first['reasoning'] as Map?)?['effort'];
          final kinds = reqs.map(FakeOpenRouter.kind).toSet().join('+');
          return '${b['model']} ${effort ?? 'temp'} $kinds x${reqs.length}';
        }(),
    ];

void main() {
  late Env env;
  tearDown(() => env.dispose());

  group('grouped batches', () {
    test('a course generated at once is one notes batch, then one script batch',
        () async {
      env = Env();
      final runner = FakeRunner([passed(2)]);
      await env.init(runner: runner);
      final ids = await _course(env, 3);
      for (final id in ids) {
        env.service.enqueue(id);
      }
      await env.settle();

      expect(env.fake.submitted, hasLength(1), reason: 'ONE POST /batches');
      final reqs = (env.fake.submitted.single['requests'] as List).cast<Map>();
      expect([for (final r in reqs) r['custom_id']], ['l1:0', 'l2:0', 'l3:0']);
      expect(env.fake.submitted.single['model'], _sol);
      for (final id in ids) {
        final l = await env.lesson(id);
        expect(l.batch!.id, 'batch_1', reason: 'same batch id for all');
        expect(l.batch!.step, BatchStep.notes);
        expect(l.isWaitingForBatch, isTrue);
        expect(env.lastLabel(id), 'Waiting for the batch answer…');
      }
      expect(env.fake.chatBodies, isEmpty);

      await env.finishAndPoll('batch_1');
      expect(env.fake.submitted, hasLength(2));
      expect(_batches(env), [
        '$_sol high notes x3',
        '$_sol high script x3',
      ]);
      final script =
          (env.fake.submitted.last['requests'] as List).cast<Map>();
      expect([for (final r in script) r['custom_id']], ['l1:0', 'l2:0', 'l3:0']);
      for (final id in ids) {
        expect((await env.lesson(id)).batch!.id, 'batch_2');
      }

      await env.finishAndPoll('batch_2');
      for (final id in ids) {
        final l = await env.lesson(id);
        expect(l.stage, LessonStage.ready);
        expect(l.hasAudio, isTrue);
        expect(l.batch, isNull);
      }
      expect(env.notifications.ready.map((r) => r.id), ids);
      expect(env.fake.submitted, hasLength(2));
      expect(env.fake.deleted.toSet(), {'batch_1', 'batch_2'});
    });

    test('a shared batch is deleted only after the last lesson collected',
        () async {
      env = Env();
      late final List<String> ids;
      final deletedAtCheck = <int>[];
      final runner = FakeRunner([passed(2)], onRun: (_) async {
        deletedAtCheck.add(env.fake.deleted.length);
      });
      await env.init(runner: runner);
      ids = await _course(env, 3);
      for (final id in ids) {
        env.service.enqueue(id);
      }
      await env.settle();
      env.fake.finish('batch_1');
      await env.service.pollBatches();
      await env.settle();

      // The checks of lessons 1 and 2 ran while lesson 3 still had its
      // answer in the batch.
      expect(deletedAtCheck, hasLength(3));
      expect(deletedAtCheck[0], 0);
      expect(deletedAtCheck[1], 0);
      expect(env.fake.deleted.where((d) => d == 'batch_1'), isNotEmpty,
          reason: 'deleted once everyone collected');
      expect(env.fake.deleted.toSet(), {'batch_1'});
    });

    // SUSPECTED BUG (known to fail): lib/pipeline/generation_service.dart,
    // _forget (~l.962) only runs for a lesson that stored its answer, and
    // skips deletion while another lesson still waits on the batch. If the
    // lesson that fails to collect (no answer, error result, 410) is the
    // last one, no one deletes the batch.
    test('a lesson that cannot collect its answer must not leave the batch '
        'undeleted', () async {
      env = Env();
      await env.init();
      final ids = await _course(env, 3);
      for (final id in ids) {
        env.service.enqueue(id);
      }
      await env.settle();
      // The batch has no answer for the last lesson.
      env.fake.resultOverride['batch_1'] = [
        FakeOpenRouter.okResult('l1:0', notesWithChecks),
        FakeOpenRouter.okResult('l2:0', notesWithChecks),
      ];
      await env.finishAndPoll('batch_1');
      expect((await env.lesson('l3')).stage, LessonStage.failed);
      expect((await env.lesson('l1')).batch!.step, BatchStep.narration);
      // l1 and l2 collected; l3 failed. Nobody waits for batch_1 any more,
      // so it should be gone from OpenRouter (it holds lesson text for 30
      // days).
      expect(env.fake.deleted, contains('batch_1'));
    });

    test('a 429 on the grouped submit fails every lesson readably', () async {
      env = Env();
      await env.init();
      env.fake.failSubmitWith = 429;
      final ids = await _course(env, 3);
      for (final id in ids) {
        env.service.enqueue(id);
      }
      await env.settle();

      for (final id in ids) {
        final l = await env.lesson(id);
        expect(l.stage, LessonStage.failed);
        expect(l.error, contains('Too many batches are in progress'));
        expect(l.batch, isNull);
        expect(env.lastLabel(id), isNull, reason: 'progress cleared');
      }
      expect(env.notifications.failed.map((f) => f.id), ids);
      expect(env.notifications.failed.every((f) => f.reason == (
          env.notifications.failed.first.reason)), isTrue);
      expect(env.fake.submitted, isEmpty);
      expect(env.keepAlive.distinct.last, 'release');
      expect(env.background.updates, isEmpty);
    });

    test('more than 100 requests are split by whole lessons', () async {
      env = Env();
      await env.init();
      final notes = _longNotes();
      final parts = splitForNarration(stripPageMarkers(notes)).length;
      expect(parts, greaterThan(1), reason: 'test needs multi-part lessons');
      final n = 100 ~/ parts + 2;
      for (var i = 1; i <= n; i++) {
        await env.repo.saveLesson(Lesson(
          id: 'ch$i',
          title: 'Chapter $i',
          brief: '',
          createdAt: DateTime(2026),
          notesMarkdown: notes,
          sourceStartPage: 10,
          sourceEndPage: 30,
        ));
      }
      for (var i = 1; i <= n; i++) {
        env.service.enqueue('ch$i');
      }
      await env.settle();

      expect(env.fake.submitted.length, greaterThan(1));
      final lessonsInBatch = <String, Set<String>>{};
      for (var b = 0; b < env.fake.submitted.length; b++) {
        final reqs = (env.fake.submitted[b]['requests'] as List).cast<Map>();
        expect(reqs.length, lessThanOrEqualTo(100));
        final byLesson = <String, List<String>>{};
        for (final r in reqs) {
          final id = (r['custom_id'] as String).split(':');
          byLesson.putIfAbsent(id[0], () => []).add(id[1]);
        }
        for (final e in byLesson.entries) {
          expect(e.value, [for (var i = 0; i < parts; i++) '$i'],
              reason: '${e.key} is not split inside batch ${b + 1}');
          lessonsInBatch.putIfAbsent(e.key, () => {}).add('batch_${b + 1}');
        }
      }
      expect(lessonsInBatch.length, n);
      expect(lessonsInBatch.values.every((s) => s.length == 1), isTrue);
      for (var i = 1; i <= n; i++) {
        final l = await env.lesson('ch$i');
        expect(l.batch!.parts, parts);
        expect(l.batch!.id, startsWith('batch_'));
      }
    });

    test('cancelling a lesson still in the outbox: Cancelled, not submitted',
        () async {
      env = Env();
      final gate = Completer0();
      final runner = FakeRunner([passed(1)], onRun: (_) => gate.future);
      await env.init(runner: runner);
      await env.repo.saveLesson(Lesson(
        id: 'a',
        title: 'A',
        brief: 'b',
        createdAt: DateTime(2026),
      ));
      // B has notes and unrun checks, so it holds the queue at the runner.
      await env.repo.saveLesson(Lesson(
        id: 'b',
        title: 'B',
        brief: 'b',
        createdAt: DateTime(2026),
        notesMarkdown: '# B\n\nbody',
        checks: const [MathCheck(title: 'c', code: 'assert 1 == 1')],
      ));
      env.service.enqueue('a');
      env.service.enqueue('b');
      await pumpUntil(() => runner.calls.isNotEmpty);
      expect(env.service.isQueued('b'), isTrue);
      expect(env.service.isQueued('a'), isFalse, reason: 'A is in the outbox');
      expect(env.fake.submitted, isEmpty);

      env.service.cancel('a');
      await pumpEventQueue();
      gate.complete();
      await env.settle();

      final a = await env.lesson('a');
      expect(a.stage, LessonStage.failed);
      expect(a.error, 'Cancelled.');
      expect(a.batch, isNull);
      expect(env.lastLabel('a'), isNull);
      expect(env.fake.submitted, hasLength(1));
      final reqs = (env.fake.submitted.single['requests'] as List).cast<Map>();
      expect([for (final r in reqs) r['custom_id']], ['b:0'],
          reason: 'only B (its script) was submitted');
      expect((await env.lesson('b')).batch!.step, BatchStep.narration);
    });
  });

  group('keep-alive', () {
    test('immediate mode: working on N lessons, released at the end',
        () async {
      env = Env();
      await env.init();
      env.settings = _lunaSettings(verify: false);
      final ids = await _course(env, 2);
      for (final id in ids) {
        env.service.enqueue(id);
      }
      await env.settle();
      expect(env.keepAlive.distinct, [
        'hold: Working on 1 lesson',
        'hold: Working on 2 lessons',
        'hold: Working on 1 lesson',
        'release',
      ]);
    });

    test('batch mode: working, waiting for N batch answers, release',
        () async {
      env = Env();
      await env.init(runner: FakeRunner([passed(2)]));
      final ids = await _course(env, 3);
      for (final id in ids) {
        env.service.enqueue(id);
      }
      await env.settle();
      expect(env.keepAlive.distinct.first, 'hold: Working on 1 lesson');
      expect(env.keepAlive.distinct, contains('hold: Working on 3 lessons'));
      expect(env.keepAlive.distinct.last, 'hold: Waiting for 3 batch answers');
      expect(env.keepAlive.calls, isNot(contains('release')));

      await env.finishAndPoll('batch_1');
      expect(env.keepAlive.distinct.last, 'hold: Waiting for 3 batch answers');
      expect(env.keepAlive.calls, isNot(contains('release')),
          reason: 'never released between the two steps');

      await env.finishAndPoll('batch_2');
      expect(env.keepAlive.distinct.last, 'release');
      expect(env.keepAlive.calls.where((c) => c == 'release'), isNotEmpty);
    });

    test('singular: one batch answer', () async {
      env = Env();
      await env.init();
      await env.create();
      expect(env.keepAlive.distinct.last, 'hold: Waiting for 1 batch answer');
    });

    test('a restart with a waiting lesson holds, an empty one releases',
        () async {
      env = Env();
      await env.init();
      await env.service.recoverInterrupted();
      expect(env.keepAlive.distinct, ['release']);
      await env.create();
      env.keepAlive.calls.clear();
      await env.service.recoverInterrupted();
      expect(env.keepAlive.distinct.last, 'hold: Waiting for 1 batch answer');
    });
  });

  group('proof review (immediate)', () {
    test('NO ISSUES: reviewer gets the notes with effort high, then the script',
        () async {
      env = Env();
      final stages = <LessonStage>[];
      await env.init(runner: FakeRunner([passed(2)]));
      env.settings = _lunaSettings();
      env.fake.onChat = (r) async {
        if (r.kind == 'verify') {
          stages.add((await env.repo.getAllLessons()).single.stage);
        }
      };
      final id = await env.create();
      final l = await env.lesson(id);

      expect(env.fake.kinds, ['notes', 'verify', 'script']);
      final v = env.fake.ofKind('verify').single;
      expect(v.model, _reviewer);
      expect(v.effort, 'high');
      expect(v.hasTemperature, isFalse);
      expect(FakeOpenRouter.userText(v.body), contains('Banach'));
      expect(FakeOpenRouter.userText(v.body), isNot(contains('<<<CHECKS')));
      expect(stages, [LessonStage.verifyingProofs]);
      expect(l.stage, LessonStage.ready);
      expect(l.review!.isDone, isTrue);
      expect(l.review!.issues, isEmpty);
      expect(l.review!.round, 0);
      expect(l.review!.dismissed, 0);
      expect(l.hasAudio, isTrue);
      expect(env.progress.map((p) => p.$2),
          contains('A second model is reviewing the proofs…'));
    });

    test('the verifier model comes from the settings', () async {
      env = Env();
      await env.init();
      env.settings = _lunaSettings(verifier: 'acme/ref');
      await env.create();
      expect(env.fake.ofKind('verify').single.model, 'acme/ref');
    });

    test('false alarms are dropped and counted; no rewrite', () async {
      env = Env();
      await env.init();
      env.settings = _lunaSettings();
      env.fake.verifierAnswers
        ..clear()
        ..add(_twoIssues);
      env.fake.judgeAnswer = (_) =>
          'verdict 1: false alarm - fine\nVERDICT 2: FALSE ALARM - fine';
      final id = await env.create();
      final l = await env.lesson(id);

      expect(env.fake.kinds, ['notes', 'verify', 'judge', 'script']);
      final j = env.fake.ofKind('judge').single;
      expect(j.model, _luna, reason: 'the lesson model judges');
      expect(j.effort, isNull, reason: 'preset without effort: none');
      expect(j.hasTemperature, isTrue);
      expect(FakeOpenRouter.userText(j.body), contains('1. ISSUE: Lemma 1'));
      expect(FakeOpenRouter.userText(j.body), contains('2. ISSUE: Step 3'));
      expect(l.review!.isDone, isTrue);
      expect(l.review!.issues, isEmpty);
      expect(l.review!.dismissed, 2);
      expect(l.review!.rewritten, isFalse);
      expect(l.notesMarkdown, contains('2 + 2 = 4'));
    });

    test('the judge runs at effort medium when the preset has an effort',
        () async {
      env = Env();
      await env.init();
      env.settings = const AppSettings(
          apiKey: 'k',
          lessonPreset: 'custom',
          chatModel: 'acme/m',
          customEffort: 'high',
          verifyProofs: true);
      env.fake.verifierAnswers
        ..clear()
        ..add(_issue);
      env.fake.judgeAnswer = (_) => 'VERDICT 1: FALSE ALARM - x';
      await env.create();
      expect(env.fake.ofKind('notes').single.effort, 'high');
      final j = env.fake.ofKind('judge').single;
      expect(j.model, 'acme/m');
      expect(j.effort, 'medium');
      expect(j.hasTemperature, isFalse);
      expect(env.fake.ofKind('verify').single.effort, 'high');
    });

    test('a real issue: one rewrite, SymPy re-run without a repair, second '
        'reading clean', () async {
      env = Env();
      final runner = FakeRunner([
        [CheckStatus.passed, CheckStatus.passed],
        [CheckStatus.failed], // after the rewrite: must NOT trigger a repair
      ]);
      await env.init(runner: runner);
      env.settings = _lunaSettings();
      env.fake.verifierAnswers
        ..clear()
        ..addAll([_issue, 'NO ISSUES']);
      final id = await env.create();
      final l = await env.lesson(id);

      expect(env.fake.kinds,
          ['notes', 'verify', 'judge', 'proofRepair', 'verify', 'script']);
      final fix = env.fake.ofKind('proofRepair').single;
      expect(fix.model, _luna);
      expect(FakeOpenRouter.userText(fix.body), contains('Lemma 1 needs'));
      expect(FakeOpenRouter.systemText(fix.body), contains('<<<CHECKS'));
      // The second reading sees the rewritten notes.
      final second = env.fake.ofKind('verify').last;
      expect(FakeOpenRouter.userText(second.body), contains('2 + 3 = 5'));
      expect(second.model, _reviewer);

      expect(l.notesMarkdown, contains('2 + 3 = 5'));
      expect(l.checks.map((c) => c.title), ['Example A fixed']);
      expect(runner.calls, hasLength(2), reason: 'checks re-run once');
      expect(env.fake.chatOf('repair'), isEmpty, reason: 'no SymPy repair');
      expect(l.checkReport!.repaired, isTrue);
      expect(l.review!.isDone, isTrue);
      expect(l.review!.issues, isEmpty);
      expect(l.review!.round, 1);
      expect(l.review!.rewritten, isTrue);
      expect(l.stage, LessonStage.ready);
      expect(FakeOpenRouter.userText(env.fake.ofKind('script').single.body),
          contains('2 + 3 = 5'),
          reason: 'the script is written from the corrected notes');
    });

    test('what is still real after the rewrite is stored; never a second '
        'rewrite', () async {
      env = Env();
      await env.init(runner: FakeRunner([passed(2)]));
      env.settings = _lunaSettings();
      env.fake.verifierAnswers
        ..clear()
        ..addAll([_issue, _twoIssues]);
      var judged = 0;
      env.fake.judgeAnswer = (_) => ++judged == 1
          ? 'VERDICT 1: REAL - yes'
          : 'VERDICT 1: REAL - yes\nVERDICT 2: FALSE ALARM - no';
      final id = await env.create();
      final l = await env.lesson(id);

      expect(env.fake.kinds, [
        'notes', 'verify', 'judge', 'proofRepair', //
        'verify', 'judge', 'script',
      ]);
      expect(l.review!.state, ProofReviewState.done);
      expect(l.review!.round, 1);
      expect(l.review!.issues.map((i) => i.summary),
          ['Lemma 1 needs compactness']);
      expect(l.review!.issues.single.fix, 'Assume K compact.');
      expect(l.review!.dismissed, 1);
      expect(l.stage, LessonStage.ready);
    });

    test('an unusable rewrite keeps the notes and finishes with the '
        'confirmed issues', () async {
      env = Env();
      await env.init(runner: FakeRunner([passed(2)]));
      env.settings = _lunaSettings();
      env.fake.verifierAnswers
        ..clear()
        ..add(_issue);
      env.fake.proofRepairAnswer = '<<<CHECKS\nCHECKS>>>';
      final id = await env.create();
      final l = await env.lesson(id);

      expect(env.fake.kinds, ['notes', 'verify', 'judge', 'proofRepair', 'script']);
      expect(l.notesMarkdown, contains('2 + 2 = 4'));
      expect(l.review!.isDone, isTrue);
      expect(l.review!.issues, hasLength(1));
      expect(l.review!.rewritten, isFalse);
      expect(l.stage, LessonStage.ready);
      expect(env.notifications.failed, isEmpty);
    });

    test('verifyProofs off: nothing goes to the verifier, no review', () async {
      env = Env();
      await env.init();
      env.settings = _lunaSettings(verify: false);
      final id = await env.create();
      expect(env.fake.requests.where((r) => r.model == _reviewer), isEmpty);
      expect((await env.lesson(id)).review, isNull);
      expect(env.fake.kinds, ['notes', 'script']);
    });

    test('a book chapter is not reviewed', () async {
      env = Env();
      await env.init();
      env.settings = _lunaSettings();
      await env.repo.saveLesson(Lesson(
        id: 'chap',
        title: 'Chapter',
        brief: '',
        createdAt: DateTime(2026),
        notesMarkdown: '# Chapter\n\nSome text.',
        sourceStartPage: 3,
        sourceEndPage: 9,
      ));
      env.service.enqueue('chap');
      await env.settle();
      expect(env.fake.requests.where((r) => r.model == _reviewer), isEmpty);
      final l = await env.lesson('chap');
      expect(l.review, isNull);
      expect(l.stage, LessonStage.ready);
    });

    test('a reviewer error fails the lesson, keeps the notes, retry resumes '
        'at the review', () async {
      env = Env();
      await env.init();
      env.settings = _lunaSettings();
      env.fake.modelAnswers[_reviewer] = (_) => throw StateError('x');
      final id = await env.create();
      var l = await env.lesson(id);
      expect(l.stage, LessonStage.failed);
      expect(l.hasNotes, isTrue);
      expect(env.notifications.failed, hasLength(1));
      expect(env.fake.chatOf('notes'), hasLength(1));

      env.fake.modelAnswers.clear();
      env.service.enqueue(id);
      await env.settle();
      l = await env.lesson(id);
      expect(l.stage, LessonStage.ready);
      expect(l.review!.isDone, isTrue);
      expect(env.fake.chatOf('notes'), hasLength(1), reason: 'notes kept');
    });

    test('verify() on a finished lesson reports only', () async {
      env = Env();
      await env.init(runner: FakeRunner([passed(2)]));
      env.settings = _lunaSettings(verify: false);
      final id = await env.create();
      final before = await env.lesson(id);
      expect(before.stage, LessonStage.ready);
      expect(before.review, isNull);
      env.fake.requests.clear();
      env.fake.chatBodies.clear();
      env.fake.verifierAnswers
        ..clear()
        ..add(_issue);

      await env.service.verify(id);
      await env.settle();
      final l = await env.lesson(id);

      expect(env.fake.kinds, ['verify', 'judge'],
          reason: 'no rewrite, no new script');
      expect(l.stage, LessonStage.ready);
      expect(l.error, isNull);
      expect(l.review!.isDone, isTrue);
      expect(l.review!.reportOnly, isTrue);
      expect(l.review!.issues.map((i) => i.summary),
          ['Lemma 1 needs compactness']);
      expect(l.review!.rewritten, isFalse);
      expect(l.notesMarkdown, before.notesMarkdown);
      expect(l.checks.length, before.checks.length);
      expect(l.segments.length, before.segments.length);
      expect(l.audioPath, before.audioPath);
      expect(File(l.audioPath!).existsSync(), isTrue);
      expect(l.audioDurationMs, before.audioDurationMs);
    });

    test('verify() with no issues found', () async {
      env = Env();
      await env.init();
      env.settings = _lunaSettings(verify: false);
      final id = await env.create();
      env.fake.requests.clear();
      await env.service.verify(id);
      await env.settle();
      expect(env.fake.kinds, ['verify']);
      final l = await env.lesson(id);
      expect(l.review!.isDone, isTrue);
      expect(l.review!.issues, isEmpty);
      expect(l.stage, LessonStage.ready);
    });
  });

  group('proof review (batch)', () {
    test('two lessons: verify requests are grouped apart from lesson-model '
        'requests, whole pipeline', () async {
      env = Env();
      await env.init(runner: FakeRunner([passed(2)]));
      env.settings = _solSettings(verify: true);
      env.fake.verifierAnswers
        ..clear()
        ..addAll([_issue, 'NO ISSUES']); // l1 has an issue, l2 none, then clean
      final ids = await _course(env, 2);
      for (final id in ids) {
        env.service.enqueue(id);
      }
      await env.settle();
      expect(_batches(env), ['$_sol high notes x2']);

      await env.finishAndPoll('batch_1');
      expect(_batches(env).last, '$_reviewer high verify x2');
      expect(env.fake.submitted.last['model'], _reviewer);
      expect((await env.lesson('l1')).stage, LessonStage.verifyingProofs);
      expect((await env.lesson('l1')).batch!.step, BatchStep.verify);
      expect(env.fake.deleted, contains('batch_1'));

      await env.finishAndPoll('batch_2');
      // l1: issue -> judge (sol, medium); l2: clean -> script (sol, high).
      expect(_batches(env).skip(2), [
        '$_sol medium judge x1',
        '$_sol high script x1',
      ]);
      expect((await env.lesson('l1')).review!.state, ProofReviewState.raw);
      expect((await env.lesson('l2')).review!.isDone, isTrue);

      env.fake.finish('batch_3');
      env.fake.finish('batch_4');
      await env.service.pollBatches();
      await env.settle();
      expect((await env.lesson('l2')).stage, LessonStage.ready);
      expect(_batches(env).last, '$_sol high proofRepair x1');
      expect((await env.lesson('l1')).batch!.step, BatchStep.proofRepair);

      await env.finishAndPoll('batch_5');
      var l1 = await env.lesson('l1');
      expect(l1.notesMarkdown, contains('2 + 3 = 5'));
      expect(l1.review!.round, 1);
      expect(_batches(env).last, '$_reviewer high verify x1');

      await env.finishAndPoll('batch_6');
      l1 = await env.lesson('l1');
      expect(l1.review!.isDone, isTrue);
      expect(l1.review!.issues, isEmpty);
      expect(_batches(env).last, '$_sol high script x1');

      await env.finishAndPoll('batch_7');
      l1 = await env.lesson('l1');
      expect(l1.stage, LessonStage.ready);
      expect(l1.hasAudio, isTrue);
      expect(env.fake.chatBodies, isEmpty, reason: 'everything was batched');
      expect(env.fake.submitted, hasLength(7));
      expect(env.notifications.ready.map((r) => r.id).toSet(), {'l1', 'l2'});
      expect(env.notifications.failed, isEmpty);
      expect(env.keepAlive.distinct.last, 'release');
    });

    test('verifyProofs off: no verify batch', () async {
      env = Env();
      await env.init();
      env.settings = _solSettings();
      final ids = await _course(env, 2);
      for (final id in ids) {
        env.service.enqueue(id);
      }
      await env.settle();
      await env.finishAndPoll('batch_1');
      await env.finishAndPoll('batch_2');
      expect(env.fake.requests.where((r) => r.kind == 'verify'), isEmpty);
      expect(env.fake.requests.where((r) => r.model == _reviewer), isEmpty);
      expect((await env.lesson('l1')).review, isNull);
    });
  });
}

String _longNotes() {
  final b = StringBuffer();
  for (var s = 1; s <= 4; s++) {
    b.writeln('## Section $s\n');
    for (var p = 0; p < 12; p++) {
      b.writeln('Paragraph $p of section $s. ${'word ' * 90}\n');
    }
  }
  return b.toString();
}

/// A one-shot gate.
class Completer0 {
  final _c = Completer<void>();
  Future<void> get future => _c.future;
  void complete() => _c.complete();
}

Future<void> pumpUntil(bool Function() cond) async {
  for (var i = 0; i < 500 && !cond(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 2));
  }
  expect(cond(), isTrue, reason: 'condition never became true');
}
