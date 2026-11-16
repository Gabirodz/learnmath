import 'dart:js_interop';
import 'dart:typed_data';

import 'kokoro_voices.dart';
import 'tts_engine.dart';
import 'wav.dart';

// Defined in web/learnmath_web.js; the model runs in web/kokoro_worker.js.
@JS('learnmathKokoro.load')
external JSPromise<_Loaded> _load(JSFunction onProgress);
@JS('learnmathKokoro.generate')
external JSPromise<_Audio> _generate(String text, String voice, double speed);

extension type _Loaded(JSObject _) implements JSObject {
  external String get device;
}

extension type _Audio(JSObject _) implements JSObject {
  external JSFloat32Array get samples;
  external int get sampleRate;
}

/// The Kokoro voice, speaking as [voice] (see [kokoroVoices]). [onDownload]
/// hears how far the one-time download of the model is (null: unknown).
TtsEngine createKokoroWebEngine({
  required String voice,
  void Function(double? fraction)? onDownload,
}) =>
    _KokoroWebEngine(voice, onDownload);

/// Kokoro through kokoro-js: on the graphics card where the browser has
/// WebGPU, else on the processor (WebAssembly). The model is downloaded the
/// first time (about 330 MB with WebGPU, 90 MB without) and stays loaded for
/// the next lecture, so [dispose] does nothing.
class _KokoroWebEngine implements TtsEngine {
  _KokoroWebEngine(this._voice, this._onDownload);

  final String _voice;
  final void Function(double? fraction)? _onDownload;
  int _sampleRate = 24000;

  @override
  int get sampleRate => _sampleRate;

  @override
  int get maxConcurrency => 1;

  @override
  Future<void> prepare() async {
    void progress(JSNumber loaded, JSNumber total) {
      final t = total.toDartDouble;
      _onDownload?.call(t > 0 ? (loaded.toDartDouble / t).clamp(0, 1) : null);
    }

    try {
      await _load(progress.toJS).toDart;
    } catch (e) {
      throw TtsException('The voice could not be loaded: ${_message(e)}');
    }
  }

  @override
  Future<Int16List> synthesize(String text) async {
    final pieces = <Int16List>[];
    try {
      for (final piece in splitForKokoro(text)) {
        final audio = await _generate(piece, _voice, 1).toDart;
        _sampleRate = audio.sampleRate;
        pieces.add(floatToPcm16(audio.samples.toDart));
      }
    } catch (e) {
      throw TtsException('The voice failed: ${_message(e)}');
    }
    if (pieces.length == 1) return pieces.single;
    final out = Int16List(pieces.fold(0, (n, p) => n + p.length));
    var at = 0;
    for (final p in pieces) {
      out.setAll(at, p);
      at += p.length;
    }
    return out;
  }

  @override
  Future<void> dispose() async {}

  static String _message(Object e) =>
      e.toString().replaceFirst(RegExp(r'^(JavaScriptError|Error):\s*'), '');
}
