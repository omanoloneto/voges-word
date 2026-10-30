import 'dart:math' as math;

import 'byte_view.dart';
import 'doc_sprms.dart';

/// Character properties (CHP) from styles and sprms.
class CharProps {
  /// Character style; 10 is Default Paragraph Font.
  int style = 10;
  bool bold = false;
  bool italic = false;
  bool strike = false;
  bool doubleStrike = false;
  bool caps = false;
  bool smallCaps = false;
  bool hidden = false;
  int underline = 0;
  int halfPoints = 20;
  int font = 0;

  /// RRGGBB; null is automatic.
  String? color;
  String? highlight;
  String? shading;

  /// 1 superscript, 2 subscript.
  int script = 0;
  int language = 0x0400;

  /// The character is a field mark, picture, note reference...
  bool special = false;
  bool deleted = false;
  bool inserted = false;

  /// Form field data or an OLE object instead of a picture.
  bool formData = false;
  bool ole = false;
  int pictureOffset = -1;
  int symbolFont = -1;
  int symbolCharacter = 0;

  CharProps copy() => CharProps()
    ..style = style
    ..bold = bold
    ..italic = italic
    ..strike = strike
    ..doubleStrike = doubleStrike
    ..caps = caps
    ..smallCaps = smallCaps
    ..hidden = hidden
    ..underline = underline
    ..halfPoints = halfPoints
    ..font = font
    ..color = color
    ..highlight = highlight
    ..shading = shading
    ..script = script
    ..language = language
    ..special = special
    ..deleted = deleted
    ..inserted = inserted
    ..formData = formData
    ..ole = ole
    ..pictureOffset = pictureOffset
    ..symbolFont = symbolFont
    ..symbolCharacter = symbolCharacter;

  /// Applies the character sprms of a grpprl; toggles resolve against
  /// [style], the properties the styles give.
  void apply(ByteView data, int start, int end, CharProps style) {
    forEachSprm(data, start, end, (sprm, at, size) {
      switch (sprm) {
        case Sprm.cFBold:
          bold = _toggle(data.u8(at), bold, style.bold);
        case Sprm.cFItalic:
          italic = _toggle(data.u8(at), italic, style.italic);
        case Sprm.cFStrike:
          strike = _toggle(data.u8(at), strike, style.strike);
        case Sprm.cFDStrike:
          doubleStrike = _toggle(data.u8(at), doubleStrike, style.doubleStrike);
        case Sprm.cFCaps:
          caps = _toggle(data.u8(at), caps, style.caps);
        case Sprm.cFSmallCaps:
          smallCaps = _toggle(data.u8(at), smallCaps, style.smallCaps);
        case Sprm.cFVanish:
          hidden = _toggle(data.u8(at), hidden, style.hidden);
        case Sprm.cKul:
          underline = data.u8(at);
        case Sprm.cHps:
          halfPoints = data.u16(at).clamp(2, 3276);
        case Sprm.cRgFtc0:
          font = data.u16(at);
        case Sprm.cIco:
          color = icoColor(data.u8(at));
        case Sprm.cCv:
          color = colorRef(data.u32(at));
        case Sprm.cHighlight:
          highlight = icoColor(data.u8(at));
        case Sprm.cShd80:
          shading = shading80(data.u16(at));
        case Sprm.cShd when size >= 10:
          shading = shadingAt(data, at);
        case Sprm.cIss:
          script = data.u8(at);
        case Sprm.cRgLid0 || Sprm.cRgLid0Old:
          language = data.u16(at);
        case Sprm.cFSpec:
          special = data.u8(at) != 0;
        case Sprm.cFRMarkDel:
          deleted = _toggle(data.u8(at), deleted, false);
        case Sprm.cFRMarkIns:
          inserted = _toggle(data.u8(at), inserted, false);
        case Sprm.cFData:
          formData = data.u8(at) != 0;
        case Sprm.cFOle2 || Sprm.cFObj:
          ole = data.u8(at) != 0;
        case Sprm.cPicLocation:
          pictureOffset = data.u32(at);
        case Sprm.cSymbol:
          symbolFont = data.u16(at);
          symbolCharacter = data.u16(at + 2);
        case Sprm.cPlain:
          _reset(style);
      }
    });
  }

  void _reset(CharProps style) {
    bold = style.bold;
    italic = style.italic;
    strike = style.strike;
    doubleStrike = style.doubleStrike;
    caps = style.caps;
    smallCaps = style.smallCaps;
    hidden = style.hidden;
    underline = style.underline;
    halfPoints = style.halfPoints;
    font = style.font;
    color = style.color;
    highlight = style.highlight;
    shading = style.shading;
    script = style.script;
  }

  static bool _toggle(int operand, bool current, bool style) =>
      switch (operand) {
        0 => false,
        1 => true,
        0x80 => style,
        0x81 => !style,
        _ => current,
      };
}

/// A tab stop in twips.
typedef DocTab = ({int position, int align, int leader});

/// Paragraph properties (PAP) from styles and sprms.
class ParaProps {
  int style = 0;
  int justification = 0;
  int left = 0;
  int right = 0;

  /// Negative is a hanging indent.
  int firstLine = 0;
  int before = 0;
  int after = 0;

  /// Twips, or 240ths of a line when [lineMultiple]; negative is exact.
  int line = 240;
  bool lineMultiple = true;
  bool keep = false;
  bool keepNext = false;
  bool pageBreakBefore = false;
  bool contextualSpacing = false;
  bool rightToLeft = false;
  List<DocTab> tabs = const [];
  int listOverride = 0;
  int listLevel = 0;
  bool inTable = false;
  bool rowEnd = false;
  bool innerCell = false;
  bool innerRowEnd = false;
  int tableDepth = 0;

  /// Offset in the Data stream of a grpprl too large for its page.
  int hugeGrpprl = -1;

  /// Properties of the table row a row end closes.
  RowProps? row;

  /// Table nesting level of the paragraph.
  int get depth => tableDepth > 0 ? tableDepth : (inTable ? 1 : 0);

  ParaProps copy() => ParaProps()
    ..style = style
    ..justification = justification
    ..left = left
    ..right = right
    ..firstLine = firstLine
    ..before = before
    ..after = after
    ..line = line
    ..lineMultiple = lineMultiple
    ..keep = keep
    ..keepNext = keepNext
    ..pageBreakBefore = pageBreakBefore
    ..contextualSpacing = contextualSpacing
    ..rightToLeft = rightToLeft
    ..tabs = tabs
    ..listOverride = listOverride
    ..listLevel = listLevel
    ..inTable = inTable
    ..rowEnd = rowEnd
    ..innerCell = innerCell
    ..innerRowEnd = innerRowEnd
    ..tableDepth = tableDepth;

  void apply(ByteView data, int start, int end) {
    forEachSprm(data, start, end, (sprm, at, size) {
      switch (sprm) {
        case Sprm.pJc80 || Sprm.pJc:
          justification = data.u8(at);
        case Sprm.pFKeep:
          keep = data.u8(at) != 0;
        case Sprm.pFKeepFollow:
          keepNext = data.u8(at) != 0;
        case Sprm.pFPageBreakBefore:
          pageBreakBefore = data.u8(at) != 0;
        case Sprm.pIlvl:
          listLevel = math.min(data.u8(at), 8);
        case Sprm.pIlfo:
          listOverride = data.i16(at);
        case Sprm.pChgTabsPapx:
          tabs = _changeTabs(data, at, at + size, closeRanges: false);
        case Sprm.pChgTabs:
          tabs = _changeTabs(data, at, at + size, closeRanges: true);
        case Sprm.pDxaRight80 || Sprm.pDxaRight:
          right = data.i16(at);
        case Sprm.pDxaLeft80 || Sprm.pDxaLeft:
          left = data.i16(at);
        case Sprm.pNest80 || Sprm.pNest:
          left = math.max(0, left + data.i16(at));
        case Sprm.pDxaLeft180 || Sprm.pDxaLeft1:
          firstLine = data.i16(at);
        case Sprm.pDyaLine:
          line = data.i16(at);
          lineMultiple = data.i16(at + 2) == 1;
        case Sprm.pDyaBefore:
          before = data.u16(at);
        case Sprm.pDyaAfter:
          after = data.u16(at);
        case Sprm.pFInTable:
          inTable = data.u8(at) != 0;
        case Sprm.pFTtp:
          rowEnd = data.u8(at) != 0;
        case Sprm.pItap:
          tableDepth = math.max(0, data.i32(at));
        case Sprm.pDtap:
          tableDepth = math.max(0, tableDepth + data.i32(at));
        case Sprm.pFInnerTableCell:
          innerCell = data.u8(at) != 0;
        case Sprm.pFInnerTtp:
          innerRowEnd = data.u8(at) != 0;
        case Sprm.pFBiDi:
          rightToLeft = data.u8(at) != 0;
        case Sprm.pFContextualSpacing:
          contextualSpacing = data.u8(at) != 0;
        case Sprm.pHugePapx:
          hugeGrpprl = data.u32(at);
        case _ when (sprm >> 10) & 7 == 5:
          (row ??= RowProps()).apply(sprm, data, at, size);
      }
    });
  }

  List<DocTab> _changeTabs(
    ByteView data,
    int start,
    int end, {
    required bool closeRanges,
  }) {
    final result = [...tabs];
    if (start >= end) return result;
    var at = start;
    final deleted = data.u8(at++);
    final close = at + deleted * 2;
    // Counts past the operand would read the next sprms.
    if (at + deleted * (closeRanges ? 4 : 2) > end) return result;
    for (var index = 0; index < deleted; index++) {
      final position = data.i16(at + index * 2);
      final range = closeRanges ? data.i16(close + index * 2).abs() : 0;
      result.removeWhere((tab) => (tab.position - position).abs() <= range);
    }
    at += deleted * (closeRanges ? 4 : 2);
    if (at >= end) return result;
    final added = data.u8(at++);
    if (at + added * 3 > end) return result;
    for (var index = 0; index < added; index++) {
      final position = data.i16(at + index * 2);
      final descriptor = data.u8(at + added * 2 + index);
      result
        ..removeWhere((tab) => tab.position == position)
        ..add((
          position: position,
          align: descriptor & 0x07,
          leader: (descriptor >> 3) & 0x07,
        ));
    }
    result.sort((a, b) => a.position.compareTo(b.position));
    return result.length > 64 ? result.sublist(0, 64) : result;
  }
}

/// A cell of a table row definition.
class CellProps {
  /// 1 starts a horizontal merge, 2 and 3 continue it.
  int horizontalMerge = 0;

  /// 3 starts a vertical merge, 1 continues it.
  int verticalMerge = 0;
  int verticalAlign = 0;
  String? fill;
}

/// Table row properties (TAP) held by the mark that ends a row.
class RowProps {
  /// Cell boundaries in twips; one more than the cells.
  List<int> boundaries = const [];
  final cells = <CellProps>[];
  bool header = false;

  /// Twips; negative is an exact height.
  int height = 0;
  int gapHalf = 0;

  /// Whether the row says anything about borders, and whether any shows.
  bool bordersKnown = false;
  bool bordered = false;

  static const maxCells = 63;

  CellProps cell(int index) {
    while (cells.length <= index) {
      cells.add(CellProps());
    }
    return cells[index];
  }

  void apply(int sprm, ByteView data, int at, int size) {
    switch (sprm) {
      case Sprm.tDefTable:
        _define(data, at, size);
      case Sprm.tTableHeader:
        header = data.u8(at) != 0;
      case Sprm.tDyaRowHeight:
        height = data.i16(at);
      case Sprm.tDxaGapHalf:
        gapHalf = data.i16(at);
      case Sprm.tDxaLeft when boundaries.isNotEmpty:
        final shift = data.i16(at) - (boundaries.first + gapHalf);
        boundaries = [for (final value in boundaries) value + shift];
      case Sprm.tTableBorders80 when size >= 24:
        bordersKnown = true;
        for (var side = 0; side < 6; side++) {
          if (_visible80(data.u32(at + side * 4))) bordered = true;
        }
      case Sprm.tTableBorders when size >= 48:
        bordersKnown = true;
        for (var side = 0; side < 6; side++) {
          final type = data.u8(at + side * 8 + 5);
          if (type != 0 && type != 0xFF) bordered = true;
        }
      case Sprm.tDefTableShd80:
        for (var index = 0; index < size ~/ 2; index++) {
          if (index >= maxCells) break;
          cell(index).fill = shading80(data.u16(at + index * 2));
        }
      case Sprm.tDefTableShd || Sprm.tDefTableShdRaw:
        _shading(data, at, size, 0);
      case Sprm.tDefTableShd2nd || Sprm.tDefTableShdRaw2nd:
        _shading(data, at, size, 22);
      case Sprm.tDefTableShd3rd || Sprm.tDefTableShdRaw3rd:
        _shading(data, at, size, 44);
      case Sprm.tVertMerge when size >= 2:
        final index = data.u8(at);
        if (index < maxCells) cell(index).verticalMerge = data.u8(at + 1);
    }
  }

  void _define(ByteView data, int at, int size) {
    if (size < 1) return;
    final count = math.min(data.u8(at), maxCells);
    if (1 + (count + 1) * 2 > size) return;
    boundaries = [
      for (var index = 0; index <= count; index++) data.i16(at + 1 + index * 2),
    ];
    cells.clear();
    final first = at + 1 + (count + 1) * 2;
    final described = math.min(count, (at + size - first) ~/ 20);
    for (var index = 0; index < count; index++) {
      final cell = this.cell(index);
      if (index >= described) continue;
      final tc = first + index * 20;
      final flags = data.u16(tc);
      cell
        ..horizontalMerge = flags & 0x03
        ..verticalMerge = (flags >> 5) & 0x03
        ..verticalAlign = (flags >> 7) & 0x03;
      bordersKnown = true;
      for (var side = 0; side < 4; side++) {
        if (_visible80(data.u32(tc + 4 + side * 4))) bordered = true;
      }
    }
  }

  void _shading(ByteView data, int at, int size, int first) {
    for (var index = 0; index < size ~/ 10; index++) {
      if (first + index >= maxCells) break;
      cell(first + index).fill = shadingAt(data, at + index * 10);
    }
  }

  static bool _visible80(int border) {
    if (border == 0xFFFFFFFF) return false;
    return (border >> 8) & 0xFF != 0;
  }
}

/// Section properties (SEP) in twips.
class SectionProps {
  /// 0 continuous, 1 new column, 2 new page, 3 even page, 4 odd page.
  int breakKind = 2;
  bool titlePage = false;
  int columns = 1;
  int columnSpacing = 720;
  int headerDistance = 720;
  int footerDistance = 720;
  int width = 12240;
  int height = 15840;
  int left = 1800;
  int right = 1800;
  int top = 1440;
  int bottom = 1440;

  void apply(ByteView data, int start, int end) {
    forEachSprm(data, start, end, (sprm, at, size) {
      switch (sprm) {
        case Sprm.sBkc:
          breakKind = data.u8(at);
        case Sprm.sFTitlePage:
          titlePage = data.u8(at) != 0;
        case Sprm.sCcolumns:
          columns = data.u16(at) + 1;
        case Sprm.sDxaColumns:
          columnSpacing = data.u16(at);
        case Sprm.sDyaHdrTop:
          headerDistance = data.u16(at);
        case Sprm.sDyaHdrBottom:
          footerDistance = data.u16(at);
        case Sprm.sXaPage:
          width = data.u16(at);
        case Sprm.sYaPage:
          height = data.u16(at);
        case Sprm.sDxaLeft:
          left = data.u16(at);
        case Sprm.sDxaRight:
          right = data.u16(at);
        // Negative top and bottom margins are kept even under a header.
        case Sprm.sDyaTop:
          top = data.i16(at).abs();
        case Sprm.sDyaBottom:
          bottom = data.i16(at).abs();
      }
    });
  }
}

const _icoColors = [
  null,
  '000000',
  '0000FF',
  '00FFFF',
  '00FF00',
  'FF00FF',
  'FF0000',
  'FFFF00',
  'FFFFFF',
  '000080',
  '008080',
  '008000',
  '800080',
  '800000',
  '808000',
  '808080',
  'C0C0C0',
];

/// A color of Word 97's 16-color palette; null for automatic.
String? icoColor(int ico) => ico < _icoColors.length ? _icoColors[ico] : null;

/// A COLORREF (red, green, blue, automatic flag); null for automatic.
String? colorRef(int value) {
  if (value >> 24 == 0xFF) return null;
  final red = value & 0xFF;
  final green = (value >> 8) & 0xFF;
  final blue = (value >> 16) & 0xFF;
  return [
    red,
    green,
    blue,
  ].map((part) => part.toRadixString(16).padLeft(2, '0')).join().toUpperCase();
}

/// The fill of an SHD80 (palette colors and a pattern).
String? shading80(int value) => _fill(
  icoColor(value & 0x1F),
  icoColor((value >> 5) & 0x1F),
  (value >> 10) & 0x3F,
);

/// The fill of an SHD (COLORREFs and a pattern) at [at].
String? shadingAt(ByteView data, int at) =>
    _fill(colorRef(data.u32(at)), colorRef(data.u32(at + 4)), data.u16(at + 8));

const _patternPercent = {
  2: 5,
  3: 10,
  4: 20,
  5: 25,
  6: 30,
  7: 40,
  8: 50,
  9: 60,
  10: 70,
  11: 75,
  12: 80,
  13: 90,
};

/// Clear shows the background, solid the foreground, and the percentages mix
/// them; other patterns show the background.
String? _fill(String? foreground, String? background, int pattern) {
  if (pattern == 0) return background;
  if (pattern == 1) return foreground ?? '000000';
  final percent = _patternPercent[pattern];
  if (percent == null) return background;
  final front = int.parse(foreground ?? '000000', radix: 16);
  final back = int.parse(background ?? 'FFFFFF', radix: 16);
  var mixed = 0;
  for (final shift in const [16, 8, 0]) {
    final a = (front >> shift) & 0xFF;
    final b = (back >> shift) & 0xFF;
    mixed |= ((a * percent + b * (100 - percent)) / 100).round() << shift;
  }
  return mixed.toRadixString(16).padLeft(6, '0').toUpperCase();
}
