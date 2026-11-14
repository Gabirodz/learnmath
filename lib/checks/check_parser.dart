import 'math_check.dart';

/// Start and end markers of the checks block that follows the notes in a
/// model answer (see `Prompts.checksAddendum`).
const checksOpen = '<<<CHECKS';
const checksClose = 'CHECKS>>>';

/// Splits a model answer into the notes document and its SymPy checks.
///
/// Tolerant of the usual deviations: a missing end marker, the block wrapped
/// in a code fence, fences around each check, text before the first `CHECK:`.
({String notes, List<MathCheck> checks}) splitNotesAndChecks(String raw) {
  final start = raw.indexOf(checksOpen);
  if (start < 0) return (notes: raw, checks: const []);
  var notes = raw.substring(0, start);
  // A code fence opened just before the marker wraps the block and is not
  // part of the notes. An even number of fences means the last one closes a
  // code block of the notes, which must stay.
  final fences = RegExp(r'^[ \t]*```', multiLine: true).allMatches(notes);
  if (fences.length.isOdd) {
    notes = notes.replaceFirst(RegExp(r'```[A-Za-z]*[ \t]*\r?\n?\s*$'), '');
  }
  var block = raw.substring(start + checksOpen.length);
  final end = block.indexOf(checksClose);
  if (end >= 0) block = block.substring(0, end);
  return (notes: notes.trimRight(), checks: parseChecks(block));
}

/// Parses the inside of a checks block: `CHECK: title` lines, each followed
/// by the Python lines of that check.
List<MathCheck> parseChecks(String block) {
  final checks = <MathCheck>[];
  String? title;
  final code = <String>[];

  void flush() {
    final t = title;
    if (t == null) return;
    while (code.isNotEmpty && code.first.trim().isEmpty) {
      code.removeAt(0);
    }
    while (code.isNotEmpty && code.last.trim().isEmpty) {
      code.removeLast();
    }
    if (code.isNotEmpty) {
      checks.add(MathCheck(
        title: t.isEmpty ? 'Check ${checks.length + 1}' : t,
        code: code.join('\n'),
      ));
    }
    code.clear();
  }

  final header = RegExp(r'^CHECK\s*:\s*(.*)$');
  for (final line in block.split(RegExp(r'\r?\n'))) {
    final m = header.firstMatch(line);
    if (m != null) {
      flush();
      title = m.group(1)!.trim();
    } else if (title != null && !line.trimLeft().startsWith('```')) {
      code.add(line.trimRight());
    }
  }
  flush();
  return checks;
}

/// The block as the model wrote it, for showing the model its own checks.
String formatChecks(List<MathCheck> checks) {
  final b = StringBuffer()..writeln(checksOpen);
  for (final c in checks) {
    b
      ..writeln('CHECK: ${c.title}')
      ..writeln(c.code);
  }
  b.write(checksClose);
  return b.toString();
}

/// The failed checks with what SymPy said, for the repair request.
String formatFailures(List<MathCheck> checks, List<CheckOutcome> outcomes) {
  final b = StringBuffer();
  for (var i = 0; i < checks.length && i < outcomes.length; i++) {
    if (outcomes[i].status != CheckStatus.failed) continue;
    b
      ..writeln('CHECK: ${checks[i].title}')
      ..writeln(checks[i].code)
      ..writeln('RESULT: ${outcomes[i].detail ?? 'assertion failed'}')
      ..writeln();
  }
  return b.toString().trimRight();
}
