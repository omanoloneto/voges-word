import 'dart:convert';

import 'package:flutter_quill/flutter_quill.dart';

abstract final class EmbedTypes {
  static const image = BlockEmbed.imageType;
  static const table = 'vw-table';
  static const pageBreak = 'vw-page-break';
  static const sectionBreak = 'vw-section';
  static const opaqueBlock = 'vw-block';
  static const opaqueInline = 'vw-inline';

  /// Ocupam a linha inteira; o resto são embutidos no meio do texto.
  static const blockLevel = {table, sectionBreak, opaqueBlock};
}

/// Atributos invisíveis que guardam o que o editor não mostra, para o arquivo
/// salvo continuar igual ao original.
abstract final class HiddenAttributes {
  static const paragraphProperties = 'vw-ppr';
  static const runProperties = 'vw-rpr';
  static const numbering = 'vw-num';
  static const bookmarks = 'vw-bmk';
  static const drawing = 'vw-drawing';
  static const package = 'vw-pkg';

  /// Cópias em pontos do espaçamento e dos recuos do parágrafo, só para a
  /// tela; o arquivo continua vindo de [paragraphProperties].
  static const spaceBefore = 'vw-sb';
  static const spaceAfter = 'vw-sa';
  static const indentRight = 'vw-ir';
  static const firstLine = 'vw-fl';

  /// Estilo dos parágrafos que não somam espaço entre si.
  static const contextualGroup = 'vw-ctx';
}

/// Conteúdo do Word que o editor exibe mas não edita (campos, sumário,
/// equações, formas...).
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

String tableIdOf(Object? data) =>
    (jsonDecode(data as String) as Map<String, dynamic>)['id'] as String;

String encodeTableId(String id) => jsonEncode({'id': id});

String sectionXmlOf(Object? data) =>
    (jsonDecode(data as String) as Map<String, dynamic>)['xml'] as String;

String encodeSection(String xml) => jsonEncode({'xml': xml});
