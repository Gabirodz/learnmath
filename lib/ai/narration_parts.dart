/// Splitting long source text (a book chapter) into chunks that are each
/// turned into a stretch of lecture script.
library;

final _pageMarker = RegExp(r'^\[\[page \d+\]\]\s*$', multiLine: true);
final _heading = RegExp(r'^#{1,3}\s+(.+)$');

/// Removes the `[[page N]]` marker lines of transcribed book chapters.
String stripPageMarkers(String markdown) =>
    markdown.replaceAll(_pageMarker, '').replaceAll(RegExp(r'\n{3,}'), '\n\n');

class SourcePart {
  const SourcePart(this.text, this.sections);
  final String text;

  /// Heading titles that start inside this part.
  final List<String> sections;
}

/// Packs [markdown] into parts of at most about [maxChars], cutting at
/// headings where possible and otherwise between paragraphs (never inside a
/// `$$` block). A short trailing part is merged into the previous one.
List<SourcePart> splitForNarration(String markdown, {int maxChars = 14000}) {
  // 1. Atomic blocks: paragraphs, with display math kept whole.
  final blocks = <String>[];
  final buf = StringBuffer();
  var inMath = false;
  void flush() {
    final t = buf.toString().trim();
    if (t.isNotEmpty) blocks.add(t);
    buf.clear();
  }

  for (final line in markdown.split('\n')) {
    final dollars = r'$$'.allMatches(line).length;
    if (!inMath && line.trim().isEmpty) {
      flush();
      continue;
    }
    if (!inMath && _heading.hasMatch(line)) flush();
    buf.writeln(line);
    if (dollars.isOdd) inMath = !inMath;
  }
  flush();

  // 2. Greedy packing; a heading starts a new part once the current one is
  // reasonably full.
  final parts = <List<String>>[];
  var current = <String>[];
  var size = 0;
  for (final b in blocks) {
    final isHeading = _heading.hasMatch(b.split('\n').first);
    final wouldOverflow = size + b.length > maxChars;
    final goodBreak = isHeading && size > maxChars * 0.6;
    if (current.isNotEmpty && (wouldOverflow || goodBreak)) {
      parts.add(current);
      current = <String>[];
      size = 0;
    }
    current.add(b);
    size += b.length + 2;
  }
  if (current.isNotEmpty) parts.add(current);

  // 3. Avoid a tiny last part.
  if (parts.length > 1 &&
      parts.last.fold<int>(0, (n, b) => n + b.length) < maxChars * 0.25) {
    final last = parts.removeLast();
    parts.last.addAll(last);
  }

  return [
    for (final p in parts)
      SourcePart(p.join('\n\n'), [
        for (final b in p)
          if (_heading.firstMatch(b.split('\n').first) case final m?)
            m.group(1)!.replaceAll(RegExp(r'[\$\*_`]'), '').trim(),
      ]),
  ];
}
