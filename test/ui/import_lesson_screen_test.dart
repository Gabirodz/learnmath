import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:learnmath/ai/lesson_import.dart';
import 'package:learnmath/core/models.dart';
import 'package:learnmath/core/providers.dart';
import 'package:learnmath/core/storage.dart';
import 'package:learnmath/pipeline/generation_service.dart';
import 'package:learnmath/ui/import_lesson_screen.dart';

class _Settings extends SettingsNotifier {
  _Settings(this.initial);
  final AppSettings initial;

  @override
  AppSettings build() => initial;
}

class _Gen implements GenerationService {
  final imported = <ImportedLesson>[];
  final into = <String?>[];
  final courses = <CourseOutline>[];

  @override
  Future<String> importLesson(ImportedLesson lesson, {String? into}) async {
    imported.add(lesson);
    this.into.add(into);
    return into ?? 'L1';
  }

  @override
  Future<String> importCourse(CourseOutline outline,
      {ModelChoice? model,
      Course? continues,
      List<Lesson> earlier = const []}) async {
    courses.add(outline);
    return 'C1';
  }

  @override
  Future<CourseContext?> courseContext(Lesson lesson) async =>
      const CourseContext(
        courseTitle: 'Galois Theory',
        courseDescription: 'Fields and their symmetries.',
        lessonTitles: ['Field extensions', 'Splitting fields', 'The Galois group'],
        lessonIndex: 1,
      );

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

/// The one lesson the screen asks the library for.
class _Repo implements LibraryRepository {
  @override
  Future<Lesson?> getLesson(String id) async => Lesson(
        id: id,
        courseId: 'C1',
        order: 1,
        title: 'Splitting fields',
        brief: 'Existence and uniqueness.',
        createdAt: DateTime(2026),
      );

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

const _notes = '<<<NOTES\n# Sylow Theorems\n\n'
    r'Let $G$ be a finite group.'
    '\nNOTES>>>\n';
const _scriptStart = '<<<SCRIPT\nSECTION: Intro\nSAY: One.\nSAY: Two.\n';
const _scriptEnd = 'SAY: Three.\nSCRIPT>>>';

void main() {
  late _Gen gen;
  String? location;
  String? clipboard;

  Future<void> open(WidgetTester tester, AppSettings settings,
      {String start = '/'}) async {
    tester.view.physicalSize = const Size(400, 1400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    gen = _Gen();
    location = null;
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

    final router = GoRouter(initialLocation: start, routes: [
      GoRoute(
        path: '/',
        builder: (_, _) => const ImportLessonScreen(topic: 'Sylow theorems'),
      ),
      GoRoute(
        path: '/plan',
        builder: (_, _) =>
            const ImportLessonScreen(topic: 'Galois theory', course: true),
      ),
      GoRoute(
        path: '/course-page',
        builder: (c, _) => Scaffold(
          body: TextButton(
            onPressed: () => c.push('/slot'),
            child: const Text('course page'),
          ),
        ),
      ),
      GoRoute(
        path: '/slot',
        builder: (_, _) => const ImportLessonScreen(lessonId: 'L2'),
      ),
      for (final p in ['/lesson/:id', '/course/:id'])
        GoRoute(
          path: p,
          builder: (_, state) {
            location = state.uri.toString();
            return const Scaffold(body: Text('opened page'));
          },
        ),
    ]);
    addTearDown(router.dispose);
    await tester.pumpWidget(ProviderScope(
      overrides: [
        settingsProvider.overrideWith(() => _Settings(settings)),
        generationProvider.overrideWithValue(gen),
        repositoryProvider.overrideWithValue(_Repo()),
      ],
      child: MaterialApp.router(routerConfig: router),
    ));
    await tester.pumpAndSettle();
  }

  testWidgets('copies the prompt for the topic, following the settings',
      (tester) async {
    await open(tester, const AppSettings(mathChecks: false));
    await tester.tap(find.text('Copy prompt'));
    await tester.pumpAndSettle();
    expect(clipboard, contains('Lesson topic: Sylow theorems'));
    expect(clipboard, contains('<<<SCRIPT'));
    expect(clipboard, isNot(contains('<<<CHECKS')));
  });

  testWidgets('pasted answer is previewed and imported without a key',
      (tester) async {
    await open(tester, const AppSettings());
    expect(find.textContaining('Import and'), findsNothing);

    clipboard = '$_notes$_scriptStart$_scriptEnd';
    await tester.tap(find.text('Paste answer'));
    await tester.pumpAndSettle();
    expect(find.text('Sylow Theorems'), findsOneWidget);
    expect(find.textContaining('Lecture: about 1 min'), findsOneWidget);

    await tester.tap(find.text('Import and record the lecture'));
    await tester.pumpAndSettle();
    expect(gen.imported.single.segments, hasLength(3));
    expect(location, '/lesson/L1');
  });

  testWidgets('a cut-off answer is completed by pasting the continuation',
      (tester) async {
    await open(tester, const AppSettings());
    clipboard = '$_notes$_scriptStart';
    await tester.tap(find.text('Paste answer'));
    await tester.pumpAndSettle();
    expect(find.textContaining('continue'), findsOneWidget);

    clipboard = _scriptEnd;
    await tester.tap(find.text('Paste the continuation'));
    await tester.pumpAndSettle();
    expect(find.textContaining('continue'), findsNothing);
    expect(find.text('Paste the continuation'), findsNothing);
  });

  testWidgets('notes without a script cannot be imported without a key',
      (tester) async {
    await open(tester, const AppSettings());
    clipboard = _notes;
    await tester.tap(find.text('Paste answer'));
    await tester.pumpAndSettle();
    expect(find.textContaining('needs an OpenRouter key'), findsOneWidget);
    final button = tester.widget<FilledButton>(find.widgetWithText(
        FilledButton, 'Import and write the script here'));
    expect(button.onPressed, isNull);
  });

  testWidgets('a course: the plan is copied, pasted, previewed and created',
      (tester) async {
    await open(tester, const AppSettings(), start: '/plan');
    await tester.tap(find.text('6'));
    await tester.pump();
    await tester.tap(find.text('Copy prompt'));
    await tester.pumpAndSettle();
    expect(clipboard, contains('Galois theory'));
    expect(clipboard, contains('Plan exactly 6 lessons.'));
    expect(clipboard, contains('ONE code block'));

    clipboard = 'Here you go:\n```\nCOURSE: Galois Theory\n'
        'DESCRIPTION: Fields and their symmetries.\n'
        'LESSON: Field extensions\nBRIEF: Degree and the tower law.\n'
        'LESSON: Splitting fields\nBRIEF: Existence and uniqueness.\n```';
    await tester.tap(find.text('Paste answer'));
    await tester.pumpAndSettle();
    expect(find.text('Galois Theory'), findsOneWidget);
    expect(find.text('2. Splitting fields'), findsOneWidget);

    await tester.tap(find.text('Create course'));
    await tester.pumpAndSettle();
    expect(gen.courses.single.lessons, hasLength(2));
    expect(gen.courses.single.lessons[1].brief, 'Existence and uniqueness.');
    expect(location, '/course/C1');
  });

  testWidgets('a pasted lesson is no course plan', (tester) async {
    await open(tester, const AppSettings(), start: '/plan');
    clipboard = '$_notes$_scriptStart$_scriptEnd';
    await tester.tap(find.text('Paste answer'));
    await tester.pumpAndSettle();
    expect(find.textContaining('No course plan found'), findsOneWidget);
    expect(find.text('Create course'), findsNothing);
  });

  testWidgets('a planned lesson: the prompt knows the course, and the '
      'answer fills that lesson', (tester) async {
    await open(tester, const AppSettings(), start: '/course-page');
    await tester.tap(find.text('course page'));
    await tester.pumpAndSettle();
    expect(find.text('Splitting fields'), findsOneWidget);
    expect(find.textContaining('Lesson 2 of 3'), findsOneWidget);
    expect(find.byType(TextField), findsNothing);

    await tester.tap(find.text('Copy prompt'));
    await tester.pumpAndSettle();
    expect(clipboard, contains('Lesson topic: Splitting fields'));
    expect(clipboard, contains('What it should cover: Existence and uniqueness.'));
    expect(clipboard, contains('part of a course: "Galois Theory"'));
    expect(clipboard, contains('2. Splitting fields  <-- this lesson'));
    expect(clipboard, contains('(lesson 2 of 3), and at the end hint'));

    clipboard = '$_notes$_scriptStart$_scriptEnd';
    await tester.tap(find.text('Paste answer'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Import and record the lecture'));
    await tester.pumpAndSettle();
    expect(gen.into, ['L2']);
    expect(find.text('course page'), findsOneWidget, reason: 'back to the course');
  });

  testWidgets('text that is no lesson shows why', (tester) async {
    await open(tester, const AppSettings());
    clipboard = '<<<SCRIPT\nSAY: One.\nSCRIPT>>>';
    await tester.tap(find.text('Paste answer'));
    await tester.pumpAndSettle();
    expect(find.textContaining('No lecture notes found'), findsOneWidget);
  });
}
