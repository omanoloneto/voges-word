import 'dart:convert';

import 'package:flutter_quill/flutter_quill.dart';

abstract final class EmbedTypes {
  static const image = BlockEmbed.imageType;
  static const table = 'vw-table';
  static const pageBreak = 'vw-page-break';
  static const sectionBreak = 'vw-section';
  static const opaqueBlock = 'vw-block';
  static const opaqueInline = 'vw-inline';

  /// Word's PAGE field: the number of the page it appears on.
  static const pageNumber = 'vw-page-number';

  /// These take up a whole line; the rest are embeds inside the text.
  static const blockLevel = {table, sectionBreak, opaqueBlock};
}

/// Invisible attributes that keep what the editor does not show, so the saved
/// file stays the same as the original.
abstract final class HiddenAttributes {
  static const paragraphProperties = 'vw-ppr';
  static const runProperties = 'vw-rpr';
  static const numbering = 'vw-num';

  /// The Word level of a paragraph at a level of its [numbering] list without
  /// numbers (w:numFmt none), which the editor shows as a plain paragraph.
  static const unnumberedLevel = 'vw-nlvl';

  static const bookmarks = 'vw-bmk';
  static const drawing = 'vw-drawing';
  static const package = 'vw-pkg';

  /// Copies in points of the paragraph's spacing and indents, for the screen
  /// only; the file still comes from [paragraphProperties].
  static const spaceBefore = 'vw-sb';
  static const spaceAfter = 'vw-sa';
  static const indentRight = 'vw-ir';
  static const firstLine = 'vw-fl';

  /// Style of the paragraphs that add no space between one another.
  static const contextualGroup = 'vw-ctx';
}

/// Kinds of protected content; the editor shows them in the user's language.
abstract final class OpaqueLabels {
  static const special = 'special';
  static const tableOfContents = 'toc';
  static const coverPage = 'cover';
  static const bibliography = 'bibliography';
  static const note = 'note';
  static const chart = 'chart';
  static const diagram = 'diagram';
  static const textBox = 'textBox';
  static const equation = 'equation';
  static const object = 'object';
}

/// Word content the editor shows but does not edit (fields, table of contents,
/// equations, shapes...).
class OpaqueContent {
  const OpaqueContent({
    required this.xml,
    required this.text,
    this.packageId,
    this.label,
    this.hidden = false,
  });

  factory OpaqueContent.decode(Object? data) {
    final map = jsonDecode(data as String) as Map<String, dynamic>;
    return OpaqueContent(
      xml: map['xml'] as String,
      text: map['text'] as String? ?? '',
      packageId: map['pkg'] as String?,
      label: map['label'] as String?,
      hidden: map['hidden'] as bool? ?? false,
    );
  }

  final String xml;
  final String text;
  final String? packageId;
  final String? label;
  final bool hidden;

  String encode() => jsonEncode({
    'xml': xml,
    'text': text,
    if (packageId != null) 'pkg': packageId,
    if (label != null) 'label': label,
    if (hidden) 'hidden': true,
  });
}

/// First word of a Word field's instruction (PAGE, NUMPAGES...).
String? fieldNameOf(String xml) {
  final simple = RegExp(r'w:instr="([^"]*)"').firstMatch(xml)?.group(1);
  final complex = RegExp(
    r'<w:instrText[^>]*>([^<]*)</w:instrText>',
  ).allMatches(xml).map((match) => match.group(1)).join();
  final instruction = (simple ?? complex).trim();
  if (instruction.isEmpty) return null;
  return instruction.split(RegExp(r'\s+')).first.toUpperCase();
}

String tableIdOf(Object? data) =>
    (jsonDecode(data as String) as Map<String, dynamic>)['id'] as String;

String encodeTableId(String id) => jsonEncode({'id': id});

String sectionXmlOf(Object? data) =>
    (jsonDecode(data as String) as Map<String, dynamic>)['xml'] as String;

String encodeSection(String xml) => jsonEncode({'xml': xml});
