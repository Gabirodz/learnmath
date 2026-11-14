import 'package:flutter/material.dart';

import 'math_check.dart';

/// Says above the notes what the SymPy checks found: nothing to see when all
/// is well beyond one quiet line, a clear warning when a computation in the
/// notes disagrees with SymPy.
class CheckBanner extends StatelessWidget {
  const CheckBanner({
    super.key,
    required this.checks,
    required this.report,
    this.onCheckNow,
  });

  final List<MathCheck> checks;

  /// Null when the checks have not been run.
  final CheckReport? report;

  /// Runs the checks; null where that is not possible (or already running).
  final VoidCallback? onCheckNow;

  @override
  Widget build(BuildContext context) {
    if (checks.isEmpty) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final r = report;
    final n = checks.length;
    String plural(int k) => k == 1 ? 'computation' : 'computations';

    if (r == null || r.outcomes.length != n) {
      return _Strip(
        icon: Icons.rule,
        color: scheme.onSurfaceVariant,
        text: '$n ${plural(n)} in these notes '
            '${n == 1 ? 'has' : 'have'} not been checked yet.',
        action: onCheckNow == null
            ? null
            : TextButton(onPressed: onCheckNow, child: const Text('Check now')),
      );
    }

    final failed = r.failed;
    final unsure = r.inconclusive;
    if (failed.isEmpty && unsure.isEmpty) {
      return _Strip(
        icon: Icons.verified_outlined,
        color: scheme.primary,
        text: 'All $n ${plural(n)} checked with SymPy'
            '${r.repaired ? ', after one correction' : ''}.',
      );
    }

    final warn = failed.isNotEmpty;
    final title = warn
        ? '${failed.length} of $n ${plural(n)} '
            '${failed.length == 1 ? 'disagrees' : 'disagree'} with SymPy'
        : '${unsure.length} of $n ${plural(n)} could not be checked';
    final fg = warn ? scheme.onErrorContainer : scheme.onSurfaceVariant;
    return Material(
      color: warn ? scheme.errorContainer : scheme.surfaceContainerHighest,
      child: Theme(
        // No divider lines around the expanded list.
        data: theme.copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          leading: Icon(warn ? Icons.warning_amber_rounded : Icons.help_outline,
              color: fg),
          title: Text(title,
              style: theme.textTheme.titleSmall?.copyWith(color: fg)),
          subtitle: Text(
            warn
                ? 'Verify these against a textbook before relying on them.'
                : 'The other ${r.passed} passed.',
            style: theme.textTheme.bodySmall?.copyWith(color: fg),
          ),
          iconColor: fg,
          collapsedIconColor: fg,
          childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
          expandedCrossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final o in [...failed, ...unsure])
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text.rich(
                  TextSpan(children: [
                    TextSpan(
                        text: o.title,
                        style: const TextStyle(fontWeight: FontWeight.w600)),
                    TextSpan(
                        text: switch (o.status) {
                      CheckStatus.failed => '\n${o.detail ?? 'assertion failed'}',
                      CheckStatus.timeout => '\nTook too long to check.',
                      _ => '\nThe check itself did not run.',
                    }),
                  ]),
                  style: theme.textTheme.bodySmall?.copyWith(color: fg),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _Strip extends StatelessWidget {
  const _Strip(
      {required this.icon, required this.color, required this.text, this.action});

  final IconData icon;
  final Color color;
  final String text;
  final Widget? action;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 8, 4),
        child: Row(
          children: [
            Icon(icon, size: 18, color: color),
            const SizedBox(width: 8),
            Expanded(
              child: Text(text,
                  style: Theme.of(context)
                      .textTheme
                      .bodySmall
                      ?.copyWith(color: color)),
            ),
            ?action,
          ],
        ),
      );
}
