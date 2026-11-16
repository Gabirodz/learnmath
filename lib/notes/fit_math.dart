import 'dart:math' as math;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_math_fork/ast.dart';
import 'package:flutter_math_fork/flutter_math.dart';

const _relPenalty = 500;
const _binPenalty = 700;

/// A formula that fits the width it is given:
///
/// * as it is, when it fits;
/// * scaled down, but to no less than [minScale], when that is enough;
/// * otherwise at [minScale] and broken into lines after its top-level
///   relations (`=`, `<`, `\in`, `\Rightarrow`, ...), as TeX breaks inline
///   math. It is not broken after `+` or `-`, so `|x - y|` stays whole.
///
/// While the formula fits on one line it is typeset as one piece, so its
/// spacing is exactly TeX's. A piece that cannot be broken (a wide
/// fraction or matrix) and is still too wide overflows. Meant for inline
/// math: as a [WidgetSpan] child it is given the paragraph's width.
class FitMath extends StatelessWidget {
  const FitMath(
    this.tex, {
    super.key,
    required this.textStyle,
    this.mathStyle = MathStyle.text,
    this.minScale = 0.7,
    this.center = true,
    this.textScaleFactor,
    this.onErrorFallback,
  });

  final String tex;
  final TextStyle textStyle;
  final MathStyle mathStyle;
  final double minScale;

  /// Centre broken lines on each other; otherwise they start at the left.
  final bool center;

  /// As for [Math.tex]: null follows the ambient text scale.
  final double? textScaleFactor;
  final Widget Function(FlutterMathException e)? onErrorFallback;

  @override
  Widget build(BuildContext context) {
    final whole = Math.tex(
      tex,
      mathStyle: mathStyle,
      textScaleFactor: textScaleFactor,
      textStyle: textStyle,
      onErrorFallback: onErrorFallback ?? Math.defaultOnErrorFallback,
    );
    if (whole.parseError != null) return whole;

    // texBreak splits after every relation and binary operator; join the
    // pieces again across operators so lines break only after relations,
    // and the operators keep their spacing. The pieces come from a second
    // parse: syntax nodes carry GlobalKeys, so the whole formula and its
    // pieces cannot share them.
    final raw = Math.tex(
      tex,
      mathStyle: mathStyle,
      textScaleFactor: textScaleFactor,
      textStyle: textStyle,
    ).texBreak(relPenalty: _relPenalty, binOpPenalty: _binPenalty);
    final parts = <Math>[];
    var row = <GreenNode>[];
    for (var i = 0; i < raw.parts.length; i++) {
      row.addAll(raw.parts[i].ast!.greenRoot.children);
      final last = i == raw.parts.length - 1;
      if (last || raw.penalties[i] == _relPenalty) {
        parts.add(Math(
          ast: SyntaxTree(greenRoot: EquationRowNode(children: row)),
          mathStyle: whole.mathStyle,
          logicalPpi: whole.logicalPpi,
          onErrorFallback: whole.onErrorFallback,
          options: whole.options,
          textScaleFactor: whole.textScaleFactor,
          textStyle: whole.textStyle,
        ));
        row = <GreenNode>[];
      }
    }

    // A piece that ends in a relation lost the thick space (5/18 em) TeX
    // puts after it; it is put back between pieces on the same line.
    final em = (textStyle.fontSize ?? 16) *
        (textScaleFactor ?? MediaQuery.textScalerOf(context).scale(1));
    return _FitLayout(
      minScale: minScale,
      center: center,
      gap: em * 5 / 18,
      children: [whole, if (parts.length > 1) ...parts],
    );
  }
}

/// Children: the whole formula, then (when it can be broken) its pieces.
class _FitLayout extends MultiChildRenderObjectWidget {
  const _FitLayout({
    required this.minScale,
    required this.center,
    required this.gap,
    required super.children,
  });

  final double minScale;
  final bool center;
  final double gap;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderFit(minScale, center, gap);

  @override
  void updateRenderObject(BuildContext context, _RenderFit renderObject) {
    renderObject
      ..minScale = minScale
      ..center = center
      ..gap = gap;
  }
}

class _FitParentData extends ContainerBoxParentData<RenderBox> {}

/// Result of a layout: which children are shown, where (before scaling),
/// at what scale, the size and the first line's baseline after scaling.
class _Plan {
  _Plan(this.shown, this.offsets, this.scale, this.size, this.baseline);
  final List<int> shown;
  final List<Offset> offsets;
  final double scale;
  final Size size;
  final double baseline;
}

class _RenderFit extends RenderBox
    with
        ContainerRenderObjectMixin<RenderBox, _FitParentData>,
        RenderBoxContainerDefaultsMixin<RenderBox, _FitParentData> {
  _RenderFit(this._minScale, this._center, this._gap);

  double _minScale;
  set minScale(double v) {
    if (v == _minScale) return;
    _minScale = v;
    markNeedsLayout();
  }

  bool _center;
  set center(bool v) {
    if (v == _center) return;
    _center = v;
    markNeedsLayout();
  }

  double _gap;
  set gap(double v) {
    if (v == _gap) return;
    _gap = v;
    markNeedsLayout();
  }

  double _scale = 1;
  double _baseline = 0;
  List<int> _shown = const [];

  @override
  void setupParentData(RenderBox child) {
    if (child.parentData is! _FitParentData) {
      child.parentData = _FitParentData();
    }
  }

  List<RenderBox> get _kids {
    final out = <RenderBox>[];
    var c = firstChild;
    while (c != null) {
      out.add(c);
      c = (c.parentData! as _FitParentData).nextSibling;
    }
    return out;
  }

  _Plan _plan(double maxWidth, List<Size> sizes, List<double> baselines) {
    final whole = sizes.first;
    if (!maxWidth.isFinite || whole.width <= maxWidth) {
      return _Plan([0], [Offset.zero], 1, whole, baselines.first);
    }
    if (whole.width * _minScale <= maxWidth || sizes.length < 3) {
      // Shrinking is enough, or there is nothing to break at.
      final s = math.max(maxWidth / whole.width, _minScale);
      return _Plan([0], [Offset.zero], s, whole * s, baselines.first * s);
    }

    // Break: pieces 1..n at the smallest scale, greedy lines, the
    // relation's space between pieces that share a line.
    final scale = _minScale;
    final limit = maxWidth / scale;
    final lines = <List<int>>[];
    var cur = <int>[];
    var w = 0.0;
    for (var i = 1; i < sizes.length; i++) {
      final add = sizes[i].width + (cur.isEmpty ? 0 : _gap);
      if (cur.isNotEmpty && w + add > limit) {
        lines.add(cur);
        cur = [i];
        w = sizes[i].width;
      } else {
        cur.add(i);
        w += add;
      }
    }
    if (cur.isNotEmpty) lines.add(cur);

    double widthOf(List<int> l) =>
        l.fold(0.0, (s, i) => s + sizes[i].width) + _gap * (l.length - 1);
    final width = lines.map(widthOf).fold(0.0, math.max);
    final shown = <int>[];
    final offsets = <Offset>[];
    var y = 0.0;
    var firstBaseline = 0.0;
    for (var k = 0; k < lines.length; k++) {
      var ascent = 0.0, descent = 0.0;
      for (final i in lines[k]) {
        ascent = math.max(ascent, baselines[i]);
        descent = math.max(descent, sizes[i].height - baselines[i]);
      }
      if (k == 0) firstBaseline = ascent;
      var x = _center ? (width - widthOf(lines[k])) / 2 : 0.0;
      for (final i in lines[k]) {
        shown.add(i);
        offsets.add(Offset(x, y + ascent - baselines[i]));
        x += sizes[i].width + _gap;
      }
      y += ascent + descent + (k < lines.length - 1 ? 2 : 0);
    }
    return _Plan(shown, offsets, scale, Size(width * scale, y * scale),
        firstBaseline * scale);
  }

  @override
  void performLayout() {
    final kids = _kids;
    final sizes = <Size>[];
    final baselines = <double>[];
    for (final k in kids) {
      k.layout(const BoxConstraints(), parentUsesSize: true);
      sizes.add(k.size);
      baselines.add(
          k.getDistanceToBaseline(TextBaseline.alphabetic, onlyReal: true) ??
              k.size.height);
    }
    final p = _plan(constraints.maxWidth, sizes, baselines);
    for (var j = 0; j < p.shown.length; j++) {
      (kids[p.shown[j]].parentData! as _FitParentData).offset = p.offsets[j];
    }
    _shown = p.shown;
    _scale = p.scale;
    _baseline = p.baseline;
    size = constraints.constrain(p.size);
  }

  _Plan _dryPlan(BoxConstraints constraints) {
    const loose = BoxConstraints();
    final kids = _kids;
    final sizes = [for (final k in kids) k.getDryLayout(loose)];
    final baselines = [
      for (var i = 0; i < kids.length; i++)
        kids[i].getDryBaseline(loose, TextBaseline.alphabetic) ??
            sizes[i].height
    ];
    return _plan(constraints.maxWidth, sizes, baselines);
  }

  @override
  Size computeDryLayout(BoxConstraints constraints) =>
      constraints.constrain(_dryPlan(constraints).size);

  @override
  double? computeDryBaseline(
          BoxConstraints constraints, TextBaseline baseline) =>
      _dryPlan(constraints).baseline;

  @override
  double? computeDistanceToActualBaseline(TextBaseline baseline) => _baseline;

  @override
  double computeMinIntrinsicWidth(double height) {
    final kids = _kids;
    final pieces = kids.length > 1 ? kids.skip(1) : kids;
    return pieces.fold(0.0,
            (m, k) => math.max(m, k.getMaxIntrinsicWidth(double.infinity))) *
        _minScale;
  }

  @override
  double computeMaxIntrinsicWidth(double height) =>
      firstChild?.getMaxIntrinsicWidth(double.infinity) ?? 0;

  @override
  double computeMinIntrinsicHeight(double width) =>
      firstChild?.getMaxIntrinsicHeight(double.infinity) ?? 0;

  @override
  double computeMaxIntrinsicHeight(double width) =>
      computeMinIntrinsicHeight(width);

  Matrix4 get _transform => Matrix4.diagonal3Values(_scale, _scale, 1);

  void _paintShown(PaintingContext context, Offset offset) {
    final kids = _kids;
    for (final i in _shown) {
      final pd = kids[i].parentData! as _FitParentData;
      context.paintChild(kids[i], offset + pd.offset);
    }
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    if (_scale == 1) {
      layer = null;
      _paintShown(context, offset);
      return;
    }
    layer = context.pushTransform(
      needsCompositing,
      offset,
      _transform,
      _paintShown,
      oldLayer: layer is TransformLayer ? layer! as TransformLayer : null,
    );
  }

  @override
  void applyPaintTransform(RenderBox child, Matrix4 transform) {
    final o = (child.parentData! as _FitParentData).offset;
    transform
      ..multiply(_transform)
      ..multiply(Matrix4.translationValues(o.dx, o.dy, 0));
  }

  /// Only what is drawn is read out: the whole formula, or its pieces.
  @override
  void visitChildrenForSemantics(RenderObjectVisitor visitor) {
    final kids = _kids;
    for (final i in _shown) {
      visitor(kids[i]);
    }
  }

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) {
    final kids = _kids;
    return result.addWithPaintTransform(
      transform: _transform,
      position: position,
      hitTest: (r, p) {
        for (final i in _shown) {
          final pd = kids[i].parentData! as _FitParentData;
          final hit = r.addWithPaintOffset(
            offset: pd.offset,
            position: p,
            hitTest: (r2, p2) => kids[i].hitTest(r2, position: p2),
          );
          if (hit) return true;
        }
        return false;
      },
    );
  }
}
