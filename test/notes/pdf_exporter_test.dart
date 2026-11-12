import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:learnmath/notes/pdf_exporter.dart';

import 'sample.dart';

/// Serves `assets/fonts/*` from disk (pubspec does not need to declare them
/// for this test) by intercepting the asset channel.
void _mockFontAssets() {
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMessageHandler('flutter/assets', (ByteData? message) async {
    final key = const StringCodec().decodeMessage(message)!;
    final f = File(Uri.decodeFull(key));
    if (key.startsWith('assets/fonts/') && f.existsSync()) {
      final b = f.readAsBytesSync();
      return ByteData.view(Uint8List.fromList(b).buffer);
    }
    return null;
  });
}

Future<void> _loadKatexFonts() async {
  final home = Platform.environment['HOME']!;
  final dir = Directory('$home/.pub-cache/hosted/pub.dev/flutter_math_fork-0.7.4/lib/katex_fonts/fonts');
  if (!dir.existsSync()) return;
  final byFamily = <String, List<File>>{};
  for (final f in dir.listSync().whereType<File>()) {
    final name = f.uri.pathSegments.last;
    final family = name.split('-').first;
    byFamily.putIfAbsent(family, () => []).add(f);
  }
  for (final e in byFamily.entries) {
    final loader = FontLoader('packages/flutter_math_fork/${e.key}');
    for (final f in e.value) {
      loader.addFont(Future.value(ByteData.view(f.readAsBytesSync().buffer)));
    }
    await loader.load();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('PdfExporter.build produces a valid multi-element PDF',
      (tester) async {
    _mockFontAssets();
    await _loadKatexFonts();
    final bytes = await tester.runAsync(() => PdfExporter.build(
          title: 'Compactness in Metric Spaces',
          subtitle: 'Lecture 3',
          markdown: sampleNotesHard,
        ));
    expect(bytes, isNotNull);
    expect(String.fromCharCodes(bytes!.take(5)), '%PDF-');
    expect(bytes.length, greaterThan(20000));
    final out = Platform.environment['PDF_OUT'];
    if (out != null) File(out).writeAsBytesSync(bytes);
  });
}
