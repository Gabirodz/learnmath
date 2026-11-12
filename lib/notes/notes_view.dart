import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_math_fork/flutter_math.dart';
import 'package:gpt_markdown/gpt_markdown.dart';

/// Maximum readable column width on tablets / desktop / web.
const double kNotesMaxWidth = 720;

final _pageMarker = RegExp(r'^\s*\[\[page\s+\d+\]\]\s*$');
final _listItem = RegExp(r'^\s*([-*+]|\d+[.)])\s');

/// Removes `[[page N]]` marker lines (book page of the following text).
String stripPageMarkers(String markdown) {
  if (!markdown.contains('[[page')) return markdown;
  return markdown
      .split('\n')
      .where((l) => !_pageMarker.hasMatch(l))
      .join('\n');
}

/// Splits Markdown source into top-level blocks on blank lines, never inside
/// a `$$...$$` display or a ``` fence. Consecutive list items stay together,
/// and a `**Bold-labelled**` paragraph stays with a display equation that
/// directly follows it. `[[page N]]` markers are dropped.
List<String> splitSourceBlocks(String markdown) {
  final lines = markdown.replaceAll('\r\n', '\n').split('\n');
  final blocks = <String>[];
  var cur = <String>[];
  var inFence = false;
  var inDisplay = false;

  void flush() {
    final t = cur.join('\n').trim();
    if (t.isNotEmpty) blocks.add(t);
    cur = [];
  }

  String? nextNonBlank(int from) {
    for (var k = from; k < lines.length; k++) {
      if (lines[k].trim().isNotEmpty && !_pageMarker.hasMatch(lines[k])) {
        return lines[k];
      }
    }
    return null;
  }

  for (var i = 0; i < lines.length; i++) {
    final line = lines[i];
    if (_pageMarker.hasMatch(line) && !inFence && !inDisplay) continue;
    final trimmed = line.trim();
    if (!inDisplay && trimmed.startsWith('```')) inFence = !inFence;
    if (!inFence && !trimmed.startsWith('```') &&
        '\$\$'.allMatches(line).length.isOdd) {
      inDisplay = !inDisplay;
    }
    if (trimmed.isEmpty && !inFence && !inDisplay) {
      final next = nextNonBlank(i + 1);
      final last = cur.isEmpty ? null : cur.last;
      final keep = next != null &&
          last != null &&
          ((_listItem.hasMatch(last) &&
                  (_listItem.hasMatch(next) || next.startsWith('  '))) ||
              (cur.first.startsWith('**') && next.trimLeft().startsWith('\$\$')));
      if (keep) {
        cur.add(line);
      } else {
        flush();
      }
      continue;
    }
    cur.add(line);
  }
  flush();
  return blocks;
}

/// Non-scrolling Markdown + LaTeX renderer shared by [NotesView] and chat.
///
/// * `$...$` inline math flows with the text baseline.
/// * `$$...$$` display math is centred; when wider than the column it scrolls
///   horizontally on its own.
/// * Formulas that fail to parse degrade to raw TeX in a monospace style.
/// * `[[page N]]` marker lines are hidden.
class MarkdownMath extends StatelessWidget {
  const MarkdownMath(this.markdown, {super.key, this.dense = false});

  final String markdown;

  /// Slightly smaller text and tighter spacing (chat).
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final tt = theme.textTheme;

    final body = (tt.bodyLarge ?? const TextStyle()).copyWith(
      fontSize: dense ? 15 : 16,
      height: dense ? 1.45 : 1.55,
      color: cs.onSurface,
    );
    final k = dense ? 0.85 : 1.0;
    TextStyle h(double size, FontWeight w, double height) => body.copyWith(
          fontSize: size * k,
          fontWeight: w,
          height: height,
          color: cs.onSurface,
        );

    final mdTheme = GptMarkdownThemeData(
      brightness: theme.brightness,
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

    return GptMarkdownTheme(
      gptThemeData: mdTheme,
      child: GptMarkdown(
        stripPageMarkers(markdown),
        style: body,
        useDollarSignsForLatex: true,
        inlineLatexBuilder: (d) => d.asWidgetSpan(
          _InlineMath(tex: d.tex, style: d.style),
        ),
        blockLatexBuilder: (d) => _DisplayMath(
          tex: d.tex,
          style: d.style,
          dense: dense,
        ),
      ),
    );
  }
}

/// Scrollable rendering of LLM-written Markdown + LaTeX lecture notes.
///
/// With [onAskAbout], the notes are shown as lazily built source blocks and
/// long-pressing one offers "Ask about this" / "Copy"; otherwise the whole
/// document is selectable text.
class NotesView extends StatefulWidget {
  const NotesView({
    super.key,
    required this.markdown,
    this.padding,
    this.controller,
    this.onAskAbout,
  });

  final String markdown;

  /// Padding around the content. Defaults to `fromLTRB(16, 12, 16, 32)`.
  final EdgeInsetsGeometry? padding;

  /// Optional controller for the vertical scroll position.
  final ScrollController? controller;

  /// Called with a block's Markdown source when the student picks
  /// "Ask about this" from the long-press menu.
  final void Function(String blockMarkdown)? onAskAbout;

  @override
  State<NotesView> createState() => _NotesViewState();
}

class _NotesViewState extends State<NotesView> {
  List<String> _blocks = const [];

  @override
  void initState() {
    super.initState();
    _split();
  }

  @override
  void didUpdateWidget(NotesView old) {
    super.didUpdateWidget(old);
    if (old.markdown != widget.markdown ||
        (old.onAskAbout == null) != (widget.onAskAbout == null)) {
      _split();
    }
  }

  void _split() {
    _blocks = widget.onAskAbout == null
        ? const <String>[]
        : splitSourceBlocks(widget.markdown);
  }

  Widget _column(Widget child) => Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: kNotesMaxWidth),
          child: child,
        ),
      );

  @override
  Widget build(BuildContext context) {
    final resolvedPadding =
        widget.padding ?? const EdgeInsets.fromLTRB(16, 12, 16, 32);
    final ask = widget.onAskAbout;
    if (ask == null) {
      return SelectionArea(
        child: SingleChildScrollView(
          controller: widget.controller,
          padding: resolvedPadding,
          child: _column(MarkdownMath(widget.markdown)),
        ),
      );
    }
    return ListView.builder(
      controller: widget.controller,
      padding: resolvedPadding,
      itemCount: _blocks.length,
      itemBuilder: (context, i) => _column(
        _BlockTile(source: _blocks[i], onAsk: ask),
      ),
    );
  }
}

class _BlockTile extends StatefulWidget {
  const _BlockTile({required this.source, required this.onAsk});
  final String source;
  final void Function(String) onAsk;

  @override
  State<_BlockTile> createState() => _BlockTileState();
}

class _BlockTileState extends State<_BlockTile> {
  bool _hot = false;

  Future<void> _menu() async {
    HapticFeedback.mediumImpact();
    setState(() => _hot = true);
    final choice = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.forum_outlined),
              title: const Text('Ask about this'),
              onTap: () => Navigator.pop(ctx, 'ask'),
            ),
            ListTile(
              leading: const Icon(Icons.copy_rounded),
              title: const Text('Copy'),
              onTap: () => Navigator.pop(ctx, 'copy'),
            ),
          ],
        ),
      ),
    );
    if (mounted) setState(() => _hot = false);
    if (choice == 'ask') {
      widget.onAsk(widget.source);
    } else if (choice == 'copy') {
      await Clipboard.setData(ClipboardData(text: widget.source));
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onLongPress: _menu,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        decoration: BoxDecoration(
          color: _hot ? cs.secondaryContainer.withValues(alpha: 0.6) : null,
          borderRadius: BorderRadius.circular(8),
        ),
        child: MarkdownMath(widget.source),
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
  const _DisplayMath(
      {required this.tex, required this.style, this.dense = false});
  final String tex;
  final TextStyle style;
  final bool dense;

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
      padding: EdgeInsets.symmetric(vertical: dense ? 4 : 8),
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
