import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:learnmath/ai/openrouter_client.dart';

http.StreamedResponse _resp(List<List<int>> chunks, {int status = 200}) =>
    http.StreamedResponse(Stream.fromIterable(chunks), status);

String _d(String c) =>
    'data: ${jsonEncode({'choices': [{'delta': {'content': c}}]})}\n\n';

OpenRouterClient _client(http.Client c) =>
    OpenRouterClient(apiKey: 'k', httpClient: c);

void main() {
  test('parses SSE, keep-alives, DONE, progress, request shape', () async {
    late http.BaseRequest seen;
    String? body;
    final mock = MockClient.streaming((req, bodyStream) async {
      seen = req;
      body = await bodyStream.bytesToString();
      return _resp([
        utf8.encode(': OPENROUTER PROCESSING\n\n'),
        utf8.encode(_d('Hello')),
        utf8.encode(_d(' world')),
        utf8.encode('data: [DONE]\n\n'),
        utf8.encode(_d('ignored')),
      ]);
    });
    final progress = <int>[];
    final text = await _client(mock).chat(
      model: 'm',
      messages: const [ChatMessage.user('hi')],
      onProgress: progress.add,
    );
    expect(text, 'Hello world');
    expect(progress, [5, 11]);
    expect(seen.url.toString(), 'https://openrouter.ai/api/v1/chat/completions');
    expect(seen.headers['Authorization'], 'Bearer k');
    expect(seen.headers['X-Title'], 'LearnMath');
    final j = jsonDecode(body!) as Map;
    expect(j['stream'], true);
    expect(j['model'], 'm');
  });

  test('handles lines and UTF-8 split across chunks', () async {
    final all = utf8.encode('${_d('héllo ∫')}${_d(' ok')}data: [DONE]\n\n');
    // Split into 3-byte chunks, which cuts multi-byte characters.
    final chunks = <List<int>>[
      for (var i = 0; i < all.length; i += 3)
        all.sublist(i, i + 3 > all.length ? all.length : i + 3),
    ];
    final mock = MockClient.streaming((r, b) async => _resp(chunks));
    final text = await _client(mock)
        .chat(model: 'm', messages: const [ChatMessage.user('x')]);
    expect(text, 'héllo ∫ ok');
  });

  test('mid-stream error throws', () async {
    final mock = MockClient.streaming((r, b) async => _resp([
          utf8.encode(_d('part')),
          utf8.encode('data: {"error":{"code":500,"message":"boom"}}\n\n'),
        ]));
    expect(
      _client(mock).chat(model: 'm', messages: const [ChatMessage.user('x')]),
      throwsA(isA<OpenRouterException>()
          .having((e) => e.toString(), 'msg', contains('boom'))),
    );
  });

  for (final c in {
    401: 'Invalid API key',
    402: 'credits',
    404: 'Model not found',
    429: 'Rate limited',
  }.entries) {
    test('status ${c.key} maps to helpful message', () async {
      final mock = MockClient.streaming((r, b) async => _resp([
            utf8.encode('{"error":{"message":"detail","code":${c.key}}}')
          ], status: c.key));
      expect(
        _client(mock).chat(model: 'm', messages: const [ChatMessage.user('x')]),
        throwsA(isA<OpenRouterException>()
            .having((e) => e.statusCode, 'status', c.key)
            .having((e) => e.toString(), 'msg', contains(c.value))),
      );
    });
  }

  test('speech returns bytes and sends body', () async {
    String? body;
    final mock = MockClient.streaming((r, b) async {
      body = await b.bytesToString();
      expect(r.url.path, endsWith('/audio/speech'));
      return _resp([
        [1, 2],
        [3, 4]
      ]);
    });
    final bytes = await _client(mock)
        .speech(model: 'm', input: 'hi', voice: 'alloy', speed: 1.1);
    expect(bytes, [1, 2, 3, 4]);
    final j = jsonDecode(body!) as Map;
    expect(j['response_format'], 'pcm');
    expect(j['speed'], 1.1);
    expect(j.containsKey('instructions'), isFalse);
  });
}
