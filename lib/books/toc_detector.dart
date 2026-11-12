import 'dart:typed_data';

import '../ai/openrouter_client.dart';
import 'chapter_plan.dart';
import 'pdf_source.dart';

const _system = 'You read the front matter of a mathematics textbook and extract '
    'its table of contents. Answer ONLY in the exact line format requested.';

/// Asks a vision/text model to read the printed table of contents.
Future<List<ChapterPlan>> detectChaptersWithAi({
  required PdfSource pdf,
  required OpenRouterClient client,
  required String model,
  void Function(String status)? onStatus,
}) async {
  final n = pdf.pageCount < 20 ? pdf.pageCount : 20;
  onStatus?.call('Reading the first $n pages…');
  final texts = <String>[];
  for (var i = 1; i <= n; i++) {
    texts.add((await pdf.pageText(i)).trim());
  }
  final withText = texts.where((t) => t.length >= 200).length;
  final useText = withText >= (n * 0.6).ceil();

  const format = 'Find the table of contents. Reply with exactly these lines and '
      'nothing else:\n'
      'OFFSET: <the PDF page number of the page that is printed as page 1, minus 1; 0 if unknown>\n'
      'CHAPTER: <chapter title> | <printed page number where it starts>\n'
      'List chapter-level entries only (not sections, not front/back matter such as '
      'preface, index or bibliography), in book order, one CHAPTER line each. '
      'Page numbers must be plain integers as printed in the book.';

  final ChatMessage message;
  if (useText) {
    final b = StringBuffer('$format\n\nThe book has ${pdf.pageCount} PDF pages. '
        'Text of the first $n pages follows.\n\n');
    for (var i = 0; i < n; i++) {
      final t = texts[i];
      b.writeln('--- PDF page ${i + 1} ---');
      b.writeln(t.length > 4000 ? t.substring(0, 4000) : t);
    }
    message = ChatMessage.user(b.toString());
  } else {
    final count = n < 12 ? n : 12;
    final images = <Uint8List>[];
    for (var i = 1; i <= count; i++) {
      onStatus?.call('Rendering page $i of $count…');
      images.add(await pdf.renderPagePng(i, longSide: 1100));
    }
    message = ChatMessage.userWithImages(
        '$format\n\nThe book has ${pdf.pageCount} PDF pages. The attached images are '
        'PDF pages 1 to $count in order.',
        images);
  }

  onStatus?.call('Asking the AI to find the chapters…');
  final raw = await client.chat(
    model: model,
    messages: [const ChatMessage.system(_system), message],
    temperature: 0,
  );
  return parseTocResponse(raw, pdf.pageCount);
}
