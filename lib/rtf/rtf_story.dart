import 'dart:math' as math;

import '../document/document_codec.dart';
import '../docx/docx_builder.dart';

/// Caps what one file may hold, so hostile input fails fast instead of
/// exhausting memory.
class RtfBudget {
  static const maxElements = 500000;
  static const maxText = 50000000;

  var _elements = 0;
  var _text = 0;

  void spend({int elements = 1, int text = 0}) {
    _elements += elements;
    _text += text;
    if (_elements > maxElements || _text > maxText) {
      throw DocumentProblemException(DocumentProblem.tooLarge);
    }
  }
}

bool sameRunFormat(RunFormat a, RunFormat b) =>
    identical(a, b) ||
    (a.styleId == b.styleId &&
        a.font == b.font &&
        a.size == b.size &&
        a.bold == b.bold &&
        a.italic == b.italic &&
        a.underline == b.underline &&
        a.strike == b.strike &&
        a.allCaps == b.allCaps &&
        a.smallCaps == b.smallCaps &&
        a.hidden == b.hidden &&
        a.color == b.color &&
        a.background == b.background &&
        a.position == b.position);

/// The inline content of the paragraph being read.
class RtfParagraph {
  RtfParagraph(this._budget);

  final RtfBudget _budget;
  final inlines = <InlineSpec>[];
  final _text = StringBuffer();
  RunFormat _format = const RunFormat();

  bool get isEmpty => inlines.isEmpty && _text.isEmpty;

  void addText(String text, RunFormat format) {
    if (text.isEmpty) return;
    if (!sameRunFormat(_format, format)) flush();
    _format = format;
    _text.write(text);
    _budget.spend(elements: 0, text: text.length);
  }

  void add(InlineSpec inline) {
    flush();
    inlines.add(inline);
    _budget.spend();
  }

  /// Turns the pending text into a [TextSpec].
  void flush() {
    if (_text.isEmpty) return;
    inlines.add(TextSpec(_text.toString(), _format));
    _text.clear();
    _budget.spend();
  }
}

/// Cell properties of a row definition, up to its `\cellx`.
class RtfCellDefinition {
  /// Twips from the left margin.
  int right = 0;
  bool mergesWithPrevious = false;
  CellMerge vertical = CellMerge.none;

  /// RRGGBB.
  String? fill;
  CellAlign? align;
}

/// What `\trowd` and the keywords after it say about a table row.
class RtfRowDefinition {
  static const maxCells = 63;

  int left = 0;
  int gap = 0;
  bool header = false;

  /// Twips; negative is an exact height.
  int? height;
  bool bordered = false;
  final cells = <RtfCellDefinition>[];
  var pending = RtfCellDefinition();

  void closeCell(int right) {
    if (cells.length < maxCells) cells.add(pending..right = right);
    pending = RtfCellDefinition();
  }
}

class _Row {
  _Row(this.cells, this.definition);

  final List<List<BlockSpec>> cells;
  final RtfRowDefinition? definition;
}

class _TableLevel {
  final rows = <_Row>[];
  var cells = <List<BlockSpec>>[];
  var cell = <BlockSpec>[];

  bool get hasContent => rows.isNotEmpty || cells.isNotEmpty || cell.isNotEmpty;
}

class _CellLayout {
  _CellLayout(this.blocks, this.right, this.definition);

  final List<BlockSpec> blocks;
  int right;
  final RtfCellDefinition? definition;
}

/// The blocks of one story (body, header, note, text box): RTF tables are
/// paragraphs marked as in a table, so they are assembled here.
class RtfStory {
  RtfStory(this._budget);

  /// Deeper tables go into the cells of the deepest one kept.
  static const maxTableDepth = 32;
  static const _minCellWidth = 20;
  static const _gridTolerance = 10;

  /// Twips shared by the cells of a row that has no definition.
  static const _rowWidth = 9000;

  final RtfBudget _budget;

  final _blocks = <BlockSpec>[];
  late var paragraph = RtfParagraph(_budget);
  final _levels = <_TableLevel>[];
  final _deferred = <BlockSpec>[];

  /// Row definitions by table nesting level.
  final definitions = <int, RtfRowDefinition>{};

  /// The old-style numbered list (`\pn`) the last paragraph belonged to.
  ({String key, int id})? numbering;

  /// Placed after the current paragraph, in the same container.
  void defer(Iterable<BlockSpec> blocks) => _deferred.addAll(blocks);

  RtfRowDefinition definition(int level) =>
      definitions.putIfAbsent(level, RtfRowDefinition.new);

  void startRow(int level) => definitions[level] = RtfRowDefinition();

  /// Ends the paragraph at table nesting [level] (0 outside tables).
  void endParagraph(
    ParagraphSpec Function(List<InlineSpec> inlines) build,
    int level,
  ) {
    paragraph.flush();
    final spec = build(paragraph.inlines);
    paragraph = RtfParagraph(_budget);
    _budget.spend();
    _place(spec, level);
    if (_deferred.isNotEmpty) {
      for (final block in _deferred) {
        _place(block, level);
      }
      _deferred.clear();
    }
  }

  void endCell(
    ParagraphSpec Function(List<InlineSpec> inlines) build,
    int level,
  ) {
    final depth = _depth(level);
    endParagraph(build, depth);
    final table = _levels[depth - 1];
    table.cells.add(table.cell);
    table.cell = [];
    _budget.spend();
  }

  void endRow(
    ParagraphSpec Function(List<InlineSpec> inlines) build,
    int level,
  ) {
    final depth = _depth(level);
    if (!paragraph.isEmpty) endCell(build, depth);
    _ensureDepth(depth);
    final table = _levels[depth - 1];
    if (table.cell.isNotEmpty) {
      table.cells.add(table.cell);
      table.cell = [];
    }
    if (table.cells.isEmpty) return;
    table.rows.add(_Row(table.cells, definitions[depth]));
    table.cells = [];
    _budget.spend();
  }

  /// Ends the tables in progress, as a paragraph outside them does.
  void closeTables() => _ensureDepth(0);

  /// A block outside tables, like a section break.
  void add(BlockSpec block) {
    closeTables();
    _blocks.add(block);
    _budget.spend();
  }

  List<BlockSpec> finish() {
    closeTables();
    _blocks.addAll(_deferred);
    _deferred.clear();
    return _blocks;
  }

  static int _depth(int level) => level.clamp(1, maxTableDepth);

  void _place(BlockSpec block, int level) {
    _ensureDepth(level.clamp(0, maxTableDepth));
    if (_levels.isEmpty) {
      _blocks.add(block);
    } else {
      _levels.last.cell.add(block);
    }
  }

  void _ensureDepth(int depth) {
    while (_levels.length > depth) {
      final definition = definitions.remove(_levels.length);
      final level = _levels.removeLast();
      if (level.cell.isNotEmpty) level.cells.add(level.cell);
      if (level.cells.isNotEmpty) level.rows.add(_Row(level.cells, definition));
      if (level.rows.isEmpty) continue;
      final table = _table(level.rows);
      if (_levels.isEmpty) {
        _blocks.add(table);
      } else {
        _levels.last.cell.add(table);
      }
    }
    while (_levels.length < depth) {
      _levels.add(_TableLevel());
    }
  }

  TableSpec _table(List<_Row> rows) {
    final layouts = [for (final row in rows) _layout(row)];
    final rights = <int>{
      for (final layout in layouts)
        for (final cell in layout) cell.right,
    }.toList()..sort();
    final grid = <int>[0];
    for (final right in rights) {
      if (right - grid.last > _gridTolerance) grid.add(right);
    }
    // Word's grid has at most 63 columns; beyond that the cells share the
    // width evenly.
    final regular = grid.length - 1 <= RtfRowDefinition.maxCells;
    int columnOf(int right) {
      var best = 1;
      for (var index = 2; index < grid.length; index++) {
        if ((grid[index] - right).abs() < (grid[best] - right).abs()) {
          best = index;
        }
      }
      return best;
    }

    final specs = <RowSpec>[];
    for (final (index, layout) in layouts.indexed) {
      final definition = rows[index].definition;
      final cells = <CellSpec>[];
      var column = 0;
      for (final cell in layout) {
        var span = 1;
        if (regular) {
          final end = math.max(columnOf(cell.right), column + 1);
          span = end - column;
          column = end;
        }
        cells.add(
          CellSpec(
            cell.blocks,
            span: span,
            merge: cell.definition?.vertical ?? CellMerge.none,
            background: cell.definition?.fill,
            verticalAlign: cell.definition?.align,
          ),
        );
      }
      specs.add(
        RowSpec(
          cells,
          header: definition?.header ?? false,
          height: switch (definition?.height) {
            final height? when height != 0 => height.abs() / 20,
            _ => null,
          },
        ),
      );
    }
    final first = rows.first.definition;
    final indent = first == null ? 0 : first.left + first.gap;
    return TableSpec(
      specs,
      columnWidths: regular
          ? [
              for (var index = 1; index < grid.length; index++)
                (grid[index] - grid[index - 1]) / 20,
            ]
          : null,
      bordered: rows.any((row) => row.definition?.bordered ?? false),
      indent: indent.abs() >= 20 ? indent / 20 : null,
    );
  }

  /// Cell right edges from the row's left edge; `\clmrg` cells join the cell
  /// before them.
  List<_CellLayout> _layout(_Row row) {
    final definition = row.definition;
    final defined = definition?.cells ?? const <RtfCellDefinition>[];
    final left = definition?.left ?? 0;
    final fallback = defined.isEmpty
        ? _rowWidth ~/ math.max(row.cells.length, 1)
        : (defined.last.right - left) ~/ defined.length;
    final cells = <_CellLayout>[];
    var right = 0;
    for (var index = 0; index < row.cells.length; index++) {
      final cell = index < defined.length ? defined[index] : null;
      final position = cell == null ? right + fallback : cell.right - left;
      right = math.max(position, right + _minCellWidth);
      if (cells.isNotEmpty &&
          (cell?.mergesWithPrevious == true ||
              cells.length >= RtfRowDefinition.maxCells)) {
        cells.last.right = right;
        if (!_isBlank(row.cells[index])) {
          cells.last.blocks.addAll(row.cells[index]);
        }
        continue;
      }
      cells.add(_CellLayout(row.cells[index], right, cell));
    }
    return cells;
  }

  static bool _isBlank(List<BlockSpec> blocks) =>
      blocks.every((block) => block is ParagraphSpec && block.inlines.isEmpty);
}
