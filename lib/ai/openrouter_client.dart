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
    void Function(int totalChars)? onProgress,
    void Function(String delta)? onDelta,
  }) async {
    final req = http.Request('POST', Uri.parse('$_baseUrl/chat/completions'))
      ..headers.addAll(_headers)
      ..body = jsonEncode({
        'model': model,
        'messages': [for (final m in messages) m.toJson()],
        'stream': true,
        'temperature': ?temperature,
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

  Future<OpenRouterException> _errorFromResponse(
      http.StreamedResponse resp) async {
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
      _describeError(err, resp.statusCode, rawBody: body),
      statusCode: resp.statusCode,
    );
  }

  static String _describeError(Object? err, int? status, {String rawBody = ''}) {
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
