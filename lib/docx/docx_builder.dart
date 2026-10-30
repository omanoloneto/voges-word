import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/painting.dart' show EdgeInsets;

import '../document/headers_footers.dart';
import 'docx_package.dart';
import 'image_formats.dart';
import 'word_xml.dart';

/// Page size, margins and header distances, in points.
class PageSpec {
  const PageSpec({
    this.width = 595.3,
    this.height = 841.9,
    this.margins = const EdgeInsets.fromLTRB(85.05, 70.85, 85.05, 70.85),
    this.headerDistance = 35.4,
    this.footerDistance = 35.4,
    this.columns = 1,
    this.columnSpacing = 35.4,
    this.numberFormat,
    this.firstNumber,
  });

  final double width;
  final double height;
  final EdgeInsets margins;
  final double headerDistance;
  final double footerDistance;
  final int columns;
  final double columnSpacing;

  /// How the section numbers its pages; null keeps 1, 2, 3.
  final NumberFormat? numberFormat;

  /// The number of the section's first page; null continues the numbering.
  final int? firstNumber;

  double get textWidth => width - margins.left - margins.right;
  double get textHeight => height - margins.top - margins.bottom;
}

enum VerticalPosition { superscript, subscript }

/// Character formatting; null keeps what the style gives.
class RunFormat {
  const RunFormat({
    this.styleId,
    this.font,
    this.size,
    this.bold,
    this.italic,
    this.underline,
    this.strike,
    this.allCaps,
    this.smallCaps,
    this.hidden,
    this.color,
    this.background,
    this.position,
  });

  /// Character style.
  final String? styleId;
  final String? font;

  /// Points.
  final double? size;
  final bool? bold;
  final bool? italic;
  final bool? underline;
  final bool? strike;
  final bool? allCaps;
  final bool? smallCaps;
  final bool? hidden;

  /// RRGGBB.
  final String? color;
  final String? background;
  final VerticalPosition? position;

  bool get isEmpty =>
      styleId == null &&
      font == null &&
      size == null &&
      bold == null &&
      italic == null &&
      underline == null &&
      strike == null &&
      allCaps == null &&
      smallCaps == null &&
      hidden == null &&
      color == null &&
      background == null &&
      position == null;

  /// [other]'s values win where they are set.
  RunFormat merge(RunFormat other) => RunFormat(
    styleId: other.styleId ?? styleId,
    font: other.font ?? font,
    size: other.size ?? size,
    bold: other.bold ?? bold,
    italic: other.italic ?? italic,
    underline: other.underline ?? underline,
    strike: other.strike ?? strike,
    allCaps: other.allCaps ?? allCaps,
    smallCaps: other.smallCaps ?? smallCaps,
    hidden: other.hidden ?? hidden,
    color: other.color ?? color,
    background: other.background ?? background,
    position: other.position ?? position,
  );
}

enum ParagraphAlign { left, center, right, justify }

enum LineRule { multiple, exactly, atLeast }

class LineSpacing {
  /// [value] times single spacing.
  const LineSpacing.multiple(this.value) : rule = LineRule.multiple;

  /// [value] in points.
  const LineSpacing.exactly(this.value) : rule = LineRule.exactly;
  const LineSpacing.atLeast(this.value) : rule = LineRule.atLeast;

  final double value;
  final LineRule rule;
}

/// [clear] removes a tab stop the paragraph's style sets at that position.
enum TabAlign { left, center, right, decimal, clear }

enum TabLeader { none, dot, hyphen, underscore }

class TabStop {
  const TabStop(
    this.position, {
    this.align = TabAlign.left,
    this.leader = TabLeader.none,
  });

  /// Points from the left indent's origin.
  final double position;
  final TabAlign align;
  final TabLeader leader;
}

/// A paragraph's place in a list made with [DocumentSpec.addList];
/// [ListRef.none] takes the paragraph out of the list its style gives.
class ListRef {
  const ListRef(this.numId, [this.level = 0]);

  static const none = ListRef(0);

  final int numId;
  final int level;
}

/// Paragraph formatting; null keeps what the style gives.
class ParagraphFormat {
  const ParagraphFormat({
    this.styleId,
    this.align,
    this.indentLeft,
    this.indentRight,
    this.firstLine,
    this.spaceBefore,
    this.spaceAfter,
    this.lineSpacing,
    this.keepNext,
    this.keepLines,
    this.pageBreakBefore,
    this.contextualSpacing,
    this.rightToLeft,
    this.list,
    this.tabs = const [],
  });

  final String? styleId;
  final ParagraphAlign? align;

  /// Points; a negative [firstLine] is a hanging indent.
  final double? indentLeft;
  final double? indentRight;
  final double? firstLine;
  final double? spaceBefore;
  final double? spaceAfter;
  final LineSpacing? lineSpacing;
  final bool? keepNext;
  final bool? keepLines;
  final bool? pageBreakBefore;
  final bool? contextualSpacing;
  final bool? rightToLeft;
  final ListRef? list;
  final List<TabStop> tabs;

  /// [other]'s values win where they are set.
  ParagraphFormat merge(ParagraphFormat other) => ParagraphFormat(
    styleId: other.styleId ?? styleId,
    align: other.align ?? align,
    indentLeft: other.indentLeft ?? indentLeft,
    indentRight: other.indentRight ?? indentRight,
    firstLine: other.firstLine ?? firstLine,
    spaceBefore: other.spaceBefore ?? spaceBefore,
    spaceAfter: other.spaceAfter ?? spaceAfter,
    lineSpacing: other.lineSpacing ?? lineSpacing,
    keepNext: other.keepNext ?? keepNext,
    keepLines: other.keepLines ?? keepLines,
    pageBreakBefore: other.pageBreakBefore ?? pageBreakBefore,
    contextualSpacing: other.contextualSpacing ?? contextualSpacing,
    rightToLeft: other.rightToLeft ?? rightToLeft,
    list: other.list ?? list,
    tabs: other.tabs.isNotEmpty ? other.tabs : tabs,
  );
}

enum StyleKind { paragraph, character }

class StyleSpec {
  /// The paragraph style with id `Normal` is the document's default one.
  const StyleSpec.paragraph(
    this.id,
    this.name, {
    this.basedOn,
    this.next,
    this.run = const RunFormat(),
    this.paragraph = const ParagraphFormat(),
    this.headingLevel,
  }) : kind = StyleKind.paragraph;

  const StyleSpec.character(
    this.id,
    this.name, {
    this.basedOn,
    this.run = const RunFormat(),
  }) : kind = StyleKind.character,
       next = null,
       paragraph = const ParagraphFormat(),
       headingLevel = null;

  final StyleKind kind;
  final String id;

  /// Shown in Word; heading styles are always named `heading N`, the name the
  /// editor and Word recognize.
  final String name;
  final String? basedOn;
  final String? next;
  final RunFormat run;
  final ParagraphFormat paragraph;

  /// 1 to 9.
  final int? headingLevel;
}

enum NumberFormat {
  bullet,
  decimal,
  decimalZero,
  lowerLetter,
  upperLetter,
  lowerRoman,
  upperRoman,
  none,
}

class ListLevelSpec {
  const ListLevelSpec({
    required this.format,
    required this.text,
    this.start = 1,
    this.indentLeft,
    this.hanging = 18,
    this.font,
  });

  final NumberFormat format;

  /// Word's level text: `%1.` shows the first level's number, `•` a bullet.
  final String text;
  final int start;

  /// Points; null is 36 per level.
  final double? indentLeft;
  final double hanging;

  /// Font of the bullet or number.
  final String? font;
}

class ListSpec {
  ListSpec(List<ListLevelSpec> levels)
    : levels = List.unmodifiable(levels.take(9));

  factory ListSpec.bullets() => ListSpec([
    for (var level = 0; level < 9; level++)
      ListLevelSpec(format: NumberFormat.bullet, text: _bullets[level % 3]),
  ]);

  factory ListSpec.numbered({
    int start = 1,
    NumberFormat format = NumberFormat.decimal,
  }) => ListSpec([
    for (var level = 0; level < 9; level++)
      ListLevelSpec(
        format: level == 0 ? format : _numberCycle[level % 3],
        text: '%${level + 1}.',
        start: level == 0 ? start : 1,
      ),
  ]);

  static const _bullets = ['•', '◦', '▪'];
  static const _numberCycle = [
    NumberFormat.decimal,
    NumberFormat.lowerLetter,
    NumberFormat.lowerRoman,
  ];

  final List<ListLevelSpec> levels;
}

sealed class InlineSpec {
  const InlineSpec();
}

/// Text; tabs, line breaks (`\n`, ` `, `\v`), page breaks (`\f`) and
/// hyphen characters become Word's elements.
class TextSpec extends InlineSpec {
  const TextSpec(this.text, [this.format = const RunFormat()]);

  final String text;
  final RunFormat format;
}

/// An inline picture; without a size it takes its pixels at 96 dpi.
class ImageSpec extends InlineSpec {
  const ImageSpec(
    this.bytes,
    this.mime, {
    this.width,
    this.height,
    this.description = '',
  });

  final Uint8List bytes;
  final String mime;

  /// Points.
  final double? width;
  final double? height;
  final String description;
}

/// A link to a web address, e-mail or `#bookmark`; other targets keep only the
/// text.
class LinkSpec extends InlineSpec {
  const LinkSpec(this.target, this.children);

  final String target;
  final List<InlineSpec> children;
}

/// A Word field such as `PAGE`; fields that could fetch content or run
/// something keep only their [result].
class FieldSpec extends InlineSpec {
  const FieldSpec(
    this.instruction, {
    this.result = '',
    this.format = const RunFormat(),
  });

  final String instruction;
  final String result;
  final RunFormat format;
}

enum NoteKind { footnote, endnote }

class NoteSpec extends InlineSpec {
  const NoteSpec(this.kind, this.blocks, {this.format = const RunFormat()});

  final NoteKind kind;
  final List<BlockSpec> blocks;

  /// Format of the reference mark.
  final RunFormat format;
}

enum BreakKind { line, page, column }

class BreakSpec extends InlineSpec {
  const BreakSpec(this.kind);

  final BreakKind kind;
}

/// A target for `#name` links.
class BookmarkSpec extends InlineSpec {
  const BookmarkSpec(this.name);

  final String name;
}

sealed class BlockSpec {
  const BlockSpec();
}

class ParagraphSpec extends BlockSpec {
  const ParagraphSpec(
    this.inlines, {
    this.format = const ParagraphFormat(),
    this.heading,
    this.mark = const RunFormat(),
  });

  final List<InlineSpec> inlines;
  final ParagraphFormat format;

  /// 1 to 9: uses the style of that heading level (made if missing).
  final int? heading;

  /// Format of the paragraph mark.
  final RunFormat mark;
}

enum CellMerge { none, restart, continuation }

enum CellAlign { top, center, bottom }

class CellSpec {
  const CellSpec(
    this.blocks, {
    this.span = 1,
    this.merge = CellMerge.none,
    this.background,
    this.verticalAlign,
  });

  final List<BlockSpec> blocks;

  /// Grid columns it covers.
  final int span;

  /// Vertical merge with the cells above and below.
  final CellMerge merge;

  /// RRGGBB.
  final String? background;
  final CellAlign? verticalAlign;
}

class RowSpec {
  const RowSpec(this.cells, {this.header = false, this.height});

  final List<CellSpec> cells;

  /// Repeats at the top of each page.
  final bool header;

  /// Minimum height in points.
  final double? height;
}

class TableSpec extends BlockSpec {
  const TableSpec(
    this.rows, {
    this.columnWidths,
    this.bordered = true,
    this.indent,
  });

  final List<RowSpec> rows;

  /// Points; without them the columns split the text width.
  final List<double>? columnWidths;
  final bool bordered;

  /// Points from the left margin.
  final double? indent;
}

enum SectionKind { nextPage, continuous, evenPage, oddPage }

/// Ends a section that used [page]; the last section uses
/// [DocumentSpec.page].
class SectionBreakSpec extends BlockSpec {
  const SectionBreakSpec(this.page, {this.kind = SectionKind.nextPage});

  final PageSpec page;

  /// How the section that ends here starts.
  final SectionKind kind;
}

/// A document built from another format, turned into a .docx package by
/// [DocxBuilder].
class DocumentSpec {
  DocumentSpec({
    this.page = const PageSpec(),
    this.lastSectionKind = SectionKind.nextPage,
    this.defaultRun = const RunFormat(font: 'Arial', size: 12),
    this.defaultParagraph = const ParagraphFormat(
      spaceAfter: 8,
      lineSpacing: LineSpacing.multiple(1.15),
    ),
    this.language,
    this.defaultTabStop = 35.4,
  });

  PageSpec page;
  SectionKind lastSectionKind;
  RunFormat defaultRun;
  ParagraphFormat defaultParagraph;

  /// Like `pt-BR`.
  String? language;

  /// Points.
  double defaultTabStop;

  final styles = <StyleSpec>[];
  final body = <BlockSpec>[];
  final headers = <PageVariant, List<BlockSpec>>{};
  final footers = <PageVariant, List<BlockSpec>>{};
  bool differentFirstPage = false;
  bool differentOddEven = false;

  final _lists = <ListSpec>[];

  List<ListSpec> get lists => List.unmodifiable(_lists);

  /// Returns the id for [ListRef].
  int addList(ListSpec list) {
    _lists.add(list);
    return _lists.length;
  }
}

/// Picture formats Word opens.
const buildableImageTypes = {
  'image/png',
  'image/jpeg',
  'image/gif',
  'image/bmp',
  'image/tiff',
  'image/x-emf',
  'image/x-wmf',
};

/// Word bookmark names: letters, digits and `_`, at most 40 characters,
/// starting with a letter, or with `_` for the hidden ones Word makes for
/// tables of contents and cross-references (`_Toc…`, `_Ref…`).
String bookmarkName(String name) {
  var clean = name.replaceAll(RegExp(r'[^\p{L}\p{N}_]', unicode: true), '_');
  if (!RegExp(r'^(\p{L}|_[\p{L}\p{N}])', unicode: true).hasMatch(clean)) {
    clean = 'b$clean';
  }
  return clean.length > 40 ? clean.substring(0, 40) : clean;
}

/// Web, e-mail and FTP addresses; null for anything else (`javascript:`,
/// `file:`...).
String? safeLinkTarget(String target) {
  final trimmed = target.trim();
  final uri = Uri.tryParse(trimmed);
  if (uri == null) return null;
  return const {'http', 'https', 'mailto', 'ftp'}.contains(uri.scheme)
      ? trimmed
      : null;
}

const _safeFields = {
  'PAGE',
  'NUMPAGES',
  'SECTIONPAGES',
  'SECTION',
  'DATE',
  'TIME',
  'CREATEDATE',
  'SAVEDATE',
  'PRINTDATE',
  'AUTHOR',
  'TITLE',
  'SUBJECT',
  'KEYWORDS',
  'NUMWORDS',
  'NUMCHARS',
  'REF',
  'PAGEREF',
  'NOTEREF',
  'SEQ',
  'STYLEREF',
  '=',
};

/// Whether a field only shows the document's own data; the others (DDE,
/// INCLUDEPICTURE, INCLUDETEXT...) fetch content or run something.
bool isSafeField(String instruction) {
  final trimmed = instruction.trim();
  return trimmed.startsWith('=') ||
      _safeFields.contains(trimmed.split(RegExp(r'\s+')).first.toUpperCase());
}

const _declaration = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>';
const _main = 'application/vnd.openxmlformats-officedocument.wordprocessingml';
const _relationshipBase =
    'http://schemas.openxmlformats.org/officeDocument/2006/relationships';

class DocxBuilder {
  DocxBuilder(this.spec);

  final DocumentSpec spec;

  final _parts = <String, Uint8List>{};
  final _overrides = <String, String>{};
  final _mediaExtensions = <String>{};
  final _sharedRelationships = <String, List<_Relationship>>{};
  final _styleIds = <String>{'Normal', 'DefaultParagraphFont', 'TableNormal'};
  final _headingStyles = <int, String>{};
  final _bookmarks = <String>{};
  final _footnotes = StringBuffer();
  final _endnotes = StringBuffer();
  var _bookmarkId = 0;
  var _drawingId = 0;
  var _noteId = 0;
  var _media = 0;
  var _inNote = false;
  var _usesHyperlinkStyle = false;
  var _references = '';
  late final _document = _Part(this, 'word/document.xml');

  /// Call once.
  DocxPackage build() {
    for (final style in spec.styles) {
      if (style.headingLevel case final level?) {
        _headingStyles.putIfAbsent(level, () => style.id);
      }
      _styleIds.add(style.id);
    }

    final references = StringBuffer();
    var number = 0;
    for (final (kind, stories) in [
      ('header', spec.headers),
      ('footer', spec.footers),
    ]) {
      for (final MapEntry(key: variant, value: blocks) in stories.entries) {
        final part = _Part(this, 'word/$kind${++number}.xml');
        final root = kind == 'header' ? 'hdr' : 'ftr';
        _save(
          part,
          '<w:$root ${_namespaces()}>${_blocks(blocks, part)}</w:$root>',
          '$_main.$kind+xml',
        );
        final id = _document.relate('$_relationshipBase/$kind', part.target);
        final type = switch (variant) {
          PageVariant.normal => 'default',
          PageVariant.first => 'first',
          PageVariant.even => 'even',
        };
        references.write('<w:${kind}Reference w:type="$type" r:id="$id"/>');
      }
    }
    _references = references.toString();

    final body =
        _blocks(spec.body, _document, body: true) +
        _section(spec.page, spec.lastSectionKind);

    for (final kind in NoteKind.values) {
      if ((kind == NoteKind.footnote ? _footnotes : _endnotes).isNotEmpty) {
        _notes(kind);
      }
    }
    if (spec.lists.isNotEmpty) {
      _addPart('numbering.xml', _numbering(), 'numbering');
    }
    _addPart('styles.xml', _styles(), 'styles');
    _addPart('settings.xml', _settings(), 'settings');
    _save(
      _document,
      '<w:document ${_namespaces()} mc:Ignorable="w14 wp14">'
          '<w:body>$body</w:body></w:document>',
      '$_main.document.main+xml',
    );
    _parts['_rels/.rels'] = _utf8(
      '$_declaration<Relationships xmlns="${Namespaces.packageRelationships}">'
      '<Relationship Id="rId1" Type="$_relationshipBase/officeDocument" '
      'Target="word/document.xml"/></Relationships>',
    );
    _parts['[Content_Types].xml'] = _utf8(_contentTypes());
    return DocxPackage(_parts);
  }

  void _addPart(String name, String xml, String type) {
    _parts['word/$name'] = _utf8(xml);
    _overrides['/word/$name'] = '$_main.$type+xml';
    _document.relate('$_relationshipBase/$type', name);
  }

  void _save(_Part part, String xml, String contentType) {
    _parts[part.name] = _utf8('$_declaration$xml');
    _overrides['/${part.name}'] = contentType;
    final relationships = part.xml();
    if (relationships != null) {
      _parts[DocxPackage.relationshipsPath(part.name)] = _utf8(relationships);
    }
  }

  static Uint8List _utf8(String text) => Uint8List.fromList(utf8.encode(text));

  static String _namespaces() => [
    for (final prefix in const [
      'w',
      'r',
      'wp',
      'a',
      'pic',
      'mc',
      'w14',
      'wp14',
    ])
      'xmlns:$prefix="${Namespaces.known[prefix]}"',
  ].join(' ');

  // Blocks

  /// Ends with a paragraph, as Word requires after a table. Section breaks
  /// only count in the body.
  String _blocks(List<BlockSpec> blocks, _Part part, {bool body = false}) {
    final out = StringBuffer();
    var endsWithParagraph = false;
    for (var index = 0; index < blocks.length; index++) {
      final block = blocks[index];
      final next = index + 1 < blocks.length ? blocks[index + 1] : null;
      switch (block) {
        case ParagraphSpec():
          final section = body && next is SectionBreakSpec
              ? _section(next.page, next.kind)
              : null;
          out.write(_paragraph(block, part, section: section));
          if (section != null) index++;
          endsWithParagraph = true;
        case TableSpec():
          final table = _table(block, part);
          if (table.isEmpty) continue;
          out.write(table);
          endsWithParagraph = false;
        case SectionBreakSpec():
          if (!body) continue;
          out.write(
            '<w:p><w:pPr>${_section(block.page, block.kind)}</w:pPr></w:p>',
          );
          endsWithParagraph = true;
      }
    }
    if (!endsWithParagraph) out.write('<w:p/>');
    return out.toString();
  }

  String _section(PageSpec page, SectionKind kind) {
    final margins = page.margins;
    final landscape = page.width > page.height;
    final type = switch (kind) {
      SectionKind.nextPage => '',
      _ => '<w:type w:val="${kind.name}"/>',
    };
    final columns = page.columns > 1
        ? ' w:num="${math.min(page.columns, 45)}"'
        : '';
    final numbers = [
      if (page.numberFormat case final format?
          when format != NumberFormat.bullet)
        ' w:fmt="${format.name}"',
      if (page.firstNumber case final first?)
        ' w:start="${first.clamp(0, 32767)}"',
    ].join();
    return '<w:sectPr>$_references$type'
        '<w:pgSz w:w="${_twips(page.width)}" w:h="${_twips(page.height)}"'
        '${landscape ? ' w:orient="landscape"' : ''}/>'
        '<w:pgMar w:top="${_twips(margins.top)}" '
        'w:right="${_twips(margins.right)}" '
        'w:bottom="${_twips(margins.bottom)}" '
        'w:left="${_twips(margins.left)}" '
        'w:header="${_twips(page.headerDistance)}" '
        'w:footer="${_twips(page.footerDistance)}" w:gutter="0"/>'
        '${numbers.isEmpty ? '' : '<w:pgNumType$numbers/>'}'
        '<w:cols w:space="${_twips(page.columnSpacing)}"$columns/>'
        '${spec.differentFirstPage ? '<w:titlePg/>' : ''}'
        '</w:sectPr>';
  }

  String _paragraph(ParagraphSpec paragraph, _Part part, {String? section}) {
    var format = paragraph.format;
    if (paragraph.heading case final level? when level >= 1 && level <= 9) {
      format = format.merge(ParagraphFormat(styleId: _headingStyle(level)));
    }
    final properties =
        _paragraphProperties(format, mark: paragraph.mark) + (section ?? '');
    final content = _inlines(paragraph.inlines, part, const RunFormat());
    return '<w:p>${properties.isEmpty ? '' : '<w:pPr>$properties</w:pPr>'}'
        '$content</w:p>';
  }

  /// In schema order; the section properties go after it.
  String _paragraphProperties(
    ParagraphFormat format, {
    RunFormat mark = const RunFormat(),
    bool inStyle = false,
  }) {
    final out = StringBuffer();
    final styleId = format.styleId;
    if (!inStyle && styleId != null && _styleIds.contains(styleId)) {
      out.write('<w:pStyle w:val="${escapeXmlAttribute(styleId)}"/>');
    }
    _onOff(out, 'keepNext', format.keepNext);
    _onOff(out, 'keepLines', format.keepLines);
    _onOff(out, 'pageBreakBefore', format.pageBreakBefore);
    final list = format.list;
    if (list != null && list.numId >= 0 && list.numId <= spec.lists.length) {
      out.write(
        '<w:numPr><w:ilvl w:val="${list.level.clamp(0, 8)}"/>'
        '<w:numId w:val="${list.numId}"/></w:numPr>',
      );
    }
    if (format.tabs.isNotEmpty) {
      out.write('<w:tabs>');
      for (final tab in format.tabs.take(64)) {
        final leader = tab.leader == TabLeader.none
            ? ''
            : ' w:leader="${tab.leader.name}"';
        out.write(
          '<w:tab w:val="${tab.align.name}"$leader '
          'w:pos="${_twips(tab.position)}"/>',
        );
      }
      out.write('</w:tabs>');
    }
    _onOff(out, 'bidi', format.rightToLeft);
    final spacing = StringBuffer();
    if (format.spaceBefore case final before?) {
      spacing.write(' w:before="${_twips(math.max(before, 0))}"');
    }
    if (format.spaceAfter case final after?) {
      spacing.write(' w:after="${_twips(math.max(after, 0))}"');
    }
    if (format.lineSpacing case final line? when line.value > 0) {
      final (value, rule) = switch (line.rule) {
        LineRule.multiple => (
          (line.value * 240).round().clamp(1, 31680),
          'auto',
        ),
        LineRule.exactly => (_twips(line.value), 'exact'),
        LineRule.atLeast => (_twips(line.value), 'atLeast'),
      };
      spacing.write(' w:line="$value" w:lineRule="$rule"');
    }
    if (spacing.isNotEmpty) out.write('<w:spacing$spacing/>');
    final indent = StringBuffer();
    if (format.indentLeft case final left?) {
      indent.write(' w:left="${_twips(left)}"');
    }
    if (format.indentRight case final right?) {
      indent.write(' w:right="${_twips(right)}"');
    }
    if (format.firstLine case final first?) {
      indent.write(
        first < 0
            ? ' w:hanging="${_twips(-first)}"'
            : ' w:firstLine="${_twips(first)}"',
      );
    }
    if (indent.isNotEmpty) out.write('<w:ind$indent/>');
    _onOff(out, 'contextualSpacing', format.contextualSpacing);
    if (format.align case final align?) {
      out.write('<w:jc w:val="${_alignment(align)}"/>');
    }
    final markProperties = _runProperties(mark);
    if (markProperties.isNotEmpty) out.write('<w:rPr>$markProperties</w:rPr>');
    return out.toString();
  }

  static String _alignment(ParagraphAlign align) => switch (align) {
    ParagraphAlign.left => 'left',
    ParagraphAlign.center => 'center',
    ParagraphAlign.right => 'right',
    ParagraphAlign.justify => 'both',
  };

  String _table(TableSpec table, _Part part) {
    final rows = [
      for (final row in table.rows)
        if (row.cells.isNotEmpty) row,
    ];
    if (rows.isEmpty) return '';
    final columns = rows
        .map((row) => row.cells.fold(0, (sum, cell) => sum + _span(cell)))
        .reduce(math.max);
    var widths = table.columnWidths;
    if (widths == null ||
        widths.length != columns ||
        widths.any((width) => !width.isFinite || width <= 0)) {
      widths = List.filled(columns, spec.page.textWidth / columns);
    }
    final border = table.bordered ? 'single' : 'none';
    final sides = [
      for (final side in const [
        'top',
        'left',
        'bottom',
        'right',
        'insideH',
        'insideV',
      ])
        '<w:$side w:val="$border" w:sz="4" w:space="0" w:color="auto"/>',
    ].join();
    final indent = table.indent == null
        ? ''
        : '<w:tblInd w:w="${_twips(table.indent!)}" w:type="dxa"/>';
    final out = StringBuffer(
      '<w:tbl><w:tblPr><w:tblW w:w="0" w:type="auto"/>$indent'
      '<w:tblBorders>$sides</w:tblBorders><w:tblLayout w:type="fixed"/>'
      '<w:tblLook w:val="04A0" w:firstRow="1" w:lastRow="0" '
      'w:firstColumn="1" w:lastColumn="0" w:noHBand="0" w:noVBand="1"/>'
      '</w:tblPr><w:tblGrid>',
    );
    for (final width in widths) {
      out.write('<w:gridCol w:w="${_twips(width)}"/>');
    }
    out.write('</w:tblGrid>');
    for (final row in rows) {
      final rowProperties = [
        if (row.height case final height? when height > 0)
          '<w:trHeight w:val="${_twips(height)}"/>',
        if (row.header) '<w:tblHeader/>',
      ].join();
      out.write(
        rowProperties.isEmpty
            ? '<w:tr>'
            : '<w:tr><w:trPr>$rowProperties</w:trPr>',
      );
      var column = 0;
      for (final cell in row.cells) {
        final span = math.min(_span(cell), math.max(columns - column, 1));
        final width = widths
            .skip(column)
            .take(span)
            .fold<double>(0, (sum, value) => sum + value);
        column += span;
        final properties = StringBuffer(
          '<w:tcW w:w="${_twips(width)}" w:type="dxa"/>',
        );
        if (span > 1) properties.write('<w:gridSpan w:val="$span"/>');
        switch (cell.merge) {
          case CellMerge.restart:
            properties.write('<w:vMerge w:val="restart"/>');
          case CellMerge.continuation:
            properties.write('<w:vMerge/>');
          case CellMerge.none:
            break;
        }
        if (_hex(cell.background) case final fill?) {
          properties.write(
            '<w:shd w:val="clear" w:color="auto" w:fill="$fill"/>',
          );
        }
        if (cell.verticalAlign case final align?) {
          properties.write('<w:vAlign w:val="${align.name}"/>');
        }
        out.write(
          '<w:tc><w:tcPr>$properties</w:tcPr>'
          '${_blocks(cell.blocks, part)}</w:tc>',
        );
      }
      out.write('</w:tr>');
    }
    out.write('</w:tbl>');
    return out.toString();
  }

  static int _span(CellSpec cell) => cell.span.clamp(1, 63);

  // Inline content

  String _inlines(List<InlineSpec> inlines, _Part part, RunFormat base) {
    final out = StringBuffer();
    for (final inline in inlines) {
      switch (inline) {
        case TextSpec():
          out.write(_text(inline.text, base.merge(inline.format)));
        case ImageSpec():
          out.write(_image(inline, part));
        case LinkSpec():
          out.write(_link(inline, part, base));
        case FieldSpec():
          out.write(_field(inline, base));
        case NoteSpec():
          if (!_inNote) out.write(_noteReference(inline, base));
        case BreakSpec():
          out.write(switch (inline.kind) {
            BreakKind.line => '<w:r><w:br/></w:r>',
            BreakKind.page => '<w:r><w:br w:type="page"/></w:r>',
            BreakKind.column => '<w:r><w:br w:type="column"/></w:r>',
          });
        case BookmarkSpec():
          final name = bookmarkName(inline.name);
          if (!_bookmarks.add(name)) continue;
          final id = _bookmarkId++;
          out.write(
            '<w:bookmarkStart w:id="$id" w:name="${escapeXmlAttribute(name)}"/>'
            '<w:bookmarkEnd w:id="$id"/>',
          );
      }
    }
    return out.toString();
  }

  String _text(String text, RunFormat format) {
    if (text.isEmpty) return '';
    final content = StringBuffer();
    final pending = StringBuffer();
    void flush() {
      if (pending.isEmpty) return;
      content.write(
        '<w:t xml:space="preserve">${escapeXmlText(pending.toString())}</w:t>',
      );
      pending.clear();
    }

    for (final rune in text.runes) {
      final element = switch (rune) {
        0x09 => '<w:tab/>',
        0x0A || 0x0B || 0x2028 => '<w:br/>',
        0x0C => '<w:br w:type="page"/>',
        0x1E || 0x2011 => '<w:noBreakHyphen/>',
        0x1F || 0xAD => '<w:softHyphen/>',
        _ => null,
      };
      if (element != null) {
        flush();
        content.write(element);
      } else if (rune >= 0x20 &&
          rune != 0xFFFE &&
          rune != 0xFFFF &&
          (rune < 0xD800 || rune > 0xDFFF)) {
        pending.writeCharCode(rune);
      }
    }
    flush();
    if (content.isEmpty) return '';
    return '<w:r>${_runPropertiesElement(format)}$content</w:r>';
  }

  String _runPropertiesElement(RunFormat format) {
    final properties = _runProperties(format);
    return properties.isEmpty ? '' : '<w:rPr>$properties</w:rPr>';
  }

  /// In schema order.
  String _runProperties(RunFormat format, {bool inStyle = false}) {
    final out = StringBuffer();
    final styleId = format.styleId;
    if (!inStyle && styleId != null && _styleIds.contains(styleId)) {
      out.write('<w:rStyle w:val="${escapeXmlAttribute(styleId)}"/>');
    }
    if (format.font case final font? when font.trim().isNotEmpty) {
      final name = escapeXmlAttribute(stripInvalidXmlChars(font.trim()));
      out.write(
        '<w:rFonts w:ascii="$name" w:hAnsi="$name" w:eastAsia="$name" '
        'w:cs="$name"/>',
      );
    }
    _onOff(out, 'b', format.bold);
    _onOff(out, 'bCs', format.bold);
    _onOff(out, 'i', format.italic);
    _onOff(out, 'iCs', format.italic);
    _onOff(out, 'caps', format.allCaps);
    _onOff(out, 'smallCaps', format.smallCaps);
    _onOff(out, 'strike', format.strike);
    _onOff(out, 'vanish', format.hidden);
    if (format.color case final color?) {
      out.write('<w:color w:val="${_hex(color) ?? 'auto'}"/>');
    }
    if (format.size case final size? when size > 0 && size.isFinite) {
      final half = (size * 2).round().clamp(2, 3276);
      out.write('<w:sz w:val="$half"/><w:szCs w:val="$half"/>');
    }
    if (format.underline case final underline?) {
      out.write('<w:u w:val="${underline ? 'single' : 'none'}"/>');
    }
    if (format.background case final background?) {
      out.write(
        '<w:shd w:val="clear" w:color="auto" '
        'w:fill="${_hex(background) ?? 'auto'}"/>',
      );
    }
    if (format.position case final position?) {
      final value = position == VerticalPosition.superscript
          ? 'superscript'
          : 'subscript';
      out.write('<w:vertAlign w:val="$value"/>');
    }
    return out.toString();
  }

  static void _onOff(StringBuffer out, String name, bool? value) {
    if (value == null) return;
    out.write(value ? '<w:$name/>' : '<w:$name w:val="0"/>');
  }

  String _link(LinkSpec link, _Part part, RunFormat base) {
    final target = link.target.trim();
    final anchor = target.startsWith('#')
        ? bookmarkName(target.substring(1))
        : null;
    final address = anchor == null ? safeLinkTarget(target) : null;
    if (anchor == null && address == null) {
      return _inlines(link.children, part, base);
    }
    _usesHyperlinkStyle = true;
    _styleIds.add('Hyperlink');
    final content = _inlines(
      link.children,
      part,
      base.merge(const RunFormat(styleId: 'Hyperlink')),
    );
    if (content.isEmpty) return '';
    if (anchor != null) {
      return '<w:hyperlink w:anchor="${escapeXmlAttribute(anchor)}" '
          'w:history="1">$content</w:hyperlink>';
    }
    final id = part.relate(
      '$_relationshipBase/hyperlink',
      address!,
      external: true,
    );
    return '<w:hyperlink r:id="$id" w:history="1">$content</w:hyperlink>';
  }

  String _field(FieldSpec field, RunFormat base) {
    final format = base.merge(field.format);
    final instruction = stripInvalidXmlChars(field.instruction).trim();
    if (!isSafeField(instruction)) {
      return _text(field.result, format);
    }
    final properties = _runPropertiesElement(format);
    String run(String content) => '<w:r>$properties$content</w:r>';
    return [
      run('<w:fldChar w:fldCharType="begin"/>'),
      run(
        '<w:instrText xml:space="preserve"> ${escapeXmlText(instruction)} '
        '</w:instrText>',
      ),
      run('<w:fldChar w:fldCharType="separate"/>'),
      _text(field.result, format),
      run('<w:fldChar w:fldCharType="end"/>'),
    ].join();
  }

  String _noteReference(NoteSpec note, RunFormat base) {
    final id = ++_noteId;
    final footnote = note.kind == NoteKind.footnote;
    final kind = footnote ? 'footnote' : 'endnote';
    final referenceStyle = footnote ? 'FootnoteReference' : 'EndnoteReference';
    final textStyle = footnote ? 'FootnoteText' : 'EndnoteText';
    _styleIds
      ..add(referenceStyle)
      ..add(textStyle);
    final part = _Part(this, 'word/${kind}s.xml', shared: true);
    final blocks = note.blocks.isEmpty
        ? const <BlockSpec>[ParagraphSpec([])]
        : note.blocks;
    _inNote = true;
    final content = StringBuffer();
    var first = true;
    for (final block in blocks) {
      if (block is ParagraphSpec) {
        final properties = _paragraphProperties(
          ParagraphFormat(styleId: textStyle).merge(block.format),
          mark: block.mark,
        );
        final mark = first
            ? '<w:r><w:rPr><w:rStyle w:val="$referenceStyle"/></w:rPr>'
                  '<w:${kind}Ref/></w:r><w:r><w:t xml:space="preserve"> </w:t></w:r>'
            : '';
        first = false;
        content.write(
          '<w:p><w:pPr>$properties</w:pPr>$mark'
          '${_inlines(block.inlines, part, const RunFormat())}</w:p>',
        );
      } else if (block is TableSpec) {
        content.write(_table(block, part));
      }
    }
    _inNote = false;
    if (blocks.last is! ParagraphSpec) content.write('<w:p/>');
    (footnote ? _footnotes : _endnotes).write(
      '<w:$kind w:id="$id">$content</w:$kind>',
    );
    final format = base
        .merge(note.format)
        .merge(RunFormat(styleId: referenceStyle));
    return '<w:r>${_runPropertiesElement(format)}'
        '<w:${kind}Reference w:id="$id"/></w:r>';
  }

  void _notes(NoteKind kind) {
    final name = kind == NoteKind.footnote ? 'footnote' : 'endnote';
    final notes = kind == NoteKind.footnote ? _footnotes : _endnotes;
    String separator(String type, int id, String mark) =>
        '<w:$name w:type="$type" w:id="$id"><w:p><w:pPr>'
        '<w:spacing w:after="0" w:line="240" w:lineRule="auto"/></w:pPr>'
        '<w:r><w:$mark/></w:r></w:p></w:$name>';
    final part = _Part(this, 'word/${name}s.xml', shared: true);
    _save(
      part,
      '<w:${name}s ${_namespaces()}>'
          '${separator('separator', -1, 'separator')}'
          '${separator('continuationSeparator', 0, 'continuationSeparator')}'
          '$notes</w:${name}s>',
      '$_main.${name}s+xml',
    );
    _document.relate('$_relationshipBase/${name}s', part.target);
  }

  String _image(ImageSpec image, _Part part) {
    if (!buildableImageTypes.contains(image.mime) || image.bytes.isEmpty) {
      return '';
    }
    final pixels = imagePixelSize(image.bytes);
    final natural = pixels == null
        ? null
        : (width: pixels.width * 0.75, height: pixels.height * 0.75);
    final ratio = natural == null || natural.width <= 0 || natural.height <= 0
        ? 1.0
        : natural.height / natural.width;
    var w = image.width ?? (image.height ?? natural?.height ?? 72) / ratio;
    var h = image.height ?? w * ratio;
    if (image.width == null && image.height == null && natural != null) {
      w = natural.width;
      h = natural.height;
    }
    if (!w.isFinite || !h.isFinite || w <= 0 || h <= 0) return '';
    final maxWidth = spec.page.textWidth;
    if (w > maxWidth && maxWidth > 0) {
      h = h * maxWidth / w;
      w = maxWidth;
    }
    final maxHeight = spec.page.textHeight;
    if (h > maxHeight && maxHeight > 0) {
      w = w * maxHeight / h;
      h = maxHeight;
    }
    final extension = extensionForMime(image.mime);
    final target = 'media/image${++_media}.$extension';
    _parts['word/$target'] = image.bytes;
    _mediaExtensions.add(extension);
    final id = part.relate('$_relationshipBase/image', target);
    final cx = (w * 12700).round();
    final cy = (h * 12700).round();
    final drawing = ++_drawingId;
    final description = escapeXmlAttribute(
      stripInvalidXmlChars(image.description),
    );
    return '<w:r><w:drawing><wp:inline distT="0" distB="0" distL="0" distR="0">'
        '<wp:extent cx="$cx" cy="$cy"/><wp:effectExtent l="0" t="0" r="0" b="0"/>'
        '<wp:docPr id="$drawing" name="Picture $drawing" descr="$description"/>'
        '<wp:cNvGraphicFramePr><a:graphicFrameLocks noChangeAspect="1"/>'
        '</wp:cNvGraphicFramePr><a:graphic>'
        '<a:graphicData uri="${Namespaces.pic}"><pic:pic><pic:nvPicPr>'
        '<pic:cNvPr id="$drawing" name="Picture $drawing"/><pic:cNvPicPr/>'
        '</pic:nvPicPr><pic:blipFill><a:blip r:embed="$id"/><a:stretch>'
        '<a:fillRect/></a:stretch></pic:blipFill><pic:spPr><a:xfrm>'
        '<a:off x="0" y="0"/><a:ext cx="$cx" cy="$cy"/></a:xfrm>'
        '<a:prstGeom prst="rect"><a:avLst/></a:prstGeom></pic:spPr></pic:pic>'
        '</a:graphicData></a:graphic></wp:inline></w:drawing></w:r>';
  }

  // Package parts

  String _headingStyle(int level) => _headingStyles.putIfAbsent(level, () {
    final id = 'Heading$level';
    _styleIds.add(id);
    return id;
  });

  String _styles() {
    final defaults = spec.defaultRun;
    final language = spec.language == null
        ? ''
        : '<w:lang w:val="${escapeXmlAttribute(spec.language!)}" '
              'w:eastAsia="${escapeXmlAttribute(spec.language!)}" '
              'w:bidi="ar-SA"/>';
    final paragraph = spec.defaultParagraph;
    final out = StringBuffer(
      '$_declaration<w:styles xmlns:w="${Namespaces.w}">'
      '<w:docDefaults><w:rPrDefault><w:rPr>'
      '${_runProperties(RunFormat(font: defaults.font ?? 'Arial', size: defaults.size ?? 12, color: defaults.color), inStyle: true)}'
      '$language</w:rPr></w:rPrDefault><w:pPrDefault><w:pPr>'
      '${_paragraphProperties(ParagraphFormat(spaceBefore: paragraph.spaceBefore, spaceAfter: paragraph.spaceAfter, lineSpacing: paragraph.lineSpacing), inStyle: true)}'
      '</w:pPr></w:pPrDefault></w:docDefaults>',
    );
    final written = <String>{'DefaultParagraphFont', 'TableNormal'};
    if (!spec.styles.any((style) => style.id == 'Normal')) {
      out.write(
        _style(
          StyleSpec.paragraph(
            'Normal',
            'Normal',
            paragraph: ParagraphFormat(
              align: paragraph.align,
              indentLeft: paragraph.indentLeft,
              indentRight: paragraph.indentRight,
              firstLine: paragraph.firstLine,
            ),
          ),
        ),
      );
      written.add('Normal');
    }
    out.write(
      '<w:style w:type="character" w:default="1" '
      'w:styleId="DefaultParagraphFont"><w:name w:val="Default Paragraph Font"/>'
      '<w:uiPriority w:val="1"/><w:semiHidden/><w:unhideWhenUsed/></w:style>'
      '<w:style w:type="table" w:default="1" w:styleId="TableNormal">'
      '<w:name w:val="Normal Table"/><w:uiPriority w:val="99"/><w:semiHidden/>'
      '<w:unhideWhenUsed/><w:tblPr><w:tblInd w:w="0" w:type="dxa"/>'
      '<w:tblCellMar><w:top w:w="0" w:type="dxa"/>'
      '<w:left w:w="108" w:type="dxa"/><w:bottom w:w="0" w:type="dxa"/>'
      '<w:right w:w="108" w:type="dxa"/></w:tblCellMar></w:tblPr></w:style>',
    );
    final all = [
      ...spec.styles,
      for (final MapEntry(key: level, value: id) in _headingStyles.entries)
        _defaultHeading(level, id),
      if (_usesHyperlinkStyle)
        const StyleSpec.character(
          'Hyperlink',
          'Hyperlink',
          run: RunFormat(color: '0563C1', underline: true),
        ),
      for (final (kind, used) in [
        ('footnote', _footnotes.isNotEmpty),
        ('endnote', _endnotes.isNotEmpty),
      ])
        if (used) ...[
          StyleSpec.paragraph(
            '${kind == 'footnote' ? 'Footnote' : 'Endnote'}Text',
            '$kind text',
            basedOn: 'Normal',
            run: const RunFormat(size: 10),
            paragraph: const ParagraphFormat(
              spaceAfter: 0,
              lineSpacing: LineSpacing.multiple(1),
            ),
          ),
          StyleSpec.character(
            '${kind == 'footnote' ? 'Footnote' : 'Endnote'}Reference',
            '$kind reference',
            run: const RunFormat(position: VerticalPosition.superscript),
          ),
        ],
    ];
    for (final style in all) {
      if (written.add(style.id)) out.write(_style(style));
    }
    out.write('</w:styles>');
    return out.toString();
  }

  static StyleSpec _defaultHeading(int level, String id) {
    const sizes = [16.0, 14.0, 13.0, 12.0, 12.0, 12.0, 11.0, 11.0, 11.0];
    return StyleSpec.paragraph(
      id,
      'heading $level',
      basedOn: 'Normal',
      next: 'Normal',
      headingLevel: level,
      run: RunFormat(bold: true, size: sizes[level - 1], italic: level >= 5),
      paragraph: ParagraphFormat(
        keepNext: true,
        keepLines: true,
        spaceBefore: level == 1 ? 18 : 12,
        spaceAfter: 4,
        indentLeft: 0,
        firstLine: 0,
        align: ParagraphAlign.left,
      ),
    );
  }

  String _style(StyleSpec style) {
    final isParagraph = style.kind == StyleKind.paragraph;
    final name = style.headingLevel != null && isParagraph
        ? 'heading ${style.headingLevel!.clamp(1, 9)}'
        : stripInvalidXmlChars(style.name);
    final out = StringBuffer(
      '<w:style w:type="${isParagraph ? 'paragraph' : 'character'}"'
      '${style.id == 'Normal' && isParagraph ? ' w:default="1"' : ''}'
      ' w:styleId="${escapeXmlAttribute(style.id)}">'
      '<w:name w:val="${escapeXmlAttribute(name)}"/>',
    );
    if (style.basedOn case final basedOn?
        when basedOn != style.id && _styleIds.contains(basedOn)) {
      out.write('<w:basedOn w:val="${escapeXmlAttribute(basedOn)}"/>');
    }
    if (style.next case final next? when _styleIds.contains(next)) {
      out.write('<w:next w:val="${escapeXmlAttribute(next)}"/>');
    }
    out.write('<w:qFormat/>');
    if (isParagraph) {
      final outline = style.headingLevel == null
          ? ''
          : '<w:outlineLvl w:val="${(style.headingLevel! - 1).clamp(0, 8)}"/>';
      final properties =
          _paragraphProperties(style.paragraph, inStyle: true) + outline;
      if (properties.isNotEmpty) out.write('<w:pPr>$properties</w:pPr>');
    }
    final run = _runProperties(style.run, inStyle: true);
    if (run.isNotEmpty) out.write('<w:rPr>$run</w:rPr>');
    out.write('</w:style>');
    return out.toString();
  }

  String _numbering() {
    final out = StringBuffer(
      '$_declaration<w:numbering xmlns:w="${Namespaces.w}">',
    );
    for (final (index, list) in spec.lists.indexed) {
      out.write(
        '<w:abstractNum w:abstractNumId="$index">'
        '<w:multiLevelType w:val="hybridMultilevel"/>',
      );
      for (final (level, definition) in list.levels.indexed) {
        final left = definition.indentLeft ?? 36.0 * (level + 1);
        final font = definition.font == null
            ? ''
            : escapeXmlAttribute(stripInvalidXmlChars(definition.font!));
        out.write(
          '<w:lvl w:ilvl="$level">'
          '<w:start w:val="${definition.start.clamp(0, 32767)}"/>'
          '<w:numFmt w:val="${definition.format.name}"/>'
          '<w:lvlText w:val="${escapeXmlAttribute(stripInvalidXmlChars(definition.text))}"/>'
          '<w:lvlJc w:val="left"/><w:pPr><w:ind w:left="${_twips(left)}" '
          'w:hanging="${_twips(definition.hanging)}"/></w:pPr>'
          '${font.isEmpty ? '' : '<w:rPr><w:rFonts w:ascii="$font" w:hAnsi="$font" w:hint="default"/></w:rPr>'}'
          '</w:lvl>',
        );
      }
      out.write('</w:abstractNum>');
    }
    for (var index = 0; index < spec.lists.length; index++) {
      out.write(
        '<w:num w:numId="${index + 1}">'
        '<w:abstractNumId w:val="$index"/></w:num>',
      );
    }
    out.write('</w:numbering>');
    return out.toString();
  }

  String _settings() {
    final notes = [
      if (_footnotes.isNotEmpty)
        '<w:footnotePr><w:footnote w:id="-1"/><w:footnote w:id="0"/>'
            '</w:footnotePr>',
      if (_endnotes.isNotEmpty)
        '<w:endnotePr><w:endnote w:id="-1"/><w:endnote w:id="0"/>'
            '</w:endnotePr>',
    ].join();
    return '$_declaration<w:settings xmlns:w="${Namespaces.w}">'
        '<w:defaultTabStop w:val="${_twips(spec.defaultTabStop)}"/>'
        '${spec.differentOddEven ? '<w:evenAndOddHeaders/>' : ''}'
        '<w:characterSpacingControl w:val="doNotCompress"/>$notes'
        '<w:compat><w:compatSetting w:name="compatibilityMode" '
        'w:uri="http://schemas.microsoft.com/office/word" w:val="15"/>'
        '</w:compat></w:settings>';
  }

  String _contentTypes() {
    final out = StringBuffer(
      '$_declaration<Types xmlns="${Namespaces.contentTypes}">'
      '<Default Extension="rels" '
      'ContentType="application/vnd.openxmlformats-package.relationships+xml"/>'
      '<Default Extension="xml" ContentType="application/xml"/>',
    );
    for (final extension in _mediaExtensions) {
      final mime = switch (extension) {
        'emf' => 'image/x-emf',
        'wmf' => 'image/x-wmf',
        _ => 'image/$extension',
      };
      out.write('<Default Extension="$extension" ContentType="$mime"/>');
    }
    _overrides.forEach((name, type) {
      out.write('<Override PartName="$name" ContentType="$type"/>');
    });
    out.write('</Types>');
    return out.toString();
  }

  static int _twips(double points) =>
      points.isFinite ? (points * 20).round().clamp(-63360, 63360) : 0;

  static String? _hex(String? value) {
    if (value == null) return null;
    final clean = (value.startsWith('#') ? value.substring(1) : value)
        .toUpperCase();
    return RegExp(r'^[0-9A-F]{6}$').hasMatch(clean) ? clean : null;
  }
}

typedef _Relationship = ({
  String id,
  String type,
  String target,
  bool external,
});

/// A package part and the relationships it collects.
class _Part {
  _Part(DocxBuilder builder, this.name, {bool shared = false})
    : _relationships = shared
          ? builder._sharedRelationships.putIfAbsent(name, () => [])
          : [];

  final String name;
  final List<_Relationship> _relationships;

  /// Path relative to the main document's folder.
  String get target => name.substring('word/'.length);

  String relate(String type, String target, {bool external = false}) {
    for (final relationship in _relationships) {
      if (relationship.type == type && relationship.target == target) {
        return relationship.id;
      }
    }
    final id = 'rId${_relationships.length + 1}';
    _relationships.add((
      id: id,
      type: type,
      target: target,
      external: external,
    ));
    return id;
  }

  String? xml() {
    if (_relationships.isEmpty) return null;
    final out = StringBuffer(
      '$_declaration<Relationships xmlns="${Namespaces.packageRelationships}">',
    );
    for (final relationship in _relationships) {
      out.write(
        '<Relationship Id="${relationship.id}" Type="${relationship.type}" '
        'Target="${escapeXmlAttribute(relationship.target)}"'
        '${relationship.external ? ' TargetMode="External"' : ''}/>',
      );
    }
    out.write('</Relationships>');
    return out.toString();
  }
}
