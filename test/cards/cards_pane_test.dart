import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:learnmath/cards/card_models.dart';
import 'package:learnmath/cards/card_store.dart';
import 'package:learnmath/cards/cards_pane.dart';
import 'package:learnmath/core/providers.dart';
import 'package:sembast/sembast_memory.dart';

final _fixedNow = DateTime(2026, 11, 14, 9);

/// Lets the real sembast futures finish, then runs the fake timers they use.
Future<void> _settle(WidgetTester tester) async {
  await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)));
  await tester.pump(const Duration(milliseconds: 100));
}

Future<void> _pump(WidgetTester tester, Database db) async {
  final container = ProviderContainer(overrides: [
    databaseProvider.overrideWithValue(db),
    lessonProvider.overrideWith((ref, id) => Stream.value(null)),
  ]);
  addTearDown(container.dispose);
  await tester.pumpWidget(UncontrolledProviderScope(
    container: container,
    child: MaterialApp(
      home: Scaffold(
        body: CardsPane(lessonId: 'L', now: () => _fixedNow),
      ),
    ),
  ));
  await _settle(tester);
  await tester.pump();
}

const _group = Flashcard(
    front: 'What is a group?', back: 'A set with an associative operation.',
    topic: 'Groups');
const _ring = Flashcard(front: 'What is a ring?', back: 'A group with a second operation.');

void main() {
  late Database db;

  setUp(() async {
    db = await newDatabaseFactoryMemory().openDatabase('cards_pane_test.db');
  });

  testWidgets('an empty store says where the cards will appear',
      (tester) async {
    await _pump(tester, db);
    expect(find.text('Cards appear here once the review has been written.'),
        findsOneWidget);
  });

  testWidgets('shows, flips and grades cards; Got it saves box 1',
      (tester) async {
    await tester.runAsync(() => CardStore(db).save('L', [_group, _ring]));
    await _pump(tester, db);

    expect(find.text('What is a group?'), findsOneWidget);
    expect(find.text('Groups'), findsOneWidget);
    expect(find.text('Recall the answer, then tap the card.'), findsOneWidget);
    expect(find.text('Got it'), findsNothing);

    await tester.tap(find.byKey(const Key('card')));
    await tester.pump();
    expect(find.text('A set with an associative operation.'), findsOneWidget);
    expect(find.text('Again'), findsOneWidget);
    expect(find.text('Got it'), findsOneWidget);

    await tester.tap(find.text('Got it'));
    await _settle(tester);
    await tester.pump();
    expect(find.text('What is a ring?'), findsOneWidget);

    final stored = await tester.runAsync(() => CardStore(db).load('L'));
    expect(stored![0].box, 1);
    expect(stored[0].dueAt, _fixedNow.add(const Duration(days: 1)));
  });

  testWidgets('Again puts the card at the end of the queue and stores box 0',
      (tester) async {
    await tester.runAsync(() => CardStore(db).save('L', [_group, _ring]));
    await _pump(tester, db);

    await tester.tap(find.byKey(const Key('card')));
    await tester.pump();
    await tester.tap(find.text('Again'));
    await _settle(tester);
    await tester.pump();
    expect(find.text('What is a ring?'), findsOneWidget);

    final stored = await tester.runAsync(() => CardStore(db).load('L'));
    expect(stored![0].box, 0);
    expect(stored[0].dueAt, _fixedNow);

    await tester.tap(find.byKey(const Key('card')));
    await tester.pump();
    await tester.tap(find.text('Got it'));
    await _settle(tester);
    await tester.pump();
    expect(find.text('What is a group?'), findsOneWidget);
  });

  testWidgets('after everything is known, Go through all cards brings them back',
      (tester) async {
    await tester.runAsync(() => CardStore(db).save('L', [_group, _ring]));
    await _pump(tester, db);

    for (var i = 0; i < 2; i++) {
      await tester.tap(find.byKey(const Key('card')));
      await tester.pump();
      await tester.tap(find.text('Got it'));
      await _settle(tester);
      await tester.pump();
    }
    expect(find.text('All caught up'), findsOneWidget);
    expect(find.text('2 cards. The next one is due tomorrow.'), findsOneWidget);

    await tester.tap(find.text('Go through all cards now'));
    await tester.pump();
    expect(find.text('What is a group?'), findsOneWidget);
    expect(find.text('All caught up'), findsNothing);
  });
}
