import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:learnmath/core/models.dart';
import 'package:learnmath/core/providers.dart';
import 'package:learnmath/core/storage.dart';
import 'package:learnmath/exercises/exercise_controller.dart';
import 'package:learnmath/exercises/exercises_sheet.dart';
import 'package:sembast/sembast_memory.dart';

class _Settings extends SettingsNotifier {
  @override
  AppSettings build() => const AppSettings(apiKey: 'k');
}

void main() {
  testWidgets('lists exercises, Hint shows the hint, no overflow at 320x640',
      (tester) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    late Database db;
    late LibraryRepository repo;
    late Directory tmp;
    await tester.runAsync(() async {
      tmp = await Directory.systemTemp.createTemp('sheet');
      db = await newDatabaseFactoryMemory().openDatabase('sheet');
      repo = LibraryRepository(
          db, AppPaths(docs: '${tmp.path}/d', support: '${tmp.path}/s'));
      await repo.saveLesson(Lesson(
          id: 'l1',
          title: 'Calc',
          brief: '',
          createdAt: DateTime(2026),
          notesMarkdown: '# Calc\n\n## Exercises\n\n'
              '1. Differentiate \$x^2\$ with respect to a very long variable name.\n'
              '2. Integrate \$x\$.\n'));
    });

    final container = ProviderContainer(overrides: [
      repositoryProvider.overrideWithValue(repo),
      settingsProvider.overrideWith(_Settings.new),
      exerciseModelProvider.overrideWithValue(({
        required apiKey,
        required model,
        required messages,
        reasoningEffort,
        required onDelta,
      }) async {
        onDelta('Use the power rule.');
        return 'Use the power rule.';
      }),
    ]);
    addTearDown(container.dispose);

    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: TextButton(
                onPressed: () => showExercisesSheet(context, 'l1'),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.text('Exercise 1'), findsOneWidget);
    expect(find.text('Exercise 2'), findsOneWidget);
    expect(find.text('Hint'), findsNWidgets(2));
    expect(find.text('Solution'), findsNWidgets(2));
    expect(find.textContaining('Use the power rule', findRichText: true), findsNothing);

    await tester.tap(find.text('Hint').first);
    for (var i = 0; i < 4; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 100)));
      await tester.pump(const Duration(milliseconds: 100));
    }

    expect(tester.takeException(), isNull);
    expect(find.textContaining('Use the power rule', findRichText: true), findsWidgets);
    await tester.runAsync(() => tmp.delete(recursive: true));
  });
}
