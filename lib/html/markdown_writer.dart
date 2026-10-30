import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter_quill/quill_delta.dart';

import '../document/delta_blocks.dart';
import '../document/embeds.dart';
import '../document/tables.dart';
import 'html_writer.dart';
import 'writing.dart';

/// Writes the editor's content as CommonMark with GitHub's tables and
/// strikethrough. Underline, colors, sizes, alignment, headers and footers
/// have no Markdown and are left out.
class MarkdownWriter {
  MarkdownWriter(this.tables, {required this.numbering, required this.html})
    : _counter = ListCounter(numbering);

  final TableStore tables;
  final ListNumbering numbering;

  /// Writes the tables Markdown can't hold: merged cells, lists or tables
  /// inside cells.
  final HtmlWriter html;
  final ListCounter _counter;

  String write(Delta delta) {
    final blocks = documentBlocks(delta);
    final front = _frontMatter(blocks);
    final chunks = [
      ?front?.text,
      ..._blocks(front == null ? blocks : blocks.sublist(front.blocks)),
    ];
    return chunks.isEmpty ? '' : '${chunks.join('\n\n')}\n';
  }

  /// Front matter at the top of the document, which the Markdown reader
  /// shows as monospace lines: written back as it was, without a fence, when
  /// every line looks like YAML or TOML.
  ({String text, int blocks})? _frontMatter(List<DocumentBlock> blocks) {
    final lines = <String>[];
    for (var index = 0; index < blocks.length; index++) {
      final block = blocks[index];
      if (block is! LineBlock ||
          block.list != null ||
          !(_isCode(block) || (index > 0 && block.isEmpty))) {
        return null;
      }
      final start = lines.length;
      lines.addAll(block.plainText.split('\u2028'));
      final fence = lines.first.trimRight();
      if ((fence != '---' && fence != '+++') ||
          (lines.length > 1 && lines[1].trim().isEmpty)) {
        return null;
      }
      for (var line = math.max(start, 1); line < lines.length; line++) {
        final text = lines[line].trimRight();
        if (text != fence && (fence != '---' || text != '...')) {
          if (!_isMetadata(lines[line])) return null;
          continue;
        }
        if (line < lines.length - 1) return null;
        return (text: lines.join('\n'), blocks: index + 1);
      }
    }
    return null;
  }

  /// A line of YAML or TOML: a key, a list item, a table, a comment, or an
  /// empty or indented line. Renderers without front matter read the lines
  /// as Markdown, so none may hold a tag they would show as HTML.
  static bool _isMetadata(String line) =>
      !line.contains(_tag) &&
      (line.trim().isEmpty ||
          line.startsWith(_space) ||
          line.startsWith(_metadata));

  static final _tag = RegExp('<[A-Za-z/!?]');
  static final _space = RegExp(r'\s');
  static final _metadata = RegExp(
    r'''#|\[|-(?:\s|$)|[\w"'.$@-][^:=]*(?::(?:\s|$)|=)''',
  );

  List<String> _blocks(List<DocumentBlock> blocks) {
    final chunks = <String>[];
    final items = <String>[];
    final levels = <_Level>[];
    final code = <String>[];
    // The list level whose item holds the code being gathered; null when it
    // is at the top.
    int? codeLevel;
    var continued = false;
    void endList() {
      if (items.isEmpty) return;
      chunks.add(items.join('\n'));
      items.clear();
      levels.clear();
      continued = false;
    }

    void endCode() {
      if (code.isEmpty) return;
      final level = codeLevel;
      if (level == null) {
        chunks.add(_fence(code));
      } else {
        final indent = ' ' * levels[level].offset;
        final lines = [
          for (final line in _fence(code).split('\n'))
            line.isEmpty ? line : '$indent$line',
        ];
        items.add('\n${lines.join('\n')}');
        continued = true;
      }
      code.clear();
    }

    for (var index = 0; index < blocks.length; index++) {
      final block = blocks[index];
      if (block is LineBlock && block.list != null) {
        endCode();
        items.add(_item(block, levels, continued: continued));
        continued = false;
        continue;
      }
      final level = _continuationLevel(block, levels.length);
      if (block is LineBlock && _isCode(block)) {
        if (code.isNotEmpty && codeLevel != level) endCode();
        if (level == null) endList();
        codeLevel = level;
        code.addAll(block.plainText.split('\u2028'));
        continue;
      }
      if (code.isNotEmpty && _isBlank(block)) {
        // Empty lines between two code lines of the same block stay in it.
        var next = index + 1;
        while (next < blocks.length && _isBlank(blocks[next])) {
          next++;
        }
        final following = next < blocks.length ? blocks[next] : null;
        if (following is LineBlock &&
            following.list == null &&
            _isCode(following) &&
            _continuationLevel(following, levels.length) == codeLevel) {
          code.addAll(List.filled(next - index, ''));
          index = next - 1;
          continue;
        }
      }
      endCode();
      if (level != null && block is LineBlock) {
        levels.length = level + 1;
        items.add('\n${_continuation(block, levels[level].offset)}');
        continued = true;
        continue;
      }
      endList();
      _counter.breakRun();
      switch (block) {
        case LineBlock():
          chunks.addAll(_paragraph(block));
        case EmbedBlock(type: EmbedTypes.table):
          final table = tables[tableIdOf(block.value)];
          if (table != null) chunks.add(_table(table));
        case EmbedBlock(type: EmbedTypes.opaqueBlock):
          final content = OpaqueContent.decode(block.value);
          if (content.hidden) break;
          for (final line in content.text.split('\n')) {
            chunks.add(_escape(line.trim(), lineStart: true));
          }
        case EmbedBlock():
          break;
      }
    }
    endCode();
    endList();
    return [
      for (final chunk in chunks)
        if (chunk.trim().isNotEmpty) chunk,
    ];
  }

  static bool _isBlank(DocumentBlock block) =>
      block is LineBlock && block.list == null && block.isEmpty;

  /// The list level whose item [block] goes on: an indented paragraph or code
  /// line right after the items of a list [depth] levels deep, without the
  /// right indent of quotes. Null for anything else.
  static int? _continuationLevel(DocumentBlock block, int depth) {
    if (block is! LineBlock ||
        block.list != null ||
        block.heading != null ||
        block.isEmpty ||
        block.indent < 1 ||
        block.indent > depth ||
        (block.indentRight ?? 0) > 0 ||
        block.pieces.any(
          (piece) => piece is EmbedPiece && piece.type == EmbedTypes.pageBreak,
        )) {
      return null;
    }
    return block.indent - 1;
  }

  /// A paragraph of a list item after its first one, aligned with the
  /// item's text at [offset].
  String _continuation(LineBlock line, int offset) {
    final indent = ' ' * offset;
    final text = _inline(line.pieces, indent: indent).trim();
    return '$indent${_anchors(line)}$text';
  }

  // Paragraphs and headings

  List<String> _paragraph(LineBlock line) {
    final chunks = <String>[];
    final parts = pageParts(line);
    final heading = line.heading?.clamp(1, 6);
    final quote = math.min(line.indent, 8);
    for (var index = 0; index < parts.length; index++) {
      final anchors = index == 0 ? _anchors(line) : '';
      var text = _inline(
        parts[index],
        breaks: heading == null,
        indent: quote == 0 ? '' : '> ' * quote,
      ).trim();
      if (heading != null && text.endsWith('#')) {
        text = '${text.substring(0, text.length - 1)}\\#';
      }
      if (text.isNotEmpty || anchors.isNotEmpty) {
        chunks.add(
          heading != null
              ? '${'#' * heading} $anchors$text'
              : '${'> ' * quote}$anchors$text',
        );
      }
      if (index < parts.length - 1) chunks.add('---');
    }
    return chunks;
  }

  /// Inline HTML anchors for the line's bookmarks, the targets of `#` links.
  static String _anchors(LineBlock line) => [
    for (final name in bookmarksOf(line))
      '<a id="${escapeHtmlAttribute(name)}"></a>',
  ].join();

  bool _isCode(LineBlock line) =>
      line.heading == null &&
      line.pieces.isNotEmpty &&
      line.pieces.every(
        (piece) =>
            piece is TextPiece &&
            piece.link == null &&
            isMonospace(piece.attributes['font']),
      );

  static String _fence(List<String> lines) {
    var longest = 0;
    for (final line in lines) {
      for (final run in _backticks.allMatches(line)) {
        longest = math.max(longest, run[0]!.length);
      }
    }
    final fence = '`' * math.max(3, longest + 1);
    return '$fence\n${lines.join('\n')}\n$fence';
  }

  // Lists

  /// The item's Markdown. It starts with an empty line after a paragraph or
  /// code that [continued] the item before, and where Markdown would read it
  /// as part of the text above.
  String _item(LineBlock line, List<_Level> levels, {bool continued = false}) {
    final level = math.min(line.indent, levels.length);
    final indent = level == 0 ? 0 : levels[level - 1].offset;
    final previous = level < levels.length ? levels[level] : null;
    final parent = level == 0 ? null : levels[level - 1];
    final ordered = line.isOrdered;
    final key = ordered ? _counter.keyOf(line) : 'bullets';
    var delimiter = '.';
    var marker = '-';
    var number = 1;
    if (ordered) {
      if (previous != null && previous.ordered) {
        // A list right after another one at the same level needs another
        // delimiter, or Markdown joins them.
        delimiter = previous.key == key
            ? previous.delimiter
            : (previous.delimiter == '.' ? ')' : '.');
      }
      number = _counter.next(line);
      marker = '$number$delimiter';
    } else {
      _counter.countBullet(line);
    }
    final offset = indent + marker.length + 1;
    final (:checkbox, :pieces) = _task(line);
    final text = _inline(pieces, indent: ' ' * offset).trim();
    final item = '${' ' * indent}$marker $checkbox${_anchors(line)}$text'
        .trimRight();
    final empty = item.length == indent + marker.length;
    levels
      ..length = level
      ..add(
        _Level(
          offset: offset,
          key: key,
          ordered: ordered,
          delimiter: delimiter,
          empty: empty,
        ),
      );
    // Another list right after a list needs a blank line: one that doesn't
    // start at 1 can't interrupt the item before. Under the text of its
    // parent, neither can an empty item or a list not starting at 1.
    final another =
        previous != null &&
        (previous.ordered != ordered || previous.key != key);
    final interrupts =
        previous == null &&
        parent != null &&
        !parent.empty &&
        (empty || number != 1);
    return another || interrupts || continued ? '\n$item' : item;
  }

  /// The item's task box: a checklist item of the editor, or an item that
  /// starts with ☐ or ☑, as GitHub's task lists are read. The pieces come
  /// without the box and without page breaks.
  static ({String checkbox, List<InlinePiece> pieces}) _task(LineBlock line) {
    final pieces = [
      for (final piece in line.pieces)
        if (piece is! EmbedPiece || piece.type != EmbedTypes.pageBreak) piece,
    ];
    switch (line.list) {
      case 'checked':
        return (checkbox: '[x] ', pieces: pieces);
      case 'unchecked':
        return (checkbox: '[ ] ', pieces: pieces);
    }
    final first = pieces.firstOrNull;
    final box = first is TextPiece ? _taskBox.firstMatch(first.text) : null;
    if (first is! TextPiece || box == null) {
      return (checkbox: '', pieces: pieces);
    }
    final rest = first.text.substring(box.end);
    return (
      checkbox: box[1] == '☑' ? '[x] ' : '[ ] ',
      pieces: [
        if (rest.isNotEmpty) TextPiece(rest, first.attributes),
        ...pieces.skip(1),
      ],
    );
  }

  static final _taskBox = RegExp('^([☐☑])(?: |\$)');

  // Tables

  String _table(TableModel table) {
    if (table.rows.isEmpty) return '';
    final rows = [
      for (final row in table.rows)
        [
          for (final cell in row.cells)
            documentBlocks(cell.controller.document.toDelta()),
        ],
    ];
    final simple =
        !table.hasMergedCells &&
        rows.every(
          (row) => row.every(
            (blocks) => blocks.every(
              (block) => block is LineBlock && block.list == null,
            ),
          ),
        );
    if (!simple) return html.table(table).trim();
    final columns = rows.map((row) => row.length).fold(1, math.max);
    String line(List<List<DocumentBlock>> row, {bool header = false}) {
      final cells = [
        for (var column = 0; column < columns; column++)
          column < row.length ? _cell(row[column], header: header) : '',
      ];
      return '| ${cells.join(' | ')} |';
    }

    // Header cells show bold and centered anyway; the first row of data
    // tells each column's alignment.
    final alignments = [
      for (var column = 0; column < columns; column++)
        switch (rows.length > 1 && column < rows[1].length
            ? rows[1][column].whereType<LineBlock>().firstOrNull?.align
            : null) {
          'center' => ' :---: |',
          'right' => ' ---: |',
          _ => ' --- |',
        },
    ];
    return [
      line(rows.first, header: true),
      '|${alignments.join()}',
      for (final row in rows.skip(1)) line(row),
    ].join('\n');
  }

  String _cell(List<DocumentBlock> blocks, {bool header = false}) => [
    for (final block in blocks.whereType<LineBlock>())
      _inline(block.pieces, table: true, header: header).trim(),
  ].where((text) => text.isNotEmpty).join('<br>');

  // Inline content

  /// Markdown of [pieces]. Hard line breaks end a line with `\` and the next
  /// one starts with [indent]; in tables they become `<br>`, and in headings
  /// spaces when [breaks] is false. A [header] row of a table is bold
  /// anyway.
  String _inline(
    List<InlinePiece> pieces, {
    String indent = '',
    bool table = false,
    bool breaks = true,
    bool header = false,
  }) {
    final runs = _runs(pieces, bold: !header);
    return _render(runs, indent, table: table, breaks: breaks, html: false) ??
        _render(runs, indent, table: table, breaks: breaks, html: true)!;
  }

  /// Text and pictures with their formatting; spaces at the edges of a
  /// formatted run take only the formatting their neighbors share, so
  /// delimiters never sit next to a space on their inner side.
  List<_Run> _runs(List<InlinePiece> pieces, {required bool bold}) {
    final raw = <_Run>[];
    for (final piece in pieces) {
      final attributes = piece.attributes;
      final marks = {
        if (bold && attributes['bold'] == true) _Mark.bold,
        if (attributes['italic'] == true) _Mark.italic,
        if (attributes['strike'] == true) _Mark.strike,
      };
      final link = exportLink(piece.link);
      switch (piece) {
        case TextPiece(:final text):
          _textRuns(text, attributes, marks, link, raw);
        case EmbedPiece(type: EmbedTypes.image, :final value):
          if (value is String && _pictureUri.hasMatch(value)) {
            raw.add(_Run.markdown('![]($value)', marks, link));
          }
        case EmbedPiece(type: EmbedTypes.opaqueInline, :final value):
          final content = OpaqueContent.decode(value);
          if (!content.hidden) {
            _textRuns(
              content.text.replaceAll('\n', '\u2028'),
              attributes,
              marks,
              link,
              raw,
            );
          }
        case EmbedPiece():
          break;
      }
    }
    _endWithoutBreak(raw);
    final runs = <_Run>[];
    for (var index = 0; index < raw.length; index++) {
      final run = raw[index];
      final text = run.text;
      if (run.kind != _RunKind.text || run.marks.isEmpty) {
        runs.add(run);
        continue;
      }
      Set<_Mark> shared(_Run? neighbor) => {
        if (neighbor != null && neighbor.link == run.link)
          ...run.marks.intersection(neighbor.marks),
      };
      final start = text.length - text.trimLeft().length;
      final end = text.trimRight().length;
      if (start >= end) {
        runs.add(_Run.text(text, shared(runs.lastOrNull), run.link, run.style));
        continue;
      }
      if (start > 0) {
        runs.add(
          _Run.text(
            text.substring(0, start),
            shared(runs.lastOrNull),
            run.link,
            run.style,
          ),
        );
      }
      runs.add(
        _Run.text(text.substring(start, end), run.marks, run.link, run.style),
      );
      if (end < text.length) {
        runs.add(
          _Run.text(
            text.substring(end),
            shared(index + 1 < raw.length ? raw[index + 1] : null),
            run.link,
            run.style,
          ),
        );
      }
    }
    return runs;
  }

  /// Drops line breaks with only spaces after them: at the end of a block
  /// Markdown reads the `\` of a break as text.
  static void _endWithoutBreak(List<_Run> runs) {
    var end = runs.length;
    while (end > 0) {
      final run = runs[end - 1];
      if (run.kind != _RunKind.lineBreak &&
          (run.kind != _RunKind.text ||
              run.style != _Style.plain ||
              run.text.trim().isNotEmpty)) {
        break;
      }
      end--;
    }
    if (runs.skip(end).any((run) => run.kind == _RunKind.lineBreak)) {
      runs.length = end;
    }
  }

  /// Adds the runs of [text]. Monospace text right after monospace text
  /// with the same formatting and link joins it: Markdown has none of what
  /// tells them apart, and two code spans side by side would join their
  /// backticks.
  static void _textRuns(
    String text,
    Map<String, dynamic> attributes,
    Set<_Mark> marks,
    String? link,
    List<_Run> runs,
  ) {
    final style = switch (attributes['script']) {
      'super' => _Style.superscript,
      'sub' => _Style.subscript,
      _ => isMonospace(attributes['font']) ? _Style.code : _Style.plain,
    };
    final lines = text.split(_lineBreaks);
    for (var index = 0; index < lines.length; index++) {
      if (index > 0) runs.add(_Run.lineBreak(link));
      if (lines[index].isEmpty) continue;
      final last = runs.lastOrNull;
      if (index == 0 &&
          style == _Style.code &&
          last != null &&
          last.kind == _RunKind.text &&
          last.style == _Style.code &&
          last.link == link &&
          last.marks.length == marks.length &&
          last.marks.containsAll(marks)) {
        last.parts.add(lines[index]);
      } else {
        runs.add(_Run.text(lines[index], marks, link, style));
      }
    }
  }

  static final _lineBreaks = RegExp('[\u2028\n\u000B]');
  static final _backticks = RegExp('`+');
  static final _controlCharacters = RegExp(r'[\u0000-\u0008\u000A-\u001F]');

  static final _pictureUri = RegExp(
    r'^data:image/(png|jpeg|gif|bmp|webp|tiff|x-emf|x-wmf);base64,'
    r'[A-Za-z0-9+/]*={0,2}$',
  );

  /// Null when a delimiter wouldn't be read back as formatting.
  String? _render(
    List<_Run> runs,
    String indent, {
    required bool table,
    required bool breaks,
    required bool html,
  }) {
    final out = StringBuffer();
    final open = <_Mark>[];
    final delimiters = <({int start, int end, bool opening})>[];
    String? link;
    var lineStart = !table;

    void delimiter(_Mark mark, {required bool opening}) {
      final text = html
          ? switch (mark) {
              _Mark.strike => opening ? '<del>' : '</del>',
              _Mark.bold => opening ? '<strong>' : '</strong>',
              _Mark.italic => opening ? '<em>' : '</em>',
            }
          : switch (mark) {
              _Mark.strike => '~~',
              _Mark.bold => '**',
              _Mark.italic => '*',
            };
      final start = out.length;
      out.write(text);
      if (!html) {
        delimiters.add((start: start, end: out.length, opening: opening));
      }
      lineStart = false;
    }

    void closeAll() {
      while (open.isNotEmpty) {
        delimiter(open.removeLast(), opening: false);
      }
    }

    void setLink(String? target) {
      if (target == link) return;
      closeAll();
      if (link != null) out.write('](${_destination(link!, table: table)})');
      if (target != null) out.write('[');
      link = target;
      lineStart = false;
    }

    for (final run in runs) {
      setLink(run.link);
      if (run.kind == _RunKind.lineBreak) {
        closeAll();
        if (table) {
          out.write('<br>');
        } else if (!breaks) {
          out.write(' ');
        } else {
          out.write('\\\n$indent');
          lineStart = true;
        }
        continue;
      }
      while (open.any((mark) => !run.marks.contains(mark))) {
        delimiter(open.removeLast(), opening: false);
      }
      for (final mark in _Mark.values) {
        if (run.marks.contains(mark) && !open.contains(mark)) {
          open.add(mark);
          delimiter(mark, opening: true);
        }
      }
      var text = run.text;
      if (run.kind == _RunKind.markdown) {
        out.write(text);
      } else if (run.style == _Style.code) {
        out.write(_codeSpan(text, table: table));
      } else {
        if (lineStart) text = text.trimLeft();
        if (text.isEmpty) continue;
        var escaped = _escape(text, lineStart: lineStart, table: table);
        if (run.style == _Style.superscript) escaped = '<sup>$escaped</sup>';
        if (run.style == _Style.subscript) escaped = '<sub>$escaped</sub>';
        out.write(escaped);
      }
      lineStart = false;
    }
    closeAll();
    setLink(null);
    final markdown = out.toString();
    return html || _parsesBack(markdown, delimiters) ? markdown : null;
  }

  /// Whether every delimiter run follows CommonMark's flanking rules, so it
  /// reads back as formatting: on GitHub and in package:markdown, where
  /// punctuation is Unicode's, and in CommonMark 0.31, where symbols like €
  /// or ✓ are punctuation too.
  static bool _parsesBack(
    String text,
    List<({int start, int end, bool opening})> delimiters,
  ) =>
      _flanks(text, delimiters, _punctuation) &&
      _flanks(text, delimiters, _punctuationOrSymbol);

  static bool _flanks(
    String text,
    List<({int start, int end, bool opening})> delimiters,
    RegExp punctuation,
  ) {
    bool isPunctuation(String char) => punctuation.hasMatch(char);
    for (var index = 0; index < delimiters.length; index++) {
      final delimiter = delimiters[index];
      final next = index + 1 < delimiters.length ? delimiters[index + 1] : null;
      // A closing run right before an opening one of the same character
      // would merge with it.
      if (next != null &&
          next.start == delimiter.end &&
          !delimiter.opening &&
          next.opening &&
          text[delimiter.end - 1] == text[next.start]) {
        return false;
      }
      final before = delimiter.start > 0 ? text[delimiter.start - 1] : null;
      final after = delimiter.end < text.length ? text[delimiter.end] : null;
      if (delimiter.opening) {
        if (after == null || _isSpace(after)) return false;
        if (isPunctuation(after) &&
            before != null &&
            !_isSpace(before) &&
            !isPunctuation(before)) {
          return false;
        }
      } else {
        if (before == null || _isSpace(before)) return false;
        if (isPunctuation(before) &&
            after != null &&
            !_isSpace(after) &&
            !isPunctuation(after)) {
          return false;
        }
      }
    }
    return true;
  }

  static bool _isSpace(String char) => char.trim().isEmpty;

  /// Punctuation as GitHub and package:markdown tell it: ASCII punctuation
  /// and Unicode's.
  static final _punctuation = RegExp(
    r'''[!"#$%&'()*+,\-./:;<=>?@\[\\\]^_`{|}~\p{P}]''',
    unicode: true,
  );

  static final _punctuationOrSymbol = RegExp(r'[\p{P}\p{S}]', unicode: true);

  /// Text with Markdown's special characters escaped, so it reads back as
  /// the same text. The start of web and e-mail addresses is escaped too:
  /// GitHub's Markdown links them, reading what follows as part of the
  /// address.
  static String _escape(
    String text, {
    bool lineStart = false,
    bool table = false,
  }) {
    final out = StringBuffer();
    for (var index = 0; index < text.length; index++) {
      final char = text[index];
      final unit = char.codeUnitAt(0);
      if (unit < 0x20 && unit != 0x09) continue;
      if (r'\`*_[]<~'.contains(char)) {
        out.write('\\$char');
      } else if (char == '|' && table) {
        out.write(r'\|');
      } else if (char == '&' && _entity.matchAsPrefix(text, index) != null) {
        out.write(r'\&');
      } else if ((char == ':' && text.startsWith('//', index + 1)) ||
          (char == '.' && _afterWww(text, index)) ||
          (char == '@' && _inAddress(text, index))) {
        out.write('\\$char');
      } else {
        out.write(char);
      }
    }
    var escaped = out.toString();
    if (lineStart) {
      final block = _blockStart.firstMatch(escaped);
      if (block != null) {
        escaped = block[1] == null
            ? '\\$escaped'
            : '${block[1]}\\${escaped.substring(block[1]!.length)}';
      }
    }
    return escaped;
  }

  static bool _afterWww(String text, int index) =>
      index >= 3 && text.substring(index - 3, index).toLowerCase() == 'www';

  /// Whether the `@` at [index] sits between characters of an e-mail
  /// address.
  static bool _inAddress(String text, int index) =>
      index + 1 < text.length &&
      _domainCharacter.hasMatch(text[index + 1]) &&
      (index == 0 || _localCharacter.hasMatch(text[index - 1]));

  static final _localCharacter = RegExp(r'[-_.+A-Za-z0-9]');
  static final _domainCharacter = RegExp(r'[-_A-Za-z0-9]');

  static final _entity = RegExp(
    r'&(#[0-9]{1,7}|#[xX][0-9a-fA-F]{1,6}|[A-Za-z][A-Za-z0-9]{0,31});',
  );

  /// Text at the start of a line that Markdown would read as a heading,
  /// quote, list item or rule; group 1 is the number of an ordered item.
  static final _blockStart = RegExp(r'^(?:[#>+=-]|([0-9]{1,9})[.)])');

  static String _codeSpan(String text, {required bool table}) {
    var content = table ? text.replaceAll('|', r'\|') : text;
    content = content.replaceAll(_controlCharacters, '');
    if (content.isEmpty) return '';
    var longest = 0;
    for (final run in _backticks.allMatches(content)) {
      longest = math.max(longest, run[0]!.length);
    }
    final fence = '`' * (longest + 1);
    final pad =
        content.startsWith('`') ||
        content.endsWith('`') ||
        (content.startsWith(' ') &&
            content.endsWith(' ') &&
            content.trim().isNotEmpty);
    return pad ? '$fence $content $fence' : '$fence$content$fence';
  }

  /// A link destination with spaces and angle brackets percent-encoded and
  /// parentheses and backslashes escaped. In a [table] pipes are escaped
  /// too, or they would split the cell.
  static String _destination(String url, {required bool table}) {
    final out = StringBuffer();
    for (final rune in url.runes) {
      if (rune <= 0x20 || rune == 0x7F || rune == 0x3C || rune == 0x3E) {
        for (final byte in utf8.encode(String.fromCharCode(rune))) {
          out.write('%${byte.toRadixString(16).padLeft(2, '0').toUpperCase()}');
        }
      } else if (rune == 0x28 ||
          rune == 0x29 ||
          rune == 0x5C ||
          (rune == 0x7C && table)) {
        out.write('\\${String.fromCharCode(rune)}');
      } else {
        out.writeCharCode(rune);
      }
    }
    return out.toString();
  }
}

class _Level {
  const _Level({
    required this.offset,
    required this.key,
    required this.ordered,
    required this.delimiter,
    required this.empty,
  });

  /// Column where the item's content starts.
  final int offset;
  final Object key;
  final bool ordered;
  final String delimiter;

  /// The item has no text, so an item under it doesn't follow a paragraph.
  final bool empty;
}

/// Delimiters open in this order, so strikethrough sits inside bold and
/// italic: package:markdown misreads `~~**$10**~~`.
enum _Mark { bold, italic, strike }

enum _RunKind { text, markdown, lineBreak }

enum _Style { plain, code, superscript, subscript }

class _Run {
  _Run.text(String text, this.marks, this.link, this.style)
    : kind = _RunKind.text,
      parts = [text];

  /// Already Markdown, like a picture.
  _Run.markdown(String text, this.marks, this.link)
    : kind = _RunKind.markdown,
      style = _Style.plain,
      parts = [text];

  _Run.lineBreak(this.link)
    : kind = _RunKind.lineBreak,
      parts = [],
      marks = const {},
      style = _Style.plain;

  final _RunKind kind;

  /// Pieces of text that make up the run.
  final List<String> parts;
  final Set<_Mark> marks;
  final String? link;
  final _Style style;

  String get text => parts.length == 1 ? parts.first : parts.join();
}
