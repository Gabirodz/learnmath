import 'dart:async';
import 'dart:math' as dm;
import 'dart:typed_data';

import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter/widgets.dart' as fw;
import 'package:flutter_math_fork/flutter_math.dart' as fm;
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:screenshot/screenshot.dart';

import 'md_blocks.dart';

/// Exports lecture notes (Markdown + LaTeX) to an A4 PDF.
class PdfExporter {
  PdfExporter._();

  /// Asset paths of the bundled fonts (declare `assets/fonts/` in pubspec).
  static const fontRegular = 'assets/fonts/NotoSerif-Regular.ttf';
  static const fontBold = 'assets/fonts/NotoSerif-Bold.ttf';
  static const fontItalic = 'assets/fonts/NotoSerif-Italic.ttf';
  static const fontBoldItalic = 'assets/fonts/NotoSerif-BoldItalic.ttf';
  static const fontMono = 'assets/fonts/NotoSansMono-Regular.ttf';

  /// Renders the notes to an A4 PDF and returns its bytes. Must be called
  /// while the Flutter binding is up (it rasterizes math off-screen).
  static Future<Uint8List> build({
    required String title,
    required String markdown,
    String? subtitle,
  }) async {
    final fonts = await _loadFonts();
    final blocks = parseMarkdownBlocks(markdown);

    final math = _MathCache();
    final formulas = <(String, bool)>{};
    _collectFormulas(blocks, formulas);
    for (final f in formulas) {
      await math.render(f.$1, display: f.$2);
    }

    final doc = pw.Document(title: title, compress: true);
    final builder = _PdfBuilder(fonts: fonts, math: math, title: title);
    final widgets = builder.build(blocks, title: title, subtitle: subtitle);

    final theme = pw.ThemeData.withFont(
      base: fonts.regular,
      bold: fonts.bold,
      italic: fonts.italic,
      boldItalic: fonts.boldItalic,
    );

    doc.addPage(
      pw.MultiPage(
        maxPages: 2000,
        pageTheme: pw.PageTheme(
          pageFormat: PdfPageFormat.a4,
          margin: const pw.EdgeInsets.fromLTRB(
              _PdfBuilder.margin, 54, _PdfBuilder.margin, 54),
          theme: theme,
        ),
        header: (ctx) => ctx.pageNumber > 1
            ? pw.Container(
                alignment: pw.Alignment.centerLeft,
                margin: const pw.EdgeInsets.only(bottom: 10),
                child: pw.Text(
                  title,
                  style: pw.TextStyle(
                      fontSize: 8, color: PdfColors.grey700, font: fonts.italic),
                ),
              )
            : pw.SizedBox(),
        footer: (ctx) => pw.Container(
          alignment: pw.Alignment.center,
          margin: const pw.EdgeInsets.only(top: 12),
          child: pw.Text(
            '${ctx.pageNumber} / ${ctx.pagesCount}',
            style: const pw.TextStyle(fontSize: 8, color: PdfColors.grey700),
          ),
        ),
        build: (ctx) => widgets,
      ),
    );
    return doc.save();
  }

  static Future<_Fonts>? _fontsFuture;

  static Future<_Fonts> _loadFonts() => _fontsFuture ??= () async {
        Future<pw.Font> load(String p) async => pw.Font.ttf(await rootBundle.load(p));
        return _Fonts(
          regular: await load(fontRegular),
          bold: await load(fontBold),
          italic: await load(fontItalic),
          boldItalic: await load(fontBoldItalic),
          mono: await load(fontMono),
        );
      }().catchError((Object e) {
        _fontsFuture = null;
        throw e;
      });
}

class _Fonts {
  const _Fonts({
    required this.regular,
    required this.bold,
    required this.italic,
    required this.boldItalic,
    required this.mono,
  });
  final pw.Font regular, bold, italic, boldItalic, mono;
}

void _collectFormulas(List<Block> blocks, Set<(String, bool)> out) {
  void inl(List<Inline> l) {
    for (final r in l) {
      if (r.kind == InlineKind.math) out.add((r.text, false));
    }
  }

  for (final b in blocks) {
    switch (b) {
      case HeadingBlock():
        inl(b.inlines);
      case ParagraphBlock():
        inl(b.inlines);
      case DisplayMathBlock():
        out.add((b.tex, true));
      case ListBlock():
        for (final it in b.items) {
          inl(it.inlines);
          _collectFormulas(it.children, out);
        }
      case QuoteBlock():
        _collectFormulas(b.blocks, out);
      case TableBlock():
        for (final c in b.header) {
          inl(c);
        }
        for (final r in b.rows) {
          for (final c in r) {
            inl(c);
          }
        }
      case RuleBlock():
      case CodeBlock():
        break;
    }
  }
}

// ---------------------------------------------------------------------------
// Math rasterization

/// A rasterized formula. Sizes are logical pixels at [_MathCache.fontSize].
class _MathImage {
  _MathImage(this.image, this.width, this.height, this.baseline);
  final pw.MemoryImage image;
  final double width;
  final double height;

  /// Distance from the top of the image to the math baseline.
  final double baseline;
}

class _Metrics {
  Size? size;
  double? baseline;
  bool failed = false;
}

class _Probe extends fw.SingleChildRenderObjectWidget {
  const _Probe({required this.metrics, required super.child});
  final _Metrics metrics;

  @override
  RenderObject createRenderObject(fw.BuildContext context) =>
      _RenderProbe(metrics);

  @override
  void updateRenderObject(fw.BuildContext context, _RenderProbe renderObject) {
    renderObject.metrics = metrics;
  }
}

class _RenderProbe extends RenderProxyBox {
  _RenderProbe(this.metrics);
  _Metrics metrics;

  @override
  void performLayout() {
    super.performLayout();
    metrics.size = size;
    metrics.baseline =
        child?.getDistanceToBaseline(TextBaseline.alphabetic, onlyReal: true);
  }
}

class _MathCache {
  /// Font size (logical px) formulas are rasterized at.
  static const double fontSize = 24;
  static const double pixelRatio = 4;

  final Map<String, _MathImage?> _cache = {};
  final ScreenshotController _controller = ScreenshotController();

  _MathImage? lookup(String tex, {required bool display}) =>
      _cache['${display ? 1 : 0}|$tex'];

  /// Rasterizes [tex]; returns null when it cannot be parsed or built (the
  /// caller then emits raw TeX).
  Future<_MathImage?> render(String tex, {required bool display}) async {
    final key = '${display ? 1 : 0}|$tex';
    if (_cache.containsKey(key)) return _cache[key];
    _MathImage? result;
    try {
      result = await _renderUncached(normalizeTex(tex.trim()), display);
    } catch (_) {
      result = null;
    }
    return _cache[key] = result;
  }

  Future<_MathImage?> _renderUncached(String tex, bool display) async {
    if (tex.isEmpty) return null;
    final probe = fm.Math.tex(tex);
    if (probe.parseError != null) return null;

    final metrics = _Metrics();
    final widget = fw.Directionality(
      textDirection: TextDirection.ltr,
      child: _Probe(
        metrics: metrics,
        child: fm.Math(
          ast: probe.ast,
          options: fm.MathOptions(
            style: display ? fm.MathStyle.display : fm.MathStyle.text,
            fontSize: fontSize,
            color: const Color(0xFF000000),
          ),
          onErrorFallback: (e) {
            metrics.failed = true;
            return const fw.SizedBox(width: 1, height: 1);
          },
        ),
      ),
    );

    final bytes = await _controller.captureFromWidget(
      widget,
      pixelRatio: pixelRatio,
      delay: const Duration(milliseconds: 5),
      targetSize: const Size(8000, 2000),
    );
    if (metrics.failed || metrics.size == null) return null;
    final size = metrics.size!;
    if (size.width < 1 || size.height < 1) return null;
    // Without baseline info, centre the formula on the x-height line.
    final baseline = metrics.baseline ?? (size.height / 2 + fontSize * 0.25);
    return _MathImage(pw.MemoryImage(bytes), size.width, size.height, baseline);
  }
}

// ---------------------------------------------------------------------------
// PDF layout

class _PdfBuilder {
  _PdfBuilder({required this.fonts, required this.math, required this.title});

  final _Fonts fonts;
  final _MathCache math;
  final String title;

  static const double margin = 54;
  static const double bodySize = 10.5;
  static final double contentWidth = PdfPageFormat.a4.width - 2 * margin;

  List<pw.Widget> build(List<Block> blocks,
      {required String title, String? subtitle}) {
    final out = <pw.Widget>[
      pw.Text(title,
          style: pw.TextStyle(
              fontSize: 22, fontWeight: pw.FontWeight.bold, lineSpacing: 2)),
      if (subtitle != null && subtitle.trim().isNotEmpty)
        pw.Padding(
          padding: const pw.EdgeInsets.only(top: 4),
          child: pw.Text(subtitle,
              style: pw.TextStyle(
                  fontSize: 11,
                  fontStyle: pw.FontStyle.italic,
                  color: PdfColors.grey700)),
        ),
      pw.Padding(
        padding: const pw.EdgeInsets.only(top: 8, bottom: 14),
        child: pw.Divider(thickness: 0.8, color: PdfColors.grey600, height: 1),
      ),
    ];

    var rest = blocks;
    // Don't repeat the title if the notes start with the same H1.
    if (rest.isNotEmpty && rest.first is HeadingBlock) {
      final h = rest.first as HeadingBlock;
      if (h.level == 1 && _plain(h.inlines).trim() == title.trim()) {
        rest = rest.sublist(1);
      }
    }
    _blocks(rest, out, indent: 0);
    return out;
  }

  String _plain(List<Inline> l) => l.map((e) => e.text).join();

  void _blocks(List<Block> blocks, List<pw.Widget> out,
      {required double indent, pw.TextStyle? style}) {
    for (final b in blocks) {
      switch (b) {
        case HeadingBlock():
          out.add(_heading(b, indent));
        case ParagraphBlock():
          out.add(pw.Padding(
            padding: pw.EdgeInsets.only(left: indent, bottom: 7),
            child: _rich(b.inlines, _body(style),
                align: pw.TextAlign.justify),
          ));
        case DisplayMathBlock():
          out.add(_display(b.tex, indent));
        case ListBlock():
          _list(b, out, indent, style);
        case QuoteBlock():
          final inner = <pw.Widget>[];
          _blocks(b.blocks, inner,
              indent: 0,
              style: _body(style).copyWith(color: PdfColors.grey800));
          for (final w in inner) {
            out.add(pw.Container(
              margin: pw.EdgeInsets.only(left: indent + 4),
              padding: const pw.EdgeInsets.only(left: 10),
              decoration: const pw.BoxDecoration(
                border: pw.Border(
                    left: pw.BorderSide(color: PdfColors.grey500, width: 2)),
              ),
              child: w,
            ));
          }
        case RuleBlock():
          out.add(pw.Padding(
            padding: pw.EdgeInsets.only(left: indent, top: 4, bottom: 10),
            child: pw.Divider(thickness: 0.6, color: PdfColors.grey500, height: 1),
          ));
        case CodeBlock():
          _code(b, out, indent);
        case TableBlock():
          out.add(_table(b, indent));
      }
    }
  }

  pw.TextStyle _body(pw.TextStyle? s) =>
      s ??
      const pw.TextStyle(fontSize: bodySize, lineSpacing: 3.2);

  pw.Widget _heading(HeadingBlock h, double indent) {
    const sizes = [20.0, 16.0, 13.5, 12.0, 11.0, 10.5];
    final size = sizes[(h.level - 1).clamp(0, 5)];
    final style = pw.TextStyle(
        fontSize: size, fontWeight: pw.FontWeight.bold, lineSpacing: 2);
    return pw.Padding(
      padding: pw.EdgeInsets.only(
          left: indent, top: h.level <= 2 ? 14 : 9, bottom: h.level <= 2 ? 6 : 4),
      child: pw.RichText(
          text: pw.TextSpan(
              style: style, children: _spans(h.inlines, style, baseSize: size))),
    );
  }

  pw.Widget _rich(List<Inline> inlines, pw.TextStyle style,
      {pw.TextAlign? align}) {
    return pw.RichText(
      textAlign: align,
      text: pw.TextSpan(
          style: style,
          children: _spans(inlines, style, baseSize: style.fontSize ?? bodySize)),
    );
  }

  List<pw.InlineSpan> _spans(List<Inline> inlines, pw.TextStyle base,
      {required double baseSize}) {
    final spans = <pw.InlineSpan>[];
    final k = baseSize / _MathCache.fontSize;
    for (final r in inlines) {
      switch (r.kind) {
        case InlineKind.text:
          spans.add(pw.TextSpan(
            text: r.text,
            style: pw.TextStyle(
              fontWeight: r.bold ? pw.FontWeight.bold : null,
              fontStyle: r.italic ? pw.FontStyle.italic : null,
            ),
          ));
        case InlineKind.code:
          spans.add(pw.TextSpan(
            text: r.text,
            style: pw.TextStyle(
                font: fonts.mono,
                fontSize: baseSize * 0.88,
                fontWeight: pw.FontWeight.normal,
                fontStyle: pw.FontStyle.normal),
          ));
        case InlineKind.math:
          final img = math.lookup(r.text, display: false);
          if (img == null) {
            spans.add(_rawSpan('\$${r.text}\$', baseSize));
          } else {
            final w = img.width * k;
            final h = img.height * k;
            final descent = (img.height - img.baseline) * k;
            spans.add(pw.WidgetSpan(
              baseline: -descent,
              child: pw.Image(img.image, width: w, height: h),
            ));
          }
      }
    }
    return spans;
  }

  pw.TextSpan _rawSpan(String text, double baseSize) => pw.TextSpan(
        text: text,
        style: pw.TextStyle(
            font: fonts.mono,
            fontSize: baseSize * 0.85,
            fontWeight: pw.FontWeight.normal,
            fontStyle: pw.FontStyle.normal),
      );

  pw.Widget _display(String tex, double indent) {
    final img = math.lookup(tex, display: true);
    if (img == null) {
      return pw.Padding(
        padding: pw.EdgeInsets.fromLTRB(indent, 4, 0, 10),
        child: pw.Container(
          width: double.infinity,
          padding: const pw.EdgeInsets.all(6),
          color: PdfColors.grey200,
          child: pw.Text(tex.trim(),
              style: pw.TextStyle(font: fonts.mono, fontSize: 8.5, lineSpacing: 2)),
        ),
      );
    }
    // Display formulas are a bit larger than body text.
    final k = (bodySize * 1.08) / _MathCache.fontSize;
    var w = img.width * k;
    var h = img.height * k;
    final avail = contentWidth - indent;
    final scale = dm.min(1.0, dm.min(avail / w, 600 / h));
    w *= scale;
    h *= scale;
    return pw.Padding(
      padding: pw.EdgeInsets.fromLTRB(indent, 4, 0, 10),
      child: pw.Center(child: pw.Image(img.image, width: w, height: h)),
    );
  }

  void _list(ListBlock b, List<pw.Widget> out, double indent,
      pw.TextStyle? style) {
    var n = b.start;
    for (final it in b.items) {
      final marker = b.ordered ? '${n++}.' : '•';
      final bodyStyle = _body(style);
      out.add(pw.Padding(
        padding: pw.EdgeInsets.only(left: indent, bottom: 3.5),
        child: pw.Row(
          crossAxisAlignment: pw.CrossAxisAlignment.start,
          children: [
            pw.SizedBox(
              width: 20,
              child: pw.Text(marker,
                  style: bodyStyle, textAlign: pw.TextAlign.right),
            ),
            pw.SizedBox(width: 6),
            pw.Expanded(child: _rich(it.inlines, bodyStyle)),
          ],
        ),
      ));
      _blocks(it.children, out, indent: indent + 26, style: style);
    }
  }

  void _code(CodeBlock b, List<pw.Widget> out, double indent) {
    final lines = b.code.split('\n');
    const chunk = 45;
    for (var i = 0; i < lines.length; i += chunk) {
      final part = lines.sublist(i, dm.min(i + chunk, lines.length));
      out.add(pw.Container(
        width: double.infinity,
        margin: pw.EdgeInsets.only(left: indent, bottom: i + chunk >= lines.length ? 8 : 0),
        padding: const pw.EdgeInsets.all(6),
        color: PdfColors.grey200,
        child: pw.Text(part.join('\n'),
            style: pw.TextStyle(font: fonts.mono, fontSize: 8.5, lineSpacing: 1.5)),
      ));
    }
  }

  pw.Widget _table(TableBlock t, double indent) {
    final cols = t.header.length;
    pw.Widget cell(List<Inline> c, {bool header = false}) {
      final style = pw.TextStyle(
          fontSize: 9.5,
          lineSpacing: 2,
          fontWeight: header ? pw.FontWeight.bold : null);
      return pw.Padding(
        padding: const pw.EdgeInsets.symmetric(horizontal: 5, vertical: 3),
        child: _rich(c, style),
      );
    }

    pw.Widget empty() => pw.SizedBox();
    return pw.Padding(
      padding: pw.EdgeInsets.only(left: indent, top: 2, bottom: 10),
      child: pw.Table(
        border: pw.TableBorder.all(color: PdfColors.grey500, width: 0.5),
        defaultColumnWidth: const pw.FlexColumnWidth(),
        children: [
          pw.TableRow(
            decoration: const pw.BoxDecoration(color: PdfColors.grey200),
            children: [for (final c in t.header) cell(c, header: true)],
          ),
          for (final r in t.rows)
            pw.TableRow(children: [
              for (var i = 0; i < cols; i++)
                i < r.length ? cell(r[i]) : empty(),
            ]),
        ],
      ),
    );
  }
}
