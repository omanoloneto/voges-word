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

  /// In points.
  final double fontSize;
  final String? fontFamily;
  final Color color;
  final bool bold;
  final bool italic;
  final double spaceBefore;
  final double spaceAfter;
  final double indentRight;

  /// Negative means a hanging indent.
  final double firstLine;
}

/// Page measurements and the document's base look, all in points.
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

  /// Multiple of single line spacing.
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

/// Scale used when the document defines no heading styles.
double headingScale(int level) => switch (level) {
  1 => 1.6,
  2 => 1.35,
  _ => 1.15,
};
