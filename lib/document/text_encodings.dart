import 'dart:convert';
import 'dart:typed_data';

/// Text of a file whose encoding is unknown: a byte order mark decides, then
/// UTF-8, and Windows' Western code page when it isn't valid UTF-8.
String decodeText(Uint8List bytes) {
  if (bytes.length >= 3 &&
      bytes[0] == 0xEF &&
      bytes[1] == 0xBB &&
      bytes[2] == 0xBF) {
    return utf8.decode(bytes.sublist(3), allowMalformed: true);
  }
  if (bytes.length >= 2 &&
      (bytes[0] == 0xFF && bytes[1] == 0xFE ||
          bytes[0] == 0xFE && bytes[1] == 0xFF)) {
    final littleEndian = bytes[0] == 0xFF;
    final units = <int>[
      for (var i = 2; i + 1 < bytes.length; i += 2)
        littleEndian
            ? bytes[i] | bytes[i + 1] << 8
            : bytes[i] << 8 | bytes[i + 1],
    ];
    return String.fromCharCodes(units);
  }
  try {
    return utf8.decode(bytes);
  } on FormatException {
    return decodeCodePage(bytes, 1252);
  }
}

/// Decodes text in a single-byte code page; unknown code pages read as 1252.
String decodeCodePage(List<int> bytes, int codePage) {
  final high = _codePages[codePage] ?? _codePages[1252]!;
  final out = StringBuffer();
  for (final byte in bytes) {
    out.write(byte < 0x80 ? String.fromCharCode(byte) : high[byte - 0x80]);
  }
  return out.toString();
}

/// Whether [decodeCodePage] knows [codePage].
bool isKnownCodePage(int codePage) => _codePages.containsKey(codePage);

/// Code page of a Windows font character set (RTF's \fcharset, the .doc font
/// table); null for sets that aren't single-byte.
int? codePageOfCharset(int charset) => switch (charset) {
  0 || 1 => 1252,
  77 => 10000,
  161 => 1253,
  162 => 1254,
  163 => 1258,
  177 => 1255,
  178 => 1256,
  186 => 1257,
  204 => 1251,
  222 => 874,
  238 => 1250,
  254 => 437,
  255 => 850,
  _ => null,
};

/// Characters 0x80 to 0xFF of each code page.
const _codePages = <int, String>{
  437:
      'ÇüéâäàåçêëèïîìÄÅÉæÆôöòûùÿÖÜ¢£¥₧ƒ'
      'áíóúñÑªº¿⌐¬½¼¡«»░▒▓│┤╡╢╖╕╣║╗╝╜╛┐'
      '└┴┬├─┼╞╟╚╔╩╦╠═╬╧╨╤╥╙╘╒╓╫╪┘┌█▄▌▐▀'
      'αßΓπΣσµτΦΘΩδ∞φε∩≡±≥≤⌠⌡÷≈°∙·√ⁿ²■\u{a0}',
  850:
      'ÇüéâäàåçêëèïîìÄÅÉæÆôöòûùÿÖÜø£Ø×ƒ'
      'áíóúñÑªº¿®¬½¼¡«»░▒▓│┤ÁÂÀ©╣║╗╝¢¥┐'
      '└┴┬├─┼ãÃ╚╔╩╦╠═╬¤ðÐÊËÈıÍÎÏ┘┌█▄¦Ì▀'
      'ÓßÔÒõÕµþÞÚÛÙýÝ¯´\u{ad}±‗¾¶§÷¸°¨·¹³²■\u{a0}',
  852:
      'ÇüéâäůćçłëŐőîŹÄĆÉĹĺôöĽľŚśÖÜŤťŁ×č'
      'áíóúĄąŽžĘę¬źČş«»░▒▓│┤ÁÂĚŞ╣║╗╝Żż┐'
      '└┴┬├─┼Ăă╚╔╩╦╠═╬¤đĐĎËďŇÍÎě┘┌█▄ŢŮ▀'
      'ÓßÔŃńňŠšŔÚŕŰýÝţ´\u{ad}˝˛ˇ˘§÷¸°¨˙űŘř■\u{a0}',
  866:
      'АБВГДЕЖЗИЙКЛМНОПРСТУФХЦЧШЩЪЫЬЭЮЯ'
      'абвгдежзийклмноп░▒▓│┤╡╢╖╕╣║╗╝╜╛┐'
      '└┴┬├─┼╞╟╚╔╩╦╠═╬╧╨╤╥╙╘╒╓╫╪┘┌█▄▌▐▀'
      'рстуфхцчшщъыьэюяЁёЄєЇїЎў°∙·√№¤■\u{a0}',
  874:
      '€\u{fffd}\u{fffd}\u{fffd}\u{fffd}…\u{fffd}\u{fffd}\u{fffd}\u{fffd}\u{fffd}\u{fffd}\u{fffd}\u{fffd}\u{fffd}\u{fffd}\u{fffd}‘’“”•–—\u{fffd}\u{fffd}\u{fffd}\u{fffd}\u{fffd}\u{fffd}\u{fffd}\u{fffd}'
      '\u{a0}\u{e01}\u{e02}\u{e03}\u{e04}\u{e05}\u{e06}\u{e07}\u{e08}\u{e09}\u{e0a}\u{e0b}\u{e0c}\u{e0d}\u{e0e}\u{e0f}\u{e10}\u{e11}\u{e12}\u{e13}\u{e14}\u{e15}\u{e16}\u{e17}\u{e18}\u{e19}\u{e1a}\u{e1b}\u{e1c}\u{e1d}\u{e1e}\u{e1f}'
      '\u{e20}\u{e21}\u{e22}\u{e23}\u{e24}\u{e25}\u{e26}\u{e27}\u{e28}\u{e29}\u{e2a}\u{e2b}\u{e2c}\u{e2d}\u{e2e}\u{e2f}\u{e30}\u{e31}\u{e32}\u{e33}\u{e34}\u{e35}\u{e36}\u{e37}\u{e38}\u{e39}\u{e3a}\u{fffd}\u{fffd}\u{fffd}\u{fffd}\u{e3f}'
      '\u{e40}\u{e41}\u{e42}\u{e43}\u{e44}\u{e45}\u{e46}\u{e47}\u{e48}\u{e49}\u{e4a}\u{e4b}\u{e4c}\u{e4d}\u{e4e}\u{e4f}\u{e50}\u{e51}\u{e52}\u{e53}\u{e54}\u{e55}\u{e56}\u{e57}\u{e58}\u{e59}\u{e5a}\u{e5b}\u{fffd}\u{fffd}\u{fffd}\u{fffd}',
  1250:
      '€\u{fffd}‚\u{fffd}„…†‡\u{fffd}‰Š‹ŚŤŽŹ\u{fffd}‘’“”•–—\u{fffd}™š›śťžź'
      '\u{a0}ˇ˘Ł¤Ą¦§¨©Ş«¬\u{ad}®Ż°±˛ł´µ¶·¸ąş»Ľ˝ľż'
      'ŔÁÂĂÄĹĆÇČÉĘËĚÍÎĎĐŃŇÓÔŐÖ×ŘŮÚŰÜÝŢß'
      'ŕáâăäĺćçčéęëěíîďđńňóôőö÷řůúűüýţ˙',
  1251:
      'ЂЃ‚ѓ„…†‡€‰Љ‹ЊЌЋЏђ‘’“”•–—\u{fffd}™љ›њќћџ'
      '\u{a0}ЎўЈ¤Ґ¦§Ё©Є«¬\u{ad}®Ї°±Ііґµ¶·ё№є»јЅѕї'
      'АБВГДЕЖЗИЙКЛМНОПРСТУФХЦЧШЩЪЫЬЭЮЯ'
      'абвгдежзийклмнопрстуфхцчшщъыьэюя',
  1252:
      '€\u{fffd}‚ƒ„…†‡ˆ‰Š‹Œ\u{fffd}Ž\u{fffd}\u{fffd}‘’“”•–—˜™š›œ\u{fffd}žŸ'
      '\u{a0}¡¢£¤¥¦§¨©ª«¬\u{ad}®¯°±²³´µ¶·¸¹º»¼½¾¿'
      'ÀÁÂÃÄÅÆÇÈÉÊËÌÍÎÏÐÑÒÓÔÕÖ×ØÙÚÛÜÝÞß'
      'àáâãäåæçèéêëìíîïðñòóôõö÷øùúûüýþÿ',
  1253:
      '€\u{fffd}‚ƒ„…†‡\u{fffd}‰\u{fffd}‹\u{fffd}\u{fffd}\u{fffd}\u{fffd}\u{fffd}‘’“”•–—\u{fffd}™\u{fffd}›\u{fffd}\u{fffd}\u{fffd}\u{fffd}'
      '\u{a0}΅Ά£¤¥¦§¨©\u{fffd}«¬\u{ad}®―°±²³΄µ¶·ΈΉΊ»Ό½ΎΏ'
      'ΐΑΒΓΔΕΖΗΘΙΚΛΜΝΞΟΠΡ\u{fffd}ΣΤΥΦΧΨΩΪΫάέήί'
      'ΰαβγδεζηθικλμνξοπρςστυφχψωϊϋόύώ\u{fffd}',
  1254:
      '€\u{fffd}‚ƒ„…†‡ˆ‰Š‹Œ\u{fffd}\u{fffd}\u{fffd}\u{fffd}‘’“”•–—˜™š›œ\u{fffd}\u{fffd}Ÿ'
      '\u{a0}¡¢£¤¥¦§¨©ª«¬\u{ad}®¯°±²³´µ¶·¸¹º»¼½¾¿'
      'ÀÁÂÃÄÅÆÇÈÉÊËÌÍÎÏĞÑÒÓÔÕÖ×ØÙÚÛÜİŞß'
      'àáâãäåæçèéêëìíîïğñòóôõö÷øùúûüışÿ',
  1255:
      '€\u{fffd}‚ƒ„…†‡ˆ‰\u{fffd}‹\u{fffd}\u{fffd}\u{fffd}\u{fffd}\u{fffd}‘’“”•–—˜™\u{fffd}›\u{fffd}\u{fffd}\u{fffd}\u{fffd}'
      '\u{a0}¡¢£₪¥¦§¨©×«¬\u{ad}®¯°±²³´µ¶·¸¹÷»¼½¾¿'
      '\u{5b0}\u{5b1}\u{5b2}\u{5b3}\u{5b4}\u{5b5}\u{5b6}\u{5b7}\u{5b8}\u{5b9}\u{fffd}\u{5bb}\u{5bc}\u{5bd}\u{5be}\u{5bf}\u{5c0}\u{5c1}\u{5c2}\u{5c3}\u{5f0}\u{5f1}\u{5f2}\u{5f3}\u{5f4}\u{fffd}\u{fffd}\u{fffd}\u{fffd}\u{fffd}\u{fffd}\u{fffd}'
      '\u{5d0}\u{5d1}\u{5d2}\u{5d3}\u{5d4}\u{5d5}\u{5d6}\u{5d7}\u{5d8}\u{5d9}\u{5da}\u{5db}\u{5dc}\u{5dd}\u{5de}\u{5df}\u{5e0}\u{5e1}\u{5e2}\u{5e3}\u{5e4}\u{5e5}\u{5e6}\u{5e7}\u{5e8}\u{5e9}\u{5ea}\u{fffd}\u{fffd}\u{200e}\u{200f}\u{fffd}',
  1256:
      '€\u{67e}‚ƒ„…†‡ˆ‰\u{679}‹Œ\u{686}\u{698}\u{688}\u{6af}‘’“”•–—\u{6a9}™\u{691}›œ\u{200c}\u{200d}\u{6ba}'
      '\u{a0}\u{60c}¢£¤¥¦§¨©\u{6be}«¬\u{ad}®¯°±²³´µ¶·¸¹\u{61b}»¼½¾\u{61f}'
      '\u{6c1}\u{621}\u{622}\u{623}\u{624}\u{625}\u{626}\u{627}\u{628}\u{629}\u{62a}\u{62b}\u{62c}\u{62d}\u{62e}\u{62f}\u{630}\u{631}\u{632}\u{633}\u{634}\u{635}\u{636}×\u{637}\u{638}\u{639}\u{63a}\u{640}\u{641}\u{642}\u{643}'
      'à\u{644}â\u{645}\u{646}\u{647}\u{648}çèéêë\u{649}\u{64a}îï\u{64b}\u{64c}\u{64d}\u{64e}ô\u{64f}\u{650}÷\u{651}ù\u{652}ûü\u{200e}\u{200f}\u{6d2}',
  1257:
      '€\u{fffd}‚\u{fffd}„…†‡\u{fffd}‰\u{fffd}‹\u{fffd}¨ˇ¸\u{fffd}‘’“”•–—\u{fffd}™\u{fffd}›\u{fffd}¯˛\u{fffd}'
      '\u{a0}\u{fffd}¢£¤\u{fffd}¦§Ø©Ŗ«¬\u{ad}®Æ°±²³´µ¶·ø¹ŗ»¼½¾æ'
      'ĄĮĀĆÄÅĘĒČÉŹĖĢĶĪĻŠŃŅÓŌÕÖ×ŲŁŚŪÜŻŽß'
      'ąįāćäåęēčéźėģķīļšńņóōõö÷ųłśūüżž˙',
  1258:
      '€\u{fffd}‚ƒ„…†‡ˆ‰\u{fffd}‹Œ\u{fffd}\u{fffd}\u{fffd}\u{fffd}‘’“”•–—˜™\u{fffd}›œ\u{fffd}\u{fffd}Ÿ'
      '\u{a0}¡¢£¤¥¦§¨©ª«¬\u{ad}®¯°±²³´µ¶·¸¹º»¼½¾¿'
      'ÀÁÂĂÄÅÆÇÈÉÊË̀ÍÎÏĐÑ̉ÓÔƠÖ×ØÙÚÛÜỮß'
      'àáâăäåæçèéêë́íîïđṇ̃óôơö÷øùúûüư₫ÿ',
  10000:
      'ÄÅÇÉÑÖÜáàâäãåçéèêëíìîïñóòôöõúùûü'
      '†°¢£§•¶ß®©™´¨≠ÆØ∞±≤≥¥µ∂∑∏π∫ªºΩæø'
      '¿¡¬√ƒ≈∆«»…\u{a0}ÀÃÕŒœ–—“”‘’÷◊ÿŸ⁄€‹›ﬁﬂ'
      '‡·‚„‰ÂÊÁËÈÍÎÏÌÓÔÒÚÛÙıˆ˜¯˘˙˚¸˝˛ˇ',
};
