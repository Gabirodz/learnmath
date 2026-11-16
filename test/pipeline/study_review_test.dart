import 'package:flutter_test/flutter_test.dart';
import 'package:learnmath/cards/card_store.dart';
import 'package:learnmath/core/models.dart';

import 'fakes.dart';

const _luna = 'openai/gpt-6-luna';
const _sol = 'openai/gpt-6.1-sol';

const _reviewAnswer = '# Review: Fixed points and compactness\n\n'
    '## Banach\n\n**Theorem.** A contraction has one fixed point.\n\n'
    '## Compactness\n\n**Definition.** Every open cover has a finite subcover.\n\n'
    '<<<CARDS\n'
    'FRONT: State the Banach fixed-point theorem.\n'
    'BACK: A contraction on a complete metric space has exactly one fixed point.\n'
    'TOPIC: Banach\n\n'
    'FRONT: What is a compact space?\n'
    'BACK: One where every open cover has a finite subcover.\n'
    'TOPIC: Compactness\n'
    'CARDS>>>';

bool _isDigest(Map<String, Object?> body) =>
    FakeOpenRouter.systemText(body).startsWith('You condense the lecture notes');
bool _isReview(Map<String, Object?> body) =>
    FakeOpenRouter.systemText(body).startsWith('You write a review');

/// The fake only knows the lesson prompts; the review ones are answered here.
void _answerReviews(Env env, {String? digest}) {
  env.fake.extraAnswer = (body) {
    if (_isDigest(body)) {
      final title = RegExp(r'^Lesson: "(.*)"', multiLine: true)
          .firstMatch(FakeOpenRouter.userText(body))!
          .group(1);
      return digest ?? '## Key facts\n\nDigest of $title.';
    }
    return _isReview(body) ? _reviewAnswer : null;
  };
}

Lesson _studied(String id, String title,
        {String? digest, bool completed = true, DateTime? at}) =>
    Lesson(
      id: id,
      title: title,
      brief: '',
      createdAt: DateTime(2026, 1, 1),
      notesMarkdown: '# $title\n\nFull notes of $title.\n\n'
          '## Summary\n\nSummary of $title.\n',
      completed: completed,
      completedAt: completed ? (at ?? DateTime(2026, 2, 1)) : null,
      digest: digest,
    );

void main() {
  late Env env;
  var live = false;
  setUp(() => live = false);
  tearDown(() async {
    if (live) await env.dispose();
  });
  Future<void> init(AppSettings settings) async {
    env = Env()..settings = settings;
    await env.init();
    live = true;
  }

  const immediate = AppSettings(apiKey: 'k', lessonPreset: 'luna');

  group('the model picked for a lesson', () {
    test('writes it, whatever the remembered choice is', () async {
      await init(const AppSettings(apiKey: 'k')); // Sol through the batch API
      const choice = ModelChoice(model: 'acme/m', effort: 'low');
      final id = await env.service.createLesson('Banach', model: choice);
      await env.settle();

      final l = await env.lesson(id);
      expect(l.stage, LessonStage.ready);
      expect(env.fake.submitted, isEmpty);
      expect({for (final r in env.fake.requests) r.model}, {'acme/m'});
      expect({for (final r in env.fake.requests) r.effort}, {'low'});
      expect(l.model, choice);
      expect(l.writtenBy, 'acme/m · low');
    });

    test('a batch choice is batched although the remembered one is not',
        () async {
      await init(immediate);
      final id = await env.service.createLesson('Banach',
          model: const ModelChoice(model: _sol, effort: 'high', batch: true));
      await env.settle();
      expect(env.fake.chatBodies, isEmpty);
      expect(env.fake.submitted.single['model'], _sol);
      expect((await env.lesson(id)).isWaitingForBatch, isTrue);

      await env.finishAndPoll();
      await env.finishAndPoll();
      final l = await env.lesson(id);
      expect(l.stage, LessonStage.ready);
      expect(l.writtenBy, 'GPT-6.1 Sol (batch) · high');
    });

    test('without one, the remembered choice writes and is named', () async {
      await init(immediate);
      final id = await env.create();
      final l = await env.lesson(id);
      expect(l.model, isNull);
      expect(l.writtenBy, 'GPT-6 Luna');
      expect({for (final r in env.fake.requests) r.model}, {_luna});
    });

    test('a course is planned by the planner, its lessons keep the lesson '
        'model', () async {
      await init(const AppSettings(apiKey: 'k'));
      const choice = ModelChoice(model: _luna, effort: 'medium', batch: true);
      const planner = ModelChoice(model: 'acme/strong', effort: 'xhigh');
      final courseId = await env.service
          .createCourse('Topology', model: choice, planner: planner);
      final plan = env.fake.requests.single;
      expect(plan.via, 'chat');
      expect(plan.model, 'acme/strong');
      expect(plan.effort, 'xhigh');
      final lessons = await env.repo.getCourseLessons(courseId);
      expect(lessons, hasLength(2));
      expect({for (final l in lessons) l.model}, {choice});
    });

    test('by default the most accurate model plans, at high effort, '
        'whatever writes the lessons; a batch planner is asked right away',
        () async {
      await init(const AppSettings(apiKey: 'k', lessonPreset: 'luna'));
      await env.service.createCourse('Topology');
      expect(env.fake.requests.single.model, 'openai/gpt-6.1-sol');
      expect(env.fake.requests.single.effort, 'high');

      await env.service.createCourse('Topology',
          planner: const ModelChoice(model: _luna, batch: true));
      expect(env.fake.submitted, isEmpty);
      expect(env.fake.requests.last.via, 'chat');
      expect(env.fake.requests.last.model, _luna);
    });

    test('the planner choice survives JSON', () {
      const s = AppSettings(
          plannerChoice: ModelChoice(model: 'acme/p', effort: 'max'));
      final back = AppSettings.fromJson(s.toJson());
      expect(back.plannerModel.model, 'acme/p');
      expect(back.plannerModel.effort, 'max');
      expect(const AppSettings().plannerModel.model, 'openai/gpt-6.1-sol');
    });

    test('survives JSON, as do the review fields', () {
      final l = Lesson(
        id: 'r',
        title: 't',
        brief: '',
        createdAt: DateTime(2026),
        model: const ModelChoice(model: 'acme/m', effort: 'xhigh', batch: true),
        writtenBy: 'acme/m (batch) · xhigh',
        covers: const ['a', 'b'],
        digest: 'd',
        material: 'm',
        batch: PendingBatch(
            id: 'b1',
            step: BatchStep.digest,
            submittedAt: DateTime(2026),
            parts: 2,
            keys: const ['a', 'b']),
      );
      final back = Lesson.fromJson(l.toJson());
      expect(back.model, l.model);
      expect(back.writtenBy, l.writtenBy);
      expect(back.covers, ['a', 'b']);
      expect(back.isReview, isTrue);
      expect(back.digest, 'd');
      expect(back.material, 'm');
      expect(back.batch!.step, BatchStep.digest);
      expect(back.batch!.keys, ['a', 'b']);
      // Lessons saved before these fields existed.
      final old = Lesson.fromJson(
          {'id': 'o', 'title': 't', 'createdAt': 0, 'stage': 'ready'});
      expect(old.model, isNull);
      expect(old.writtenBy, isNull);
      expect(old.isReview, isFalse);
    });
  });

  group('studiedLessons', () {
    test('completed lessons with notes, oldest first; no reviews or recaps',
        () async {
      await init(immediate);
      await env.repo.saveLesson(_studied('late', 'Late', at: DateTime(2026, 3)));
      await env.repo.saveLesson(_studied('early', 'Early', at: DateTime(2026, 2)));
      await env.repo.saveLesson(_studied('open', 'Open', completed: false));
      await env.repo.saveLesson(Lesson(
          id: 'nonotes',
          title: 'x',
          brief: '',
          createdAt: DateTime(2026),
          completed: true));
      await env.repo.saveLesson(Lesson(
          id: 'review',
          title: 'x',
          brief: '',
          createdAt: DateTime(2026),
          notesMarkdown: '# R',
          completed: true,
          covers: const ['early']));
      await env.repo.saveLesson(Lesson(
          id: 'recap',
          title: 'x',
          brief: '',
          createdAt: DateTime(2026),
          notesMarkdown: '# R',
          completed: true,
          recapOf: 'early'));
      expect([for (final l in await env.service.studiedLessons()) l.id],
          ['early', 'late']);
    });
  });

  group('createReview', () {
    test('immediate: summarises what lacks a summary, then writes the '
        'review, its cards and its lecture', () async {
      await init(immediate);
      _answerReviews(env);
      await env.repo.saveLesson(_studied('a', 'Banach'));
      await env.repo
          .saveLesson(_studied('b', 'Compactness', digest: 'Kept digest.'));

      final id = await env.service.createReview(['a', 'b']);
      await env.settle();

      final digests = [for (final r in env.fake.requests) if (_isDigest(r.body)) r];
      expect(digests, hasLength(1));
      expect(FakeOpenRouter.userText(digests.single.body),
          contains('Full notes of Banach'));
      expect((await env.lesson('a')).digest, '## Key facts\n\nDigest of Banach.');
      expect((await env.lesson('b')).digest, 'Kept digest.');

      final asked = [for (final r in env.fake.requests) if (_isReview(r.body)) r];
      final user = FakeOpenRouter.userText(asked.single.body);
      expect(user, contains('=== LESSON 1: Banach ==='));
      expect(user, contains('Digest of Banach.'));
      expect(user, contains('=== LESSON 2: Compactness ==='));
      expect(user, contains('Kept digest.'));
      // The summaries stand in for the notes.
      expect(user, isNot(contains('Full notes of')));

      final review = await env.lesson(id);
      expect(review.stage, LessonStage.ready);
      expect(review.isReview, isTrue);
      expect(review.title, 'Review: Fixed points and compactness');
      expect(review.notesMarkdown, startsWith('# Review: Fixed points'));
      expect(review.notesMarkdown, isNot(contains('CARDS')));
      expect(review.material, contains('## Banach\n\n## Key facts'));
      expect(review.material, contains('## Compactness\n\nKept digest.'));
      expect(review.studyText, contains('Kept digest.'));
      expect(review.studyText, startsWith('# Review: Fixed points'));
      expect(review.writtenBy, 'GPT-6 Luna');
      expect(review.hasAudio, isTrue);
      expect(review.review, isNull);

      final cards = await CardStore(env.db).load(id);
      expect([for (final c in cards) c.topic], ['Banach', 'Compactness']);
      expect(cards.first.front, 'State the Banach fixed-point theorem.');
      expect(env.notifications.ready.single.id, id);
    });

    test('nothing to summarise: straight to the review', () async {
      await init(immediate);
      _answerReviews(env);
      await env.repo.saveLesson(_studied('a', 'Banach', digest: 'D.'));
      await env.service.createReview(['a']);
      await env.settle();
      expect(env.fake.requests.where((r) => _isDigest(r.body)), isEmpty);
      expect(env.fake.requests.where((r) => _isReview(r.body)), hasLength(1));
    });

    test('an empty summary falls back to the Summary section of the notes',
        () async {
      await init(immediate);
      // A code fence with nothing in it.
      _answerReviews(env, digest: '```\n```');
      await env.repo.saveLesson(_studied('a', 'Banach'));
      final id = await env.service.createReview(['a']);
      await env.settle();
      expect((await env.lesson('a')).digest, isNull);
      expect((await env.lesson(id)).material, contains('Summary of Banach.'));
    });

    test('batch: one batch of summaries, then the review, then the script; '
        'a lesson deleted meanwhile does not shift the answers', () async {
      await init(const AppSettings(apiKey: 'k')); // Sol through the batch API
      _answerReviews(env);
      await env.repo.saveLesson(_studied('a', 'Banach'));
      await env.repo.saveLesson(_studied('b', 'Compactness'));
      await env.repo.saveLesson(_studied('c', 'Baire'));

      final id = await env.service.createReview(['a', 'b', 'c']);
      await env.settle();
      expect(env.fake.chatBodies, isEmpty);
      expect((env.fake.submitted.single['requests'] as List), hasLength(3));
      var review = await env.lesson(id);
      expect(review.batch!.step, BatchStep.digest);
      expect(review.batch!.keys, ['a', 'b', 'c']);

      await env.repo.deleteLesson('a');
      await env.finishAndPoll();
      expect((await env.lesson('b')).digest, contains('Digest of Compactness.'));
      expect((await env.lesson('c')).digest, contains('Digest of Baire.'));
      review = await env.lesson(id);
      expect(review.batch!.step, BatchStep.notes);
      final user = FakeOpenRouter.userText(env.fake.batchBodies.last);
      expect(user, contains('=== LESSON 1: Compactness ==='));
      expect(user, contains('=== LESSON 2: Baire ==='));
      expect(user, isNot(contains('Banach')));

      await env.finishAndPoll();
      expect((await env.lesson(id)).batch!.step, BatchStep.narration);
      expect(await CardStore(env.db).load(id), hasLength(2));

      await env.finishAndPoll();
      review = await env.lesson(id);
      expect(review.stage, LessonStage.ready);
      expect(review.writtenBy, 'GPT-6.1 Sol (batch) · high');
      expect(env.fake.submitted, hasLength(3));
    });

    test('fails with a reason when its lessons are gone', () async {
      await init(immediate);
      _answerReviews(env);
      final id = await env.service.createReview(['gone']);
      await env.settle();
      final review = await env.lesson(id);
      expect(review.stage, LessonStage.failed);
      expect(review.error, contains('no longer in the library'));
    });

    test('needs at least one lesson', () async {
      await init(immediate);
      expect(() => env.service.createReview([]), throwsA(isA<Exception>()));
    });

    test('deleting a review deletes its cards', () async {
      await init(immediate);
      _answerReviews(env);
      await env.repo.saveLesson(_studied('a', 'Banach', digest: 'D.'));
      final id = await env.service.createReview(['a']);
      await env.settle();
      expect(await CardStore(env.db).load(id), isNotEmpty);
      await env.repo.deleteLesson(id);
      expect(await CardStore(env.db).load(id), isEmpty);
    });
  });
}
