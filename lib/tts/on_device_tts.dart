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

/// Which sherpa-onnx model family a voice model belongs to; decides how its
/// files are handed to the engine.
enum VoiceFamily { kokoro, kitten, vits }

/// A downloadable on-device voice model.
class VoiceModel {
  const VoiceModel({
    required this.id,
    required this.label,
    required this.archive,
    required this.family,
    required this.modelFile,
    required this.downloadMb,
    required this.speed,
    required this.speakers,
  });

  /// Stored in settings.
  final String id;
  final String label;

  /// Name of the archive in the sherpa-onnx `tts-models` release, which is
  /// also the directory it unpacks to.
  final String archive;
  final VoiceFamily family;

  /// The `.onnx` file inside the archive.
  final String modelFile;
  final int downloadMb;

  /// How it compares when recording a lecture, for the settings screen.
  final String speed;

  /// Speaker names, indexed by speaker id.
  final List<String> speakers;

  String get url =>
      'https://github.com/k2-fsa/sherpa-onnx/releases/download/tts-models/$archive.tar.bz2';

  static VoiceModel byId(String id) {
    id = _renamed[id] ?? id;
    for (final m in voiceModels) {
      if (m.id == id) return m;
    }
    return voiceModels.first;
  }

  /// Ids of removed models, mapped to the model that replaced them.
  static const _renamed = {'piper-lessac': 'piper-ljspeech'};
}

/// On-device voices, most natural first. Speeds were measured with
/// sherpa-onnx 1.13.8 on a 4-core x86 machine using two threads (time to
/// synthesize / length of the audio): Kokoro 2.2, Kitten 0.48, Piper 0.11.
/// Every voice here must allow use in free and commercial software, so no
/// Piper voice trained on (or fine-tuned from) the research-only Lessac
/// recordings.
const voiceModels = <VoiceModel>[
  VoiceModel(
    id: 'kokoro',
    label: 'Kokoro',
    archive: 'kokoro-int8-en-v0_19',
    family: VoiceFamily.kokoro,
    modelFile: 'model.int8.onnx',
    downloadMb: 103,
    speed: 'Slowest to record',
    speakers: [
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
    ],
  ),
  VoiceModel(
    id: 'kitten-nano',
    label: 'Kitten Nano 0.8',
    archive: 'kitten-nano-en-v0_8-int8',
    family: VoiceFamily.kitten,
    modelFile: 'model.int8.onnx',
    downloadMb: 31,
    speed: 'About 5× faster than Kokoro',
    speakers: [
      'Voice 2 (male)',
      'Voice 2 (female)',
      'Voice 3 (male)',
      'Voice 3 (female)',
      'Voice 4 (male)',
      'Voice 4 (female)',
      'Voice 5 (male)',
      'Voice 5 (female)',
    ],
  ),
  VoiceModel(
    id: 'piper-ljspeech',
    label: 'Piper LJSpeech',
    archive: 'vits-piper-en_US-ljspeech-medium',
    family: VoiceFamily.vits,
    modelFile: 'en_US-ljspeech-medium.onnx',
    downloadMb: 67,
    speed: 'About 20× faster than Kokoro',
    speakers: ['LJ (US, female)'],
  ),
];

/// Downloads and unpacks on-device voice models (once each).
class VoiceModelManager {
  VoiceModelManager(this.modelsDir);

  final String modelsDir;

  String _dir(VoiceModel m) => p.join(modelsDir, m.archive);
  File _marker(VoiceModel m) => File(p.join(_dir(m), '.installed'));

  Future<bool> isInstalled(VoiceModel m) => _marker(m).exists();

  Future<void> delete(VoiceModel m) async {
    final d = Directory(_dir(m));
    if (await d.exists()) await d.delete(recursive: true);
  }

  /// Folders of models the app no longer offers: Piper Lessac, whose
  /// recordings are licensed for research only.
  static const _retired = ['vits-piper-en_US-lessac-medium'];

  /// Deletes the files of retired models, which settings no longer lists.
  Future<void> removeRetired() async {
    for (final name in _retired) {
      final d = Directory(p.join(modelsDir, name));
      try {
        if (await d.exists()) await d.delete(recursive: true);
      } on FileSystemException {
        // Tried again on the next start.
      }
    }
  }

  final _installing = <String, Future<void>>{};

  /// [onProgress] gets 0..1 while downloading and null while unpacking.
  /// A second call for a model that is already being installed joins the
  /// running download (its [onProgress] is not called).
  Future<void> install(VoiceModel m,
      {void Function(double? fraction)? onProgress}) {
    final running = _installing[m.id];
    if (running != null) return running;
    final f = _install(m, onProgress);
    _installing[m.id] = f;
    return f.whenComplete(() => _installing.remove(m.id));
  }

  Future<void> _install(
      VoiceModel m, void Function(double? fraction)? onProgress) async {
    if (await isInstalled(m)) return;
    await Directory(modelsDir).create(recursive: true);
    final archive = File(p.join(modelsDir, '${m.archive}.tar.bz2.part'));

    final client = http.Client();
    try {
      final resp = await client.send(http.Request('GET', Uri.parse(m.url)));
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
    await delete(m); // clear any half-extracted previous attempt
    final archivePath = archive.path;
    final outDir = modelsDir;
    // Pure-Dart bzip2 is slow; keep it off the UI isolate.
    await Isolate.run(() => extractFileToDisk(archivePath, outDir));
    await archive.delete();
    if (!await File(p.join(_dir(m), m.modelFile)).exists()) {
      throw TtsException('The downloaded voice model is incomplete.');
    }
    await _marker(m).create();
  }

  Future<VoiceModelPaths> paths(VoiceModel m) async {
    final model = File(p.join(_dir(m), m.modelFile));
    if (!await model.exists()) {
      throw TtsException('Voice model is not installed.');
    }
    return VoiceModelPaths(
      model: model.path,
      voices: p.join(_dir(m), 'voices.bin'),
      tokens: p.join(_dir(m), 'tokens.txt'),
      dataDir: p.join(_dir(m), 'espeak-ng-data'),
    );
  }
}

class VoiceModelPaths {
  const VoiceModelPaths({
    required this.model,
    required this.voices,
    required this.tokens,
    required this.dataDir,
  });
  final String model;

  /// Speaker embeddings; Piper voices have none.
  final String voices;
  final String tokens;
  final String dataDir;
}

/// A [VoiceModel] running through sherpa-onnx in a worker isolate, so
/// synthesis never blocks the UI.
class OnDeviceTtsEngine implements TtsEngine {
  OnDeviceTtsEngine({
    required this.manager,
    required this.model,
    required int speakerId,
  }) : speakerId = speakerId.clamp(0, model.speakers.length - 1);

  final VoiceModelManager manager;
  final VoiceModel model;
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
    final paths = await manager.paths(model);
    final from = ReceivePort();
    _fromWorker = from;
    _replies = StreamIterator<Object?>(from);
    final threads = (Platform.numberOfProcessors ~/ 2).clamp(1, 4);
    _isolate = await Isolate.spawn(
      _worker,
      [
        from.sendPort,
        paths.model,
        paths.voices,
        paths.tokens,
        paths.dataDir,
        threads,
        model.family.index,
      ],
      errorsAreFatal: true,
      onExit: from.sendPort,
      debugName: 'tts-${model.id}',
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
      final model = args[1] as String;
      final voices = args[2] as String;
      final tokens = args[3] as String;
      final dataDir = args[4] as String;
      final family = VoiceFamily.values[args[6] as int];
      tts = sherpa.OfflineTts(sherpa.OfflineTtsConfig(
        model: sherpa.OfflineTtsModelConfig(
          kokoro: family == VoiceFamily.kokoro
              ? sherpa.OfflineTtsKokoroModelConfig(
                  model: model,
                  voices: voices,
                  tokens: tokens,
                  dataDir: dataDir)
              : const sherpa.OfflineTtsKokoroModelConfig(),
          kitten: family == VoiceFamily.kitten
              ? sherpa.OfflineTtsKittenModelConfig(
                  model: model,
                  voices: voices,
                  tokens: tokens,
                  dataDir: dataDir)
              : const sherpa.OfflineTtsKittenModelConfig(),
          vits: family == VoiceFamily.vits
              ? sherpa.OfflineTtsVitsModelConfig(
                  model: model, tokens: tokens, dataDir: dataDir)
              : const sherpa.OfflineTtsVitsModelConfig(),
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
