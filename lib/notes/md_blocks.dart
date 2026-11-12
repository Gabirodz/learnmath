/// A small pure-Dart Markdown(+LaTeX) block parser used by the PDF exporter.
///
/// Supports headings, paragraphs with inline runs (text / bold / italic /
/// code / inline math), display math (`$$...$$`, `\[...\]`), bullet and
/// numbered lists (nested), block quotes, horizontal rules, simple pipe
/// tables and fenced code.
library;

/// One inline run inside a paragraph, heading, list item or table cell.
class Inline {
  const Inline.text(this.text, {this.bold = false, this.italic = false})
      : kind = InlineKind.text;
  const Inline.code(this.text)
      : kind = InlineKind.code,
        bold = false,
        italic = false;
  const Inline.math(this.text, {this.bold = false, this.italic = false})
      : kind = InlineKind.math;

  final InlineKind kind;

  /// Text, code source or TeX source (without delimiters).
  final String text;
  final bool bold;
  final bool italic;

  @override
  bool operator ==(Object other) =>
      other is Inline &&
      other.kind == kind &&
      other.text == text &&
      other.bold == bold &&
      other.italic == italic;

  @override
  int get hashCode => Object.hash(kind, text, bold, italic);

  @override
  String toString() =>
      '${kind.name}(${bold ? 'b' : ''}${italic ? 'i' : ''}"$text")';
}

enum InlineKind { text, code, math }

sealed class Block {
  const Block();
}

class HeadingBlock extends Block {
  const HeadingBlock(this.level, this.inlines);
  final int level;
  final List<Inline> inlines;
}

class ParagraphBlock extends Block {
  const ParagraphBlock(this.inlines);
  final List<Inline> inlines;
}

class DisplayMathBlock extends Block {
  const DisplayMathBlock(this.tex);
  final String tex;
}

class ListItem {
  const ListItem(this.inlines, [this.children = const []]);
  final List<Inline> inlines;

  /// Nested blocks (typically nested lists).
  final List<Block> children;
}

class ListBlock extends Block {
  const ListBlock({
    required this.ordered,
    required this.start,
    required this.items,
  });
  final bool ordered;
  final int start;
  final List<ListItem> items;
}

class QuoteBlock extends Block {
  const QuoteBlock(this.blocks);
  final List<Block> blocks;
}

class RuleBlock extends Block {
  const RuleBlock();
}

class CodeBlock extends Block {
  const CodeBlock(this.code, [this.language = '']);
  final String code;
  final String language;
}

class TableBlock extends Block {
  const TableBlock({required this.header, required this.rows});
  final List<List<Inline>> header;
  final List<List<List<Inline>>> rows;
}

/// Parses [markdown] into blocks.
List<Block> parseMarkdownBlocks(String markdown) {
  final lines = markdown.replaceAll('\r\n', '\n').replaceAll('\r', '\n').split('\n');
  return _BlockParser(lines).parse();
}

/// Parses inline content (emphasis, code, math) into runs.
List<Inline> parseInlines(String text) => [
      for (final r in _InlineParser(text).parse())
        if (r.kind == InlineKind.math && r.text.startsWith(_displayMarker))
          Inline.math(r.text.substring(_displayMarker.length),
              bold: r.bold, italic: r.italic)
        else
          r
    ];

// ---------------------------------------------------------------------------

final _fenceRe = RegExp(r'^\s{0,3}(`{3,}|~{3,})\s*([^`\s]*)');
final _headingRe = RegExp(r'^\s{0,3}(#{1,6})\s+(.*?)(?:\s+#+\s*)?$');
final _ruleRe = RegExp(r'^\s{0,3}([-*_])(\s*\1){2,}\s*$');
final _bulletRe = RegExp(r'^(\s*)([-*+])\s+(.*)$');
final _orderedRe = RegExp(r'^(\s*)(\d{1,9})[.)]\s+(.*)$');
final _tableSepRe = RegExp(r'^\s*\|?\s*:?-{1,}:?\s*(\|\s*:?-{1,}:?\s*)*\|?\s*$');

class _BlockParser {
  _BlockParser(this.lines);
  final List<String> lines;
  int i = 0;

  List<Block> parse() {
    final out = <Block>[];
    while (i < lines.length) {
      final line = lines[i];
      if (line.trim().isEmpty) {
        i++;
        continue;
      }
      final b = _parseOne(out);
      if (b != null) out.addAll(b);
    }
    return out;
  }

  bool _startsBlock(String line) {
    final t = line.trimLeft();
    return _fenceRe.hasMatch(line) ||
        _headingRe.hasMatch(line) ||
        _ruleRe.hasMatch(line) ||
        t.startsWith('>') ||
        t.startsWith(r'$$') ||
        t.startsWith(r'\[') ||
        _bulletRe.hasMatch(line) ||
        _orderedRe.hasMatch(line);
  }

  List<Block>? _parseOne(List<Block> out) {
    final line = lines[i];

    final fence = _fenceRe.firstMatch(line);
    if (fence != null) {
      final marker = fence.group(1)!;
      final lang = fence.group(2) ?? '';
      i++;
      final buf = <String>[];
      while (i < lines.length) {
        final l = lines[i];
        if (l.trimLeft().startsWith(marker) && l.trim().replaceAll(marker[0], '').isEmpty) {
          i++;
          break;
        }
        buf.add(l);
        i++;
      }
      return [CodeBlock(buf.join('\n'), lang)];
    }

    final trimmed = line.trim();

    // Display math, $$ ... $$ possibly multi-line.
    if (trimmed.startsWith(r'$$') || trimmed.startsWith(r'\[')) {
      final dollar = trimmed.startsWith(r'$$');
      final open = dollar ? r'$$' : r'\[';
      final close = dollar ? r'$$' : r'\]';
      var rest = trimmed.substring(2);
      final closeIdx = rest.indexOf(close);
      if (closeIdx >= 0) {
        final after = rest.substring(closeIdx + 2).trim();
        i++;
        final res = <Block>[DisplayMathBlock(rest.substring(0, closeIdx).trim())];
        if (after.isNotEmpty) {
          res.addAll(_paragraphFrom(after));
        }
        return res;
      }
      // multi-line
      final buf = StringBuffer(rest);
      var j = i + 1;
      while (j < lines.length) {
        final l = lines[j];
        final idx = l.indexOf(close);
        if (idx >= 0) {
          buf.write('\n${l.substring(0, idx)}');
          final after = l.substring(idx + 2).trim();
          i = j + 1;
          final res = <Block>[DisplayMathBlock(buf.toString().trim())];
          if (after.isNotEmpty) res.addAll(_paragraphFrom(after));
          return res;
        }
        buf.write('\n$l');
        j++;
      }
      // Unterminated: treat opener as plain paragraph text.
      assert(open.isNotEmpty);
      return _consumeParagraph();
    }

    final h = _headingRe.firstMatch(line);
    if (h != null) {
      i++;
      return [HeadingBlock(h.group(1)!.length, parseInlines(h.group(2)!.trim()))];
    }

    if (_ruleRe.hasMatch(line)) {
      i++;
      return [const RuleBlock()];
    }

    if (line.trimLeft().startsWith('>')) {
      final buf = <String>[];
      while (i < lines.length && lines[i].trimLeft().startsWith('>')) {
        var l = lines[i].trimLeft().substring(1);
        if (l.startsWith(' ')) l = l.substring(1);
        buf.add(l);
        i++;
      }
      return [QuoteBlock(parseMarkdownBlocks(buf.join('\n')))];
    }

    if (_bulletRe.hasMatch(line) || _orderedRe.hasMatch(line)) {
      return [_parseList(_indentOf(line))];
    }

    // Table: header line with a pipe followed by separator.
    if (line.contains('|') &&
        i + 1 < lines.length &&
        lines[i + 1].contains('-') &&
        _tableSepRe.hasMatch(lines[i + 1])) {
      final header = _splitRow(line).map(parseInlines).toList();
      i += 2;
      final rows = <List<List<Inline>>>[];
      while (i < lines.length && lines[i].trim().isNotEmpty && lines[i].contains('|')) {
        rows.add(_splitRow(lines[i]).map(parseInlines).toList());
        i++;
      }
      return [TableBlock(header: header, rows: rows)];
    }

    return _consumeParagraph();
  }

  int _indentOf(String l) {
    var n = 0;
    for (final c in l.codeUnits) {
      if (c == 0x20) {
        n++;
      } else if (c == 0x09) {
        n += 4;
      } else {
        break;
      }
    }
    return n;
  }

  List<String> _splitRow(String line) {
    var t = line.trim();
    if (t.startsWith('|')) t = t.substring(1);
    if (t.endsWith('|') && !t.endsWith(r'\|')) t = t.substring(0, t.length - 1);
    final cells = <String>[];
    final cur = StringBuffer();
    var inMath = false;
    for (var k = 0; k < t.length; k++) {
      final c = t[k];
      if (c == r'\' && k + 1 < t.length) {
        if (t[k + 1] == '|') {
          cur.write('|');
        } else {
          cur.write(c);
          cur.write(t[k + 1]);
        }
        k++;
        continue;
      }
      if (c == r'$') inMath = !inMath;
      if (c == '|' && !inMath) {
        cells.add(cur.toString().trim());
        cur.clear();
      } else {
        cur.write(c);
      }
    }
    cells.add(cur.toString().trim());
    return cells;
  }

  List<Block> _consumeParagraph() {
    final buf = <String>[lines[i]];
    i++;
    while (i < lines.length &&
        lines[i].trim().isNotEmpty &&
        !_startsBlock(lines[i]) &&
        !(lines[i].contains('|') &&
            i + 1 < lines.length &&
            _tableSepRe.hasMatch(lines[i + 1]) &&
            lines[i + 1].contains('-'))) {
      buf.add(lines[i]);
      i++;
    }
    return _paragraphFrom(buf.map((e) => e.trim()).join(' '));
  }

  /// Builds a paragraph; display math found inline splits it into blocks.
  List<Block> _paragraphFrom(String text) {
    final inl = _InlineParser(text).parse();
    final res = <Block>[];
    var cur = <Inline>[];
    void flush() {
      if (cur.isNotEmpty && !(cur.length == 1 && cur[0].kind == InlineKind.text && cur[0].text.trim().isEmpty)) {
        res.add(ParagraphBlock(cur));
      }
      cur = [];
    }

    for (final r in inl) {
      if (r.kind == InlineKind.math && r.text.startsWith(_displayMarker)) {
        flush();
        res.add(DisplayMathBlock(r.text.substring(_displayMarker.length)));
      } else {
        cur.add(r);
      }
    }
    flush();
    return res;
  }

  ListBlock _parseList(int baseIndent) {
    final first = lines[i];
    final ordered = _orderedRe.hasMatch(first) && !_bulletRe.hasMatch(first);
    var start = 1;
    if (ordered) start = int.parse(_orderedRe.firstMatch(first)!.group(2)!);
    final items = <ListItem>[];

    while (i < lines.length) {
      final l = lines[i];
      final bm = _bulletRe.firstMatch(l);
      final om = _orderedRe.firstMatch(l);
      final m = ordered ? om : bm;
      if (m == null || _indentOf(l) != baseIndent) break;
      final text = StringBuffer(m.group(ordered ? 3 : 3)!.trim());
      i++;
      final children = <Block>[];
      while (i < lines.length) {
        final n = lines[i];
        if (n.trim().isEmpty) {
          // Blank: continue only if next non-blank is deeper-indented.
          var j = i + 1;
          while (j < lines.length && lines[j].trim().isEmpty) {
            j++;
          }
          if (j < lines.length && _indentOf(lines[j]) > baseIndent) {
            i = j;
            continue;
          }
          break;
        }
        final ind = _indentOf(n);
        if (ind <= baseIndent) break;
        if (_bulletRe.hasMatch(n) || _orderedRe.hasMatch(n)) {
          children.add(_parseList(ind));
        } else if (_startsBlock(n)) {
          final sub = _parseOne(children);
          if (sub != null) children.addAll(sub);
        } else {
          text.write(' ${n.trim()}');
          i++;
        }
      }
      items.add(ListItem(parseInlines(text.toString()), children));
    }
    return ListBlock(ordered: ordered, start: start, items: items);
  }
}

// ---------------------------------------------------------------------------

/// Internal marker prefix marking `$$..$$` found inside a paragraph.
const _displayMarker = '\u0000display\u0000';

enum _TokKind { text, code, math, delim }

class _Tok {
  _Tok(this.kind, this.text, {this.delimChar = '', this.canOpen = false, this.canClose = false});
  final _TokKind kind;
  String text;
  final String delimChar;
  final bool canOpen;
  final bool canClose;
  bool active = false; // set when the delimiter is used as emphasis
}

class _InlineParser {
  _InlineParser(this.s);
  final String s;

  static const _escapable = r'\`*_{}[]()#+-.!$|<>~&"' "'";

  List<Inline> parse() {
    final toks = _tokenize();
    return _emphasis(toks);
  }

  bool _isSpace(String c) => c.trim().isEmpty;
  bool _isAlnum(String c) => RegExp(r'[\p{L}\p{N}]', unicode: true).hasMatch(c);

  List<_Tok> _tokenize() {
    final toks = <_Tok>[];
    final text = StringBuffer();
    void flush() {
      if (text.isNotEmpty) {
        toks.add(_Tok(_TokKind.text, text.toString()));
        text.clear();
      }
    }

    var i = 0;
    final n = s.length;
    while (i < n) {
      final c = s[i];

      if (c == r'\') {
        if (i + 1 < n) {
          final nx = s[i + 1];
          if (nx == '(') {
            final end = s.indexOf(r'\)', i + 2);
            if (end > 0) {
              flush();
              toks.add(_Tok(_TokKind.math, s.substring(i + 2, end).trim()));
              i = end + 2;
              continue;
            }
          }
          if (nx == '[') {
            final end = s.indexOf(r'\]', i + 2);
            if (end > 0) {
              flush();
              toks.add(_Tok(_TokKind.math, _displayMarker + s.substring(i + 2, end).trim()));
              i = end + 2;
              continue;
            }
          }
          if (_escapable.contains(nx)) {
            text.write(nx);
            i += 2;
            continue;
          }
        }
        text.write(c);
        i++;
        continue;
      }

      if (c == '`') {
        var j = i;
        while (j < n && s[j] == '`') {
          j++;
        }
        final ticks = s.substring(i, j);
        final end = s.indexOf(ticks, j);
        // Closing run must be exactly the same length.
        var close = end;
        while (close >= 0) {
          final after = close + ticks.length;
          if (after < n && s[after] == '`') {
            close = s.indexOf(ticks, _skipTicks(after));
          } else {
            break;
          }
        }
        if (close > 0) {
          flush();
          var code = s.substring(j, close);
          if (code.length > 1 && code.startsWith(' ') && code.endsWith(' ') && code.trim().isNotEmpty) {
            code = code.substring(1, code.length - 1);
          }
          toks.add(_Tok(_TokKind.code, code));
          i = close + ticks.length;
          continue;
        }
        text.write(ticks);
        i = j;
        continue;
      }

      if (c == r'$') {
        // $$...$$ inline-embedded display math
        if (i + 1 < n && s[i + 1] == r'$') {
          final end = _findClose(i + 2, double: true);
          if (end > 0) {
            flush();
            toks.add(_Tok(_TokKind.math, _displayMarker + s.substring(i + 2, end).trim()));
            i = end + 2;
            continue;
          }
          text.write(r'$$');
          i += 2;
          continue;
        }
        final next = i + 1 < n ? s[i + 1] : '';
        if (next.isNotEmpty && !_isSpace(next)) {
          final end = _findClose(i + 1, double: false);
          if (end > 0) {
            flush();
            toks.add(_Tok(_TokKind.math, s.substring(i + 1, end)));
            i = end + 1;
            continue;
          }
        }
        text.write(c);
        i++;
        continue;
      }

      if (c == '*' || c == '_') {
        var j = i;
        while (j < n && s[j] == c) {
          j++;
        }
        final run = j - i;
        final prev = i > 0 ? s[i - 1] : ' ';
        final next = j < n ? s[j] : ' ';
        var canOpen = !_isSpace(next);
        var canClose = !_isSpace(prev);
        if (c == '_') {
          if (_isAlnum(prev)) canOpen = false;
          if (_isAlnum(next)) canClose = false;
        }
        flush();
        toks.add(_Tok(_TokKind.delim, s.substring(i, j),
            delimChar: c, canOpen: canOpen && run <= 3, canClose: canClose && run <= 3));
        i = j;
        continue;
      }

      // Links / images: keep only the label text.
      if (c == '[' || (c == '!' && i + 1 < n && s[i + 1] == '[')) {
        final start = c == '!' ? i + 1 : i;
        final closeB = s.indexOf(']', start);
        if (closeB > 0 && closeB + 1 < n && s[closeB + 1] == '(') {
          final closeP = s.indexOf(')', closeB + 2);
          if (closeP > 0) {
            if (c == '[') {
              // Re-parse the label so emphasis/math inside survives.
              flush();
              toks.addAll(_InlineParser(s.substring(start + 1, closeB))._tokenize());
            }
            i = closeP + 1;
            continue;
          }
        }
      }

      text.write(c);
      i++;
    }
    flush();
    return toks;
  }

  int _skipTicks(int p) {
    while (p < s.length && s[p] == '`') {
      p++;
    }
    return p;
  }

  /// Index of closing `$` (or `$$`) starting search at [from], or -1.
  int _findClose(int from, {required bool double}) {
    final n = s.length;
    for (var k = from; k < n; k++) {
      final c = s[k];
      if (c == r'\') {
        k++;
        continue;
      }
      if (c == r'$') {
        if (double) {
          if (k + 1 < n && s[k + 1] == r'$') return k;
          continue;
        }
        if (k == from) continue;
        if (_isSpace(s[k - 1])) continue; // closing $ must follow non-space
        if (k + 1 < n && RegExp(r'\d').hasMatch(s[k + 1])) continue;
        return k;
      }
    }
    return -1;
  }

  List<Inline> _emphasis(List<_Tok> toks) {
    // Decide which delimiter tokens act as emphasis via lookahead matching.
    final out = <Inline>[];
    var bold = false;
    var italic = false;

    bool hasCloser(int from, String ch, int len) {
      for (var k = from; k < toks.length; k++) {
        final t = toks[k];
        if (t.kind == _TokKind.delim && t.delimChar == ch && t.canClose && t.text.length >= 1) {
          return true;
        }
      }
      return false;
    }

    void addText(String t) {
      if (t.isEmpty) return;
      if (out.isNotEmpty &&
          out.last.kind == InlineKind.text &&
          out.last.bold == bold &&
          out.last.italic == italic) {
        final p = out.removeLast();
        out.add(Inline.text(p.text + t, bold: bold, italic: italic));
      } else {
        out.add(Inline.text(t, bold: bold, italic: italic));
      }
    }

    for (var k = 0; k < toks.length; k++) {
      final t = toks[k];
      switch (t.kind) {
        case _TokKind.text:
          addText(t.text);
        case _TokKind.code:
          out.add(Inline.code(t.text));
        case _TokKind.math:
          out.add(Inline.math(t.text, bold: bold, italic: italic));
        case _TokKind.delim:
          final len = t.text.length;
          final on = bold || italic;
          final closing = t.canClose && (bold || italic);
          final opening = t.canOpen && hasCloser(k + 1, t.delimChar, len);
          if (closing && !(opening && !on)) {
            // Toggle off.
            if (len >= 2 && bold) {
              bold = false;
              if (len == 3 && italic) italic = false;
            } else if (len == 1 && italic) {
              italic = false;
            } else if (len == 3 && italic) {
              italic = false;
            } else if (len == 2 && !bold) {
              addText(t.text);
            } else {
              addText(t.text);
            }
          } else if (opening) {
            if (len == 1) {
              italic = true;
            } else if (len == 2) {
              bold = true;
            } else {
              bold = true;
              italic = true;
            }
          } else {
            addText(t.text);
          }
      }
    }
    return out;
  }
}
