import 'dart:math' as math;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_quill/flutter_quill.dart';

import '../document/document_look.dart';
import '../document/embeds.dart';

const pageGap = 24.0;

QuillPageLayout pageLayoutFor(
  DocumentLook look,
  double scale, {
  ValueChanged<int>? onPageCountChanged,
}) {
  return QuillPageLayout(
    pageHeight: look.pageHeight * scale,
    marginTop: look.margins.top * scale,
    marginBottom: look.margins.bottom * scale,
    pageGap: pageGap,
    firstPageTop: pageGap,
    breaksBefore: _startsWithPageBreak,
    breaksAfter: _endsWithPageBreak,
    keepsWithNext: (node) =>
        node is Line && node.style.attributes.containsKey(Attribute.header.key),
    flowsAcrossPages: _isTableLine,
    onPageCountChanged: onPageCountChanged,
  );
}

Embed? _embedAt(Node node, {required bool first}) {
  if (node is! Line || node.children.isEmpty) return null;
  final child = first ? node.children.first : node.children.last;
  return child is Embed ? child : null;
}

bool _startsWithPageBreak(Node node) =>
    node is Line &&
    node.children.length > 1 &&
    _embedAt(node, first: true)?.value.type == EmbedTypes.pageBreak;

/// Quebra de seção contínua não muda de página.
bool _endsWithPageBreak(Node node) {
  final embed = _embedAt(node, first: false);
  return switch (embed?.value.type) {
    EmbedTypes.pageBreak => true,
    EmbedTypes.sectionBreak => !sectionXmlOf(
      embed!.value.data,
    ).contains('w:val="continuous"'),
    _ => false,
  };
}

bool _isTableLine(Node node) =>
    node is Line &&
    node.children.length == 1 &&
    _embedAt(node, first: true)?.value.type == EmbedTypes.table;

/// Linhas de tabela empilhadas; com páginas, a linha que não cabe vai
/// inteira para a página seguinte, como no Word.
class PagedRows extends MultiChildRenderObjectWidget {
  const PagedRows({super.children, this.padding = 4, super.key});

  final double padding;

  @override
  RenderPagedRows createRenderObject(BuildContext context) =>
      RenderPagedRows(padding);

  @override
  void updateRenderObject(BuildContext context, RenderPagedRows renderObject) =>
      renderObject.padding = padding;
}

class _RowParentData extends ContainerBoxParentData<RenderBox> {}

class RenderPagedRows extends RenderBox
    with
        ContainerRenderObjectMixin<RenderBox, _RowParentData>,
        RenderBoxContainerDefaultsMixin<RenderBox, _RowParentData> {
  RenderPagedRows(this._padding);

  double _padding;

  set padding(double value) {
    if (value == _padding) return;
    _padding = value;
    markNeedsLayout();
  }

  @override
  void setupParentData(RenderBox child) {
    if (child.parentData is! _RowParentData) {
      child.parentData = _RowParentData();
    }
  }

  @override
  void performLayout() {
    final paged = constraints is PagedBoxConstraints
        ? constraints as PagedBoxConstraints
        : null;
    final childConstraints = BoxConstraints(maxWidth: constraints.maxWidth);
    var y = _padding;
    var width = 0.0;
    var child = firstChild;
    while (child != null) {
      child.layout(childConstraints, parentUsesSize: true);
      if (paged != null) {
        y = paged.pages.place(paged.top + y, child.size.height) - paged.top;
      }
      final parentData = child.parentData! as _RowParentData
        ..offset = Offset(0, y);
      y += child.size.height;
      width = math.max(width, child.size.width);
      child = parentData.nextSibling;
    }
    size = constraints.constrain(Size(width, y + _padding));
  }

  double _sumHeights(double Function(RenderBox child) height) {
    var total = _padding * 2;
    var child = firstChild;
    while (child != null) {
      total += height(child);
      child = (child.parentData! as _RowParentData).nextSibling;
    }
    return total;
  }

  double _maxWidth(double Function(RenderBox child) width) {
    var result = 0.0;
    var child = firstChild;
    while (child != null) {
      result = math.max(result, width(child));
      child = (child.parentData! as _RowParentData).nextSibling;
    }
    return result;
  }

  @override
  double computeMinIntrinsicHeight(double width) =>
      _sumHeights((child) => child.getMinIntrinsicHeight(width));

  @override
  double computeMaxIntrinsicHeight(double width) =>
      _sumHeights((child) => child.getMaxIntrinsicHeight(width));

  @override
  double computeMinIntrinsicWidth(double height) =>
      _maxWidth((child) => child.getMinIntrinsicWidth(double.infinity));

  @override
  double computeMaxIntrinsicWidth(double height) =>
      _maxWidth((child) => child.getMaxIntrinsicWidth(double.infinity));

  @override
  void paint(PaintingContext context, Offset offset) =>
      defaultPaint(context, offset);

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) =>
      defaultHitTestChildren(result, position: position);
}
