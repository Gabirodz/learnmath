import 'dart:typed_data';

/// A file being written front to back whose first bytes (a header) are only
/// known at the end, like a WAV file.
abstract class ByteSink {
  Future<void> add(Uint8List bytes);

  /// Puts [header] over the first bytes written and closes the file.
  Future<void> finish(Uint8List header);

  /// Closes the file without finishing it; what was written is discarded
  /// where the platform allows.
  Future<void> abandon();
}
