/// The Kokoro voice running in the browser, for the web version of the app.
library;

export 'kokoro_voices.dart';
export 'kokoro_web_stub.dart'
    if (dart.library.js_interop) 'kokoro_web_engine.dart';
