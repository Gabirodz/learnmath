/// Review of a lesson's proofs by a second model from another family.
///
/// SymPy catches wrong computations; it cannot see a theorem stated with a
/// missing hypothesis or a proof step that assumes what it should show. A
/// model reading its own notes tends to wave those through, so the reviewer
/// is a different model, and because a strict reviewer also raises false
/// alarms, the lesson model then judges each reported issue before anything
/// is rewritten.
library;

/// One problem the reviewer found.
class ProofIssue {
  const ProofIssue({required this.summary, this.where = '', this.why = '', this.fix = ''});

  /// One line: what is wrong.
  final String summary;

  /// Which statement or step of the notes.
  final String where;
  final String why;

  /// What the correct statement or step would be.
  final String fix;

  Map<String, Object?> toJson() =>
      {'summary': summary, 'where': where, 'why': why, 'fix': fix};

  factory ProofIssue.fromJson(Map<String, Object?> j) => ProofIssue(
        summary: j['summary'] as String? ?? '',
        where: j['where'] as String? ?? '',
        why: j['why'] as String? ?? '',
        fix: j['fix'] as String? ?? '',
      );
}

enum ProofReviewState {
  /// The reviewer has to read the notes (again, after a rewrite).
  toVerify,

  /// [ProofReview.issues] are the reviewer's, not yet judged.
  raw,

  /// [ProofReview.issues] were judged real.
  confirmed,

  /// Finished; [ProofReview.issues] are what remains for the reader.
  done,
}

class ProofReview {
  const ProofReview({
    required this.state,
    this.issues = const [],
    this.round = 0,
    this.reportOnly = false,
    this.dismissed = 0,
  });

  final ProofReviewState state;
  final List<ProofIssue> issues;

  /// 0 for the first reading, 1 after the notes were rewritten once.
  final int round;

  /// Asked for on a finished lesson: issues are reported, the notes (and
  /// the lecture already recorded from them) are left alone.
  final bool reportOnly;

  /// How many reported issues were judged false alarms.
  final int dismissed;

  bool get isDone => state == ProofReviewState.done;
  bool get rewritten => round > 0;

  ProofReview copyWith({
    ProofReviewState? state,
    List<ProofIssue>? issues,
    int? round,
    int? dismissed,
  }) =>
      ProofReview(
        state: state ?? this.state,
        issues: issues ?? this.issues,
        round: round ?? this.round,
        reportOnly: reportOnly,
        dismissed: dismissed ?? this.dismissed,
      );

  Map<String, Object?> toJson() => {
        'state': state.name,
        'issues': [for (final i in issues) i.toJson()],
        'round': round,
        'reportOnly': reportOnly,
        'dismissed': dismissed,
      };

  static ProofReview? fromJson(Object? j) {
    if (j is! Map) return null;
    final state = ProofReviewState.values.asNameMap()[j['state']];
    if (state == null) return null;
    return ProofReview(
      state: state,
      issues: [
        for (final i in (j['issues'] as List? ?? const []))
          ProofIssue.fromJson((i as Map).cast<String, Object?>()),
      ],
      round: (j['round'] as num?)?.toInt() ?? 0,
      reportOnly: j['reportOnly'] as bool? ?? false,
      dismissed: (j['dismissed'] as num?)?.toInt() ?? 0,
    );
  }
}

/// Parses the reviewer's answer: `ISSUE:` / `WHERE:` / `WHY:` / `FIX:` lines
/// per issue, or `NO ISSUES`. Continuation lines extend the last field.
List<ProofIssue> parseIssues(String raw) {
  final issues = <ProofIssue>[];
  Map<String, StringBuffer>? cur;
  String? field;

  void flush() {
    final c = cur;
    if (c == null) return;
    String get(String k) => (c[k]?.toString() ?? '').trim();
    if (get('ISSUE').isNotEmpty) {
      issues.add(ProofIssue(
          summary: get('ISSUE'),
          where: get('WHERE'),
          why: get('WHY'),
          fix: get('FIX')));
    }
  }

  final key = RegExp(r'^\s*(?:[-*]\s*|\d+[.)]\s*)?\**(ISSUE|WHERE|WHY|FIX)\s*(?:#?\d+\s*)?\**\s*:\**\s*(.*)$');
  for (final line in raw.split(RegExp(r'\r?\n'))) {
    final m = key.firstMatch(line);
    if (m != null) {
      final k = m.group(1)!;
      if (k == 'ISSUE') {
        flush();
        cur = {};
      }
      field = k;
      (cur ??= {})[k] = StringBuffer(m.group(2)!);
    } else if (cur != null && field != null && line.trim().isNotEmpty) {
      cur[field]!
        ..write(' ')
        ..write(line.trim());
    }
  }
  flush();
  return issues;
}

/// Numbered list of issues, as shown to the judging and the repairing model.
String formatIssues(List<ProofIssue> issues) {
  final b = StringBuffer();
  for (var i = 0; i < issues.length; i++) {
    final x = issues[i];
    b.writeln('${i + 1}. ISSUE: ${x.summary}');
    if (x.where.isNotEmpty) b.writeln('   WHERE: ${x.where}');
    if (x.why.isNotEmpty) b.writeln('   WHY: ${x.why}');
    if (x.fix.isNotEmpty) b.writeln('   FIX: ${x.fix}');
  }
  return b.toString().trimRight();
}

/// Parses the judge's `VERDICT <n>: REAL` / `VERDICT <n>: FALSE ALARM` lines
/// and returns the issues judged real. An issue without a verdict is kept:
/// when in doubt the reader should see it.
List<ProofIssue> keepRealIssues(List<ProofIssue> issues, String verdicts) {
  final dismissed = <int>{};
  final line = RegExp(r'VERDICT\s*#?(\d+)\s*[:\-]\s*\**\s*(REAL|FALSE)',
      caseSensitive: false);
  for (final m in line.allMatches(verdicts)) {
    if (m.group(2)!.toUpperCase() == 'FALSE') {
      dismissed.add(int.parse(m.group(1)!) - 1);
    }
  }
  return [
    for (var i = 0; i < issues.length; i++)
      if (!dismissed.contains(i)) issues[i],
  ];
}
