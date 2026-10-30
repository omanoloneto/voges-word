import 'package:flutter_quill/quill_delta.dart';

import 'embeds.dart';

/// Text or an inline embed (image, page break, page number, protected
/// content) of a line.
sealed class InlinePiece {
  const InlinePiece(this.attributes);

  /// Character attributes: bold, italic, underline, strike, size (points),
  /// font, color and background (`#RRGGBB`), script (`super`, `sub`) and link.
  final Map<String, dynamic> attributes;

  String? get link => attributes['link'] as String?;
}

/// Tabs are `\t`; line breaks inside the paragraph are ` `.
class TextPiece extends InlinePiece {
  const TextPiece(this.text, super.attributes);

  final String text;
}

class EmbedPiece extends InlinePiece {
  const EmbedPiece(this.type, this.value, super.attributes);

  /// One of [EmbedTypes].
  final String type;
  final Object? value;
}

sealed class DocumentBlock {
  const DocumentBlock();
}

/// A paragraph and its line attributes.
class LineBlock extends DocumentBlock {
  const LineBlock(this.pieces, this.attributes);

  final List<InlinePiece> pieces;
  final Map<String, dynamic> attributes;

  /// 1 to 6.
  int? get heading => attributes['header'] as int?;

  /// `bullet`, `ordered`, `checked` or `unchecked`.
  String? get list => attributes['list'] as String?;
  bool get isOrdered => list == 'ordered';

  /// List level, or 36-point steps of left indent outside lists.
  int get indent => (attributes['indent'] as num?)?.toInt() ?? 0;

  /// `left`, `center`, `right` or `justify`.
  String get align => attributes['align'] as String? ?? 'left';

  /// Multiple of single spacing; null keeps the document's.
  double? get lineHeight => (attributes['line-height'] as num?)?.toDouble();

  /// Points; null keeps the document's.
  double? get spaceBefore =>
      pointsValue(attributes[HiddenAttributes.spaceBefore]);
  double? get spaceAfter =>
      pointsValue(attributes[HiddenAttributes.spaceAfter]);
  double? get indentRight =>
      pointsValue(attributes[HiddenAttributes.indentRight]);

  /// Negative for a hanging indent.
  double? get firstLine => pointsValue(attributes[HiddenAttributes.firstLine]);

  bool get isEmpty => pieces.isEmpty;

  String get plainText => [
    for (final piece in pieces)
      switch (piece) {
        TextPiece(:final text) => text,
        EmbedPiece(type: EmbedTypes.opaqueInline, :final value) =>
          OpaqueContent.decode(value).hidden
              ? ''
              : OpaqueContent.decode(value).text,
        EmbedPiece() => '',
      },
  ].join();
}

/// A table, section break or protected block; it takes a whole line.
class EmbedBlock extends DocumentBlock {
  const EmbedBlock(this.type, this.value);

  /// [EmbedTypes.table], [EmbedTypes.sectionBreak] or
  /// [EmbedTypes.opaqueBlock].
  final String type;
  final Object? value;
}

/// Splits the editor's content into paragraphs and block embeds, the way the
/// .docx writer does: each `\n` ends a paragraph and carries its attributes.
List<DocumentBlock> documentBlocks(Delta delta) {
  final blocks = <DocumentBlock>[];
  var pieces = <InlinePiece>[];

  void endLine(Map<String, dynamic> attributes) {
    var group = <InlinePiece>[];
    var hadBlock = false;
    for (final piece in pieces) {
      if (piece is EmbedPiece && EmbedTypes.blockLevel.contains(piece.type)) {
        if (group.isNotEmpty) blocks.add(LineBlock(group, attributes));
        group = [];
        blocks.add(EmbedBlock(piece.type, piece.value));
        hadBlock = true;
      } else {
        group.add(piece);
      }
    }
    if (group.isNotEmpty || !hadBlock) blocks.add(LineBlock(group, attributes));
    pieces = [];
  }

  for (final operation in delta.toList()) {
    final data = operation.data;
    final attributes = operation.attributes ?? const <String, dynamic>{};
    if (data is String) {
      var start = 0;
      while (true) {
        final newline = data.indexOf('\n', start);
        if (newline < 0) {
          if (start < data.length) {
            pieces.add(TextPiece(data.substring(start), attributes));
          }
          break;
        }
        if (newline > start) {
          pieces.add(TextPiece(data.substring(start, newline), attributes));
        }
        endLine(attributes);
        start = newline + 1;
      }
    } else if (data is Map && data.isNotEmpty) {
      pieces.add(
        EmbedPiece(data.keys.first as String, data.values.first, attributes),
      );
    }
  }
  if (pieces.isNotEmpty) endLine(const {});
  return blocks;
}

/// Points from an attribute stored as a number or text (`12`, `10.5`).
double? pointsValue(Object? value) => switch (value) {
  num() => value.toDouble(),
  String() => double.tryParse(value),
  _ => null,
};

/// `RRGGBB` from `#RRGGBB` (or `RRGGBB`); null for anything else.
String? hexColor(Object? value) {
  if (value is! String) return null;
  final clean = (value.startsWith('#') ? value.substring(1) : value)
      .toUpperCase();
  return RegExp(r'^[0-9A-F]{6}$').hasMatch(clean) ? clean : null;
}
