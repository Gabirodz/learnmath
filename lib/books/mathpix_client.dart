// ignore_for_file: prefer_initializing_formals
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:learnmath/tts/lecture_audio_builder.dart';

/// Error raised by [MathpixClient] with a user-readable [message].
class MathpixException implements Exception {
  final String message;
  final int? statusCode;
  MathpixException(this.message, {this.statusCode});

  @override
  String toString() => message;
}

/// Minimal client for the Mathpix `v3/pdf` API (async document conversion).
///
/// Flow: POST v3/pdf (multipart `file` + `options_json`) -> poll
/// GET v3/pdf/{id} -> GET v3/pdf/{id}.mmd.
class MathpixClient {
  MathpixClient({
    required String appId,
    required String appKey,
    http.Client? httpClient,
    String baseUrl = 'https://api.mathpix.com',
    Duration pollInterval = const Duration(seconds: 2),
    Duration timeout = const Duration(minutes: 15),
  })  : _appId = appId,
        _appKey = appKey,
        _client = httpClient ?? http.Client(),
        _ownsClient = httpClient == null,
        _baseUrl = baseUrl.endsWith('/')
            ? baseUrl.substring(0, baseUrl.length - 1)
            : baseUrl,
        _pollInterval = pollInterval,
        _timeout = timeout;

  final String _appId;
  final String _appKey;
  final http.Client _client;
  final bool _ownsClient;
  final String _baseUrl;
  final Duration _pollInterval;
  final Duration _timeout;

  Map<String, String> get _headers => {'app_id': _appId, 'app_key': _appKey};

  /// Converts pages [startPage]..[endPage] (1-based, inclusive) of the PDF at
  /// [pdfPath] and returns Markdown (see [mathpixToMarkdown]). Contains
  /// `[[page N]]` marker lines (N = page in the original PDF) when the
  /// number of returned pages matches the requested range.
  Future<String> transcribePages({
    required String pdfPath,
    required int startPage,
    required int endPage,
    void Function(double? fraction)? onProgress,
    bool Function()? isCancelled,
  }) async {
    if (startPage < 1 || endPage < startPage) {
      throw MathpixException('Invalid page range $startPage-$endPage.');
    }
    try {
      final id = await _upload(pdfPath, startPage, endPage);
      final deadline = DateTime.now().add(_timeout);
      while (true) {
        if (isCancelled?.call() ?? false) throw const GenerationCancelled();
        final st = await _status(id);
        final status = st['status'];
        if (status == 'error') throw MathpixException(_errorText(st));
        final pct = st['percent_done'];
        onProgress?.call(pct is num ? (pct / 100).clamp(0.0, 1.0).toDouble() : null);
        if (status == 'completed') break;
        if (DateTime.now().isAfter(deadline)) {
          throw MathpixException('Mathpix took too long to convert the pages.');
        }
        await Future<void>.delayed(_pollInterval);
      }
      if (isCancelled?.call() ?? false) throw const GenerationCancelled();
      final mmd = await _getText('/v3/pdf/$id.mmd');
      onProgress?.call(1.0);
      return mathpixPagesToMarkdown(mmd, firstPage: startPage, expectedPages: endPage - startPage + 1);
    } on SocketException {
      throw MathpixException('No connection to Mathpix.');
    } on http.ClientException {
      throw MathpixException('No connection to Mathpix.');
    } on TimeoutException {
      throw MathpixException('No connection to Mathpix.');
    }
  }

  void close() {
    if (_ownsClient) _client.close();
  }

  Future<String> _upload(String pdfPath, int start, int end) async {
    final file = File(pdfPath);
    if (!await file.exists()) {
      throw MathpixException('PDF file not found: $pdfPath');
    }
    final req = http.MultipartRequest('POST', Uri.parse('$_baseUrl/v3/pdf'))
      ..headers.addAll(_headers)
      ..fields['options_json'] = jsonEncode({
        'page_ranges': '$start-$end',
        'math_inline_delimiters': [r'$', r'$'],
        'math_display_delimiters': [r'$$', r'$$'],
        'rm_spaces': true,
        'include_page_breaks': true,
      });
    req.files.add(await http.MultipartFile.fromPath('file', pdfPath));
    final res = await http.Response.fromStream(await _client.send(req));
    final body = _decode(res.body);
    if (res.statusCode != 200) throw _httpError(res.statusCode, body, res.body);
    final id = body['pdf_id'];
    if (id is! String || id.isEmpty) {
      throw MathpixException(body['error'] is String
          ? 'Mathpix error: ${body['error']}'
          : 'Mathpix returned no document id.');
    }
    return id;
  }

  Future<Map<String, dynamic>> _status(String id) async {
    final res = await _client.get(Uri.parse('$_baseUrl/v3/pdf/$id'), headers: _headers);
    final body = _decode(res.body);
    // A 404 whose body is a status object means "not ready yet".
    if (res.statusCode == 404 && body['status'] is String) return body;
    if (res.statusCode != 200) throw _httpError(res.statusCode, body, res.body);
    return body;
  }

  Future<String> _getText(String path) async {
    final res = await _client.get(Uri.parse('$_baseUrl$path'), headers: _headers);
    if (res.statusCode != 200) {
      throw _httpError(res.statusCode, _decode(res.body), res.body);
    }
    return utf8.decode(res.bodyBytes, allowMalformed: true);
  }

  Map<String, dynamic> _decode(String body) {
    try {
      final v = jsonDecode(body);
      if (v is Map<String, dynamic>) return v;
    } catch (_) {}
    return {};
  }

  String _errorText(Map<String, dynamic> body) {
    final info = body['error_info'];
    String? detail;
    if (info is Map) {
      detail = (info['message'] ?? info['id'])?.toString();
    }
    final err = body['error'];
    detail ??= err is String ? err : null;
    return detail == null
        ? 'Mathpix could not convert the pages.'
        : 'Mathpix could not convert the pages: $detail';
  }

  MathpixException _httpError(int code, Map<String, dynamic> body, String raw) {
    if (code == 401 || code == 403) {
      return MathpixException(
          'Mathpix rejected the credentials. Check the app id and key in Settings.',
          statusCode: code);
    }
    if (code == 429) {
      return MathpixException(
          'Mathpix rate limit or quota reached. Try again later.',
          statusCode: code);
    }
    if (code == 413) {
      return MathpixException('The PDF is too large for Mathpix.', statusCode: code);
    }
    final info = body['error_info'];
    final id = info is Map ? info['id']?.toString() : null;
    if (id != null && id.contains('quota')) {
      return MathpixException('Mathpix quota exceeded.', statusCode: code);
    }
    final detail = (info is Map ? info['message'] : null) ?? body['error'];
    return MathpixException(
        'Mathpix error ($code)${detail != null ? ': $detail' : ''}',
        statusCode: code);
  }
}

/// Splits Mathpix's per-page output (pages end with `\pagebreak`) and
/// returns Markdown with `[[page N]]` markers. If the page count does not
/// match [expectedPages], markers are omitted.
String mathpixPagesToMarkdown(String mmd,
    {required int firstPage, required int expectedPages}) {
  final parts = mmd.split(RegExp(r'\\pagebreak(?![A-Za-z])'));
  if (parts.isNotEmpty && parts.last.trim().isEmpty) parts.removeLast();
  if (parts.length != expectedPages) {
    return mathpixToMarkdown(parts.join('\n\n'));
  }
  final out = <String>[];
  for (var i = 0; i < parts.length; i++) {
    final text = mathpixToMarkdown(parts[i]);
    out.add('[[page ${firstPage + i}]]${text.isEmpty ? '' : '\n\n$text'}');
  }
  return out.join('\n\n');
}

/// Pure post-processing of Mathpix Markdown into plain Markdown + `$` math.
String mathpixToMarkdown(String mmd) {
  var s = mmd.replaceAll('\r\n', '\n').replaceAll(RegExp(r'\\pagebreak(?![A-Za-z])'), '');

  // Math delimiters (in case the API still emitted \( \) / \[ \]).
  s = s.replaceAllMapped(RegExp(r'\\\[(.*?)\\\]', dotAll: true),
      (m) => '\n\$\$\n${m[1]!.trim()}\n\$\$\n');
  s = s.replaceAllMapped(
      RegExp(r'\\\((.*?)\\\)', dotAll: true), (m) => '\$${m[1]!.trim()}\$');
  // Display math on its own lines.
  s = s.replaceAllMapped(RegExp(r'\$\$(.+?)\$\$', dotAll: true), (m) {
    final inner = m[1]!.trim();
    return '\n\$\$\n$inner\n\$\$\n';
  });

  // Figures: keep caption only.
  s = s.replaceAllMapped(
      RegExp(r'\\begin\{figure\}.*?\\end\{figure\}', dotAll: true), (m) {
    final body = m[0]!;
    final i = body.indexOf(r'\caption{');
    if (i < 0) return '';
    final open = i + r'\caption'.length;
    final end = _matchBrace(body, open);
    return end < 0 ? '' : '\n\n${body.substring(open + 1, end).trim()}\n\n';
  });
  s = s.replaceAll(RegExp(r'!\[[^\]]*\]\([^)]*\)'), '');
  s = s.replaceAll(RegExp(r'\\includegraphics(\[[^\]]*\])?\{[^}]*\}'), '');

  // Footnotes dropped.
  s = _replaceCommand(s, 'footnotetext', (_) => '');
  s = _replaceCommand(s, 'footnote', (_) => '');

  // Headings.
  for (final e in const {
    'title': '#',
    'section': '##',
    'subsection': '###',
    'subsubsection': '####',
  }.entries) {
    s = _replaceCommand(
        s, e.key, (arg) => '\n\n${e.value} ${arg.trim().replaceAll('\n', ' ')}\n\n');
  }
  s = _replaceCommand(s, 'author', (a) => '\n\n${a.trim()}\n\n');

  // Theorem-like environments.
  const envs = {
    'theorem': 'Theorem',
    'lemma': 'Lemma',
    'proposition': 'Proposition',
    'corollary': 'Corollary',
    'definition': 'Definition',
    'remark': 'Remark',
    'example': 'Example',
    'proof': 'Proof',
    'claim': 'Claim',
    'conjecture': 'Conjecture',
    'notation': 'Notation',
    'exercise': 'Exercise',
    'abstract': 'Abstract',
  };
  for (final e in envs.entries) {
    s = s.replaceAllMapped(
        RegExp('\\\\begin\\{${e.key}\\}(\\[[^\\]]*\\])?(.*?)\\\\end\\{${e.key}\\}',
            dotAll: true), (m) {
      final t = m[1] == null ? '' : ' (${m[1]!.substring(1, m[1]!.length - 1)})';
      return '\n\n**${e.value}$t.** ${m[2]!.trim()}\n\n';
    });
  }

  // Lists.
  s = s.replaceAllMapped(
      RegExp(r'\\begin\{itemize\}(.*?)\\end\{itemize\}', dotAll: true),
      (m) => '\n${_items(m[1]!, false)}\n');
  s = s.replaceAllMapped(
      RegExp(r'\\begin\{enumerate\}(.*?)\\end\{enumerate\}', dotAll: true),
      (m) => '\n${_items(m[1]!, true)}\n');

  s = s.replaceAll(RegExp(r'[ \t]+\n'), '\n');
  s = s.replaceAll(RegExp(r'\n{3,}'), '\n\n');
  return s.trim();
}

String _items(String body, bool numbered) {
  final items = body.split(RegExp(r'\\item\b')).skip(1);
  var n = 0;
  return items.map((it) {
    n++;
    return '${numbered ? '$n.' : '-'} ${it.trim().replaceAll(RegExp(r'\n+'), ' ')}';
  }).join('\n');
}

/// Index of the `}` matching the `{` at [open], or -1.
int _matchBrace(String s, int open) {
  var depth = 0;
  for (var i = open; i < s.length; i++) {
    final c = s[i];
    if (c == r'\' ) {
      i++;
      continue;
    }
    if (c == '{') depth++;
    if (c == '}') {
      depth--;
      if (depth == 0) return i;
    }
  }
  return -1;
}

/// Replaces `\name{arg}` / `\name*{arg}` (nested braces ok) using [f].
String _replaceCommand(String s, String name, String Function(String) f) {
  final re = RegExp('\\\\$name\\*?\\s*\\{');
  final sb = StringBuffer();
  var pos = 0;
  while (true) {
    final m = re.matchAsPrefix(s, s.indexOf(re, pos) < 0 ? s.length : s.indexOf(re, pos));
    if (m == null) break;
    final open = m.end - 1;
    final close = _matchBrace(s, open);
    if (close < 0) break;
    sb.write(s.substring(pos, m.start));
    sb.write(f(s.substring(open + 1, close)));
    pos = close + 1;
  }
  sb.write(s.substring(pos));
  return sb.toString();
}
