import 'package:flutter/material.dart';
import 'package:learnmath/notes/fit_math.dart';

/// Subtitle line: plain text with inline `$...$` LaTeX rendered as math.
/// Wraps like normal text. A formula wider than the line is shrunk (to 70 %
/// at least) and, if still too wide, broken after its relations and
/// operators ([FitMath]). Formulas that fail to parse show as raw TeX.
class SubtitleText extends StatelessWidget {
  const SubtitleText(
    this.text, {
    super.key,
    required this.style,
    this.maxLines,
  });

  final String text;
  final TextStyle style;
  final int? maxLines;

  static final _math = RegExp(r'\$\$?([^$]+)\$\$?');

  @override
  Widget build(BuildContext context) {
    final spans = <InlineSpan>[];
    var last = 0;
    for (final m in _math.allMatches(text)) {
      if (m.start > last) {
        spans.add(TextSpan(text: text.substring(last, m.start)));
      }
      final tex = m.group(1)!.trim();
      spans.add(
        WidgetSpan(
          alignment: PlaceholderAlignment.baseline,
          baseline: TextBaseline.alphabetic,
          child: FitMath(
            tex,
            textStyle: style,
            onErrorFallback: (_) => Text(tex, style: style),
          ),
        ),
      );
      last = m.end;
    }
    if (last < text.length) spans.add(TextSpan(text: text.substring(last)));
    return Text.rich(
      TextSpan(style: style, children: spans),
      textAlign: TextAlign.center,
      maxLines: maxLines,
      overflow: maxLines == null ? null : TextOverflow.ellipsis,
    );
  }
}
