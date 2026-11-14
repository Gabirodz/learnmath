import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:learnmath/ai/openrouter_client.dart';
import 'package:learnmath/core/models.dart';
import 'package:learnmath/core/providers.dart';
import 'package:learnmath/core/storage.dart';
import 'package:learnmath/quiz/quiz_controller.dart';
import 'package:learnmath/quiz/quiz_models.dart';
import 'package:learnmath/quiz/quiz_pane.dart';
import 'package:learnmath/quiz/quiz_store.dart';
import 'package:sembast/sembast_memory.dart';

import 'quiz_parser_test.dart' show quizText;

class _Settings extends SettingsNotifier {
  _Settings(this.s);
  final AppSettings s;
  @override
  AppSettings build() => s;
}

void main() {
  late Database db;
  late LibraryRepository repo;
  late Directory tmp;
  var n = 0;
  final calls = <({String system, String user})>[];
  late String Function(int call) answer;

  Future<void> open() async {
    tmp = await Directory.systemTemp.createTemp('quiz_test');
    db = await newDatabaseFactoryMemory().openDatabase('quiz${n++}');
    repo = LibraryRepository(
        db, AppPaths(docs: '${tmp.path}/d', support: '${tmp.path}/s'));
    await repo.saveLesson(Lesson(
        id: 'l1',
        title: 'Sylow',
        brief: '',
        createdAt: DateTime(2026),
        stage: LessonStage.ready,
        notesMarkdown: '# Sylow\n\nNOTES BODY'));
  }

  Future<void> close() async {
    await db.close();
    await tmp.delete(recursive: true);
  }

  List<Object> overrides(AppSettings settings) => [
        repositoryProvider.overrideWithValue(repo),
        databaseProvider.overrideWithValue(db),
        settingsProvider.overrideWith(() => _Settings(settings)),
        quizShuffleProvider.overrideWithValue(Random(1)),
        quizModelProvider.overrideWithValue(({
          required apiKey,
          required model,
          required messages,
          reasoningEffort,
          required onDelta,
        }) async {
          calls.add(
              (system: messages.first.content, user: messages.last.content));
          return answer(calls.length);
        }),
      ];

  group('controller', () {
    setUp(open);
    tearDown(close);

    Future<ProviderContainer> make(
        [AppSettings settings = const AppSettings(apiKey: 'k')]) async {
      calls.clear();
      final c = ProviderContainer(overrides: overrides(settings).cast());
      addTearDown(c.dispose);
      c.listen(quizControllerProvider('l1'), (_, _) {});
      await pumpEventQueue();
      return c;
    }

    test('generate stores the quiz; the next one is told what was asked',
        () async {
      answer = (_) => quizText;
      final c = await make();
      final ctl = c.read(quizControllerProvider('l1').notifier);

      final id = await ctl.generate(
          difficulty: QuizDifficulty.hard, kind: QuizKind.mixed, count: 2);
      expect(id, isNotNull);
      final quiz = c.read(quizControllerProvider('l1')).byId(id)!;
      expect(quiz.questions, hasLength(2));
      expect(quiz.difficulty, QuizDifficulty.hard);
      expect(calls.single.user, contains('NOTES BODY'));
      expect(calls.single.user, isNot(contains('already been asked')));
      expect((await QuizStore(db).load('l1')).single.id, id);

      await ctl.generate(
          difficulty: QuizDifficulty.easy, kind: QuizKind.choice, count: 2);
      expect(calls.last.user, contains('already been asked'));
      expect(calls.last.user, contains('- Why are all Sylow'));
      expect(c.read(quizControllerProvider('l1')).quizzes, hasLength(2));
    });

    test('an unusable answer or a missing key is reported, nothing stored',
        () async {
      answer = (_) => 'I cannot help with that.';
      var c = await make();
      expect(
          await c.read(quizControllerProvider('l1').notifier).generate(
              difficulty: QuizDifficulty.easy,
              kind: QuizKind.choice,
              count: 3),
          isNull);
      expect(c.read(quizControllerProvider('l1')).error, contains('unusable'));
      expect(c.read(quizControllerProvider('l1')).writing, isFalse);

      c = await make(const AppSettings());
      await c.read(quizControllerProvider('l1').notifier).generate(
          difficulty: QuizDifficulty.easy, kind: QuizKind.choice, count: 3);
      expect(c.read(quizControllerProvider('l1')).error, contains('API key'));
      expect(calls, isEmpty);
      expect(await QuizStore(db).load('l1'), isEmpty);
    });

    test('choosing marks right or wrong once; grading a free answer asks '
        'the model with the notes', () async {
      answer = (_) => 'VERDICT: PARTIAL\nFEEDBACK: Say why they are conjugate.';
      final c = await make();
      final ctl = c.read(quizControllerProvider('l1').notifier);
      final id = await ctl.import(quizText);
      Quiz quiz() => c.read(quizControllerProvider('l1')).byId(id)!;
      expect(quiz().imported, isTrue);

      final wrong = (quiz().questions[0].correct! + 1) % 4;
      await ctl.choose(id, 0, wrong);
      await ctl.choose(id, 0, quiz().questions[0].correct!);
      expect(quiz().questions[0].verdict, Verdict.wrong);
      expect(quiz().questions[0].chosen, wrong);

      await ctl.grade(id, 1, 'they are conjugate');
      final q = quiz().questions[1];
      expect(q.verdict, Verdict.partial);
      expect(q.feedback, 'Say why they are conjugate.');
      expect(q.reply, 'they are conjugate');
      expect(calls.single.user, contains('NOTES BODY'));
      expect(calls.single.user, contains('they are conjugate'));
      expect(calls.single.system, contains('judge the ideas'));
      expect(quiz().score, 0.5);

      final stored = (await QuizStore(db).load('l1')).single;
      expect(stored.finished, isTrue);
    });

    test('a failed grading keeps the answer and allows judging it oneself',
        () async {
      answer = (_) => throw OpenRouterException('No connection.');
      final c = await make();
      final ctl = c.read(quizControllerProvider('l1').notifier);
      final id = await ctl.import(quizText);

      await ctl.grade(id, 1, 'conjugate');
      var s = c.read(quizControllerProvider('l1'));
      expect(s.error, 'No connection.');
      expect(s.ungraded, (quizId: id, index: 1));
      expect(s.grading, isNull);
      expect(s.byId(id)!.questions[1].answered, isFalse);

      await ctl.selfGrade(id, 1, 'conjugate', Verdict.correct);
      s = c.read(quizControllerProvider('l1'));
      expect(s.byId(id)!.questions[1].verdict, Verdict.correct);
      expect(s.error, isNull);
    });

    test('import rejects text without questions; delete removes; deleting '
        'the lesson removes its quizzes', () async {
      final c = await make();
      final ctl = c.read(quizControllerProvider('l1').notifier);
      await expectLater(ctl.import('hello'), throwsFormatException);
      final id = await ctl.import(quizText);
      await ctl.delete(id);
      expect(await QuizStore(db).load('l1'), isEmpty);

      await ctl.import(quizText);
      await repo.deleteLesson('l1');
      expect(await QuizStore(db).load('l1'), isEmpty);
    });
  });

  group('pane', () {
    String? clipboard;

    Future<void> pump(WidgetTester tester, AppSettings settings) async {
      tester.view.physicalSize = const Size(420, 1600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.runAsync(open);
      addTearDown(() => tester.runAsync(close));
      calls.clear();
      clipboard = null;
      tester.binding.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.setData') {
          clipboard = (call.arguments as Map)['text'] as String;
        }
        if (call.method == 'Clipboard.getData') return {'text': clipboard};
        return null;
      });
      addTearDown(() => tester.binding.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null));
      await tester.pumpWidget(ProviderScope(
        overrides: [
          ...overrides(settings).cast(),
          lessonProvider.overrideWith((ref, id) => Stream.value(Lesson(
              id: id,
              title: 'Sylow',
              brief: '',
              createdAt: DateTime(2026),
              notesMarkdown: '# Sylow\n\nNOTES BODY'))),
        ],
        child: const MaterialApp(
            home: Scaffold(body: QuizPane(lessonId: 'l1'))),
      ));
      for (var i = 0; i < 5; i++) {
        await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 60)));
        await tester.pump(const Duration(milliseconds: 100));
      }
    }

    Future<void> settle(WidgetTester tester) async {
      for (var i = 0; i < 5; i++) {
        await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 60)));
        await tester.pump(const Duration(milliseconds: 100));
      }
    }

    testWidgets('without a key: copy the prompt, paste the quiz, answer it',
        (tester) async {
      await pump(tester, const AppSettings());
      expect(find.text('Start quiz'), findsNothing);

      await tester.tap(find.text('Hard'));
      await tester.tap(find.text('3'));
      await tester.pump();
      await tester.tap(find.text('1. Copy prompt'));
      await settle(tester);
      expect(clipboard, contains('exactly 3 questions'));
      expect(clipboard, contains('Hard: transfer'));
      expect(clipboard, contains('NOTES BODY'));

      clipboard = '````\n$quizText````';
      await tester.tap(find.text('2. Paste answer'));
      await settle(tester);
      expect(find.text('0 of 2 answered'), findsOneWidget);

      // The free question: type, reveal, judge.
      await tester.enterText(find.byType(TextField), 'conjugate');
      await tester.pump();
      await tester.tap(find.text('Show reference answer'));
      await tester.pump();
      await tester.tap(find.text('Got it'));
      await settle(tester);
      expect(find.text('Correct'), findsOneWidget);
      expect(find.text('1 of 2 answered'), findsOneWidget);
      expect(calls, isEmpty);

      await tester.tap(find.text('Quizzes'));
      await settle(tester);
      expect(find.text('Earlier quizzes'), findsOneWidget);
      expect(find.textContaining('imported'), findsOneWidget);
    });

    testWidgets('with a key: start a quiz and have a free answer checked',
        (tester) async {
      answer = (call) => call == 1
          ? quizText
          : 'VERDICT: CORRECT\nFEEDBACK: Exactly the idea.';
      await pump(tester, const AppSettings(apiKey: 'k'));
      await tester.tap(find.text('Start quiz'));
      await settle(tester);
      expect(find.text('Question 2'), findsOneWidget);

      await tester.enterText(find.byType(TextField), 'they are conjugate');
      await tester.pump();
      await tester.tap(find.text('Check answer'));
      await settle(tester);
      expect(find.text('Correct'), findsOneWidget);
      expect(find.textContaining('Exactly the idea.'), findsOneWidget);
      expect(calls, hasLength(2));
    });
  });
}
