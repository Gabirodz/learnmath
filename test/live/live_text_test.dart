// Live checks against OpenRouter (cost a fraction of a cent). Skipped unless
// OPENROUTER_API_KEY is set. Optional: LIVE_MODEL, LIVE_OUT (output folder).
@TestOn('vm')
@Timeout(Duration(minutes: 8))
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:learnmath/ai/lesson_generator.dart';
import 'package:learnmath/ai/openrouter_client.dart';
import 'package:learnmath/chat/chat_models.dart';
import 'package:learnmath/chat/chat_prompts.dart';
import 'package:learnmath/core/models.dart';

void main() {
  final key = Platform.environment['OPENROUTER_API_KEY'];
  final model = Platform.environment['LIVE_MODEL'] ?? AppSettings.defaultChatModel;
  final out = Platform.environment['LIVE_OUT'];
  void save(String name, String text) {
    if (out != null) File('$out/$name').writeAsStringSync(text);
  }

  group('live', () {
    late OpenRouterClient client;
    late LessonGenerator gen;
    var notes = '';
    setUpAll(() {
      client = OpenRouterClient(apiKey: key!);
      gen = LessonGenerator(client, model: model);
    });
    tearDownAll(() => client.close());

    test('course outline', () async {
      final o = await gen.generateOutline('Point-set topology', lessonCount: 4);
      save('outline.txt',
          '${o.title}\n${o.description}\n${o.lessons.map((l) => '- ${l.title}: ${l.brief}').join('\n')}');
      expect(o.lessons, hasLength(4));
    });

    test('lecture notes', () async {
      final raw = await gen.ask(
        LessonGenerator.notesMessages(
          title: 'The Banach fixed-point theorem',
          brief: 'Contractions on complete metric spaces, statement and '
              'proof, one application.',
          withChecks: true,
        ),
        temperature: LessonGenerator.notesTemperature,
      );
      final draft = LessonGenerator.parseNotes(raw);
      notes = draft.notes;
      save('notes.md', notes);
      save('checks.txt',
          draft.checks.map((c) => 'CHECK: ${c.title}\n${c.code}').join('\n'));
      expect(draft.checks, isNotEmpty, reason: 'at least one parsed check');
      expect(notes, isNot(contains('<<<CHECKS')));
      expect(notes, startsWith('# '));
      expect(notes, contains(r'$'));
      expect(notes.contains(r'\(') || notes.contains(r'\['), isFalse);
      expect(notes.split(RegExp(r'\s+')).length, greaterThan(500));
    });

    test('narration script', () async {
      final rawScript = await gen.ask(
        LessonGenerator.narrationMessages(
            title: 'The Banach fixed-point theorem', notesMarkdown: notes),
        temperature: LessonGenerator.narrationTemperature,
      );
      final segs = LessonGenerator.parseScript(rawScript);
      save(
          'narration.txt',
          segs
              .map((s) =>
                  '${s.section == null ? '' : '== ${s.section} ==\n'}SAY: ${s.say}\n${s.show == null ? '' : 'SHOW: ${s.show}\n'}PAUSE: ${s.pauseMs}')
              .join('\n'));
      final words = segs.fold<int>(0, (n, s) => n + s.say.split(' ').length);
      // ignore: avoid_print
      print('segments ${segs.length}, words $words, '
          'sections ${segs.where((s) => s.section != null).length}, '
          'with SHOW ${segs.where((s) => s.show != null).length}, '
          'long pauses ${segs.where((s) => s.pauseMs >= 2000).length}');
      expect(segs.length, greaterThan(40));
      expect(words, greaterThan(900));
      expect(segs.where((s) => s.section != null).length, greaterThan(2));
      expect(segs.where((s) => s.pauseMs >= 2000), isNotEmpty);
      expect(segs.where((s) => s.say.contains(r'$') || s.say.contains(r'\')),
          isEmpty,
          reason: 'spoken text must be free of LaTeX');
    });

    test('tutor chat with a quoted passage', () async {
      final lesson = Lesson(
        id: 'x',
        title: 'The Banach fixed-point theorem',
        brief: '',
        createdAt: DateTime.now(),
        notesMarkdown: notes,
      );
      final quote = notes
          .split('\n\n')
          .firstWhere((b) => b.contains('**Theorem'), orElse: () => notes.split('\n\n')[2]);
      var deltas = 0;
      final answer = await client.chat(
        model: model,
        messages: buildChatMessages(lesson: lesson, history: [
          ChatTurn(
              fromUser: true,
              text: "I don't get why completeness is needed here.",
              quote: quote,
              createdAt: DateTime.now()),
        ]),
        onDelta: (_) => deltas++,
      );
      save('chat.md', '> $quote\n\n$answer');
      expect(deltas, greaterThan(3), reason: 'answer is streamed');
      expect(answer.toLowerCase(), contains('complete'));
    });
  }, skip: key == null ? 'OPENROUTER_API_KEY not set' : false);
}
