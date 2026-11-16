@TestOn('vm')
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:learnmath/tts/on_device_tts.dart';
import 'package:path/path.dart' as p;

void main() {
  test('the retired Lessac id opens its replacement, not the default', () {
    expect(VoiceModel.byId('piper-lessac').id, 'piper-ljspeech');
    expect(VoiceModel.byId('unknown').id, voiceModels.first.id);
  });

  test('no offered voice is the research-only Lessac one', () {
    for (final m in voiceModels) {
      expect(m.archive.toLowerCase(), isNot(contains('lessac')));
    }
  });

  test('removeRetired deletes Lessac files and keeps the others', () async {
    final dir = Directory.systemTemp.createTempSync();
    addTearDown(() => dir.delete(recursive: true));
    final lessac = Directory(p.join(dir.path, 'vits-piper-en_US-lessac-medium'))
      ..createSync();
    File(p.join(lessac.path, 'en_US-lessac-medium.onnx')).writeAsStringSync('x');
    final lj = Directory(p.join(dir.path, voiceModels.last.archive))
      ..createSync();

    final manager = VoiceModelManager(dir.path);
    await manager.removeRetired();
    await manager.removeRetired(); // nothing left: no error

    expect(lessac.existsSync(), isFalse);
    expect(lj.existsSync(), isTrue);
  });
}
