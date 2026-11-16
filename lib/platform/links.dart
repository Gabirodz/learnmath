/// Opening a web page outside the app: the device's browser, or a new tab
/// when the app itself runs in a browser.
library;

export 'links_io.dart' if (dart.library.js_interop) 'links_web.dart';
