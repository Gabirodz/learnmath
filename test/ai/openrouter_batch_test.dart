import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:learnmath/ai/openrouter_client.dart';

http.StreamedResponse _json(Object body, [int status = 200]) =>
    http.StreamedResponse(
        Stream.value(utf8.encode(body is String ? body : jsonEncode(body))),
        status);

OpenRouterClient _client(http.Client c) =>
    OpenRouterClient(apiKey: 'k', httpClient: c);

const _submitted = {
  'id': 'batch_123',
  'object': 'batch',
  'endpoint': '/v1/chat/completions',
  'model': 'openai/gpt-6.1-sol',
  'completion_window': '24h',
  'status': 'validating',
  'created_at': 1782097200,
  'finalized_at': null,
  'provider': 'OpenAI',
  'expires_at': 1782183600,
  'request_counts': {'total': 2, 'completed': 0, 'failed': 0},
  'usage': null,
  'results': null,
  'error': null,
};

Map<String, Object?> _ok(String id, String text,
        {String finish = 'stop', int status = 200}) =>
    {
      'custom_id': id,
      'id': 'batch_req_$id',
      'response': {
        'status_code': status,
        'request_id': 'req_1',
        'body': {
          'choices': [
            {
              'finish_reason': finish,
              'index': 0,
              'message': {'role': 'assistant', 'content': text},
            }
          ],
          'usage': {'prompt_tokens': 3, 'completion_tokens': 4},
        },
      },
    };

Future<OpenRouterException> _thrown(Future<Object?> f) async {
  try {
    await f;
  } on OpenRouterException catch (e) {
    return e;
  }
  fail('expected an OpenRouterException');
}

void main() {
  group('chat() reasoning effort', () {
    Future<Map<String, Object?>> chatBody(
        {double? temperature, String? effort, int? maxTokens}) async {
      late String body;
      final mock = MockClient.streaming((req, s) async {
        body = await s.bytesToString();
        return http.StreamedResponse(
            Stream.value(utf8.encode(
                'data: ${jsonEncode({'choices': [{'delta': {'content': 'x'}}]})}\n\ndata: [DONE]\n\n')),
            200);
      });
      await _client(mock).chat(
        model: 'm',
        messages: const [ChatMessage.user('hi')],
        temperature: temperature,
        reasoningEffort: effort,
        maxTokens: maxTokens,
      );
      return (jsonDecode(body) as Map).cast<String, Object?>();
    }

    test('effort sends reasoning and omits temperature', () async {
      final j = await chatBody(temperature: 0.5, effort: 'high');
      expect(j['reasoning'], {'effort': 'high'});
      expect(j.containsKey('temperature'), isFalse);
    });

    test('without effort temperature is sent and reasoning is not', () async {
      final j = await chatBody(temperature: 0.5);
      expect(j['temperature'], 0.5);
      expect(j.containsKey('reasoning'), isFalse);
    });

    test('empty effort counts as none', () async {
      final j = await chatBody(temperature: 0.2, effort: '');
      expect(j['temperature'], 0.2);
      expect(j.containsKey('reasoning'), isFalse);
    });

    test('neither temperature nor effort sends neither', () async {
      final j = await chatBody();
      expect(j.containsKey('temperature'), isFalse);
      expect(j.containsKey('reasoning'), isFalse);
      expect(j.containsKey('max_tokens'), isFalse);
    });

    test('maxTokens is sent when given', () async {
      expect((await chatBody(maxTokens: 99))['max_tokens'], 99);
    });
  });

  group('createBatch', () {
    test('request shape, key order, headers, parsed response', () async {
      late http.BaseRequest seen;
      late String raw;
      final mock = MockClient.streaming((req, s) async {
        seen = req;
        raw = await s.bytesToString();
        return _json(_submitted, 202);
      });
      final info = await _client(mock).createBatch(
        model: 'openai/gpt-6.1-sol',
        temperature: 0.3,
        requests: const [
          BatchRequest(customId: 'a:0', messages: [
            ChatMessage.system('sys'),
            ChatMessage.user('one'),
          ]),
          BatchRequest(customId: 'b:0', messages: [ChatMessage.user('two')]),
        ],
      );
      expect(seen.method, 'POST');
      expect(seen.url.toString(), 'https://openrouter.ai/api/v1/batches');
      expect(seen.headers['Authorization'], 'Bearer k');
      expect(seen.headers['Content-Type'], 'application/json');
      expect(seen.headers['X-Title'], 'LearnMath');

      final j = jsonDecode(raw) as Map;
      expect(j.keys.toList(), ['endpoint', 'model', 'requests']);
      expect(j['endpoint'], '/v1/chat/completions');
      expect(j['model'], 'openai/gpt-6.1-sol');
      final reqs = j['requests'] as List;
      expect(reqs, hasLength(2));
      expect((reqs[0] as Map)['custom_id'], 'a:0');
      final body0 = (reqs[0] as Map)['body'] as Map;
      expect(body0['messages'], [
        {'role': 'system', 'content': 'sys'},
        {'role': 'user', 'content': 'one'},
      ]);
      expect(body0['temperature'], 0.3);
      expect(body0.containsKey('model'), isFalse);
      expect(body0.containsKey('stream'), isFalse);
      expect(((reqs[1] as Map)['body'] as Map)['messages'], [
        {'role': 'user', 'content': 'two'},
      ]);

      expect(info.id, 'batch_123');
      expect(info.status, 'validating');
      expect(info.total, 2);
      expect(info.completed, 0);
      expect(info.failed, 0);
      expect(info.isTerminal, isFalse);
      expect(info.results, isEmpty);
      expect(info.cost, isNull);
      expect(info.error, isNull);
      expect(info.expiresAt!.millisecondsSinceEpoch, 1782183600 * 1000);
    });

    test('requests is the last key even with effort set', () async {
      late String raw;
      final mock = MockClient.streaming((req, s) async {
        raw = await s.bytesToString();
        return _json(_submitted, 202);
      });
      await _client(mock).createBatch(
        model: 'm',
        temperature: 0.5,
        reasoningEffort: 'high',
        requests: const [
          BatchRequest(customId: 'a', messages: [ChatMessage.user('x')]),
        ],
      );
      final j = jsonDecode(raw) as Map;
      expect(j.keys.last, 'requests');
      final body = ((j['requests'] as List).single as Map)['body'] as Map;
      expect(body['reasoning'], {'effort': 'high'});
      expect(body.containsKey('temperature'), isFalse);
    });

    test('images are embedded as data urls like in chat', () async {
      late String raw;
      final mock = MockClient.streaming((req, s) async {
        raw = await s.bytesToString();
        return _json(_submitted, 202);
      });
      await _client(mock).createBatch(model: 'm', requests: [
        BatchRequest(customId: 'a', messages: [
          ChatMessage.userWithImages('look', [
            Uint8List.fromList([1, 2, 3])
          ]),
        ]),
      ]);
      expect(raw, contains('data:image/png;base64,AQID'));
    });

    test('accepts 200 as well as 202', () async {
      final mock = MockClient.streaming((r, s) async => _json(_submitted, 200));
      final info = await _client(mock).createBatch(model: 'm', requests: const [
        BatchRequest(customId: 'a', messages: [ChatMessage.user('x')]),
      ]);
      expect(info.id, 'batch_123');
    });

    for (final c in {
      400: 'did not accept the batch',
      413: 'too large',
      429: 'Too many batches',
    }.entries) {
      test('status ${c.key} gives the batch-specific message', () async {
        final mock = MockClient.streaming((r, s) async => _json({
              'error': {'message': 'provider detail', 'code': c.key}
            }, c.key));
        final e = await _thrown(_client(mock).createBatch(
            model: 'm',
            requests: const [
              BatchRequest(customId: 'a', messages: [ChatMessage.user('x')]),
            ]));
        expect(e.statusCode, c.key);
        expect(e.message, contains(c.value));
        expect(e.message, contains('provider detail'));
      });
    }

    test('429 on submit is not the generic rate-limit text', () async {
      final mock = MockClient.streaming((r, s) async => _json('', 429));
      final e = await _thrown(_client(mock).createBatch(
          model: 'm',
          requests: const [
            BatchRequest(customId: 'a', messages: [ChatMessage.user('x')]),
          ]));
      expect(e.message, isNot(contains('Wait a moment')));
    });

    test('401 and 402 keep their generic messages', () async {
      for (final c in {401: 'Invalid API key', 402: 'credits'}.entries) {
        final mock = MockClient.streaming((r, s) async => _json('', c.key));
        final e = await _thrown(_client(mock).createBatch(
            model: 'm',
            requests: const [
              BatchRequest(customId: 'a', messages: [ChatMessage.user('x')]),
            ]));
        expect(e.message, contains(c.value));
      }
    });

    test('unreadable success body is an OpenRouterException', () async {
      final mock = MockClient.streaming((r, s) async => _json('<html>', 202));
      final e = await _thrown(_client(mock).createBatch(
          model: 'm',
          requests: const [
            BatchRequest(customId: 'a', messages: [ChatMessage.user('x')]),
          ]));
      expect(e.message, contains('unreadable'));
    });

    test('network failure becomes OpenRouterException', () async {
      final mock = MockClient.streaming(
          (r, s) async => throw http.ClientException('offline'));
      final e = await _thrown(_client(mock).createBatch(
          model: 'm',
          requests: const [
            BatchRequest(customId: 'a', messages: [ChatMessage.user('x')]),
          ]));
      expect(e.message, contains('Network error'));
    });
  });

  group('getBatch', () {
    Future<BatchInfo> get(Map<String, Object?> body) => _client(
            MockClient.streaming((r, s) async => _json(body)))
        .getBatch('batch_123');

    test('GET to /batches/{id}, id is URL encoded', () async {
      late http.BaseRequest seen;
      final mock = MockClient.streaming((req, s) async {
        seen = req;
        return _json(_submitted);
      });
      await _client(mock).getBatch('a/b c');
      expect(seen.method, 'GET');
      expect(seen.url.toString(),
          'https://openrouter.ai/api/v1/batches/a%2Fb%20c');
      expect(seen.headers['Authorization'], 'Bearer k');
    });

    test('in-progress batch has no results and is not terminal', () async {
      for (final s in ['validating', 'in_progress', 'finalizing']) {
        final info = await get({..._submitted, 'status': s});
        expect(info.status, s);
        expect(info.isTerminal, isFalse, reason: s);
        expect(info.isDone, isFalse, reason: s);
      }
    });

    test('completed batch: cost, counts, results by custom id', () async {
      final info = await get({
        ..._submitted,
        'status': 'completed',
        'request_counts': {'total': 3, 'completed': 2, 'failed': 1},
        'usage': {'cost': 0.0123, 'prompt_tokens': 10},
        'results': [
          _ok('l1:0', 'Answer one'),
          {
            'custom_id': 'l2:0',
            'error': {
              'message': 'Too fast',
              'type': 'rate_limit',
              'error_type': 'rate_limit_exceeded',
            },
          },
          _ok('l3:0', 'Answer three'),
        ],
      });
      expect(info.isDone, isTrue);
      expect(info.isTerminal, isTrue);
      expect(info.cost, closeTo(0.0123, 1e-12));
      expect(info.total, 3);
      expect(info.completed, 2);
      expect(info.failed, 1);
      expect(info.results.keys, {'l1:0', 'l2:0', 'l3:0'});
      expect(info.results['l1:0']!.text, 'Answer one');
      expect(info.results['l1:0']!.error, isNull);
      expect(info.results['l2:0']!.text, isNull);
      expect(info.results['l2:0']!.error, contains('Too fast'));
      expect(info.results['l3:0']!.text, 'Answer three');
    });

    test('integer cost is accepted', () async {
      final info = await get({
        ..._submitted,
        'status': 'completed',
        'usage': {'cost': 1},
      });
      expect(info.cost, 1.0);
    });

    test('failed batch carries error.message', () async {
      final info = await get({
        ..._submitted,
        'status': 'failed',
        'error': {'message': 'Invalid request on line 2'},
      });
      expect(info.status, 'failed');
      expect(info.isTerminal, isTrue);
      expect(info.isDone, isFalse);
      expect(info.error, 'Invalid request on line 2');
    });

    test('expired and cancelled are terminal but not done', () async {
      for (final s in ['expired', 'cancelled']) {
        final info = await get({..._submitted, 'status': s});
        expect(info.isTerminal, isTrue, reason: s);
        expect(info.isDone, isFalse, reason: s);
      }
    });

    test('empty content with finish_reason length has a specific error',
        () async {
      final info = await get({
        ..._submitted,
        'status': 'completed',
        'results': [
          _ok('a', '', finish: 'length'),
          _ok('b', '   ', finish: 'stop'),
        ],
      });
      final a = info.results['a']!;
      expect(a.text, isNull);
      expect(a.error, contains('ran out of output tokens'));
      final b = info.results['b']!;
      expect(b.error, contains('empty response'));
      expect(b.error, isNot(contains('ran out')));
    });

    test('null content (reasoning only) is handled', () async {
      final info = await get({
        ..._submitted,
        'status': 'completed',
        'results': [
          {
            'custom_id': 'a',
            'response': {
              'status_code': 200,
              'body': {
                'choices': [
                  {
                    'finish_reason': 'length',
                    'message': {'role': 'assistant', 'content': null},
                  }
                ]
              },
            },
          }
        ],
      });
      expect(info.results['a']!.error, contains('ran out of output tokens'));
    });

    test('per-request HTTP error inside response.body is an error', () async {
      final info = await get({
        ..._submitted,
        'status': 'completed',
        'results': [
          {
            'custom_id': 'a',
            'response': {
              'status_code': 402,
              'body': {
                'error': {'message': 'no credit'}
              },
            },
          }
        ],
      });
      final r = info.results['a']!;
      expect(r.text, isNull);
      expect(r.error, contains('credits'));
    });

    test('a non-200 status_code without a body error is not a success',
        () async {
      final info = await get({
        ..._submitted,
        'status': 'completed',
        'results': [
          {
            'custom_id': 'a',
            'response': {'status_code': 500, 'body': null},
          }
        ],
      });
      expect(info.results['a']!.text, isNull);
      expect(info.results['a']!.error, isNotNull);
    });

    test('results without a custom id are skipped', () async {
      final info = await get({
        ..._submitted,
        'status': 'completed',
        'results': [
          {'response': {}},
          _ok('ok', 'fine'),
        ],
      });
      expect(info.results.keys, ['ok']);
    });

    test('404 and 410 mean the batch is gone', () async {
      for (final code in [404, 410]) {
        final mock = MockClient.streaming(
            (r, s) async => _json({'error': {'message': 'gone'}}, code));
        final info = await _client(mock).getBatch('batch_x');
        expect(info.status, BatchInfo.gone, reason: '$code');
        expect(info.id, 'batch_x');
        expect(info.isTerminal, isTrue);
        expect(info.isDone, isFalse);
        expect(info.error, isNotNull);
      }
    });

    test('other errors throw with batch wording where applicable', () async {
      final mock = MockClient.streaming((r, s) async => _json('', 429));
      final e = await _thrown(_client(mock).getBatch('b'));
      expect(e.statusCode, 429);
      final mock2 = MockClient.streaming((r, s) async => _json('', 401));
      final e2 = await _thrown(_client(mock2).getBatch('b'));
      expect(e2.message, contains('Invalid API key'));
    });

    test('a 500 on polling is an exception, not "gone"', () async {
      final mock = MockClient.streaming((r, s) async => _json('', 500));
      final e = await _thrown(_client(mock).getBatch('b'));
      expect(e.statusCode, 500);
    });

    test('body without a status is rejected', () async {
      final e = await _thrown(get({'id': 'batch_123'}));
      expect(e.message, contains('unreadable'));
    });

    test('missing id falls back to the requested one', () async {
      final info = await get({'status': 'in_progress'});
      expect(info.id, 'batch_123');
    });
  });

  group('deleteBatch', () {
    test('sends DELETE to /batches/{id}', () async {
      late http.BaseRequest seen;
      final mock = MockClient.streaming((req, s) async {
        seen = req;
        return _json({'deleted': true});
      });
      await _client(mock).deleteBatch('batch_123');
      expect(seen.method, 'DELETE');
      expect(seen.url.toString(),
          'https://openrouter.ai/api/v1/batches/batch_123');
      expect(seen.headers['Authorization'], 'Bearer k');
    });
  });
}
