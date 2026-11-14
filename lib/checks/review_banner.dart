import 'package:flutter/material.dart';

import 'proof_review.dart';

/// Says above the notes what the second model found when it refereed the
/// proofs: a quiet line while it works or when it found nothing, an
/// expandable warning listing what remains wrong otherwise.
class ReviewBanner extends StatelessWidget {
  const ReviewBanner({super.key, required this.review});

  /// Null when no review was asked for.
  final ProofReview? review;

  @override
  Widget build(BuildContext context) {
    final r = review;
    if (r == null) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    if (!r.isDone) {
      return _Strip(
        icon: Icons.hourglass_empty,
        color: scheme.onSurfaceVariant,
        text: 'A second model is reviewing the proofs…',
      );
    }
    if (r.issues.isEmpty) {
      return _Strip(
        icon: Icons.verified_outlined,
        color: scheme.primary,
        text: 'Proofs reviewed by a second model: no errors found'
            '${r.rewritten ? ', after one correction' : ''}',
      );
    }

    final n = r.issues.length;
    final fg = scheme.onErrorContainer;
    return Material(
      color: scheme.errorContainer,
      child: Theme(
        data: theme.copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          leading: Icon(Icons.warning_amber_rounded, color: fg),
          title: Text(
              '$n possible ${n == 1 ? 'error' : 'errors'} found by a second model',
              style: theme.textTheme.titleSmall?.copyWith(color: fg)),
          subtitle: Text(
            r.rewritten
                ? 'The notes were corrected once; these remain.'
                : 'Verify these against a textbook before relying on them.',
            style: theme.textTheme.bodySmall?.copyWith(color: fg),
          ),
          iconColor: fg,
          collapsedIconColor: fg,
          childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
          expandedCrossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Long lists scroll inside the banner instead of pushing the
            // notes off the screen.
            ConstrainedBox(
              constraints: BoxConstraints(
                  maxHeight: MediaQuery.sizeOf(context).height * 0.4),
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (final i in r.issues)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 10),
                        child: Text.rich(
                          TextSpan(children: [
                            TextSpan(
                                text: i.summary,
                                style:
                                    const TextStyle(fontWeight: FontWeight.bold)),
                            if (i.where.isNotEmpty)
                              TextSpan(text: '\nWhere: ${i.where}'),
                            if (i.why.isNotEmpty)
                              TextSpan(text: '\nWhy: ${i.why}'),
                            if (i.fix.isNotEmpty)
                              TextSpan(text: '\nFix: ${i.fix}'),
                          ]),
                          style: theme.textTheme.bodySmall?.copyWith(color: fg),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Strip extends StatelessWidget {
  const _Strip({required this.icon, required this.color, required this.text});

  final IconData icon;
  final Color color;
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
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
          ],
        ),
      );
}
