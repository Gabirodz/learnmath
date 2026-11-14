import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import 'math_check.dart';

/// Where Pyodide (Python on WebAssembly) and its SymPy package are fetched
/// from, on first use only; the WebView cache keeps them afterwards. Must end
/// in a slash. Pyodide 314.0.7 ships SymPy 1.14.0.
const pyodideBaseUrl = 'https://cdn.jsdelivr.net/pyodide/v314.0.7/full/';

/// Runs checks with Pyodide inside an invisible WebView.
///
/// The Python runs in a Web Worker owned by `assets/mathcheck/runner.html`, so
/// a check stuck in a loop is stopped by terminating the worker and the app
/// stays responsive. The WebView is created on the first [run] and reused, so
/// SymPy is loaded once per app session rather than once per lesson.
class PyodideCheckRunner implements MathCheckRunner {
  PyodideCheckRunner({this.pyodideUrl = pyodideBaseUrl});

  /// Base URL Pyodide is loaded from.
  final String pyodideUrl;

  static const _asset = 'assets/mathcheck/runner.html';
  static const _progressHandler = 'mathcheckProgress';

  /// Pyodide plus SymPy is a download of several MB; the page itself gives up
  /// after 120 s, this is the margin on top of that for the whole run.
  static const _loadAllowance = Duration(seconds: 150);

  /// Extra time per check for restarting the worker after a timeout.
  static const _restartAllowance = Duration(seconds: 15);

  HeadlessInAppWebView? _view;
  InAppWebViewController? _controller;
  Future<InAppWebViewController>? _starting;
  void Function(int done, int total)? _onProgress;

  @override
  Future<List<CheckOutcome>> run(
    List<MathCheck> checks, {
    Duration perCheckTimeout = const Duration(seconds: 20),
    void Function(int done, int total)? onProgress,
  }) async {
    if (checks.isEmpty) return const [];
    final controller = await _ensureStarted();
    _onProgress = onProgress;

    final overall = _loadAllowance +
        (perCheckTimeout + _restartAllowance) * checks.length;
    final CallAsyncJavaScriptResult? result;
    try {
      result = await controller.callAsyncJavaScript(
        // Defined here rather than as a user script so it cannot be missing
        // when the page reloads. Python never sees it: it lives in the worker.
        functionBody: '''
          window.mathcheckProgress = function (done, total) {
            window.flutter_inappwebview.callHandler('$_progressHandler', done, total);
          };
          return await window.mathcheck.run(request);
        ''',
        arguments: {
          'request': {
            'pyodideUrl': pyodideUrl,
            'harness': checkHarnessPython,
            'checks': [
              for (final c in checks) {'code': c.code},
            ],
            'timeoutMs': perCheckTimeout.inMilliseconds,
          },
        },
      ).timeout(overall);
    } on TimeoutException {
      // The page is probably wedged; start from scratch next time.
      await _teardown();
      throw MathCheckException(
          'The math checks did not finish in ${overall.inSeconds} s.');
    } finally {
      _onProgress = null;
    }

    if (result == null) {
      throw MathCheckException('The math checker did not respond.');
    }
    final error = result.error;
    if (error != null) throw MathCheckException(_explain(error));

    final value = result.value;
    final List<dynamic> decoded;
    try {
      decoded = jsonDecode(value as String) as List<dynamic>;
    } on Object {
      throw MathCheckException('The math checker returned an unreadable answer.');
    }
    if (decoded.length != checks.length) {
      throw MathCheckException(
          'The math checker answered ${decoded.length} of ${checks.length} checks.');
    }
    return [
      for (var i = 0; i < checks.length; i++)
        _outcome(checks[i], (decoded[i] as Map).cast<String, Object?>()),
    ];
  }

  CheckOutcome _outcome(MathCheck check, Map<String, Object?> json) {
    final status = CheckStatus.values.asNameMap()[json['status']] ??
        CheckStatus.error;
    final detail = json['detail'] as String?;
    return CheckOutcome(
      title: check.title,
      status: status,
      detail: status == CheckStatus.passed || detail == null || detail.isEmpty
          ? null
          : detail,
    );
  }

  /// The page rejects with messages written for people ("Could not load
  /// Pyodide/SymPy ... Check the network connection"); anything else is wrapped.
  String _explain(String error) {
    if (error.contains('Pyodide') || error.contains('SymPy')) {
      return 'The math checker could not start: $error '
          '(it downloads Pyodide once, so it needs a network connection the first time).';
    }
    return 'The math checker failed: $error';
  }

  Future<InAppWebViewController> _ensureStarted() {
    final existing = _controller;
    if (existing != null) return Future.value(existing);
    return _starting ??= _start().whenComplete(() => _starting = null);
  }

  Future<InAppWebViewController> _start() async {
    final String html;
    try {
      html = await rootBundle.loadString(_asset);
    } on Object {
      throw MathCheckException('The math checker page is missing from the app.');
    }

    final created = Completer<InAppWebViewController>();
    final loaded = Completer<void>();

    // The page is loaded as a string with an https base URL, not as a file
    // asset. Under file:// (and Android's file:///android_asset/) the origin is
    // opaque: a module Web Worker from a Blob URL fails to start there (seen in
    // Chromium) and cross-origin fetches of the Pyodide CDN are more fragile.
    // With an https base URL the page has a real origin, so Blob workers and
    // CORS-enabled CDN requests behave as on a normal website. The host is
    // never contacted; loadDataWithBaseURL only uses it as the origin.
    final view = HeadlessInAppWebView(
      initialData: InAppWebViewInitialData(
        data: html,
        mimeType: 'text/html',
        encoding: 'utf-8',
        baseUrl: WebUri('https://mathcheck.localhost/'),
      ),
      initialSettings: InAppWebViewSettings(
        javaScriptEnabled: true,
        isInspectable: false,
        // Pyodide's files are cached by the WebView's HTTP cache.
        cacheEnabled: true,
        mediaPlaybackRequiresUserGesture: true,
      ),
      onWebViewCreated: (controller) {
        controller.addJavaScriptHandler(
          handlerName: _progressHandler,
          callback: (args) {
            if (args.length >= 2 && args[0] is num && args[1] is num) {
              _onProgress?.call((args[0] as num).toInt(), (args[1] as num).toInt());
            }
            return null;
          },
        );
        if (!created.isCompleted) created.complete(controller);
      },
      onLoadStop: (controller, url) {
        if (!loaded.isCompleted) loaded.complete();
      },
      onReceivedError: (controller, request, error) {
        if ((request.isForMainFrame ?? true) && !loaded.isCompleted) {
          loaded.completeError(
              MathCheckException('Could not open the math checker: ${error.description}'));
        }
      },
    );
    _view = view;

    try {
      await view.run();
      final controller = await created.future.timeout(const Duration(seconds: 20));
      await loaded.future.timeout(const Duration(seconds: 20));
      _controller = controller;
      return controller;
    } on TimeoutException {
      await _teardown();
      throw MathCheckException('The math checker did not start.');
    } on MathCheckException {
      await _teardown();
      rethrow;
    } on Object catch (e) {
      await _teardown();
      throw MathCheckException('Could not start the math checker: $e');
    }
  }

  Future<void> _teardown() async {
    final view = _view;
    _view = null;
    _controller = null;
    try {
      await view?.dispose();
    } on Object {
      // Already gone.
    }
  }

  @override
  Future<void> dispose() => _teardown();
}
