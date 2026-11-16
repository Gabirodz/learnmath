import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:learnmath/core/models.dart';
import 'package:learnmath/core/providers.dart';
import 'package:learnmath/pipeline/generation_service.dart';
import 'package:learnmath/ui/create_sheet.dart';

import '../pipeline/fakes.dart';

class _Settings extends SettingsNotifier {
  _Settings(this.initial);
  final AppSettings initial;

  @override
  AppSettings build() => initial;

  @override
  Future<void> update(AppSettings Function(AppSettings) change) async {
    state = change(state);
  }
}

/// Records what the sheet asks for without touching the database, so no
/// real I/O runs inside the widget test's fake-async zone.
class _Gen implements GenerationService {
  final lessons = <String>[];
  final courses = <(String, int?)>[];
  final planners = <ModelChoice?>[];

  /// The model each lesson or course was created with.
  final models = <ModelChoice?>[];

  @override
  Future<String> createLesson(String request, {ModelChoice? model}) async {
    lessons.add(request);
    models.add(model);
    return 'L${lessons.length}';
  }

  /// Planning a course waits for this, when set.
  Completer<void>? planning;

  @override
  Future<String> createCourse(String topic,
      {int? lessonCount, ModelChoice? model, ModelChoice? planner}) async {
    await planning?.future;
    courses.add((topic, lessonCount));
    models.add(model);
    planners.add(planner);
    return 'C${courses.length}';
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

const _batchHint = 'Written through the batch queue';
const _courseBatchHint = 'The outline is planned now';
const _checking = 'Checking what this lesson builds on…';
const _noKey = 'Add your OpenRouter API key in Settings';

void main() {
  late Env env;
  var live = false;
  String? location;
  late _Gen gen;

  setUp(() => live = false);
  tearDown(() async {
    if (live) await env.dispose();
  });

  /// Pumps an app with a button that opens the sheet.
  Future<void> open(WidgetTester tester, AppSettings settings) async {
    tester.view.physicalSize = const Size(400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    location = null;
    gen = _Gen();
    env = Env();
    env.settings = settings;
    await tester.runAsync(() => env.init());
    live = true;

    final router = GoRouter(routes: [
      GoRoute(
        path: '/',
        builder: (_, _) => Scaffold(
          body: Builder(
            builder: (c) => Center(
              child: TextButton(
                  onPressed: () => showCreateSheet(c),
                  child: const Text('open sheet')),
            ),
          ),
        ),
      ),
      for (final p in [
        '/lesson/:id', '/course/:id', '/settings', '/import-book',
        '/import-lesson', '/import-course',
      ])
        GoRoute(
          path: p,
          builder: (c, state) {
            location = state.uri.toString();
            return Scaffold(body: Text('page $p'));
          },
        ),
    ]);
    addTearDown(router.dispose);

    await tester.pumpWidget(ProviderScope(
      overrides: [
        settingsProvider.overrideWith(() => _Settings(settings)),
        generationProvider.overrideWithValue(gen),
        repositoryProvider.overrideWithValue(env.repo),
      ],
      child: MaterialApp.router(routerConfig: router),
    ));
    await tester.tap(find.text('open sheet'));
    await tester.pumpAndSettle();
  }

  Future<void> settleService(WidgetTester tester) async {
    await tester.pumpAndSettle();
  }

  group('batch hint', () {
    testWidgets('shown for a batch preset (the default) with a key',
        (tester) async {
      await open(tester, const AppSettings(apiKey: 'k'));
      expect(find.textContaining(_batchHint), findsOneWidget);
      expect(find.textContaining(_courseBatchHint), findsNothing);
    });

    testWidgets('not shown for an immediate preset', (tester) async {
      await open(tester, const AppSettings(apiKey: 'k', lessonPreset: 'luna'));
      expect(find.textContaining(_batchHint), findsNothing);
      expect(find.textContaining(_courseBatchHint), findsNothing);
    });

    testWidgets('course mode shows the outline wording instead',
        (tester) async {
      await open(tester, const AppSettings(apiKey: 'k'));
      await tester.tap(find.text('Course'));
      await tester.pumpAndSettle();
      expect(find.textContaining(_batchHint), findsNothing);
      expect(find.textContaining(_courseBatchHint), findsOneWidget);
    });

    testWidgets('not shown without an API key', (tester) async {
      await open(tester, const AppSettings());
      expect(find.textContaining(_batchHint), findsNothing);
      expect(find.textContaining(_noKey), findsOneWidget);
    });
  });

  group('writing the lesson outside the app', () {
    testWidgets('the link opens the import screen with the typed topic',
        (tester) async {
      await open(tester, const AppSettings(apiKey: 'k'));
      await tester.enterText(find.byType(TextField), 'Sylow theorems');
      await tester.tap(find.text('Or write it with your own AI assistant'));
      await tester.pumpAndSettle();
      expect(location, '/import-lesson?topic=Sylow+theorems');
      expect(gen.lessons, isEmpty);
    });

    testWidgets('offered instead of creating when there is no key',
        (tester) async {
      await open(tester, const AppSettings());
      await tester.tap(find.text('Use my own assistant'));
      await tester.pumpAndSettle();
      expect(location, '/import-lesson');
    });

    testWidgets('a course is planned on the course import screen',
        (tester) async {
      await open(tester, const AppSettings());
      await tester.tap(find.text('Course'));
      await tester.pumpAndSettle();
      expect(find.text('Or write it with your own AI assistant'), findsNothing);
      await tester.enterText(find.byType(TextField), 'Galois theory');
      await tester.tap(find.text('Or plan it with your own AI assistant'));
      await tester.pumpAndSettle();
      expect(location, '/import-course?topic=Galois+theory');
      expect(gen.courses, isEmpty);
    });

    testWidgets('without a key the course card offers it too', (tester) async {
      await open(tester, const AppSettings());
      await tester.tap(find.text('Course'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Use my own assistant'));
      await tester.pumpAndSettle();
      expect(location, '/import-course');
    });
  });

  group('model', () {
    AppSettings settings(WidgetTester tester) =>
        ProviderScope.containerOf(tester.element(find.byType(MaterialApp)))
            .read(settingsProvider);

    Future<void> choose(WidgetTester tester, String from, String item) async {
      await tester.ensureVisible(find.text(from));
      await tester.pumpAndSettle();
      await tester.tap(find.text(from));
      await tester.pumpAndSettle();
      await tester.tap(find.text(item).last);
      await tester.pumpAndSettle();
    }

    /// Opens the writer's sheet from its compact button ([label]), lets
    /// [pick] change it, and closes the sheet again.
    Future<void> inWriterSheet(WidgetTester tester, String label,
        Future<void> Function() pick) async {
      await tester.ensureVisible(find.text(label));
      await tester.pumpAndSettle();
      await tester.tap(find.text(label));
      await tester.pumpAndSettle();
      expect(find.text('Lesson writer'), findsOneWidget);
      await pick();
      Navigator.of(tester.element(find.text('Lesson writer'))).pop();
      await tester.pumpAndSettle();
      expect(find.text('Lesson writer'), findsNothing);
    }

    testWidgets('starts as the one picked last and is passed on unchanged',
        (tester) async {
      await open(tester,
          const AppSettings(apiKey: 'k', prerequisiteCheck: false));
      expect(find.text('Writes the lesson'), findsOneWidget);
      expect(find.text('GPT-6.1 Sol (batch) · high'), findsOneWidget);
      // The full picker is only in the button's sheet.
      expect(find.text('Reasoning effort'), findsNothing);
      await tester.enterText(find.byType(TextField), 'Sylow theorems');
      await tester.pump();
      await tester.tap(find.text('Create lesson'));
      await settleService(tester);
      expect(gen.models.single,
          const ModelChoice(model: 'openai/gpt-6.1-sol', effort: 'high', batch: true));
    });

    testWidgets('another model and effort write this lesson and are '
        'remembered', (tester) async {
      await open(tester,
          const AppSettings(apiKey: 'k', prerequisiteCheck: false));
      await inWriterSheet(tester, 'GPT-6.1 Sol (batch) · high', () async {
        await choose(tester, 'GPT-6.1 Sol (batch) · recommended',
            'GPT-6 Luna (batch)');
        await choose(tester, 'High · recommended', 'Medium');
      });
      expect(find.text('GPT-6 Luna (batch) · medium'), findsOneWidget);
      expect(find.textContaining(_batchHint), findsOneWidget);
      await tester.enterText(find.byType(TextField), 'Sylow theorems');
      await tester.pump();
      await tester.ensureVisible(find.text('Create lesson'));
      await tester.tap(find.text('Create lesson'));
      await settleService(tester);

      const picked = ModelChoice(
          model: 'openai/gpt-6-luna', effort: 'medium', batch: true);
      expect(gen.models.single, picked);
      expect(settings(tester).lessonChoice, picked);
      expect(settings(tester).lessonPreset, 'luna-batch');
    });

    testWidgets('an immediate model takes the batch hint away',
        (tester) async {
      await open(tester, const AppSettings(apiKey: 'k'));
      await inWriterSheet(tester, 'GPT-6.1 Sol (batch) · high', () async {
        await choose(tester, 'GPT-6.1 Sol (batch) · recommended',
            'GPT-6 Luna (immediate)');
      });
      expect(find.textContaining(_batchHint), findsNothing);
    });

    testWidgets('a course: its lessons get the picked model, the planner '
        'plans it', (tester) async {
      await open(tester, const AppSettings(apiKey: 'k'));
      expect(find.text('Plans the course'), findsNothing); // lesson mode
      await tester.tap(find.text('Course'));
      await tester.pumpAndSettle();
      expect(find.text('Plans the course'), findsOneWidget);
      expect(find.text('Writes the lessons'), findsOneWidget);
      expect(find.text('GPT-6.1 Sol · high'), findsOneWidget); // planner
      expect(find.text('Reasoning effort'), findsNothing);
      await inWriterSheet(tester, 'GPT-6.1 Sol (batch) · high', () async {
        await choose(tester, 'GPT-6.1 Sol (batch) · recommended',
            'GPT-6.1 Terra (batch)');
      });
      expect(find.text('GPT-6.1 Terra (batch) · high'), findsOneWidget);
      await tester.enterText(find.byType(TextField), 'Topology');
      await tester.pump();
      await tester.ensureVisible(find.text('Create course'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Create course'));
      await settleService(tester);
      expect(gen.courses.single.$1, 'Topology');
      expect(gen.models.single,
          const ModelChoice(model: 'openai/gpt-6.1-terra', effort: 'high', batch: true));
      expect(gen.planners.single,
          const ModelChoice(model: 'openai/gpt-6.1-sol', effort: 'high'));
    });

    testWidgets('no picker without a key', (tester) async {
      await open(tester, const AppSettings());
      expect(find.text('Writes the lesson'), findsNothing);
    });
  });

  group('creating without a prerequisite lookup', () {
    testWidgets('prerequisiteCheck off: Create lesson creates directly',
        (tester) async {
      await open(
          tester,
          const AppSettings(
              apiKey: 'k', lessonPreset: 'luna', prerequisiteCheck: false));
      expect(
          tester
              .widget<FilledButton>(find.widgetWithText(FilledButton, 'Create lesson'))
              .onPressed,
          isNull,
          reason: 'disabled while the request is empty');
      await tester.enterText(find.byType(TextField), 'Sylow theorems');
      await tester.pump();
      await tester.tap(find.text('Create lesson'));
      await tester.pump();
      expect(find.text(_checking), findsNothing);
      await settleService(tester);

      expect(gen.lessons, ['Sylow theorems']);
      expect(location, '/lesson/L1');
      expect(find.byType(BottomSheet), findsNothing);
    });

    testWidgets('prerequisiteCheck off, batch preset: lesson is created',
        (tester) async {
      await open(tester,
          const AppSettings(apiKey: 'k', prerequisiteCheck: false));
      await tester.enterText(find.byType(TextField), 'Galois theory');
      await tester.pump();
      await tester.tap(find.text('Create lesson'));
      await settleService(tester);
      expect(gen.lessons, ['Galois theory']);
      expect(location, '/lesson/L1');
      expect(env.fake.requests, isEmpty, reason: 'no prerequisite request');
    });

    testWidgets('no API key: no Create button, a way to settings instead',
        (tester) async {
      await open(tester, const AppSettings());
      expect(find.text('Create lesson'), findsNothing);
      expect(find.text('Open settings'), findsOneWidget);
      await tester.tap(find.text('Open settings'));
      await tester.pumpAndSettle();
      expect(location, '/settings');
    });

    testWidgets('a sheet dismissed while the course is planned does not '
        'take the screen beneath it along', (tester) async {
      await open(tester, const AppSettings(apiKey: 'k'));
      gen.planning = Completer<void>();
      await tester.tap(find.text('Course'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'Galois theory');
      await tester.pump();
      await tester.ensureVisible(find.text('Create course'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Create course'));
      await tester.pump();
      expect(find.text('Planning the course…'), findsOneWidget);

      // The system back gesture closes the sheet.
      tester.state<NavigatorState>(find.byType(Navigator).last).pop();
      await tester.pumpAndSettle();
      expect(find.text('Planning the course…'), findsNothing);

      gen.planning!.complete();
      await tester.pumpAndSettle();
      expect(location, '/course/C1');
      // The page the sheet was opened from is still under the course.
      expect(find.text('open sheet', skipOffstage: false), findsOneWidget);
    });

    testWidgets('course mode never looks up prerequisites', (tester) async {
      await open(tester, const AppSettings(apiKey: 'k', lessonPreset: 'luna'));
      await tester.tap(find.text('Course'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'Introduction to topology');
      await tester.pump();
      await tester.ensureVisible(find.text('Create course'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Create course'));
      await tester.pump();
      expect(find.text(_checking), findsNothing);
      await settleService(tester);

      expect(location, '/course/C1');
      expect(gen.courses, [('Introduction to topology', null)]);
      expect(gen.lessons, isEmpty);
      expect(env.fake.requests, isEmpty, reason: 'no lookup request');
    });
  });
}
