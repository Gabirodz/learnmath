import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:pdfrx/pdfrx.dart';

import 'chapter_plan.dart';

export 'chapter_plan.dart' show OutlineEntry;

/// Thin wrapper over pdfrx. All page numbers are 1-based.
class PdfSource {
  PdfSource._(this._doc);
  final PdfDocument _doc;

  /// Throws [PdfPasswordException] for encrypted files and other
  /// [PdfException]s for unreadable ones.
  static Future<PdfSource> open(String path) async {
    await pdfrxFlutterInitialize();
    return PdfSource._(await PdfDocument.openFile(path));
  }

  int get pageCount => _doc.pages.length;

  Future<List<OutlineEntry>> outline() async {
    final nodes = await _doc.loadOutline();
    final out = <OutlineEntry>[];
    void walk(List<PdfOutlineNode> list, int level) {
      for (final n in list) {
        final page = n.dest?.pageNumber;
        if (page != null && page >= 1 && page <= pageCount && n.title.trim().isNotEmpty) {
          out.add(OutlineEntry(n.title.trim(), page, level));
        }
        walk(n.children, level + 1);
      }
    }

    walk(nodes, 0);
    return out;
  }

  PdfPage _page(int page) {
    if (page < 1 || page > pageCount) {
      throw RangeError.range(page, 1, pageCount, 'page');
    }
    return _doc.pages[page - 1];
  }

  Future<Uint8List> renderPagePng(int page, {int longSide = 1600}) async {
    final p = _page(page);
    final scale = longSide / (p.width > p.height ? p.width : p.height);
    final img = await p.render(
      fullWidth: p.width * scale,
      fullHeight: p.height * scale,
      backgroundColor: 0xffffffff,
    );
    if (img == null) throw StateError('Could not render page $page.');
    ui.Image? uiImage;
    try {
      uiImage = await img.createImage();
    } finally {
      img.dispose();
    }
    try {
      final data = await uiImage.toByteData(format: ui.ImageByteFormat.png);
      if (data == null) throw StateError('Could not encode page $page.');
      return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
    } finally {
      uiImage.dispose();
    }
  }

  Future<String> pageText(int page) async {
    final t = await _page(page).loadText();
    return t?.fullText ?? '';
  }

  Future<void> close() => _doc.dispose();
}
