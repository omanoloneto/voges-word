import 'dart:typed_data';

import '../document/document_codec.dart';
import '../docx/docx_codec.dart';

/// Word 97–2003 documents (.doc, .dot); they open but are saved as .docx.
class DocCodec implements DocumentDecoder {
  DocCodec(this.docx);

  /// Opens the .docx package built from the file.
  final DocxCodec docx;

  @override
  LoadedDocument decode(Uint8List bytes) => throw UnimplementedError();
}
