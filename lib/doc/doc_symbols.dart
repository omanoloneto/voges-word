/// The Unicode text of character [code] drawn in a symbol font, for the
/// characters with an obvious equivalent; null keeps the symbol font.
String? symbolText(String? font, int code) {
  final low = code >= 0xF000 && code <= 0xF0FF ? code - 0xF000 : code;
  if (low < 0x20 || low > 0xFF) return null;
  switch (font?.toLowerCase()) {
    case 'symbol':
      final index = low < 0x80 ? low - 0x20 : low - 0xA0 + 0x60;
      if (low >= 0x80 && low < 0xA0) return null;
      final mapped = _symbol.codeUnitAt(index);
      return mapped == 0x20 && low != 0x20 ? null : String.fromCharCode(mapped);
    case 'wingdings':
      final mapped = _wingdings[low];
      return mapped == null ? null : String.fromCharCode(mapped);
  }
  return null;
}

/// Symbol's 0x20–0x7F, then 0xA0–0xFF; spaces mark characters with no clear
/// Unicode equivalent.
const _symbol =
    ' !∀#∃%&∋()∗+,−./0123456789:;<=>?'
    '≅ΑΒΧΔΕΦΓΗΙϑΚΛΜΝΟΠΘΡΣΤΥςΩΞΨΖ[∴]⊥_'
    ' αβχδεφγηιϕκλμνοπθρστυϖωξψζ{|}∼ '
    '€ϒ′≤⁄∞ƒ♣♦♥♠↔←↑→↓°±″≥×∝∂•÷≠≡≈…  ↵'
    'ℵℑℜ℘⊗⊕∅∩∪⊃⊇⊄⊂⊆∈∉∠∇®©™∏√⋅¬∧∨⇔⇐⇑⇒⇓'
    '◊〈®©™∑           〉∫             ';

const _wingdings = {
  0x6C: 0x25CF,
  0x6E: 0x25A0,
  0x6F: 0x25A1,
  0x71: 0x2751,
  0x75: 0x25C6,
  0x76: 0x2756,
  0xA7: 0x25AA,
  0xA8: 0x25FB,
  0xD8: 0x27A2,
  0xFC: 0x2714,
  0xFD: 0x2612,
  0xFE: 0x2611,
};

/// BCP 47 tag of a Windows language id; null for unknown ones.
String? languageTag(int lcid) => _languages[lcid];

const _languages = {
  0x0401: 'ar-SA',
  0x0402: 'bg-BG',
  0x0403: 'ca-ES',
  0x0404: 'zh-TW',
  0x0405: 'cs-CZ',
  0x0406: 'da-DK',
  0x0407: 'de-DE',
  0x0408: 'el-GR',
  0x0409: 'en-US',
  0x040A: 'es-ES',
  0x040B: 'fi-FI',
  0x040C: 'fr-FR',
  0x040D: 'he-IL',
  0x040E: 'hu-HU',
  0x040F: 'is-IS',
  0x0410: 'it-IT',
  0x0411: 'ja-JP',
  0x0412: 'ko-KR',
  0x0413: 'nl-NL',
  0x0414: 'nb-NO',
  0x0415: 'pl-PL',
  0x0416: 'pt-BR',
  0x0418: 'ro-RO',
  0x0419: 'ru-RU',
  0x041A: 'hr-HR',
  0x041B: 'sk-SK',
  0x041D: 'sv-SE',
  0x041E: 'th-TH',
  0x041F: 'tr-TR',
  0x0421: 'id-ID',
  0x0422: 'uk-UA',
  0x0424: 'sl-SI',
  0x0425: 'et-EE',
  0x0426: 'lv-LV',
  0x0427: 'lt-LT',
  0x042A: 'vi-VN',
  0x0804: 'zh-CN',
  0x0807: 'de-CH',
  0x0809: 'en-GB',
  0x080A: 'es-MX',
  0x080C: 'fr-BE',
  0x0810: 'it-CH',
  0x0813: 'nl-BE',
  0x0816: 'pt-PT',
  0x0C07: 'de-AT',
  0x0C09: 'en-AU',
  0x0C0A: 'es-ES',
  0x0C0C: 'fr-CA',
  0x1009: 'en-CA',
  0x100C: 'fr-CH',
  0x1409: 'en-NZ',
  0x1809: 'en-IE',
  0x1C09: 'en-ZA',
  0x2C0A: 'es-AR',
  0x340A: 'es-CL',
  0x240A: 'es-CO',
  0x280A: 'es-PE',
  0x380A: 'es-UY',
};
