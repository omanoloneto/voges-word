import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/painting.dart' show Color, EdgeInsets;
import 'package:flutter_quill/quill_delta.dart';
import 'package:image/image.dart' as img;
import 'package:xml/xml.dart';
import 'package:xml/xml_events.dart'
    show XmlEndElementEvent, XmlStartElementEvent, parseEvents;

import '../document/delta_blocks.dart';
import '../document/document_look.dart';
import '../document/embeds.dart';
import '../document/headers_footers.dart';
import '../document/tables.dart';
import '../docx/docx_builder.dart';
import '../docx/docx_codec.dart';
import '../docx/docx_numbering.dart';
import '../docx/docx_package.dart';
import '../docx/docx_styles.dart';
import '../docx/image_formats.dart';
import '../docx/word_list_counter.dart';
import 'rtf_pictures.dart';

/// Writes the editor's content as RTF that Word, LibreOffice and TextEdit
/// open. Every character above 127 goes out as `\uN`, so any text survives.
class RtfWriter {
  RtfWriter(this._tables);

  static const _maxTableDepth = 32;
  static const _hyperlinkColor = '0563C1';

  /// The style of list items; the styles of paragraph groups come after it.
  static const _listStyle = 7;

  /// Larger pictures are left out instead of converted: decoding them takes
  /// too long and too much memory.
  static const _maxPixels = 40000000;

  /// Checklist boxes are bullets in this font, as the other readers build
  /// task items.
  static const _checkboxFont = 'Segoe UI Symbol';
  static const _bullets = ['•', '◦', '▪'];

  /// Longer font names of Word list levels are left out.
  static const _maxFontName = 100;

  /// RTF's `\levelnfc` of Word's number formats; the others count 1, 2, 3.
  static const _numberFormats = {
    'decimal': 0,
    'upperRoman': 1,
    'lowerRoman': 2,
    'upperLetter': 3,
    'lowerLetter': 4,
    'ordinal': 5,
    'cardinalText': 6,
    'ordinalText': 7,
    'decimalZero': 22,
  };

  final TableStore _tables;
  final _fonts = <String>[];
  final _fontIndexes = <String, int>{};
  final _colors = <String>[];

  /// The levels of each list of the list table; its `\listid` is its place
  /// from 1.
  final _lists = <List<_Level>>[];

  /// The list overrides; the `\ls` of each is its place from 1.
  final _overrides = <_Override>[];
  final _counters = <int, List<int?>>{};

  /// The `\ls` of the Word lists of the opened package, by what numbers
  /// them as one list.
  final _wordLists = <Object, int>{};

  /// The list of each abstract Word list: RTF readers count its `\ls`
  /// together, as Word counts its lists.
  final _abstractLists = <Object, int>{};
  var _numbering = DocxNumbering.parse(null);
  var _counter = WordListCounter(DocxNumbering.parse(null));
  final _bookmarks = <String>{};
  final _groupStyles = <String, int>{};
  final _notes = <String, Map<String, Delta>>{};
  final _relationships = <String, List<Relationship>>{};
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
  DocxPackage? _package;

  /// The package part of what is being written, which the pictures of its
  /// protected content are related to.
  String? _part;

  /// Notes are written in the body and its tables only.
  var _inBody = false;
  var _endnotes = false;

  /// The reference mark that starts the first paragraph of a note.
  String? _noteMark;

  /// [source] is the opened package, where the text of notes and the
  /// pictures of objects are.
  Uint8List write(
    Delta delta, {
    DocumentLook look = const DocumentLook(),
    HeadersFooters? headersFooters,
    Object? source,
  }) {
    _look = look;
    _package = source is DocxPackage ? source : null;
    _numbering = DocxNumbering.of(source);
    _font(look.body.fontFamily ?? 'Arial');
    _differentFirstPage = headersFooters?.differentFirstPage ?? false;
    _headerDistance = headersFooters?.headerDistance ?? 35.4;
    _footerDistance = headersFooters?.footerDistance ?? 35.4;

    final blocks = documentBlocks(delta);
    _sections = [
      for (final block in blocks)
        if (block is EmbedBlock && block.type == EmbedTypes.sectionBreak)
          _PageSetup.fromSection(sectionXmlOf(block.value), look),
      _PageSetup.fromLook(
        look,
        titlePage: _differentFirstPage,
        numbers: _lastPageNumbers(),
      ),
    ];
    final defaults =
        '{\\*\\defchp ${_characterLook(look.body)}}'
        '{\\*\\defpap ${_paragraphLook(look.body, lineSpacing: look.lineSpacing)}}'
        '\r\n';
    final stories = StringBuffer();
    if (headersFooters != null) _stories(stories, headersFooters);
    final body = StringBuffer();
    _counter = WordListCounter(_numbering);
    _part = _package?.mainDocumentPath;
    _inBody = true;
    _orderedList = null;
    _blocks(body, blocks, 0, body: true);
    _inBody = false;
    // The text decides which list and paragraph group styles there are.
    final styles = _stylesheet();

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
      // With both kinds, \ftnalt marks the endnotes; Word puts them at the end.
      ..write(_endnotes ? r'\fet2\aenddoc' : '')
      ..write('\\deftab720\\viewkind1\r\n')
      ..write(_sectionProperties(_sections.first))
      ..write('\r\n')
      ..write(stories)
      ..write(body)
      ..write('}\r\n');
    return Uint8List.fromList(latin1.encode(out.toString()));
  }

  // Header tables

  int _font(String name) => _fontIndexes[name] ??= () {
    _fonts.add(name);
    return _fonts.length - 1;
  }();

  /// Index in the color table; 0 is the automatic color.
  int _color(String hex) {
    final index = _colors.indexOf(hex);
    if (index >= 0) return index + 1;
    _colors.add(hex);
    return _colors.length;
  }

  String _stylesheet() {
    final paragraph = _paragraphLook(
      _look.body,
      lineSpacing: _look.lineSpacing,
    );
    final character = _characterLook(_look.body);
    final out = StringBuffer('{\\stylesheet{')
      ..write('$paragraph $character \\snext0 Normal;}');
    for (var level = 1; level <= 6; level++) {
      final heading = _look.heading(level);
      out
        ..write('{\\s$level')
        ..write(_paragraphLook(heading, lineSpacing: _look.lineSpacing))
        ..write('\\keepn\\outlinelevel${level - 1} ')
        ..write(_characterLook(heading))
        ..write(' \\sbasedon0\\snext0 heading $level;}');
    }
    // Word adds no space between paragraphs of one style that say so.
    if (_lists.isNotEmpty) {
      out.write(
        '{\\s$_listStyle$paragraph\\contextualspace $character '
        '\\sbasedon0\\snext$_listStyle List Paragraph;}',
      );
    }
    for (final MapEntry(key: name, value: number) in _groupStyles.entries) {
      out.write(
        '{\\s$number$paragraph\\contextualspace $character '
        '\\sbasedon0\\snext$number ',
      );
      _escape(out, name.replaceAll(';', ''));
      out.write(';}');
    }
    out.write('}\r\n');
    return out.toString();
  }

  /// The style of a group of paragraphs without space between them; the
  /// Normal group keeps the Normal style.
  int? _groupStyle(String group) {
    if (group.isEmpty || group == 'Normal') return null;
    return _groupStyles[group] ??= _listStyle + 1 + _groupStyles.length;
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

  /// Nothing for single spacing, the default of RTF readers.
  static String _lineSpacing(double multiple) =>
      (multiple - 1).abs() < 0.01 ? '' : _multiple(multiple);

  static String _multiple(double multiple) =>
      '\\sl${(multiple * 240).round().clamp(1, 31680)}\\slmult1';

  void _listTables(StringBuffer out) {
    if (_lists.isEmpty) return;
    out.write(r'{\*\listtable');
    for (final (index, levels) in _lists.indexed) {
      final id = index + 1;
      out.write('\r\n{\\list\\listtemplateid$id\\listhybrid');
      for (final definition in levels) {
        _listLevel(out, definition);
      }
      out.write('{\\listname ;}\\listid$id}');
    }
    out.write('}\r\n{\\*\\listoverridetable');
    for (final (index, override) in _overrides.indexed) {
      out.write('{\\listoverride\\listid${override.list + 1}');
      final starts = override.starts;
      final redefined = override.redefined;
      final levels = {...starts.keys, ...redefined.keys};
      // Word writes the levels in order, one or all nine of them.
      final count = levels.isEmpty
          ? 0
          : (levels.every((level) => level == 0) ? 1 : wordListLevels);
      out.write('\\listoverridecount$count');
      for (var level = 0; level < count; level++) {
        out.write(r'{\lfolevel');
        if (starts[level] case final start?) {
          out.write(
            '\\listoverridestartat\\levelstartat${start.clamp(0, 32767)}',
          );
        }
        if (redefined[level] case final definition?) {
          out.write(r'\listoverrideformat');
          _listLevel(out, definition);
        }
        out.write('}');
      }
      out.write('\\ls${index + 1}}');
    }
    out.write('}\r\n');
  }

  void _listLevel(StringBuffer out, _Level definition) {
    final format = switch (definition.format) {
      'bullet' => 23,
      'none' => 255,
      final format => _numberFormats[format] ?? 0,
    };
    final align = definition.justification;
    out
      ..write(
        '{\\listlevel\\levelnfc$format\\levelnfcn$format\\leveljc$align'
        '\\leveljcn$align\\levelfollow${definition.follow.index}'
        '\\levelstartat${definition.start}'
        '${definition.legal ? r'\levellegal1' : ''}'
        '\\levelspace0\\levelindent0',
      )
      // TextEdit shows its own check or box instead of the bullet.
      ..write(switch (definition.text) {
        '☑' => r'{\*\levelmarker \{check\}}',
        '☐' => r'{\*\levelmarker \{box\}}',
        _ => '',
      })
      ..write(_levelText(definition.text))
      ..write(definition.font == null ? '' : '\\f${definition.font}')
      ..write(
        '\\fi${-definition.hanging}\\li${definition.left}'
        '\\lin${definition.left} }',
      );
  }

  /// `\leveltext`: its length, then its characters, where `\'0N` stands for
  /// the number of level N + 1; and `\levelnumbers`: where those numbers are.
  static String _levelText(String text) {
    final characters = StringBuffer();
    final numbers = StringBuffer();
    var length = 0;
    for (var index = 0; index < text.length && length < 255; index++) {
      final unit = text.codeUnitAt(index);
      if (unit < 0x20) continue;
      length++;
      final next = index + 1 < text.length ? text.codeUnitAt(index + 1) : 0;
      if (unit == 0x25 && next >= 0x31 && next <= 0x39) {
        characters.write("\\'${_hexBytes[next - 0x31]}");
        numbers.write("\\'${_hexBytes[length]}");
        index++;
      } else {
        _escape(characters, String.fromCharCode(unit));
      }
    }
    return "{\\leveltext\\'${_hexBytes[length]}$characters;}"
        '{\\levelnumbers$numbers;}';
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
    out.write(switch (page.numbers.format) {
      'upperRoman' => r'\pgnucrm',
      'lowerRoman' => r'\pgnlcrm',
      'upperLetter' => r'\pgnucltr',
      'lowerLetter' => r'\pgnlcltr',
      _ => '',
    });
    if (page.numbers.start case final first?) {
      out.write('\\pgnrestart\\pgnstarts${first.clamp(0, 32767)}');
    }
    out.write(switch (page.start) {
      'continuous' => r'\sbknone',
      'evenPage' => r'\sbkeven',
      'oddPage' => r'\sbkodd',
      'nextColumn' => r'\sbkcol',
      _ => '',
    });
    if (page.titlePage) out.write(r'\titlepg');
    return out.toString();
  }

  /// How the last section numbers its pages, from the body's own w:sectPr,
  /// which the editor keeps in the package.
  _PageNumbers _lastPageNumbers() {
    final package = _package;
    if (package == null) return _unnumbered;
    try {
      final text = package.text(package.mainDocumentPath);
      if (text == null || !text.contains('pgNumType')) return _unnumbered;
      final path = <String>[];
      var numbers = _unnumbered;
      for (final event in parseEvents(text)) {
        if (event is XmlStartElementEvent) {
          final local = event.localName;
          final inBody = path.length >= 2 && path[1] == 'body';
          if (inBody && path.length == 2 && local == 'sectPr') {
            numbers = _unnumbered;
          } else if (inBody &&
              path.length == 3 &&
              path[2] == 'sectPr' &&
              local == 'pgNumType') {
            String? attribute(String name) => event.attributes
                .where((attribute) => attribute.localName == name)
                .firstOrNull
                ?.value;
            numbers = (
              format: attribute('fmt'),
              start: int.tryParse(attribute('start')?.trim() ?? ''),
            );
          }
          if (!event.isSelfClosing) path.add(local);
        } else if (event is XmlEndElementEvent && path.isNotEmpty) {
          path.removeLast();
        }
      }
      return numbers;
    } catch (_) {
      return _unnumbered;
    }
  }

  /// The document's one set of headers and footers, which every section
  /// uses.
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
        _part = story.partPath;
        _orderedList = null;
        // The lists of headers and footers count apart from the body's.
        _counter = WordListCounter(_numbering);
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
    final lines = <DocumentBlock>[];
    // Protected content that writes nothing still ends a numbered list, as
    // in the .docx.
    final listEnds = Set<DocumentBlock>.identity();
    var ended = false;
    for (final block in blocks) {
      if (block is EmbedBlock && block.type == EmbedTypes.opaqueBlock) {
        final text = _opaqueLines(block.value);
        ended = text.isEmpty;
        lines.addAll(text);
      } else {
        if (ended) listEnds.add(block);
        ended = false;
        lines.add(block);
      }
    }
    for (var index = 0; index < lines.length; index++) {
      final block = lines[index];
      if (listEnds.contains(block)) _orderedList = null;
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
    final content = _opaque(value);
    if (content == null || content.hidden || content.text.isEmpty) {
      return const [];
    }
    return [
      for (final line in content.text.split('\n'))
        LineBlock([TextPiece(line, const {})], const {}),
    ];
  }

  static OpaqueContent? _opaque(Object? value) {
    try {
      return OpaqueContent.decode(value);
    } catch (_) {
      return null;
    }
  }

  void _paragraph(StringBuffer out, LineBlock line, int level, String end) {
    final heading = line.heading;
    final base = heading == null ? _look.body : _look.heading(heading);
    final preserved = _Preserved.of(line.attributes);
    final list = line.list;
    final group = line.attributes[HiddenAttributes.contextualGroup];
    out.write(r'\pard\plain');
    if (heading != null) {
      out.write('\\s$heading\\outlinelevel${heading - 1}');
    } else if (list != null) {
      out.write('\\s$_listStyle');
    } else if (group is String) {
      final style = _groupStyle(group);
      if (style != null) out.write('\\s$style');
    }
    // TextEdit keeps the last nesting level unless \itap says it.
    if (level > 0) out.write('\\intbl\\itap$level');
    out.write(switch (line.align) {
      'center' => r'\qc',
      'right' => r'\qr',
      'justify' => r'\qj',
      _ => r'\ql',
    });
    if (list == null) _orderedList = null;
    // A paragraph at a level of its Word list without numbers stays in the
    // list, which shows the level's text.
    final unnumbered = _counter.unnumberedList(line);
    final listNumber = unnumbered != null
        ? _wordListNumber(unnumbered)
        : (list == null ? null : _listNumber(line));
    final listLevel = WordListCounter.levelOf(line);
    final definition = listNumber == null
        ? null
        : _levelsOf(listNumber)[listLevel];
    if (definition != null) {
      _counter.count(line);
      out.write(
        '\\ls$listNumber\\ilvl$listLevel\\li${definition.left}'
        '\\fi${-definition.hanging}',
      );
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
    final height = line.lineHeight;
    final exact = preserved?.exactLine;
    if (height != null && height.isFinite && height > 0) {
      // Single spacing too: the document's spacing may be another.
      out.write(_multiple(height));
    } else if (exact != null) {
      out.write('\\sl$exact\\slmult0');
    } else {
      out.write(_lineSpacing(_look.lineSpacing));
    }
    // The editor adds no space between list items, nor inside a group.
    if (group is String || (list != null && heading == null)) {
      out.write(r'\contextualspace');
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
    if (definition != null) {
      out.write('{\\listtext\\f${definition.font ?? 0} ');
      _escape(
        out,
        (unnumbered ?? _counter.wordList(line)) == null
            ? _listText(listNumber!, listLevel)
            : _counter.textOf(line) ?? '',
      );
      out.write(switch (definition.follow) {
        ListSuffix.tab => r'\tab}',
        ListSuffix.space => ' }',
        ListSuffix.nothing => '}',
      });
    }
    final content = StringBuffer();
    if (_noteMark case final mark?) {
      content.write(mark);
      _noteMark = null;
    }
    final names = <String>[];
    final bookmarks = line.attributes[HiddenAttributes.bookmarks];
    if (bookmarks is String) {
      for (final name in _decodeNames(bookmarks)) {
        final clean = bookmarkName(name);
        if (!_bookmarks.add(clean)) continue;
        names.add(clean);
        content.write(r'{\*\bkmkstart ');
        _escape(content, clean);
        content.write('}');
      }
    }
    _pieces(content, line.pieces);
    // The bookmark spans the paragraph, so REF fields show its text.
    for (final name in names) {
      content.write(r'{\*\bkmkend ');
      _escape(content, name);
      content.write('}');
    }
    if (end == r'\sect' && content.isEmpty) {
      // LibreOffice, TextEdit and Voges drop an empty paragraph that \sect
      // ends; \par keeps it.
      out.write('\\par\r\n\\pard\\plain\\sect\r\n');
      return;
    }
    out
      ..write(content)
      ..write('$end\r\n');
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

  /// The `\ls` of the paragraph's list: one per Word list of the opened
  /// package, or one for the lists of an abstract list that number as one,
  /// which go on counting after other paragraphs as in Word; one for each
  /// kind of the editor's bullets and checklists; one per run of the
  /// editor's numbered items, so each starts at 1.
  int _listNumber(LineBlock line) {
    final numId = _counter.wordList(line);
    if (line.list != 'ordered' || numId != null) _orderedList = null;
    if (numId != null) return _wordListNumber(numId);
    return switch (line.list) {
      'ordered' => _orderedList ??= _addList(_levels(_ListKind.ordered)),
      'checked' => _checkedList ??= _addList(_levels(_ListKind.checked)),
      'unchecked' => _uncheckedList ??= _addList(_levels(_ListKind.unchecked)),
      _ => _bulletList ??= _addList(_levels(_ListKind.bullet)),
    };
  }

  /// The `\ls` of Word list [numId]. The lists of an abstract list number on
  /// its list, so they count together as in Word: each starts again the
  /// levels it restarts with `\listoverridestartat` and gives the levels it
  /// redefines with `\listoverrideformat`.
  int _wordListNumber(int numId) =>
      _wordLists[_numbering.sameNumbering(numId)] ??= () {
        final list = _abstractLists[_numbering.groupOf(numId)!] ??= _define(
          _wordLevels((level) => _numbering.abstractLevel(numId, level)),
        );
        final shared = _lists[list];
        final starts = _numbering.startOverrides(numId);
        final redefined = <int, _Level>{};
        for (var level = 0; level < wordListLevels; level++) {
          final own = _numbering.level(numId, level);
          if (own == null) continue;
          // A level that only starts again keeps the list's definition.
          final start = starts.containsKey(level) ? shared[level].start : null;
          if (_wordLevel(own, start: start) != shared[level]) {
            redefined[level] = _wordLevel(own);
          }
        }
        return _override(list, starts: starts, redefined: redefined);
      }();

  /// A list with an override of its own; returns its `\ls`.
  int _addList(List<_Level> levels) => _override(_define(levels));

  int _define(List<_Level> levels) {
    _lists.add(levels);
    return _lists.length - 1;
  }

  int _override(
    int list, {
    Map<int, int> starts = const {},
    Map<int, _Level> redefined = const {},
  }) {
    _overrides.add((
      list: list,
      starts: starts,
      redefined: redefined,
      levels: [
        for (final (level, definition) in _lists[list].indexed)
          redefined[level] ?? definition,
      ],
    ));
    return _overrides.length;
  }

  /// The levels `\ls` [number] numbers.
  List<_Level> _levelsOf(int number) => _overrides[number - 1].levels;

  /// The levels of a Word list as its definition in the opened package
  /// numbers them; the levels it leaves out are the editor's.
  List<_Level> _wordLevels(WordLevel? Function(int level) levelOf) {
    final bullets = levelOf(0)?.format == 'bullet';
    final fallback = _levels(bullets ? _ListKind.bullet : _ListKind.ordered);
    return [
      for (var level = 0; level < 9; level++)
        switch (levelOf(level)) {
          final defined? => _wordLevel(defined),
          null => fallback[level],
        },
    ];
  }

  /// [level] as the list table holds it, starting at [start] if given.
  _Level _wordLevel(WordLevel level, {int? start}) {
    final font = level.font?.trim();
    return (
      format: level.format,
      text: level.text,
      start: (start ?? level.start).clamp(0, 32767),
      font: font == null || font.isEmpty || font.length > _maxFontName
          ? null
          : _font(font),
      justification: switch (level.justification) {
        'center' => 1,
        'right' || 'end' => 2,
        _ => 0,
      },
      follow: level.suffix,
      left: _twips(level.left ?? 0),
      hanging: _twips(level.hanging ?? 0),
      legal: level.legal,
    );
  }

  /// The editor's lists: numbers go 1, a, i by level; checklist boxes are
  /// bullets.
  List<_Level> _levels(_ListKind kind) {
    final boxes = kind == _ListKind.checked || kind == _ListKind.unchecked;
    final font = boxes ? _font(_checkboxFont) : null;
    return [
      for (var level = 0; level < 9; level++)
        (
          format: kind == _ListKind.ordered
              ? const ['decimal', 'lowerLetter', 'lowerRoman'][level % 3]
              : 'bullet',
          text: switch (kind) {
            _ListKind.ordered => '%${level + 1}.',
            _ListKind.checked => '☑',
            _ListKind.unchecked => '☐',
            _ListKind.bullet => _bullets[level % 3],
          },
          start: 1,
          font: font,
          justification: 0,
          follow: ListSuffix.tab,
          left: 720 * (level + 1),
          hanging: 360,
          legal: false,
        ),
    ];
  }

  /// What readers without lists show of an item of the editor's lists: the
  /// level's text with the item's number.
  String _listText(int number, int level) {
    final levels = _levelsOf(number);
    final counters = _counters.putIfAbsent(
      number,
      () => List<int?>.filled(9, null),
    );
    counters[level] = switch (counters[level]) {
      final count? => count + 1,
      null => levels[level].start,
    };
    counters.fillRange(level + 1, 9, null);
    return levels[level].text.replaceAllMapped(_placeholder, (match) {
      final shown = int.parse(match[1]!) - 1;
      final definition = levels[shown];
      return wordNumber(counters[shown] ?? definition.start, definition.format);
    });
  }

  static final _placeholder = RegExp('%([1-9])');

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
        _quoted(out, _percentEncoded(link));
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

  /// Characters beyond ASCII as UTF-8 escapes: TextEdit stops reading an
  /// address at its first `\uN`.
  static String _percentEncoded(String address) {
    final out = StringBuffer();
    for (final rune in address.runes) {
      if (rune < 0x80) {
        out.writeCharCode(rune);
        continue;
      }
      for (final byte in utf8.encode(String.fromCharCode(rune))) {
        out.write('%${byte.toRadixString(16).toUpperCase().padLeft(2, '0')}');
      }
    }
    return out.toString();
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
        _image(out, piece);
      case EmbedPiece(type: EmbedTypes.pageBreak):
        out.write(r'\page ');
      case EmbedPiece(type: EmbedTypes.pageNumber):
        _field(out, 'PAGE', '1', format);
      case EmbedPiece(type: EmbedTypes.opaqueInline):
        final content = _opaque(piece.value);
        if (content != null) _protected(out, content, format);
      case EmbedPiece():
        return;
    }
  }

  /// Word content the editor keeps as it is: hidden text, fields and notes
  /// as such, objects by their picture, the rest by its text.
  void _protected(StringBuffer out, OpaqueContent content, String format) {
    late final root = _fragment(content.xml);
    if (content.hidden) {
      final text = _xmlText(root);
      if (text.isNotEmpty) _run(out, '${_xmlFormat(root)}$format\\v', text);
      return;
    }
    final field = content.xml.contains('instr') ? _fieldOf(root) : null;
    if (field != null) {
      _field(out, field, content.text, '${_xmlFormat(root)}$format');
      return;
    }
    if (content.label == OpaqueLabels.note && _note(out, content, format)) {
      return;
    }
    if (content.xml.contains('imagedata') || content.xml.contains('blip')) {
      if (_objectPicture(content, root) case final picture?) {
        _picture(
          out,
          picture.bytes,
          width: picture.width,
          height: picture.height,
        );
      }
    }
    if (content.text.isNotEmpty) {
      final note = content.label == OpaqueLabels.note ? r'\super' : '';
      _run(out, '$format$note', content.text);
    }
  }

  /// Text in a group with its character formatting.
  static void _run(StringBuffer out, String format, String text) {
    out.write(format.isEmpty ? '{' : '{$format ');
    _escape(out, text);
    out.write('}');
  }

  /// The instruction and result have the same formatting: Word gives the
  /// instruction's to the result when it updates the field.
  static void _field(
    StringBuffer out,
    String instruction,
    String result,
    String format,
  ) {
    out.write('{\\field{\\*\\fldinst{$format ');
    _escape(out, instruction);
    out.write(r' }}{\fldrslt');
    _run(out, format, result);
    out.write('}}');
  }

  /// A fragment of Word XML as the editor keeps it; null if it is damaged.
  static XmlElement? _fragment(String xml) {
    try {
      return XmlDocument.parse('<r>$xml</r>').rootElement;
    } on XmlException {
      return null;
    }
  }

  /// The instruction of a Word field that shows the document's own data.
  static String? _fieldOf(XmlElement? root) {
    if (root == null) return null;
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
    return isSafeField(instruction) ? _bookmarkReferences(instruction) : null;
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

  /// REF, PAGEREF and NOTEREF name their bookmark as it is written here.
  static String _bookmarkReferences(String instruction) =>
      instruction.replaceFirstMapped(
        RegExp(
          r'^(REF|PAGEREF|NOTEREF)(\s+)(?:"([^"]*)"|([^\s"]+))',
          caseSensitive: false,
        ),
        (match) =>
            '${match[1]}${match[2]}${bookmarkName(match[3] ?? match[4]!)}',
      );

  /// The text of Word runs, with their tabs and breaks.
  static String _xmlText(XmlElement? root) {
    final out = StringBuffer();
    for (final element in root?.descendantElements ?? <XmlElement>[]) {
      out.write(switch (element.name.local) {
        't' => element.innerText,
        'tab' || 'ptab' => '\t',
        'br' || 'cr' => '\u2028',
        'noBreakHyphen' => '\u2011',
        'softHyphen' => '\u00AD',
        _ => '',
      });
    }
    return out.toString();
  }

  /// The first character formatting (`w:rPr`) of Word XML.
  String _xmlFormat(XmlElement? root) {
    XmlElement? properties;
    for (final element in root?.descendantElements ?? <XmlElement>[]) {
      if (element.name.local == 'rPr') {
        properties = element;
        break;
      }
    }
    if (properties == null) return '';
    final out = StringBuffer();
    for (final element in properties.childElements) {
      final value = element.getAttribute('w:val');
      final on = !const {'0', 'false', 'off'}.contains(value);
      switch (element.name.local) {
        case 'b':
          out.write(on ? r'\b' : r'\b0');
        case 'i':
          out.write(on ? r'\i' : r'\i0');
        case 'strike':
          out.write(on ? r'\strike' : r'\strike0');
        case 'caps' when on:
          out.write(r'\caps');
        case 'smallCaps' when on:
          out.write(r'\scaps');
        case 'u':
          out.write(value == 'none' ? r'\ulnone' : r'\ul');
        case 'sz':
          final half = int.tryParse(value ?? '');
          if (half != null && half > 0) out.write('\\fs${half.clamp(2, 3276)}');
        case 'color':
          if (hexColor(value) case final color?) {
            out.write('\\cf${_color(color)}');
          }
        case 'rFonts':
          final font =
              (element.getAttribute('w:ascii') ??
                      element.getAttribute('w:hAnsi'))
                  ?.trim();
          if (font != null && font.isNotEmpty) out.write('\\f${_font(font)}');
        case 'vertAlign':
          out.write(switch (value) {
            'superscript' => r'\super',
            'subscript' => r'\sub',
            _ => '',
          });
      }
    }
    return out.toString();
  }

  // Notes

  /// A footnote or endnote with its text from the opened package; false
  /// when the package doesn't have it, and only its number is written.
  bool _note(StringBuffer out, OpaqueContent content, String format) {
    final package = _package;
    if (!_inBody || package == null || content.packageId != package.id) {
      return false;
    }
    final reference = RegExp(
      r'<w:(footnote|endnote)Reference\b[^>]*?\bw:id="(-?\d+)"',
    ).firstMatch(content.xml);
    if (reference == null) return false;
    final kind = reference[1]!;
    final note = (_notes[kind] ??= _readNotes(package, kind))[reference[2]];
    if (note == null) return false;
    final endnote = kind == 'endnote';
    _endnotes |= endnote;
    out.write('{$format\\super\\chftn{\\footnote${endnote ? r'\ftnalt' : ''}');
    final part = _part;
    final ordered = _orderedList;
    _part = _relatedPart(package, package.mainDocumentPath, '${kind}s');
    _inBody = false;
    _orderedList = null;
    _noteMark = r'{\super\chftn} ';
    final blocks = documentBlocks(note);
    _blocks(
      out,
      [
        if (blocks.firstOrNull is! LineBlock) const LineBlock([], {}),
        ...blocks,
      ],
      0,
      cellMark: '',
    );
    _noteMark = null;
    _part = part;
    _orderedList = ordered;
    _inBody = true;
    out.write('}}');
    return true;
  }

  Map<String, Delta> _readNotes(DocxPackage package, String kind) {
    try {
      return DocxCodec(_tables).notes(package, kind);
    } catch (_) {
      // A damaged notes part keeps only the numbers.
      return const {};
    }
  }

  List<Relationship> _relationshipsOf(DocxPackage package, String part) =>
      _relationships[part] ??= () {
        try {
          return package.relationships(part);
        } catch (_) {
          return const <Relationship>[];
        }
      }();

  /// The part [part] relates to with [type] (`footnotes`, `endnotes`).
  String? _relatedPart(DocxPackage package, String part, String type) {
    for (final relationship in _relationshipsOf(package, part)) {
      if (relationship.hasType(type) && !relationship.external) {
        return DocxPackage.resolve(part, relationship.target);
      }
    }
    return null;
  }

  // Pictures

  void _image(StringBuffer out, EmbedPiece piece) {
    final value = piece.value;
    final decoded = value is String ? decodeDataUri(value) : null;
    if (decoded == null) return;
    _picture(
      out,
      decoded.bytes,
      width: pointsValue(piece.attributes['width']),
      height: pointsValue(piece.attributes['height']),
    );
  }

  /// The picture Word keeps for an object, a VML picture, or a drawing
  /// other programs can't show (its fallback), with its size in points.
  ({Uint8List bytes, double? width, double? height})? _objectPicture(
    OpaqueContent content,
    XmlElement? root,
  ) {
    final package = _package;
    final part = _part;
    if (root == null ||
        package == null ||
        part == null ||
        content.packageId != package.id) {
      return null;
    }
    for (final element in root.descendantElements) {
      final String? id;
      double? width;
      double? height;
      switch (element.name.local) {
        case 'imagedata':
          id =
              _relationshipId(element, 'id') ?? element.getAttribute('o:relid');
          final style = element.parentElement?.getAttribute('style');
          width = _cssPoints(style, 'width');
          height = _cssPoints(style, 'height');
        case 'blip':
          final fallback = element.ancestorElements
              .where((ancestor) => ancestor.name.local == 'Fallback')
              .firstOrNull;
          if (fallback == null) continue;
          id = _relationshipId(element, 'embed');
          final extent = fallback.descendantElements
              .where((descendant) => descendant.name.local == 'extent')
              .firstOrNull;
          width = _emuPoints(extent?.getAttribute('cx'));
          height = _emuPoints(extent?.getAttribute('cy'));
        default:
          continue;
      }
      final relationship = _relationshipsOf(package, part)
          .where((candidate) => candidate.id == id && !candidate.external)
          .firstOrNull;
      if (relationship == null) continue;
      final bytes =
          package.parts[DocxPackage.resolve(part, relationship.target)];
      if (bytes == null || bytes.isEmpty) continue;
      return (bytes: bytes, width: width, height: height);
    }
    return null;
  }

  static String? _relationshipId(XmlElement element, String local) {
    for (final attribute in element.attributes) {
      if (attribute.name.local == local && attribute.name.prefix == 'r') {
        return attribute.value;
      }
    }
    return null;
  }

  /// A length of a VML style (`width:72pt;height:1in`), in points.
  static double? _cssPoints(String? style, String property) {
    if (style == null) return null;
    final match = RegExp(
      '(?:^|;)\\s*$property\\s*:\\s*([0-9.]+)\\s*(pt|in|cm|mm|pc|px)?',
      caseSensitive: false,
    ).firstMatch(style);
    final value = double.tryParse(match?[1] ?? '');
    if (value == null) return null;
    return value *
        switch (match![2]?.toLowerCase()) {
          'pt' => 1,
          'in' => 72,
          'cm' => 72 / 2.54,
          'mm' => 72 / 25.4,
          'pc' => 12,
          _ => 0.75,
        };
  }

  static double? _emuPoints(String? value) {
    final emu = int.tryParse(value ?? '');
    return emu == null ? null : emu / 12700;
  }

  /// [width] and [height] in points; without them the picture takes its own
  /// size, and without one of them it keeps its proportions.
  void _picture(
    StringBuffer out,
    Uint8List bytes, {
    double? width,
    double? height,
  }) {
    final blip = _blip(bytes);
    if (blip == null || blip.data.isEmpty) return;
    final pixels = blip.pixels;
    final natural = pixels == null || pixels.width <= 0 || pixels.height <= 0
        ? null
        : (width: pixels.width * 0.75, height: pixels.height * 0.75);
    final ratio = natural == null ? 1.0 : natural.height / natural.width;
    double? positive(double? value) =>
        value != null && value.isFinite && value > 0 ? value : null;
    final givenWidth = positive(width);
    final givenHeight = positive(height);
    final goalWidth =
        givenWidth ??
        (givenHeight != null ? givenHeight / ratio : natural?.width ?? 72);
    final goalHeight = givenHeight ?? goalWidth * ratio;
    final ownWidth = blip.metafile
        ? (goalWidth * 2540 / 72).round()
        : pixels?.width ?? (goalWidth / 0.75).round();
    final ownHeight = blip.metafile
        ? (goalHeight * 2540 / 72).round()
        : pixels?.height ?? (goalHeight / 0.75).round();
    final data = blip.data;
    out.write(
      '{\\pict${blip.keyword}\\picw$ownWidth\\pich$ownHeight'
      '\\picwgoal${_twips(goalWidth)}\\pichgoal${_twips(goalHeight)}\r\n',
    );
    for (var index = 0; index < data.length; index++) {
      out.write(_hexBytes[data[index]]);
      if (index % 64 == 63) out.write('\r\n');
    }
    out.write('}');
  }

  /// RTF holds PNG, JPEG, metafiles and bitmaps, told by their bytes
  /// whatever their type says; other pictures go as PNG.
  static _Blip? _blip(Uint8List bytes) {
    if (isPng(bytes)) return _Blip(r'\pngblip', bytes, imagePixelSize(bytes));
    if (isJpeg(bytes)) {
      return _Blip(r'\jpegblip', bytes, imagePixelSize(bytes));
    }
    if (isEmf(bytes)) return _Blip(r'\emfblip', bytes, null, metafile: true);
    if (rawWmf(bytes) case final metafile?) {
      return _Blip(r'\wmetafile8', metafile, null, metafile: true);
    }
    if (dibFromBitmap(bytes) case final bitmap?) {
      return _Blip(r'\dibitmap0', bitmap, imagePixelSize(bytes));
    }
    return _png(bytes);
  }

  /// GIF, TIFF, WebP and bitmaps RTF can't hold, as PNG; null for what
  /// can't be decoded or is too large.
  static _Blip? _png(Uint8List bytes) {
    for (final decoder in <img.Decoder>[
      img.GifDecoder(),
      img.TiffDecoder(),
      img.WebPDecoder(),
      img.BmpDecoder(),
    ]) {
      try {
        if (!decoder.isValidFile(bytes)) continue;
        final info = decoder.startDecode(bytes);
        if (info == null ||
            info.width < 1 ||
            info.height < 1 ||
            info.width * info.height > _maxPixels) {
          return null;
        }
        final image = decoder.decode(bytes, frame: 0);
        if (image == null) return null;
        return _Blip(r'\pngblip', img.encodePng(image), (
          width: image.width,
          height: image.height,
        ));
      } catch (_) {
        // Decoders of pictures from untrusted files may throw anything.
        return null;
      }
    }
    return null;
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
          _orderedList = null;
          _blocks(
            out,
            documentBlocks(cell.controller.document.toDelta()),
            level - 1,
          );
        }
      }
      _orderedList = null;
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
        // Each cell numbers its lists from 1, as the editor shows them.
        _orderedList = null;
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
    _orderedList = null;
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

/// A picture as RTF holds it; metafiles have no pixel size.
class _Blip {
  const _Blip(this.keyword, this.data, this.pixels, {this.metafile = false});

  final String keyword;
  final Uint8List data;
  final ({int width, int height})? pixels;
  final bool metafile;
}

enum _ListKind { bullet, ordered, checked, unchecked }

/// A level of a list of the list table: Word's number format, its text,
/// where %1 to %9 stand for the numbers of those levels, its first number,
/// its font in the font table, `\leveljc`, what follows the number, and its
/// indents in twips.
typedef _Level = ({
  String format,
  String text,
  int start,
  int? font,
  int justification,
  ListSuffix follow,
  int left,
  int hanging,
  bool legal,
});

/// A list override: the list it numbers, the levels it starts again and
/// the levels it redefines, and so the levels it numbers with.
typedef _Override = ({
  int list,
  Map<int, int> starts,
  Map<int, _Level> redefined,
  List<_Level> levels,
});

/// Page size, margins, start and page numbers of a section, in twips.
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
    this.titlePage = false,
    this.numbers = _unnumbered,
  });

  /// The last section, whose first page the editor's setting decides.
  factory _PageSetup.fromLook(
    DocumentLook look, {
    bool titlePage = false,
    _PageNumbers numbers = _unnumbered,
  }) => _PageSetup.fromPoints(
    look.pageWidth,
    look.pageHeight,
    look.margins,
    titlePage: titlePage,
    numbers: numbers,
  );

  factory _PageSetup.fromPoints(
    double width,
    double height,
    EdgeInsets margins, {
    bool titlePage = false,
    _PageNumbers numbers = _unnumbered,
  }) => _PageSetup(
    width: RtfWriter._twips(width),
    height: RtfWriter._twips(height),
    left: RtfWriter._twips(margins.left),
    right: RtfWriter._twips(margins.right),
    top: RtfWriter._twips(margins.top),
    bottom: RtfWriter._twips(margins.bottom),
    titlePage: titlePage,
    numbers: numbers,
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
    final titlePage = child('titlePg');
    final numbers = child('pgNumType');
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
      titlePage:
          titlePage != null &&
          !const {
            '0',
            'false',
            'off',
          }.contains(titlePage.getAttribute('w:val')),
      numbers: (
        format: numbers?.getAttribute('w:fmt'),
        start: number(numbers, 'start'),
      ),
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

  /// The section's first page has its own header and footer.
  final bool titlePage;
  final _PageNumbers numbers;

  bool get landscape => width > height;
}

/// Word's `w:pgNumType`: the format, such as lowerRoman (null for 1, 2, 3),
/// and the number of the section's first page (null to go on counting).
typedef _PageNumbers = ({String? format, int? start});

const _PageNumbers _unnumbered = (format: null, start: null);

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
