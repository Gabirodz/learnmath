import 'dart:typed_data';

import '../ai/openrouter_client.dart';

/// A text-to-speech backend producing 16-bit mono PCM.
abstract class TtsEngine {
  /// Valid after [prepare].
  int get sampleRate;

  /// How many [synthesize] calls may run at once.
  int get maxConcurrency;

  Future<void> prepare();

  Future<Int16List> synthesize(String text);

  Future<void> dispose();
}

class TtsException implements Exception {
  TtsException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Cloud TTS through OpenRouter's `/audio/speech` endpoint.
///
/// Requests raw 16-bit mono PCM. The sample rate differs between providers
/// (24 kHz, 44.1 kHz, ...) and is read from each response.
class OpenRouterTtsEngine implements TtsEngine {
  OpenRouterTtsEngine({
    required this.client,
    required this.model,
    required this.voice,
  });

  final OpenRouterClient client;
  final String model;
  final String voice;

  static const _instructions =
      'You are a university mathematics lecturer. Speak clearly and calmly, '
      'at a measured teaching pace, with natural emphasis on key terms.';

  int _sampleRate = 24000;

  @override
  int get sampleRate => _sampleRate;

  @override
  int get maxConcurrency => 4;

  @override
  Future<void> prepare() async {}

  @override
  Future<Int16List> synthesize(String text) async {
    Object? lastError;
    for (var attempt = 0; attempt < 3; attempt++) {
      try {
        final audio = await client.speechPcm(
          model: model,
          input: text,
          voice: voice,
          instructions: _instructions,
        );
        _sampleRate = audio.sampleRate;
        final bytes = audio.bytes;
        final even = bytes.length & ~1;
        // Copy: the response buffer may not be 2-byte aligned.
        final copy = Uint8List.fromList(Uint8List.sublistView(bytes, 0, even));
        return copy.buffer.asInt16List();
      } on OpenRouterException catch (e) {
        lastError = e;
        final code = e.statusCode;
        final retryable = code == null || code == 429 || code >= 500;
        if (!retryable) break;
        await Future<void>.delayed(Duration(seconds: 1 << attempt));
      }
    }
    throw TtsException('Speech synthesis failed: $lastError');
  }

  @override
  Future<void> dispose() async {}
}
