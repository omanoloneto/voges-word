import 'dart:convert';
import 'dart:typed_data';

import 'docx_package.dart';
import 'word_xml.dart';

const _declaration = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>';

enum DocumentTemplate {
  blank('Em branco'),
  singleSpaced('Espaçamento simples'),
  schoolWork('Trabalho escolar'),
  resume('Currículo');

  const DocumentTemplate(this.label);

  final String label;
}

class TemplateOptions {
  const TemplateOptions({
    this.lineTwips = 276,
    this.afterTwips = 160,
    this.justify = false,
    this.firstLineTwips = 0,
    this.margins = (top: 1417, right: 1701, bottom: 1417, left: 1701),
  });

  final int lineTwips;
  final int afterTwips;
  final bool justify;
  final int firstLineTwips;
  final ({int top, int right, int bottom, int left}) margins;

  static TemplateOptions of(DocumentTemplate template) => switch (template) {
    DocumentTemplate.singleSpaced => const TemplateOptions(
      lineTwips: 240,
      afterTwips: 0,
    ),
    // Normas da ABNT: 1,5 de entrelinha, justificado, recuo de 1,25 cm na
    // primeira linha, margens 3 e 2 cm.
    DocumentTemplate.schoolWork => const TemplateOptions(
      lineTwips: 360,
      afterTwips: 0,
      justify: true,
      firstLineTwips: 709,
      margins: (top: 1701, right: 1134, bottom: 1134, left: 1701),
    ),
    DocumentTemplate.resume => const TemplateOptions(
      lineTwips: 264,
      afterTwips: 80,
    ),
    DocumentTemplate.blank => const TemplateOptions(),
  };
}

/// Documento em branco: A4, margens do Word em português (3 cm / 2,5 cm),
/// Arial 12 e títulos prontos para sumário.
DocxPackage newDocumentPackage([
  TemplateOptions options = const TemplateOptions(),
]) {
  final margins = options.margins;
  final namespaces = Namespaces.known.entries
      .map((entry) => 'xmlns:${entry.key}="${entry.value}"')
      .join(' ');
  final parts = <String, String>{
    '[Content_Types].xml':
        '$_declaration'
        '<Types xmlns="${Namespaces.contentTypes}">'
        '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>'
        '<Default Extension="xml" ContentType="application/xml"/>'
        '<Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>'
        '<Override PartName="/word/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml"/>'
        '<Override PartName="/word/settings.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.settings+xml"/>'
        '</Types>',
    '_rels/.rels':
        '$_declaration'
        '<Relationships xmlns="${Namespaces.packageRelationships}">'
        '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>'
        '</Relationships>',
    'word/_rels/document.xml.rels':
        '$_declaration'
        '<Relationships xmlns="${Namespaces.packageRelationships}">'
        '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>'
        '<Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/settings" Target="settings.xml"/>'
        '</Relationships>',
    'word/document.xml':
        '$_declaration'
        '<w:document $namespaces mc:Ignorable="w14 w15 wp14"><w:body>'
        '<w:p/>'
        '<w:sectPr><w:pgSz w:w="11906" w:h="16838"/>'
        '<w:pgMar w:top="${margins.top}" w:right="${margins.right}" w:bottom="${margins.bottom}" w:left="${margins.left}" w:header="708" w:footer="708" w:gutter="0"/>'
        '<w:cols w:space="708"/></w:sectPr>'
        '</w:body></w:document>',
    'word/settings.xml':
        '$_declaration'
        '<w:settings xmlns:w="${Namespaces.w}">'
        '<w:defaultTabStop w:val="708"/>'
        '<w:characterSpacingControl w:val="doNotCompress"/>'
        '<w:compat><w:compatSetting w:name="compatibilityMode" w:uri="http://schemas.microsoft.com/office/word" w:val="15"/></w:compat>'
        '</w:settings>',
    'word/styles.xml': _styles(options),
  };
  return DocxPackage({
    for (final entry in parts.entries)
      entry.key: Uint8List.fromList(utf8.encode(entry.value)),
  });
}

/// Títulos não herdam o recuo de primeira linha do Normal.
String _heading(int level, int halfPoints, int before, String noIndent) =>
    '<w:style w:type="paragraph" w:styleId="Heading$level">'
    '<w:name w:val="heading $level"/><w:basedOn w:val="Normal"/><w:next w:val="Normal"/>'
    '<w:uiPriority w:val="9"/><w:qFormat/>'
    '<w:pPr><w:keepNext/><w:keepLines/><w:spacing w:before="$before" w:after="80"/>'
    '$noIndent<w:jc w:val="left"/><w:outlineLvl w:val="${level - 1}"/></w:pPr>'
    '<w:rPr><w:b/><w:bCs/><w:sz w:val="$halfPoints"/><w:szCs w:val="$halfPoints"/></w:rPr>'
    '</w:style>';

String _styles(TemplateOptions options) {
  final firstLine = options.firstLineTwips;
  final noIndent = firstLine == 0 ? '' : '<w:ind w:firstLine="0"/>';
  final normal = [
    if (firstLine != 0) '<w:ind w:firstLine="$firstLine"/>',
    if (options.justify) '<w:jc w:val="both"/>',
  ].join();
  return '$_declaration'
      '<w:styles xmlns:w="${Namespaces.w}">'
      '<w:docDefaults>'
      '<w:rPrDefault><w:rPr>'
      '<w:rFonts w:ascii="Arial" w:hAnsi="Arial" w:eastAsia="Arial" w:cs="Arial"/>'
      '<w:sz w:val="24"/><w:szCs w:val="24"/>'
      '<w:lang w:val="pt-BR" w:eastAsia="en-US" w:bidi="ar-SA"/>'
      '</w:rPr></w:rPrDefault>'
      '<w:pPrDefault><w:pPr><w:spacing w:after="${options.afterTwips}" w:line="${options.lineTwips}" w:lineRule="auto"/></w:pPr></w:pPrDefault>'
      '</w:docDefaults>'
      '<w:style w:type="paragraph" w:default="1" w:styleId="Normal"><w:name w:val="Normal"/><w:qFormat/>'
      '${normal.isEmpty ? '' : '<w:pPr>$normal</w:pPr>'}</w:style>'
      '<w:style w:type="character" w:default="1" w:styleId="DefaultParagraphFont">'
      '<w:name w:val="Default Paragraph Font"/><w:uiPriority w:val="1"/><w:semiHidden/><w:unhideWhenUsed/></w:style>'
      '<w:style w:type="table" w:default="1" w:styleId="TableNormal"><w:name w:val="Normal Table"/>'
      '<w:uiPriority w:val="99"/><w:semiHidden/><w:unhideWhenUsed/>'
      '<w:tblPr><w:tblInd w:w="0" w:type="dxa"/><w:tblCellMar><w:top w:w="0" w:type="dxa"/>'
      '<w:left w:w="108" w:type="dxa"/><w:bottom w:w="0" w:type="dxa"/><w:right w:w="108" w:type="dxa"/>'
      '</w:tblCellMar></w:tblPr></w:style>'
      '<w:style w:type="numbering" w:default="1" w:styleId="NoList"><w:name w:val="No List"/>'
      '<w:uiPriority w:val="99"/><w:semiHidden/><w:unhideWhenUsed/></w:style>'
      '${_heading(1, 32, 360, noIndent)}${_heading(2, 28, 240, noIndent)}'
      '${_heading(3, 26, 240, noIndent)}'
      '<w:style w:type="paragraph" w:styleId="Title"><w:name w:val="Title"/><w:basedOn w:val="Normal"/>'
      '<w:next w:val="Normal"/><w:uiPriority w:val="10"/><w:qFormat/>'
      '<w:pPr><w:spacing w:after="80" w:line="240" w:lineRule="auto"/>$noIndent</w:pPr>'
      '<w:rPr><w:sz w:val="52"/><w:szCs w:val="52"/></w:rPr></w:style>'
      '<w:style w:type="paragraph" w:styleId="ListParagraph"><w:name w:val="List Paragraph"/>'
      '<w:basedOn w:val="Normal"/><w:uiPriority w:val="34"/><w:qFormat/>'
      '<w:pPr><w:ind w:left="720"/><w:contextualSpacing/></w:pPr></w:style>'
      '<w:style w:type="character" w:styleId="Hyperlink"><w:name w:val="Hyperlink"/>'
      '<w:basedOn w:val="DefaultParagraphFont"/><w:uiPriority w:val="99"/><w:unhideWhenUsed/>'
      '<w:rPr><w:color w:val="0563C1"/><w:u w:val="single"/></w:rPr></w:style>'
      '</w:styles>';
}
