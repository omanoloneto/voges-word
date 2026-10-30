import 'dart:typed_data';

import 'package:flutter_quill/quill_delta.dart';

import '../document/document_codec.dart';
import '../document/document_look.dart';
import '../document/headers_footers.dart';
import '../document/tables.dart';
import 'docx_package.dart';
import 'docx_reader.dart';
import 'docx_template.dart';
import 'docx_writer.dart';

class DocxCodec implements DocumentCodec {
  DocxCodec(this.tables, {this.flavor = DocxFlavor.document});

  final TableStore tables;

  /// Kind of package written; .docm keeps its macros.
  final DocxFlavor flavor;

  @override
  LoadedDocument decode(Uint8List bytes) => read(DocxPackage.decode(bytes));

  /// Opens a package built in memory, like the ones made from other formats.
  LoadedDocument read(DocxPackage package) =>
      DocxReader(package, tables).read();

  LoadedDocument createEmpty() => create(DocumentTemplate.blank);

  /// [language] goes into the new document so Word checks its spelling in
  /// that language; [content] fills templates that come with sample text.
  LoadedDocument create(
    DocumentTemplate template, {
    String language = 'en-US',
    Delta? content,
  }) {
    final package = newDocumentPackage(TemplateOptions.of(template), language);
    if (content == null) return DocxReader(package, tables).read();
    return decode(encode(content, source: package));
  }

  @override
  Uint8List encode(
    Delta delta, {
    Object? source,
    DocumentLook look = const DocumentLook(),
    bool pageSetupChanged = false,
    HeadersFooters? headersFooters,
  }) => DocxWriter(tables).write(
    delta,
    (source is DocxPackage ? source : newDocumentPackage()).copy()
      ..convertTo(flavor),
    pageSetup: pageSetupChanged ? look : null,
    headersFooters: headersFooters,
  );
}
