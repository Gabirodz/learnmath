import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:learnmath/books/pdf_source.dart';
import 'package:pdfrx/pdfrx.dart' show Pdfrx;
import 'package:pdf/widgets.dart' as pw;

/// pdfium is only available to flutter_test when pointed at explicitly:
/// set PDFIUM_PATH, or build the app once so build/native_assets exists.
String? _pdfiumPath() {
  final env = Platform.environment['PDFIUM_PATH'];
  if (env != null && File(env).existsSync()) return env;
  const built = 'build/native_assets/linux/libpdfium.so';
  return File(built).existsSync() ? File(built).absolute.path : null;
}

void main() {
  final pdfium = _pdfiumPath();
  test(
    'PdfSource reads outline, text and renders PNG',
    () async {
      TestWidgetsFlutterBinding.ensureInitialized();
      Pdfrx.pdfiumModulePath = pdfium;
      final tmp = Directory.systemTemp.createTempSync('pdfrx_cache').path;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('plugins.flutter.io/path_provider'),
            (_) async => tmp,
          );
      final doc = pw.Document();
      for (var i = 1; i <= 3; i++) {
        doc.addPage(
          pw.Page(
            build: (_) => pw.Column(
              children: [
                pw.Outline(
                  name: 'p$i',
                  title: 'Chapter $i',
                  level: 0,
                  child: pw.Text('Hello page $i'),
                ),
              ],
            ),
          ),
        );
      }
      final dir = Directory.systemTemp.createTempSync('pdfsrc');
      final f = File('${dir.path}/t.pdf')..writeAsBytesSync(await doc.save());
      PdfSource? src;
      try {
        src = await PdfSource.open(f.path);
        expect(src.pageCount, 3);
        expect(await src.pageText(2), contains('Hello page 2'));
        final png = await src.renderPagePng(1, longSide: 400);
        expect(png.sublist(1, 4), [0x50, 0x4E, 0x47]);
        final o = await src.outline();
        expect(o.map((e) => (e.title, e.page, e.level)), [
          ('Chapter 1', 1, 0),
          ('Chapter 2', 2, 0),
          ('Chapter 3', 3, 0),
        ]);
      } finally {
        await src?.close();
        dir.deleteSync(recursive: true);
      }
    },
    skip: pdfium == null ? 'libpdfium not found (set PDFIUM_PATH)' : null,
    timeout: const Timeout(Duration(seconds: 60)),
  );
}
