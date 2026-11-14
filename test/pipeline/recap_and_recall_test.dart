import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:learnmath/ai/lesson_generator.dart';
import 'package:learnmath/ai/narration_parts.dart';
import 'package:learnmath/core/models.dart';
import 'package:learnmath/pipeline/generation_service.dart';

import 'fakes.dart';

const _luna = 'openai/gpt-6-luna';
const _recallMarker = 'Check yourself';
final _now = DateTime(2026, 6, 20, 12);

const _notes = '# Banach Fixed-Point Theorem\n\n'
    'Intro text.\n\n'
    '## Theorem\n\nA contraction has a fixed point.\n\n'
    '## Summary\n\nContractions have unique fixed points.\n\n'
    'Iterate to find it.\n\n'
    '## Exercises\n\n1. Do something.\n';

Lesson _done(String id,
        {String title = 'Banach',
        String? notes = _notes,
        DateTime? completedAt,
        bool recapMade = false,
        String? courseId}) =>
    Lesson(
      id: id,
      title: title,
      brief: '',
      createdAt: DateTime(2026, 1, 1),
      notesMarkdown: notes,
      completedAt: completedAt ?? _now.subtract(const Duration(days: 4)),
      recapMade: recapMade,
      courseId: courseId,
    );

AppSettings _luna_({bool recall = true, bool verify = false, bool spaced = true}) =>
    AppSettings(
      apiKey: 'k',
      lessonPreset: 'luna',
      recallQuestions: recall,
      verifyProofs: verify,
      spacedReview: spaced,
    );

/// The fake only knows the course/lesson script prompts; the review prompt
/// starts differently, so it is answered by model here.
void _answerRecaps(Env env, String model) {
  env.fake.modelAnswers[model] = (body) =>
      FakeOpenRouter.userText(body).startsWith('The student listened')
          ? scriptFor('Review')
          : null;
}

void main() {
  late Env env;
  var live = false;
  setUp(() => live = false);
  tearDown(() async {
    if (live) await env.dispose();
  });
  // Every test that builds an Env goes through this.
  Future<void> init(AppSettings settings, {FakeRunner? runner}) async {
    env = Env()..settings = settings;
    await env.init(runner: runner);
    live = true;
  }

  group('summaryOf', () {
    test('summary in the middle: only its body', () {
      expect(GenerationService.summaryOf(_notes),
          'Contractions have unique fixed points.\n\nIterate to find it.');
    });

    test('summary as last section runs to the end', () {
      const n = '# T\n\n## Theorem\n\nx\n\n## Summary\n\nLast words.\n\nMore.\n';
      expect(GenerationService.summaryOf(n), 'Last words.\n\nMore.');
    });

    test('heading matches only at line start', () {
      const n = '# T\n\nSee the  ## Summary of results below.\n\n'
          '  ## Summary\n\nindented.\n\n### Summary\n\nsub.\n';
      final s = GenerationService.summaryOf(n);
      expect(s, contains('See the'));
      expect(s, isNot(equals('indented.')));
    });

    test('a ### Summary subsection is not the Summary section', () {
      const n = '# T\n\nBody.\n\n### Summary\n\nsub.\n';
      expect(GenerationService.summaryOf(n), 'Body.\n\n### Summary\n\nsub.');
    });

    test('no summary: notes minus the title line', () {
      expect(GenerationService.summaryOf('# Title\n\nBody one.\n\nBody two.'),
          'Body one.\n\nBody two.');
    });

    test('empty summary section falls back to whole notes minus title', () {
      expect(
          GenerationService.summaryOf('# T\n\nBody.\n\n## Summary\n\n## Next\n\nz'),
          contains('Body.'));
    });

    test('summary heading at end of text with no body does not throw', () {
      expect(() => GenerationService.summaryOf('# T\n\nBody.\n\n## Summary'),
          returnsNormally);
    });
  });

  group('makeDueRecaps', () {
    test('creates one standalone review with summary notes, once', () async {
      await init(_luna_());
      _answerRecaps(env, _luna);
      await env.repo.saveLesson(_done('a', courseId: 'c'));

      expect(await env.service.makeDueRecaps(now: _now), 1);
      await env.settle();

      final all = await env.repo.getAllLessons();
      expect(all, hasLength(2));
      final review = all.firstWhere((l) => l.isRecap);
      expect(review.recapOf, 'a');
      expect(review.courseId, isNull);
      expect(review.title, 'Review: Banach');
      expect(review.notesMarkdown!.startsWith('# Review: Banach\n\n'), isTrue);
      expect(review.notesMarkdown,
          '# Review: Banach\n\nContractions have unique fixed points.\n\nIterate to find it.');
      expect((await env.lesson('a')).recapMade, isTrue);

      expect(await env.service.makeDueRecaps(now: _now), 0);
      expect(await env.repo.getAllLessons(), hasLength(2));
    });

    test('notes without Summary: notes minus title line', () async {
      await init(_luna_());
      _answerRecaps(env, _luna);
      await env.repo
          .saveLesson(_done('a', notes: '# Old title\n\nJust body.'));
      await env.service.makeDueRecaps(now: _now);
      await env.settle();
      final review =
          (await env.repo.getAllLessons()).firstWhere((l) => l.isRecap);
      expect(review.notesMarkdown, '# Review: Banach\n\nJust body.');
    });

    test('exactly 3 days counts; just under does not', () async {
      await init(_luna_());
      _answerRecaps(env, _luna);
      await env.repo.saveLesson(_done('edge',
          completedAt: _now.subtract(GenerationService.reviewDelay)));
      await env.repo.saveLesson(_done('young',
          completedAt: _now
              .subtract(GenerationService.reviewDelay - const Duration(minutes: 1))));
      expect(await env.service.makeDueRecaps(now: _now), 1);
      await env.settle();
      expect((await env.lesson('edge')).recapMade, isTrue);
      expect((await env.lesson('young')).recapMade, isFalse);
    });

    test('skips: not completed, recapMade, a review itself, no notes', () async {
      await init(_luna_());
      await env.repo.saveLesson(Lesson(
          id: 'nc',
          title: 'x',
          brief: '',
          createdAt: DateTime(2026),
          notesMarkdown: _notes));
      await env.repo.saveLesson(_done('made', recapMade: true));
      await env.repo.saveLesson(
          _done('rev').copyWith(recapMade: false).let((l) => Lesson(
                id: l.id,
                title: l.title,
                brief: '',
                createdAt: l.createdAt,
                notesMarkdown: l.notesMarkdown,
                completedAt: l.completedAt,
                recapOf: 'zzz',
              )));
      await env.repo.saveLesson(_done('nonotes', notes: null));
      await env.repo.saveLesson(_done('empty', notes: ''));
      expect(await env.service.makeDueRecaps(now: _now), 0);
      expect(await env.repo.getAllLessons(), hasLength(5));
    });

    test('nothing when spacedReview is off or there is no API key', () async {
      await init(_luna_(spaced: false));
      await env.repo.saveLesson(_done('a'));
      expect(await env.service.makeDueRecaps(now: _now), 0);
      env.settings = const AppSettings(apiKey: '', lessonPreset: 'luna');
      expect(await env.service.makeDueRecaps(now: _now), 0);
      expect(await env.repo.getAllLessons(), hasLength(1));
      expect((await env.lesson('a')).recapMade, isFalse);
    });

    test('two due lessons give two reviews', () async {
      await init(_luna_());
      _answerRecaps(env, _luna);
      await env.repo.saveLesson(_done('a', title: 'A'));
      await env.repo.saveLesson(_done('b', title: 'B'));
      expect(await env.service.makeDueRecaps(now: _now), 2);
      await env.settle();
      expect(
          [
            for (final l in await env.repo.getAllLessons())
              if (l.isRecap) l.title
          ]..sort(),
          ['Review: A', 'Review: B']);
    });
  });

  group('generating a review', () {
    test('no notes request, no checks, no proof review; script from the '
        "original's full notes; then audio", () async {
      final runner = FakeRunner([passed(2)]);
      await init(_luna_(verify: true), runner: runner);
      _answerRecaps(env, _luna);
      await env.repo.saveLesson(_done('a'));
      await env.service.makeDueRecaps(now: _now);
      await env.settle();

      final review =
          (await env.repo.getAllLessons()).firstWhere((l) => l.isRecap);
      expect(runner.calls, isEmpty);
      expect(env.fake.requests, hasLength(1),
          reason: 'only the script: ${env.fake.kinds}');
      final u = FakeOpenRouter.userText(env.fake.requests.single.body);
      expect(u, startsWith('The student listened to the lecture "Banach"'));
      expect(u, contains('Do something.'), reason: 'full original notes');
      expect(u, contains('A contraction has a fixed point.'));
      expect(u, isNot(contains(_recallMarker)));
      expect(env.fake.requests.single.via, 'chat');

      final done = await env.lesson(review.id);
      expect(done.stage, LessonStage.ready);
      expect(done.segments, isNotEmpty);
      expect(done.audioPath, isNotNull);
      expect(File(done.audioPath!).existsSync(), isTrue);
      expect(done.review, isNull);
    });

    test('original deleted: script built from the review\'s own notes',
        () async {
      await init(_luna_());
      _answerRecaps(env, _luna);
      await env.repo.saveLesson(Lesson(
        id: 'rev',
        title: 'Review: Banach',
        brief: '',
        createdAt: _now,
        recapOf: 'deleted-original',
        notesMarkdown:
            '# Review: Banach\n\nContractions have unique fixed points.',
      ));
      env.service.enqueue('rev');
      await env.settle();

      expect(env.fake.requests, hasLength(1));
      final u = FakeOpenRouter.userText(env.fake.requests.single.body);
      expect(u, contains('# Review: Banach'));
      expect(u, contains('Contractions have unique fixed points.'));
      expect(u, isNot(contains('Do something.')));
      expect(u, contains('"Review: Banach"'));
    });

    test('batch mode: the review script goes through the Batch API', () async {
      await init(const AppSettings(apiKey: 'k', verifyProofs: true), runner: FakeRunner([passed(1)]));
      await env.repo.saveLesson(_done('a'));
      await env.service.makeDueRecaps(now: _now);
      await env.settle();
      final review =
          (await env.repo.getAllLessons()).firstWhere((l) => l.isRecap);

      expect(env.fake.chatBodies, isEmpty);
      expect(env.fake.submitted, hasLength(1));
      final reqs = (env.fake.submitted.single['requests'] as List).cast<Map>();
      expect(reqs, hasLength(1));
      expect(reqs.single['custom_id'], '${review.id}:0');
      final body = (reqs.single['body'] as Map).cast<String, Object?>();
      expect(FakeOpenRouter.userText(body), startsWith('The student listened'));
      expect((await env.lesson(review.id)).batch!.step, BatchStep.narration);

      env.fake.resultOverride[env.fake.lastBatchId] = [
        FakeOpenRouter.okResult('${review.id}:0', scriptFor('Review')),
      ];
      await env.finishAndPoll();
      final l = await env.lesson(review.id);
      expect(l.stage, LessonStage.ready);
      expect(l.segments, isNotEmpty);
      expect(env.fake.submitted, hasLength(1), reason: 'no second batch');
    });
  });

  group('recall questions in the script request', () {
    Future<List<String>> scriptUsers(Env e) async => [
          for (final r in e.fake.requests)
            if (r.kind == 'script') FakeOpenRouter.userText(r.body)
        ];

    test('on by default for a normal lesson', () async {
      expect(const AppSettings().recallQuestions, isTrue);
      await init(_luna_(), runner: FakeRunner([passed(2)]));
      await env.create();
      final s = await scriptUsers(env);
      expect(s, hasLength(1));
      expect(s.single, contains(_recallMarker));
      expect(s.single, contains('PAUSE: 7'));
      expect(s.single, contains('answer'));
    });

    test('off: the request does not mention it', () async {
      await init(_luna_(recall: false), runner: FakeRunner([passed(2)]));
      await env.create();
      final s = await scriptUsers(env);
      expect(s, hasLength(1));
      expect(s.single, isNot(contains(_recallMarker)));
      expect(s.single.toLowerCase(), isNot(contains('check yourself')));
    });

    test('book chapter in parts: only the last part carries it', () async {
      await init(_luna_());
      final b = StringBuffer();
      for (var s = 1; s <= 4; s++) {
        b.writeln('## Section $s\n');
        for (var p = 0; p < 12; p++) {
          b.writeln('Paragraph $p of section $s. ${'word ' * 90}\n');
        }
      }
      final parts = splitForNarration(stripPageMarkers(b.toString()));
      expect(parts.length, greaterThan(1));
      await env.repo.saveLesson(Lesson(
        id: 'chap',
        title: 'Chapter 2',
        brief: '',
        createdAt: DateTime(2026),
        notesMarkdown: b.toString(),
        sourceStartPage: 1,
        sourceEndPage: 9,
      ));
      env.service.enqueue('chap');
      await env.settle();
      final s = await scriptUsers(env);
      expect(s, hasLength(parts.length));
      for (var i = 0; i < s.length - 1; i++) {
        expect(s[i], isNot(contains(_recallMarker)), reason: 'part ${i + 1}');
      }
      expect(s.last, contains(_recallMarker));
    });

    test('single-part book chapter carries it', () async {
      await init(_luna_());
      await env.repo.saveLesson(Lesson(
        id: 'chap',
        title: 'Chapter 1',
        brief: '',
        createdAt: DateTime(2026),
        notesMarkdown: '# C\n\nShort.',
        sourceStartPage: 1,
        sourceEndPage: 2,
      ));
      env.service.enqueue('chap');
      await env.settle();
      expect((await scriptUsers(env)).single, contains(_recallMarker));
    });

    test('the generator: recap request never carries it', () {
      final m = LessonGenerator.recapMessages(title: 'T', notesMarkdown: 'n');
      expect(m.last.content, isNot(contains(_recallMarker)));
      final n = LessonGenerator.narrationMessages(
          title: 'T', notesMarkdown: 'n', recall: true);
      expect(n.last.content, contains(_recallMarker));
      final off = LessonGenerator.narrationMessages(
          title: 'T', notesMarkdown: 'n');
      expect(off.last.content, isNot(contains(_recallMarker)));
    });

    test('a review run with recallQuestions on has no recall request',
        () async {
      await init(_luna_(recall: true));
      _answerRecaps(env, _luna);
      await env.repo.saveLesson(_done('a'));
      await env.service.makeDueRecaps(now: _now);
      await env.settle();
      for (final r in env.fake.requests) {
        expect(FakeOpenRouter.userText(r.body), isNot(contains(_recallMarker)));
      }
    });
  });
}

extension<T> on T {
  R let<R>(R Function(T) f) => f(this);
}
