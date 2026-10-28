import 'package:flutter/painting.dart';

class TextLook {
  const TextLook({
    required this.fontSize,
    this.fontFamily,
    this.color = const Color(0xFF000000),
    this.bold = false,
    this.italic = false,
    this.spaceBefore = 0,
    this.spaceAfter = 0,
    this.indentRight = 0,
    this.firstLine = 0,
  });

  /// Pontos.
  final double fontSize;
  final String? fontFamily;
  final Color color;
  final bool bold;
  final bool italic;
  final double spaceBefore;
  final double spaceAfter;
  final double indentRight;

  /// Negativo é recuo deslocado.
  final double firstLine;
}

/// Medidas da página e aparência base do documento, tudo em pontos.
class DocumentLook {
  const DocumentLook({
    this.pageWidth = 595.3,
    this.pageHeight = 841.9,
    this.margins = const EdgeInsets.fromLTRB(85, 71, 85, 71),
    this.body = const TextLook(
      fontSize: 12,
      fontFamily: 'Arial',
      spaceAfter: 8,
    ),
    this.headings = const {},
    this.lineSpacing = 1.15,
  });

  final double pageWidth;
  final double pageHeight;
  final EdgeInsets margins;
  final TextLook body;
  final Map<int, TextLook> headings;

  /// Múltiplo de linha simples.
  final double lineSpacing;

  double get contentWidth => pageWidth - margins.horizontal;

  bool get isLandscape => pageWidth > pageHeight;

  DocumentLook copyWith({
    double? pageWidth,
    double? pageHeight,
    EdgeInsets? margins,
  }) => DocumentLook(
    pageWidth: pageWidth ?? this.pageWidth,
    pageHeight: pageHeight ?? this.pageHeight,
    margins: margins ?? this.margins,
    body: body,
    headings: headings,
    lineSpacing: lineSpacing,
  );

  TextLook heading(int level) =>
      headings[level] ??
      TextLook(
        fontSize: body.fontSize * headingScale(level),
        fontFamily: body.fontFamily,
        color: body.color,
        bold: true,
        spaceBefore: 12,
        spaceAfter: 4,
      );
}

/// Proporção usada quando o documento não define estilos de título.
double headingScale(int level) => switch (level) {
  1 => 1.6,
  2 => 1.35,
  _ => 1.15,
};
