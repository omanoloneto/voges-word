import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';

import '../document/nodes/node.dart';

/// Voges Word: geometria das páginas. Com ela o editor desenha folhas
/// separadas e empurra para a página seguinte o que não cabe na atual.
///
/// Todas as medidas são em pixels lógicos, no espaço do editor.
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
  });

  final double pageHeight;
  final double marginTop;
  final double marginBottom;
  final double pageGap;
  final double firstPageTop;
  final Color pageColor;
  final Color shadowColor;

  /// Linhas que começam numa página nova (quebra de página no início).
  final bool Function(Node node)? breaksBefore;

  /// Linhas depois das quais o conteúdo continua na página seguinte.
  final bool Function(Node node)? breaksAfter;

  /// Linhas que não ficam sozinhas no pé da página (títulos).
  final bool Function(Node node)? keepsWithNext;

  /// Linhas que se dividem entre páginas por conta própria (tabelas); elas
  /// recebem [PagedBoxConstraints] com a posição em que começam.
  final bool Function(Node node)? flowsAcrossPages;

  final ValueChanged<int>? onPageCountChanged;

  static const _epsilon = 0.5;

  double get stride => pageHeight + pageGap;

  double get contentHeight => math.max(1, pageHeight - marginTop - marginBottom);

  double pageTop(int page) => firstPageTop + page * stride;

  double contentTop(int page) => pageTop(page) + marginTop;

  double contentBottom(int page) => contentTop(page) + contentHeight;

  int pageAt(double y) => math.max(0, ((y - firstPageTop) / stride).floor());

  /// Onde começa um trecho de altura [height] que chegou em [y]: pula a área
  /// fora do texto e vai para a próxima página se não couber nesta. Trechos
  /// maiores que uma página inteira ficam onde estão.
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

  /// Início da página seguinte à que contém o fim de um trecho em [y].
  double nextPage(double y) => contentTop(pageAt(y - _epsilon) + 1);

  int pageCountFor(double end) =>
      pageAt(math.max(end - _epsilon, contentTop(0))) + 1;

  double totalHeight(int pageCount) =>
      pageTop(math.max(pageCount, 1) - 1) + pageHeight + firstPageTop;

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
      other.shadowColor == shadowColor;

  @override
  int get hashCode => Object.hash(
      pageHeight, marginTop, marginBottom, pageGap, firstPageTop, pageColor, shadowColor);
}

/// Restrições de layout que levam a posição vertical do filho no documento,
/// para ele decidir onde quebrar entre páginas.
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
