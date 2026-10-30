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
    expect(decodeCodePage([0xA0, 0xFF], 850), 'á\u00A0');
    expect(decodeCodePage([0x80], 99999), '€');
    expect(codePageOfCharset(204), 1251);
    expect(codePageOfCharset(128), isNull);
  });
}
