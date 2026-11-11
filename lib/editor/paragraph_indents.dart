import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter_quill/flutter_quill.dart';
import 'package:flutter_quill/quill_delta.dart';

import '../document/document_look.dart';
import '../document/embeds.dart';
import 'paper_styles.dart';

/// Left indents go in the steps of the indent buttons (1.27 cm).
const indentStep = 36.0;

/// The deepest left indent the files keep.
const maxIndentLevel = 8;

/// A paragraph's indents in points, as Word's ruler shows them.
@immutable
class ParagraphIndents {
  const ParagraphIndents({
    required this.left,
    required this.firstLine,
    required this.right,
    this.editable = true,
  });

  /// From the left margin.
  final double left;

  /// From [left]; negative for a hanging indent.
  final double firstLine;

  /// From the right margin.
  final double right;

  /// Lists keep the indents of their levels.
  final bool editable;

  double get firstLineStart => left + firstLine;

  @override
  bool operator ==(Object other) =>
      other is ParagraphIndents &&
      other.left == left &&
      other.firstLine == firstLine &&
      other.right == right &&
      other.editable == editable;

  @override
  int get hashCode => Object.hash(left, firstLine, right, editable);
}

/// Indents of the paragraph at [offset]; null for tables and other blocks.
ParagraphIndents? indentsAt(Document document, int offset, DocumentLook look) {
  final line = _lineAt(document, offset)?.$1;
  if (line == null) return null;
  final attributes = line.style.attributes;
  final level = _levelOf(line);
  if (attributes.containsKey(Attribute.list.key)) {
    return ParagraphIndents(
      left: indentStep * (level + 1),
      firstLine: -indentStep,
      right: 0,
      editable: false,
    );
  }
  final format = paragraphFormat(line, look);
  if (format == null) return null;
  return ParagraphIndents(
    left: indentStep * level,
    firstLine: format.firstLine,
    right: format.indentRight,
  );
}

/// Sets the indents of the paragraphs in the selection, as one change that
/// undo takes back at once. Lists and tables keep theirs.
void setIndents(
  QuillController controller,
  DocumentLook look, {
  int? level,
  double? firstLine,
  double? right,
}) {
  final document = controller.document;
  final selection = controller.selection;
  final start = _lineAt(document, selection.start);
  if (start == null) return;
  final end = math.min(selection.end, document.length - 1);
  var (Line? line, lineStart) = start;
  final delta = Delta();
  var position = 0;
  while (line != null && lineStart <= end) {
    final attributes = _indentAttributes(line, look, level, firstLine, right);
    if (attributes != null) {
      final lineBreak = lineStart + line.length - 1;
      delta
        ..retain(lineBreak - position)
        ..retain(1, attributes);
      position = lineBreak + 1;
    }
    lineStart += line.length;
    line = line.nextLine;
  }
  if (delta.isEmpty) return;
  controller.compose(delta, selection, ChangeSource.local);
}

(Line, int)? _lineAt(Document document, int offset) {
  final length = document.length;
  if (length == 0) return null;
  final clamped = math.min(math.max(offset, 0), length - 1);
  final query = document.queryChild(clamped);
  final line = query.node;
  return line is Line ? (line, clamped - query.offset) : null;
}

int _levelOf(Line line) =>
    (line.style.attributes[Attribute.indent.key]?.value as num?)?.toInt() ?? 0;

Map<String, dynamic>? _indentAttributes(
  Line line,
  DocumentLook look,
  int? level,
  double? firstLine,
  double? right,
) {
  final attributes = line.style.attributes;
  if (attributes.containsKey(Attribute.list.key)) return null;
  if (paragraphFormat(line, look) == null) return null;
  // Kept even when equal to the style, so the file takes it over its own.
  double points(double value) => (value * 100).round() / 100;
  return {
    if (level != null) Attribute.indent.key: level == 0 ? null : level,
    if (firstLine != null) HiddenAttributes.firstLine: points(firstLine),
    if (right != null) HiddenAttributes.indentRight: points(right),
  };
}
