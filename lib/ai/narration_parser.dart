/// Tolerant parsers for the line-based formats the LLM is asked to produce.
library;

import 'package:learnmath/core/models.dart';

const int _defaultPauseMs = 350;
const int _maxPauseMs = 10000;

/// A SAY longer than this many words is split into sentence-sized pieces.
const int _splitThresholdWords = 45;

/// Target size of the pieces when splitting.
const int _targetWords = 30;

final RegExp _keyLine = RegExp(
  r'^\s*(?:[-*•>#]+\s*)*(?:\*\*|__)?\s*([A-Za-z]+)\s*(?:\*\*|__)?\s*:\s*(?:\*\*|__)?\s*(.*)$',
);

/// Returns (key, value) when [line] is `KEY: value` for one of [keys]
/// (case-insensitive, markdown decoration tolerated), else null.
(String, String)? _matchKey(String line, Set<String> keys) {
  final m = _keyLine.firstMatch(line);
  if (m == null) return null;
  final key = m.group(1)!.toUpperCase();
  if (!keys.contains(key)) return null;
  var value = m.group(2)!.trim();
  // Drop a dangling closing emphasis marker, e.g. "**SAY: text**".
  if (value.endsWith('**') && !value.substring(0, value.length - 2).contains('**')) {
    value = value.substring(0, value.length - 2).trim();
  }
  return (key, value);
}

bool _isFence(String line) => line.trim().startsWith('```');

// -------------------------------------------------------------- narration

class _Seg {
  _Seg(this.say, this.section);
  String say;
  String? show;
  int? pauseMs;
  final String? section;
}

/// Parses the SECTION/SAY/SHOW/PAUSE script.
///
/// * A SECTION applies to the next non-empty SAY.
/// * Segments without PAUSE get 350 ms; PAUSE is clamped to 0..10 s.
/// * If no SAY lines exist at all, the raw text is split into sentences.
/// * A SAY over ~45 words is split into sentence-sized pieces. In that case
///   the SHOW text is dropped for all pieces (a formula cannot be split
///   sensibly, and the subtitle then falls back to the spoken text); the
///   section stays on the first piece and the pause goes on the last.
List<NarrationSegment> parseNarration(String raw) {
  const keys = {'SECTION', 'SAY', 'SHOW', 'PAUSE'};
  final segs = <_Seg>[];
  _Seg? cur;
  String? pendingSection;
  // Which field continuation lines append to: 'say', 'show', 'section', null.
  String? last;
  var sawSay = false;

  for (final line in raw.split(RegExp(r'\r?\n'))) {
    if (_isFence(line)) continue;
    if (line.trim().isEmpty) {
      last = null;
      continue;
    }
    final kv = _matchKey(line, keys);
    if (kv == null) {
      final text = line.trim();
      if (last == 'say' && cur != null) {
        cur.say = '${cur.say} $text'.trim();
      } else if (last == 'show' && cur != null) {
        cur.show = '${cur.show ?? ''} $text'.trim();
      } else if (last == 'section') {
        pendingSection = '${pendingSection ?? ''} $text'.trim();
      }
      continue;
    }
    final (key, value) = kv;
    switch (key) {
      case 'SECTION':
        pendingSection = value.isEmpty ? null : value;
        last = 'section';
      case 'SAY':
        sawSay = true;
        cur = _Seg(value, pendingSection);
        pendingSection = null;
        segs.add(cur);
        last = 'say';
      case 'SHOW':
        if (cur != null) {
          cur.show = value;
          last = 'show';
        } else {
          last = null;
        }
      case 'PAUSE':
        if (cur != null) cur.pauseMs = _parsePauseMs(value) ?? cur.pauseMs;
        last = null;
    }
  }

  if (!sawSay) return _fallbackSentences(raw);

  final out = <NarrationSegment>[];
  String? carriedSection;
  for (final s in segs) {
    final say = s.say.trim();
    final section = s.section ?? carriedSection;
    if (say.isEmpty) {
      carriedSection = section; // keep the chapter marker for the next SAY
      continue;
    }
    carriedSection = null;
    final show = (s.show == null || s.show!.trim().isEmpty) ? null : s.show!.trim();
    out.addAll(_splitLong(say, show, section, s.pauseMs ?? _defaultPauseMs));
  }
  return out;
}

int? _parsePauseMs(String v) {
  final m = RegExp(r'(\d+(?:[.,]\d+)?|[.,]\d+)').firstMatch(v);
  if (m == null) return null;
  final d = double.tryParse(m.group(1)!.replaceAll(',', '.'));
  if (d == null) return null;
  var ms = (d * 1000).round();
  // "PAUSE: 500ms" style.
  if (RegExp(r'\d\s*ms\b', caseSensitive: false).hasMatch(v)) ms = d.round();
  return ms.clamp(0, _maxPauseMs);
}

int _wordCount(String s) =>
    s.trim().isEmpty ? 0 : s.trim().split(RegExp(r'\s+')).length;

List<String> _sentences(String text) => text
    .split(RegExp(r'(?<=[.!?])\s+'))
    .map((s) => s.trim())
    .where((s) => s.isNotEmpty)
    .toList();

List<NarrationSegment> _splitLong(
    String say, String? show, String? section, int pauseMs) {
  if (_wordCount(say) <= _splitThresholdWords) {
    return [
      NarrationSegment(say: say, show: show, pauseMs: pauseMs, section: section)
    ];
  }
  // Break into atoms: sentences, and clauses for over-long sentences.
  final atoms = <String>[];
  for (final s in _sentences(say)) {
    if (_wordCount(s) > _splitThresholdWords) {
      final clauses = s
          .split(RegExp(r'(?<=[,;:])\s+'))
          .map((c) => c.trim())
          .where((c) => c.isNotEmpty);
      atoms.addAll(clauses);
    } else {
      atoms.add(s);
    }
  }
  // Greedily pack atoms into pieces of about _targetWords.
  final pieces = <String>[];
  var current = '';
  for (final a in atoms) {
    if (current.isNotEmpty &&
        _wordCount(current) + _wordCount(a) > _targetWords) {
      pieces.add(current);
      current = a;
    } else {
      current = current.isEmpty ? a : '$current $a';
    }
  }
  if (current.isNotEmpty) pieces.add(current);

  if (pieces.length <= 1) {
    return [
      NarrationSegment(say: say, show: show, pauseMs: pauseMs, section: section)
    ];
  }
  return [
    for (var i = 0; i < pieces.length; i++)
      NarrationSegment(
        say: pieces[i],
        pauseMs: i == pieces.length - 1 ? pauseMs : _defaultPauseMs,
        section: i == 0 ? section : null,
      ),
  ];
}

List<NarrationSegment> _fallbackSentences(String raw) {
  final lines = raw
      .split(RegExp(r'\r?\n'))
      .where((l) => !_isFence(l))
      .map((l) => l
          .replaceFirst(RegExp(r'^\s*(?:[-*•>#]+\s*)+'), '')
          .replaceAll('**', '')
          .trim())
      .where((l) => l.isNotEmpty);
  final text = lines.join(' ');
  final out = <NarrationSegment>[];
  for (final s in _sentences(text)) {
    out.addAll(_splitLong(s, null, null, _defaultPauseMs));
  }
  return out;
}

// ---------------------------------------------------------------- outline

/// Parses the COURSE/DESCRIPTION/LESSON/BRIEF outline.
/// Throws [FormatException] if no lessons are found.
CourseOutline parseOutline(String raw) {
  const keys = {'COURSE', 'TITLE', 'DESCRIPTION', 'LESSON', 'BRIEF'};
  String title = '';
  String description = '';
  final lessons = <({String title, String brief})>[];
  String? lessonTitle;
  var brief = '';
  String? last; // 'course' | 'desc' | 'lesson' | 'brief'

  void flush() {
    if (lessonTitle != null && lessonTitle!.trim().isNotEmpty) {
      lessons.add((title: lessonTitle!.trim(), brief: brief.trim()));
    }
    lessonTitle = null;
    brief = '';
  }

  for (var line in raw.split(RegExp(r'\r?\n'))) {
    if (_isFence(line)) continue;
    if (line.trim().isEmpty) {
      last = null;
      continue;
    }
    // Tolerate "LESSON 3: Title" / "Lesson 3 - Title" numbering.
    line = line.replaceFirstMapped(
      RegExp(r'^(\s*(?:[-*•>#]+\s*)*(?:\*\*|__)?\s*LESSON)\s+\d+\s*(?=(?:\*\*|__)?\s*:)',
          caseSensitive: false),
      (m) => m.group(1)!,
    );
    final kv = _matchKey(line, keys);
    if (kv == null) {
      final t = line.trim();
      switch (last) {
        case 'course':
          title = '$title $t'.trim();
        case 'desc':
          description = '$description $t'.trim();
        case 'brief':
          brief = '$brief $t'.trim();
        case 'lesson':
          lessonTitle = '${lessonTitle ?? ''} $t'.trim();
      }
      continue;
    }
    final (key, value) = kv;
    switch (key) {
      case 'COURSE':
      case 'TITLE':
        if (title.isEmpty) title = value;
        last = 'course';
      case 'DESCRIPTION':
        description = value;
        last = 'desc';
      case 'LESSON':
        flush();
        lessonTitle = value;
        last = 'lesson';
      case 'BRIEF':
        brief = value;
        last = 'brief';
    }
  }
  flush();

  if (lessons.isEmpty) {
    throw const FormatException('No lessons found in the course outline.');
  }
  return CourseOutline(
    title: title.isEmpty ? lessons.first.title : title,
    description: description,
    lessons: [
      for (final l in lessons) OutlineLesson(title: l.title, brief: l.brief),
    ],
  );
}

// ------------------------------------------------------------------ notes

/// Strips an enclosing code fence, converts `\( \)` to `$ $` and `\[ \]` to
/// `$$ $$` (on their own lines), and trims.
String cleanNotes(String raw) {
  var s = raw.trim();
  final open = RegExp(r'^```[A-Za-z]*[ \t]*\r?\n');
  if (open.hasMatch(s)) {
    s = s.replaceFirst(open, '');
    s = s.replaceFirst(RegExp(r'\r?\n?```\s*$'), '');
  }
  s = s.replaceAllMapped(
    RegExp(r'(?<!\\)\\\[(.*?)(?<!\\)\\\]', dotAll: true),
    (m) => '\n\$\$\n${m.group(1)!.trim()}\n\$\$\n',
  );
  s = s.replaceAllMapped(
    RegExp(r'(?<!\\)\\\((.*?)(?<!\\)\\\)', dotAll: true),
    (m) => '\$${m.group(1)!.trim()}\$',
  );
  return s.trim();
}
