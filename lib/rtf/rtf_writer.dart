import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/painting.dart' show Color, EdgeInsets;
import 'package:flutter_quill/quill_delta.dart';
import 'package:xml/xml.dart';

import '../document/delta_blocks.dart';
import '../document/document_look.dart';
import '../document/embeds.dart';
import '../document/headers_footers.dart';
import '../document/tables.dart';
import '../docx/docx_builder.dart';
import '../docx/docx_styles.dart';
import '../docx/image_formats.dart';
import 'rtf_pictures.dart';

/// Writes the editor's content as RTF that Word, LibreOffice and TextEdit
/// open. Every character above 127 goes out as `\uN`, so any text survives.
class RtfWriter {
  RtfWriter(this._tables);

  static const _maxTableDepth = 32;
  static const _hyperlinkColor = '0563C1';

  final TableStore _tables;
  final _fonts = <String>[];
  final _colors = <String>[];
  final _lists = <_ListKind>[];
  final _counters = <int, List<int>>{};
  final _numbered = <int, int>{};
  final _bookmarks = <String>{};
  int? _bulletList;
  int? _checkedList;
  int? _uncheckedList;
  int? _orderedList;
  var _look = const DocumentLook();
  var _sections = <_PageSetup>[];
  var _section = 0;
  var _differentFirstPage = false;
  var _headerDistance = 35.4;
  var _footerDistance = 35.4;

  Uint8List write(
    Delta delta, {
    DocumentLook look = const DocumentLook(),
    HeadersFooters? headersFooters,
  }) {
    _look = look;
    _font(look.body.fontFamily ?? 'Arial');
    _differentFirstPage = headersFooters?.differentFirstPage ?? false;
    _headerDistance = headersFooters?.headerDistance ?? 35.4;
    _footerDistance = headersFooters?.footerDistance ?? 35.4;

    final blocks = documentBlocks(delta);
    _sections = [
      for (final block in blocks)
        if (block is EmbedBlock && block.type == EmbedTypes.sectionBreak)
          _PageSetup.fromSection(sectionXmlOf(block.value), look),
      _PageSetup.fromLook(look),
    ];
    final defaults =
        '{\\*\\defchp ${_characterLook(look.body)}}'
        '{\\*\\defpap ${_paragraphLook(look.body, lineSpacing: look.lineSpacing)}}'
        '\r\n';
    final styles = _stylesheet();
    final stories = StringBuffer();
    if (headersFooters != null) _stories(stories, headersFooters);
    final body = StringBuffer();
    _blocks(body, blocks, 0, body: true);

    final out = StringBuffer(r'{\rtf1\ansi\ansicpg1252\deff0\uc1')
      ..write('\r\n{\\fonttbl');
    for (final (index, font) in _fonts.indexed) {
      out.write('{\\f$index\\fnil\\fcharset0 ');
      _escape(out, font.replaceAll(';', ''));
      out.write(';}');
    }
    out.write('}\r\n{\\colortbl;');
    for (final color in _colors) {
      final value = int.parse(color, radix: 16);
      out.write(
        '\\red${value >> 16 & 0xFF}\\green${value >> 8 & 0xFF}'
        '\\blue${value & 0xFF};',
      );
    }
    out
      ..write('}\r\n')
      ..write(defaults)
      ..write(styles);
    _listTables(out);
    final page = _sections.last;
    out
      ..write(
        '\\paperw${page.width}\\paperh${page.height}'
        '\\margl${page.left}\\margr${page.right}'
        '\\margt${page.top}\\margb${page.bottom}',
      )
      ..write(page.landscape ? r'\landscape' : '')
      ..write(headersFooters?.differentOddEven ?? false ? r'\facingp' : '')
      ..write('\\deftab720\\viewkind1\r\n')
      ..write(_sectionProperties(_sections.first))
      ..write('\r\n')
      ..write(stories)
      ..write(body)
      ..write('}\r\n');
    return Uint8List.fromList(latin1.encode(out.toString()));
  }

  // Header tables

  int _font(String name) {
    final index = _fonts.indexOf(name);
    if (index >= 0) return index;
    _fonts.add(name);
    return _fonts.length - 1;
  }

  /// Index in the color table; 0 is the automatic color.
  int _color(String hex) {
    final index = _colors.indexOf(hex);
    if (index >= 0) return index + 1;
    _colors.add(hex);
    return _colors.length;
  }

  String _stylesheet() {
    final out = StringBuffer('{\\stylesheet{');
    out
      ..write(_paragraphLook(_look.body, lineSpacing: _look.lineSpacing))
      ..write(' ')
      ..write(_characterLook(_look.body))
      ..write(' \\snext0 Normal;}');
    for (var level = 1; level <= 6; level++) {
      final heading = _look.heading(level);
      out
        ..write('{\\s$level')
        ..write(_paragraphLook(heading, lineSpacing: _look.lineSpacing))
        ..write('\\keepn\\outlinelevel${level - 1} ')
        ..write(_characterLook(heading))
        ..write(' \\sbasedon0\\snext0 heading $level;}');
    }
    out.write('}\r\n');
    return out.toString();
  }

  static String _paragraphLook(TextLook look, {required double lineSpacing}) =>
      '\\ql\\fi${_twips(look.firstLine)}\\ri${_twips(look.indentRight)}'
      '\\sb${_twips(look.spaceBefore)}\\sa${_twips(look.spaceAfter)}'
      '${_lineSpacing(lineSpacing)}';

  String _characterLook(TextLook look) {
    final out = StringBuffer(
      '\\f${_font(look.fontFamily ?? _fonts.first)}'
      '\\fs${(look.fontSize * 2).round().clamp(2, 3276)}',
    );
    if (look.bold) out.write(r'\b');
    if (look.italic) out.write(r'\i');
    final color = _hexOf(look.color);
    if (color != '000000') out.write('\\cf${_color(color)}');
    return out.toString();
  }

  static String _lineSpacing(double multiple) => (multiple - 1).abs() < 0.01
      ? ''
      : '\\sl${(multiple * 240).round().clamp(1, 31680)}\\slmult1';

  void _listTables(StringBuffer out) {
    if (_lists.isEmpty) return;
    out.write(r'{\*\listtable');
    for (final (index, kind) in _lists.indexed) {
      final id = index + 1;
      out.write('\r\n{\\list\\listtemplateid$id\\listhybrid');
      for (var level = 0; level < 9; level++) {
        final indent = 720 * (level + 1);
        final (format, text) = switch (kind) {
          _ListKind.ordered => (
            const [0, 4, 2][level % 3],
            "\\'02\\'0$level.;}{\\levelnumbers\\'01;}",
          ),
          _ => (23, '\\\'01${_unicode(kind.marker(level))};}{\\levelnumbers;}'),
        };
        out.write(
          '{\\listlevel\\levelnfc$format\\levelnfcn$format\\leveljc0'
          '\\leveljcn0\\levelfollow0\\levelstartat1\\levelspace0'
          '\\levelindent0{\\leveltext$text\\fi-360\\li$indent\\lin$indent }',
        );
      }
      out.write('{\\listname ;}\\listid$id}');
    }
    out.write('}\r\n{\\*\\listoverridetable');
    for (var index = 0; index < _lists.length; index++) {
      out.write(
        '{\\listoverride\\listid${index + 1}\\listoverridecount0'
        '\\ls${index + 1}}',
      );
    }
    out.write('}\r\n');
  }

  static String _unicode(String text) {
    final out = StringBuffer();
    _escape(out, text);
    return out.toString();
  }

  // Sections, headers and footers

  String _sectionProperties(_PageSetup page) {
    final out = StringBuffer(r'\sectd')
      ..write(page.landscape ? r'\lndscpsxn' : '')
      ..write(
        '\\pgwsxn${page.width}\\pghsxn${page.height}'
        '\\marglsxn${page.left}\\margrsxn${page.right}'
        '\\margtsxn${page.top}\\margbsxn${page.bottom}'
        '\\headery${page.header ?? _twips(_headerDistance)}'
        '\\footery${page.footer ?? _twips(_footerDistance)}',
      );
    if (page.columns > 1) {
      out.write('\\cols${page.columns}\\colsx${page.columnSpacing}');
    }
    out.write(switch (page.start) {
      'continuous' => r'\sbknone',
      'evenPage' => r'\sbkeven',
      'oddPage' => r'\sbkodd',
      'nextColumn' => r'\sbkcol',
      _ => '',
    });
    if (_differentFirstPage) out.write(r'\titlepg');
    return out.toString();
  }

  void _stories(StringBuffer out, HeadersFooters stories) {
    for (final (kind, all) in [
      ('header', stories.headers),
      ('footer', stories.footers),
    ]) {
      for (final MapEntry(key: variant, value: story) in all.entries) {
        final keyword = switch (variant) {
          PageVariant.normal => stories.differentOddEven ? '${kind}r' : kind,
          PageVariant.even => stories.differentOddEven ? '${kind}l' : null,
          PageVariant.first => stories.differentFirstPage ? '${kind}f' : null,
        };
        if (keyword == null) continue;
        out.write('{\\$keyword ');
        _blocks(out, documentBlocks(story.delta), 0);
        out.write('}\r\n');
      }
    }
  }

  // Blocks

  /// The last paragraph of a cell ends with [cellMark] instead of `\par`.
  void _blocks(
    StringBuffer out,
    List<DocumentBlock> blocks,
    int level, {
    String? cellMark,
    bool body = false,
  }) {
    final lines = [
      for (final block in blocks)
        if (block is EmbedBlock && block.type == EmbedTypes.opaqueBlock)
          ..._opaqueLines(block.value)
        else
          block,
    ];
    for (var index = 0; index < lines.length; index++) {
      final block = lines[index];
      final next = index + 1 < lines.length ? lines[index + 1] : null;
      final sectionNext =
          body && next is EmbedBlock && next.type == EmbedTypes.sectionBreak;
      switch (block) {
        case LineBlock():
          final last = index == lines.length - 1;
          final mark = sectionNext
              ? r'\sect'
              : (last && cellMark != null ? cellMark : r'\par');
          _paragraph(out, block, level, mark);
          if (sectionNext) {
            index++;
            _nextSection(out);
          }
        case EmbedBlock(type: EmbedTypes.table):
          final table = _tables[tableIdOf(block.value)];
          if (table != null) _table(out, table, level + 1);
        case EmbedBlock(type: EmbedTypes.sectionBreak):
          if (!body) continue;
          out.write(r'\pard\plain\sect');
          _nextSection(out);
        case EmbedBlock():
          continue;
      }
    }
    if (cellMark != null && (lines.isEmpty || lines.last is! LineBlock)) {
      _paragraph(out, const LineBlock([], {}), level, cellMark);
    }
  }

  void _nextSection(StringBuffer out) {
    _section = math.min(_section + 1, _sections.length - 1);
    out
      ..write(_sectionProperties(_sections[_section]))
      ..write('\r\n');
  }

  static List<LineBlock> _opaqueLines(Object? value) {
    final content = OpaqueContent.decode(value);
    if (content.hidden || content.text.isEmpty) return const [];
    return [
      for (final line in content.text.split('\n'))
        LineBlock([TextPiece(line, const {})], const {}),
    ];
  }

  void _paragraph(StringBuffer out, LineBlock line, int level, String mark) {
    final heading = line.heading;
    final base = heading == null ? _look.body : _look.heading(heading);
    final preserved = _Preserved.of(line.attributes);
    out.write(r'\pard\plain');
    if (heading != null) out.write('\\s$heading\\outlinelevel${heading - 1}');
    // TextEdit keeps the last nesting level unless \itap says it.
    if (level > 0) out.write('\\intbl\\itap$level');
    out.write(switch (line.align) {
      'center' => r'\qc',
      'right' => r'\qr',
      'justify' => r'\qj',
      _ => r'\ql',
    });
    final list = line.list;
    if (list == null) _orderedList = null;
    final listNumber = list == null ? null : _listNumber(line);
    final listLevel = line.indent.clamp(0, 8);
    if (listNumber != null) {
      final indent = 720 * (listLevel + 1);
      out.write('\\ls$listNumber\\ilvl$listLevel\\li$indent\\fi-360');
    } else {
      // The editor rounds the indent to 36-point steps; the .docx keeps it.
      final left = preserved?.left;
      final exact = left != null && (left / 720).round() == line.indent;
      out
        ..write('\\li${exact ? left : line.indent * 720}')
        ..write('\\fi${_twips(line.firstLine ?? base.firstLine)}');
    }
    out
      ..write('\\ri${_twips(line.indentRight ?? base.indentRight)}')
      ..write('\\sb${_twips(line.spaceBefore ?? base.spaceBefore)}')
      ..write('\\sa${_twips(line.spaceAfter ?? base.spaceAfter)}');
    final exact = preserved?.exactLine;
    if (line.lineHeight == null && exact != null) {
      out.write('\\sl$exact\\slmult0');
    } else {
      out.write(_lineSpacing(line.lineHeight ?? _look.lineSpacing));
    }
    if (preserved != null) {
      if (preserved.keepNext) out.write(r'\keepn');
      if (preserved.keepLines) out.write(r'\keep');
      if (preserved.pageBreakBefore) out.write(r'\pagebb');
      if (preserved.rightToLeft) out.write(r'\rtlpar');
      out.write(preserved.tabs);
    }
    out
      ..write(_characterLook(base))
      ..write(' ');
    if (listNumber != null) {
      out.write('{\\listtext\\f0 ');
      _escape(out, _listText(listNumber, list!, listLevel));
      out.write(r'\tab}');
    }
    final bookmarks = line.attributes[HiddenAttributes.bookmarks];
    if (bookmarks is String) {
      for (final name in _decodeNames(bookmarks)) {
        final clean = bookmarkName(name);
        if (!_bookmarks.add(clean)) continue;
        out.write(r'{\*\bkmkstart ');
        _escape(out, clean);
        out.write(r'}{\*\bkmkend ');
        _escape(out, clean);
        out.write('}');
      }
    }
    _pieces(out, line.pieces);
    out.write('$mark\r\n');
  }

  static List<String> _decodeNames(String json) {
    try {
      final names = jsonDecode(json);
      return names is List ? names.whereType<String>().toList() : const [];
    } on FormatException {
      return const [];
    }
  }

  // Lists

  /// The `\ls` of the paragraph's list: one for all bullets, one per
  /// numbered list, so each numbered list starts at 1.
  int _listNumber(LineBlock line) {
    switch (line.list) {
      case 'ordered':
        final original = line.attributes[HiddenAttributes.numbering];
        if (original is num) {
          return _numbered[original.toInt()] ??= _addList(_ListKind.ordered);
        }
        return _orderedList ??= _addList(_ListKind.ordered);
      case 'checked':
        _orderedList = null;
        return _checkedList ??= _addList(_ListKind.checked);
      case 'unchecked':
        _orderedList = null;
        return _uncheckedList ??= _addList(_ListKind.unchecked);
      default:
        _orderedList = null;
        return _bulletList ??= _addList(_ListKind.bullet);
    }
  }

  int _addList(_ListKind kind) {
    _lists.add(kind);
    return _lists.length;
  }

  /// What readers without lists show: the number or bullet.
  String _listText(int number, String list, int level) {
    if (list != 'ordered') return _lists[number - 1].marker(level);
    final counters = _counters.putIfAbsent(number, () => List.filled(9, 0));
    counters[level]++;
    counters.fillRange(level + 1, 9, 0);
    final value = counters[level];
    return '${switch (level % 3) {
      1 => _letters(value),
      2 => _roman(value),
      _ => '$value',
    }}.';
  }

  static String _letters(int value) {
    final out = StringBuffer();
    var rest = value;
    while (rest > 0) {
      rest--;
      out.writeCharCode(0x61 + rest % 26);
      rest ~/= 26;
    }
    return out.toString().split('').reversed.join();
  }

  static String _roman(int value) {
    if (value <= 0 || value >= 4000) return '$value';
    const numerals = [
      (1000, 'm'),
      (900, 'cm'),
      (500, 'd'),
      (400, 'cd'),
      (100, 'c'),
      (90, 'xc'),
      (50, 'l'),
      (40, 'xl'),
      (10, 'x'),
      (9, 'ix'),
      (5, 'v'),
      (4, 'iv'),
      (1, 'i'),
    ];
    final out = StringBuffer();
    var rest = value;
    for (final (amount, numeral) in numerals) {
      while (rest >= amount) {
        out.write(numeral);
        rest -= amount;
      }
    }
    return out.toString();
  }

  // Inline content

  void _pieces(StringBuffer out, List<InlinePiece> pieces) {
    var index = 0;
    while (index < pieces.length) {
      final link = _linkTarget(pieces[index].link);
      if (link == null) {
        _piece(out, pieces[index], link: false);
        index++;
        continue;
      }
      var end = index;
      while (end < pieces.length && _linkTarget(pieces[end].link) == link) {
        end++;
      }
      out.write(r'{\field{\*\fldinst{HYPERLINK ');
      if (link.startsWith('#')) {
        out.write(r'\\l ');
        _quoted(out, link.substring(1));
      } else {
        _quoted(out, link);
      }
      out.write(r'}}{\fldrslt{');
      for (final piece in pieces.sublist(index, end)) {
        _piece(out, piece, link: true);
      }
      out.write('}}}');
      index = end;
    }
  }

  /// Web, e-mail and FTP addresses and bookmarks; the rest stays text.
  static String? _linkTarget(String? link) {
    if (link == null) return null;
    final trimmed = link.trim();
    if (trimmed.startsWith('#')) {
      return trimmed.length > 1
          ? '#${bookmarkName(trimmed.substring(1))}'
          : null;
    }
    return safeLinkTarget(trimmed);
  }

  /// A quoted field argument: `"` and `\` get a backslash.
  static void _quoted(StringBuffer out, String text) {
    out.write('"');
    _escape(out, text.replaceAll(r'\', r'\\').replaceAll('"', r'\"'));
    out.write('"');
  }

  void _piece(StringBuffer out, InlinePiece piece, {required bool link}) {
    final attributes = piece.attributes;
    final format = _runFormat(attributes, link: link);
    switch (piece) {
      case TextPiece(:final text):
        if (text.isEmpty) return;
        if (format.isEmpty) {
          _escape(out, text);
        } else {
          _run(out, format, text);
        }
      case EmbedPiece(type: EmbedTypes.image):
        _picture(out, piece);
      case EmbedPiece(type: EmbedTypes.pageBreak):
        out.write(r'\page ');
      case EmbedPiece(type: EmbedTypes.pageNumber):
        _field(out, 'PAGE', '1', format);
      case EmbedPiece(type: EmbedTypes.opaqueInline):
        final content = OpaqueContent.decode(piece.value);
        if (content.hidden) return;
        final field = _fieldOf(content.xml);
        if (field != null) {
          _field(out, field, content.text, format);
        } else if (content.text.isNotEmpty) {
          final note = content.label == OpaqueLabels.note ? r'\super' : '';
          _run(out, '$format$note', content.text);
        }
      case EmbedPiece():
        return;
    }
  }

  /// Text in a group with its character formatting.
  static void _run(StringBuffer out, String format, String text) {
    out.write(format.isEmpty ? '{' : '{$format ');
    _escape(out, text);
    out.write('}');
  }

  static void _field(
    StringBuffer out,
    String instruction,
    String result,
    String format,
  ) {
    out.write(r'{\field{\*\fldinst{ ');
    _escape(out, instruction);
    out.write(r' }}{\fldrslt');
    _run(out, format, result);
    out.write('}}');
  }

  /// The instruction of a Word field that shows the document's own data.
  static String? _fieldOf(String xml) {
    if (!xml.contains('instr')) return null;
    try {
      final root = XmlDocument.parse('<r>$xml</r>').rootElement;
      final parts = <String>[];
      for (final element in root.descendantElements) {
        if (element.name.local == 'fldSimple') {
          final instruction = element.getAttribute('w:instr');
          if (instruction != null) parts.add(instruction);
        } else if (element.name.local == 'instrText') {
          parts.add(element.innerText);
        }
      }
      final instruction = parts.join().trim();
      return isSafeField(instruction) ? instruction : null;
    } on XmlException {
      return null;
    }
  }

  /// Character formatting from the editor's attributes; [link] text is
  /// underlined in the link color unless it says otherwise.
  String _runFormat(Map<String, dynamic> attributes, {required bool link}) {
    final out = StringBuffer();
    void toggle(String key, String on, String off) {
      final value = attributes[key];
      if (value == true) out.write(on);
      if (value == false) out.write(off);
    }

    toggle('bold', r'\b', r'\b0');
    toggle('italic', r'\i', r'\i0');
    toggle('strike', r'\strike', r'\strike0');
    final underline = attributes['underline'];
    if (underline == true || (underline == null && link)) out.write(r'\ul');
    if (underline == false) out.write(r'\ulnone');
    final preserved = attributes[HiddenAttributes.runProperties];
    if (preserved is String) {
      if (preserved.contains('<w:caps/>')) out.write(r'\caps');
      if (preserved.contains('<w:smallCaps/>')) out.write(r'\scaps');
    }
    if (_points(attributes['size']) case final size? when size > 0) {
      out.write('\\fs${(size * 2).round().clamp(2, 3276)}');
    }
    if (attributes['font'] case final String font when font.trim().isNotEmpty) {
      out.write('\\f${_font(font.trim())}');
    }
    final color =
        hexColor(attributes['color']) ?? (link ? _hyperlinkColor : null);
    if (color != null) out.write('\\cf${_color(color)}');
    if (hexColor(attributes['background']) case final background?) {
      final index = _color(background);
      out.write('\\chcbpat$index\\cb$index');
      if (highlightColors.containsValue(background)) {
        out.write('\\highlight$index');
      }
    }
    switch (attributes['script']) {
      case 'super':
        out.write(r'\super');
      case 'sub':
        out.write(r'\sub');
    }
    return out.toString();
  }

  static double? _points(Object? value) => switch (value) {
    'small' => 9,
    'large' => 18,
    'huge' => 28,
    _ => pointsValue(value),
  };

  // Pictures

  void _picture(StringBuffer out, EmbedPiece piece) {
    final decoded = decodeDataUri(piece.value as String? ?? '');
    if (decoded == null) return;
    final bytes = decoded.bytes;
    final (keyword, data, metafile) = switch (decoded.mime) {
      'image/png' when isPng(bytes) => (r'\pngblip', bytes, false),
      'image/jpeg' when isJpeg(bytes) => (r'\jpegblip', bytes, false),
      'image/bmp' => (r'\dibitmap0', dibFromBitmap(bytes), false),
      'image/x-emf' when isEmf(bytes) => (r'\emfblip', bytes, true),
      'image/x-wmf' => (r'\wmetafile8', rawWmf(bytes), true),
      _ => (null, null, false),
    };
    if (keyword == null || data == null || data.isEmpty) return;
    final pixels = metafile ? null : imagePixelSize(bytes);
    final width =
        pointsValue(piece.attributes['width']) ??
        (pixels == null ? 72 : pixels.width * 0.75);
    final height =
        pointsValue(piece.attributes['height']) ??
        (pixels == null ? 72 : pixels.height * 0.75);
    if (!width.isFinite || !height.isFinite || width <= 0 || height <= 0) {
      return;
    }
    final ownWidth = metafile
        ? (width * 2540 / 72).round()
        : pixels?.width ?? (width / 0.75).round();
    final ownHeight = metafile
        ? (height * 2540 / 72).round()
        : pixels?.height ?? (height / 0.75).round();
    out.write(
      '{\\pict$keyword\\picw$ownWidth\\pich$ownHeight'
      '\\picwgoal${_twips(width)}\\pichgoal${_twips(height)}\r\n',
    );
    for (var index = 0; index < data.length; index++) {
      out.write(_hexBytes[data[index]]);
      if (index % 64 == 63) out.write('\r\n');
    }
    out.write('}');
  }

  static final _hexBytes = [
    for (var byte = 0; byte < 256; byte++)
      byte.toRadixString(16).padLeft(2, '0'),
  ];

  // Tables

  void _table(StringBuffer out, TableModel table, int level) {
    if (level > _maxTableDepth) {
      for (final row in table.rows) {
        for (final cell in row.cells) {
          _blocks(
            out,
            documentBlocks(cell.controller.document.toDelta()),
            level - 1,
          );
        }
      }
      return;
    }
    final columns = table.rows.fold(
      0,
      (count, row) => math.max(
        count,
        row.cells.fold(0, (sum, cell) => sum + math.max(cell.gridSpan, 1)),
      ),
    );
    if (columns == 0) return;
    var widths = table.columnWidths;
    if (widths.length != columns ||
        widths.any((width) => !width.isFinite || width <= 0)) {
      final total = _twips(_look.contentWidth).toDouble();
      widths = List.filled(columns, total / columns);
    }
    final cellMark = level == 1 ? r'\cell' : r'\nestcell';
    for (final row in table.rows) {
      final definition = StringBuffer(r'\trowd\trgaph108\trleft0');
      final flags = _RowFlags.of(row.propertiesXml);
      if (flags.header) definition.write(r'\trhdr');
      if (flags.height case final height?) definition.write('\\trrh$height');
      var column = 0;
      var right = 0.0;
      for (final cell in row.cells) {
        final span = math.max(cell.gridSpan, 1);
        for (
          var index = column;
          index < math.min(column + span, columns);
          index++
        ) {
          right += widths[index];
        }
        column += span;
        definition.write(switch (cell.verticalMerge) {
          VerticalMerge.restart => r'\clvmgf',
          VerticalMerge.continuation => r'\clvmrg',
          VerticalMerge.none => '',
        });
        if (cell.fill case final fill?) {
          definition.write('\\clcbpat${_color(_hexOf(fill))}');
        }
        if (table.bordered) {
          definition.write(
            r'\clbrdrt\brdrs\brdrw10\clbrdrl\brdrs\brdrw10'
            r'\clbrdrb\brdrs\brdrw10\clbrdrr\brdrs\brdrw10',
          );
        }
        definition.write('\\cellx${right.round()}');
      }
      if (level == 1) out.write('$definition\r\n');
      for (final cell in row.cells) {
        _blocks(
          out,
          documentBlocks(cell.controller.document.toDelta()),
          level,
          cellMark: cellMark,
        );
      }
      // No \nonesttables fallback: TextEdit reads its paragraph as text.
      out.write(
        level == 1
            ? '\\row\r\n'
            : '{\\*\\nesttableprops$definition\\nestrow}\r\n',
      );
    }
  }

  // Text

  static void _escape(StringBuffer out, String text) {
    for (final unit in text.codeUnits) {
      switch (unit) {
        case 0x5C:
          out.write(r'\\');
        case 0x7B:
          out.write(r'\{');
        case 0x7D:
          out.write(r'\}');
        case 0x09:
          out.write(r'\tab ');
        case 0x0A || 0x0B || 0x2028:
          out.write(r'\line ');
        case 0x0C:
          out.write(r'\page ');
        case 0xA0:
          out.write(r'\~');
        case 0xAD:
          out.write(r'\-');
        case 0x2011:
          out.write(r'\_');
        default:
          if (unit < 0x20) continue;
          if (unit < 0x80) {
            out.writeCharCode(unit);
          } else {
            out.write('\\u${unit > 0x7FFF ? unit - 0x10000 : unit}?');
          }
      }
    }
  }

  static int _twips(double points) =>
      points.isFinite ? (points * 20).round().clamp(-31680, 31680) : 0;

  static String _hexOf(Color color) => (color.toARGB32() & 0xFFFFFF)
      .toRadixString(16)
      .padLeft(6, '0')
      .toUpperCase();
}

enum _ListKind {
  bullet,
  ordered,
  checked,
  unchecked;

  String marker(int level) => switch (this) {
    checked => '\u2611',
    unchecked => '\u2610',
    _ => const ['\u2022', '\u25E6', '\u25AA'][level % 3],
  };
}

/// Page size, margins and start of a section, in twips.
class _PageSetup {
  _PageSetup({
    required this.width,
    required this.height,
    required this.left,
    required this.right,
    required this.top,
    required this.bottom,
    this.header,
    this.footer,
    this.columns = 1,
    this.columnSpacing = 720,
    this.start,
  });

  factory _PageSetup.fromLook(DocumentLook look) =>
      _PageSetup.fromPoints(look.pageWidth, look.pageHeight, look.margins);

  factory _PageSetup.fromPoints(
    double width,
    double height,
    EdgeInsets margins,
  ) => _PageSetup(
    width: RtfWriter._twips(width),
    height: RtfWriter._twips(height),
    left: RtfWriter._twips(margins.left),
    right: RtfWriter._twips(margins.right),
    top: RtfWriter._twips(margins.top),
    bottom: RtfWriter._twips(margins.bottom),
  );

  /// From a .docx section (`w:sectPr`); what it lacks comes from [look].
  factory _PageSetup.fromSection(String xml, DocumentLook look) {
    final fallback = _PageSetup.fromLook(look);
    final XmlElement root;
    try {
      root = XmlDocument.parse(xml).rootElement;
    } on XmlException {
      return fallback;
    }
    XmlElement? child(String local) {
      for (final element in root.childElements) {
        if (element.name.local == local) return element;
      }
      return null;
    }

    int? number(XmlElement? element, String name) =>
        int.tryParse(element?.getAttribute('w:$name') ?? '');

    final size = child('pgSz');
    final margins = child('pgMar');
    final columns = child('cols');
    return _PageSetup(
      width: number(size, 'w') ?? fallback.width,
      height: number(size, 'h') ?? fallback.height,
      left: number(margins, 'left') ?? fallback.left,
      right: number(margins, 'right') ?? fallback.right,
      top: number(margins, 'top') ?? fallback.top,
      bottom: number(margins, 'bottom') ?? fallback.bottom,
      header: number(margins, 'header'),
      footer: number(margins, 'footer'),
      columns: (number(columns, 'num') ?? 1).clamp(1, 45),
      columnSpacing: number(columns, 'space') ?? 720,
      start: child('type')?.getAttribute('w:val'),
    );
  }

  final int width;
  final int height;
  final int left;
  final int right;
  final int top;
  final int bottom;
  final int? header;
  final int? footer;
  final int columns;
  final int columnSpacing;

  /// How the section starts (`w:type`): nextPage, continuous...
  final String? start;

  bool get landscape => width > height;
}

/// Paragraph properties of a .docx paragraph that the editor keeps hidden
/// and RTF can say.
class _Preserved {
  _Preserved._();

  static _Preserved? of(Map<String, dynamic> attributes) {
    final raw = attributes[HiddenAttributes.paragraphProperties];
    if (raw is! String) return null;
    final XmlElement root;
    try {
      root = XmlDocument.parse(raw).rootElement;
    } on XmlException {
      return null;
    }
    bool on(XmlElement element) =>
        !const {'0', 'false', 'off'}.contains(element.getAttribute('w:val'));
    final preserved = _Preserved._();
    for (final element in root.childElements) {
      switch (element.name.local) {
        case 'ind':
          preserved.left = int.tryParse(
            element.getAttribute('w:left') ??
                element.getAttribute('w:start') ??
                '',
          );
        case 'spacing':
          final line = int.tryParse(element.getAttribute('w:line') ?? '');
          final rule = element.getAttribute('w:lineRule');
          if (line != null && line > 0 && rule == 'exact') {
            preserved.exactLine = -line;
          } else if (line != null && line > 0 && rule == 'atLeast') {
            preserved.exactLine = line;
          }
        case 'keepNext':
          preserved.keepNext = on(element);
        case 'keepLines':
          preserved.keepLines = on(element);
        case 'pageBreakBefore':
          preserved.pageBreakBefore = on(element);
        case 'bidi':
          preserved.rightToLeft = on(element);
        case 'tabs':
          for (final tab in element.childElements.take(64)) {
            final position = int.tryParse(tab.getAttribute('w:pos') ?? '');
            final kind = tab.getAttribute('w:val');
            if (position == null || kind == 'clear' || kind == 'bar') continue;
            preserved.tabs.write(switch (kind) {
              'center' => r'\tqc',
              'right' || 'end' => r'\tqr',
              'decimal' => r'\tqdec',
              _ => '',
            });
            preserved.tabs.write(switch (tab.getAttribute('w:leader')) {
              'dot' || 'middleDot' => r'\tldot',
              'hyphen' => r'\tlhyph',
              'underscore' || 'heavy' => r'\tlul',
              _ => '',
            });
            preserved.tabs.write('\\tx$position');
          }
      }
    }
    return preserved;
  }

  int? left;

  /// `\sl`: negative is exact, positive at least.
  int? exactLine;
  var keepNext = false;
  var keepLines = false;
  var pageBreakBefore = false;
  var rightToLeft = false;
  final tabs = StringBuffer();
}

/// Row properties of a .docx row the editor keeps.
class _RowFlags {
  const _RowFlags({this.header = false, this.height});

  factory _RowFlags.of(String? xml) {
    if (xml == null) return const _RowFlags();
    final height = RegExp(
      r'<w:trHeight\b[^>]*?w:val="(\d+)"[^>]*>',
    ).firstMatch(xml);
    final exact = height != null && height[0]!.contains('w:hRule="exact"');
    final value = height == null ? null : int.tryParse(height[1]!);
    return _RowFlags(
      header: RegExp(r'<w:tblHeader\s*/>').hasMatch(xml),
      height: value == null || value == 0 ? null : (exact ? -value : value),
    );
  }

  final bool header;

  /// `\trrh`: negative is exact, positive at least.
  final int? height;
}
