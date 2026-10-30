import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_quill/quill_delta.dart';

import '../document/document_codec.dart';
import '../document/document_look.dart';
import '../document/headers_footers.dart';
import '../document/text_encodings.dart';
import '../docx/docx_codec.dart';
import '../docx/docx_numbering.dart';
import 'html_codec.dart';
import 'markdown_reader.dart';
import 'markdown_writer.dart';

/// Markdown (.md), GitHub flavored.
class MarkdownCodec implements DocumentCodec {
  MarkdownCodec(this.docx);

  /// Opens the .docx package built from the file.
  final DocxCodec docx;

  /// Pictures come inside the file as `data:` URIs.
  static const maxBytes = 64 * 1024 * 1024;

  @override
  LoadedDocument decode(Uint8List bytes) => load(prepare(bytes));

  /// Builds the .docx package of the file, through HTML.
  static PreparedPackage prepare(Uint8List bytes) {
    if (bytes.length > maxBytes) {
      throw DocumentProblemException(DocumentProblem.tooLarge);
    }
    return guardParse(() {
      final (:html, :notices) = markdownHtml(decodeText(bytes));
      return prepareHtml(html, notices: notices);
    });
  }

  @override
  LoadedDocument load(covariant PreparedPackage prepared) =>
      guardParse(() => docx.load(prepared));

  @override
  Uint8List encode(
    Delta delta, {
    Object? source,
    DocumentLook look = const DocumentLook(),
    bool pageSetupChanged = false,
    HeadersFooters? headersFooters,
  }) {
    return Uint8List.fromList(
      utf8.encode(
        MarkdownWriter(
          docx.tables,
          numbering: DocxNumbering.of(source),
          look: look,
        ).write(delta),
      ),
    );
  }
}
