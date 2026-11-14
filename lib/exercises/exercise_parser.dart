/// Splits the `## Exercises` section of lecture notes into its exercises.
///
/// The notes are written by a model, so the section comes in several shapes:
/// numbered lists (`1.`, `1)`), bullets, or bold labels (`**Exercise 1.**`,
/// `**1.**`). An exercise may span paragraphs, contain display math and have
/// sub-parts `(a)`, `(b)`; all of that belongs to the exercise it follows.
///
/// Returns each exercise's Markdown without its list marker, or an empty list
/// when the notes have no such section.
List<String> parseExercises(String notesMarkdown) {
  final lines = notesMarkdown.split(RegExp(r'\r?\n'));
  final heading = RegExp(r'^(#{1,6})[ \t]+(?:exercises?|problems?)\b[^\n]*$',
      caseSensitive: false);
  final anyHeading = RegExp(r'^(#{1,6})[ \t]+\S');

  // Find the section (outside code fences and display math).
  var start = -1;
  var level = 0;
  var inFence = false;
  for (var i = 0; i < lines.length; i++) {
    if (lines[i].trimLeft().startsWith('```')) inFence = !inFence;
    if (inFence) continue;
    final m = heading.firstMatch(lines[i].trimRight());
    if (m != null) {
      start = i + 1;
      level = m.group(1)!.length;
      break;
    }
  }
  if (start < 0) return const [];

  final body = <String>[];
  inFence = false;
  for (var i = start; i < lines.length; i++) {
    final line = lines[i];
    if (line.trimLeft().startsWith('```')) inFence = !inFence;
    if (!inFence) {
      final h = anyHeading.firstMatch(line);
      if (h != null && h.group(1)!.length <= level) break;
    }
    body.add(line);
  }

  final marker = RegExp(r'^( {0,3})(?:(\d{1,3}[.)])|([-*+]))[ \t]+(?=\S)');
  final boldLabel = RegExp(
      r'^ {0,3}\*\*\s*(?:(?:Exercise|Problem)\s+)?\d+\s*(?:\([^)*\n]*\))?\s*[.:)]?\s*\*\*',
      caseSensitive: false);
  // A bullet that only introduces a sub-part belongs to the exercise above.
  final subPart = RegExp(r'^(?:\([a-z]\)|\([ivx]+\)|[a-z]\)|\([0-9]\))\s');

  final items = <List<String>>[];
  final intro = <String>[]; // text before the first marker
  var dollars = false; // inside a $$ block
  for (final line in body) {
    var startsItem = false;
    var text = line;
    if (!dollars) {
      final m = marker.firstMatch(line);
      if (m != null) {
        final rest = line.substring(m.end);
        final isBullet = m.group(3) != null;
        // Sub-part bullets and indented bullets are nested in the exercise.
        final nested = isBullet &&
            items.isNotEmpty &&
            (subPart.hasMatch(rest) || m.group(1)!.length >= 2);
        if (!nested) {
          startsItem = true;
          text = rest;
        }
      } else if (boldLabel.hasMatch(line)) {
        startsItem = true;
        text = line.trimLeft();
      }
    }
    if (startsItem) {
      items.add([text]);
    } else if (items.isNotEmpty) {
      items.last.add(_dedent(line));
    } else {
      intro.add(line);
    }
    if (r'$$'.allMatches(line).length.isOdd) dollars = !dollars;
  }

  // An introduction ("Solve the following.") is not an exercise when real
  // list items follow it; a section without any markers is one exercise.
  final sources = items.isEmpty ? [intro] : items;
  return [
    for (final item in sources)
      if (item.join('\n').trim().isNotEmpty) item.join('\n').trim(),
  ];
}

/// Continuation lines are indented under the marker; drop up to three
/// leading spaces so Markdown does not read them as a code block.
String _dedent(String line) {
  var n = 0;
  while (n < 3 && n < line.length && line.codeUnitAt(n) == 0x20) {
    n++;
  }
  return line.substring(n);
}
