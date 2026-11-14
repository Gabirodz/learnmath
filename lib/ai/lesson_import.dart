/// Reading a lesson that was written outside the app, by an assistant given
/// `Prompts.externalLesson`.
library;

import 'package:learnmath/ai/narration_parser.dart';
import 'package:learnmath/checks/check_parser.dart';
import 'package:learnmath/checks/math_check.dart';
import 'package:learnmath/core/models.dart';

/// A lesson found in pasted text.
class ImportedLesson {
  const ImportedLesson({
    required this.title,
    required this.notes,
    required this.checks,
    required this.segments,
    required this.cutOff,
    required this.warnings,
  });

  final String title;
  final String notes;
  final List<MathCheck> checks;

  /// Empty when the text has no usable lecture script.
  final List<NarrationSegment> segments;

  /// Whether the text ends in the middle of the lesson (the assistant ran
  /// out of room and has to be asked to continue).
  final bool cutOff;

  /// What the student should know before importing, in plain sentences.
  final List<String> warnings;

  bool get hasScript => segments.isNotEmpty;

  int get notesWords => _words(notes);

  /// Rough length of the lecture: speech at 150 words a minute plus the
  /// scripted pauses.
  Duration get estimatedDuration {
    var words = 0;
    var pauseMs = 0;
    for (final s in segments) {
      words += _words(s.say);
      pauseMs += s.pauseMs;
    }
    return Duration(milliseconds: words * 400 + pauseMs);
  }
}

int _words(String s) =>
    s.trim().isEmpty ? 0 : s.trim().split(RegExp(r'\s+')).length;

const _regions = ['NOTES', 'CHECKS', 'SCRIPT'];

RegExp _open(String name) =>
    RegExp('^[ \\t]*<<<[ \\t]*$name[ \\t]*\$', multiLine: true, caseSensitive: false);
RegExp _close(String name) =>
    RegExp('^[ \\t]*$name[ \\t]*>>>[ \\t]*\$', multiLine: true, caseSensitive: false);

final _fenceLine = RegExp(r'^[ \t]*`{3,}[A-Za-z]*[ \t]*$');
final _scriptLine = RegExp(r'^[ \t]*(?:SECTION|SAY)[ \t]*:', multiLine: true);

/// The text between the markers of [name], and whether its end marker was
/// there. Without one the region runs to the next region or the end.
({String text, bool closed, int end})? _region(String raw, String name) {
  final open = _open(name).firstMatch(raw);
  if (open == null) return null;
  final rest = raw.substring(open.end);
  final close = _close(name).firstMatch(rest);
  if (close != null) {
    return (
      text: rest.substring(0, close.start),
      closed: true,
      end: open.end + close.end,
    );
  }
  var end = rest.length;
  for (final other in _regions) {
    if (other == name) continue;
    final m = _open(other).firstMatch(rest);
    if (m != null && m.start < end) end = m.start;
  }
  return (text: rest.substring(0, end), closed: false, end: open.end + end);
}

/// Parses an answer in the format of `Prompts.externalLesson`.
///
/// Tolerant of what copying out of a chat does: text around the code block,
/// the fence lines themselves, an answer continued in a second code block,
/// missing end markers, and plain notes with no markers at all (then
/// everything up to the first script line is the notes).
///
/// Throws [FormatException] when there are no notes.
ImportedLesson parseImportedLesson(String raw) {
  raw = raw.replaceAll('\r\n', '\n');
  final warnings = <String>[];

  final checksRegion = _region(raw, 'CHECKS');
  var scriptRegion = _region(raw, 'SCRIPT');
  var notesRegion = _region(raw, 'NOTES');

  if (notesRegion == null) {
    // No markers: the notes are whatever precedes the checks and the script.
    var end = raw.length;
    for (final m in [
      _open('CHECKS').firstMatch(raw),
      _open('SCRIPT').firstMatch(raw),
      if (scriptRegion == null) _scriptLine.firstMatch(raw),
    ]) {
      if (m != null && m.start < end) end = m.start;
    }
    final lines = raw.substring(0, end).trim().split('\n');
    if (lines.isNotEmpty && _fenceLine.hasMatch(lines.first)) lines.removeAt(0);
    if (lines.isNotEmpty && _fenceLine.hasMatch(lines.last)) lines.removeLast();
    notesRegion = (text: lines.join('\n'), closed: true, end: end);
  }
  if (scriptRegion == null) {
    // A script without its marker still starts with SECTION or SAY.
    final after = notesRegion.end;
    final m = _scriptLine.firstMatch(raw.substring(after));
    if (m != null) {
      scriptRegion = (
        text: raw.substring(after + m.start),
        closed: true,
        end: raw.length,
      );
    }
  }

  // A continuation in a second code block leaves fence lines mid-text.
  final notes = cleanNotes(notesRegion.text
      .split('\n')
      .where((l) => !_fenceLine.hasMatch(l) || !l.trim().startsWith('````'))
      .join('\n'));
  if (notes.isEmpty) {
    throw const FormatException(
        'No lecture notes found. Copy the whole answer, from <<<NOTES to '
        'SCRIPT>>>.');
  }

  final checks = checksRegion == null
      ? const <MathCheck>[]
      : parseChecks(checksRegion.text);

  var segments = const <NarrationSegment>[];
  final script = scriptRegion?.text ?? '';
  if (RegExp(r'^[ \t]*SAY[ \t]*:', multiLine: true).hasMatch(script)) {
    segments = parseNarration(script);
  }
  if (segments.length < 3) segments = const [];

  final cutOff = !notesRegion.closed && scriptRegion == null ||
      (checksRegion != null && !checksRegion.closed && scriptRegion == null) ||
      (scriptRegion != null && !scriptRegion.closed);
  if (cutOff) {
    warnings.add(segments.isEmpty
        ? 'The answer stops before the lecture script. Tell the assistant '
            '"continue" and add what it writes.'
        : 'The answer looks cut off: the script has no end marker. Tell the '
            'assistant "continue" and add what it writes, or import the '
            'lecture as far as it goes.');
  } else if (segments.isEmpty) {
    warnings.add('No lecture script found, only notes.');
  }

  if (!notes.contains(r'$')) {
    warnings.add(r'The notes contain no formulas in $…$. If the lesson has '
        'math in it, the formatting was lost in copying: use the copy button '
        'of the code block, not of the whole message.');
  }
  final symbols = segments
      .where((s) => RegExp(r'[\$\\^_{}=<>]').hasMatch(s.say))
      .length;
  if (symbols > 0) {
    warnings.add('$symbols spoken '
        '${symbols == 1 ? 'line contains' : 'lines contain'} formulas or '
        'symbols instead of words; the voice will stumble over them.');
  }

  return ImportedLesson(
    title: _title(notes),
    notes: notes,
    checks: checks,
    segments: segments,
    cutOff: cutOff,
    warnings: warnings,
  );
}

String _title(String notes) {
  final m = RegExp(r'^#\s+(.+)$', multiLine: true).firstMatch(notes);
  final title = m?.group(1)?.replaceAll(RegExp(r'[\$\*_`]'), '').trim() ?? '';
  if (title.isEmpty) return 'Imported lesson';
  return title.length <= 90 ? title : '${title.substring(0, 89)}…';
}
