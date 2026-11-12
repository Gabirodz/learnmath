import 'package:flutter/material.dart';
import 'package:flutter_math_fork/flutter_math.dart';
import 'package:gpt_markdown/gpt_markdown.dart';

/// Maximum readable column width on tablets / desktop / web.
const double kNotesMaxWidth = 720;

/// Scrollable rendering of LLM-written Markdown + LaTeX lecture notes.
///
/// * `$...$` inline math flows with the text baseline.
/// * `$$...$$` display math is centred; when wider than the column it scrolls
///   horizontally on its own (the page never scrolls sideways).
/// * Formulas that fail to parse degrade to raw TeX in a monospace style.
class NotesView extends StatelessWidget {
  const NotesView({
    super.key,
    required this.markdown,
    this.padding,
    this.controller,
  });

  final String markdown;

  /// Padding around the content. Defaults to `fromLTRB(16, 12, 16, 32)`.
  final EdgeInsetsGeometry? padding;

  /// Optional controller for the vertical scroll position.
  final ScrollController? controller;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final tt = theme.textTheme;
    final scheme = theme.brightness;

    final body = (tt.bodyLarge ?? const TextStyle()).copyWith(
      fontSize: 16,
      height: 1.55,
      color: cs.onSurface,
    );
    TextStyle h(double size, FontWeight w, double height) => body.copyWith(
          fontSize: size,
          fontWeight: w,
          height: height,
          color: cs.onSurface,
        );

    final mdTheme = GptMarkdownThemeData(
      brightness: scheme,
      h1: h(28, FontWeight.w700, 1.25),
      h2: h(23, FontWeight.w700, 1.3),
      h3: h(19.5, FontWeight.w600, 1.35),
      h4: h(17.5, FontWeight.w600, 1.4),
      h5: h(16, FontWeight.w700, 1.45),
      h6: h(16, FontWeight.w600, 1.45).copyWith(color: cs.onSurfaceVariant),
      hrLineColor: cs.outlineVariant,
      linkColor: cs.primary,
      linkHoverColor: cs.primary,
      highlightColor: cs.secondaryContainer,
      inlineCode: InlineCodeStyle(
        fontFamily: 'monospace',
        color: cs.onSurface,
        backgroundColor: cs.surfaceContainerHighest,
      ),
    );

    final resolvedPadding = padding ?? const EdgeInsets.fromLTRB(16, 12, 16, 32);

    return SelectionArea(
      child: SingleChildScrollView(
        controller: controller,
        padding: resolvedPadding,
        child: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: kNotesMaxWidth),
            child: GptMarkdownTheme(
              gptThemeData: mdTheme,
              child: GptMarkdown(
                markdown,
                style: body,
                useDollarSignsForLatex: true,
                inlineLatexBuilder: (d) => d.asWidgetSpan(
                  _InlineMath(tex: d.tex, style: d.style),
                ),
                blockLatexBuilder: (d) => _DisplayMath(
                  tex: d.tex,
                  style: d.style,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

TextStyle _monoStyle(TextStyle base, Color color) => base.copyWith(
      fontFamily: 'monospace',
      fontFamilyFallback: const ['Roboto Mono', 'Courier New', 'Courier'],
      color: color,
      fontStyle: FontStyle.normal,
      fontWeight: FontWeight.normal,
    );

/// Raw TeX in monospace, used when a formula cannot be parsed or built.
Widget _rawTex(BuildContext context, String tex, TextStyle style,
    {required bool display}) {
  final cs = Theme.of(context).colorScheme;
  final t = Text(
    display ? tex : '\$$tex\$',
    softWrap: !display,
    style: _monoStyle(style, cs.onSurfaceVariant).copyWith(
      fontSize: (style.fontSize ?? 16) * 0.9,
    ),
  );
  return t;
}

Color _mathColor(BuildContext context, TextStyle style) =>
    style.color ?? Theme.of(context).colorScheme.onSurface;

class _InlineMath extends StatelessWidget {
  const _InlineMath({required this.tex, required this.style});
  final String tex;
  final TextStyle style;

  @override
  Widget build(BuildContext context) {
    // The enclosing paragraph scales this whole placeholder with the system
    // text scale, so the formula itself is built at the unscaled size.
    final size = style.fontSize ?? 16;
    return Math.tex(
      tex.trim(),
      mathStyle: MathStyle.text,
      textScaleFactor: 1.0,
      textStyle: style.copyWith(
        fontSize: size,
        color: _mathColor(context, style),
        fontWeight: FontWeight.normal,
      ),
      onErrorFallback: (_) => _rawTex(context, tex, style, display: false),
    );
  }
}

class _DisplayMath extends StatelessWidget {
  const _DisplayMath({required this.tex, required this.style});
  final String tex;
  final TextStyle style;

  @override
  Widget build(BuildContext context) {
    final base = style.fontSize ?? 16;
    final scaled = MediaQuery.textScalerOf(context).scale(base);
    final math = Math.tex(
      tex.trim(),
      mathStyle: MathStyle.display,
      textScaleFactor: 1.0,
      textStyle: style.copyWith(
        fontSize: scaled * 1.1,
        color: _mathColor(context, style),
        fontWeight: FontWeight.normal,
      ),
      onErrorFallback: (_) => _rawTex(
        context,
        tex,
        style.copyWith(fontSize: scaled),
        display: true,
      ),
    );
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: LayoutBuilder(
        builder: (context, c) => SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: ConstrainedBox(
            constraints: BoxConstraints(minWidth: c.maxWidth),
            child: Center(child: math),
          ),
        ),
      ),
    );
  }
}
