import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/painting.dart' show EdgeInsets;
import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;

import '../document/document_codec.dart';
import '../docx/docx_builder.dart';
import '../docx/image_formats.dart';
import 'css.dart';
import 'html_guard.dart';

/// A page read into a document, and what was adjusted on the way.
typedef HtmlContent = ({DocumentSpec spec, Set<DocumentNotice> notices});

/// Reads untrusted HTML into a [DocumentSpec]. Nothing is fetched: pictures
/// come only from `data:` URIs and links only to the web, e-mail or bookmarks.
HtmlContent readHtml(String html) {
  final guarded = guardHtml(html);
  final reader = _Reader(StyleSheet.parse(guarded.styleSheets));
  if (guarded.dropped) reader.notices.add(DocumentNotice.contentNotImported);
  reader.read(html_parser.parse(guarded.html));
  return (spec: reader.spec, notices: reader.notices);
}

const monospaceFont = 'Courier New';

final _whitespace = RegExp(r'\s+');
final _inlineSpaces = RegExp(r'[ \t\f]+');
final _wordStarts = RegExp(r'(^|\s)(\S)');
final _zeroLength = RegExp(r'^0(\.0*)?([a-z]+)?$');

const _maxBlocks = 300000;
const _maxInlines = 2000000;
const _maxCells = 300000;
const _maxLists = 5000;
const _maxBookmarks = 10000;
const _maxTableDepth = 8;
const _maxColumns = 63;
const _maxPictureBytes = 32 * 1024 * 1024;
const _maxPicturesBytes = 256 * 1024 * 1024;
const _maxPicturePixels = 100000000;

/// Declarations applied to elements in all; legitimate pages stay far below.
const _maxStyleWork = 20000000;

/// Elements left out with their content; the embedded ones are reported.
const _skipped = {
  'head',
  'script',
  'style',
  'title',
  'meta',
  'link',
  'base',
  'template',
  'noscript',
  'noembed',
  'noframes',
  'frameset',
  'frame',
  'select',
  'option',
  'optgroup',
  'datalist',
  'textarea',
  'button',
  'input',
  'keygen',
  'progress',
  'meter',
  'map',
  'area',
  'source',
  'track',
  'param',
  'wbr',
  'iframe',
  'object',
  'embed',
  'applet',
  'svg',
  'math',
  'canvas',
  'video',
  'audio',
};
const _embedded = {
  'iframe',
  'object',
  'embed',
  'applet',
  'svg',
  'math',
  'canvas',
  'video',
  'audio',
};

/// Blocks whose content always makes a paragraph, even an empty one.
const _paragraphTags = {
  'p',
  'h1',
  'h2',
  'h3',
  'h4',
  'h5',
  'h6',
  'li',
  'dt',
  'dd',
  'pre',
  'listing',
  'plaintext',
  'caption',
  'figcaption',
  'summary',
  'legend',
  'address',
};
const _blockTags = {
  'html',
  'body',
  'div',
  'section',
  'article',
  'aside',
  'header',
  'footer',
  'nav',
  'main',
  'search',
  'blockquote',
  'center',
  'figure',
  'form',
  'fieldset',
  'details',
  'dialog',
  'dl',
  'hgroup',
  'menu',
  'dir',
  'ul',
  'ol',
  'table',
  'thead',
  'tbody',
  'tfoot',
  'tr',
  'td',
  'th',
  'colgroup',
};
const _listTags = {'ul', 'ol', 'menu', 'dir'};

enum _Kind { inline, block, paragraph, table, section, row, cell }

enum _WhiteSpace { normal, pre, preLine }

/// Computed style of an element: inherited text and paragraph formatting
/// plus the element's own box.
class _Style {
  String? font;
  double? size;
  bool? bold;
  bool? italic;
  bool? underline;
  bool? strike;
  bool? allCaps;
  bool? smallCaps;
  String? color;
  String? background;
  VerticalPosition? position;

  /// `lowercase` or `capitalize`; uppercase is [allCaps].
  String? transform;
  var whiteSpace = _WhiteSpace.normal;

  /// Inside `<pre>`: each line is a paragraph.
  var splitLines = false;
  ParagraphAlign? align;
  LineSpacing? lineSpacing;
  double? textIndent;
  double indentLeft = 0;
  double indentRight = 0;
  bool? rightToLeft;
  String? link;
  int? heading;
  _ListContext? list;
  _ListItem? item;
  int listLevel = -1;

  // The element's own.
  double? spaceBefore;
  double? spaceAfter;
  var breakBefore = false;
  var breakAfter = false;
  var hidden = false;
  String? display;
  String? width;
  String? height;
  String? fill;
  var border = false;
  CellAlign? verticalAlign;
  String? wordList;
  var wordListLabel = false;
  var tabs = 0;
  var comment = false;
  String? listStyle;
  double? marginLeft;

  RunFormat? _run;

  _Style inherit() => _Style()
    ..font = font
    ..size = size
    ..bold = bold
    ..italic = italic
    ..underline = underline
    ..strike = strike
    ..allCaps = allCaps
    ..smallCaps = smallCaps
    ..color = color
    ..background = background
    ..position = position
    ..transform = transform
    ..whiteSpace = whiteSpace
    ..splitLines = splitLines
    ..align = align
    ..lineSpacing = lineSpacing
    ..textIndent = textIndent
    ..indentLeft = indentLeft
    ..indentRight = indentRight
    ..rightToLeft = rightToLeft
    ..link = link
    ..heading = heading
    ..list = list
    ..item = item
    ..listLevel = listLevel;

  RunFormat get run => _run ??= RunFormat(
    font: font,
    size: size,
    bold: bold,
    italic: italic,
    underline: underline,
    strike: strike,
    allCaps: allCaps,
    smallCaps: smallCaps,
    color: color,
    background: background,
    position: position,
  );
}

/// Margins and paddings an element sets for itself, in points.
class _Box {
  double? marginTop;
  double? marginRight;
  double? marginBottom;
  double? marginLeft;
  double? paddingTop;
  double? paddingRight;
  double? paddingBottom;
  double? paddingLeft;
  String? background;
}

class _ListContext {
  _ListContext(this.level, this.format, {this.start = 1, this.bullet = '•'});

  final int level;
  final NumberFormat format;
  final String bullet;
  int start;
  int? numId;
}

class _ListItem {
  _ListItem(this.list, this.value);

  final _ListContext list;
  final int? value;
  var used = false;
}

class _Paragraph {
  _Paragraph(this.block);

  /// Style of the block the paragraph belongs to.
  final _Style block;
  final inlines = <InlineSpec>[];
  ListRef? list;
  String? wordList;
  String? wordListLabel;
  double? indentLeft;
  double? firstLine;

  var atLineStart = true;
  var pendingSpace = false;
  _Style? spaceStyle;
  _Style? runStyle;
  final run = StringBuffer();
  String? linkTarget;
  List<InlineSpec>? linkChildren;

  /// Only spaces so far; such paragraphs are empty lines.
  var blank = true;
}

class _Frame {
  _Frame(this.element, this.style, this.kind, this.produced)
    : nodes = element.nodes;

  final dom.Element element;
  final _Style style;
  final _Kind kind;

  /// Blocks made before the element started.
  final int produced;
  final List<dom.Node> nodes;
  var next = 0;
  _TableBuilder? table;
  ({List<BlockSpec> sink, List<InlineSpec>? last})? saved;
}

class _Cell {
  _Cell(this.colspan, this.rowspan, this.style);

  final int colspan;
  final int rowspan;
  final _Style style;
  final blocks = <BlockSpec>[];
}

class _Row {
  _Row(this.header, this.style);

  final bool header;
  final _Style style;
  final cells = <_Cell>[];
}

class _TableBuilder {
  _TableBuilder(this.style, {required this.bordered});

  final _Style style;
  bool bordered;
  final rows = <_Row>[];
  final columns = <String?>[];
  var header = false;
}

class _Reader {
  _Reader(this.sheet);

  final StyleSheet sheet;
  final spec = DocumentSpec();
  final notices = <DocumentNotice>{};

  final _targets = <String>{};
  final _frames = <_Frame>[];
  final _tables = <_TableBuilder?>[];
  final _pendingBookmarks = <String>[];
  final _sharedLists = <String, _ListContext>{};
  final _wordLists = <String, int>{};

  /// Where blocks go: the body, or the cell being read.
  late List<BlockSpec> _sink = spec.body;
  _Paragraph? _paragraph;
  List<InlineSpec>? _lastInlines;
  var _produced = 0;
  var _inlines = 0;
  var _cells = 0;
  var _bookmarks = 0;
  var _pictureBytes = 0;
  var _cellDepth = 0;
  var _tableDepth = 0;
  var _styleWork = 0;
  double _textWidth = const PageSpec().textWidth;

  final _fonts = <String?, int>{};
  final _sizes = <double?, int>{};
  final _colors = <String?, int>{};
  final _spaceBefore = <double?, int>{};
  final _spaceAfter = <double?, int>{};
  final _lineSpacings = <String?, int>{};
  final _lineSpacingValues = <String, LineSpacing>{};

  void read(dom.Document document) {
    final root = document.documentElement;
    if (root == null) return;
    _scan(root);
    _page();
    final body = _Frame(root, _styleOf(root, 'html', _Style()), _Kind.block, 0);
    _frames.add(body);
    _walk();
    _closeParagraph();
    _defaults();
    _headingStyles(body.style);
  }

  // Before the walk: link targets and the language.

  void _scan(dom.Element root) {
    String? language = root.attributes['lang'] ?? root.attributes['xml:lang'];
    final stack = <dom.Element>[root];
    while (stack.isNotEmpty) {
      final element = stack.removeLast();
      final name = originalTagName(element.localName ?? '');
      if (name == 'a') {
        final href = element.attributes['href']?.trim();
        if (href != null && href.length > 1 && href.startsWith('#')) {
          _targets.add(href.substring(1));
        }
      } else if (name == 'body') {
        language ??= element.attributes['lang'];
      } else if (name == 'meta' &&
          element.attributes['http-equiv']?.toLowerCase() ==
              'content-language') {
        language ??= element.attributes['content'];
      }
      for (final node in element.nodes) {
        if (node is dom.Element) stack.add(node);
      }
    }
    spec.language = _languageTag(language);
  }

  static String? _languageTag(String? value) {
    if (value == null) return null;
    final parts = value.trim().replaceAll('_', '-').split(',').first.split('-');
    if (parts.isEmpty ||
        !RegExp(r'^[A-Za-z]{2,3}$').hasMatch(parts.first) ||
        parts.any((part) => !RegExp(r'^[A-Za-z0-9]{1,8}$').hasMatch(part))) {
      return null;
    }
    return [
      parts.first.toLowerCase(),
      for (final part in parts.skip(1).take(3))
        part.length == 2 ? part.toUpperCase() : part,
    ].join('-');
  }

  // Page setup from `@page`.

  void _page() {
    var page = spec.page;
    double? width;
    double? height;
    var landscape = false;
    var margins = page.margins;
    var header = page.headerDistance;
    var footer = page.footerDistance;
    for (final declarations in sheet.pages) {
      for (final declaration in declarations) {
        final value = declaration.value;
        switch (declaration.property) {
          case 'size':
            final size = _pageSize(value);
            if (size != null) {
              width = size.width;
              height = size.height;
            }
            landscape = value.toLowerCase().contains('landscape');
          case 'margin':
            final sides = _sides(value, 12, page.width);
            margins = EdgeInsets.fromLTRB(
              sides[3] ?? margins.left,
              sides[0] ?? margins.top,
              sides[1] ?? margins.right,
              sides[2] ?? margins.bottom,
            );
          case 'margin-top' ||
              'margin-right' ||
              'margin-bottom' ||
              'margin-left':
            final length = cssLength(value);
            if (length == null) break;
            margins = switch (declaration.property) {
              'margin-top' => margins.copyWith(top: length),
              'margin-right' => margins.copyWith(right: length),
              'margin-bottom' => margins.copyWith(bottom: length),
              _ => margins.copyWith(left: length),
            };
          case 'mso-header-margin':
            header = cssLength(value) ?? header;
          case 'mso-footer-margin':
            footer = cssLength(value) ?? footer;
        }
      }
    }
    width = (width ?? page.width).clamp(72, 1584).toDouble();
    height = (height ?? page.height).clamp(72, 1584).toDouble();
    if (landscape && width < height) {
      final swap = width;
      width = height;
      height = swap;
    }
    double side(double value, double length) =>
        value.isFinite ? value.clamp(0, length * 0.4).toDouble() : 0;
    page = PageSpec(
      width: width,
      height: height,
      margins: EdgeInsets.fromLTRB(
        side(margins.left, width),
        side(margins.top, height),
        side(margins.right, width),
        side(margins.bottom, height),
      ),
      headerDistance: side(header, height),
      footerDistance: side(footer, height),
    );
    spec.page = page;
    _textWidth = page.textWidth;
  }

  static ({double width, double height})? _pageSize(String value) {
    final words = value.toLowerCase().split(_whitespace);
    for (final word in words) {
      final size = switch (word) {
        'a3' => (width: 841.9, height: 1190.55),
        'a4' => (width: 595.3, height: 841.9),
        'a5' => (width: 419.55, height: 595.3),
        'b4' => (width: 708.65, height: 1000.6),
        'b5' => (width: 498.9, height: 708.65),
        'letter' => (width: 612.0, height: 792.0),
        'legal' => (width: 612.0, height: 1008.0),
        'ledger' => (width: 792.0, height: 1224.0),
        _ => null,
      };
      if (size != null) return size;
    }
    final lengths = [
      for (final word in words) ?cssLength(word),
    ].where((length) => length > 0).toList();
    if (lengths.isEmpty) return null;
    return (
      width: lengths.first,
      height: lengths.length > 1 ? lengths[1] : lengths.first,
    );
  }

  // The walk

  void _walk() {
    while (_frames.isNotEmpty) {
      final frame = _frames.last;
      if (frame.next >= frame.nodes.length) {
        _frames.removeLast();
        _exit(frame);
        continue;
      }
      final node = frame.nodes[frame.next++];
      if (node is dom.Text) {
        _text(node.data, frame.style);
      } else if (node is dom.Element) {
        final child = _enter(node, frame.style);
        if (child != null) _frames.add(child);
      }
    }
  }

  _Frame? _enter(dom.Element element, _Style parent) {
    final name = originalTagName(element.localName ?? '');
    if (_skipped.contains(name)) {
      if (_embedded.contains(name)) {
        notices.add(DocumentNotice.contentNotImported);
      }
      return null;
    }
    final style = _styleOf(element, name, parent);
    if (style.hidden || element.attributes.containsKey('hidden')) {
      if (style.breakBefore || style.breakAfter) _pageBreak();
      return null;
    }
    if (style.comment) {
      notices.add(DocumentNotice.commentsHidden);
      return null;
    }
    if (style.wordListLabel) {
      (_paragraph ?? _open(_blockStyle())).wordListLabel = _textOf(element);
      return null;
    }
    switch (name) {
      case 'br':
        _bookmarksOf(element, name);
        _lineBreak(style);
        return null;
      case 'img':
        _bookmarksOf(element, name);
        _image(element, style);
        return null;
      case 'hr':
        _closeParagraph();
        if (style.breakBefore || style.breakAfter) _pageBreak();
        return null;
      case 'col':
        _column(element, style);
        return null;
    }
    if (style.tabs > 0) {
      _bookmarksOf(element, name);
      _preserved('\t' * style.tabs, style);
      return null;
    }
    final kind = _kindOf(name, style);
    if (kind == _Kind.inline) {
      _bookmarksOf(element, name);
      return _Frame(element, style, kind, _produced);
    }
    _closeParagraph();
    if (style.breakBefore) _pageBreak();
    _bookmarksOf(element, name);
    final frame = _Frame(element, style, kind, _produced);
    switch (kind) {
      case _Kind.table:
        final table = _TableBuilder(style, bordered: style.border);
        frame.table = table;
        _tables.add(table);
        _tableDepth++;
      case _Kind.section:
        _tables.last?.header = name == 'thead';
      case _Kind.row:
        _tables.last?.rows.add(_Row(_tables.last?.header ?? false, style));
      case _Kind.cell:
        _startCell(frame, name);
      case _Kind.inline || _Kind.block || _Kind.paragraph:
        if (name == 'table') _tables.add(null);
    }
    return frame;
  }

  _Kind _kindOf(String name, _Style style) {
    final display = style.display;
    final tableNested = _tables.isNotEmpty && _tables.last != null;
    switch (name) {
      case 'table':
        return _tableDepth < _maxTableDepth ? _Kind.table : _Kind.block;
      case 'thead' || 'tbody' || 'tfoot':
        return tableNested ? _Kind.section : _Kind.block;
      case 'tr':
        return tableNested ? _Kind.row : _Kind.block;
      case 'td' || 'th':
        return tableNested ? _Kind.cell : _Kind.paragraph;
      case 'colgroup':
        return _Kind.block;
    }
    if (display == 'inline' || display == 'inline-block') {
      if (!_listTags.contains(name) && name != 'li') return _Kind.inline;
    }
    if (_paragraphTags.contains(name)) return _Kind.paragraph;
    if (_blockTags.contains(name)) return _Kind.block;
    if (display == 'block' || display == 'list-item' || display == 'flex') {
      return _Kind.block;
    }
    return _Kind.inline;
  }

  void _exit(_Frame frame) {
    switch (frame.kind) {
      case _Kind.inline:
        return;
      case _Kind.paragraph:
        if (_paragraph != null) {
          _closeParagraph();
        } else if (_produced == frame.produced) {
          _open(frame.style);
          _closeParagraph();
        }
      case _Kind.block:
        _closeParagraph();
        if (frame.element.localName == 'table') _tables.removeLast();
      case _Kind.table:
        _closeParagraph();
        _tables.removeLast();
        _tableDepth--;
        final table = _buildTable(frame.table!);
        if (table != null) _addBlock(table);
      case _Kind.section:
        _tables.last?.header = false;
      case _Kind.row:
        break;
      case _Kind.cell:
        _closeParagraph();
        final saved = frame.saved!;
        _sink = saved.sink;
        _lastInlines = saved.last;
        _cellDepth--;
    }
    if (frame.style.breakAfter) {
      // An empty element that only breaks the page is a line of its own, as
      // the editor makes them.
      _pageBreak(
        own: frame.kind != _Kind.inline && _produced == frame.produced,
      );
    }
  }

  /// Style of the innermost block, which sets the paragraph's format.
  _Style _blockStyle() {
    for (var index = _frames.length - 1; index >= 0; index--) {
      if (_frames[index].kind != _Kind.inline) return _frames[index].style;
    }
    return _frames.isEmpty ? _Style() : _frames.first.style;
  }

  // Styles

  _Style _styleOf(dom.Element element, String name, _Style parent) {
    final style = parent.inherit();
    final parentSize = parent.size ?? 12;
    final box = _Box();
    final attributes = element.attributes;
    switch (name) {
      case 'b' || 'strong':
        style.bold = true;
      case 'i' || 'em' || 'cite' || 'dfn' || 'var' || 'address':
        style.italic = true;
      case 'u' || 'ins':
        style.underline = true;
      case 's' || 'strike' || 'del':
        style.strike = true;
      case 'sup':
        style.position = VerticalPosition.superscript;
      case 'sub':
        style.position = VerticalPosition.subscript;
      case 'small':
        style.size = parentSize / 1.2;
      case 'big':
        style.size = parentSize * 1.2;
      case 'code' || 'kbd' || 'samp' || 'tt':
        style.font = monospaceFont;
      case 'pre' || 'listing' || 'plaintext':
        style
          ..font = monospaceFont
          ..whiteSpace = _WhiteSpace.pre
          ..splitLines = true
          ..spaceBefore = 0
          ..spaceAfter = 0;
      case 'mark':
        box.background = 'FFFF00';
      case 'center':
        style.align = ParagraphAlign.center;
      case 'th':
        style
          ..bold = true
          ..align = ParagraphAlign.center;
      case 'caption':
        style.align = ParagraphAlign.center;
      case 'blockquote' || 'dd':
        box.marginLeft = 36;
      case 'h1' || 'h2' || 'h3' || 'h4' || 'h5' || 'h6':
        // The heading style sets the size unless the page does.
        style
          ..heading = int.parse(name.substring(1))
          ..size = null;
      case 'a' when attributes.containsKey('href'):
        style.link = _linkOf(attributes['href']!);
        // Links have their own look in browsers; Word's hyperlink style gives
        // it unless the page styles the link.
        if (style.link != null) {
          style
            ..color = null
            ..underline = null;
        }
      case 'font':
        if (attributes['face'] case final face?) {
          style.font = cssFontFamily(face) ?? style.font;
        }
        if (attributes['size'] case final size?) {
          style.size = legacyFontSize(size) ?? style.size;
        }
        if (attributes['color'] case final color?) {
          style.color = attributeColor(color) ?? style.color;
        }
    }
    if (const {'td', 'th', 'caption'}.contains(name)) {
      style
        ..indentLeft = 0
        ..indentRight = 0
        ..textIndent = null
        ..list = null
        ..item = null
        ..listLevel = -1
        ..heading = null
        ..splitLines = false;
    }

    if (attributes['align'] case final align?) {
      final value = _alignment(align);
      if (value != null && name != 'table' && name != 'img') {
        style.align = value;
      }
    }
    if (attributes['bgcolor'] case final color?) {
      box.background = attributeColor(color);
    }
    if (attributes['width'] case final width?) style.width = width;
    if (attributes['height'] case final height?) style.height = height;
    if (attributes['valign'] case final align?) {
      style.verticalAlign = _cellAlign(align);
    }
    if (attributes['dir'] case final direction?) {
      style.rightToLeft = direction.toLowerCase() == 'rtl';
    }
    if (attributes['border'] case final border? when name == 'table') {
      style.border = border.trim() != '0';
    }

    final classes = {
      for (final name in (attributes['class'] ?? '').split(_whitespace))
        if (name.isNotEmpty) name.toLowerCase(),
    };
    if (classes.contains('msocomanchor') ||
        classes.contains('msocommentreference')) {
      style.comment = true;
    }
    final rules = sheet.rulesFor(
      name,
      classes,
      attributes['id']?.toLowerCase(),
    );
    final inline = attributes['style'] == null
        ? const <CssDeclaration>[]
        : parseDeclarations(attributes['style']!);
    _styleWork += inline.length + rules.length;
    for (final rule in rules) {
      _styleWork += rule.declarations.length;
    }
    if (_styleWork > _maxStyleWork) {
      throw const FormatException('The page\'s styles are too complex.');
    }
    for (final important in [false, true]) {
      for (final rule in rules) {
        for (final declaration in rule.declarations) {
          if (declaration.important == important) {
            _apply(style, box, declaration, parentSize);
          }
        }
      }
      for (final declaration in inline) {
        if (declaration.important == important) {
          _apply(style, box, declaration, parentSize);
        }
      }
    }

    if (_listTags.contains(name)) {
      _startList(style, name, attributes, classes);
    } else if (name == 'li') {
      style.list ??= _ListContext(0, NumberFormat.bullet);
      style.item = _ListItem(
        style.list!,
        int.tryParse(attributes['value'] ?? ''),
      );
    }

    final inlineBox =
        !_paragraphTags.contains(name) &&
        !_blockTags.contains(name) &&
        style.display != 'block';
    if (inlineBox) {
      if (box.background != null) style.background = box.background;
    } else if (const {'td', 'th', 'tr', 'table'}.contains(name)) {
      style
        ..fill = box.background
        ..marginLeft = box.marginLeft;
    } else if (name != 'html' && name != 'body' && !_listTags.contains(name)) {
      style
        ..indentLeft =
            (style.indentLeft + (box.marginLeft ?? 0) + (box.paddingLeft ?? 0))
                .clamp(-72, 720)
                .toDouble()
        ..indentRight =
            (style.indentRight +
                    (box.marginRight ?? 0) +
                    (box.paddingRight ?? 0))
                .clamp(-72, 720)
                .toDouble();
      final before = _sum(box.marginTop, box.paddingTop);
      final after = _sum(box.marginBottom, box.paddingBottom);
      if (before != null) style.spaceBefore = before.clamp(0, 1584).toDouble();
      if (after != null) style.spaceAfter = after.clamp(0, 1584).toDouble();
    }
    return style;
  }

  static double? _sum(double? a, double? b) =>
      a == null && b == null ? null : (a ?? 0) + (b ?? 0);

  void _apply(_Style s, _Box box, CssDeclaration declaration, double parent) {
    final value = declaration.value;
    final lower = value.toLowerCase();
    final em = s.size ?? parent;
    double? length(String text) =>
        cssLength(text, fontSize: em, percentOf: _textWidth);
    switch (declaration.property) {
      case 'font-family':
        s.font = cssFontFamily(value) ?? s.font;
      case 'font-size':
        s.size = cssFontSize(value, parent) ?? s.size;
      case 'font-weight':
        s.bold = _bold(lower) ?? s.bold;
      case 'font-style':
        if (lower == 'italic' || lower == 'oblique') s.italic = true;
        if (lower == 'normal') s.italic = false;
      case 'font-variant' || 'font-variant-caps':
        if (lower.contains('small-caps')) s.smallCaps = true;
        if (lower == 'normal') s.smallCaps = false;
      case 'font':
        _font(s, value, parent);
      case 'text-decoration' || 'text-decoration-line':
        if (lower.contains('none')) {
          s
            ..underline = false
            ..strike = false;
        }
        if (lower.contains('underline')) s.underline = true;
        if (lower.contains('line-through')) s.strike = true;
      case 'color':
        s.color = cssColor(value) ?? s.color;
      case 'background' || 'background-color' || 'mso-highlight':
        for (final part in splitCss(value, 0x20)) {
          final color = cssColor(part);
          if (color != null) {
            box.background = color;
            break;
          }
        }
      case 'vertical-align':
        switch (lower) {
          case 'super':
            s.position = VerticalPosition.superscript;
          case 'sub':
            s.position = VerticalPosition.subscript;
          case 'baseline':
            s.position = null;
          case 'top' || 'middle' || 'bottom':
            s.verticalAlign = _cellAlign(lower);
        }
      case 'text-transform':
        switch (lower) {
          case 'uppercase':
            s
              ..allCaps = true
              ..transform = null;
          case 'lowercase' || 'capitalize':
            s
              ..allCaps = false
              ..transform = lower;
          case 'none':
            s
              ..allCaps = false
              ..transform = null;
        }
      case 'text-align':
        s.align = _alignment(lower) ?? s.align;
      case 'text-indent':
        s.textIndent =
            length(value)?.clamp(-720, 720).toDouble() ?? s.textIndent;
      case 'line-height':
        s.lineSpacing = _lineHeight(lower, em);
      case 'margin' || 'padding':
        final sides = _sides(value, em, _textWidth);
        if (declaration.property == 'margin') {
          box
            ..marginTop = sides[0] ?? box.marginTop
            ..marginRight = sides[1] ?? box.marginRight
            ..marginBottom = sides[2] ?? box.marginBottom
            ..marginLeft = sides[3] ?? box.marginLeft;
        } else {
          box
            ..paddingTop = sides[0] ?? box.paddingTop
            ..paddingRight = sides[1] ?? box.paddingRight
            ..paddingBottom = sides[2] ?? box.paddingBottom
            ..paddingLeft = sides[3] ?? box.paddingLeft;
        }
      case 'margin-top':
        box.marginTop = length(value) ?? box.marginTop;
      case 'margin-right':
        box.marginRight = length(value) ?? box.marginRight;
      case 'margin-bottom':
        box.marginBottom = length(value) ?? box.marginBottom;
      case 'margin-left':
        box.marginLeft = length(value) ?? box.marginLeft;
      case 'padding-top':
        box.paddingTop = length(value) ?? box.paddingTop;
      case 'padding-right':
        box.paddingRight = length(value) ?? box.paddingRight;
      case 'padding-bottom':
        box.paddingBottom = length(value) ?? box.paddingBottom;
      case 'padding-left':
        box.paddingLeft = length(value) ?? box.paddingLeft;
      case 'page-break-before' || 'break-before':
        s.breakBefore = _isPageBreak(lower);
      case 'page-break-after' || 'break-after':
        s.breakAfter = _isPageBreak(lower);
      case 'display':
        s.display = lower;
        if (lower == 'none') s.hidden = true;
      case 'mso-hide':
        if (lower == 'all') s.hidden = true;
      case 'white-space':
        s.whiteSpace = switch (lower) {
          'pre' || 'pre-wrap' || 'break-spaces' => _WhiteSpace.pre,
          'pre-line' => _WhiteSpace.preLine,
          'normal' || 'nowrap' => _WhiteSpace.normal,
          _ => s.whiteSpace,
        };
        if (s.whiteSpace == _WhiteSpace.normal) s.splitLines = false;
      case 'width':
        s.width = value;
      case 'height':
        s.height = value;
      case 'direction':
        if (lower == 'rtl' || lower == 'ltr') s.rightToLeft = lower == 'rtl';
      case 'mso-list':
        if (lower == 'ignore') {
          s.wordListLabel = true;
        } else if (lower.contains('lfo')) {
          s.wordList = lower;
        }
      case 'mso-tab-count':
        s.tabs = (int.tryParse(value) ?? 0).clamp(0, 16);
      case 'mso-element':
        if (lower.startsWith('comment')) s.comment = true;
      case 'list-style-type' || 'list-style':
        s.listStyle = lower;
      default:
        if (declaration.property.startsWith('border') ||
            declaration.property == 'mso-border-alt') {
          final visible = _visibleBorder(declaration.property, lower);
          if (visible != null) s.border = visible;
        }
    }
  }

  static bool? _bold(String value) => switch (value) {
    'bold' || 'bolder' => true,
    'normal' || 'lighter' => false,
    _ => int.tryParse(value) == null ? null : int.parse(value) >= 600,
  };

  static bool _isPageBreak(String value) => const {
    'always',
    'page',
    'left',
    'right',
    'recto',
    'verso',
  }.contains(value);

  static ParagraphAlign? _alignment(String value) =>
      switch (value.trim().toLowerCase()) {
        'center' || 'middle' => ParagraphAlign.center,
        'right' || 'end' => ParagraphAlign.right,
        'justify' => ParagraphAlign.justify,
        'left' || 'start' => ParagraphAlign.left,
        _ => null,
      };

  static CellAlign? _cellAlign(String value) =>
      switch (value.trim().toLowerCase()) {
        'top' => CellAlign.top,
        'middle' || 'center' => CellAlign.center,
        'bottom' => CellAlign.bottom,
        _ => null,
      };

  static LineSpacing? _lineHeight(String value, double fontSize) {
    if (value == 'normal') return null;
    final number = double.tryParse(value);
    if (number != null) {
      return number > 0
          ? LineSpacing.multiple(number.clamp(0.5, 10).toDouble())
          : null;
    }
    if (value.endsWith('%')) {
      final percent = double.tryParse(value.substring(0, value.length - 1));
      return percent == null || percent <= 0
          ? null
          : LineSpacing.multiple((percent / 100).clamp(0.5, 10).toDouble());
    }
    final points = cssLength(value, fontSize: fontSize);
    return points == null || points <= 0
        ? null
        : LineSpacing.atLeast(points.clamp(1, 1584).toDouble());
  }

  /// Top, right, bottom and left of a `margin` or `padding` shorthand.
  static List<double?> _sides(String value, double em, double width) {
    final parts = value.trim().split(_whitespace);
    final lengths = [
      for (final part in parts.take(4))
        cssLength(part, fontSize: em, percentOf: width),
    ];
    return switch (lengths.length) {
      1 => [lengths[0], lengths[0], lengths[0], lengths[0]],
      2 => [lengths[0], lengths[1], lengths[0], lengths[1]],
      3 => [lengths[0], lengths[1], lengths[2], lengths[1]],
      _ => [lengths[0], lengths[1], lengths[2], lengths[3]],
    };
  }

  static final _fontShorthand = RegExp(
    r'^((?:[a-z-]+\s+)*?)'
    r'([\d.]+[a-z%]*|xx-small|x-small|small|medium|large|x-large|xx-large|smaller|larger)'
    r'(?:\s*/\s*(\S+))?\s+(.+)$',
  );

  void _font(_Style s, String value, double parent) {
    final match = _fontShorthand.firstMatch(value.trim().toLowerCase());
    if (match == null) return;
    for (final word in match[1]!.split(_whitespace)) {
      if (word == 'italic' || word == 'oblique') s.italic = true;
      if (word == 'small-caps') s.smallCaps = true;
      final bold = _bold(word);
      if (bold != null) s.bold = bold;
    }
    s.size = cssFontSize(match[2]!, parent) ?? s.size;
    if (match[3] != null) {
      s.lineSpacing = _lineHeight(match[3]!, s.size ?? parent);
    }
    final familyStart = value.toLowerCase().lastIndexOf(match[4]!);
    s.font =
        cssFontFamily(
          familyStart < 0 ? match[4]! : value.substring(familyStart),
        ) ??
        s.font;
  }

  /// Whether a border declaration draws a line; null when it says nothing.
  static bool? _visibleBorder(String property, String value) {
    if (const {
      'border-collapse',
      'border-spacing',
      'border-radius',
      'border-image',
    }.contains(property)) {
      return null;
    }
    final words = value.split(_whitespace);
    if (words.contains('none') || words.contains('hidden')) return false;
    final styled = words.any(
      (word) => const {
        'solid',
        'dotted',
        'dashed',
        'double',
        'groove',
        'ridge',
        'inset',
        'outset',
      }.contains(word),
    );
    if (!styled) return null;
    return !words.any((word) => _zeroLength.hasMatch(word));
  }

  // Lists

  void _startList(
    _Style style,
    String name,
    Map<Object, String> attributes,
    Set<String> classes,
  ) {
    var level = math.min(style.listLevel + 1, 8);
    String? shared;
    for (final className in classes) {
      final match = RegExp(r'^lst-kix_(\w+)-(\d)$').firstMatch(className);
      if (match != null) {
        level = int.parse(match[2]!).clamp(0, 8);
        shared = 'g:${match[1]}:$level';
        break;
      }
    }
    style.listLevel = level;
    final ordered = name == 'ol';
    // Google Docs hides the markers and draws its own: the tag tells the kind.
    final type = shared == null
        ? style.listStyle ?? attributes['type']
        : attributes['type'];
    final format = _numberFormat(type, ordered: ordered);
    final context = _ListContext(
      level,
      format,
      start: ordered ? int.tryParse(attributes['start'] ?? '') ?? 1 : 1,
      bullet: switch (type?.split(_whitespace).first) {
        'circle' => '◦',
        'square' => '▪',
        _ => '•',
      },
    );
    style.list = shared == null
        ? context
        : _sharedLists.putIfAbsent('$shared:${format.name}', () => context);
  }

  static NumberFormat _numberFormat(String? type, {required bool ordered}) {
    final word = type?.trim().split(_whitespace).first;
    return switch (word) {
      'none' => NumberFormat.none,
      'disc' || 'circle' || 'square' => NumberFormat.bullet,
      'a' || 'lower-alpha' || 'lower-latin' => NumberFormat.lowerLetter,
      'A' || 'upper-alpha' || 'upper-latin' => NumberFormat.upperLetter,
      'i' || 'lower-roman' => NumberFormat.lowerRoman,
      'I' || 'upper-roman' => NumberFormat.upperRoman,
      'decimal-leading-zero' => NumberFormat.decimalZero,
      '1' || 'decimal' => NumberFormat.decimal,
      _ => ordered ? NumberFormat.decimal : NumberFormat.bullet,
    };
  }

  ListRef? _listRef(_ListItem item) {
    final list = item.list;
    if (list.format == NumberFormat.none) return null;
    if (item.value != null && list.format != NumberFormat.bullet) {
      list
        ..numId = null
        ..start = item.value!;
    }
    list.numId ??= _addList(
      _listSpec(list.level, list.format, list.start, list.bullet),
    );
    return ListRef(list.numId!, list.level);
  }

  int _addList(ListSpec list) {
    if (spec.lists.length >= _maxLists) return spec.lists.length;
    return spec.addList(list);
  }

  static ListSpec _listSpec(
    int level,
    NumberFormat format,
    int start,
    String bullet,
  ) {
    final bullets = format == NumberFormat.bullet;
    return ListSpec([
      for (var index = 0; index < 9; index++)
        ListLevelSpec(
          format: index == level
              ? format
              : bullets
              ? NumberFormat.bullet
              : NumberFormat.decimal,
          text: bullets
              ? (index == level ? bullet : const ['•', '◦', '▪'][index % 3])
              : '%${index + 1}.',
          start: index == level ? start.clamp(0, 32767) : 1,
        ),
    ]);
  }

  /// Word's lists in HTML are paragraphs with `mso-list: l0 level1 lfo1`,
  /// defined by `@list` rules; the bullet text tells the kind when they're
  /// missing.
  ListRef? _wordListRef(String value, String? label) {
    final match = RegExp(r'(l\d+)\s+level(\d+)\s+(lfo\d+)').firstMatch(value);
    if (match == null) return null;
    final level = (int.parse(match[2]!) - 1).clamp(0, 8);
    final numId = _wordLists[match[3]!] ??= _addList(
      ListSpec([
        for (var index = 0; index < 9; index++)
          _wordLevel(
            sheet.listLevels['${match[1]}:level${index + 1}'],
            index,
            index == level ? label : null,
          ),
      ]),
    );
    return ListRef(numId, level);
  }

  static ListLevelSpec _wordLevel(
    List<CssDeclaration>? declarations,
    int level,
    String? label,
  ) {
    var format = NumberFormat.decimal;
    var start = 1;
    if (declarations == null) {
      final text = (label ?? '').replaceAll(_whitespace, '');
      format = RegExp(r'^\(?([0-9]+|[a-zA-Z]{1,4})[.)]$').hasMatch(text)
          ? NumberFormat.decimal
          : NumberFormat.bullet;
    }
    for (final declaration in declarations ?? const <CssDeclaration>[]) {
      switch (declaration.property) {
        case 'mso-level-number-format':
          format = switch (declaration.value.toLowerCase()) {
            'bullet' => NumberFormat.bullet,
            'alpha-lower' => NumberFormat.lowerLetter,
            'alpha-upper' => NumberFormat.upperLetter,
            'roman-lower' => NumberFormat.lowerRoman,
            'roman-upper' => NumberFormat.upperRoman,
            'arabic-leading-zero' => NumberFormat.decimalZero,
            'none' => NumberFormat.none,
            _ => NumberFormat.decimal,
          };
        case 'mso-level-start-at':
          start = int.tryParse(declaration.value) ?? 1;
      }
    }
    return ListLevelSpec(
      format: format,
      text: format == NumberFormat.bullet
          ? const ['•', '◦', '▪'][level % 3]
          : '%${level + 1}.',
      start: start.clamp(0, 32767),
    );
  }

  // Paragraphs

  _Paragraph _open(_Style block) {
    final paragraph = _Paragraph(block);
    final item = block.item;
    if (item != null) {
      final ListRef? list;
      if (item.used) {
        list = null;
      } else {
        item.used = true;
        list = _listRef(item);
      }
      paragraph
        ..list = list
        ..indentLeft = list == null ? 36.0 * (item.list.level + 1) : null;
    } else {
      paragraph
        ..indentLeft = block.indentLeft == 0 ? null : block.indentLeft
        ..firstLine = block.textIndent
        ..wordList = block.wordList;
    }
    for (final name in _pendingBookmarks) {
      paragraph.inlines.add(BookmarkSpec(name));
    }
    _pendingBookmarks.clear();
    return _paragraph = paragraph;
  }

  void _closeParagraph() {
    final paragraph = _paragraph;
    if (paragraph == null) return;
    _flush(paragraph);
    _paragraph = null;
    final inlines = paragraph.inlines;
    while (inlines.isNotEmpty &&
        inlines.last is BreakSpec &&
        (inlines.last as BreakSpec).kind == BreakKind.line) {
      inlines.removeLast();
    }
    if (paragraph.blank) {
      inlines.removeWhere((inline) => inline is TextSpec);
    }
    final block = paragraph.block;
    var list = paragraph.list;
    var indentLeft = paragraph.indentLeft;
    var firstLine = paragraph.firstLine;
    if (paragraph.wordList != null) {
      list = _wordListRef(paragraph.wordList!, paragraph.wordListLabel);
      if (list != null) {
        indentLeft = null;
        firstLine = null;
      }
    }
    if (block.heading == null && list == null && !block.splitLines) {
      _count(_spaceBefore, block.spaceBefore);
      _count(_spaceAfter, block.spaceAfter);
      final spacing = block.lineSpacing;
      final key = spacing == null
          ? null
          : '${spacing.rule.name}${spacing.value}';
      if (key != null) _lineSpacingValues[key] = spacing!;
      _count(_lineSpacings, key);
    }
    _addBlock(
      ParagraphSpec(
        inlines,
        heading: block.heading,
        format: ParagraphFormat(
          align: block.align,
          indentLeft: indentLeft,
          indentRight: block.indentRight == 0 ? null : block.indentRight,
          firstLine: firstLine,
          spaceBefore: block.spaceBefore,
          spaceAfter: block.spaceAfter,
          lineSpacing: block.lineSpacing,
          rightToLeft: block.rightToLeft,
          list: list,
        ),
      ),
    );
    _lastInlines = inlines;
  }

  void _addBlock(BlockSpec block) {
    _sink.add(block);
    if (++_produced > _maxBlocks) {
      throw DocumentProblemException(DocumentProblem.tooLarge);
    }
  }

  /// Ends the last paragraph with a page break, or adds a paragraph with only
  /// the break when [own] or when there's no paragraph to end.
  void _pageBreak({bool own = false}) {
    if (_cellDepth > 0) return;
    _closeParagraph();
    final last = _sink.lastOrNull;
    if (!own) {
      if (last == null) return;
      if (last is ParagraphSpec && identical(last.inlines, _lastInlines)) {
        final inlines = _lastInlines!;
        if (inlines.lastOrNull case BreakSpec(kind: BreakKind.page)) return;
        inlines.add(const BreakSpec(BreakKind.page));
        return;
      }
    }
    final inlines = <InlineSpec>[const BreakSpec(BreakKind.page)];
    _addBlock(ParagraphSpec(inlines));
    _lastInlines = inlines;
  }

  // Inline content

  void _text(String data, _Style style) {
    if (data.isEmpty) return;
    if (style.whiteSpace != _WhiteSpace.normal) {
      _preserved(data, style);
      return;
    }
    var start = 0;
    for (final match in _spaces.allMatches(data)) {
      if (match.start > start) _word(data.substring(start, match.start), style);
      _space(style);
      start = match.end;
    }
    if (start < data.length) _word(data.substring(start), style);
  }

  static final _spaces = RegExp(r'[ \t\n\r\f]+');

  void _word(String word, _Style style) {
    final paragraph = _paragraph ?? _open(_blockStyle());
    _flushSpace(paragraph);
    _append(paragraph, word, style);
  }

  void _space(_Style style) {
    final paragraph = _paragraph;
    if (paragraph == null || paragraph.atLineStart || paragraph.pendingSpace) {
      return;
    }
    paragraph
      ..pendingSpace = true
      ..spaceStyle = style;
  }

  void _flushSpace(_Paragraph paragraph) {
    if (!paragraph.pendingSpace) return;
    paragraph.pendingSpace = false;
    _append(paragraph, ' ', paragraph.spaceStyle!);
  }

  /// Text whose spaces and line breaks are kept.
  void _preserved(String data, _Style style) {
    final lines = data
        .replaceAll('\r\n', '\n')
        .replaceAll('\r', '\n')
        .split('\n');
    for (var index = 0; index < lines.length; index++) {
      if (index > 0) {
        if (style.splitLines) {
          if (_paragraph == null) {
            _open(_blockStyle());
          }
          _closeParagraph();
        } else {
          _lineBreak(style);
        }
      }
      var line = lines[index];
      if (style.whiteSpace == _WhiteSpace.preLine) {
        line = line.replaceAll(_inlineSpaces, ' ');
        final paragraph = _paragraph;
        if (paragraph == null || paragraph.atLineStart) line = line.trimLeft();
      }
      if (line.isEmpty) continue;
      final paragraph = _paragraph ?? _open(_blockStyle());
      _flushSpace(paragraph);
      _append(paragraph, line, style);
    }
  }

  void _append(_Paragraph paragraph, String text, _Style style) {
    if (paragraph.runStyle != style) {
      _flush(paragraph);
      paragraph.runStyle = style;
    }
    paragraph.run.write(switch (style.transform) {
      'lowercase' => text.toLowerCase(),
      'capitalize' => text.replaceAllMapped(
        _wordStarts,
        (match) => '${match[1]}${match[2]!.toUpperCase()}',
      ),
      _ => text,
    });
    paragraph.atLineStart = false;
    if (paragraph.blank && text.trim().isNotEmpty) {
      paragraph.blank = false;
    }
  }

  void _flush(_Paragraph paragraph) {
    final style = paragraph.runStyle;
    if (style == null || paragraph.run.isEmpty) return;
    final text = paragraph.run.toString();
    paragraph.run.clear();
    // Headings and code don't tell the page's text font.
    if (paragraph.block.heading == null && style.font != monospaceFont) {
      _count(_fonts, style.font, text.length);
      _count(_sizes, style.size, text.length);
      _count(_colors, style.color, text.length);
    }
    _add(paragraph, TextSpec(text, style.run), style.link);
  }

  void _add(_Paragraph paragraph, InlineSpec inline, String? link) {
    if (++_inlines > _maxInlines) {
      throw DocumentProblemException(DocumentProblem.tooLarge);
    }
    if (link == null) {
      paragraph
        ..linkChildren = null
        ..inlines.add(inline);
      return;
    }
    if (paragraph.linkChildren == null || paragraph.linkTarget != link) {
      final children = <InlineSpec>[];
      paragraph
        ..inlines.add(LinkSpec(link, children))
        ..linkTarget = link
        ..linkChildren = children;
    }
    paragraph.linkChildren!.add(inline);
  }

  /// Adds a picture, break or other non-text inline at the current position.
  void _inline(InlineSpec inline, _Style style) {
    final paragraph = _paragraph ?? _open(_blockStyle());
    _flushSpace(paragraph);
    _flush(paragraph);
    paragraph.runStyle = null;
    _add(paragraph, inline, style.link);
  }

  void _lineBreak(_Style style) {
    if ((style.breakBefore || style.breakAfter) && _cellDepth == 0) {
      _inline(const BreakSpec(BreakKind.page), style);
      _paragraph?.atLineStart = true;
      return;
    }
    final paragraph = _paragraph ?? _open(_blockStyle());
    paragraph.pendingSpace = false;
    _inline(const BreakSpec(BreakKind.line), style);
    paragraph.atLineStart = true;
  }

  void _bookmarksOf(dom.Element element, String name) {
    final id = element.attributes['id']?.trim();
    final anchor = name == 'a' ? element.attributes['name']?.trim() : null;
    for (final target in [anchor, id]) {
      if (target == null || target.isEmpty) continue;
      if (name != 'a' && !_targets.contains(target)) continue;
      if (++_bookmarks > _maxBookmarks) return;
      final paragraph = _paragraph;
      if (paragraph == null) {
        _pendingBookmarks.add(target);
      } else {
        _flush(paragraph);
        paragraph
          ..runStyle = null
          ..linkChildren = null
          ..inlines.add(BookmarkSpec(target));
      }
    }
  }

  static String? _linkOf(String href) {
    final target = href.trim();
    if (target.startsWith('#')) return target.length > 1 ? target : null;
    return safeLinkTarget(target);
  }

  /// Text of an element, such as Word's list bullet.
  static String _textOf(dom.Element element) {
    final out = StringBuffer();
    final stack = <dom.Node>[element];
    while (stack.isNotEmpty && out.length < 64) {
      final node = stack.removeLast();
      if (node is dom.Text) {
        out.write(node.data);
      } else {
        stack.addAll(node.nodes.reversed);
      }
    }
    return out.toString();
  }

  // Pictures

  void _image(dom.Element element, _Style style) {
    final alt = (element.attributes['alt'] ?? '').trim();
    final picture = _picture(element.attributes['src'] ?? '');
    if (picture == null) {
      notices.add(DocumentNotice.contentNotImported);
      if (alt.isNotEmpty) _text(alt, style);
      return;
    }
    final width = _size(style.width, _textWidth);
    final height = _size(style.height, spec.page.textHeight);
    _inline(
      ImageSpec(
        picture.bytes,
        picture.mime,
        width: width,
        height: height,
        description: alt.length > 1024 ? alt.substring(0, 1024) : alt,
      ),
      style,
    );
  }

  /// Points of a `width` or `height` attribute or property.
  static double? _size(String? value, double whole) {
    if (value == null) return null;
    final points = cssLength(value, percentOf: whole);
    return points != null && points > 0 ? math.min(points, 1584) : null;
  }

  ({Uint8List bytes, String mime})? _picture(String source) {
    final uri = source.trim();
    if (uri.length < 6 || uri.substring(0, 5).toLowerCase() != 'data:') {
      return null;
    }
    final comma = uri.indexOf(',');
    if (comma < 0 || uri.length - comma > _maxPictureBytes * 4 ~/ 3 + 4) {
      return null;
    }
    final header = uri.substring(5, comma).toLowerCase();
    if (!header.endsWith(';base64')) return null;
    final Uint8List bytes;
    try {
      bytes = base64.decode(
        base64.normalize(uri.substring(comma + 1).replaceAll(_whitespace, '')),
      );
    } on FormatException {
      return null;
    }
    final mime = _pictureType(bytes, header.split(';').first);
    if (mime == null || _pictureBytes + bytes.length > _maxPicturesBytes) {
      return null;
    }
    final pixels = imagePixelSize(bytes);
    if (pixels != null &&
        (pixels.width <= 0 ||
            pixels.height <= 0 ||
            pixels.width * pixels.height > _maxPicturePixels)) {
      return null;
    }
    _pictureBytes += bytes.length;
    return (bytes: bytes, mime: mime);
  }

  /// The picture's type from its first bytes; Word's own vector formats are
  /// taken on the declared type.
  static String? _pictureType(Uint8List bytes, String declared) {
    bool starts(List<int> prefix) =>
        bytes.length >= prefix.length &&
        Iterable.generate(
          prefix.length,
        ).every((index) => bytes[index] == prefix[index]);
    if (starts(const [0x89, 0x50, 0x4E, 0x47])) return 'image/png';
    if (starts(const [0xFF, 0xD8, 0xFF])) return 'image/jpeg';
    if (starts(const [0x47, 0x49, 0x46, 0x38])) return 'image/gif';
    if (starts(const [0x42, 0x4D])) return 'image/bmp';
    if (starts(const [0x49, 0x49, 0x2A, 0x00]) ||
        starts(const [0x4D, 0x4D, 0x00, 0x2A])) {
      return 'image/tiff';
    }
    if ((declared == 'image/x-emf' || declared == 'image/emf') &&
        starts(const [0x01, 0x00, 0x00, 0x00])) {
      return 'image/x-emf';
    }
    if ((declared == 'image/x-wmf' || declared == 'image/wmf') &&
        (starts(const [0xD7, 0xCD, 0xC6, 0x9A]) ||
            starts(const [0x01, 0x00, 0x09, 0x00]) ||
            starts(const [0x02, 0x00, 0x09, 0x00]))) {
      return 'image/x-wmf';
    }
    return null;
  }

  // Tables

  void _startCell(_Frame frame, String name) {
    final table = _tables.last!;
    if (table.rows.isEmpty) table.rows.add(_Row(table.header, table.style));
    final attributes = frame.element.attributes;
    int span(String key, int max) =>
        (int.tryParse(attributes[key]?.trim() ?? '') ?? 1).clamp(1, max);
    final cell = _Cell(
      span('colspan', _maxColumns),
      span('rowspan', 65534),
      frame.style,
    );
    table.rows.last.cells.add(cell);
    if (frame.style.border) table.bordered = true;
    frame.saved = (sink: _sink, last: _lastInlines);
    _sink = cell.blocks;
    _lastInlines = null;
    _cellDepth++;
  }

  void _column(dom.Element element, _Style style) {
    final table = _tables.lastOrNull;
    if (table == null) return;
    final span = (int.tryParse(element.attributes['span'] ?? '') ?? 1).clamp(
      1,
      _maxColumns,
    );
    for (
      var index = 0;
      index < span && table.columns.length < _maxColumns;
      index++
    ) {
      table.columns.add(style.width);
    }
  }

  TableSpec? _buildTable(_TableBuilder table) {
    final rows = <RowSpec>[];
    var pending = <int, ({int rows, int span})>{};
    var columns = 0;
    final widths = <int, double>{};
    final tableWidth = _size(table.style.width, _textWidth);
    for (final row in table.rows) {
      final cells = <CellSpec>[];
      final next = <int, ({int rows, int span})>{};
      var column = 0;
      void place(CellSpec cell) {
        if (++_cells > _maxCells) {
          throw DocumentProblemException(DocumentProblem.tooLarge);
        }
        cells.add(cell);
        column += cell.span;
      }

      // Columns that cells of rows above span down into.
      void covered() {
        while (true) {
          final above = pending[column];
          if (above == null) return;
          final start = column;
          place(
            CellSpec(
              <BlockSpec>[],
              span: above.span,
              merge: CellMerge.continuation,
            ),
          );
          if (above.rows > 1) {
            next[start] = (rows: above.rows - 1, span: above.span);
          }
        }
      }

      for (final source in row.cells) {
        covered();
        if (column >= _maxColumns) {
          cells.lastOrNull?.blocks.addAll(source.blocks);
          continue;
        }
        final span = math.min(source.colspan, _maxColumns - column);
        final style = source.style;
        if (span == 1) {
          final width = _size(style.width, tableWidth ?? _textWidth);
          if (width != null) widths.putIfAbsent(column, () => width);
        }
        final start = column;
        place(
          CellSpec(
            source.blocks,
            span: span,
            merge: source.rowspan > 1 ? CellMerge.restart : CellMerge.none,
            background: style.fill ?? row.style.fill,
            verticalAlign: style.verticalAlign ?? row.style.verticalAlign,
          ),
        );
        if (source.rowspan > 1) {
          next[start] = (rows: source.rowspan - 1, span: span);
        }
      }
      covered();
      // Cells above may span into columns past this row's last cell.
      for (final start in pending.keys.toList()..sort()) {
        if (start < column) continue;
        if (start > column) {
          place(CellSpec(<BlockSpec>[], span: start - column));
        }
        covered();
      }
      pending = next;
      if (cells.isEmpty) continue;
      columns = math.max(columns, column);
      rows.add(
        RowSpec(
          cells,
          header: row.header,
          height: _size(row.style.height, spec.page.textHeight),
        ),
      );
    }
    if (rows.isEmpty) return null;
    return TableSpec(
      rows,
      columnWidths: _columnWidths(table, columns, widths, tableWidth),
      bordered: table.bordered,
      indent: _tableIndent(table.style),
    );
  }

  double? _tableIndent(_Style style) {
    final indent = style.indentLeft + (style.marginLeft ?? 0);
    return indent > 0 ? math.min(indent, _textWidth / 2) : null;
  }

  List<double>? _columnWidths(
    _TableBuilder table,
    int columns,
    Map<int, double> cellWidths,
    double? tableWidth,
  ) {
    if (columns == 0) return null;
    final base = tableWidth ?? _textWidth;
    final widths = List<double?>.generate(
      columns,
      (index) => index < table.columns.length
          ? _size(table.columns[index], base) ?? cellWidths[index]
          : cellWidths[index],
    );
    final known = widths.whereType<double>().fold<double>(0, (a, b) => a + b);
    final unknown = widths.where((width) => width == null).length;
    if (unknown == columns && tableWidth == null) return null;
    final total = math.max(tableWidth ?? _textWidth, known);
    final rest = unknown == 0
        ? 0.0
        : math.max(total - known, 18.0 * unknown) / unknown;
    var result = [for (final width in widths) width ?? rest];
    final sum = result.fold<double>(0, (a, b) => a + b);
    if (sum > _textWidth && sum > 0) {
      result = [for (final width in result) width * _textWidth / sum];
    }
    return [for (final width in result) math.max(width, 4.0)];
  }

  // Defaults the page sets for most of its text.

  static void _count<T>(Map<T, int> counts, T value, [int weight = 1]) =>
      counts[value] = (counts[value] ?? 0) + weight;

  static T? _dominant<T>(Map<T?, int> counts) {
    T? best;
    var most = 0;
    counts.forEach((value, count) {
      if (count > most) {
        most = count;
        best = value;
      }
    });
    return best;
  }

  void _defaults() {
    final font = _dominant(_fonts);
    final size = _dominant(_sizes);
    final color = _dominant(_colors);
    spec.defaultRun = RunFormat(
      font: font ?? spec.defaultRun.font,
      size: size ?? spec.defaultRun.size,
      color: color,
    );
    final spacing = _dominant(_lineSpacings);
    final paragraph = spec.defaultParagraph;
    final defaults = spec.defaultParagraph = ParagraphFormat(
      spaceBefore: _dominant(_spaceBefore) ?? paragraph.spaceBefore,
      spaceAfter: _dominant(_spaceAfter) ?? paragraph.spaceAfter,
      lineSpacing: spacing == null
          ? paragraph.lineSpacing
          : _lineSpacingValues[spacing],
    );

    // Spacing equal to the defaults needn't be written on each paragraph.
    bool same(LineSpacing? a, LineSpacing? b) =>
        a?.rule == b?.rule && a?.value == b?.value;
    final lists = <List<BlockSpec>>[spec.body];
    while (lists.isNotEmpty) {
      final blocks = lists.removeLast();
      for (var index = 0; index < blocks.length; index++) {
        switch (blocks[index]) {
          case TableSpec(:final rows):
            for (final row in rows) {
              for (final cell in row.cells) {
                lists.add(cell.blocks);
              }
            }
          case ParagraphSpec(:final format) && final block
              when block.heading == null && format.list == null:
            blocks[index] = ParagraphSpec(
              block.inlines,
              mark: block.mark,
              format: ParagraphFormat(
                align: format.align,
                indentLeft: format.indentLeft,
                indentRight: format.indentRight,
                firstLine: format.firstLine,
                spaceBefore: format.spaceBefore == defaults.spaceBefore
                    ? null
                    : format.spaceBefore,
                spaceAfter: format.spaceAfter == defaults.spaceAfter
                    ? null
                    : format.spaceAfter,
                lineSpacing: same(format.lineSpacing, defaults.lineSpacing)
                    ? null
                    : format.lineSpacing,
                rightToLeft: format.rightToLeft,
              ),
            );
          default:
            break;
        }
      }
    }
  }

  /// Heading styles from rules for bare `h1` to `h6`; levels the page doesn't
  /// style keep the app's.
  void _headingStyles(_Style root) {
    final bodySize = spec.defaultRun.size ?? root.size ?? 12;
    for (var level = 1; level <= 6; level++) {
      final declarations = sheet.tagDeclarations('h$level');
      if (declarations.isEmpty) continue;
      final style = _Style();
      final box = _Box();
      for (final declaration in declarations) {
        _apply(style, box, declaration, bodySize);
      }
      spec.styles.add(
        StyleSpec.paragraph(
          'Heading$level',
          'heading $level',
          basedOn: 'Normal',
          next: 'Normal',
          headingLevel: level,
          run: RunFormat(
            font: style.font,
            size:
                style.size ??
                const [16.0, 14.0, 13.0, 12.0, 12.0, 12.0][level - 1],
            bold: style.bold ?? true,
            italic: style.italic ?? level >= 5,
            underline: style.underline,
            allCaps: style.allCaps,
            color: style.color,
          ),
          paragraph: ParagraphFormat(
            keepNext: true,
            keepLines: true,
            spaceBefore:
                (_sum(box.marginTop, box.paddingTop) ?? (level == 1 ? 18 : 12))
                    .clamp(0, 1584)
                    .toDouble(),
            spaceAfter: (_sum(box.marginBottom, box.paddingBottom) ?? 4)
                .clamp(0, 1584)
                .toDouble(),
            indentLeft: 0,
            firstLine: 0,
            align: style.align ?? ParagraphAlign.left,
            lineSpacing: style.lineSpacing,
          ),
        ),
      );
    }
  }
}
