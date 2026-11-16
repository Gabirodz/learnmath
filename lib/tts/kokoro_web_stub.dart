import 'tts_engine.dart';

/// Only in a browser; see `kokoro_web_engine.dart`.
TtsEngine createKokoroWebEngine({
  required String voice,
  void Function(double? fraction)? onDownload,
}) =>
    throw UnsupportedError('The browser voice only runs in a browser.');
