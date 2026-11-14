import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

/// Error talking to OpenRouter. [toString] is user-readable.
class OpenRouterException implements Exception {
  OpenRouterException(this.message, {this.statusCode});

  final int? statusCode;
  final String message;

  @override
  String toString() => message;
}

class ChatMessage {
  const ChatMessage._(this.role, this.content, [this.images = const []]);
  const ChatMessage.system(String content) : this._('system', content);
  const ChatMessage.user(String content) : this._('user', content);
  const ChatMessage.assistant(String content) : this._('assistant', content);

  /// A user message with PNG images attached (for vision models).
  const ChatMessage.userWithImages(String content, List<Uint8List> pngImages)
      : this._('user', content, pngImages);

  final String role;
  final String content;
  final List<Uint8List> images;

  Map<String, Object> toJson() => {
        'role': role,
        'content': images.isEmpty
            ? content
            : [
                {'type': 'text', 'text': content},
                for (final png in images)
                  {
                    'type': 'image_url',
                    'image_url': {
                      'url': 'data:image/png;base64,${base64Encode(png)}',
                    },
                  },
              ],
      };
}

/// One request of a batch: the body is what the sync endpoint would take.
class BatchRequest {
  const BatchRequest({required this.customId, required this.messages});

  /// Unique within the batch; results are matched back by it.
  final String customId;
  final List<ChatMessage> messages;
}

/// Answer to one [BatchRequest]: either [text] or [error] is set.
class BatchResult {
  const BatchResult({this.text, this.error});
  final String? text;
  final String? error;
}

/// A batch as reported by `GET /batches/{id}`.
class BatchInfo {
  const BatchInfo({
    required this.id,
    required this.status,
    this.error,
    this.expiresAt,
    this.total = 0,
    this.completed = 0,
    this.failed = 0,
    this.cost,
    this.results = const {},
  });

  final String id;

  /// `validating`, `in_progress`, `finalizing`, `completed`, `failed`,
  /// `expired`, `cancelled`, or [gone] once OpenRouter has deleted it.
  final String status;

  /// Why the whole batch failed.
  final String? error;
  final DateTime? expiresAt;
  final int total;
  final int completed;
  final int failed;

  /// What OpenRouter charged, in USD, once finished.
  final double? cost;

  /// By custom id; only present in a terminal status.
  final Map<String, BatchResult> results;

  /// Results are kept for 30 days; after that the batch is gone.
  static const gone = 'gone';

  bool get isDone => status == 'completed';
  bool get isTerminal =>
      isDone ||
      status == 'failed' ||
      status == 'expired' ||
      status == 'cancelled' ||
      status == gone;
}

class OpenRouterClient {
  OpenRouterClient({
    required this._apiKey,
    http.Client? httpClient,
    String baseUrl = 'https://openrouter.ai/api/v1',
    this.firstByteTimeout = const Duration(seconds: 60),
    this.idleTimeout = const Duration(seconds: 120),
  })  : _http = httpClient ?? http.Client(),
        _ownsClient = httpClient == null,
        _baseUrl = baseUrl.endsWith('/')
            ? baseUrl.substring(0, baseUrl.length - 1)
            : baseUrl;

  final String _apiKey;
  final http.Client _http;
  final bool _ownsClient;
  final String _baseUrl;

  /// Max wait for response headers.
  final Duration firstByteTimeout;

  /// Max silence between chunks of a streaming body (keep-alives count).
  final Duration idleTimeout;

  Map<String, String> get _headers => {
        'Authorization': 'Bearer $_apiKey',
        'Content-Type': 'application/json',
        'X-Title': 'LearnMath',
      };

  /// Streams the completion and returns the full text. [onProgress] receives
  /// the accumulated character count as text arrives, [onDelta] each new
  /// piece of text.
  Future<String> chat({
    required String model,
    required List<ChatMessage> messages,
    double? temperature,
    int? maxTokens,
    String? reasoningEffort,
    void Function(int totalChars)? onProgress,
    void Function(String delta)? onDelta,
  }) async {
    final req = http.Request('POST', Uri.parse('$_baseUrl/chat/completions'))
      ..headers.addAll(_headers)
      ..body = jsonEncode({
        'model': model,
        'messages': [for (final m in messages) m.toJson()],
        'stream': true,
        ..._sampling(temperature, reasoningEffort),
        'max_tokens': ?maxTokens,
      });

    final resp = await _send(req);
    if (resp.statusCode != 200) {
      throw await _errorFromResponse(resp);
    }

    final buf = StringBuffer();
    var total = 0;
    final lines = resp.stream
        .timeout(idleTimeout, onTimeout: (sink) {
          sink.addError(OpenRouterException(
              'The model stopped responding. Please try again.'));
          sink.close();
        })
        .transform(utf8.decoder)
        .transform(const LineSplitter());

    try {
      await for (final rawLine in lines) {
        final line = rawLine.trim();
        if (line.isEmpty || line.startsWith(':')) continue;
        if (!line.startsWith('data:')) continue;
        final data = line.substring(5).trim();
        if (data.isEmpty) continue;
        if (data == '[DONE]') break;

        Object? json;
        try {
          json = jsonDecode(data);
        } on FormatException {
          continue; // partial / garbage line; ignore
        }
        if (json is! Map) continue;

        final err = json['error'];
        if (err != null) {
          throw OpenRouterException(
            _describeError(err, null),
            statusCode: err is Map && err['code'] is int
                ? err['code'] as int
                : null,
          );
        }

        final choices = json['choices'];
        if (choices is! List || choices.isEmpty) continue;
        final choice = choices.first;
        if (choice is! Map) continue;
        final delta = choice['delta'] ?? choice['message'];
        final content = delta is Map ? delta['content'] : null;
        if (content is String && content.isNotEmpty) {
          buf.write(content);
          total += content.length;
          onProgress?.call(total);
          onDelta?.call(content);
        }
        final finish = choice['finish_reason'];
        if (finish == 'error') {
          throw OpenRouterException('The model reported an error mid-stream.');
        }
      }
    } on http.ClientException catch (e) {
      throw OpenRouterException('Network error: ${e.message}');
    }

    final text = buf.toString();
    if (text.trim().isEmpty) {
      throw OpenRouterException('The model returned an empty response.');
    }
    return text;
  }

  /// Text-to-speech as raw 16-bit mono PCM, with the sample rate the provider
  /// reports in its `Content-Type` (e.g. `audio/pcm;rate=44100`); providers
  /// differ, and playing at the wrong rate shifts speed and pitch.
  Future<({Uint8List bytes, int sampleRate})> speechPcm({
    required String model,
    required String input,
    required String voice,
    String? instructions,
  }) async {
    int? rate;
    final bytes = await speech(
      model: model,
      input: input,
      voice: voice,
      instructions: instructions,
      onContentType: (type) {
        final m = RegExp(r'rate=(\d+)').firstMatch(type);
        if (m != null) rate = int.parse(m.group(1)!);
      },
    );
    return (bytes: bytes, sampleRate: rate ?? 24000);
  }

  /// Text-to-speech via POST /audio/speech. Returns the raw audio bytes.
  Future<Uint8List> speech({
    required String model,
    required String input,
    required String voice,
    String responseFormat = 'pcm',
    double? speed,
    String? instructions,
    void Function(String contentType)? onContentType,
  }) async {
    final req = http.Request('POST', Uri.parse('$_baseUrl/audio/speech'))
      ..headers.addAll(_headers)
      ..body = jsonEncode({
        'model': model,
        'input': input,
        'voice': voice,
        'response_format': responseFormat,
        'speed': ?speed,
        if (instructions != null && instructions.isNotEmpty)
          'instructions': instructions,
      });
    final resp = await _send(req);
    if (resp.statusCode != 200) {
      throw await _errorFromResponse(resp);
    }
    onContentType?.call(resp.headers['content-type'] ?? '');
    try {
      final bytes = await resp.stream.toBytes();
      if (bytes.isEmpty) {
        throw OpenRouterException('The speech service returned no audio.');
      }
      return bytes;
    } on http.ClientException catch (e) {
      throw OpenRouterException('Network error: ${e.message}');
    }
  }

  /// Reasoning models reject or ignore a sampling temperature, so it is only
  /// sent when no reasoning effort is asked for.
  static Map<String, Object> _sampling(double? temperature, String? effort) => {
        if (effort != null && effort.isNotEmpty)
          'reasoning': {'effort': effort}
        else
          'temperature': ?temperature,
      };

  /// Submits [requests] to the Batch API (about half the sync price, answered
  /// within 24 hours, usually minutes). The returned batch is still being
  /// validated; poll [getBatch] until it [BatchInfo.isTerminal].
  Future<BatchInfo> createBatch({
    required String model,
    required List<BatchRequest> requests,
    double? temperature,
    String? reasoningEffort,
  }) async {
    final req = http.Request('POST', Uri.parse('$_baseUrl/batches'))
      ..headers.addAll(_headers)
      // `requests` must come last: OpenRouter reads the body as a stream.
      ..body = jsonEncode({
        'endpoint': '/v1/chat/completions',
        'model': model,
        'requests': [
          for (final r in requests)
            {
              'custom_id': r.customId,
              'body': {
                'messages': [for (final m in r.messages) m.toJson()],
                ..._sampling(temperature, reasoningEffort),
              },
            },
        ],
      });
    final resp = await _send(req);
    if (resp.statusCode != 202 && resp.statusCode != 200) {
      throw await _errorFromResponse(resp, batch: true);
    }
    return _batchFromJson(await _readJson(resp));
  }

  Future<BatchInfo> getBatch(String id) async {
    final req = http.Request(
        'GET', Uri.parse('$_baseUrl/batches/${Uri.encodeComponent(id)}'))
      ..headers.addAll(_headers);
    final resp = await _send(req);
    if (resp.statusCode == 410 || resp.statusCode == 404) {
      await resp.stream.drain<void>();
      return BatchInfo(
        id: id,
        status: BatchInfo.gone,
        error: 'The batch is no longer available on OpenRouter.',
      );
    }
    if (resp.statusCode != 200) {
      throw await _errorFromResponse(resp, batch: true);
    }
    return _batchFromJson(await _readJson(resp), fallbackId: id);
  }

  /// Deletes a finished batch and its stored results. A running batch cannot
  /// be cancelled.
  Future<void> deleteBatch(String id) async {
    final req = http.Request(
        'DELETE', Uri.parse('$_baseUrl/batches/${Uri.encodeComponent(id)}'))
      ..headers.addAll(_headers);
    final resp = await _send(req);
    await resp.stream.drain<void>();
  }

  Future<Map<Object?, Object?>> _readJson(http.StreamedResponse resp) async {
    try {
      final body = utf8.decode(await resp.stream.toBytes());
      final j = jsonDecode(body);
      if (j is Map) return j;
    } on http.ClientException catch (e) {
      throw OpenRouterException('Network error: ${e.message}');
    } on FormatException {
      // fall through
    }
    throw OpenRouterException('OpenRouter sent an unreadable answer.');
  }

  static BatchInfo _batchFromJson(Map<Object?, Object?> j,
      {String? fallbackId}) {
    final id = j['id'] is String ? j['id'] as String : fallbackId;
    final status = j['status'];
    if (id == null || status is! String) {
      throw OpenRouterException('OpenRouter sent an unreadable batch status.');
    }
    final counts = j['request_counts'];
    int count(String k) =>
        counts is Map && counts[k] is num ? (counts[k] as num).toInt() : 0;
    final err = j['error'];
    final usage = j['usage'];
    final expires = j['expires_at'];
    final results = <String, BatchResult>{};
    final list = j['results'];
    if (list is List) {
      for (final r in list) {
        if (r is! Map || r['custom_id'] is! String) continue;
        results[r['custom_id'] as String] = _batchResult(r);
      }
    }
    return BatchInfo(
      id: id,
      status: status,
      error: err is Map && err['message'] is String
          ? err['message'] as String
          : null,
      expiresAt: expires is num
          ? DateTime.fromMillisecondsSinceEpoch(expires.toInt() * 1000)
          : null,
      total: count('total'),
      completed: count('completed'),
      failed: count('failed'),
      cost: usage is Map && usage['cost'] is num
          ? (usage['cost'] as num).toDouble()
          : null,
      results: results,
    );
  }

  static BatchResult _batchResult(Map<Object?, Object?> r) {
    final err = r['error'];
    if (err != null) return BatchResult(error: _describeError(err, null));
    final response = r['response'];
    final body = response is Map ? response['body'] : null;
    if (body is! Map) {
      return const BatchResult(error: 'The request has no answer.');
    }
    if (body['error'] != null) {
      final status = response is Map ? response['status_code'] : null;
      return BatchResult(
          error: _describeError(body['error'], status is int ? status : null));
    }
    final choices = body['choices'];
    final choice = choices is List && choices.isNotEmpty ? choices.first : null;
    final message = choice is Map ? choice['message'] : null;
    final content = message is Map ? message['content'] : null;
    if (content is! String || content.trim().isEmpty) {
      // Reasoning is billed as output, so a cap can be used up before any
      // visible text is written.
      return BatchResult(
          error: choice is Map && choice['finish_reason'] == 'length'
              ? 'The model ran out of output tokens before answering.'
              : 'The model returned an empty response.');
    }
    return BatchResult(text: content);
  }

  void close() {
    if (_ownsClient) _http.close();
  }

  Future<http.StreamedResponse> _send(http.BaseRequest req) async {
    try {
      return await _http.send(req).timeout(firstByteTimeout);
    } on TimeoutException {
      throw OpenRouterException(
          'OpenRouter did not respond in time. Check your connection and try again.');
    } on http.ClientException catch (e) {
      throw OpenRouterException('Network error: ${e.message}');
    } on OpenRouterException {
      rethrow;
    } catch (e) {
      if (e is Exception) {
        throw OpenRouterException('Network error: $e');
      }
      rethrow;
    }
  }

  Future<OpenRouterException> _errorFromResponse(http.StreamedResponse resp,
      {bool batch = false}) async {
    String body = '';
    try {
      body = utf8.decode(await resp.stream.toBytes(), allowMalformed: true);
    } catch (_) {}
    Object? err;
    try {
      final j = jsonDecode(body);
      if (j is Map) err = j['error'];
    } catch (_) {}
    return OpenRouterException(
      _describeError(err, resp.statusCode, rawBody: body, batch: batch),
      statusCode: resp.statusCode,
    );
  }

  static String _describeError(Object? err, int? status,
      {String rawBody = '', bool batch = false}) {
    String? detail;
    int? code = status;
    if (err is Map) {
      final m = err['message'];
      if (m is String && m.isNotEmpty) detail = m;
      if (code == null && err['code'] is int) code = err['code'] as int;
    } else if (err is String && err.isNotEmpty) {
      detail = err;
    }
    detail ??= rawBody.trim().isNotEmpty && rawBody.length < 300
        ? rawBody.trim()
        : null;

    final String base;
    switch (code) {
      case 400 when batch:
        base = 'OpenRouter did not accept the batch. The model may have no '
            'batch variant; pick another model or turn batch off in Settings.';
      case 413 when batch:
        base = 'The batch is too large.';
      case 429 when batch:
        base = 'Too many batches are in progress on your OpenRouter account. '
            'Try again when some have finished.';
      case 401:
        base = 'Invalid API key. Check your OpenRouter key in Settings.';
      case 402:
        base = 'Insufficient OpenRouter credits. Add credits and try again.';
      case 404:
        base = 'Model not found. Check the model name in Settings.';
      case 429:
        base = 'Rate limited by OpenRouter. Wait a moment and try again.';
      case 408:
        base = 'The request timed out. Please try again.';
      case 502:
      case 503:
        base = 'The model provider is unavailable. Try again or pick another model.';
      default:
        base = code != null
            ? 'OpenRouter error ($code).'
            : 'OpenRouter error.';
    }
    return detail == null || base.contains(detail) ? base : '$base ($detail)';
  }
}
