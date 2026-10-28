import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';

import '../document/nodes/node.dart';

/// Voges Word: page geometry. With it the editor draws separate sheets and
/// pushes whatever does not fit on the current page to the next one.
///
/// All measurements are in logical pixels, in the editor's space.
@immutable
class QuillPageLayout {
  const QuillPageLayout({
    required this.pageHeight,
    required this.marginTop,
    required this.marginBottom,
    this.pageGap = 24,
    this.firstPageTop = 24,
    this.pageColor = const Color(0xFFFFFFFF),
    this.shadowColor = const Color(0x40000000),
    this.breaksBefore,
    this.breaksAfter,
    this.keepsWithNext,
    this.flowsAcrossPages,
    this.onPageCountChanged,
    this.paintPage,
    this.repaint,
  });

  final double pageHeight;
  final double marginTop;
  final double marginBottom;
  final double pageGap;
  final double firstPageTop;
  final Color pageColor;
  final Color shadowColor;

  /// Lines that start on a new page (page break before them).
  final bool Function(Node node)? breaksBefore;

  /// Lines after which the content continues on the next page.
  final bool Function(Node node)? breaksAfter;

  /// Lines that are not left alone at the bottom of a page (headings).
  final bool Function(Node node)? keepsWithNext;

  /// Lines that split across pages on their own (tables); they receive
  /// [PagedBoxConstraints] with the position where they start.
  final bool Function(Node node)? flowsAcrossPages;

  final ValueChanged<int>? onPageCountChanged;

  static const _epsilon = 0.5;

  double get stride => pageHeight + pageGap;

  double get contentHeight => math.max(1, pageHeight - marginTop - marginBottom);

  double pageTop(int page) => firstPageTop + page * stride;

  double contentTop(int page) => pageTop(page) + marginTop;

  double contentBottom(int page) => contentTop(page) + contentHeight;

  int pageAt(double y) => math.max(0, ((y - firstPageTop) / stride).floor());

  /// Where a block of height [height] that reached [y] starts: skips the area
  /// outside the text and moves to the next page if it does not fit on this
  /// one. Blocks taller than a whole page stay where they are.
  double place(double y, double height) {
    var page = pageAt(y);
    var top = math.max(y, contentTop(page));
    if (top >= contentBottom(page) - _epsilon) {
      page++;
      top = contentTop(page);
    }
    final fits = top + height <= contentBottom(page) + _epsilon;
    final atPageTop = top <= contentTop(page) + _epsilon;
    if (!fits && !atPageTop && height <= contentHeight + _epsilon) {
      top = contentTop(page + 1);
    }
    return top;
  }

  bool isAtPageTop(double y) => y <= contentTop(pageAt(y)) + _epsilon;

  /// Start of the page after the one that holds the end of a block at [y].
  double nextPage(double y) => contentTop(pageAt(y - _epsilon) + 1);

  int pageCountFor(double end) =>
      pageAt(math.max(end - _epsilon, contentTop(0))) + 1;

  double totalHeight(int pageCount) =>
      pageTop(math.max(pageCount, 1) - 1) + pageHeight + firstPageTop;

  /// Paints the header and footer over sheet [index] of [count].
  final void Function(Canvas canvas, Rect page, int index, int count)?
      paintPage;

  /// Notifies when [paintPage] needs to paint again.
  final Listenable? repaint;

  bool sameGeometry(QuillPageLayout? other) =>
      other != null &&
      other.pageHeight == pageHeight &&
      other.marginTop == marginTop &&
      other.marginBottom == marginBottom &&
      other.pageGap == pageGap &&
      other.firstPageTop == firstPageTop;

  @override
  bool operator ==(Object other) =>
      other is QuillPageLayout &&
      sameGeometry(other) &&
      other.pageColor == pageColor &&
      other.shadowColor == shadowColor &&
      other.paintPage == paintPage &&
      other.repaint == repaint;

  @override
  int get hashCode => Object.hash(pageHeight, marginTop, marginBottom, pageGap,
      firstPageTop, pageColor, shadowColor, paintPage, repaint);
}

/// Layout constraints that carry the child's vertical position in the
/// document, so it can decide where to break across pages.
class PagedBoxConstraints extends BoxConstraints {
  const PagedBoxConstraints({
    required this.pages,
    required this.top,
    super.minWidth,
    super.maxWidth,
    super.minHeight,
    super.maxHeight,
  });

  factory PagedBoxConstraints.from(
    BoxConstraints constraints,
    QuillPageLayout pages,
    double top,
  ) =>
      PagedBoxConstraints(
        pages: pages,
        top: top,
        minWidth: constraints.minWidth,
        maxWidth: constraints.maxWidth,
        minHeight: constraints.minHeight,
        maxHeight: constraints.maxHeight,
      );

  final QuillPageLayout pages;
  final double top;

  @override
  bool operator ==(Object other) =>
      super == other &&
      other is PagedBoxConstraints &&
      other.top == top &&
      other.pages.sameGeometry(pages);

  @override
  int get hashCode => Object.hash(super.hashCode, top, pages.pageHeight);
}
