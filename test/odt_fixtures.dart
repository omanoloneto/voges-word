import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_quill/quill_delta.dart';
import 'package:voges_word/document/embeds.dart';

const odfNamespaces =
    'xmlns:office="urn:oasis:names:tc:opendocument:xmlns:office:1.0" '
    'xmlns:style="urn:oasis:names:tc:opendocument:xmlns:style:1.0" '
    'xmlns:text="urn:oasis:names:tc:opendocument:xmlns:text:1.0" '
    'xmlns:table="urn:oasis:names:tc:opendocument:xmlns:table:1.0" '
    'xmlns:draw="urn:oasis:names:tc:opendocument:xmlns:drawing:1.0" '
    'xmlns:fo="urn:oasis:names:tc:opendocument:xmlns:xsl-fo-compatible:1.0" '
    'xmlns:xlink="http://www.w3.org/1999/xlink" '
    'xmlns:svg="urn:oasis:names:tc:opendocument:xmlns:svg-compatible:1.0" '
    'xmlns:loext="urn:org:documentfoundation:names:experimental:office:xmlns:loext:1.0"';

/// 1x1 PNG.
final pngPixel = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==',
);

/// What LibreOffice writes for a new document, trimmed.
const libreOfficeStyles = '''
<style:default-style style:family="paragraph">
  <style:paragraph-properties style:tab-stop-distance="1.25cm"/>
  <style:text-properties style:font-name="Liberation Serif" fo:font-size="12pt" fo:language="pt" fo:country="BR"/>
</style:default-style>
<style:style style:name="Standard" style:family="paragraph" style:class="text"/>
<style:style style:name="Heading" style:family="paragraph" style:parent-style-name="Standard" style:next-style-name="Text_20_body" style:class="text">
  <style:paragraph-properties fo:margin-top="0.423cm" fo:margin-bottom="0.212cm" fo:keep-with-next="always"/>
  <style:text-properties style:font-name="Liberation Sans" fo:font-size="14pt"/>
</style:style>
<style:style style:name="Text_20_body" style:display-name="Text body" style:family="paragraph" style:parent-style-name="Standard" style:class="text">
  <style:paragraph-properties fo:margin-top="0cm" fo:margin-bottom="0.247cm" fo:line-height="115%"/>
</style:style>
<style:style style:name="Heading_20_1" style:display-name="Heading 1" style:family="paragraph" style:parent-style-name="Heading" style:next-style-name="Text_20_body" style:default-outline-level="1" style:class="text">
  <style:text-properties fo:font-size="130%" fo:font-weight="bold"/>
</style:style>
<style:style style:name="Heading_20_2" style:display-name="Heading 2" style:family="paragraph" style:parent-style-name="Heading" style:next-style-name="Text_20_body" style:default-outline-level="2" style:class="text">
  <style:text-properties fo:font-size="115%" fo:font-weight="bold"/>
</style:style>
<style:style style:name="Quotations" style:family="paragraph" style:parent-style-name="Standard" style:class="html">
  <style:paragraph-properties fo:margin-left="1cm" fo:margin-right="1cm"/>
</style:style>
<style:style style:name="Strong_20_Emphasis" style:display-name="Strong Emphasis" style:family="text">
  <style:text-properties fo:font-weight="bold"/>
</style:style>
''';

const a4Layout =
    '<style:page-layout style:name="pm1"><style:page-layout-properties '
    'fo:page-width="21cm" fo:page-height="29.7cm" style:print-orientation="portrait" '
    'fo:margin-top="2cm" fo:margin-bottom="2cm" fo:margin-left="2cm" '
    'fo:margin-right="2cm"/></style:page-layout>';

/// An OpenDocument Text file with [body] in office:text.
Uint8List odtFile({
  String body = '<text:p/>',
  String automatic = '',
  String styles = libreOfficeStyles,
  String masterAutomatic = a4Layout,
  String masters =
      '<style:master-page style:name="Standard" style:page-layout-name="pm1"/>',
  String fonts =
      '<style:font-face style:name="Liberation Serif" '
      'svg:font-family="&apos;Liberation Serif&apos;"/>'
      '<style:font-face style:name="Liberation Sans" '
      'svg:font-family="&apos;Liberation Sans&apos;"/>',
  String mimetype = 'application/vnd.oasis.opendocument.text',
  String? manifest,
  Map<String, Object> extra = const {},
}) => zipOf({
  'mimetype': mimetype,
  'content.xml':
      '<?xml version="1.0" encoding="UTF-8"?>'
      '<office:document-content $odfNamespaces office:version="1.3">'
      '<office:font-face-decls>$fonts</office:font-face-decls>'
      '<office:automatic-styles>$automatic</office:automatic-styles>'
      '<office:body><office:text>$body</office:text></office:body>'
      '</office:document-content>',
  'styles.xml':
      '<?xml version="1.0" encoding="UTF-8"?>'
      '<office:document-styles $odfNamespaces office:version="1.3">'
      '<office:font-face-decls>$fonts</office:font-face-decls>'
      '<office:styles>$styles</office:styles>'
      '<office:automatic-styles>$masterAutomatic</office:automatic-styles>'
      '<office:master-styles>$masters</office:master-styles>'
      '</office:document-styles>',
  'META-INF/manifest.xml':
      manifest ??
      '<?xml version="1.0" encoding="UTF-8"?>'
          '<manifest:manifest xmlns:manifest="urn:oasis:names:tc:opendocument:xmlns:manifest:1.0" manifest:version="1.3">'
          '<manifest:file-entry manifest:full-path="/" manifest:media-type="$mimetype"/>'
          '</manifest:manifest>',
  ...extra,
});

/// A zip with the mimetype entry first and stored, as OpenDocument wants.
Uint8List zipOf(Map<String, Object> files) {
  final archive = Archive();
  for (final MapEntry(key: name, value: content) in files.entries) {
    final bytes = content is String
        ? utf8.encode(content)
        : content as List<int>;
    archive.addFile(
      ArchiveFile.bytes(name, bytes)
        ..compression = name == 'mimetype' ? CompressionType.none : null,
    );
  }
  return ZipEncoder().encodeBytes(archive);
}

List<Operation> operationsOf(Delta delta) => delta.toList();

/// The first operation whose text contains [text].
Operation textOperation(Delta delta, String text) =>
    operationsOf(delta).firstWhere(
      (operation) =>
          operation.data is String && (operation.data as String).contains(text),
    );

/// Attributes of the line that holds [text].
Map<String, dynamic>? lineOf(Delta delta, String text) {
  final operations = operationsOf(delta);
  for (var index = 0; index < operations.length; index++) {
    final data = operations[index].data;
    if (data is! String || !data.contains(text)) continue;
    if (data.indexOf('\n', data.indexOf(text)) >= 0) {
      return operations[index].attributes;
    }
    for (var next = index + 1; next < operations.length; next++) {
      final following = operations[next].data;
      if (following is String && following.contains('\n')) {
        return operations[next].attributes;
      }
    }
  }
  return null;
}

/// Values of the embeds of [type], in order.
List<Object?> embedsOf(Delta delta, String type) => [
  for (final operation in operationsOf(delta))
    if (operation.data case final Map<dynamic, dynamic> data
        when data.containsKey(type))
      data[type],
];

/// Text of the protected inline content, such as fields and notes.
List<OpaqueContent> opaqueOf(Delta delta) => [
  for (final value in embedsOf(delta, EmbedTypes.opaqueInline))
    OpaqueContent.decode(value),
];
