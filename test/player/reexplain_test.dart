import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:learnmath/ai/openrouter_client.dart';
import 'package:learnmath/core/models.dart';
import 'package:learnmath/player/reexplain.dart';

const segs = [
  NarrationSegment(say: 'zero zero'),
  NarrationSegment(say: 'one one'),
  NarrationSegment(say: 'two two'),
  NarrationSegment(say: 'three three', show: r'$3$ shown'),
  NarrationSegment(say: 'four four'),
];

class Fixture {
  final log = <String>[];
  ReexplainContext? asked;
  Completer<String> answer = Completer();
  Completer<void> clip = Completer();
  late final ReexplainController c = ReexplainController(
    pauseLecture: () async => log.add('pause'),
    askModel: (ctx) {
      log.add('ask');
      asked = ctx;
      return answer.future;
    },
    synthesize: (t) async {
      log.add('synth:$t');
      return '/tmp/x.wav';
    },
    playClip: (p) {
      log.add('play');
      return clip.future;
    },
    stopClip: () async => log.add('stopClip'),
    resumeLecture: (i) async => log.add('resume:$i'),
    deleteFile: (p) async => log.add('delete'),
  );
  ReexplainContext ctx() =>
      ReexplainContext.fromSegments(segs, 4, section: 'Compactness');
}

void main() {
  test(
    'happy path: pause, ask, synthesize, play, resume at segment start',
    () async {
      final f = Fixture();
      final run = f.c.start(f.ctx(), segmentIndex: 4);
      await pumpEventQueue();
      expect(f.c.state.value, isA<ReexplainThinking>());
      f.answer.complete('Think of **a ball**. It is round.');
      await pumpEventQueue();
      expect(f.c.state.value, isA<ReexplainSpeaking>());
      expect(
        (f.c.state.value as ReexplainSpeaking).text,
        'Think of a ball. It is round.',
      );
      f.clip.complete();
      await run;
      expect(f.log, [
        'pause',
        'ask',
        'synth:Think of a ball. It is round.',
        'play',
        'delete',
        'resume:4',
      ]);
      expect(f.c.state.value, isA<ReexplainIdle>());
    },
  );

  test('cancel while thinking neither plays nor resumes', () async {
    final f = Fixture();
    final run = f.c.start(f.ctx(), segmentIndex: 4);
    await pumpEventQueue();
    await f.c.start(f.ctx(), segmentIndex: 4); // second tap cancels
    expect(f.c.state.value, isA<ReexplainIdle>());
    f.answer.complete('Late answer.');
    await run;
    expect(f.log, ['pause', 'ask']);
  });

  test('model error shows a message and leaves the lecture paused', () async {
    final f = Fixture();
    final run = f.c.start(f.ctx(), segmentIndex: 4);
    await pumpEventQueue();
    f.answer.completeError(OpenRouterException('No credits left.'));
    await run;
    final s = f.c.state.value;
    expect(s, isA<ReexplainError>());
    expect((s as ReexplainError).message, 'No credits left.');
    expect(f.log.any((e) => e.startsWith('resume')), isFalse);
    expect(f.log.contains('play'), isFalse);
  });

  test('back to the lecture while speaking resumes at the segment', () async {
    final f = Fixture();
    final run = f.c.start(f.ctx(), segmentIndex: 4);
    await pumpEventQueue();
    f.answer.complete('Another way.');
    await pumpEventQueue();
    await f.c.backToLecture();
    f.clip.complete();
    await run;
    expect(f.log.where((e) => e.startsWith('resume')), ['resume:4']);
    expect(f.c.state.value, isA<ReexplainIdle>());
  });

  test('context holds current and up to three preceding segments', () {
    final c = ReexplainContext.fromSegments(segs, 4, section: 'S');
    expect(c.passages.map((p) => p.say), [
      'one one',
      'two two',
      'three three',
      'four four',
    ]);
    expect(c.section, 'S');
    expect(ReexplainContext.fromSegments(segs, 1).passages.length, 2);
  });

  test('context reaches the model', () async {
    final f = Fixture();
    final run = f.c.start(f.ctx(), segmentIndex: 4);
    await pumpEventQueue();
    expect(f.asked!.section, 'Compactness');
    expect(f.asked!.passages.last.say, 'four four');
    expect(f.asked!.passages.first.say, 'one one');
    await f.c.cancel();
    f.answer.complete('x');
    await run;
  });

  test('prompt contains the segment text, section and spoken-style rules', () {
    final u = ReexplainPrompt.user(
      ReexplainContext.fromSegments(segs, 3, section: 'Compactness'),
    );
    expect(u, contains('three three'));
    expect(u, contains(r'$3$ shown'));
    expect(u, contains('two two'));
    expect(u, contains('Compactness'));
    expect(ReexplainPrompt.system, contains('NO LaTeX'));
  });

  test('splitSentences and cleanReexplanation', () {
    expect(splitSentences('One. Two! Three? Four'), [
      'One.',
      'Two!',
      'Three?',
      'Four',
    ]);
    expect(cleanReexplanation('```\nSAY: Hi \$x\$.\n```'), 'Hi x.');
  });
}
