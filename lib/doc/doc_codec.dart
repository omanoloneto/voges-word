import 'dart:typed_data';

import '../document/document_codec.dart';
import '../docx/docx_builder.dart';
import '../docx/docx_codec.dart';
import 'doc_file.dart';
import 'doc_reader.dart';

/// Word 97–2003 documents (.doc, .dot); they open but are saved as .docx.
class DocCodec implements DocumentDecoder {
  DocCodec(this.docx);

  /// Opens the .docx package built from the file.
  final DocxCodec docx;

  @override
  LoadedDocument decode(Uint8List bytes) {
    try {
      final reader = DocReader(DocFile.open(bytes));
      final package = DocxBuilder(reader.read()).build();
      return docx.read(package).withNotices(reader.notices);
    } on DocumentProblemException {
      rethrow;
    } on FormatException {
      throw DocumentProblemException(DocumentProblem.damaged);
    } on Error {
      // Offsets in the file are untrusted: whatever slips past the checks
      // reports a damaged file instead of crashing.
      throw DocumentProblemException(DocumentProblem.damaged);
    }
  }
}
