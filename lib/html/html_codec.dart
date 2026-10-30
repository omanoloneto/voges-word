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
import '../docx/docx_package.dart';
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
  LoadedDocument decode(Uint8List bytes) => load(prepare(bytes));

  /// Builds the .docx package of the page.
  static PreparedPackage prepare(Uint8List bytes) {
    if (bytes.length > maxBytes) {
      throw DocumentProblemException(DocumentProblem.tooLarge);
    }
    return guardParse(() {
      final (:text, :lossy) = decodeHtml(bytes);
      return prepareHtml(
        text,
        notices: [if (lossy) DocumentNotice.contentNotImported],
      );
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
  }) => Uint8List.fromList(
    utf8.encode(
      HtmlWriter(
        docx.tables,
        look: look,
        numbering: ListNumbering.of(source),
        package: source is DocxPackage ? source : null,
      ).write(delta),
    ),
  );
}

/// Builds the .docx package of [html], so saving as .docx keeps styles, lists
/// and page setup; [notices] come after the page's own.
PreparedPackage prepareHtml(
  String html, {
  Iterable<DocumentNotice> notices = const [],
}) {
  final content = readHtml(html);
  return PreparedPackage(
    DocxBuilder(content.spec).build().parts,
    notices: [...content.notices, ...notices],
  );
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
/// XML declaration, then UTF-8 and Windows-1252. [lossy] tells that the page
/// has characters of an East Asian encoding this app can't read.
({String text, bool lossy}) decodeHtml(Uint8List bytes) {
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
        (_metaCharset.firstMatch(head)?.group(1) ??
                _xmlEncoding.firstMatch(head)?.group(1))
            ?.toLowerCase();
    if (_utf8Labels.contains(declared)) {
      return (text: _declaredUtf8(bytes), lossy: false);
    }
    if (_codePages[declared] case final codePage?) {
      return (text: decodeCodePage(bytes, codePage), lossy: false);
    }
    if (_eastAsian[declared] case final encoding?) {
      // Pages often keep an old label after moving to UTF-8.
      if (encoding != EastAsianEncoding.iso2022 &&
          encoding != EastAsianEncoding.hz) {
        try {
          return (text: utf8.decode(bytes), lossy: false);
        } on FormatException {
          // Read in the declared encoding.
        }
      }
      return decodeEastAsian(bytes, encoding);
    }
  }
  return (text: decodeText(bytes), lossy: false);
}

/// As in browsers, a stray byte is one U+FFFD, not a reason to read the whole
/// page as Western text; a page with more bytes that aren't UTF-8 than
/// characters that are is Western text with the wrong label, whose accented
/// letters may happen to make a few.
String _declaredUtf8(Uint8List bytes) {
  try {
    return utf8.decode(bytes);
  } on FormatException {
    final text = utf8.decode(bytes, allowMalformed: true);
    var valid = 0;
    var replaced = 0;
    for (final rune in text.runes) {
      if (rune == 0xFFFD) {
        replaced++;
      } else if (rune >= 0x80) {
        valid++;
      }
    }
    // U+FFFD written in the page is a character like any other.
    var written = 0;
    for (var index = 0; index + 2 < bytes.length; index++) {
      if (bytes[index] == 0xEF &&
          bytes[index + 1] == 0xBF &&
          bytes[index + 2] == 0xBD) {
        written++;
      }
    }
    return valid + written > replaced - written
        ? text
        : decodeCodePage(bytes, 1252);
  }
}

final _metaCharset = RegExp(
  r'''<meta\b[^>]*?charset\s*=\s*["']?\s*([\w.:-]+)''',
  caseSensitive: false,
);
final _xmlEncoding = RegExp(
  r'''^\s*<\?xml\b[^>]*?encoding\s*=\s*["']([\w.:-]+)''',
  caseSensitive: false,
);

// Charset labels as the WHATWG Encoding Standard names them. A page whose
// head reads as ASCII isn't UTF-16, so those labels mean UTF-8.
const _utf8Labels = {
  'unicode-1-1-utf-8',
  'unicode11utf8',
  'unicode20utf8',
  'utf-8',
  'utf8',
  'x-unicode20utf8',
  'csunicode',
  'iso-10646-ucs-2',
  'ucs-2',
  'unicode',
  'unicodefeff',
  'unicodefffe',
  'utf-16',
  'utf-16be',
  'utf-16le',
};

const _codePages = <String, int>{
  '866': 866,
  'cp866': 866,
  'csibm866': 866,
  'ibm866': 866,
  'csisolatin2': 28592,
  'iso-8859-2': 28592,
  'iso-ir-101': 28592,
  'iso8859-2': 28592,
  'iso88592': 28592,
  'iso_8859-2': 28592,
  'iso_8859-2:1987': 28592,
  'l2': 28592,
  'latin2': 28592,
  'csisolatin3': 28593,
  'iso-8859-3': 28593,
  'iso-ir-109': 28593,
  'iso8859-3': 28593,
  'iso88593': 28593,
  'iso_8859-3': 28593,
  'iso_8859-3:1988': 28593,
  'l3': 28593,
  'latin3': 28593,
  'csisolatin4': 28594,
  'iso-8859-4': 28594,
  'iso-ir-110': 28594,
  'iso8859-4': 28594,
  'iso88594': 28594,
  'iso_8859-4': 28594,
  'iso_8859-4:1988': 28594,
  'l4': 28594,
  'latin4': 28594,
  'csisolatincyrillic': 28595,
  'cyrillic': 28595,
  'iso-8859-5': 28595,
  'iso-ir-144': 28595,
  'iso8859-5': 28595,
  'iso88595': 28595,
  'iso_8859-5': 28595,
  'iso_8859-5:1988': 28595,
  'arabic': 28596,
  'asmo-708': 28596,
  'csiso88596e': 28596,
  'csiso88596i': 28596,
  'csisolatinarabic': 28596,
  'ecma-114': 28596,
  'iso-8859-6': 28596,
  'iso-8859-6-e': 28596,
  'iso-8859-6-i': 28596,
  'iso-ir-127': 28596,
  'iso8859-6': 28596,
  'iso88596': 28596,
  'iso_8859-6': 28596,
  'iso_8859-6:1987': 28596,
  'csisolatingreek': 28597,
  'ecma-118': 28597,
  'elot_928': 28597,
  'greek': 28597,
  'greek8': 28597,
  'iso-8859-7': 28597,
  'iso-ir-126': 28597,
  'iso8859-7': 28597,
  'iso88597': 28597,
  'iso_8859-7': 28597,
  'iso_8859-7:1987': 28597,
  'sun_eu_greek': 28597,
  'csiso88598e': 28598,
  'csisolatinhebrew': 28598,
  'hebrew': 28598,
  'iso-8859-8': 28598,
  'iso-8859-8-e': 28598,
  'iso-ir-138': 28598,
  'iso8859-8': 28598,
  'iso88598': 28598,
  'iso_8859-8': 28598,
  'iso_8859-8:1988': 28598,
  'visual': 28598,
  'csiso88598i': 28598,
  'iso-8859-8-i': 28598,
  'logical': 28598,
  'csisolatin6': 28600,
  'iso-8859-10': 28600,
  'iso-ir-157': 28600,
  'iso8859-10': 28600,
  'iso885910': 28600,
  'l6': 28600,
  'latin6': 28600,
  'iso-8859-13': 28603,
  'iso8859-13': 28603,
  'iso885913': 28603,
  'iso-8859-14': 28604,
  'iso8859-14': 28604,
  'iso885914': 28604,
  'csisolatin9': 28605,
  'iso-8859-15': 28605,
  'iso8859-15': 28605,
  'iso885915': 28605,
  'iso_8859-15': 28605,
  'l9': 28605,
  'iso-8859-16': 28606,
  'cskoi8r': 20866,
  'koi': 20866,
  'koi8': 20866,
  'koi8-r': 20866,
  'koi8_r': 20866,
  'koi8-ru': 21866,
  'koi8-u': 21866,
  'csmacintosh': 10000,
  'mac': 10000,
  'macintosh': 10000,
  'x-mac-roman': 10000,
  'dos-874': 874,
  'iso-8859-11': 874,
  'iso8859-11': 874,
  'iso885911': 874,
  'tis-620': 874,
  'windows-874': 874,
  'cp1250': 1250,
  'windows-1250': 1250,
  'x-cp1250': 1250,
  'cp1251': 1251,
  'windows-1251': 1251,
  'x-cp1251': 1251,
  'ansi_x3.4-1968': 1252,
  'ascii': 1252,
  'cp1252': 1252,
  'cp819': 1252,
  'csisolatin1': 1252,
  'ibm819': 1252,
  'iso-8859-1': 1252,
  'iso-ir-100': 1252,
  'iso8859-1': 1252,
  'iso88591': 1252,
  'iso_8859-1': 1252,
  'iso_8859-1:1987': 1252,
  'l1': 1252,
  'latin1': 1252,
  'us-ascii': 1252,
  'windows-1252': 1252,
  'x-cp1252': 1252,
  'cp1253': 1253,
  'windows-1253': 1253,
  'x-cp1253': 1253,
  'cp1254': 1254,
  'csisolatin5': 1254,
  'iso-8859-9': 1254,
  'iso-ir-148': 1254,
  'iso8859-9': 1254,
  'iso88599': 1254,
  'iso_8859-9': 1254,
  'iso_8859-9:1989': 1254,
  'l5': 1254,
  'latin5': 1254,
  'windows-1254': 1254,
  'x-cp1254': 1254,
  'cp1255': 1255,
  'windows-1255': 1255,
  'x-cp1255': 1255,
  'cp1256': 1256,
  'windows-1256': 1256,
  'x-cp1256': 1256,
  'cp1257': 1257,
  'windows-1257': 1257,
  'x-cp1257': 1257,
  'cp1258': 1258,
  'windows-1258': 1258,
  'x-cp1258': 1258,
  'x-mac-cyrillic': 10007,
  'x-mac-ukrainian': 10007,
  // DOS code pages browsers don't name but older pages do.
  'ibm437': 437,
  'cp437': 437,
  'ibm850': 850,
  'cp850': 850,
  'ibm852': 852,
  'cp852': 852,
};

const _eastAsian = <String, EastAsianEncoding>{
  'chinese': EastAsianEncoding.gbk,
  'csgb2312': EastAsianEncoding.gbk,
  'csiso58gb231280': EastAsianEncoding.gbk,
  'gb2312': EastAsianEncoding.gbk,
  'gb_2312': EastAsianEncoding.gbk,
  'gb_2312-80': EastAsianEncoding.gbk,
  'gbk': EastAsianEncoding.gbk,
  'iso-ir-58': EastAsianEncoding.gbk,
  'x-gbk': EastAsianEncoding.gbk,
  'gb18030': EastAsianEncoding.gbk,
  'big5': EastAsianEncoding.big5,
  'big5-hkscs': EastAsianEncoding.big5,
  'cn-big5': EastAsianEncoding.big5,
  'csbig5': EastAsianEncoding.big5,
  'x-x-big5': EastAsianEncoding.big5,
  'cseucpkdfmtjapanese': EastAsianEncoding.eucJp,
  'euc-jp': EastAsianEncoding.eucJp,
  'x-euc-jp': EastAsianEncoding.eucJp,
  'csiso2022jp': EastAsianEncoding.iso2022,
  'iso-2022-jp': EastAsianEncoding.iso2022,
  'csiso2022kr': EastAsianEncoding.iso2022,
  'iso-2022-kr': EastAsianEncoding.iso2022,
  'iso-2022-cn': EastAsianEncoding.iso2022,
  'iso-2022-cn-ext': EastAsianEncoding.iso2022,
  'hz-gb-2312': EastAsianEncoding.hz,
  'csshiftjis': EastAsianEncoding.shiftJis,
  'ms932': EastAsianEncoding.shiftJis,
  'ms_kanji': EastAsianEncoding.shiftJis,
  'shift-jis': EastAsianEncoding.shiftJis,
  'shift_jis': EastAsianEncoding.shiftJis,
  'sjis': EastAsianEncoding.shiftJis,
  'windows-31j': EastAsianEncoding.shiftJis,
  'x-sjis': EastAsianEncoding.shiftJis,
  'cseuckr': EastAsianEncoding.eucKr,
  'csksc56011987': EastAsianEncoding.eucKr,
  'euc-kr': EastAsianEncoding.eucKr,
  'iso-ir-149': EastAsianEncoding.eucKr,
  'korean': EastAsianEncoding.eucKr,
  'ks_c_5601-1987': EastAsianEncoding.eucKr,
  'ks_c_5601-1989': EastAsianEncoding.eucKr,
  'ksc5601': EastAsianEncoding.eucKr,
  'ksc_5601': EastAsianEncoding.eucKr,
  'windows-949': EastAsianEncoding.eucKr,
};
