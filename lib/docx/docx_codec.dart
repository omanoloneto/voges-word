import 'dart:typed_data';

import 'package:flutter_quill/quill_delta.dart';

import '../document/document_codec.dart';
import '../document/tables.dart';
import 'docx_package.dart';
import 'docx_reader.dart';
import 'docx_template.dart';
import 'docx_writer.dart';

class DocxCodec implements DocumentCodec {
  DocxCodec(this.tables);

  final TableStore tables;

  @override
  DocumentFormat get format => DocumentFormat.docx;

  @override
  LoadedDocument decode(Uint8List bytes) =>
      DocxReader(DocxPackage.decode(bytes), tables).read();

  LoadedDocument createEmpty() =>
      DocxReader(newDocumentPackage(), tables).read();

  @override
  Uint8List encode(Delta delta, {Object? source}) => DocxWriter(
    tables,
  ).write(delta, source is DocxPackage ? source : newDocumentPackage());
}
