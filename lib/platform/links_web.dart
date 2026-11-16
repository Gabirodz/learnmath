import 'dart:js_interop';

@JS('window.open')
external JSAny? _open(String url, String target, String features);

/// Opens [url] in a new browser tab.
Future<void> openInBrowser(Uri url) async {
  _open(url.toString(), '_blank', 'noopener');
}
