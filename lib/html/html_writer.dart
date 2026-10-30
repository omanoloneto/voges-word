import 'dart:math' as math;
import 'dart:ui' show Color;

import 'package:flutter_quill/quill_delta.dart';
import 'package:xml/xml.dart';

import '../document/delta_blocks.dart';
import '../document/document_look.dart';
import '../document/embeds.dart';
import '../document/tables.dart';
import '../docx/docx_builder.dart' show ListSuffix;
import '../docx/docx_codec.dart';
import '../docx/docx_numbering.dart';
import '../docx/docx_package.dart';
import '../docx/word_list_counter.dart';
import '../docx/word_xml.dart';
import 'css.dart';
import 'writing.dart';

/// Writes the editor's content as a standalone page that reads the same as
/// HTML5 and as XHTML, so .xhtml files stay valid. Headers and footers have
/// no place in a web page and are left out; footnotes and endnotes follow the
/// text, and sections that start a page break it.
class HtmlWriter {
  /// A [counter] shared with another writer goes on with its numbers.
  HtmlWriter(
    this.tables, {
    required this.look,
    required this.numbering,
    this.package,
    WordListCounter? counter,
  }) : _counter = counter ?? WordListCounter(numbering);

  final TableStore tables;
  final DocumentLook look;
  final DocxNumbering numbering;

  /// The opened document: its notes, language and title.
  final DocxPackage? package;
  final WordListCounter _counter;
  final _ids = <String>{};
  String? _title;

  /// Tables of the notes, apart from the document's.
  final _noteTables = TableStore();
  final _noteBodies = <String, Map<String, Delta>>{};
  final _noteByReference = <String, _Note>{};
  final _footnotes = <_Note>[];
  final _endnotes = <_Note>[];
  var _inNotes = false;

  /// Whether items show Word's numbers, like `1.1.`, through the page's
  /// style sheet; the tables Markdown takes come without one.
  var _markers = true;
  var _markersShown = false;

  /// Tables nested deeper are written as their paragraphs.
  static const _maxTableDepth = 16;
  static const _noBookmarks = (id: '', anchors: '');
  static const _breakBefore = 'break-before:page;page-break-before:always';
  static const _breakAfter = 'break-after:page;page-break-after:always';

  /// Longer level texts and numbers are left to the browser's numbering.
  static const _maxMarker = 64;

  /// The formats `<ol type>` shows, followed by a period.
  static const _browserFormats = {
    'decimal',
    'lowerLetter',
    'upperLetter',
    'lowerRoman',
    'upperRoman',
  };
  static final _lineBreaks = RegExp(r'[\n\r\u000B\u2028\u2029]');
  static final _lineBreaksAndTabs = RegExp(r'[\t\n\r]');
  static final _languageTag = RegExp(r'^[A-Za-z]{2,8}(-[A-Za-z0-9]{1,8})*$');
  static final _noteReference = RegExp(
    r'<w:(footnote|endnote)Reference\b[^>]*?\bw:id="(-?\d+)"',
  );

  String write(Delta delta) {
    final body = StringBuffer();
    _blocks(documentBlocks(delta), body, 0, tables);
    _notes(body);
    final language = _language();
    final title = _propertiesTitle() ?? _title ?? 'Document';
    return '<!DOCTYPE html>\n<html xmlns="http://www.w3.org/1999/xhtml"'
        '${language == null ? '' : ' lang="$language" xml:lang="$language"'}>\n'
        '<head>\n<meta charset="utf-8"/>\n'
        '<meta name="viewport" content="width=device-width, initial-scale=1"/>\n'
        '<title>${_text(title)}</title>\n'
        // XHTML would read an `&` of a font name as markup.
        '<style>/*<![CDATA[*/\n${_styleSheet()}/*]]>*/</style>\n'
        '</head>\n<body>\n$body</body>\n</html>\n';
  }

  /// A table as HTML on its own, with its borders inline, for Markdown.
  String table(TableModel table) {
    final out = StringBuffer();
    _markers = false;
    _table(table, out, 0, tables, inlineBorders: true);
    return out.toString();
  }

  String _styleSheet() {
    final body = look.body;
    final margins = look.margins;
    final out = StringBuffer()
      ..writeln(
        '@page { size: ${_pt(look.pageWidth)} ${_pt(look.pageHeight)}; '
        'margin: ${_pt(margins.top)} ${_pt(margins.right)} '
        '${_pt(margins.bottom)} ${_pt(margins.left)}; }',
      )
      ..writeln(
        'body { ${_textStyle(body)} line-height: '
        '${formatNumber(look.lineSpacing)}; '
        'max-width: ${_pt(look.contentWidth)}; margin: 24pt auto; }',
      )
      ..writeln(
        'p, li { margin: ${_pt(body.spaceBefore)} 0 ${_pt(body.spaceAfter)}; '
        'white-space: pre-wrap; }',
      );
    for (var level = 1; level <= 6; level++) {
      final heading = look.heading(level);
      out.writeln(
        'h$level { ${_textStyle(heading)} margin: ${_pt(heading.spaceBefore)} '
        '0 ${_pt(heading.spaceAfter)}; white-space: pre-wrap; }',
      );
    }
    out
      ..writeln('table { border-collapse: collapse; }')
      ..writeln('td, th { vertical-align: top; padding: 0 5.4pt; }')
      ..writeln(
        'table.grid td, table.grid th { border: 0.5pt solid #000000; }',
      );
    if (_markersShown) {
      out.writeln(
        'li[data-marker]::marker { content: attr(data-marker) " "; }',
      );
    }
    // An <hr> would reopen as content the editor lacks.
    if (_footnotes.isNotEmpty || _endnotes.isNotEmpty) {
      out.writeln(
        'section.footnotes, section.endnotes { '
        'border-top: 0.5pt solid #000000; }',
      );
    }
    return out.toString();
  }

  static String _textStyle(TextLook text) {
    final font = text.fontFamily == null
        ? null
        : safeFontName(text.fontFamily!);
    return [
      if (font != null) 'font-family: "$font";',
      'font-size: ${_pt(text.fontSize)};',
      'color: #${_hex(text.color)};',
      'font-weight: ${text.bold ? 'bold' : 'normal'};',
      'font-style: ${text.italic ? 'italic' : 'normal'};',
    ].join(' ');
  }

  /// The language of the document's text, like `pt-BR`, from its default
  /// formatting.
  String? _language() {
    final package = this.package;
    if (package == null) return null;
    try {
      final main = package.mainDocumentPath;
      for (final relationship in package.relationships(main)) {
        if (!relationship.hasType('styles') || relationship.external) continue;
        final root = package
            .xml(DocxPackage.resolve(main, relationship.target))
            ?.rootElement;
        if (root == null) return null;
        final x = WordXml(root);
        final language = x.attr(
          x.child(
            x.child(x.child(x.child(root, 'docDefaults'), 'rPrDefault'), 'rPr'),
            'lang',
          ),
          'val',
        );
        return language != null && _languageTag.hasMatch(language)
            ? language
            : null;
      }
    } on Exception {
      // A damaged styles part leaves the language out.
    }
    return null;
  }

  /// The title in the document's properties, which Word also gives its web
  /// pages.
  String? _propertiesTitle() {
    final package = this.package;
    if (package == null) return null;
    try {
      final path =
          [
            for (final relationship in package.relationships(''))
              if (relationship.hasType('core-properties') &&
                  !relationship.external)
                DocxPackage.resolve('', relationship.target),
          ].firstOrNull ??
          'docProps/core.xml';
      final title = package
          .xml(path)
          ?.rootElement
          .childElements
          .where((element) => element.name.local == 'title')
          .firstOrNull;
      return title == null ? null : _titleOf(title.innerText);
    } on Exception {
      return null;
    }
  }

  void _headingTitle(LineBlock line) {
    if (!_inNotes) _title ??= _titleOf(line.plainText);
  }

  static String? _titleOf(String text) {
    final title = text.replaceAll(_lineBreaks, ' ').trim();
    if (title.isEmpty) return null;
    return title.length > 200 ? title.substring(0, 200) : title;
  }

  // Blocks

  void _blocks(
    List<DocumentBlock> blocks,
    StringBuffer out,
    int depth,
    TableStore store,
  ) {
    final lists = <_OpenList>[];
    for (final block in blocks) {
      if (block is LineBlock && block.list != null) {
        _item(block, lists, out);
        continue;
      }
      _closeLists(lists, out);
      _counter.breakRun();
      switch (block) {
        case LineBlock():
          _paragraph(block, out, label: _label(block));
        case EmbedBlock(type: EmbedTypes.table):
          final table = store[tableIdOf(block.value)];
          if (table != null) _table(table, out, depth, store);
        case EmbedBlock(type: EmbedTypes.opaqueBlock):
          final content = OpaqueContent.decode(block.value);
          if (content.hidden) break;
          for (final line in content.text.split('\n')) {
            out.writeln('<p>${_text(line)}</p>');
          }
        case EmbedBlock(type: EmbedTypes.sectionBreak):
          if (depth == 0 && !_inNotes && _startsPage(block.value)) {
            out.writeln('<div style="$_breakAfter"></div>');
          }
        case EmbedBlock():
          break;
      }
    }
    _closeLists(lists, out);
  }

  /// Whether a Word section break starts a new page, as all but continuous
  /// ones do.
  static bool _startsPage(Object? section) =>
      _val(_properties(sectionXmlOf(section))['type']) != 'continuous';

  /// A [label] Word shows before the paragraph goes before its first text.
  void _paragraph(LineBlock line, StringBuffer out, {String label = ''}) {
    final level = line.heading?.clamp(1, 6);
    final tag = level == null ? 'p' : 'h$level';
    if (level != null) _headingTitle(line);
    final kept = _paragraphProperties(line);
    final parts = pageParts(line);
    // Bookmarks go on the first part with text, or on the page break of a
    // line that has nothing else.
    final marked = math.max(parts.indexWhere((part) => part.isNotEmpty), 0);
    final bookmarks = _bookmarks(line);
    for (var index = 0; index < parts.length; index++) {
      final pieces = parts[index];
      final breakAfter = index < parts.length - 1;
      final (:id, :anchors) = index == marked ? bookmarks : _noBookmarks;
      final labeled = index == marked && label.isNotEmpty;
      if (pieces.isEmpty && parts.length > 1 && !labeled) {
        if (!breakAfter) continue;
        final style = [
          if (index == 0 && _isOn(kept['pageBreakBefore'])) _breakBefore,
          _breakAfter,
        ];
        out.writeln('<div$id style="${style.join(';')}">$anchors</div>');
        continue;
      }
      final attributes = _paragraphAttributes(
        line,
        kept,
        breakBefore: index == 0,
        breakAfter: breakAfter,
      );
      final content = '${labeled ? _text(label) : ''}${_inlines(pieces)}';
      out.writeln(
        '<$tag$id$attributes>$anchors${content.isEmpty ? '<br/>' : content}'
        '</$tag>',
      );
    }
  }

  /// Counts a paragraph at a level of its Word list without numbers, which
  /// restarts the levels below, and returns the level's text Word shows
  /// before it with what follows; empty for other lines.
  String _label(LineBlock line) {
    final numId = _counter.unnumberedList(line);
    if (numId == null) return '';
    _counter.count(line);
    final text = _counter.textOf(line)?.replaceAll(_lineBreaksAndTabs, ' ');
    if (text == null || text.isEmpty) return '';
    final level = numbering.level(numId, WordListCounter.levelOf(line))!;
    return level.suffix == ListSuffix.nothing ? text : '$text ';
  }

  /// The properties of the line's .docx paragraph that pages show: its
  /// direction and a page break before it.
  static Map<String, XmlElement> _paragraphProperties(LineBlock line) {
    final kept = line.attributes[HiddenAttributes.paragraphProperties];
    return kept is String &&
            (kept.contains('bidi') || kept.contains('pageBreakBefore'))
        ? _properties(kept)
        : const {};
  }

  /// The direction and style of a paragraph or list item; [kept] are the
  /// properties of its .docx paragraph.
  String _paragraphAttributes(
    LineBlock line,
    Map<String, XmlElement> kept, {
    bool inList = false,
    bool breakBefore = false,
    bool breakAfter = false,
    List<String> extra = const [],
  }) {
    final style = [
      if (const {'center', 'right', 'justify'}.contains(line.align))
        'text-align:${line.align}',
      if (!inList && line.indent > 0) 'margin-left:${_pt(36.0 * line.indent)}',
      if (line.indentRight case final right?) 'margin-right:${_pt(right)}',
      if (!inList)
        if (line.firstLine case final first?) 'text-indent:${_pt(first)}',
      if (line.spaceBefore case final before?) 'margin-top:${_pt(before)}',
      if (line.spaceAfter case final after?) 'margin-bottom:${_pt(after)}',
      if (line.lineHeight case final height? when height > 0)
        'line-height:${formatNumber(height)}',
      if (breakBefore && _isOn(kept['pageBreakBefore'])) _breakBefore,
      if (breakAfter) _breakAfter,
      ...extra,
    ];
    return '${_isOn(kept['bidi']) ? ' dir="rtl"' : ''}'
        '${style.isEmpty ? '' : ' style="${style.join(';')}"'}';
  }

  /// The `id` of the line's first bookmark and anchors for the others.
  ({String id, String anchors}) _bookmarks(LineBlock line) {
    final names = [
      for (final name in bookmarksOf(line))
        if (_ids.add(name)) name,
    ];
    if (names.isEmpty) return _noBookmarks;
    return (
      id: ' id="${escapeHtmlAttribute(names.first)}"',
      anchors: [
        for (final name in names.skip(1))
          '<a id="${escapeHtmlAttribute(name)}"></a>',
      ].join(),
    );
  }

  // Lists

  void _item(LineBlock line, List<_OpenList> open, StringBuffer out) {
    final level = math.min(line.indent, 8);
    final ordered = line.isOrdered;
    final key = ordered ? _counter.keyOf(line) : 'bullets';
    final number = _counter.count(line) ?? 0;
    while (open.isNotEmpty && open.last.level > level) {
      _closeList(open, out);
    }
    if (open.isNotEmpty && open.last.level == level) {
      if (open.last.ordered == ordered && open.last.key == key) {
        // Nested lists are inside an item, which keeps line breaks.
        out.write(open.length == 1 ? '</li>\n' : '</li>');
      } else {
        _closeList(open, out);
      }
    }
    for (var gap = open.isEmpty ? 0 : open.last.level + 1; gap < level; gap++) {
      out.write('<ul style="list-style-type:none"><li>');
      open.add(_OpenList(gap, false, 'gap'));
    }
    // The editor numbers the levels of its own lists 1., a., i.
    final format =
        _wordLevel(line)?.format ??
        const ['decimal', 'lowerLetter', 'lowerRoman'][level % 3];
    if (open.isEmpty || open.last.level < level) {
      if (ordered) {
        final type = switch (format) {
          'lowerLetter' => ' type="a"',
          'upperLetter' => ' type="A"',
          'lowerRoman' => ' type="i"',
          'upperRoman' => ' type="I"',
          _ => '',
        };
        out.write('<ol${number == 1 ? '' : ' start="$number"'}$type>');
      } else {
        out.write('<ul>');
      }
      open.add(_OpenList(level, ordered, key));
    }
    final (:id, :anchors) = _bookmarks(line);
    final checklist = line.list == 'checked' || line.list == 'unchecked';
    final checkbox = switch (line.list) {
      'checked' =>
        '<input type="checkbox" disabled="disabled" checked="checked" '
            'style="margin-right:0.4em"/>',
      'unchecked' =>
        '<input type="checkbox" disabled="disabled" '
            'style="margin-right:0.4em"/>',
      _ => '',
    };
    final pieces = [
      for (final piece in line.pieces)
        if (piece is! EmbedPiece || piece.type != EmbedTypes.pageBreak) piece,
    ];
    final heading = line.heading?.clamp(1, 6);
    final kept = _paragraphProperties(line);
    final attributes = _paragraphAttributes(
      line,
      kept,
      inList: true,
      breakBefore: true,
      extra: [if (checklist && heading == null) 'list-style-type:none'],
    );
    final marker = ordered && _markers ? _marker(line, number, format) : null;
    _markersShown |= marker != null;
    final shown = marker == null
        ? ''
        : ' data-marker="${escapeHtmlAttribute(marker)}"';
    final content = '$anchors$checkbox${_inlines(pieces)}';
    if (heading == null) {
      out.write('<li$id$shown$attributes>$content');
      return;
    }
    // A numbered heading, like Word's chapters; its number goes on the side
    // the heading starts.
    _headingTitle(line);
    out.write(
      '<li${_isOn(kept['bidi']) ? ' dir="rtl"' : ''}$shown'
      '${checklist ? ' style="list-style-type:none"' : ''}>'
      '<h$heading$id$attributes>$content</h$heading>',
    );
  }

  /// The level of the Word list a numbered [line] shows.
  WordLevel? _wordLevel(LineBlock line) => switch (_counter.wordList(line)) {
    final numId? => numbering.level(numId, WordListCounter.levelOf(line)),
    null => null,
  };

  /// The [number] of a numbered [line] as its Word level writes it, like
  /// `1.1.`, `(a)` or `Article I.`; null when browsers show it the same way.
  /// Browsers go on after z with aa, ab, where Word goes on with aa, bb.
  String? _marker(LineBlock line, int number, String format) {
    final word = _wordLevel(line);
    final letters =
        number > 26 && (format == 'lowerLetter' || format == 'upperLetter');
    if (word == null) return letters ? '${wordNumber(number, format)}.' : null;
    if (word.text.length > _maxMarker) return null;
    if (!letters &&
        word.text == '%${WordListCounter.levelOf(line) + 1}.' &&
        !word.legal &&
        _browserFormats.contains(word.format)) {
      return null;
    }
    final marker = _counter.textOf(line)?.replaceAll(_lineBreaksAndTabs, ' ');
    return marker == null || marker.length > _maxMarker ? null : marker;
  }

  void _closeList(List<_OpenList> open, StringBuffer out) {
    final list = open.removeLast();
    out.write(list.ordered ? '</li></ol>' : '</li></ul>');
    if (open.isEmpty) out.write('\n');
  }

  void _closeLists(List<_OpenList> open, StringBuffer out) {
    while (open.isNotEmpty) {
      _closeList(open, out);
    }
  }

  // Inline content

  String _inlines(List<InlinePiece> pieces) {
    final out = StringBuffer();
    String? openLink;
    for (final piece in pieces) {
      final opaque =
          piece is EmbedPiece && piece.type == EmbedTypes.opaqueInline
          ? OpaqueContent.decode(piece.value)
          : null;
      final note =
          opaque != null && !opaque.hidden && opaque.label == OpaqueLabels.note;
      // A note's mark links to the note, so it stays out of other links.
      final link = note ? null : exportLink(piece.link);
      if (link != openLink) {
        if (openLink != null) out.write('</a>');
        if (link != null) out.write('<a href="${escapeHtmlAttribute(link)}">');
        openLink = link;
      }
      final attributes = link == null
          ? piece.attributes
          : _withoutLinkLook(piece.attributes);
      switch (piece) {
        case TextPiece(:final text):
          out.write(_formatted(_text(text), attributes));
        case EmbedPiece(type: EmbedTypes.image):
          out.write(_image(piece));
        case EmbedPiece() when opaque != null && !opaque.hidden:
          out.write(
            note
                ? _noteMark(opaque, attributes)
                : _formatted(_text(opaque.text), attributes),
          );
        case EmbedPiece():
          break;
      }
    }
    if (openLink != null) out.write('</a>');
    return out.toString();
  }

  /// Links look as browsers show them, without Word's blue and underline.
  static Map<String, dynamic> _withoutLinkLook(Map<String, dynamic> look) => {
    for (final MapEntry(:key, :value) in look.entries)
      if (!(key == 'underline' && value == true) &&
          !(key == 'color' && hexColor(value) == '0563C1'))
        key: value,
  };

  static String _formatted(String html, Map<String, dynamic> attributes) {
    if (html.isEmpty) return html;
    final kept = attributes[HiddenAttributes.runProperties];
    final run =
        kept is String && (kept.contains('caps') || kept.contains('Caps'))
        ? _properties(kept)
        : const <String, XmlElement>{};
    final style = [
      if (attributes['font'] case final String font?)
        if (safeFontName(font) case final name?)
          'font-family:&quot;${escapeHtmlAttribute(name)}&quot;',
      if (_size(attributes['size']) case final size?) 'font-size:${_pt(size)}',
      if (hexColor(attributes['color']) case final color?) 'color:#$color',
      if (hexColor(attributes['background']) case final color?)
        'background-color:#$color',
      if (_isOn(run['caps'])) 'text-transform:uppercase',
      if (_isOn(run['smallCaps'])) 'font-variant:small-caps',
    ];
    var out = style.isEmpty
        ? html
        : '<span style="${style.join(';')}">$html</span>';
    out = switch (attributes['script']) {
      'super' => '<sup>$out</sup>',
      'sub' => '<sub>$out</sub>',
      _ => out,
    };
    if (attributes['strike'] == true) out = '<s>$out</s>';
    if (attributes['underline'] == true) out = '<u>$out</u>';
    if (attributes['italic'] == true) out = '<i>$out</i>';
    if (attributes['bold'] == true) out = '<b>$out</b>';
    return out;
  }

  static double? _size(Object? value) {
    final size = switch (value) {
      'small' => 9.0,
      'large' => 18.0,
      'huge' => 28.0,
      _ => pointsValue(value),
    };
    return size != null && size > 0 && size.isFinite ? size : null;
  }

  static final _pictureUri = RegExp(
    r'^data:image/(png|jpeg|gif|bmp|webp|tiff|x-emf|x-wmf);base64,'
    r'[A-Za-z0-9+/]*={0,2}$',
  );

  static String _image(EmbedPiece piece) {
    final uri = piece.value;
    if (uri is! String || !_pictureUri.hasMatch(uri)) return '';
    final width = pointsValue(piece.attributes['width']);
    final height = pointsValue(piece.attributes['height']);
    final style = [
      if (width != null && width > 0) 'width:${_pt(width)}',
      if (height != null && height > 0) 'height:${_pt(height)}',
    ];
    return '<img src="$uri" alt="${escapeHtmlAttribute(_altText(piece))}"'
        '${style.isEmpty ? '' : ' style="${style.join(';')}"'}/>';
  }

  /// The description Word keeps for a picture, which screen readers read.
  static String _altText(EmbedPiece piece) {
    final drawing = piece.attributes[HiddenAttributes.drawing];
    if (drawing is! String || !drawing.contains('docPr')) return '';
    try {
      for (final element in XmlDocument.parse(drawing).descendantElements) {
        if (element.name.local != 'docPr') continue;
        final description = element.getAttribute('descr')?.trim() ?? '';
        return (description.isEmpty
                ? element.getAttribute('title') ?? ''
                : description)
            .replaceAll(_lineBreaks, ' ')
            .trim();
      }
    } on XmlException {
      // A damaged drawing has no description.
    }
    return '';
  }

  /// Escaped text; line breaks become `<br/>` and the rest of what HTML can't
  /// hold is left out.
  static String _text(String text) {
    final out = StringBuffer();
    for (final rune in text.runes) {
      switch (rune) {
        case 0x26:
          out.write('&amp;');
        case 0x3C:
          out.write('&lt;');
        case 0x3E:
          out.write('&gt;');
        case 0xA0:
          out.write('&#160;');
        case 0x2028 || 0x0A || 0x0B:
          out.write('<br/>');
        case 0x09:
          out.write('\t');
        default:
          if (rune >= 0x20 &&
              (rune < 0x7F || rune > 0x9F) &&
              (rune < 0xD800 || rune > 0xDFFF) &&
              rune != 0xFFFE &&
              rune != 0xFFFF) {
            out.writeCharCode(rune);
          }
      }
    }
    return out.toString();
  }

  // Notes

  /// The raised mark of a footnote or endnote, linked to its text at the end
  /// of the page; only the mark when the opened document doesn't have it.
  String _noteMark(OpaqueContent content, Map<String, dynamic> attributes) {
    final note = _inNotes ? null : _note(content);
    final String mark;
    if (note == null) {
      mark = _text(content.text);
    } else {
      // The note's number links back to its first mark.
      final id = note.marked ? '' : ' id="${note.referenceId}"';
      note.marked = true;
      mark = '<a href="#${note.id}"$id>${note.mark}</a>';
    }
    if (mark.isEmpty) return '';
    return '<sup>${_formatted(mark, {...attributes}..remove('script'))}</sup>';
  }

  _Note? _note(OpaqueContent content) {
    final package = this.package;
    if (package == null || content.packageId != package.id) return null;
    final reference = _noteReference.firstMatch(content.xml);
    if (reference == null) return null;
    final kind = reference[1]!;
    // A note marked many times is written once, so the page can't grow with
    // the marks.
    final key = '$kind ${reference[2]}';
    if (_noteByReference[key] case final note?) return note;
    final bodies = _noteBodies[kind] ??= _readNotes(package, kind);
    final body = bodies[reference[2]];
    if (body == null) return null;
    final endnote = kind == 'endnote';
    final notes = endnote ? _endnotes : _footnotes;
    final number = notes.length + 1;
    final prefix = endnote ? 'en' : 'fn';
    final note = _Note(
      body,
      // Word's own marks: 1, 2, 3 for footnotes and i, ii, iii for endnotes.
      mark: endnote ? romanNumeral(number) : '$number',
      id: _uniqueId('$prefix-$number'),
      referenceId: _uniqueId('${prefix}ref-$number'),
    );
    notes.add(note);
    return _noteByReference[key] = note;
  }

  Map<String, Delta> _readNotes(DocxPackage package, String kind) {
    try {
      return DocxCodec(_noteTables).notes(package, kind);
    } catch (_) {
      // A damaged notes part leaves only the marks.
      return const {};
    }
  }

  /// The footnotes and then the endnotes.
  void _notes(StringBuffer out) {
    _inNotes = true;
    for (final (kind, notes) in [
      ('footnotes', _footnotes),
      ('endnotes', _endnotes),
    ]) {
      if (notes.isEmpty) continue;
      _counter.breakRun();
      out.writeln('<section class="$kind">');
      for (final note in notes) {
        out.write('<div id="${note.id}">');
        _blocks(_noteBlocks(note), out, 0, _noteTables);
        out.writeln('</div>');
      }
      out.writeln('</section>');
    }
  }

  /// The note's blocks; the first starts with the note's number, which links
  /// back to its mark.
  static List<DocumentBlock> _noteBlocks(_Note note) {
    final blocks = documentBlocks(note.body);
    final number = TextPiece(note.mark, {
      'link': '#${note.referenceId}',
      'script': 'super',
    });
    final first = blocks.firstOrNull;
    if (first is! LineBlock || first.list != null) {
      return [
        LineBlock([number], const {}),
        ...blocks,
      ];
    }
    return [
      LineBlock([
        number,
        const TextPiece(' ', {}),
        ...first.pieces,
      ], first.attributes),
      ...blocks.skip(1),
    ];
  }

  /// [base], or [base] and a number when another id of the page has it.
  String _uniqueId(String base) {
    var id = base;
    for (var copy = 2; !_ids.add(id); copy++) {
      id = '$base-$copy';
    }
    return id;
  }

  // Tables

  void _table(
    TableModel table,
    StringBuffer out,
    int depth,
    TableStore store, {
    bool inlineBorders = false,
  }) {
    if (table.rows.isEmpty) return;
    if (depth >= _maxTableDepth) {
      for (final row in table.rows) {
        for (final cell in row.cells) {
          _blocks(
            documentBlocks(cell.controller.document.toDelta()),
            out,
            depth,
            store,
          );
        }
      }
      return;
    }
    final widths = [for (final width in table.columnWidths) width / 20];
    final total = widths.fold<double>(0, (sum, width) => sum + width);
    final grid = table.bordered
        ? inlineBorders
              ? ' border="1"'
              : ' class="grid" border="1"'
        : '';
    out.write(
      '<table$grid style="border-collapse:collapse;table-layout:fixed'
      '${total > 0 ? ';width:${_pt(total)}' : ''}">',
    );
    if (widths.isNotEmpty) {
      out.write('<colgroup>');
      for (final width in widths) {
        out.write('<col style="width:${_pt(width)}"/>');
      }
      out.write('</colgroup>');
    }
    final starts = [for (final row in table.rows) _columnStarts(row)];
    var headers = 0;
    while (headers < table.rows.length &&
        (table.rows[headers].propertiesXml?.contains('tblHeader') ?? false)) {
      headers++;
    }
    // Browsers cut a merged cell at the header's end, so the header takes in
    // the rows its cells reach.
    for (var row = 0; row < headers; row++) {
      final cells = table.rows[row].cells;
      for (var cell = 0; cell < cells.length; cell++) {
        if (cells[cell].verticalMerge == VerticalMerge.restart) {
          headers = math.max(
            headers,
            row + _rowspan(table, starts, row, starts[row][cell]),
          );
        }
      }
    }
    for (var index = 0; index < table.rows.length; index++) {
      if (index == 0 && headers > 0) out.write('<thead>');
      if (index == headers) {
        out.write('${headers > 0 ? '</thead>' : ''}<tbody>');
      }
      final row = table.rows[index];
      final height = _rowHeight(row.propertiesXml);
      out.write(height == null ? '<tr>' : '<tr style="height:${_pt(height)}">');
      for (var cell = 0; cell < row.cells.length; cell++) {
        final model = row.cells[cell];
        if (model.verticalMerge == VerticalMerge.continuation) continue;
        final rowspan = model.verticalMerge == VerticalMerge.restart
            ? _rowspan(table, starts, index, starts[index][cell])
            : 1;
        final style = [
          if (model.fill case final fill?) 'background-color:#${_hex(fill)}',
          if (_cellAlign(model.propertiesXml) case final align?)
            'vertical-align:$align',
          if (table.bordered && inlineBorders) 'border:0.5pt solid #000000',
        ];
        out.write(
          '<td${model.gridSpan > 1 ? ' colspan="${model.gridSpan}"' : ''}'
          '${rowspan > 1 ? ' rowspan="$rowspan"' : ''}'
          '${style.isEmpty ? '' : ' style="${style.join(';')}"'}>',
        );
        final content = StringBuffer();
        _blocks(
          documentBlocks(model.controller.document.toDelta()),
          content,
          depth + 1,
          store,
        );
        out.write('${content.toString().trimRight()}</td>');
      }
      out.write('</tr>');
    }
    out.write(
      '${table.rows.length > headers ? '</tbody>' : '</thead>'}</table>\n',
    );
  }

  /// Grid column where each of the row's cells starts.
  static List<int> _columnStarts(TableRowModel row) {
    final starts = <int>[];
    var column = 0;
    for (final cell in row.cells) {
      starts.add(column);
      column += math.max(cell.gridSpan, 1);
    }
    return starts;
  }

  static int _rowspan(
    TableModel table,
    List<List<int>> starts,
    int row,
    int column,
  ) {
    var span = 1;
    for (var next = row + 1; next < table.rows.length; next++) {
      final index = starts[next].indexOf(column);
      if (index < 0 ||
          table.rows[next].cells[index].verticalMerge !=
              VerticalMerge.continuation) {
        break;
      }
      span++;
    }
    return span;
  }

  /// Points of a .docx row's height; browsers take it as the least, as Word
  /// does unless the row's height is exact.
  static double? _rowHeight(String? xml) {
    if (xml == null || !xml.contains('trHeight')) return null;
    final height = _properties(xml)['trHeight'];
    if (height?.getAttribute('hRule', namespaceUri: '*') == 'auto') {
      return null;
    }
    final twips = int.tryParse(_val(height) ?? '');
    return twips == null || twips <= 0 ? null : math.min(twips / 20, 1584);
  }

  /// CSS `vertical-align` of a .docx cell that isn't aligned to the top.
  static String? _cellAlign(String? xml) {
    if (xml == null || !xml.contains('vAlign')) return null;
    return switch (_val(_properties(xml)['vAlign'])) {
      'center' => 'middle',
      'bottom' => 'bottom',
      _ => null,
    };
  }

  /// The children of .docx properties the editor keeps, like a paragraph's
  /// `w:pPr`, by name; none when they are damaged.
  static Map<String, XmlElement> _properties(Object? xml) {
    if (xml is! String || xml.isEmpty) return const {};
    try {
      return {
        for (final element in XmlDocument.parse(xml).rootElement.childElements)
          element.name.local: element,
      };
    } on XmlException {
      return const {};
    }
  }

  static String? _val(XmlElement? element) =>
      element?.getAttribute('val', namespaceUri: '*');

  /// Whether a .docx on/off property, like `w:bidi`, is on.
  static bool _isOn(XmlElement? element) =>
      element != null && !const {'0', 'false', 'off'}.contains(_val(element));

  static String _pt(double points) => '${formatNumber(points)}pt';

  static String _hex(Color color) => (color.toARGB32() & 0xFFFFFF)
      .toRadixString(16)
      .padLeft(6, '0')
      .toUpperCase();
}

class _OpenList {
  const _OpenList(this.level, this.ordered, this.key);

  final int level;
  final bool ordered;
  final Object key;
}

class _Note {
  _Note(
    this.body, {
    required this.mark,
    required this.id,
    required this.referenceId,
  });

  final Delta body;

  /// Shown at the reference and before the note's text.
  final String mark;
  final String id;
  final String referenceId;
  var marked = false;
}

final _notXml = RegExp(r'[\x00-\x08\x0B\x0C\x0E-\x1F\uFFFE\uFFFF]');

/// [text] escaped for markup; characters XML can't hold are left out.
String escapeHtmlText(String text) => text
    .replaceAll(_notXml, '')
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;');

String escapeHtmlAttribute(String text) =>
    escapeHtmlText(text).replaceAll('"', '&quot;');
