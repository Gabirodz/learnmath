import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'math_check.dart';

/// Runs checks with a local `python3` and SymPy.
///
/// For development machines and tests only: the phone has no Python, it uses
/// the Pyodide runner. Runs the same [checkHarnessPython], so a check behaves
/// the same in both. Checks are untrusted model output and run with the
/// user's full privileges here, so do not point this at anything but your own
/// lessons.
///
/// One interpreter serves a whole [run]. When a check exceeds its timeout the
/// interpreter is killed, the check is reported as [CheckStatus.timeout] and a
/// new interpreter continues with the remaining checks.
class ProcessCheckRunner implements MathCheckRunner {
  ProcessCheckRunner([this.python = 'python3']);

  /// The Python executable.
  final String python;

  /// Whether [python] can import SymPy.
  static Future<bool> isAvailable([String python = 'python3']) async {
    try {
      final r = await Process.run(python, ['-c', 'import sympy']);
      return r.exitCode == 0;
    } on ProcessException {
      return false;
    }
  }

  // Reads one JSON request per line on stdin and answers one JSON line each.
  // The harness is exec'd into a namespace of its own and checks' stdout is
  // redirected to stderr so a stray print cannot corrupt the protocol.
  static const _server = r'''
import sys, json
real_out = sys.stdout
sys.stdout = sys.stderr
ns = {}
exec(sys.argv[1], ns)
exec("from sympy import *", {})
real_out.write("ready\n"); real_out.flush()
for line in sys.stdin:
    code = json.loads(line)
    real_out.write(ns["run_check"](code) + "\n"); real_out.flush()
''';

  @override
  Future<List<CheckOutcome>> run(
    List<MathCheck> checks, {
    Duration perCheckTimeout = const Duration(seconds: 20),
    void Function(int done, int total)? onProgress,
  }) async {
    final outcomes = <CheckOutcome>[];
    _Interpreter? interpreter;
    try {
      for (final check in checks) {
        interpreter ??= await _Interpreter.start(python);
        final CheckOutcome outcome;
        try {
          final answer =
              await interpreter.ask(check.code).timeout(perCheckTimeout);
          outcome = _outcome(check, answer);
        } on TimeoutException {
          interpreter.kill();
          interpreter = null;
          outcomes.add(CheckOutcome(
            title: check.title,
            status: CheckStatus.timeout,
            detail: 'Stopped after ${perCheckTimeout.inSeconds} s.',
          ));
          onProgress?.call(outcomes.length, checks.length);
          continue;
        }
        outcomes.add(outcome);
        onProgress?.call(outcomes.length, checks.length);
      }
    } finally {
      interpreter?.kill();
    }
    return outcomes;
  }

  CheckOutcome _outcome(MathCheck check, String answer) {
    try {
      final json = (jsonDecode(answer) as Map).cast<String, Object?>();
      final status =
          CheckStatus.values.asNameMap()[json['status']] ?? CheckStatus.error;
      final detail = json['detail'] as String?;
      return CheckOutcome(
        title: check.title,
        status: status,
        detail: status == CheckStatus.passed || detail == null || detail.isEmpty
            ? null
            : detail,
      );
    } on Object {
      return CheckOutcome(
        title: check.title,
        status: CheckStatus.error,
        detail: 'Unreadable result from Python: $answer',
      );
    }
  }

  @override
  Future<void> dispose() async {}
}

/// A running Python process speaking the line protocol of
/// [ProcessCheckRunner._server].
class _Interpreter {
  _Interpreter._(this._process, this._lines);

  final Process _process;
  final StreamIterator<String> _lines;

  static Future<_Interpreter> start(String python) async {
    final Process process;
    try {
      process = await Process.start(
          python, ['-c', ProcessCheckRunner._server, checkHarnessPython]);
    } on ProcessException catch (e) {
      throw MathCheckException('Could not start $python: ${e.message}');
    }
    // Drain stderr so a chatty check cannot fill the pipe and block.
    process.stderr.drain<void>();
    final lines = StreamIterator(
        process.stdout.transform(utf8.decoder).transform(const LineSplitter()));
    final interpreter = _Interpreter._(process, lines);
    if (!await lines.moveNext() || lines.current != 'ready') {
      process.kill(ProcessSignal.sigkill);
      throw MathCheckException('$python could not start the check harness.');
    }
    return interpreter;
  }

  Future<String> ask(String code) async {
    _process.stdin.writeln(jsonEncode(code));
    await _process.stdin.flush();
    if (!await _lines.moveNext()) {
      throw MathCheckException('Python exited while running a check.');
    }
    return _lines.current;
  }

  void kill() {
    _process.kill(ProcessSignal.sigkill);
  }
}
