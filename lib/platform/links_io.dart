import 'package:flutter_inappwebview/flutter_inappwebview.dart';

/// Opens [url] in the device's browser.
Future<void> openInBrowser(Uri url) =>
    InAppBrowser.openWithSystemBrowser(url: WebUri.uri(url));
