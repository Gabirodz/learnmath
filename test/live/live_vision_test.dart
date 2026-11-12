// Live check of book-page transcription. Skipped unless OPENROUTER_API_KEY
// and LIVE_PDF (a PDF path) are set. Optional: LIVE_VISION_MODEL,
// LIVE_PAGES ("1-3"), LIVE_OUT. Needs pdfium (see pdf_source_test.dart).
@TestOn('vm')
@Timeout(Duration(minutes: 10))
library;

import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:learnmath/books/transcriber.dart';
import 'package:learnmath/core/models.dart';
import 'package:pdfrx/pdfrx.dart' show Pdfrx;

void main() {
  final env = Platform.environment;
  final key = env['OPENROUTER_API_KEY'];
  final pdf = env['LIVE_PDF'];
  const built = 'build/native_assets/linux/libpdfium.so';
  final pdfium = env['PDFIUM_PATH'] ??
      (File(built).existsSync() ? File(built).absolute.path : null);

  test('transcribes pages with the vision model', () async {
    TestWidgetsFlutterBinding.ensureInitialized();
    HttpOverrides.global = null; // allow real network under flutter_test
    Pdfrx.pdfiumModulePath = pdfium;
    final tmp = Directory.systemTemp.createTempSync('pdfrx_cache').path;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('plugins.flutter.io/path_provider'),
            (_) async => tmp);
    final range = (env['LIVE_PAGES'] ?? '1-2').split('-').map(int.parse).toList();
    final sw = Stopwatch()..start();
    final text = await ChapterTranscriber.transcribe(
      settings: AppSettings(
        apiKey: key!,
        visionModel: env['LIVE_VISION_MODEL'] ?? AppSettings.defaultVisionModel,
      ),
      pdfPath: pdf!,
      chapter: Lesson(
        id: 'x',
        title: 'Chapter',
        brief: '',
        createdAt: DateTime.now(),
        sourceStartPage: range.first,
        sourceEndPage: range.last,
      ),
      // ignore: avoid_print
      onProgress: (label, f) => print(label),
    );
    // ignore: avoid_print
    print('${text.length} chars in ${sw.elapsed.inSeconds}s');
    final out = env['LIVE_OUT'];
    if (out != null) File('$out/transcription.md').writeAsStringSync(text);
    expect(text, contains('[[page ${range.first}]]'));
    expect(text, contains(r'$'));
  }, skip: key == null || pdf == null || pdfium == null
      ? 'needs OPENROUTER_API_KEY, LIVE_PDF and pdfium'
      : false);
}
