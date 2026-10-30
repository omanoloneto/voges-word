import 'dart:typed_data';

import 'package:flutter_quill/quill_delta.dart';

import '../document/document_codec.dart';
import '../document/document_look.dart';
import '../document/headers_footers.dart';
import '../docx/docx_builder.dart';
import '../docx/docx_codec.dart';
import 'odt_package.dart';
import 'odt_reader.dart';
import 'odt_writer.dart';

/// OpenDocument Text (.odt, .ott).
class OdtCodec implements DocumentCodec {
  OdtCodec(this.docx);

  /// Opens the .docx package built from the file.
  final DocxCodec docx;

  @override
  LoadedDocument decode(Uint8List bytes) {
    try {
      final package = OdtPackage.decode(bytes);
      // Named .odt but made by Word: its content decides.
      if (package == null) return docx.decode(bytes);
      final reader = OdtReader(package);
      final spec = reader.read();
      return docx.read(DocxBuilder(spec).build()).withNotices(reader.notices);
    } on FormatException {
      rethrow;
    } catch (_) {
      // Whatever a malformed file trips, it is reported as damaged.
      throw DocumentProblemException(DocumentProblem.damaged);
    }
  }

  @override
  Uint8List encode(
    Delta delta, {
    Object? source,
    DocumentLook look = const DocumentLook(),
    bool pageSetupChanged = false,
    HeadersFooters? headersFooters,
  }) => OdtWriter(
    docx.tables,
  ).write(delta, look: look, headersFooters: headersFooters, source: source);
}
