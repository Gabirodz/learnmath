import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:archive/archive_io.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

import 'tts_engine.dart';
import 'wav.dart';

/// Speakers bundled in the kokoro-en-v0_19 voices file, indexed by speaker id.
const kokoroVoices = <String>[
  'Default (US, female)',
  'Bella (US, female)',
  'Nicole (US, female)',
  'Sarah (US, female)',
  'Sky (US, female)',
  'Adam (US, male)',
  'Michael (US, male)',
  'Emma (UK, female)',
  'Isabella (UK, female)',
  'George (UK, male)',
  'Lewis (UK, male)',
];

/// Downloads and unpacks the on-device Kokoro model (about 100 MB, once).
class KokoroModelManager {
  KokoroModelManager(this.modelsDir);

  final String modelsDir;

  static const _name = 'kokoro-int8-en-v0_19';
  static const _url =
      'https://github.com/k2-fsa/sherpa-onnx/releases/download/tts-models/$_name.tar.bz2';

  String get _dir => p.join(modelsDir, _name);
  File get _marker => File(p.join(_dir, '.installed'));

  Future<bool> isInstalled() => _marker.exists();

  Future<void> delete() async {
    final d = Directory(_dir);
    if (await d.exists()) await d.delete(recursive: true);
  }

  /// [onProgress] gets 0..1 while downloading and null while unpacking.
  Future<void> install({void Function(double? fraction)? onProgress}) async {
    if (await isInstalled()) return;
    await Directory(modelsDir).create(recursive: true);
    final archive = File(p.join(modelsDir, '$_name.tar.bz2.part'));

    final client = http.Client();
    try {
      final resp = await client.send(http.Request('GET', Uri.parse(_url)));
      if (resp.statusCode != 200) {
        throw TtsException(
            'Could not download the voice model (HTTP ${resp.statusCode}).');
      }
      final total = resp.contentLength ?? 0;
      var received = 0;
      final sink = archive.openWrite();
      try {
        await for (final chunk in resp.stream) {
          sink.add(chunk);
          received += chunk.length;
          if (total > 0) onProgress?.call(received / total);
        }
      } finally {
        await sink.close();
      }
      if (total > 0 && received != total) {
        throw TtsException('Voice model download was interrupted.');
      }
    } on SocketException {
      throw TtsException(
          'No network connection while downloading the voice model.');
    } on http.ClientException catch (e) {
      throw TtsException('Voice model download failed: ${e.message}');
    } finally {
      client.close();
    }

    onProgress?.call(null);
    await delete(); // clear any half-extracted previous attempt
    final archivePath = archive.path;
    final outDir = modelsDir;
    // Pure-Dart bzip2 is slow; keep it off the UI isolate.
    await Isolate.run(() => extractFileToDisk(archivePath, outDir));
    await archive.delete();
    if (await _findModelFile() == null) {
      throw TtsException('The downloaded voice model is incomplete.');
    }
    await _marker.create();
  }

  Future<String?> _findModelFile() async {
    final d = Directory(_dir);
    if (!await d.exists()) return null;
    await for (final e in d.list()) {
      if (e is File && e.path.endsWith('.onnx')) return e.path;
    }
    return null;
  }

  Future<KokoroPaths> paths() async {
    final model = await _findModelFile();
    if (model == null) throw TtsException('Voice model is not installed.');
    return KokoroPaths(
      model: model,
      voices: p.join(_dir, 'voices.bin'),
      tokens: p.join(_dir, 'tokens.txt'),
      dataDir: p.join(_dir, 'espeak-ng-data'),
    );
  }
}

class KokoroPaths {
  const KokoroPaths({
    required this.model,
    required this.voices,
    required this.tokens,
    required this.dataDir,
  });
  final String model;
  final String voices;
  final String tokens;
  final String dataDir;
}

/// Kokoro running through sherpa-onnx in a worker isolate, so synthesis never
/// blocks the UI.
class KokoroTtsEngine implements TtsEngine {
  KokoroTtsEngine({required this.manager, required this.speakerId});

  final KokoroModelManager manager;
  final int speakerId;

  Isolate? _isolate;
  SendPort? _toWorker;
  ReceivePort? _fromWorker;
  StreamIterator<Object?>? _replies;
  int _sampleRate = 24000;

  @override
  int get sampleRate => _sampleRate;

  @override
  int get maxConcurrency => 1;

  @override
  Future<void> prepare() async {
    if (_isolate != null) return;
    final paths = await manager.paths();
    final from = ReceivePort();
    _fromWorker = from;
    _replies = StreamIterator<Object?>(from);
    final threads = (Platform.numberOfProcessors ~/ 2).clamp(1, 4);
    _isolate = await Isolate.spawn(
      _worker,
      [from.sendPort, paths.model, paths.voices, paths.tokens, paths.dataDir, threads],
      errorsAreFatal: true,
      onExit: from.sendPort,
      debugName: 'kokoro-tts',
    );
    final first = await _next();
    if (first is SendPort) {
      _toWorker = first;
    } else {
      await dispose();
      throw TtsException('Could not start the voice model: $first');
    }
  }

  Future<Object?> _next() async {
    final r = _replies;
    if (r == null || !await r.moveNext()) return null;
    return r.current;
  }

  @override
  Future<Int16List> synthesize(String text) async {
    final port = _toWorker;
    if (port == null) throw TtsException('Voice model is not running.');
    port.send([text, speakerId]);
    final reply = await _next();
    if (reply is List && reply.length == 2) {
      _sampleRate = reply[1] as int;
      return floatToPcm16(reply[0] as Float32List);
    }
    // null means the isolate exited (native crash or out of memory).
    throw TtsException(reply == null
        ? 'The voice model stopped unexpectedly.'
        : 'Speech synthesis failed: $reply');
  }

  @override
  Future<void> dispose() async {
    _toWorker?.send(null);
    _toWorker = null;
    await _replies?.cancel();
    _replies = null;
    _fromWorker?.close();
    _fromWorker = null;
    _isolate?.kill();
    _isolate = null;
  }

  static void _worker(List<Object> args) {
    final out = args[0] as SendPort;
    final sherpa.OfflineTts tts;
    try {
      sherpa.initBindings();
      tts = sherpa.OfflineTts(sherpa.OfflineTtsConfig(
        model: sherpa.OfflineTtsModelConfig(
          kokoro: sherpa.OfflineTtsKokoroModelConfig(
            model: args[1] as String,
            voices: args[2] as String,
            tokens: args[3] as String,
            dataDir: args[4] as String,
          ),
          numThreads: args[5] as int,
        ),
        // We insert our own pauses between segments.
        maxNumSenetences: 2, // (sic) upstream spelling in 1.13
      ));
    } catch (e) {
      out.send('$e');
      return;
    }
    final inbox = ReceivePort();
    out.send(inbox.sendPort);
    inbox.listen((msg) {
      if (msg == null) {
        tts.free();
        inbox.close();
        return;
      }
      try {
        final req = msg as List;
        final audio =
            tts.generate(text: req[0] as String, sid: req[1] as int, speed: 1.0);
        if (audio.samples.isEmpty || audio.sampleRate <= 0) {
          out.send('the model produced no audio');
        } else {
          out.send([audio.samples, audio.sampleRate]);
        }
      } catch (e) {
        out.send('$e');
      }
    });
  }
}
