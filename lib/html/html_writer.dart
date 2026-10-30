import 'dart:math' as math;
import 'dart:ui' show Color;

import 'package:flutter_quill/quill_delta.dart';

import '../document/delta_blocks.dart';
import '../document/document_look.dart';
import '../document/embeds.dart';
import '../document/tables.dart';
import 'css.dart';
import 'writing.dart';

/// Writes the editor's content as a standalone HTML5 page. Headers and
/// footers have no place in a web page and are left out.
class HtmlWriter {
  HtmlWriter(this.tables, {required this.look, required this.numbering})
    : _counter = ListCounter(numbering);

  final TableStore tables;
  final DocumentLook look;
  final ListNumbering numbering;
  final ListCounter _counter;
  final _ids = <String>{};
  String? _title;

  /// Tables nested deeper are written as their paragraphs.
  static const _maxTableDepth = 16;

  String write(Delta delta) {
    final body = StringBuffer();
    _blocks(documentBlocks(delta), body, 0);
    return '<!DOCTYPE html>\n<html>\n<head>\n<meta charset="utf-8">\n'
        '<meta name="viewport" content="width=device-width, initial-scale=1">\n'
        '<title>${escapeHtmlText(_title ?? 'Document')}</title>\n'
        '<style>\n${_styleSheet()}</style>\n</head>\n<body>\n$body</body>\n'
        '</html>\n';
  }

  /// A table as HTML on its own, with its borders inline, for Markdown.
  String table(TableModel table) {
    final out = StringBuffer();
    _table(table, out, 0, inlineBorders: true);
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

  // Blocks

  void _blocks(List<DocumentBlock> blocks, StringBuffer out, int depth) {
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
          _paragraph(block, out);
        case EmbedBlock(type: EmbedTypes.table):
          final table = tables[tableIdOf(block.value)];
          if (table != null) _table(table, out, depth);
        case EmbedBlock(type: EmbedTypes.opaqueBlock):
          final content = OpaqueContent.decode(block.value);
          if (content.hidden) break;
          for (final line in content.text.split('\n')) {
            out.writeln('<p>${_text(line)}</p>');
          }
        case EmbedBlock():
          break;
      }
    }
    _closeLists(lists, out);
  }

  void _paragraph(LineBlock line, StringBuffer out) {
    final level = line.heading?.clamp(1, 6);
    final tag = level == null ? 'p' : 'h$level';
    if (level != null) {
      final text = line.plainText.replaceAll('\u2028', ' ').trim();
      if (text.isNotEmpty) {
        _title ??= text.length > 200 ? text.substring(0, 200) : text;
      }
    }
    final parts = pageParts(line);
    for (var index = 0; index < parts.length; index++) {
      final pieces = parts[index];
      final breakAfter = index < parts.length - 1;
      if (pieces.isEmpty && index > 0 && !breakAfter) continue;
      if (pieces.isEmpty && breakAfter) {
        out.writeln(
          '<div style="break-after:page;page-break-after:always"></div>',
        );
        continue;
      }
      final (:id, :anchors) = index == 0
          ? _bookmarks(line)
          : (id: '', anchors: '');
      final content = _inlines(pieces);
      out.writeln(
        '<$tag$id${_paragraphStyle(line, breakAfter: breakAfter)}>'
        '$anchors${content.isEmpty ? '<br>' : content}</$tag>',
      );
    }
  }

  String _paragraphStyle(
    LineBlock line, {
    bool inList = false,
    bool breakAfter = false,
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
      if (breakAfter) 'break-after:page;page-break-after:always',
    ];
    return style.isEmpty ? '' : ' style="${style.join(';')}"';
  }

  /// The `id` of the line's first bookmark and anchors for the others.
  ({String id, String anchors}) _bookmarks(LineBlock line) {
    final names = [
      for (final name in bookmarksOf(line))
        if (_ids.add(name)) name,
    ];
    if (names.isEmpty) return (id: '', anchors: '');
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
    final number = ordered ? _counter.next(line) : 0;
    while (open.isNotEmpty && open.last.level > level) {
      _closeList(open, out);
    }
    if (open.isNotEmpty && open.last.level == level) {
      if (open.last.ordered == ordered && open.last.key == key) {
        out.write('</li>\n');
      } else {
        _closeList(open, out);
      }
    }
    for (var gap = open.isEmpty ? 0 : open.last.level + 1; gap < level; gap++) {
      out.write('<ul style="list-style-type:none"><li>');
      open.add(_OpenList(gap, false, 'gap'));
    }
    if (open.isEmpty || open.last.level < level) {
      if (ordered) {
        final type = switch (_counter.formatOf(line)) {
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
    final checkbox = switch (line.list) {
      'checked' => '<input type="checkbox" disabled checked> ',
      'unchecked' => '<input type="checkbox" disabled> ',
      _ => '',
    };
    final pieces = [
      for (final piece in line.pieces)
        if (piece is! EmbedPiece || piece.type != EmbedTypes.pageBreak) piece,
    ];
    out.write(
      '<li$id${_paragraphStyle(line, inList: true)}>'
      '$anchors$checkbox${_inlines(pieces)}',
    );
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
      final link = exportLink(piece.link);
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
        case EmbedPiece(type: EmbedTypes.opaqueInline, :final value):
          final content = OpaqueContent.decode(value);
          if (!content.hidden) {
            out.write(_formatted(_text(content.text), attributes));
          }
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
    final style = [
      if (attributes['font'] case final String font?)
        if (safeFontName(font) case final name?)
          'font-family:&quot;$name&quot;',
      if (_size(attributes['size']) case final size?) 'font-size:${_pt(size)}',
      if (hexColor(attributes['color']) case final color?) 'color:#$color',
      if (hexColor(attributes['background']) case final color?)
        'background-color:#$color',
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
    return '<img src="$uri" alt=""'
        '${style.isEmpty ? '' : ' style="${style.join(';')}"'}>';
  }

  /// Escaped text; line breaks become `<br>` and the rest of what HTML can't
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
          out.write('&nbsp;');
        case 0x2028 || 0x0A || 0x0B:
          out.write('<br>');
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

  // Tables

  void _table(
    TableModel table,
    StringBuffer out,
    int depth, {
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
        out.write('<col style="width:${_pt(width)}">');
      }
      out.write('</colgroup>');
    }
    final starts = [for (final row in table.rows) _columnStarts(row)];
    var headers = 0;
    while (headers < table.rows.length &&
        (table.rows[headers].propertiesXml?.contains('tblHeader') ?? false)) {
      headers++;
    }
    for (var index = 0; index < table.rows.length; index++) {
      if (index == 0 && headers > 0) out.write('<thead>');
      if (index == headers) {
        out.write('${headers > 0 ? '</thead>' : ''}<tbody>');
      }
      out.write('<tr>');
      final row = table.rows[index];
      for (var cell = 0; cell < row.cells.length; cell++) {
        final model = row.cells[cell];
        if (model.verticalMerge == VerticalMerge.continuation) continue;
        final rowspan = model.verticalMerge == VerticalMerge.restart
            ? _rowspan(table, starts, index, starts[index][cell])
            : 1;
        final style = [
          if (model.fill case final fill?) 'background-color:#${_hex(fill)}',
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

String escapeHtmlText(String text) => text
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;');

String escapeHtmlAttribute(String text) =>
    escapeHtmlText(text).replaceAll('"', '&quot;');
