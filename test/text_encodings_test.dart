import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:voges_word/document/text_encodings.dart';

void main() {
  test('decodes the byte order marks, UTF-8 and Windows-1252', () {
    expect(decodeText(Uint8List.fromList([0xEF, 0xBB, 0xBF, 0x61])), 'a');
    expect(decodeText(Uint8List.fromList([0xFF, 0xFE, 0xE7, 0x00])), 'ç');
    expect(decodeText(Uint8List.fromList(utf8.encode('ação'))), 'ação');
    expect(decodeText(Uint8List.fromList([0x93, 0x61, 0x94, 0xE9])), '“a”é');
  });

  test('reads single-byte code pages', () {
    expect(decodeCodePage([0xC0, 0xE9], 1251), 'Ай');
    expect(decodeCodePage([0x8A, 0xB9], 1250), 'Šą');
    expect(decodeCodePage([0x87, 0x8E], 10000), 'áé');
    expect(decodeCodePage([0x80], 437), 'Ç');
    expect(decodeCodePage([0xA0, 0xFF], 850), 'á ');
    expect(decodeCodePage([0x80], 99999), '€');
    expect(codePageOfCharset(204), 1251);
    expect(codePageOfCharset(128), isNull);
  });

  test('reads the ISO-8859 and KOI8 sets as browsers do', () {
    expect(decodeCodePage([0xA4, 0xA6, 0xBC], 28605), '€ŠŒ');
    expect(
      decodeCodePage(latin1.encode('Za\xBF\xF3\xB3\xE6 g\xEA\xB6l\xB1'), 28592),
      'Zażółć gęślą',
    );
    expect(
      decodeCodePage([0xCA, 0xE1, 0xEB, 0xE7, 0xEC, 0xDD, 0xF1, 0xE1], 28597),
      'Καλημέρα',
    );
    expect(decodeCodePage([0xF3, 0xDF, 0xC5, 0xDB, 0xD8], 20866), 'Съешь');
    expect(decodeCodePage([0xA4, 0xA6, 0xAE], 21866), 'єіў');
    expect(decodeCodePage([0xE0, 0xE9], 28598), 'אי');
    expect(decodeCodePage([0xA2, 0xFF], 10007), 'Ґ€');
    // Control characters and undefined bytes don't pass as text.
    expect(decodeCodePage([0x85, 0xA5], 28593), '\u{FFFD}\u{FFFD}');
    for (final codePage in [28592, 28595, 28597, 28605, 20866, 21866]) {
      expect(isKnownCodePage(codePage), isTrue, reason: '$codePage');
    }
  });

  test('keeps the ASCII text of East Asian encodings it has no tables for', () {
    // 日本語 and half-width ｱ in Shift_JIS.
    final shiftJis = decodeEastAsian(
      Uint8List.fromList([
        ...latin1.encode('<p>'),
        0x93, 0xFA, 0x96, 0x7B, 0x8C, 0xEA, 0xB1, //
        ...latin1.encode('</p>'),
      ]),
      EastAsianEncoding.shiftJis,
    );
    expect(shiftJis.text, '<p>\u{FFFD}\u{FFFD}\u{FFFD}ｱ</p>');
    expect(shiftJis.lossy, isTrue);

    // A trail byte in the ASCII range belongs to its character; a byte
    // that can't follow the lead, like `<`, is read again.
    expect(
      decodeEastAsian(
        Uint8List.fromList([0xA4, 0x5C, 0x61]),
        EastAsianEncoding.big5,
      ).text,
      '\u{FFFD}a',
    );
    expect(
      decodeEastAsian(
        Uint8List.fromList([0xA4, 0x3C, 0x61]),
        EastAsianEncoding.big5,
      ).text,
      '\u{FFFD}<a',
    );

    // GB18030's four-byte characters and EUC-KR's two-byte ones.
    expect(
      decodeEastAsian(
        Uint8List.fromList([0x81, 0x30, 0x81, 0x30, 0x41]),
        EastAsianEncoding.gbk,
      ).text,
      '\u{FFFD}A',
    );
    expect(
      decodeEastAsian(
        Uint8List.fromList([0xC7, 0xD1, 0x20, 0x41]),
        EastAsianEncoding.eucKr,
      ).text,
      '\u{FFFD} A',
    );

    // ISO-2022-JP shifts into two-byte characters made of ASCII bytes.
    final iso2022 = decodeEastAsian(
      Uint8List.fromList([
        ...latin1.encode('a'),
        0x1B, 0x24, 0x42, 0x46, 0x7C, 0x4B, 0x5C, 0x1B, 0x28, 0x42, //
        ...latin1.encode('<b>'),
      ]),
      EastAsianEncoding.iso2022,
    );
    expect(iso2022.text, 'a\u{FFFD}\u{FFFD}<b>');

    final ascii = decodeEastAsian(
      Uint8List.fromList(latin1.encode('<p>plain</p>')),
      EastAsianEncoding.eucJp,
    );
    expect(ascii.text, '<p>plain</p>');
    expect(ascii.lossy, isFalse);
  });
}
