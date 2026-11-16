import 'dart:js_interop';
import 'dart:typed_data';

import 'package:sembast_web/sembast_web.dart';

import 'byte_sink.dart';

/// Whether the app runs in a browser, where files are blobs in IndexedDB.
const bool filesAreBlobs = true;

// Defined in web/learnmath_web.js.
@JS('learnmathFiles.put')
external JSPromise<JSAny?> _put(String path, JSArray<JSUint8Array> parts,
    String type);
@JS('learnmathFiles.exists')
external JSPromise<JSBoolean> _exists(String path);
@JS('learnmathFiles.remove')
external JSPromise<JSAny?> _remove(String path);
@JS('learnmathFiles.removeTree')
external JSPromise<JSAny?> _removeTree(String path);
@JS('learnmathFiles.move')
external JSPromise<JSAny?> _move(String from, String to);
@JS('learnmathFiles.url')
external JSPromise<JSString?> _url(String path);

/// Nothing is on disk: these only prefix the keys of the blobs.
Future<({String docs, String support})> appDirectories() async =>
    (docs: '/docs', support: '/support');

/// [path] is used as the name of the IndexedDB database.
Future<Database> openDatabaseAt(String path) =>
    databaseFactoryWeb.openDatabase(path);

Future<bool> fileExists(String path) async => (await _exists(path).toDart).toDart;

Future<void> deleteFile(String path) async {
  await _remove(path).toDart;
}

/// Deletes every blob at [path] or below it.
Future<void> deleteTree(String path) async {
  await _removeTree(path).toDart;
}

Future<void> moveFile(String from, String to) async {
  await _move(from, to).toDart;
}

/// What an audio player is given to play the file at [path]: a `blob:` URL.
Future<Uri> playableUri(String path) async {
  final url = (await _url(path).toDart)?.toDart;
  if (url == null) throw StateError('The recording is missing.');
  return Uri.parse(url);
}

/// Collects the file in memory and stores it as one blob when finished: a
/// half-hour lecture is under 100 MB.
Future<ByteSink> openByteSink(String path, {required int headerLength}) async =>
    _BlobSink(path);

class _BlobSink implements ByteSink {
  _BlobSink(this._path);
  final String _path;
  final _parts = <JSUint8Array>[];

  @override
  Future<void> add(Uint8List bytes) async {
    // A copy: the caller may reuse its buffer.
    _parts.add(Uint8List.fromList(bytes).toJS);
  }

  @override
  Future<void> finish(Uint8List header) async {
    final type = _path.endsWith('.wav') || _path.endsWith('.wav.part')
        ? 'audio/wav'
        : 'application/octet-stream';
    await _put(_path, [header.toJS, ..._parts].toJS, type).toDart;
    _parts.clear();
  }

  @override
  Future<void> abandon() async => _parts.clear();
}
