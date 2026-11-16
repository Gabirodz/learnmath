import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';
import 'package:sembast/sembast_io.dart';

import 'byte_sink.dart';

/// Whether the app runs in a browser, where files are blobs in IndexedDB.
const bool filesAreBlobs = false;

Future<({String docs, String support})> appDirectories() async {
  final docs = await getApplicationDocumentsDirectory();
  final support = await getApplicationSupportDirectory();
  return (docs: docs.path, support: support.path);
}

Future<Database> openDatabaseAt(String path) =>
    databaseFactoryIo.openDatabase(path);

Future<bool> fileExists(String path) => File(path).exists();

Future<void> deleteFile(String path) async {
  final f = File(path);
  if (await f.exists()) await f.delete();
}

/// Deletes the directory [path] and everything in it.
Future<void> deleteTree(String path) async {
  final dir = Directory(path);
  if (await dir.exists()) await dir.delete(recursive: true);
}

Future<void> moveFile(String from, String to) => File(from).rename(to);

/// What an audio player is given to play the file at [path].
Future<Uri> playableUri(String path) async => Uri.file(path);

/// Opens [path] for writing, with [headerLength] bytes reserved at its
/// start for [ByteSink.finish].
Future<ByteSink> openByteSink(String path, {required int headerLength}) async {
  final f = File(path);
  await f.parent.create(recursive: true);
  final raf = await f.open(mode: FileMode.write);
  await raf.writeFrom(Uint8List(headerLength));
  return _FileSink(raf);
}

class _FileSink implements ByteSink {
  _FileSink(this._file);
  final RandomAccessFile _file;

  @override
  Future<void> add(Uint8List bytes) => _file.writeFrom(bytes);

  @override
  Future<void> finish(Uint8List header) async {
    await _file.setPosition(0);
    await _file.writeFrom(header);
    await _file.close();
  }

  @override
  Future<void> abandon() => _file.close();
}
