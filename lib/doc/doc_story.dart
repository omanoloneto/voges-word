import 'dart:math' as math;

import '../document/document_codec.dart';
import '../document/text_encodings.dart';
import '../docx/docx_builder.dart';
import 'doc_context.dart';
import 'doc_file.dart';
import 'doc_properties.dart';
import 'doc_symbols.dart';

/// Fields nested deeper keep only their text.
const _maxFieldDepth = 32;

/// Tables nested deeper join the cells of the deepest one kept.
const _maxTableDepth = 16;

/// Fields that hold an embedded or linked object; only its picture stays.
const _objectFields = {'EMBED', 'LINK'};

/// Fields that show nothing when saved without a result.
const _invisibleFields = {
  '',
  'ADVANCE',
  'ASK',
  'DATA',
  'HYPERLINK',
  'NEXT',
  'NEXTIF',
  'PRIVATE',
  'RD',
  'SET',
  'SKIPIF',
  'TA',
  'TC',
  'XE',
};

enum _FieldMode { instruction, link, live, passThrough }

/// A field being read: its instruction until the separator, then its result.
class _Field {
  _Field(this.format);

  final RunFormat format;
  final instruction = StringBuffer();
  final result = <InlineSpec>[];
  var mode = _FieldMode.instruction;
  var target = '';

  /// Offset of a form field's data in the Data stream.
  var formData = -1;
}

/// Reads a story (the main text, a header, a note...) into paragraphs and
/// tables.
class StoryReader {
  StoryReader(
    this.context, {
    this.readNote,
    this.sections = false,
    this.header = false,
  });

  final DocContext context;

  /// Turns the main text's note references into notes.
  final List<BlockSpec> Function(DocNote note)? readNote;

  /// Ends sections at their marks; only the main text has them.
  final bool sections;

  /// A header or footer, whose floating shapes are the headers' drawing.
  final bool header;

  final _blocks = <BlockSpec>[];
  final _tables = <_TableBuilder>[];
  var _inlines = <InlineSpec>[];
  final _fields = <_Field>[];
  var _skippedFields = 0;
  var _section = 0;
  final _pending = StringBuffer();
  List<InlineSpec>? _pendingTarget;
  RunFormat? _pendingFormat;

  DocFile get file => context.file;

  late final Set<int> _sectionMarks = {
    for (final section in file.sections) section.end - 1,
  };

  List<BlockSpec> read(int start, int end) {
    final limit = math.min(end, file.pieces.length);
    var position = start;
    while (position < limit) {
      final mark = _paragraphEnd(position, limit);
      final ended = mark < limit;
      final props = file.paragraphAt(ended ? mark : mark - 1);
      var at = position;
      while (at < mark) {
        final next = file.runEnd(at, mark);
        final (base, characters) = file.charactersAt(at, props.style);
        _characters(at, next, base, characters);
        at = next;
      }
      _endParagraph(props, ended ? mark : null);
      position = mark + 1;
    }
    _fields.clear();
    _setDepth(0);
    return _blocks;
  }

  int _paragraphEnd(int start, int end) {
    final text = file.pieces.text;
    for (var position = start; position < end; position++) {
      switch (text[position]) {
        case 0x0D:
          return position;
        case 0x07 when file.paragraphAt(position).depth > 0:
          return position;
        case 0x0C
            when sections && _sectionMarks.contains(position) ||
                _endsParagraphRun(position):
          return position;
      }
    }
    return end;
  }

  /// A page break that the paragraph formatting ends a paragraph at.
  bool _endsParagraphRun(int position) {
    final piece = file.pieces.pieceAt(position);
    if (piece == null) return false;
    final offset = piece.offsetOf(position);
    return file.paragraphRuns.find(offset)?.end == offset + piece.width;
  }

  void _characters(int start, int end, CharProps base, CharProps props) {
    if (props.deleted) {
      context.notices.add(DocumentNotice.trackedChangesAccepted);
      for (var position = start; position < end; position++) {
        _bookmarks(position);
      }
      return;
    }
    if (props.inserted) {
      context.notices.add(DocumentNotice.trackedChangesAccepted);
    }
    final text = file.pieces.text;
    final format = context.runFormat(base, props);
    final font = context.fontName(props.font);
    final buffer = StringBuffer();
    void flush() {
      if (buffer.isEmpty) return;
      _text(buffer.toString(), format);
      buffer.clear();
    }

    for (var position = start; position < end; position++) {
      if (file.bookmarks.containsKey(position)) {
        flush();
        _bookmarks(position);
      }
      final note = readNote == null ? null : file.notes[position];
      if (note != null) {
        flush();
        _inline(
          NoteSpec(
            note.endnote ? NoteKind.endnote : NoteKind.footnote,
            readNote!(note),
            format: format,
          ),
        );
        continue;
      }
      final unit = text[position];
      final mapped = unit >= 0xF020 && unit <= 0xF0FF
          ? symbolText(font, unit)
          : null;
      // Word marks symbols as special; other writers only give sprmCSymbol.
      if (unit == 0x28 && props.symbolFont >= 0) {
        flush();
        _symbol(
          props.symbolCharacter,
          context.fontName(props.symbolFont),
          format,
        );
      } else if (mapped != null) {
        flush();
        _text(mapped, context.withFont(format, null));
      } else if (unit >= 0x20 || _textControls.contains(unit)) {
        buffer.writeCharCode(unit);
      } else {
        flush();
        _control(unit, position, props, format);
      }
    }
    flush();
  }

  /// Tabs, line breaks and hyphens the builder writes as Word's elements.
  static const _textControls = {0x09, 0x0B, 0x1E, 0x1F};

  void _control(int unit, int position, CharProps props, RunFormat format) {
    switch (unit) {
      case 0x13:
        _beginField(format);
      case 0x14:
        _separateField();
      case 0x15:
        _endField();
      case 0x0C:
        _inline(const BreakSpec(BreakKind.page));
      case 0x0E:
        _inline(const BreakSpec(BreakKind.column));
      case 0x01 when props.formData:
        if (_fields.lastOrNull case final field?
            when _skippedFields == 0 && field.mode == _FieldMode.instruction) {
          field.formData = props.pictureOffset;
        }
      case 0x01 when props.special:
        // An embedded object keeps only the picture of its content.
        if (props.ole) context.notices.add(DocumentNotice.contentNotImported);
        if (context.picture(props.pictureOffset, quiet: props.ole)
            case final image?) {
          _inline(image);
        }
      case 0x08 when props.special:
        final image = context.floatingPicture(position, header: header);
        if (image != null) _inline(image);
      case 0x05 when props.special:
        context.notices.add(DocumentNotice.commentsHidden);
    }
  }

  /// A symbol inserted from a font: Unicode when there is an equivalent,
  /// otherwise the character in its font.
  void _symbol(int code, String? font, RunFormat format) {
    final mapped = symbolText(font, code);
    if (mapped != null) {
      _text(mapped, context.withFont(format, null));
    } else if (code >= 0x20) {
      _text(String.fromCharCode(code), context.withFont(format, font));
    }
  }

  void _bookmarks(int position) {
    final names = file.bookmarks[position];
    if (names == null) return;
    _flushText();
    final target = _target().list ?? _inlines;
    for (final name in names) {
      context.addElement();
      target.add(BookmarkSpec(name));
    }
  }

  // Fields

  void _beginField(RunFormat format) {
    if (_fields.length >= _maxFieldDepth) {
      _skippedFields++;
      return;
    }
    _fields.add(_Field(format));
  }

  void _separateField() {
    if (_skippedFields > 0 || _fields.isEmpty) return;
    final field = _fields.last;
    if (field.mode != _FieldMode.instruction) return;
    final instruction = field.instruction.toString().trim();
    final name = _fieldName(instruction);
    if (_objectFields.contains(name)) {
      context.notices.add(DocumentNotice.contentNotImported);
    }
    if (name == 'HYPERLINK') {
      final target = _linkTarget(instruction);
      field.mode = target == null ? _FieldMode.passThrough : _FieldMode.link;
      field.target = target ?? '';
    } else {
      field.mode = isSafeField(instruction)
          ? _FieldMode.live
          : _FieldMode.passThrough;
    }
  }

  void _endField() {
    if (_skippedFields > 0) {
      _skippedFields--;
      return;
    }
    if (_fields.isEmpty) return;
    _flushText();
    final field = _fields.removeLast();
    final instruction = field.instruction.toString().trim();
    switch (field.mode) {
      case _FieldMode.instruction:
        _resultless(field, instruction);
      case _FieldMode.link when field.result.isNotEmpty:
        _inline(LinkSpec(field.target, field.result, hyperlinkStyle: false));
      case _FieldMode.live:
        final first = field.result.whereType<TextSpec>().firstOrNull;
        _inline(
          FieldSpec(
            _withBookmarkNames(instruction),
            result: field.result.map(_plainText).join(),
            format: first?.format ?? field.format,
          ),
        );
      default:
        break;
    }
  }

  /// A field saved without a result shows what its instruction describes;
  /// one that shows something this reader can't leaves a notice.
  void _resultless(_Field field, String instruction) {
    // Inside another field's instruction it only adds to that instruction.
    if (_target().instruction != null) return;
    final format = field.format;
    switch (_fieldName(instruction)) {
      case _ when isSafeField(instruction):
        _inline(FieldSpec(_withBookmarkNames(instruction), format: format));
      case 'MACROBUTTON' || 'GOTOBUTTON':
        final name = RegExp(r'^\S+\s+\S+\s*').firstMatch(instruction);
        if (name != null && name.end < instruction.length) {
          _text(instruction.substring(name.end), format);
        }
      case 'SYMBOL':
        _symbolField(instruction, format);
      case 'FORMCHECKBOX' || 'FORMDROPDOWN':
        final shown = context.formField(field.formData);
        if (shown == null) {
          context.notices.add(DocumentNotice.contentNotImported);
        } else if (shown.isNotEmpty) {
          _text(shown, format);
        }
      case 'EQ':
        // Only the base of a ruby or an enclosed character stays.
        context.notices.add(DocumentNotice.contentNotImported);
        final base = _equationBase(instruction);
        if (base.isNotEmpty) _text(base, format);
      case final name when !_invisibleFields.contains(name):
        context.notices.add(DocumentNotice.contentNotImported);
    }
  }

  /// The character of a field like `SYMBOL 252 \f "Wingdings"`.
  void _symbolField(String instruction, RunFormat format) {
    final tokens = _tokens(instruction);
    final number = tokens.length < 2 ? '' : tokens[1].$1.toLowerCase();
    final code = number.startsWith('0x')
        ? int.tryParse(number.substring(2), radix: 16)
        : int.tryParse(number);
    String? font;
    var unicode = false;
    var shiftJis = false;
    for (var index = 2; index < tokens.length; index++) {
      switch (tokens[index].$1.toLowerCase()) {
        case r'\f' when index + 1 < tokens.length:
          font = tokens[++index].$1;
        case r'\u':
          unicode = true;
        case r'\j':
          shiftJis = true;
      }
    }
    if (code == null ||
        code < 0x20 ||
        code > 0xFFFF ||
        (code >= 0xD800 && code <= 0xDFFF) ||
        shiftJis) {
      context.notices.add(DocumentNotice.contentNotImported);
    } else if (font != null) {
      _symbol(code, font, format);
    } else {
      _text(
        !unicode && code >= 0x80 && code <= 0xFF
            ? decodeCodePage([code], 1252)
            : String.fromCharCode(code),
        format,
      );
    }
  }

  /// What stays of an overstrike such as a ruby or an enclosed character:
  /// its last argument, the base, like 漢 in `EQ \o\ad(\s\up 9(かん),漢)`.
  static String _equationBase(String instruction) {
    final overstrike = RegExp(
      r'\\o\s*(\\a[lcdr]\s*)?\(',
      caseSensitive: false,
    ).firstMatch(instruction);
    if (overstrike == null) return '';
    var depth = 0;
    var argument = overstrike.end;
    for (var at = overstrike.end; at < instruction.length; at++) {
      switch (instruction[at]) {
        case r'\':
          at++;
        case '(':
          depth++;
        case ')' when depth > 0:
          depth--;
        case ')':
          return instruction
              .substring(argument, at)
              .replaceAllMapped(
                RegExp(
                  r'\\([,;()\\])|\\[a-z]+(\s*-?\d+)?|[()]',
                  caseSensitive: false,
                ),
                (match) => match[1] ?? '',
              )
              .trim();
        case ',' || ';' when depth == 0:
          argument = at + 1;
      }
    }
    return '';
  }

  /// Cross-references name their bookmark as the builder writes it.
  static String _withBookmarkNames(String instruction) {
    final reference = RegExp(
      r'^(REF|PAGEREF|NOTEREF)(\s+)([^\s"\\]+)',
      caseSensitive: false,
    ).firstMatch(instruction);
    if (reference == null) return instruction;
    return '${reference[1]}${reference[2]}${bookmarkName(reference[3]!)}'
        '${instruction.substring(reference.end)}';
  }

  /// At a paragraph end, open links close in this paragraph and reopen in
  /// the next; a field result that spans paragraphs is kept as text.
  void _breakFields() {
    _flushText();
    for (var index = _fields.length - 1; index >= 0; index--) {
      final field = _fields[index];
      final content = [...field.result];
      field.result.clear();
      if (field.mode == _FieldMode.link && content.isNotEmpty) {
        _inline(LinkSpec(field.target, content, hyperlinkStyle: false), index);
      } else if (field.mode == _FieldMode.live) {
        field.mode = _FieldMode.passThrough;
        for (final inline in content) {
          _inline(inline, index);
        }
      }
    }
  }

  static String _fieldName(String instruction) =>
      instruction.split(RegExp(r'\s+')).first.toUpperCase();

  /// A web, e-mail or bookmark target of a HYPERLINK field; null for
  /// others.
  static String? _linkTarget(String instruction) {
    final tokens = _tokens(instruction);
    String? address;
    String? anchor;
    for (var index = 1; index < tokens.length; index++) {
      final (value, quoted) = tokens[index];
      if (!quoted && value.startsWith(r'\')) {
        final hasArgument = const {
          r'\l',
          r'\o',
          r'\t',
        }.contains(value.toLowerCase());
        if (hasArgument && index + 1 < tokens.length) {
          index++;
          if (value.toLowerCase() == r'\l') anchor = tokens[index].$1;
        }
      } else {
        address ??= value;
      }
    }
    if (address == null || address.isEmpty) {
      return anchor == null || anchor.isEmpty ? null : '#$anchor';
    }
    return safeLinkTarget(
      anchor == null || anchor.isEmpty ? address : '$address#$anchor',
    );
  }

  /// Words of a field instruction; quoted text is one word.
  static List<(String, bool)> _tokens(String instruction) {
    final tokens = <(String, bool)>[];
    var at = 0;
    while (at < instruction.length) {
      final char = instruction[at];
      if (char.trim().isEmpty) {
        at++;
      } else if (char == '"') {
        final value = StringBuffer();
        at++;
        while (at < instruction.length && instruction[at] != '"') {
          if (instruction[at] == r'\' &&
              at + 1 < instruction.length &&
              (instruction[at + 1] == r'\' || instruction[at + 1] == '"')) {
            at++;
          }
          value.write(instruction[at]);
          at++;
        }
        at++;
        tokens.add((value.toString(), true));
      } else {
        final start = at;
        while (at < instruction.length && instruction[at].trim().isNotEmpty) {
          at++;
        }
        tokens.add((instruction.substring(start, at), false));
      }
    }
    return tokens;
  }

  static String _plainText(InlineSpec inline) => switch (inline) {
    TextSpec(:final text) => text,
    FieldSpec(:final result) => result,
    LinkSpec(:final children) => children.map(_plainText).join(),
    _ => '',
  };

  // Output

  /// Where content goes: a field's instruction or result, or the paragraph.
  /// [depth] looks only at the fields outside that one.
  ({List<InlineSpec>? list, _Field? instruction}) _target([int? depth]) {
    for (var index = (depth ?? _fields.length) - 1; index >= 0; index--) {
      final field = _fields[index];
      switch (field.mode) {
        case _FieldMode.instruction:
          return (list: null, instruction: field);
        case _FieldMode.link || _FieldMode.live:
          return (list: field.result, instruction: null);
        case _FieldMode.passThrough:
          continue;
      }
    }
    return (list: _inlines, instruction: null);
  }

  void _text(String text, RunFormat format) {
    final target = _target();
    if (target.instruction case final field?) {
      field.instruction.write(text);
      return;
    }
    final list = target.list!;
    if (!identical(list, _pendingTarget) ||
        !identical(format, _pendingFormat)) {
      _flushText();
      _pendingTarget = list;
      _pendingFormat = format;
    }
    _pending.write(text);
  }

  void _flushText() {
    if (_pending.isEmpty) return;
    context.addElement();
    _pendingTarget!.add(TextSpec(_pending.toString(), _pendingFormat!));
    _pending.clear();
  }

  void _inline(InlineSpec inline, [int? depth]) {
    _flushText();
    context.addElement();
    final target = _target(depth);
    if (target.instruction case final field?) {
      field.instruction.write(_plainText(inline));
    } else {
      target.list!.add(inline);
    }
  }

  // Paragraphs and tables

  void _endParagraph(ParaProps props, int? mark) {
    final terminator = mark == null ? null : file.pieces.text[mark];
    if (mark != null) {
      _bookmarks(mark);
      if (terminator == 0x0C && !(sections && _sectionMarks.contains(mark))) {
        _inline(const BreakSpec(BreakKind.page));
      }
    }
    _breakFields();
    final inlines = _inlines;
    _inlines = [];
    if (mark == null && inlines.isEmpty) return;
    var markFormat = const RunFormat();
    if (mark != null) {
      final (base, markProps) = file.charactersAt(mark, props.style);
      if (terminator == 0x0D && markProps.deleted && props.depth == 0) {
        // Accepting a deleted paragraph mark joins the paragraph to the next.
        context.notices.add(DocumentNotice.trackedChangesAccepted);
        _inlines = inlines;
        return;
      }
      markFormat = context.runFormat(base, markProps);
    }
    context.addElement();
    final withinLimit = props.depth <= _maxTableDepth;
    final depth = math.min(props.depth, _maxTableDepth);
    _setDepth(depth);
    final rowEnd = depth == 1
        ? terminator == 0x07 && props.rowEnd
        : props.innerRowEnd;
    if (depth > 0 && withinLimit && rowEnd) {
      _tables[depth - 1].endRow(props.row);
      return;
    }
    _container(depth).add(
      ParagraphSpec(
        inlines,
        format: context.paragraphFormat(props),
        mark: markFormat,
      ),
    );
    final cellEnd = depth == 1 ? terminator == 0x07 : props.innerCell;
    if (depth > 0 && withinLimit && cellEnd) _tables[depth - 1].endCell();
    if (sections && mark != null && depth == 0) _endSections(mark);
  }

  void _endSections(int mark) {
    final all = file.sections;
    while (_section < all.length - 1 && all[_section].end <= mark + 1) {
      final section = all[_section++].props;
      _blocks.add(
        SectionBreakSpec(
          context.page(section),
          kind: DocContext.sectionKind(section),
        ),
      );
    }
  }

  List<BlockSpec> _container(int depth) =>
      depth == 0 ? _blocks : _tables[depth - 1].blocks;

  /// Points between the margins of a column of the section being read.
  double get _columnWidth {
    final all = file.sections;
    if (!sections || _section >= all.length) return context.spec.page.textWidth;
    final page = context.page(all[_section].props);
    return (page.textWidth - (page.columns - 1) * page.columnSpacing) /
        page.columns;
  }

  void _setDepth(int depth) {
    while (_tables.length > depth) {
      final builder = _tables.removeLast();
      final table = builder.build(_tables.isEmpty ? _columnWidth : null);
      if (table != null) _container(_tables.length).add(table);
    }
    while (_tables.length < depth) {
      _tables.add(_TableBuilder());
    }
  }
}

/// Cells and rows of a table as its marks arrive.
class _TableBuilder {
  final _rows = <({List<List<BlockSpec>> cells, RowProps? props})>[];
  var _cells = <List<BlockSpec>>[];

  /// Blocks of the cell being read.
  var blocks = <BlockSpec>[];

  void endCell() {
    _cells.add(blocks);
    blocks = [];
  }

  void endRow(RowProps? props) {
    if (blocks.isNotEmpty) endCell();
    if (_cells.isNotEmpty) _rows.add((cells: _cells, props: props));
    _cells = [];
  }

  /// Rows with different cell edges share one grid: each cell spans the grid
  /// columns between its edges. A centered or right-aligned table is placed
  /// within [textWidth] points, when known.
  TableSpec? build(double? textWidth) {
    endRow(null);
    if (_rows.isEmpty) return null;
    final rows = <({List<_Cell> cells, RowProps? props})>[];
    var width = 9360;
    for (final row in _rows) {
      final props = row.props;
      final edges = [...?props?.boundaries];
      if (edges.length < 2 || !_increasing(edges)) {
        edges
          ..clear()
          ..add(0);
      }
      while (edges.length < row.cells.length + 1) {
        final count = math.max(1, row.cells.length);
        edges.add(edges.last + math.max(width ~/ count, 144));
      }
      width = edges[row.cells.length] - edges.first;
      final cells = <_Cell>[];
      for (final (index, blocks) in row.cells.indexed) {
        final cell = props != null && index < props.cells.length
            ? props.cells[index]
            : null;
        if (index > 0 &&
            (cell?.horizontalMerge ?? 0) >= 2 &&
            cells.isNotEmpty) {
          cells.last.right = edges[index + 1];
          continue;
        }
        cells.add(_Cell(blocks, edges[index], edges[index + 1], cell));
      }
      rows.add((cells: cells, props: props));
    }

    final grid = <int>[];
    for (final position in {
      for (final row in rows)
        for (final cell in row.cells) ...[cell.left, cell.right],
    }.toList()..sort()) {
      if (grid.isEmpty || position - grid.last > 5) grid.add(position);
    }
    final regular = grid.length >= 2 && grid.length <= 64;
    int column(int position) {
      var best = 0;
      for (var index = 1; index < grid.length; index++) {
        if ((grid[index] - position).abs() < (grid[best] - position).abs()) {
          best = index;
        }
      }
      return best;
    }

    final known = rows.where((row) => row.props?.bordersKnown ?? false);
    final first = rows.first.props;
    // A centered or right-aligned table ignores its cells' left positions.
    final free = textWidth == null || grid.length < 2
        ? 0
        : textWidth * 20 - (grid.last - grid.first);
    final indent = switch (first) {
      RowProps(justification: 1) => free / 2,
      RowProps(justification: 2) => free,
      RowProps(:final boundaries, :final gapHalf) when boundaries.isNotEmpty =>
        boundaries.first + gapHalf,
      _ => 0,
    };
    return TableSpec(
      [
        for (final row in rows)
          RowSpec(
            [
              for (final cell in row.cells)
                CellSpec(
                  cell.blocks,
                  span: regular
                      ? math.max(1, column(cell.right) - column(cell.left))
                      : 1,
                  merge: switch (cell.props?.verticalMerge) {
                    3 => CellMerge.restart,
                    1 || 2 => CellMerge.continuation,
                    _ => CellMerge.none,
                  },
                  background: cell.props?.fill,
                  verticalAlign: switch (cell.props?.verticalAlign) {
                    1 => CellAlign.center,
                    2 => CellAlign.bottom,
                    _ => null,
                  },
                ),
            ],
            header: row.props?.header ?? false,
            height: (row.props?.height ?? 0) == 0
                ? null
                : row.props!.height.abs() / 20,
          ),
      ],
      columnWidths: regular
          ? [
              for (var index = 1; index < grid.length; index++)
                (grid[index] - grid[index - 1]) / 20,
            ]
          : null,
      bordered: known.isEmpty || known.any((row) => row.props!.bordered),
      indent: indent.abs() >= 20 ? indent / 20 : null,
    );
  }

  static bool _increasing(List<int> values) {
    for (var index = 1; index < values.length; index++) {
      if (values[index] <= values[index - 1]) return false;
    }
    return true;
  }
}

class _Cell {
  _Cell(this.blocks, this.left, this.right, this.props);

  final List<BlockSpec> blocks;
  final int left;
  int right;
  final CellProps? props;
}
