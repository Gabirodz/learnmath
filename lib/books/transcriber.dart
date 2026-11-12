import 'dart:async';
import 'dart:typed_data';

import '../ai/narration_parser.dart';
import '../ai/openrouter_client.dart';
import '../ai/prompts.dart';
import '../core/models.dart';
import '../tts/lecture_audio_builder.dart';
import 'mathpix_client.dart';
import 'pdf_source.dart';

/// Turns the pages of a book chapter into Markdown + LaTeX, using either a
/// vision model through OpenRouter (one request per page) or Mathpix.
///
/// The result has a `[[page N]]` line before each page's text (when the
/// backend can tell pages apart), which the tutor chat uses to cite pages.
class ChapterTranscriber {
  static const _concurrency = 3;

  static Future<String> transcribe({
    required AppSettings settings,
    required String pdfPath,
    required Lesson chapter,
    void Function(String label, double? fraction)? onProgress,
    bool Function()? isCancelled,
  }) async {
    final start = chapter.sourceStartPage!;
    final end = chapter.sourceEndPage ?? start;
    final String text;
    if (settings.transcriptionBackend == TranscriptionBackend.mathpix) {
      if (!settings.hasMathpix) {
        throw TranscriptionException(
            'Add your Mathpix app id and key in Settings, or switch book '
            'transcription to OpenRouter.');
      }
      final client = MathpixClient(
          appId: settings.mathpixAppId.trim(),
          appKey: settings.mathpixAppKey.trim());
      try {
        onProgress?.call('Sending pages to Mathpix…', null);
        text = await client.transcribePages(
          pdfPath: pdfPath,
          startPage: start,
          endPage: end,
          onProgress: (f) => onProgress?.call('Mathpix is reading the pages…', f),
          isCancelled: isCancelled,
        );
      } finally {
        client.close();
      }
    } else {
      text = await _withVisionModel(
        settings: settings,
        pdfPath: pdfPath,
        chapter: chapter,
        start: start,
        end: end,
        onProgress: onProgress,
        isCancelled: isCancelled,
      );
    }
    final trimmed = cutAtHeading(text, chapter.sourceStopBefore).trim();
    if (trimmed.replaceAll(RegExp(r'\[\[page \d+\]\]'), '').trim().length < 40) {
      throw TranscriptionException(
          'No text could be read from pages $start–$end.');
    }
    return trimmed;
  }

  static Future<String> _withVisionModel({
    required AppSettings settings,
    required String pdfPath,
    required Lesson chapter,
    required int start,
    required int end,
    void Function(String label, double? fraction)? onProgress,
    bool Function()? isCancelled,
  }) async {
    final client = OpenRouterClient(apiKey: settings.apiKey);
    final pdf = await PdfSource.open(pdfPath);
    // Chapter ranges come from bookmarks and can overshoot the file.
    final last = end > pdf.pageCount ? pdf.pageCount : end;
    final total = last - start + 1;
    if (total < 1) {
      await pdf.close();
      client.close();
      throw TranscriptionException('Page $start is not in this book.');
    }
    final pages = List<String?>.filled(total, null);
    var done = 0;
    try {
      onProgress?.call('Reading page 1 of $total…', 0);
      for (var i = 0; i < total; i += _concurrency) {
        if (isCancelled?.call() ?? false) throw const GenerationCancelled();
        await Future.wait([
          for (var k = i; k < i + _concurrency && k < total; k++)
            () async {
              final page = start + k;
              // Rendering is sequential-safe in pdfrx; the model calls overlap.
              final png = await pdf.renderPagePng(page);
              final textLayer = await pdf.pageText(page);
              pages[k] = await _transcribePage(
                client,
                settings.visionModel,
                png: png,
                user: Prompts.transcribeUser(
                  page: page,
                  textLayer: textLayer,
                  startAtHeading: k == 0 && start > 1 ? chapter.title : null,
                  stopBeforeHeading:
                      k == total - 1 ? chapter.sourceStopBefore : null,
                ),
              );
              done++;
              onProgress?.call(
                  'Reading pages… $done of $total', done / total);
            }(),
        ]);
      }
    } finally {
      await pdf.close();
      client.close();
    }

    final out = StringBuffer();
    for (var k = 0; k < total; k++) {
      final t = pages[k]!.trim();
      if (t.isEmpty || t.contains('[[blank]]')) continue;
      out
        ..writeln('[[page ${start + k}]]')
        ..writeln()
        ..writeln(t)
        ..writeln();
    }
    return out.toString();
  }

  static Future<String> _transcribePage(
    OpenRouterClient client,
    String model, {
    required Uint8List png,
    required String user,
  }) async {
    Object? lastError;
    for (var attempt = 0; attempt < 3; attempt++) {
      try {
        final raw = await client.chat(
          model: model,
          temperature: 0,
          messages: [
            const ChatMessage.system(Prompts.transcribeSystem),
            ChatMessage.userWithImages(user, [png]),
          ],
        );
        return cleanNotes(raw);
      } on OpenRouterException catch (e) {
        lastError = e;
        final code = e.statusCode;
        // An empty answer (no status code) or a transient failure: retry.
        final retryable = code == null || code == 429 || code >= 500;
        if (!retryable) rethrow;
        await Future<void>.delayed(Duration(seconds: 2 << attempt));
      }
    }
    throw TranscriptionException('A page could not be read: $lastError');
  }
}

/// Safety net for the last page of a chapter: drops everything from the
/// heading of the next chapter on, if the backend included it. Only looks in
/// the final third of the text so an early mention can't truncate the chapter.
String cutAtHeading(String markdown, String? stopBefore) {
  if (stopBefore == null) return markdown;
  String norm(String s) =>
      s.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), ' ').trim();
  final target = norm(stopBefore);
  if (target.length < 4) return markdown;
  final lines = markdown.split('\n');
  final from = (lines.length * 2 / 3).floor();
  for (var i = from; i < lines.length; i++) {
    final line = lines[i].trim();
    if (line.startsWith('#') && norm(line).contains(target)) {
      return lines.sublist(0, i).join('\n');
    }
  }
  return markdown;
}

class TranscriptionException implements Exception {
  TranscriptionException(this.message);
  final String message;
  @override
  String toString() => message;
}
