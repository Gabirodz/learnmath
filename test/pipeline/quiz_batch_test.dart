import 'package:flutter_test/flutter_test.dart';
import 'package:learnmath/core/models.dart';
import 'package:learnmath/quiz/quiz_models.dart';
import 'package:learnmath/quiz/quiz_store.dart';

import 'fakes.dart';

const _quiz = 'QUESTION: What does the Banach fixed-point theorem guarantee?\n'
    'TYPE: CHOICE\n'
    'A: A unique fixed point\n'
    'B: No fixed point\n'
    'C: Two fixed points\n'
    'D: Infinitely many fixed points\n'
    'CORRECT: A\n'
    'EXPLAIN: A contraction of a complete metric space has exactly one.\n'
    '\n'
    'QUESTION: Why does completeness matter?\n'
    'TYPE: FREE\n'
    'ANSWER: The Picard iterates form a Cauchy sequence, which must converge.\n';

const _request = QuizRequest(
    difficulty: QuizDifficulty.hard, kind: QuizKind.mixed, count: 2);

void main() {
  late Env env;
  late QuizStore store;

  setUp(() async {
    env = Env();
    await env.init();
    store = QuizStore(env.db);
    await env.repo.saveLesson(Lesson(
      id: 'l1',
      title: 'Banach',
      brief: '',
      createdAt: DateTime(2026),
      notesMarkdown: '# Banach\n\nA contraction has a unique fixed point.',
    ));
    env.fake.extraAnswer = (body) =>
        '${body['messages']}'.contains('QUESTION:') ? _quiz : null;
  });
  tearDown(() => env.dispose());

  test('an ordered quiz waits, arrives, is announced and its batch deleted',
      () async {
    final id = await env.service.orderQuiz('l1', _request);
    var quizzes = await store.load('l1');
    expect(quizzes.single.id, id);
    expect(quizzes.single.isWaiting, isTrue);
    expect(quizzes.single.questions, isEmpty);
    expect(env.fake.submitted, hasLength(1));
    // The background check and the keep-alive know about it.
    expect(env.background.updates.last.single.quizId, id);
    expect(env.background.updates.last.single.lessonTitle, 'Banach');
    expect(env.keepAlive.calls.last, 'hold: Waiting for 1 batch answer');

    // Not finished yet: nothing changes.
    await env.service.pollBatches();
    expect((await store.load('l1')).single.isWaiting, isTrue);

    await env.finishAndPoll();
    quizzes = await store.load('l1');
    expect(quizzes.single.isWaiting, isFalse);
    expect(quizzes.single.questions, hasLength(2));
    expect(quizzes.single.request?.count, 2);
    expect(env.notifications.quizzes.single.questions, 2);
    expect(env.background.updates.last, isEmpty);
    expect(env.keepAlive.calls.last, 'release');
    expect(env.fake.deleted, [env.fake.lastBatchId]);
  });

  test('an unusable answer marks the quiz failed and says why', () async {
    await env.service.orderQuiz('l1', _request);
    env.fake.extraAnswer = (_) => 'Sorry, no quiz today.';
    await env.finishAndPoll();
    final q = (await store.load('l1')).single;
    expect(q.isFailed, isTrue);
    expect(q.error, contains('unusable'));
    expect(env.notifications.quizzes.single.reason, contains('unusable'));
  });

  test('a cancelled quiz is forgotten and not announced', () async {
    final id = await env.service.orderQuiz('l1', _request);
    await env.service.cancelQuiz('l1', id);
    expect(await store.load('l1'), isEmpty);
    expect(env.background.updates.last, isEmpty);
    await env.finishAndPoll();
    expect(env.notifications.quizzes, isEmpty);
  });

  test('the quiz request asks for something other than earlier quizzes',
      () async {
    await store.save('l1', [
      Quiz(
        id: 'old',
        createdAt: DateTime(2026),
        questions: const [
          QuizQuestion(prompt: 'What is a contraction?', answer: 'A map...'),
        ],
      ),
    ]);
    await env.service.orderQuiz('l1', _request);
    expect('${env.fake.batchBodies.single['messages']}',
        contains('What is a contraction?'));
  });

  test('without an API key nothing is ordered', () async {
    env.settings = const AppSettings();
    await expectLater(
        env.service.orderQuiz('l1', _request), throwsA(isA<Exception>()));
    expect(env.fake.submitted, isEmpty);
  });
}
