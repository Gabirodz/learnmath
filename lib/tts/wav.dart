import 'dart:typed_data';

import '../platform/files.dart';

/// Incrementally writes a 16-bit mono PCM WAV file so a long lecture never has
/// to be held in memory (in a browser it is, until it is stored as a blob).
class WavWriter {
  WavWriter._(this._file, this.sampleRate);

  final ByteSink _file;
  final int sampleRate;
  int _samples = 0;

  static Future<WavWriter> open(String path, int sampleRate) async =>
      WavWriter._(await openByteSink(path, headerLength: 44), sampleRate);

  int get samplesWritten => _samples;

  /// Current end-of-file position in milliseconds.
  int get positionMs => (_samples * 1000 / sampleRate).round();

  Future<void> writeSamples(Int16List pcm) async {
    if (pcm.isEmpty) return;
    await _file
        .add(pcm.buffer.asUint8List(pcm.offsetInBytes, pcm.lengthInBytes));
    _samples += pcm.length;
  }

  Future<void> writeSilence(int ms) async {
    if (ms <= 0) return;
    await writeSamples(Int16List((sampleRate * ms / 1000).round()));
  }

  Future<void> close() async {
    final dataBytes = _samples * 2;
    final h = ByteData(44);
    void tag(int offset, String s) {
      for (var i = 0; i < 4; i++) {
        h.setUint8(offset + i, s.codeUnitAt(i));
      }
    }

    tag(0, 'RIFF');
    h.setUint32(4, 36 + dataBytes, Endian.little);
    tag(8, 'WAVE');
    tag(12, 'fmt ');
    h.setUint32(16, 16, Endian.little); // fmt chunk size
    h.setUint16(20, 1, Endian.little); // PCM
    h.setUint16(22, 1, Endian.little); // mono
    h.setUint32(24, sampleRate, Endian.little);
    h.setUint32(28, sampleRate * 2, Endian.little); // byte rate
    h.setUint16(32, 2, Endian.little); // block align
    h.setUint16(34, 16, Endian.little); // bits per sample
    tag(36, 'data');
    h.setUint32(40, dataBytes, Endian.little);
    await _file.finish(h.buffer.asUint8List());
  }

  /// Closes the file unfinished, after a failure.
  Future<void> abandon() => _file.abandon();
}

Int16List floatToPcm16(Float32List samples) {
  final out = Int16List(samples.length);
  for (var i = 0; i < samples.length; i++) {
    final v = (samples[i] * 32767.0).round();
    out[i] = v > 32767 ? 32767 : (v < -32768 ? -32768 : v);
  }
  return out;
}

/// Removes leading/trailing near-silence so that pauses between segments are
/// exactly what the script asked for, whatever padding the engine adds.
/// Keeps [keepMs] of padding on each side to avoid clipping consonants.
Int16List trimSilence(Int16List pcm, int sampleRate,
    {int threshold = 250, int keepMs = 40}) {
  var start = 0;
  var end = pcm.length;
  while (start < end && pcm[start].abs() < threshold) {
    start++;
  }
  while (end > start && pcm[end - 1].abs() < threshold) {
    end--;
  }
  if (start >= end) return Int16List(0);
  final keep = sampleRate * keepMs ~/ 1000;
  start = start - keep < 0 ? 0 : start - keep;
  end = end + keep > pcm.length ? pcm.length : end + keep;
  return Int16List.sublistView(pcm, start, end);
}
