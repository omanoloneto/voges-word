import 'dart:convert';
import 'dart:typed_data';

import '../doc/doc_codec.dart';
import '../document/document_codec.dart';
import '../document/plain_text_codec.dart';
import '../docx/docx_codec.dart';
import '../docx/docx_package.dart';
import '../html/html_codec.dart';
import '../html/markdown_codec.dart';
import '../odt/odt_codec.dart';
import '../rtf/rtf_codec.dart';

/// The reader and writer of each format.
class DocumentCodecs {
  DocumentCodecs({required this.docx, required this.plainText})
    : _docm = DocxCodec(docx.tables, flavor: DocxFlavor.macroEnabled),
      _doc = DocCodec(docx),
      _odt = OdtCodec(docx),
      _rtf = RtfCodec(docx),
      _html = HtmlCodec(docx),
      _markdown = MarkdownCodec(docx);

  final DocxCodec docx;
  final PlainTextCodec plainText;
  final DocxCodec _docm;
  final DocCodec _doc;
  final OdtCodec _odt;
  final RtfCodec _rtf;
  final HtmlCodec _html;
  final MarkdownCodec _markdown;

  DocumentDecoder decoder(DocumentFormat format) => switch (format) {
    DocumentFormat.doc => _doc,
    _ => encoder(format),
  };

  /// Only for [DocumentFormat.writable] formats.
  DocumentCodec encoder(DocumentFormat format) => switch (format) {
    DocumentFormat.docx => docx,
    DocumentFormat.docm => _docm,
    DocumentFormat.odt => _odt,
    DocumentFormat.rtf => _rtf,
    DocumentFormat.html => _html,
    DocumentFormat.markdown => _markdown,
    DocumentFormat.plainText => plainText,
    DocumentFormat.doc => throw ArgumentError.value(format, 'format'),
  };
}

/// The format of a file: its content wins over its name, so a .doc that is
/// really RTF or a web page still opens. Null when the name's extension isn't
/// supported.
({DocumentFormat format, bool template})? detectFormat(
  String name,
  Uint8List bytes,
) {
  final named = DocumentFormat.matchFileName(name);
  if (named == null) return null;
  // Text and Markdown open as text even when they look like something else.
  if (named.format == DocumentFormat.plainText ||
      named.format == DocumentFormat.markdown) {
    return named;
  }
  final DocumentFormat format;
  if (_startsWith(bytes, const [
    0xD0,
    0xCF,
    0x11,
    0xE0,
    0xA1,
    0xB1,
    0x1A,
    0xE1,
  ])) {
    format = DocumentFormat.doc;
  } else if (_startsWith(bytes, const [0x50, 0x4B, 0x03, 0x04])) {
    format = named.format == DocumentFormat.odt || _isOpenDocumentText(bytes)
        ? DocumentFormat.odt
        : named.format == DocumentFormat.docm
        ? DocumentFormat.docm
        : DocumentFormat.docx;
  } else if (_head(bytes).startsWith(r'{\rtf')) {
    format = DocumentFormat.rtf;
  } else if (_looksLikeHtml(_head(bytes).toLowerCase())) {
    format = DocumentFormat.html;
  } else {
    format = named.format;
  }
  return (format: format, template: named.template);
}

bool _startsWith(Uint8List bytes, List<int> prefix) {
  if (bytes.length < prefix.length) return false;
  for (var index = 0; index < prefix.length; index++) {
    if (bytes[index] != prefix[index]) return false;
  }
  return true;
}

/// The first bytes as Latin-1, without a BOM or leading spaces.
String _head(Uint8List bytes) {
  var start = 0;
  if (_startsWith(bytes, const [0xEF, 0xBB, 0xBF])) start = 3;
  final end = start + 4096 < bytes.length ? start + 4096 : bytes.length;
  return latin1.decode(bytes.sublist(start, end)).trimLeft();
}

bool _looksLikeHtml(String head) =>
    head.startsWith('<') &&
    (head.contains('<html') ||
        head.contains('<!doctype html') ||
        head.contains('<body'));

/// OpenDocument files start with a stored `mimetype` entry.
bool _isOpenDocumentText(Uint8List bytes) {
  if (bytes.length < 30) return false;
  final data = ByteData.sublistView(bytes);
  final nameLength = data.getUint16(26, Endian.little);
  final extraLength = data.getUint16(28, Endian.little);
  final nameEnd = 30 + nameLength;
  if (nameLength != 8 || nameEnd > bytes.length) return false;
  if (latin1.decode(bytes.sublist(30, nameEnd)) != 'mimetype') return false;
  final start = nameEnd + extraLength;
  const type = 'application/vnd.oasis.opendocument.text';
  if (start + type.length > bytes.length) return false;
  return latin1.decode(bytes.sublist(start, start + type.length)) == type;
}
