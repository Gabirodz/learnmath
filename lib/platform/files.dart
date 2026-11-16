/// The app's large files (recorded lectures) and the places it keeps them.
///
/// On a device these are real files. In a browser there is no file system,
/// so the same path strings name blobs in IndexedDB (see
/// `web/learnmath_web.js`) and the database is an IndexedDB one.
library;

export 'byte_sink.dart';
export 'files_io.dart' if (dart.library.js_interop) 'files_web.dart';
