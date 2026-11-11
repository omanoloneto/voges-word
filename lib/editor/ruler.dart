import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_quill/flutter_quill.dart';

import '../l10n/l10n.dart';
import 'editor_session.dart';
import 'paragraph_indents.dart';

const rulerSize = 22.0;

const _pointsPerCm = 72 / 2.54;

/// Drags land on quarters of a centimeter; with Alt, on hundredths.
const _snap = _pointsPerCm / 4;
const _fineSnap = _pointsPerCm / 100;

/// Text the margins and indents leave at least, as in Word.
const _minText = _pointsPerCm;

const _bandStart = 3.0;
const _bandEnd = rulerSize - 3;

const _marginColor = Color(0xFFD3D3D3);
const _textColor = Color(0xFFFFFFFF);
const _markColor = Color(0xFF5C5C5C);
const _markerFill = Color(0xFFF4F4F4);
const _markerDragged = Color(0xFFD5E3F6);
const _markerStroke = Color(0xFF666666);
const _guideColor = Color(0xFF6E6E6E);

double _snapped(double points) {
  final step = HardwareKeyboard.instance.isAltPressed ? _fineSnap : _snap;
  return (points / step).round() * step;
}

/// Where a margin or indent being dragged will land, drawn across the
/// paper: a vertical line at [x] or a horizontal line at [y].
@immutable
class RulerGuide {
  const RulerGuide({this.x, this.y});

  final double? x;
  final double? y;
}

/// The ruler above the paper: the page in centimeters from the left margin,
/// the margins, and the indents of the paragraph at the caret.
class HorizontalRuler extends StatefulWidget {
  const HorizontalRuler({
    required this.session,
    required this.scale,
    required this.pageLeft,
    required this.guide,
    super.key,
  });

  final EditorSession session;

  /// Pixels per point.
  final double scale;

  /// Where the page starts, from the left of the ruler.
  final double pageLeft;

  final ValueNotifier<RulerGuide?> guide;

  @override
  State<HorizontalRuler> createState() => _HorizontalRulerState();
}

enum _Part {
  leftMargin,
  rightMargin,
  firstLine,
  hanging,
  leftIndent,
  rightIndent,
}

class _HorizontalDrag {
  _HorizontalDrag(this.part, this.grab, this.margins, this.indents);

  final _Part part;

  /// Distance from the pointer to the dragged mark.
  final double grab;

  EdgeInsets margins;
  ParagraphIndents? indents;
}

class _HorizontalRulerState extends State<HorizontalRuler> {
  QuillController? _controller;
  ValueListenable<QuillController>? _active;
  ParagraphIndents? _indents;
  var _scheduled = false;
  _HorizontalDrag? _drag;

  EditorSession get _session => widget.session;

  @override
  void initState() {
    super.initState();
    _watch();
    _indents = _currentIndents();
  }

  @override
  void didUpdateWidget(HorizontalRuler oldWidget) {
    super.didUpdateWidget(oldWidget);
    _watch();
    _schedule();
  }

  @override
  void dispose() {
    _controller?.removeListener(_schedule);
    _active?.removeListener(_schedule);
    super.dispose();
  }

  void _watch() {
    final controller = _session.controller;
    if (controller != _controller) {
      _controller?.removeListener(_schedule);
      _controller = controller..addListener(_schedule);
    }
    final active = _session.activeController;
    if (active != _active) {
      _active?.removeListener(_schedule);
      _active = active..addListener(_schedule);
    }
  }

  /// Once per frame at most, however many edits it brings.
  void _schedule() {
    if (_scheduled) return;
    _scheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scheduled = false;
      if (!mounted) return;
      final indents = _currentIndents();
      if (indents != _indents) setState(() => _indents = indents);
    });
  }

  /// A table cell being edited has no indents on the ruler.
  ParagraphIndents? _currentIndents() {
    final controller = _session.controller;
    if (_session.activeController.value != controller) return null;
    return indentsAt(
      controller.document,
      controller.selection.start,
      _session.look,
    );
  }

  double get _textLeft =>
      widget.pageLeft +
      (_drag?.margins ?? _session.look.margins).left * widget.scale;

  double get _textRight {
    final look = _session.look;
    final margins = _drag?.margins ?? look.margins;
    return widget.pageLeft + (look.pageWidth - margins.right) * widget.scale;
  }

  double _positionOf(_Part part, ParagraphIndents? indents) {
    final scale = widget.scale;
    return switch (part) {
      _Part.leftMargin => _textLeft,
      _Part.rightMargin => _textRight,
      _Part.firstLine => _textLeft + indents!.firstLineStart * scale,
      _Part.hanging || _Part.leftIndent => _textLeft + indents!.left * scale,
      _Part.rightIndent => _textRight - indents!.right * scale,
    };
  }

  double _localX(Offset global) =>
      (context.findRenderObject()! as RenderBox).globalToLocal(global).dx;

  void _start(_Part part, Offset global) {
    final indents = _indents;
    final grab = _localX(global) - _positionOf(part, indents);
    setState(
      () => _drag = _HorizontalDrag(part, grab, _session.look.margins, indents),
    );
  }

  void _update(Offset global) {
    final drag = _drag;
    if (drag == null) return;
    final look = _session.look;
    final scale = widget.scale;
    final x = _localX(global) - drag.grab;
    final margins = look.margins;
    final width = look.pageWidth;
    final indents = _indents;
    final textWidth = width - margins.horizontal;
    setState(() {
      switch (drag.part) {
        case _Part.leftMargin:
          final left = _snapped(
            (x - widget.pageLeft) / scale,
          ).clamp(0.0, width - margins.right - _minText);
          drag.margins = margins.copyWith(left: left);
        case _Part.rightMargin:
          final right = _snapped(
            width - (x - widget.pageLeft) / scale,
          ).clamp(0.0, width - margins.left - _minText);
          drag.margins = margins.copyWith(right: right);
        case _Part.firstLine:
          final double reach = math.max(
            0,
            textWidth - indents!.right - _minText,
          );
          final start = _snapped((x - _textLeft) / scale).clamp(0.0, reach);
          drag.indents = _indentsWith(indents, firstLine: start - indents.left);
        case _Part.hanging:
          final left = _leftAt(x, indents!, textWidth);
          drag.indents = _indentsWith(
            indents,
            left: left,
            firstLine: indents.firstLineStart - left,
          );
        case _Part.leftIndent:
          drag.indents = _indentsWith(
            indents!,
            left: _leftAt(x, indents, textWidth),
          );
        case _Part.rightIndent:
          final double reach = math.max(
            0,
            textWidth -
                math.max(indents!.left, indents.firstLineStart) -
                _minText,
          );
          final right = _snapped(
            textWidth - (x - _textLeft) / scale,
          ).clamp(0.0, reach);
          drag.indents = _indentsWith(indents, right: right);
      }
    });
    widget.guide.value = RulerGuide(x: _positionOf(drag.part, drag.indents));
  }

  /// Left indents keep to the steps of the indent buttons.
  double _leftAt(double x, ParagraphIndents indents, double textWidth) {
    final room = textWidth - indents.right - _minText;
    final levels = math.max(0, math.min(maxIndentLevel, room ~/ indentStep));
    final level = ((x - _textLeft) / widget.scale / indentStep).round();
    return math.max(0, math.min(level, levels)) * indentStep;
  }

  ParagraphIndents _indentsWith(
    ParagraphIndents indents, {
    double? left,
    double? firstLine,
    double? right,
  }) => ParagraphIndents(
    left: left ?? indents.left,
    firstLine: firstLine ?? indents.firstLine,
    right: right ?? indents.right,
  );

  void _end() {
    final drag = _drag;
    widget.guide.value = null;
    if (drag == null) return;
    setState(() => _drag = null);
    final look = _session.look;
    if (drag.margins != look.margins) {
      _session.setPageSetup(margins: drag.margins);
      return;
    }
    final before = _indents;
    final after = drag.indents;
    if (before == null || after == null || after == before) return;
    final controller = _session.controller;
    final level = after.left == before.left
        ? null
        : (after.left / indentStep).round();
    switch (drag.part) {
      case _Part.firstLine:
        setIndents(controller, look, firstLine: after.firstLine);
      case _Part.hanging:
        setIndents(controller, look, level: level, firstLine: after.firstLine);
      case _Part.leftIndent:
        if (level != null) setIndents(controller, look, level: level);
      case _Part.rightIndent:
        setIndents(controller, look, right: after.right);
      case _Part.leftMargin || _Part.rightMargin:
        break;
    }
  }

  void _cancel() {
    widget.guide.value = null;
    if (_drag != null) setState(() => _drag = null);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final look = _session.look;
    final scale = widget.scale;
    final drag = _drag;
    final indents = drag?.indents ?? _indents;
    final textLeft = _textLeft;
    final textRight = _textRight;

    // A margin is grabbed anywhere on its gray part or at its edge.
    Widget grip(_Part part, String tooltip, double from, double to) => _Grip(
      rect: Rect.fromLTRB(from, 0, to, rulerSize),
      tooltip: tooltip,
      cursor: SystemMouseCursors.resizeLeftRight,
      axis: Axis.horizontal,
      onStart: (global) => _start(part, global),
      onUpdate: _update,
      onEnd: _end,
      onCancel: _cancel,
    );

    Widget marker(_Part part, String tooltip, _Shape shape, double x) {
      final top = switch (shape) {
        _Shape.down => 0.0,
        _Shape.up => 9.5,
        _Shape.box => 17.5,
      };
      return _Grip(
        rect: Rect.fromLTWH(x - 5.5, top, 11, shape.height),
        tooltip: tooltip,
        shape: shape,
        dragged: drag?.part == part,
        axis: Axis.horizontal,
        onStart: (global) => _start(part, global),
        onUpdate: _update,
        onEnd: _end,
        onCancel: _cancel,
      );
    }

    return RepaintBoundary(
      child: SizedBox(
        height: rulerSize,
        child: Stack(
          children: [
            Positioned.fill(
              child: CustomPaint(
                painter: _ScalePainter(
                  axis: Axis.horizontal,
                  span: _Span(
                    widget.pageLeft,
                    widget.pageLeft + look.pageWidth * scale,
                    textLeft,
                    textRight,
                  ),
                  pixelsPerCm: _pointsPerCm * scale,
                ),
              ),
            ),
            grip(
              _Part.leftMargin,
              l10n.leftMargin,
              math.min(widget.pageLeft, textLeft - 4),
              textLeft + 4,
            ),
            grip(
              _Part.rightMargin,
              l10n.rightMargin,
              textRight - 4,
              math.max(widget.pageLeft + look.pageWidth * scale, textRight + 4),
            ),
            if (indents != null && indents.editable) ...[
              marker(
                _Part.firstLine,
                l10n.firstLineIndent,
                _Shape.down,
                textLeft + indents.firstLineStart * scale,
              ),
              marker(
                _Part.hanging,
                l10n.hangingIndent,
                _Shape.up,
                textLeft + indents.left * scale,
              ),
              marker(
                _Part.leftIndent,
                l10n.leftIndent,
                _Shape.box,
                textLeft + indents.left * scale,
              ),
              marker(
                _Part.rightIndent,
                l10n.rightIndent,
                _Shape.up,
                textRight - indents.right * scale,
              ),
            ] else if (indents != null)
              Positioned.fill(
                child: IgnorePointer(
                  child: CustomPaint(
                    painter: _ListMarksPainter(
                      firstLine: textLeft + indents.firstLineStart * scale,
                      left: textLeft + indents.left * scale,
                      right: textRight - indents.right * scale,
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// The ruler beside the paper: the page with the caret, in centimeters from
/// the top margin.
class VerticalRuler extends StatefulWidget {
  const VerticalRuler({
    required this.session,
    required this.pages,
    required this.scale,
    required this.scrollController,
    required this.currentPage,
    required this.guide,
    super.key,
  });

  final EditorSession session;
  final QuillPageLayout pages;

  /// Pixels per point.
  final double scale;
  final ScrollController scrollController;

  /// The page with the caret and the page count, from one.
  final ValueListenable<(int, int)?> currentPage;
  final ValueNotifier<RulerGuide?> guide;

  @override
  State<VerticalRuler> createState() => _VerticalRulerState();
}

class _VerticalRulerState extends State<VerticalRuler> {
  /// Which margin is being dragged, and its size in points so far.
  bool? _draggingTop;
  double _grab = 0;
  double? _dragged;

  double get _pageTop {
    final page = (widget.currentPage.value?.$1 ?? 1) - 1;
    final positions = widget.scrollController.positions;
    final scrolled = positions.isEmpty ? 0.0 : positions.first.pixels;
    return widget.pages.pageTop(page) - scrolled;
  }

  double get _marginTop =>
      _draggingTop == true ? _dragged! * widget.scale : widget.pages.marginTop;

  double get _marginBottom => _draggingTop == false
      ? _dragged! * widget.scale
      : widget.pages.marginBottom;

  double _localY(Offset global) =>
      (context.findRenderObject()! as RenderBox).globalToLocal(global).dy;

  void _start(bool top, Offset global) {
    final y = _localY(global);
    final edge = top
        ? _pageTop + _marginTop
        : _pageTop + widget.pages.pageHeight - _marginBottom;
    final margins = widget.session.look.margins;
    setState(() {
      _draggingTop = top;
      _grab = y - edge;
      _dragged = top ? margins.top : margins.bottom;
    });
  }

  void _update(Offset global) {
    final top = _draggingTop;
    if (top == null) return;
    final look = widget.session.look;
    final y = _localY(global) - _grab - _pageTop;
    final scale = widget.scale;
    final margins = look.margins;
    final height = look.pageHeight;
    setState(() {
      _dragged = top
          ? _snapped(y / scale).clamp(0.0, height - margins.bottom - _minText)
          : _snapped(
              height - y / scale,
            ).clamp(0.0, height - margins.top - _minText);
    });
    widget.guide.value = RulerGuide(
      y: top
          ? _pageTop + _marginTop
          : _pageTop + widget.pages.pageHeight - _marginBottom,
    );
  }

  void _end() {
    final top = _draggingTop;
    final dragged = _dragged;
    widget.guide.value = null;
    if (top == null || dragged == null) return;
    setState(() {
      _draggingTop = null;
      _dragged = null;
    });
    final margins = widget.session.look.margins;
    final next = top
        ? margins.copyWith(top: dragged)
        : margins.copyWith(bottom: dragged);
    if (next != margins) widget.session.setPageSetup(margins: next);
  }

  void _cancel() {
    widget.guide.value = null;
    if (_draggingTop != null) {
      setState(() {
        _draggingTop = null;
        _dragged = null;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final pages = widget.pages;
    return RepaintBoundary(
      child: SizedBox(
        width: rulerSize,
        child: ListenableBuilder(
          listenable: Listenable.merge([
            widget.scrollController,
            widget.currentPage,
          ]),
          builder: (context, _) {
            final pageTop = _pageTop;
            final textTop = pageTop + _marginTop;
            final textBottom = pageTop + pages.pageHeight - _marginBottom;

            Widget grip(bool top, String tooltip, double from, double to) =>
                _Grip(
                  rect: Rect.fromLTRB(0, from, rulerSize, to),
                  tooltip: tooltip,
                  cursor: SystemMouseCursors.resizeUpDown,
                  axis: Axis.vertical,
                  onStart: (global) => _start(top, global),
                  onUpdate: _update,
                  onEnd: _end,
                  onCancel: _cancel,
                );

            return Stack(
              children: [
                Positioned.fill(
                  child: CustomPaint(
                    painter: _ScalePainter(
                      axis: Axis.vertical,
                      span: _Span(
                        pageTop,
                        pageTop + pages.pageHeight,
                        textTop,
                        textBottom,
                      ),
                      pixelsPerCm: _pointsPerCm * widget.scale,
                    ),
                  ),
                ),
                grip(
                  true,
                  l10n.topMargin,
                  math.min(pageTop, textTop - 4),
                  textTop + 4,
                ),
                grip(
                  false,
                  l10n.bottomMargin,
                  textBottom - 4,
                  math.max(pageTop + pages.pageHeight, textBottom + 4),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

/// The dashed line of [RulerGuide] across the paper.
class RulerGuideLine extends StatelessWidget {
  const RulerGuideLine({required this.guide, super.key});

  final ValueListenable<RulerGuide?> guide;

  @override
  Widget build(BuildContext context) =>
      IgnorePointer(child: CustomPaint(painter: _GuidePainter(guide)));
}

class _GuidePainter extends CustomPainter {
  _GuidePainter(this.guide) : super(repaint: guide);

  final ValueListenable<RulerGuide?> guide;

  @override
  void paint(Canvas canvas, Size size) {
    final value = guide.value;
    if (value == null) return;
    final paint = Paint()
      ..color = _guideColor
      ..strokeWidth = 1;
    const dash = 4.0;
    const gap = 3.0;
    if (value.x case final x?) {
      for (var y = 0.0; y < size.height; y += dash + gap) {
        canvas.drawLine(
          Offset(x, y),
          Offset(x, math.min(y + dash, size.height)),
          paint,
        );
      }
    }
    if (value.y case final y?) {
      for (var x = 0.0; x < size.width; x += dash + gap) {
        canvas.drawLine(
          Offset(x, y),
          Offset(math.min(x + dash, size.width), y),
          paint,
        );
      }
    }
  }

  @override
  bool shouldRepaint(_GuidePainter oldDelegate) => oldDelegate.guide != guide;
}

enum _Shape {
  /// First line indent: points down from the top edge.
  down(9),

  /// Hanging and right indents: point up from the bottom.
  up(8),

  /// Left indent, under the hanging indent.
  box(4.5);

  const _Shape(this.height);

  final double height;

  Path path(Size size) {
    final w = size.width;
    final h = size.height;
    return switch (this) {
      _Shape.down =>
        Path()
          ..moveTo(0.5, 0.5)
          ..lineTo(w - 0.5, 0.5)
          ..lineTo(w - 0.5, h * 0.45)
          ..lineTo(w / 2, h - 0.5)
          ..lineTo(0.5, h * 0.45)
          ..close(),
      _Shape.up =>
        Path()
          ..moveTo(w / 2, 0.5)
          ..lineTo(w - 0.5, h * 0.55)
          ..lineTo(w - 0.5, h - 0.5)
          ..lineTo(0.5, h - 0.5)
          ..lineTo(0.5, h * 0.55)
          ..close(),
      _Shape.box => Path()..addRect(Rect.fromLTRB(0.5, 0, w - 0.5, h - 0.5)),
    };
  }
}

/// A mark on a ruler that can be dragged; markers take hits only inside
/// their shape, so the margin under them can still be grabbed.
class _Grip extends StatelessWidget {
  const _Grip({
    required this.rect,
    required this.tooltip,
    required this.axis,
    required this.onStart,
    required this.onUpdate,
    required this.onEnd,
    required this.onCancel,
    this.cursor = MouseCursor.defer,
    this.shape,
    this.dragged = false,
  });

  final Rect rect;
  final String tooltip;
  final Axis axis;
  final ValueChanged<Offset> onStart;
  final ValueChanged<Offset> onUpdate;
  final VoidCallback onEnd;
  final VoidCallback onCancel;
  final MouseCursor cursor;
  final _Shape? shape;
  final bool dragged;

  @override
  Widget build(BuildContext context) {
    final shape = this.shape;
    final horizontal = axis == Axis.horizontal;
    Widget child = GestureDetector(
      behavior: HitTestBehavior.opaque,
      dragStartBehavior: DragStartBehavior.down,
      onHorizontalDragStart: horizontal
          ? (details) => onStart(details.globalPosition)
          : null,
      onHorizontalDragUpdate: horizontal
          ? (details) => onUpdate(details.globalPosition)
          : null,
      onHorizontalDragEnd: horizontal ? (_) => onEnd() : null,
      onHorizontalDragCancel: horizontal ? onCancel : null,
      onVerticalDragStart: horizontal
          ? null
          : (details) => onStart(details.globalPosition),
      onVerticalDragUpdate: horizontal
          ? null
          : (details) => onUpdate(details.globalPosition),
      onVerticalDragEnd: horizontal ? null : (_) => onEnd(),
      onVerticalDragCancel: horizontal ? null : onCancel,
      child: shape == null
          ? const SizedBox.expand()
          : CustomPaint(
              size: rect.size,
              painter: _MarkerPainter(shape, dragged: dragged),
            ),
    );
    child = MouseRegion(
      cursor: cursor,
      child: Tooltip(message: tooltip, child: child),
    );
    if (shape != null) {
      child = ClipPath(
        clipper: _ShapeClipper(shape),
        clipBehavior: Clip.none,
        child: child,
      );
    }
    return Positioned.fromRect(rect: rect, child: child);
  }
}

class _ShapeClipper extends CustomClipper<Path> {
  const _ShapeClipper(this.shape);

  final _Shape shape;

  @override
  Path getClip(Size size) => shape.path(size);

  @override
  bool shouldReclip(_ShapeClipper oldClipper) => oldClipper.shape != shape;
}

class _MarkerPainter extends CustomPainter {
  const _MarkerPainter(this.shape, {this.dragged = false});

  final _Shape shape;
  final bool dragged;

  @override
  void paint(Canvas canvas, Size size) {
    final path = shape.path(size);
    canvas
      ..drawPath(path, Paint()..color = dragged ? _markerDragged : _markerFill)
      ..drawPath(
        path,
        Paint()
          ..color = _markerStroke
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1,
      );
  }

  @override
  bool shouldRepaint(_MarkerPainter oldDelegate) =>
      oldDelegate.shape != shape || oldDelegate.dragged != dragged;
}

/// The indents of a list, which follow its levels: shown, not dragged.
class _ListMarksPainter extends CustomPainter {
  const _ListMarksPainter({
    required this.firstLine,
    required this.left,
    required this.right,
  });

  final double firstLine;
  final double left;
  final double right;

  @override
  void paint(Canvas canvas, Size size) {
    for (final (shape, x, top) in [
      (_Shape.down, firstLine, 0.0),
      (_Shape.up, left, 9.5),
      (_Shape.box, left, 17.5),
      (_Shape.up, right, 9.5),
    ]) {
      canvas
        ..save()
        ..translate(x - 5.5, top);
      _MarkerPainter(shape).paint(canvas, Size(11, shape.height));
      canvas.restore();
    }
  }

  @override
  bool shouldRepaint(_ListMarksPainter oldDelegate) =>
      oldDelegate.firstLine != firstLine ||
      oldDelegate.left != left ||
      oldDelegate.right != right;
}

/// The page and its text area along a ruler, in the ruler's pixels.
@immutable
class _Span {
  const _Span(this.pageStart, this.pageEnd, this.textStart, this.textEnd);

  final double pageStart;
  final double pageEnd;
  final double textStart;
  final double textEnd;

  @override
  bool operator ==(Object other) =>
      other is _Span &&
      other.pageStart == pageStart &&
      other.pageEnd == pageEnd &&
      other.textStart == textStart &&
      other.textEnd == textEnd;

  @override
  int get hashCode => Object.hash(pageStart, pageEnd, textStart, textEnd);
}

final _labels = <int, TextPainter>{};

TextPainter _label(int value) => _labels.putIfAbsent(
  value,
  () => TextPainter(
    text: TextSpan(
      text: '$value',
      style: const TextStyle(fontSize: 9, height: 1, color: _markColor),
    ),
    textDirection: TextDirection.ltr,
  )..layout(),
);

/// Centimeters counted from the start of the text, both ways, as in Word:
/// a number every centimeter and marks in between.
class _ScalePainter extends CustomPainter {
  const _ScalePainter({
    required this.axis,
    required this.span,
    required this.pixelsPerCm,
  });

  final Axis axis;
  final _Span span;
  final double pixelsPerCm;

  @override
  void paint(Canvas canvas, Size size) {
    final horizontal = axis == Axis.horizontal;
    final extent = horizontal ? size.width : size.height;
    Rect band(double from, double to) => horizontal
        ? Rect.fromLTRB(from, _bandStart, to, _bandEnd)
        : Rect.fromLTRB(_bandStart, from, _bandEnd, to);
    canvas
      ..drawRect(
        band(span.pageStart, span.pageEnd),
        Paint()..color = _marginColor,
      )
      ..drawRect(
        band(span.textStart, span.textEnd),
        Paint()..color = _textColor,
      );

    final cm = pixelsPerCm;
    final parts = cm / 4 >= 5
        ? 4
        : cm / 2 >= 5
        ? 2
        : 1;
    final labelEvery = cm >= 15
        ? 1
        : cm >= 8
        ? 2
        : 5;
    final step = cm / parts;
    final origin = span.textStart;
    final from = math.max(span.pageStart, 0.0);
    final to = math.min(span.pageEnd, extent);
    if (to <= from) return;
    final first = ((from - origin) / step).ceil();
    final last = ((to - origin) / step).floor();
    final middle = (_bandStart + _bandEnd) / 2;
    final ticks = Paint()
      ..color = _markColor
      ..strokeWidth = 1;
    for (var index = first; index <= last; index++) {
      final at = origin + index * step;
      double reach;
      if (index % parts == 0) {
        final whole = (index ~/ parts).abs();
        if (whole == 0) continue;
        if (whole % labelEvery == 0) {
          final label = _label(whole);
          final center = horizontal ? Offset(at, middle) : Offset(middle, at);
          label.paint(
            canvas,
            center - Offset(label.width / 2, label.height / 2),
          );
          continue;
        }
        reach = 3.5;
      } else {
        reach = parts == 4 && index.isEven ? 3 : 1.5;
      }
      final line = at.roundToDouble() + 0.5;
      if (horizontal) {
        canvas.drawLine(
          Offset(line, middle - reach),
          Offset(line, middle + reach),
          ticks,
        );
      } else {
        canvas.drawLine(
          Offset(middle - reach, line),
          Offset(middle + reach, line),
          ticks,
        );
      }
    }
  }

  @override
  bool shouldRepaint(_ScalePainter oldDelegate) =>
      oldDelegate.axis != axis ||
      oldDelegate.span != span ||
      oldDelegate.pixelsPerCm != pixelsPerCm;
}
