import 'byte_view.dart';

/// Property modifiers (MS-DOC 2.6) this reader understands.
abstract final class Sprm {
  // Character
  static const cFRMarkDel = 0x0800;
  static const cFRMarkIns = 0x0801;
  static const cPicLocation = 0x6A03;
  static const cFData = 0x0806;
  static const cSymbol = 0x6A09;
  static const cFOle2 = 0x080A;
  static const cHighlight = 0x2A0C;
  static const cIstd = 0x4A30;
  static const cPlain = 0x2A33;
  static const cFBold = 0x0835;
  static const cFItalic = 0x0836;
  static const cFStrike = 0x0837;
  static const cFSmallCaps = 0x083A;
  static const cFCaps = 0x083B;
  static const cFVanish = 0x083C;
  static const cKul = 0x2A3E;
  static const cIco = 0x2A42;
  static const cHps = 0x4A43;
  static const cIss = 0x2A48;
  static const cRgFtc0 = 0x4A4F;
  static const cFDStrike = 0x2A53;
  static const cFSpec = 0x0855;
  static const cFObj = 0x0856;
  static const cShd80 = 0x4866;
  static const cRgLid0Old = 0x486D;
  static const cCv = 0x6870;
  static const cShd = 0xCA71;
  static const cRgLid0 = 0x4873;

  // Paragraph
  static const pJc80 = 0x2403;
  static const pFKeep = 0x2405;
  static const pFKeepFollow = 0x2406;
  static const pFPageBreakBefore = 0x2407;
  static const pIlvl = 0x260A;
  static const pIlfo = 0x460B;
  static const pChgTabsPapx = 0xC60D;
  static const pDxaRight80 = 0x840E;
  static const pDxaLeft80 = 0x840F;
  static const pNest80 = 0x4610;
  static const pDxaLeft180 = 0x8411;
  static const pDyaLine = 0x6412;
  static const pDyaBefore = 0xA413;
  static const pDyaAfter = 0xA414;
  static const pChgTabs = 0xC615;
  static const pFInTable = 0x2416;
  static const pFTtp = 0x2417;
  static const pFBiDi = 0x2441;
  static const pHugePapx = 0x6646;
  static const pItap = 0x6649;
  static const pDtap = 0x664A;
  static const pFInnerTableCell = 0x244B;
  static const pFInnerTtp = 0x244C;
  static const pDxaRight = 0x845D;
  static const pDxaLeft = 0x845E;
  static const pNest = 0x465F;
  static const pDxaLeft1 = 0x8460;
  static const pJc = 0x2461;
  static const pFContextualSpacing = 0x246D;

  // Table
  static const tJc90 = 0x5400;
  static const tJc = 0x548A;
  static const tDxaLeft = 0x9601;
  static const tDxaGapHalf = 0x9602;
  static const tTableHeader = 0x3404;
  static const tTableBorders80 = 0xD605;
  static const tDyaRowHeight = 0x9407;
  static const tDefTable = 0xD608;
  static const tDefTableShd80 = 0xD609;
  static const tDefTableShd3rd = 0xD60C;
  static const tDefTableShd = 0xD612;
  static const tTableBorders = 0xD613;
  static const tDefTableShd2nd = 0xD616;
  static const tVertMerge = 0xD62B;
  static const tDefTableShdRaw = 0xD670;
  static const tDefTableShdRaw2nd = 0xD671;
  static const tDefTableShdRaw3rd = 0xD672;

  // Section
  static const sBkc = 0x3009;
  static const sFTitlePage = 0x300A;
  static const sCcolumns = 0x500B;
  static const sDxaColumns = 0x900C;
  static const sNfcPgn = 0x300E;
  static const sFPgnRestart = 0x3011;
  static const sDyaHdrTop = 0xB017;
  static const sDyaHdrBottom = 0xB018;
  static const sPgnStart97 = 0x501C;
  static const sXaPage = 0xB01F;
  static const sYaPage = 0xB020;
  static const sDxaLeft = 0xB021;
  static const sDxaRight = 0xB022;
  static const sDyaTop = 0x9023;
  static const sDyaBottom = 0x9024;
  static const sPgnStart = 0x7044;
}

/// Calls [visit] with each sprm of the grpprl in [data] between [start] and
/// [end], and the offset and size of its operand. A truncated sprm ends the
/// walk.
void forEachSprm(
  ByteView data,
  int start,
  int end,
  void Function(int sprm, int operand, int size) visit,
) {
  var at = start;
  while (at + 2 <= end) {
    final sprm = data.u16(at);
    var operand = at + 2;
    int size;
    switch (sprm >> 13) {
      case 0 || 1:
        size = 1;
      case 2 || 4 || 5:
        size = 2;
      case 3:
        size = 4;
      case 7:
        size = 3;
      default:
        if (operand >= end) return;
        if (sprm == Sprm.tDefTable) {
          if (operand + 2 > end) return;
          size = data.u16(operand) - 1;
          operand += 2;
        } else if (sprm == Sprm.pChgTabs && data.u8(operand) == 255) {
          size = _changeTabsSize(data, operand + 1, end);
          operand += 1;
        } else {
          size = data.u8(operand);
          operand += 1;
        }
    }
    if (size < 0 || operand + size > end) return;
    visit(sprm, operand, size);
    at = operand + size;
  }
}

/// sprmPChgTabs with a size of 255 counts its own tabs (MS-DOC 2.6.2).
int _changeTabsSize(ByteView data, int at, int end) {
  if (at >= end) return -1;
  final deleted = data.u8(at);
  final added = at + 1 + deleted * 4;
  if (added >= end) return -1;
  return 1 + deleted * 4 + 1 + data.u8(added) * 3;
}
