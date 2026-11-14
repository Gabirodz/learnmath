import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../ai/openrouter_client.dart';
import '../core/models.dart';
import '../tts/tts_engine.dart';
import '../tts/wav.dart';

/// The lines around the playhead that the listener wants explained again.
class ReexplainContext {
  const ReexplainContext({required this.section, required this.passages});

  /// The current segment plus up to three before it, oldest first.
  factory ReexplainContext.fromSegments(
    List<NarrationSegment> segments,
    int index, {
    String? section,
  }) {
    final i = index.clamp(0, segments.length - 1);
    final from = i - 3 < 0 ? 0 : i - 3;
    return ReexplainContext(
      section: section,
      passages: segments.sublist(from, i + 1),
    );
  }

  final String? section;
  final List<NarrationSegment> passages;
}

/// Prompt for the "say that again differently" request. The spoken-style
/// rules restate the ones for SAY lines in `Prompts.narrationSystem`, since
/// the answer goes through the same text-to-speech engine.
class ReexplainPrompt {
  static const String system = '''
You are a gifted mathematics lecturer. A student is listening to your recorded lecture, probably without looking at a screen, and did not quite get the point you just made. You are given the last few lines of the lecture. Explain the point of the LAST line again, differently.

Rules:
- Take another angle than the original: a concrete example, an analogy, or the idea behind it. Do not just repeat or paraphrase the same sentences.
- Write 3 to 5 short sentences, for the ear: simple structure, no long asides.
- Your answer is spoken by a text-to-speech engine: NO LaTeX, NO symbols, NO digits-and-operators, no markdown, no lists, no parentheses for asides, no abbreviations. Spell all math out the way a lecturer says it: "the integral from zero to one of f of x, d x", "x sub n", "epsilon", "for all x in A", "A is a subset of B", "the limit as n goes to infinity", "x squared plus y squared equals one". Say Greek letters by name.
- Plain text only. No greeting, no "as I said", no commentary about the task. Start explaining right away.''';

  static String user(ReexplainContext c) {
    final b = StringBuffer();
    if (c.section != null) b.writeln('Section of the lecture: ${c.section}');
    b.write('The lecture, shortly before and at the point to explain again:');
    for (var i = 0; i < c.passages.length; i++) {
      final p = c.passages[i];
      final last = i == c.passages.length - 1;
      b.writeln();
      b.writeln();
      b.writeln(last ? 'Last line (explain this one):' : 'Earlier line:');
      b.write('Spoken: ${p.say.trim()}');
      if (p.subtitle.trim() != p.say.trim()) {
        b.write('\nWritten on screen: ${p.subtitle.trim()}');
      }
    }
    b.write(
      '\n\nNow explain the last line again in a different way, '
      '3 to 5 short spoken sentences, plain text.',
    );
    return b.toString();
  }
}

/// Strips what text-to-speech would read badly: code fences, markdown marks,
/// dollar signs and a leading "SAY:".
String cleanReexplanation(String raw) {
  final t = raw
      .replaceAll(RegExp(r'```[a-zA-Z]*'), '')
      .replaceAll(RegExp(r'^\s*SAY:\s*', multiLine: true), '')
      .replaceAll(RegExp(r'^\s*[#>*\-]+\s+', multiLine: true), '')
      .replaceAll(RegExp(r'[*`$]'), '');
  return t.replaceAll(RegExp(r'\s+'), ' ').trim();
}

/// Splits spoken text after sentence ends, so each sentence can be
/// synthesized on its own like the lecture's segments are.
List<String> splitSentences(String text) => [
  for (final s in text.split(RegExp(r'(?<=[.!?])\s+')))
    if (s.trim().isNotEmpty) s.trim(),
];

/// Synthesizes [text] sentence by sentence into a WAV at [outPath], with
/// [gapMs] of silence between sentences. Returns [outPath].
Future<String> synthesizeToWav({
  required TtsEngine engine,
  required String text,
  required String outPath,
  int gapMs = 250,
}) async {
  final sentences = splitSentences(text);
  if (sentences.isEmpty) throw TtsException('There was nothing to say.');
  await engine.prepare();
  // The first call comes before opening the file: a cloud voice's sample
  // rate is only known after its first response.
  final first = await engine.synthesize(sentences.first);
  final wav = await WavWriter.open(outPath, engine.sampleRate);
  try {
    await wav.writeSamples(trimSilence(first, wav.sampleRate));
    for (final sentence in sentences.skip(1)) {
      await wav.writeSilence(gapMs);
      final pcm = await engine.synthesize(sentence);
      await wav.writeSamples(trimSilence(pcm, wav.sampleRate));
    }
  } finally {
    await wav.close();
  }
  return outPath;
}

sealed class ReexplainState {
  const ReexplainState();
}

class ReexplainIdle extends ReexplainState {
  const ReexplainIdle();
}

/// Asking the model or synthesizing its answer.
class ReexplainThinking extends ReexplainState {
  const ReexplainThinking();
}

class ReexplainSpeaking extends ReexplainState {
  const ReexplainSpeaking(this.text);
  final String text;
}

class ReexplainError extends ReexplainState {
  const ReexplainError(this.message);
  final String message;
}

typedef AskModel = Future<String> Function(ReexplainContext context);

/// Writes the text as speech to a WAV file and returns its path.
typedef SynthesizeToFile = Future<String> Function(String text);

/// Completes when the clip at the path has been played to its end (or was cut
/// short by the stop function).
typedef PlayClip = Future<void> Function(String path);

String describeReexplainError(Object e) => switch (e) {
  OpenRouterException() => e.message,
  TtsException() => e.message,
  SocketException() => 'No internet connection. Check it and try again.',
  _ => 'Could not explain it another way. ($e)',
};

/// "Say that again differently": pauses the lecture, asks the model for
/// another explanation, speaks it, and resumes the lecture at the start of the
/// segment that was playing. The collaborators are injected so the sequence
/// can be tested without audio or network.
class ReexplainController {
  ReexplainController({
    required this.pauseLecture,
    required this.askModel,
    required this.synthesize,
    required this.playClip,
    required this.stopClip,
    required this.resumeLecture,
    Future<void> Function(String path)? deleteFile,
  }) : _deleteFile = deleteFile ?? _deleteQuietly;

  final Future<void> Function() pauseLecture;
  final AskModel askModel;
  final SynthesizeToFile synthesize;
  final PlayClip playClip;

  /// Cuts a playing clip short, leaving the lecture paused.
  final Future<void> Function() stopClip;

  /// Plays the lecture from the start of the given segment (also ending a
  /// clip that is still playing).
  final Future<void> Function(int segmentIndex) resumeLecture;
  final Future<void> Function(String path) _deleteFile;

  final ValueNotifier<ReexplainState> state = ValueNotifier(
    const ReexplainIdle(),
  );

  int _run = 0;
  int _segment = 0;
  String? _file;

  bool get busy =>
      state.value is ReexplainThinking || state.value is ReexplainSpeaking;

  /// Starts an explanation of [segmentIndex]. While busy, a second call
  /// cancels (while thinking) or returns to the lecture (while speaking).
  Future<void> start(
    ReexplainContext context, {
    required int segmentIndex,
  }) async {
    final s = state.value;
    if (s is ReexplainThinking) return cancel();
    if (s is ReexplainSpeaking) return backToLecture();

    final run = ++_run;
    _segment = segmentIndex;
    state.value = const ReexplainThinking();
    try {
      await pauseLecture();
      if (run != _run) return;
      final text = cleanReexplanation(await askModel(context));
      if (run != _run) return;
      if (text.isEmpty) {
        throw TtsException(
          'The model did not give an explanation. Please try again.',
        );
      }
      final path = await synthesize(text);
      if (run != _run) {
        await _deleteFile(path);
        return;
      }
      _file = path;
      state.value = ReexplainSpeaking(text);
      await playClip(path);
      if (run != _run) return;
    } catch (e) {
      if (run != _run) return;
      await _discardFile();
      try {
        await stopClip();
      } catch (_) {}
      if (run != _run) return;
      state.value = ReexplainError(describeReexplainError(e));
      return;
    }
    await _discardFile();
    state.value = const ReexplainIdle();
    await resumeLecture(_segment);
  }

  /// Gives up without resuming: the lecture stays paused.
  Future<void> cancel() async {
    final wasSpeaking = state.value is ReexplainSpeaking;
    _run++;
    state.value = const ReexplainIdle();
    if (wasSpeaking) {
      try {
        await stopClip();
      } catch (_) {}
    }
    await _discardFile();
  }

  /// Stops the clip and continues the lecture from the start of the segment.
  Future<void> backToLecture() async {
    if (state.value is! ReexplainSpeaking) return;
    _run++;
    state.value = const ReexplainIdle();
    await _discardFile();
    await resumeLecture(_segment);
  }

  void dismissError() {
    if (state.value is ReexplainError) state.value = const ReexplainIdle();
  }

  Future<void> dispose() async {
    await cancel();
    state.dispose();
  }

  Future<void> _discardFile() async {
    final f = _file;
    _file = null;
    if (f != null) await _deleteFile(f);
  }

  static Future<void> _deleteQuietly(String path) async {
    try {
      await File(path).delete();
    } catch (_) {}
  }
}
