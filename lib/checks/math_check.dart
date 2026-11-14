/// Machine checks of a lesson's computations.
///
/// The lesson model appends a block of small SymPy programs to its notes, one
/// per computational claim (a derivative, an integral, an identity, a matrix
/// computation, a counterexample). They are executed locally, not by a model,
/// so a wrong computation shows up as a failed assertion.
library;

/// One SymPy program asserting one claim of the notes.
class MathCheck {
  const MathCheck({required this.title, required this.code});

  /// What is being checked, as the notes call it ("Example 2: the integral").
  final String title;

  /// Python source. Runs with `from sympy import *` already done and must
  /// `assert` the claim.
  final String code;

  Map<String, Object?> toJson() => {'title': title, 'code': code};

  factory MathCheck.fromJson(Map<String, Object?> j) => MathCheck(
        title: j['title'] as String? ?? '',
        code: j['code'] as String? ?? '',
      );
}

enum CheckStatus {
  /// The assertion held.
  passed,

  /// An assertion was false: the notes and SymPy disagree.
  failed,

  /// The check itself did not run (syntax error, unknown name, ...), so it
  /// says nothing about the notes.
  error,

  /// The check ran too long and was stopped.
  timeout;

  /// Whether the claim was neither confirmed nor refuted.
  bool get inconclusive => this == error || this == timeout;
}

class CheckOutcome {
  const CheckOutcome({required this.title, required this.status, this.detail});

  final String title;
  final CheckStatus status;

  /// Error text for anything but [CheckStatus.passed].
  final String? detail;

  Map<String, Object?> toJson() => {
        'title': title,
        'status': status.name,
        if (detail != null) 'detail': detail,
      };

  factory CheckOutcome.fromJson(Map<String, Object?> j) => CheckOutcome(
        title: j['title'] as String? ?? '',
        status:
            CheckStatus.values.asNameMap()[j['status']] ?? CheckStatus.error,
        detail: j['detail'] as String?,
      );
}

/// What the checks said about a lesson's notes; stored with the lesson.
class CheckReport {
  const CheckReport({required this.outcomes, this.repaired = false});

  final List<CheckOutcome> outcomes;

  /// Whether the notes were rewritten once because checks had failed.
  final bool repaired;

  int get total => outcomes.length;
  int get passed =>
      outcomes.where((o) => o.status == CheckStatus.passed).length;
  List<CheckOutcome> get failed =>
      [for (final o in outcomes) if (o.status == CheckStatus.failed) o];
  List<CheckOutcome> get inconclusive =>
      [for (final o in outcomes) if (o.status.inconclusive) o];

  Map<String, Object?> toJson() => {
        'outcomes': [for (final o in outcomes) o.toJson()],
        'repaired': repaired,
      };

  factory CheckReport.fromJson(Map<String, Object?> j) => CheckReport(
        outcomes: [
          for (final o in (j['outcomes'] as List? ?? const []))
            CheckOutcome.fromJson((o as Map).cast<String, Object?>()),
        ],
        repaired: j['repaired'] as bool? ?? false,
      );
}

/// Executes [MathCheck]s with SymPy. Outcomes come back in input order, one
/// per check.
abstract class MathCheckRunner {
  Future<List<CheckOutcome>> run(
    List<MathCheck> checks, {
    Duration perCheckTimeout = const Duration(seconds: 20),
    void Function(int done, int total)? onProgress,
  });

  Future<void> dispose();
}

class MathCheckException implements Exception {
  MathCheckException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Python run once per interpreter before any check. Defines
/// `run_check(code) -> str`, which returns a JSON object
/// `{"status": "passed" | "failed" | "error", "detail": str}`.
///
/// Shared by every runner so a check behaves the same on the phone (Pyodide)
/// and on a development machine (CPython).
const String checkHarnessPython = r'''
import json, traceback

def _fresh_namespace():
    ns = {"__name__": "__check__"}
    exec("from sympy import *", ns)
    return ns

def _last_line(exc):
    text = "".join(traceback.format_exception_only(type(exc), exc)).strip()
    return text[-600:]

def run_check(code):
    try:
        compiled = compile(code, "<check>", "exec")
    except SyntaxError as e:
        return json.dumps({"status": "error", "detail": _last_line(e)})
    try:
        exec(compiled, _fresh_namespace())
    except AssertionError as e:
        line = None
        tb = e.__traceback__
        while tb is not None:
            if tb.tb_frame.f_code.co_filename == "<check>":
                line = tb.tb_lineno
            tb = tb.tb_next
        src = code.splitlines()[line - 1].strip() if line else ""
        msg = str(e)
        detail = "assertion failed" + (": " + msg if msg else "") + (" at `" + src + "`" if src else "")
        return json.dumps({"status": "failed", "detail": detail[-600:]})
    except BaseException as e:
        return json.dumps({"status": "error", "detail": _last_line(e)})
    return json.dumps({"status": "passed", "detail": ""})
''';
