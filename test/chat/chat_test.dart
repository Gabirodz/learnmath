import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:learnmath/chat/chat_controller.dart';
import 'package:learnmath/chat/chat_models.dart';
import 'package:learnmath/chat/chat_pane.dart';
import 'package:learnmath/chat/chat_prompts.dart';
import 'package:learnmath/chat/chat_store.dart';
import 'package:learnmath/core/models.dart';
import 'package:learnmath/core/providers.dart';
import 'package:learnmath/notes/notes_view.dart';
import 'package:sembast/sembast_memory.dart';

Lesson lesson({String? notes = '# Compactness\n\n**Theorem 2.** Every closed set is compact.'}) =>
    Lesson(
      id: 'l1',
      title: 'Compactness',
      brief: 'b',
      createdAt: DateTime(2026),
      notesMarkdown: notes,
    );

ChatTurn turn(bool user, String text, {String? quote}) =>
    ChatTurn(fromUser: user, text: text, quote: quote, createdAt: DateTime(2026));

class _Settings extends SettingsNotifier {
  @override
  AppSettings build() => const AppSettings();
}

void main() {
  group('prompts', () {
    test('system includes title and notes verbatim', () {
      final m = buildChatMessages(lesson: lesson(), history: [turn(true, 'hi')]);
      expect(m.first.role, 'system');
      expect(m.first.content, contains('Compactness'));
      expect(m.first.content, contains('**Theorem 2.** Every closed set is compact.'));
      expect(m.first.content, contains('=== BEGIN LESSON NOTES ==='));
      expect(m.first.content, contains('=== END LESSON NOTES ==='));
      expect(m.first.content, contains(r'$$'));
    });

    test('quote is rendered as blockquote before the question', () {
      final m = buildChatMessages(
          lesson: lesson(),
          history: [turn(true, 'Why?', quote: 'line one\nline two')]);
      final c = m.last.content;
      expect(c, contains('> line one\n> line two'));
      expect(c.indexOf('> line one'), lessThan(c.indexOf('Why?')));
    });

    test('history is capped at 40 turns, starting on a user turn', () {
      final h = [
        for (var i = 0; i < 60; i++) turn(i.isEven, 'm$i'),
      ];
      final m = buildChatMessages(lesson: lesson(), history: h);
      expect(m.length - 1, lessThanOrEqualTo(40));
      expect(m.last.content, 'm59');
      expect(m[1].role, 'user');
      expect(buildChatMessages(lesson: lesson(), history: h.sublist(0, 10)).length, 11);
    });
  });

  test('ChatStore round-trip', () async {
    final db = await databaseFactoryMemory.openDatabase('t1');
    final s = ChatStore(db);
    expect(await s.load('l1'), isEmpty);
    await s.save('l1', [turn(true, 'q', quote: 'x'), turn(false, 'a')]);
    final back = await s.load('l1');
    expect(back.length, 2);
    expect(back[0].quote, 'x');
    expect(back[0].fromUser, isTrue);
    expect(back[1].text, 'a');
    expect(back[1].quote, isNull);
    await s.clear('l1');
    expect(await s.load('l1'), isEmpty);
    await db.close();
  });

  group('splitSourceBlocks', () {
    test('splits on blank lines, keeps display math and fences', () {
      const md = 'Para one.\n\nPara two\n\n\$\$\na\n\nb\n\$\$\n\n```\nx\n\ny\n```\n\nEnd';
      final b = splitSourceBlocks(md);
      expect(b, [
        'Para one.',
        'Para two',
        '\$\$\na\n\nb\n\$\$',
        '```\nx\n\ny\n```',
        'End',
      ]);
    });

    test('keeps lists together and statement with its display', () {
      const md = '- a\n\n- b\n- c\n\nAfter\n\n**Theorem 1.** Then\n\n\$\$x=1\$\$\n\nNext';
      final b = splitSourceBlocks(md);
      expect(b[0], '- a\n\n- b\n- c');
      expect(b[1], 'After');
      expect(b[2], contains('**Theorem 1.**'));
      expect(b[2], contains('\$\$x=1\$\$'));
      expect(b[3], 'Next');
    });

    test('drops page markers', () {
      expect(splitSourceBlocks('[[page 3]]\nHello\n\n[[page 4]]\n\nBye'),
          ['Hello', 'Bye']);
    });
  });

  group('widgets', () {
    late Database db;
    setUp(() async => db = await newDatabaseFactoryMemory().openDatabase('w'));

    Future<ProviderContainer> pumpPane(WidgetTester tester, Lesson l,
        {double scale = 1.0}) async {
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final container = ProviderContainer(overrides: [
        databaseProvider.overrideWithValue(db),
        settingsProvider.overrideWith(_Settings.new),
        lessonProvider.overrideWith((ref, id) => Stream.value(l)),
      ]);
      addTearDown(container.dispose);
      await tester.pumpWidget(UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: ThemeData(colorSchemeSeed: Colors.indigo),
          builder: (c, child) => MediaQuery(
            data: MediaQuery.of(c).copyWith(textScaler: TextScaler.linear(scale)),
            child: child!,
          ),
          home: Scaffold(body: ChatPane(lessonId: 'l1')),
        ),
      ));
      await tester.pumpAndSettle();
      return container;
    }

    testWidgets('empty state and pending quote at 320px', (tester) async {
      final c = await pumpPane(tester, lesson(), scale: 1.6);
      expect(tester.takeException(), isNull);
      expect(find.text('Summarise the key ideas'), findsOneWidget);
      expect(find.text('Ask about this lesson…'), findsOneWidget);
      expect(find.text('Asking about:'), findsNothing);

      c.read(chatQuoteProvider('l1').notifier).set('A \$x\$ quote');
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.text('Asking about:'), findsOneWidget);
      expect(find.text('Explain this'), findsOneWidget);
      expect(find.byTooltip('Remove quote'), findsOneWidget);
      // Send is enabled with an empty field while a quote is pending.
      final send = tester.widget<IconButton>(find.ancestor(of: find.byIcon(Icons.arrow_upward), matching: find.byType(IconButton)));
      expect(send.onPressed, isNotNull);

      await tester.tap(find.byTooltip('Remove quote'));
      await tester.pumpAndSettle();
      expect(find.text('Asking about:'), findsNothing);
    });

    testWidgets('no notes shows placeholder', (tester) async {
      await pumpPane(tester, lesson(notes: null));
      expect(find.byType(TextField), findsNothing);
    });

    testWidgets('sending without API key shows error and keeps user turn',
        (tester) async {
      final c = await pumpPane(tester, lesson());
      await tester.tap(find.text('Quiz me on this lesson'));
      // Let the real (non fake-async) database writes finish.
      await tester.runAsync(() => Future.delayed(const Duration(milliseconds: 200)));
      await tester.pumpAndSettle();
      expect(find.text('Add your OpenRouter API key in Settings first.'),
          findsOneWidget);
      expect(find.text('Retry'), findsOneWidget);
      expect(c.read(chatControllerProvider('l1')).turns.length, 1);
      expect(await tester.runAsync(() => ChatStore(db).load('l1')), hasLength(1));
    });
  });

  testWidgets('NotesView onAskAbout: long press menu, markers hidden',
      (tester) async {
    String? asked;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: NotesView(
          markdown: '[[page 9]]\n\nFirst block\n\nSecond block',
          onAskAbout: (s) => asked = s,
        ),
      ),
    ));
    expect(find.textContaining('[[page'), findsNothing);
    await tester.longPress(find.text('Second block'));
    await tester.pumpAndSettle();
    expect(find.text('Copy'), findsOneWidget);
    await tester.tap(find.text('Ask about this'));
    await tester.pumpAndSettle();
    expect(asked, 'Second block');
  });
}
