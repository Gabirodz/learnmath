import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:learnmath/ai/openrouter_client.dart';
import 'package:learnmath/ai/prerequisites.dart';
import 'package:learnmath/core/models.dart';

Lesson _lesson(String id, String title) =>
    Lesson(id: id, title: title, brief: '', createdAt: DateTime(2026));

void main() {
  final library = [
    _lesson('a', 'Banach spaces and bounded operators'),
    _lesson('b', 'σ-algebras and measures'),
  ];

  test('covered and missing prerequisites', () {
    final p = parsePrerequisites('''
HAVE: Banach spaces | Banach spaces and bounded operators
MISSING: Weak topologies | Weak and weak-star topologies and the Banach-Alaoglu theorem.
''', library);
    expect(p, hasLength(2));
    expect(p[0].covered, isTrue);
    expect(p[0].lessonId, 'a');
    expect(p[1].covered, isFalse);
    expect(p[1].lessonRequest, startsWith('Weak topologies. Weak and'));
  });

  test('a HAVE with a title that is not in the library counts as missing', () {
    final p = parsePrerequisites(
        'HAVE: Hilbert spaces | Hilbert space theory', library);
    expect(p.single.covered, isFalse);
    expect(p.single.lessonRequest, 'Hilbert spaces');
  });

  test('title matching ignores case and punctuation', () {
    final p = parsePrerequisites(
        '- **HAVE:** Measures | "σ-Algebras and Measures"', library);
    expect(p.single.lessonId, 'b');
  });

  test('NONE and chatter give nothing; at most six are kept', () {
    expect(parsePrerequisites('NONE', library), isEmpty);
    expect(parsePrerequisites('Here is what you need:', library), isEmpty);
    final many = [for (var i = 0; i < 9; i++) 'MISSING: c$i | brief'].join('\n');
    expect(parsePrerequisites(many, library), hasLength(6));
  });

  group('parsePrerequisites edge cases', () {
    test('a | inside the brief is kept', () {
      final p = parsePrerequisites(
          'MISSING: Norms | Covers |x| and ||x|| for vectors.', library);
      expect(p.single.concept, 'Norms');
      expect(p.single.brief, 'Covers |x| and ||x|| for vectors.');
    });

    test('MISSING without a | has the whole line as concept and no brief', () {
      final p = parsePrerequisites('MISSING: Weak topologies', library);
      expect(p.single.concept, 'Weak topologies');
      expect(p.single.covered, isFalse);
      expect(p.single.lessonRequest, 'Weak topologies');
    });

    test('HAVE without a | counts as missing, not covered', () {
      final p = parsePrerequisites('HAVE: Banach spaces', library);
      expect(p.single.covered, isFalse);
      expect(p.single.lessonRequest, 'Banach spaces');
    });

    test('lowercase and mixed-case keys', () {
      final p = parsePrerequisites(
          'have: Measures | σ-algebras and measures\nMissing: X | y.', library);
      expect(p, hasLength(2));
      expect(p[0].lessonId, 'b');
      expect(p[1].brief, 'y.');
    });

    test('HAVE with an empty title is missing', () {
      final p = parsePrerequisites('HAVE: Banach spaces | ', library);
      expect(p.single.covered, isFalse);
    });

    test('an empty concept is dropped', () {
      expect(parsePrerequisites('MISSING: | brief', library), isEmpty);
    });

    test('bullets, bold and CRLF lines', () {
      final p = parsePrerequisites(
          '* **MISSING:** A | a.\r\n- HAVE: B | Banach spaces and bounded operators\r\n',
          library);
      expect(p, hasLength(2));
      expect(p[1].lessonId, 'a');
    });

    test('duplicate titles in the library: a match is still found', () {
      final dup = [
        _lesson('x1', 'Measures'),
        _lesson('x2', 'Measures'),
      ];
      final p = parsePrerequisites('HAVE: Measures | Measures', dup);
      expect(p.single.covered, isTrue);
      expect(['x1', 'x2'], contains(p.single.lessonId));
      expect(p.single.lessonTitle, 'Measures');
    });

    test('a title that normalizes to empty never matches a HAVE', () {
      final odd = [_lesson('z', '???')];
      final p = parsePrerequisites('HAVE: C | !!!', odd);
      expect(p.single.covered, isFalse);
    });
  });

  group('checkPrerequisites', () {
    String sse(String text) =>
        'data: ${jsonEncode({'choices': [{'delta': {'content': text}}]})}\n\ndata: [DONE]\n\n';

    test('one chat request with the lesson model; titles listed; reviews and '
        'untitled excluded; result parsed', () async {
      final bodies = <Map<String, dynamic>>[];
      final mock = MockClient.streaming((req, bodyStream) async {
        bodies.add(jsonDecode(await bodyStream.bytesToString()) as Map<String, dynamic>);
        expect(req.url.path, endsWith('/chat/completions'));
        return http.StreamedResponse(
            Stream.value(utf8.encode(sse(
                'HAVE: Banach | Banach spaces and bounded operators\n'
                'MISSING: Weak topologies | Banach-Alaoglu.'))),
            200);
      });
      final lib = [
        ...library,
        Lesson(
            id: 'r',
            title: 'Review: Banach spaces and bounded operators',
            brief: '',
            createdAt: DateTime(2026),
            recapOf: 'a'),
        _lesson('e', '   '),
      ];
      final out = await checkPrerequisites(
        client: OpenRouterClient(apiKey: 'k', httpClient: mock),
        model: 'some/model',
        request: '  Weak topologies  ',
        library: lib,
      );
      expect(bodies, hasLength(1));
      expect(bodies.single['model'], 'some/model');
      final msgs = (bodies.single['messages'] as List).cast<Map>();
      final user = msgs.last['content'] as String;
      expect(user, contains('Lesson the student wants: Weak topologies'));
      expect(user, contains('- Banach spaces and bounded operators'));
      expect(user, contains('- σ-algebras and measures'));
      expect(user, isNot(contains('Review:')));
      expect('\n- '.allMatches(user).length, 2);
      expect(out, hasLength(2));
      expect(out[0].lessonId, 'a');
      expect(out[1].lessonRequest, 'Weak topologies. Banach-Alaoglu.');
    });

    test('a HAVE pointing at a review title is not covered', () async {
      final mock = MockClient.streaming((req, bodyStream) async {
        await bodyStream.drain<void>();
        return http.StreamedResponse(
            Stream.value(utf8.encode(sse('HAVE: B | Review: Banach'))), 200);
      });
      final out = await checkPrerequisites(
        client: OpenRouterClient(apiKey: 'k', httpClient: mock),
        model: 'm',
        request: 'r',
        library: [
          Lesson(
              id: 'r',
              title: 'Review: Banach',
              brief: '',
              createdAt: DateTime(2026),
              recapOf: 'a'),
        ],
      );
      expect(out.single.covered, isFalse);
    });

    test('empty library says so', () async {
      String? user;
      final mock = MockClient.streaming((req, bodyStream) async {
        final j = jsonDecode(await bodyStream.bytesToString()) as Map;
        user = (j['messages'] as List).last['content'] as String;
        return http.StreamedResponse(Stream.value(utf8.encode(sse('NONE'))), 200);
      });
      final out = await checkPrerequisites(
        client: OpenRouterClient(apiKey: 'k', httpClient: mock),
        model: 'm',
        request: 'r',
        library: const [],
      );
      expect(out, isEmpty);
      expect(user, contains('The library is empty.'));
    });

    test('at most 200 titles are sent', () async {
      String? user;
      final mock = MockClient.streaming((req, bodyStream) async {
        final j = jsonDecode(await bodyStream.bytesToString()) as Map;
        user = (j['messages'] as List).last['content'] as String;
        return http.StreamedResponse(Stream.value(utf8.encode(sse('NONE'))), 200);
      });
      await checkPrerequisites(
        client: OpenRouterClient(apiKey: 'k', httpClient: mock),
        model: 'm',
        request: 'r',
        library: [for (var i = 0; i < 250; i++) _lesson('i$i', 'Title $i')],
      );
      expect('\n- '.allMatches(user!).length, 200);
    });
  });
}
