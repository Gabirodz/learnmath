import 'dart:typed_data';

import '../core/models.dart';
import '../platform/files.dart';
import 'tts_engine.dart';
import 'wav.dart';

class LectureAudio {
  const LectureAudio({required this.segments, required this.durationMs});

  /// The input segments with [NarrationSegment.startMs]/[endMs] filled in.
  final List<NarrationSegment> segments;
  final int durationMs;
}

class GenerationCancelled implements Exception {
  const GenerationCancelled();
  @override
  String toString() => 'Cancelled';
}

/// Turns a narration script into one audio file with lecture pacing:
/// each segment is synthesized on its own, engine padding is trimmed, and the
/// scripted silence (scaled by the user's preference) is inserted after it.
/// Because we lay the file out ourselves, subtitle timings are exact.
class LectureAudioBuilder {
  /// Silence before the first word and after the last.
  static const _leadInMs = 500;
  static const _leadOutMs = 800;

  /// Extra breathing room before a new section starts.
  static const _sectionGapMs = 900;

  /// Floor for the gap between segments so sentences never run together.
  static const _minGapMs = 180;

  static Future<LectureAudio> build({
    required List<NarrationSegment> segments,
    required TtsEngine engine,
    required String outPath,
    double pauseScale = 1.0,
    void Function(int done, int total)? onProgress,
    bool Function()? isCancelled,
  }) async {
    await engine.prepare();
    final tmpPath = '$outPath.part';
    WavWriter? wav;
    final timed = <NarrationSegment>[];
    try {
      final batch = engine.maxConcurrency.clamp(1, 8);
      for (var i = 0; i < segments.length; i += batch) {
        if (isCancelled?.call() ?? false) throw const GenerationCancelled();
        final chunk = segments.skip(i).take(batch).toList();
        final audio = await Future.wait<Int16List>(
            [for (final s in chunk) _synthesize(engine, s.say)]);
        // Engines only know their sample rate after the first synthesis.
        if (wav == null) {
          wav = await WavWriter.open(tmpPath, engine.sampleRate);
          await wav.writeSilence(_leadInMs);
        }
        for (var k = 0; k < chunk.length; k++) {
          final seg = chunk[k];
          if (seg.section != null && timed.isNotEmpty) {
            await wav.writeSilence((_sectionGapMs * pauseScale).round());
          }
          final start = wav.positionMs;
          await wav.writeSamples(trimSilence(audio[k], wav.sampleRate));
          final end = wav.positionMs;
          timed.add(seg.copyWith(startMs: start, endMs: end));
          final gap = (seg.pauseMs * pauseScale).round();
          await wav.writeSilence(gap < _minGapMs ? _minGapMs : gap);
        }
        onProgress?.call(timed.length, segments.length);
      }
      if (wav == null) throw TtsException('The narration script is empty.');
      await wav.writeSilence(_leadOutMs);
      final durationMs = wav.positionMs;
      await wav.close();
      wav = null;
      await moveFile(tmpPath, outPath);
      return LectureAudio(segments: timed, durationMs: durationMs);
    } catch (_) {
      try {
        await wav?.abandon();
        await deleteFile(tmpPath);
      } catch (_) {}
      rethrow;
    }
  }

  static Future<Int16List> _synthesize(TtsEngine engine, String say) async {
    final text = _speakable(say);
    if (!text.contains(RegExp(r'[A-Za-z0-9]'))) return Int16List(0);
    return engine.synthesize(text);
  }

  /// Last-line defence against stray markup reaching the TTS engine.
  static String _speakable(String s) => s
      .replaceAll(RegExp(r'[\$\*_`#\\]'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
}
