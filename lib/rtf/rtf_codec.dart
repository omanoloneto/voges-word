import 'dart:typed_data';

import 'package:flutter_quill/quill_delta.dart';

import '../document/document_codec.dart';
import '../document/document_look.dart';
import '../document/headers_footers.dart';
import '../docx/docx_builder.dart';
import '../docx/docx_codec.dart';
import 'rtf_reader.dart';
import 'rtf_writer.dart';

/// Rich Text Format (.rtf).
class RtfCodec implements DocumentCodec {
  RtfCodec(this.docx);

  /// Opens the .docx package built from the file.
  final DocxCodec docx;

  @override
  LoadedDocument decode(Uint8List bytes) => load(prepare(bytes));

  /// Builds the .docx package of the file.
  static PreparedPackage prepare(Uint8List bytes) => _readSafely(() {
    final document = RtfReader(bytes).read();
    return PreparedPackage(
      DocxBuilder(document.spec).build().parts,
      notices: [...document.notices],
    );
  });

  @override
  LoadedDocument load(covariant PreparedPackage prepared) =>
      _readSafely(() => docx.load(prepared));

  static T _readSafely<T>(T Function() read) {
    try {
      return read();
    } on FormatException {
      rethrow;
    } catch (_) {
      // Whatever else a broken file trips over is reported as damage.
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
  }) => RtfWriter(
    docx.tables,
  ).write(delta, look: look, headersFooters: headersFooters, source: source);
}
