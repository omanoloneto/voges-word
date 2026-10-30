import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_quill/quill_delta.dart';

import '../document/document_codec.dart';
import '../document/document_look.dart';
import '../document/headers_footers.dart';
import '../document/text_encodings.dart';
import '../docx/docx_builder.dart';
import '../docx/docx_codec.dart';
import 'html_reader.dart';
import 'html_writer.dart';
import 'writing.dart';

/// Web pages (.html, .htm, .xhtml).
class HtmlCodec implements DocumentCodec {
  HtmlCodec(this.docx);

  /// Opens the .docx package built from the file.
  final DocxCodec docx;

  /// Pictures come inside the page as `data:` URIs, so pages can be large.
  static const maxBytes = 64 * 1024 * 1024;

  @override
  LoadedDocument decode(Uint8List bytes) {
    if (bytes.length > maxBytes) {
      throw DocumentProblemException(DocumentProblem.tooLarge);
    }
    return guardParse(() => openHtml(decodeHtml(bytes), docx));
  }

  @override
  Uint8List encode(
    Delta delta, {
    Object? source,
    DocumentLook look = const DocumentLook(),
    bool pageSetupChanged = false,
    HeadersFooters? headersFooters,
  }) => Uint8List.fromList(
    utf8.encode(
      HtmlWriter(
        docx.tables,
        look: look,
        numbering: ListNumbering.of(source),
      ).write(delta),
    ),
  );
}

/// Opens [html] through the .docx reader, so saving as .docx keeps styles,
/// lists and page setup.
LoadedDocument openHtml(String html, DocxCodec docx) {
  final content = readHtml(html);
  return docx
      .read(DocxBuilder(content.spec).build())
      .withNotices(content.notices);
}

/// Runs [parse], turning any failure on hostile input into a
/// [FormatException].
T guardParse<T>(T Function() parse) {
  try {
    return parse();
  } on FormatException {
    rethrow;
  } catch (error) {
    throw FormatException('The file could not be read (${error.runtimeType}).');
  }
}

/// Text of a page: a byte order mark decides, then the `<meta>` charset or the
/// XML declaration, then UTF-8 and Windows-1252.
String decodeHtml(Uint8List bytes) {
  final bom =
      bytes.length >= 2 &&
      (bytes[0] == 0xEF && bytes[1] == 0xBB ||
          bytes[0] == 0xFF && bytes[1] == 0xFE ||
          bytes[0] == 0xFE && bytes[1] == 0xFF);
  if (!bom) {
    final head = latin1.decode(
      Uint8List.sublistView(bytes, 0, math.min(bytes.length, 4096)),
    );
    final declared =
        _metaCharset.firstMatch(head)?.group(1) ??
        _xmlEncoding.firstMatch(head)?.group(1);
    final codePage = declared == null ? null : _codePageOf(declared);
    if (codePage != null) return decodeCodePage(bytes, codePage);
  }
  return decodeText(bytes);
}

final _metaCharset = RegExp(
  r'''<meta\b[^>]*?charset\s*=\s*["']?\s*([\w.:-]+)''',
  caseSensitive: false,
);
final _xmlEncoding = RegExp(
  r'''^\s*<\?xml\b[^>]*?encoding\s*=\s*["']([\w.:-]+)''',
  caseSensitive: false,
);

/// Single-byte code page of a charset label; UTF-8 and unknown labels go
/// through [decodeText].
int? _codePageOf(String label) => switch (label.toLowerCase()) {
  'windows-1252' ||
  'cp1252' ||
  'x-cp1252' ||
  'iso-8859-1' ||
  'iso8859-1' ||
  'iso_8859-1' ||
  'latin1' ||
  'l1' ||
  'us-ascii' ||
  'ascii' => 1252,
  'windows-1250' || 'cp1250' || 'x-cp1250' => 1250,
  'windows-1251' || 'cp1251' || 'x-cp1251' => 1251,
  'windows-1253' || 'cp1253' => 1253,
  'windows-1254' || 'cp1254' || 'iso-8859-9' || 'latin5' => 1254,
  'windows-1255' || 'cp1255' => 1255,
  'windows-1256' || 'cp1256' => 1256,
  'windows-1257' || 'cp1257' => 1257,
  'windows-1258' || 'cp1258' => 1258,
  'windows-874' || 'tis-620' || 'iso-8859-11' => 874,
  'macintosh' || 'mac' || 'x-mac-roman' || 'csmacintosh' => 10000,
  'ibm866' || 'cp866' => 866,
  'ibm437' || 'cp437' => 437,
  'ibm850' || 'cp850' => 850,
  'ibm852' || 'cp852' => 852,
  _ => null,
};
