import '../checks/math_check.dart';

/// Help the tutor wrote for one exercise of a lesson, kept with the lesson so
/// asking again is instant.
class ExerciseHelp {
  const ExerciseHelp({
    required this.index,
    this.hint,
    this.solution,
    this.checks = const [],
    this.checkReport,
  });

  /// Position of the exercise in the notes' Exercises section (0-based).
  final int index;

  /// Markdown with LaTeX, like the notes.
  final String? hint;
  final String? solution;

  /// SymPy checks of the computations in [solution].
  final List<MathCheck> checks;
  final CheckReport? checkReport;

  ExerciseHelp copyWith({
    String? hint,
    String? solution,
    List<MathCheck>? checks,
    CheckReport? checkReport,
  }) =>
      ExerciseHelp(
        index: index,
        hint: hint ?? this.hint,
        solution: solution ?? this.solution,
        checks: checks ?? this.checks,
        checkReport: checkReport ?? this.checkReport,
      );

  Map<String, Object?> toJson() => {
        'index': index,
        'hint': hint,
        'solution': solution,
        'checks': [for (final c in checks) c.toJson()],
        'checkReport': checkReport?.toJson(),
      };

  factory ExerciseHelp.fromJson(Map<String, Object?> j) => ExerciseHelp(
        index: (j['index'] as num?)?.toInt() ?? 0,
        hint: j['hint'] as String?,
        solution: j['solution'] as String?,
        checks: [
          for (final c in (j['checks'] as List? ?? const []))
            MathCheck.fromJson((c as Map).cast<String, Object?>()),
        ],
        checkReport: j['checkReport'] is Map
            ? CheckReport.fromJson(
                (j['checkReport'] as Map).cast<String, Object?>())
            : null,
      );
}
