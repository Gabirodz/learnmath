// Integration test for on-device speech. Needs an extracted voice model:
//   KOKORO_MODELS_DIR=<dir containing the model's folder, e.g.
//     kokoro-int8-en-v0_19/> VOICE_MODEL=<kokoro|kitten-nano|piper-ljspeech> \
//   LD_LIBRARY_PATH=~/.pub-cache/hosted/pub.dev/sherpa_onnx_linux-<ver>/linux/x64 \
//   flutter test test/tts
@TestOn('vm')
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:learnmath/core/models.dart';
import 'package:learnmath/tts/lecture_audio_builder.dart';
import 'package:learnmath/tts/on_device_tts.dart';

void main() {
  final modelsDir = Platform.environment['KOKORO_MODELS_DIR'];
  final modelId = Platform.environment['VOICE_MODEL'] ?? 'kokoro';

  test('$modelId synthesizes a paced lecture with exact timings', () async {
    final out = '${Directory.systemTemp.createTempSync().path}/lecture.wav';
    final engine = OnDeviceTtsEngine(
        manager: VoiceModelManager(modelsDir!),
        model: VoiceModel.byId(modelId),
        speakerId: 5);
    const script = [
      NarrationSegment(
          say: 'Let us start with a question.', section: 'Intro', pauseMs: 3000),
      NarrationSegment(say: 'When is a set compact?'),
      NarrationSegment(say: r'$$ \\ **', show: 'markup only'),
      NarrationSegment(
          say: 'Epsilon is greater than zero.', section: 'Proof', pauseMs: 1000),
    ];
    final progress = <int>[];
    final audio = await LectureAudioBuilder.build(
      segments: script,
      engine: engine,
      outPath: out,
      pauseScale: 1.5,
      onProgress: (done, _) => progress.add(done),
    );
    await engine.dispose();

    expect(progress, [1, 2, 3, 4]);
    final s = audio.segments;
    expect(s[0].startMs, 500);
    expect(s[0].endMs! - s[0].startMs!, inInclusiveRange(800, 4000));
    // 3 s scripted pause x 1.5 scale.
    expect(s[1].startMs! - s[0].endMs!, closeTo(4500, 2));
    // Unspeakable segment takes no time; section gap + minimum gaps follow.
    expect(s[2].endMs, s[2].startMs);
    final bytes = File(out).lengthSync();
    expect(bytes, closeTo(44 + audio.durationMs * engine.sampleRate * 2 / 1000, 100),
        reason: 'WAV length matches reported duration');
    // ignore: avoid_print
    print('duration ${audio.durationMs} ms, ${engine.sampleRate} Hz, $out');
  }, skip: modelsDir == null ? 'KOKORO_MODELS_DIR not set' : false,
      timeout: const Timeout(Duration(minutes: 5)));
}
