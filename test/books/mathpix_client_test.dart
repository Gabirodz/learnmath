import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:learnmath/books/mathpix_client.dart';
import 'package:learnmath/tts/lecture_audio_builder.dart';

void main() {
  late Directory dir;
  late String pdf;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('mathpix_test');
    final f = File('${dir.path}/book.pdf')..writeAsBytesSync([37, 80, 68, 70, 45]);
    pdf = f.path;
  });
  tearDown(() => dir.deleteSync(recursive: true));

  MathpixClient make(MockClient c) => MathpixClient(
      appId: 'id1',
      appKey: 'key1',
      httpClient: c,
      pollInterval: Duration.zero);

  test('happy path', () async {
    final seen = <String>[];
    var polls = 0;
    http.BaseRequest? upload;
    String? uploadBody;
    final client = MockClient.streaming((req, body) async {
      seen.add('${req.method} ${req.url.path}');
      expect(req.headers['app_id'], 'id1');
      expect(req.headers['app_key'], 'key1');
      String json(Object o, [int code = 200]) => jsonEncode(o);
      http.StreamedResponse resp(String b, [int code = 200]) =>
          http.StreamedResponse(Stream.value(utf8.encode(b)), code,
              headers: {'content-type': 'application/json; charset=utf-8'});
      if (req.method == 'POST') {
        upload = req;
        uploadBody = utf8.decode(await body.expand((e) => e).toList());
        return resp(json({'pdf_id': 'abc'}));
      }
      if (req.url.path == '/v3/pdf/abc') {
        polls++;
        return resp(json(polls < 2
            ? {'status': 'split', 'percent_done': 50.0}
            : {'status': 'completed', 'percent_done': 100}));
      }
      if (req.url.path == '/v3/pdf/abc.mmd') {
        return resp('# Intro \\(x\\)\n\\pagebreak\nSecond \\[a=b\\]\n\\pagebreak\nThird\n\\pagebreak\n');
      }
      return resp('{}', 404);
    });
    final progress = <double?>[];
    final out = await make(client).transcribePages(
        pdfPath: pdf, startPage: 3, endPage: 5, onProgress: progress.add);
    expect(seen.first, 'POST /v3/pdf');
    expect(upload, isNotNull);
    expect(uploadBody, contains('name="options_json"'));
    expect(uploadBody, contains('"page_ranges":"3-5"'));
    expect(uploadBody, contains('name="file"'));
    expect(progress, containsAllInOrder([0.5, 1.0]));
    expect(
        out,
        '[[page 3]]\n\n# Intro \$x\$\n\n'
        '[[page 4]]\n\nSecond\n\n\$\$\na=b\n\$\$\n\n'
        '[[page 5]]\n\nThird');
  });

  test('error status', () async {
    final client = MockClient((req) async {
      if (req.method == 'POST') return http.Response('{"pdf_id":"z"}', 200);
      return http.Response(
          '{"status":"error","error_info":{"id":"x","message":"bad pdf"}}', 200);
    });
    expect(
        make(client).transcribePages(pdfPath: pdf, startPage: 1, endPage: 1),
        throwsA(isA<MathpixException>()
            .having((e) => e.message, 'message', contains('bad pdf'))));
  });

  test('401', () async {
    final client = MockClient((req) async => http.Response(
        '{"error":"nope","error_info":{"id":"auth_error"}}', 401));
    expect(
        make(client).transcribePages(pdfPath: pdf, startPage: 1, endPage: 1),
        throwsA(isA<MathpixException>().having((e) => e.message, 'message',
            'Mathpix rejected the credentials. Check the app id and key in Settings.')));
  });

  test('network error', () async {
    final client = MockClient((req) async => throw const SocketException('x'));
    expect(
        make(client).transcribePages(pdfPath: pdf, startPage: 1, endPage: 1),
        throwsA(isA<MathpixException>()
            .having((e) => e.message, 'message', 'No connection to Mathpix.')));
  });

  test('cancellation', () async {
    final client = MockClient((req) async {
      if (req.method == 'POST') return http.Response('{"pdf_id":"z"}', 200);
      return http.Response('{"status":"split"}', 200);
    });
    var n = 0;
    expect(
        make(client).transcribePages(
            pdfPath: pdf, startPage: 1, endPage: 1, isCancelled: () => ++n > 2),
        throwsA(isA<GenerationCancelled>()));
  });

  group('mathpixToMarkdown', () {
    test('delimiters', () {
      expect(mathpixToMarkdown(r'a \(x^2\) b'), r'a $x^2$ b');
      expect(mathpixToMarkdown('a\n\$\$x=1\$\$\nb'), 'a\n\n\$\$\nx=1\n\$\$\n\nb');
    });
    test('headings', () {
      expect(mathpixToMarkdown(r'\title{Big}'), '# Big');
      expect(mathpixToMarkdown(r'\section*{One {x}}'), '## One {x}');
      expect(mathpixToMarkdown(r'\subsection{Two}'), '### Two');
    });
    test('images and figures', () {
      expect(mathpixToMarkdown('a ![](https://x/y.jpg) b'), 'a  b');
      expect(
          mathpixToMarkdown('\\begin{figure}\n![](u)\n\\caption{Fig 1. A graph}\n\\end{figure}'),
          'Fig 1. A graph');
      expect(mathpixToMarkdown('\\begin{figure}\n![](u)\n\\end{figure}'), '');
    });
    test('theorem and footnote', () {
      expect(mathpixToMarkdown('\\begin{theorem}[Pythagoras]\n\$a\$ holds\n\\end{theorem}'),
          '**Theorem (Pythagoras).** \$a\$ holds');
      expect(mathpixToMarkdown(r'Text\footnotetext{1 note {b}} more'), 'Text more');
    });
    test('lists', () {
      expect(mathpixToMarkdown('\\begin{itemize}\n\\item A\n\\item B\n\\end{itemize}'),
          '- A\n- B');
    });
  });
}
