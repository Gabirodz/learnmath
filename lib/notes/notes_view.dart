import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_math_fork/flutter_math.dart';
import 'package:gpt_markdown/gpt_markdown.dart';
import 'package:learnmath/notes/fit_math.dart';
import 'package:learnmath/notes/md_blocks.dart' show normalizeTex;

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

/// What a stretch of notes is, by the bold label it starts with
/// ("**Theorem 2 (Heine-Borel).**", "**Proof.**").
enum NoteKind { definition, theorem, example, remark, proof }

final _noteLabel = RegExp(
    r'^\s*(?:\*\*|__)\s*(definition|theorem|lemma|proposition|corollary|'
    r'claim|fact|proof|example|non-?example|counter-?example|remark|note|'
    r'notation|intuition|warning|caution)\b',
    caseSensitive: false);

final _proofEnd =
    RegExp(r'\\blacksquare|\\square|\\qed|\\Box\b|[∎■□]');

final _listStart = RegExp(r'^\s*([-*+]|\d+[.)])\s');

/// The kind of environment [block] opens, or null for prose.
NoteKind? noteKindOf(String block) {
  final m = _noteLabel.firstMatch(block);
  if (m == null) return null;
  final w = m.group(1)!.toLowerCase();
  return switch (w) {
    'definition' || 'notation' => NoteKind.definition,
    'theorem' || 'lemma' || 'proposition' || 'corollary' || 'claim' ||
    'fact' =>
      NoteKind.theorem,
    'proof' => NoteKind.proof,
    'remark' || 'note' || 'intuition' || 'warning' || 'caution' =>
      NoteKind.remark,
    _ => NoteKind.example,
  };
}

/// A run of source blocks shown together: prose ([kind] null) or one
/// definition, theorem, proof, example or remark.
class NoteGroup {
  NoteGroup(this.kind, this.blocks);
  final NoteKind? kind;
  final List<String> blocks;
}

/// Groups source blocks ([splitSourceBlocks]) into environments, each from
/// its bold label:
/// * a proof runs to its end mark (■, `\blacksquare`, `\qed`, ...);
/// * an example runs to the next heading or label;
/// * a definition, theorem or remark takes the labelled paragraph and what
///   continues it: display formulas, lists, a sentence going on in lower
///   case, or anything after a paragraph ending in a colon.
/// A heading or rule always ends an environment.
List<NoteGroup> groupNoteBlocks(List<String> blocks) {
  final out = <NoteGroup>[];
  NoteGroup? open;

  void plain(String b) {
    if (out.isNotEmpty && out.last.kind == null && !identical(out.last, open)) {
      out.last.blocks.add(b);
    } else {
      out.add(NoteGroup(null, [b]));
    }
  }

  bool continues(NoteGroup g, String b) {
    switch (g.kind!) {
      case NoteKind.proof:
      case NoteKind.example:
        return true;
      case NoteKind.definition:
      case NoteKind.theorem:
      case NoteKind.remark:
        final t = b.trimLeft();
        if (t.startsWith(r'$$') || t.startsWith(r'\[')) return true;
        if (_listStart.hasMatch(t)) return true;
        if (t.isNotEmpty && RegExp(r'^[a-z]').hasMatch(t)) return true;
        return g.blocks.last.trimRight().endsWith(':');
    }
  }

  for (final b in blocks) {
    final t = b.trimLeft();
    if (t.startsWith('#') || RegExp(r'^([-*_])(\s*\1){2,}\s*$').hasMatch(t)) {
      open = null;
      plain(b);
      continue;
    }
    final kind = noteKindOf(b);
    if (kind != null) {
      open = NoteGroup(kind, [b]);
      out.add(open);
    } else if (open != null && continues(open, b)) {
      open.blocks.add(b);
    } else {
      open = null;
      plain(b);
      continue;
    }
    if (open.kind == NoteKind.proof && _proofEnd.hasMatch(b)) open = null;
  }
  return out;
}

/// The colour of a kind of environment: the hue of the box's edge and, faintly,
/// of its fill. Text keeps the text colour.
Color noteColor(NoteKind kind, ColorScheme cs) {
  final dark = cs.brightness == Brightness.dark;
  return switch (kind) {
    NoteKind.theorem => dark ? const Color(0xFF3987E5) : const Color(0xFF2A78D6),
    NoteKind.definition =>
      dark ? const Color(0xFF199E70) : const Color(0xFF1BAF7A),
    NoteKind.example => dark ? const Color(0xFFC98500) : const Color(0xFFEDA100),
    NoteKind.remark => dark ? const Color(0xFF9085E9) : const Color(0xFF6250D6),
    NoteKind.proof => cs.outline,
  };
}

/// A definition, theorem, proof, example or remark in its colour-coded box:
/// a coloured edge on the left and (except for proofs) a faint tint.
class NoteBox extends StatelessWidget {
  const NoteBox({super.key, required this.kind, required this.child});
  final NoteKind kind;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final c = noteColor(kind, cs);
    final dark = cs.brightness == Brightness.dark;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: CustomPaint(
        painter: _NoteBoxPainter(
          edge: c,
          fill: kind == NoteKind.proof
              ? null
              : c.withValues(alpha: dark ? 0.13 : 0.08),
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 12, 8),
          child: child,
        ),
      ),
    );
  }
}

class _NoteBoxPainter extends CustomPainter {
  _NoteBoxPainter({required this.edge, this.fill});
  final Color edge;
  final Color? fill;

  @override
  void paint(Canvas canvas, Size size) {
    final box = RRect.fromRectAndRadius(
        Offset.zero & size, const Radius.circular(10));
    canvas.save();
    canvas.clipRRect(box);
    if (fill != null) canvas.drawRect(Offset.zero & size, Paint()..color = fill!);
    canvas.drawRect(
        Rect.fromLTWH(0, 0, 4, size.height), Paint()..color = edge);
    canvas.restore();
  }

  @override
  bool shouldRepaint(_NoteBoxPainter old) =>
      old.edge != edge || old.fill != fill;
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
  List<NoteGroup> _groups = const [];

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

  /// Prose blocks one by one (the list stays lazy), each definition,
  /// theorem, proof, example or remark as one item in its box.
  void _split() {
    _groups = [
      for (final g in groupNoteBlocks(splitSourceBlocks(widget.markdown)))
        if (g.kind == null)
          for (final b in g.blocks) NoteGroup(null, [b])
        else
          g,
    ];
  }

  // Full column width: a short block (a heading, one line) would otherwise
  // shrink to its text and be centred.
  Widget _column(Widget child) => Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: kNotesMaxWidth),
          child: SizedBox(width: double.infinity, child: child),
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
          child: _column(Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (final g in _groups)
                g.kind == null
                    ? MarkdownMath(g.blocks.single)
                    : NoteBox(
                        kind: g.kind!,
                        child: MarkdownMath(g.blocks.join('\n\n'))),
            ],
          )),
        ),
      );
    }
    return ListView.builder(
      controller: widget.controller,
      padding: resolvedPadding,
      itemCount: _groups.length,
      itemBuilder: (context, i) {
        final g = _groups[i];
        if (g.kind == null) {
          return _column(_BlockTile(source: g.blocks.single, onAsk: ask));
        }
        return _column(NoteBox(
          kind: g.kind!,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (final b in g.blocks) _BlockTile(source: b, onAsk: ask),
            ],
          ),
        ));
      },
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
    // Too wide for the line: shrunk a little, then broken after relations
    // and operators, rather than cut off.
    final size = style.fontSize ?? 16;
    return FitMath(
      normalizeTex(tex.trim()),
      minScale: 0.8,
      center: false,
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
      normalizeTex(tex.trim()),
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
