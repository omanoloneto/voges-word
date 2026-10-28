import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:flutter/services.dart';
import 'package:flutter_quill/flutter_quill.dart';
import 'package:flutter_quill/quill_delta.dart';

enum VerticalMerge { none, restart, continuation }

class TableCellModel {
  TableCellModel({
    required this.controller,
    this.propertiesXml,
    this.gridSpan = 1,
    this.verticalMerge = VerticalMerge.none,
    this.fill,
  });

  final QuillController controller;

  /// Original w:tcPr.
  String? propertiesXml;
  int gridSpan;
  VerticalMerge verticalMerge;
  Color? fill;
}

class TableRowModel {
  TableRowModel({required this.cells, this.propertiesXml});

  final List<TableCellModel> cells;

  /// Original w:trPr.
  final String? propertiesXml;
}

class TableModel extends ChangeNotifier {
  TableModel({
    required this.id,
    required this.rows,
    required this.columnWidths,
    required this.bordered,
    this.packageId,
    this.propertiesXml,
  });

  final String id;
  final String? packageId;
  final List<TableRowModel> rows;

  /// Grid column widths in twips.
  final List<double> columnWidths;

  /// Original w:tblPr.
  final String? propertiesXml;
  final bool bordered;

  bool get hasMergedCells => rows.any(
    (row) => row.cells.any(
      (cell) => cell.gridSpan > 1 || cell.verticalMerge != VerticalMerge.none,
    ),
  );

  void changed() => notifyListeners();
}

/// Holds the document's tables; the editor's text only references their id.
class TableStore {
  final _tables = <String, TableModel>{};
  final _edits = StreamController<void>.broadcast();
  var _counter = 0;

  /// Emits on every edit made inside any cell.
  Stream<void> get edits => _edits.stream;

  TableModel? operator [](String id) => _tables[id];

  Iterable<TableModel> get all => _tables.values;

  String nextId() => 't${++_counter}';

  void add(TableModel table) => _tables[table.id] = table;

  QuillController newCellController([Delta? content]) {
    final delta = content == null || content.isEmpty
        ? (Delta()..insert('\n'))
        : content;
    final controller = QuillController(
      document: Document.fromDelta(delta),
      selection: const TextSelection.collapsed(offset: 0),
    );
    controller.document.changes.listen((change) {
      if (change.source == ChangeSource.local) _edits.add(null);
    });
    return controller;
  }

  TableModel createEmpty({
    required int rows,
    required int columns,
    required double totalWidth,
  }) {
    final width = totalWidth / columns;
    final table = TableModel(
      id: nextId(),
      bordered: true,
      columnWidths: List.filled(columns, width),
      rows: [
        for (var r = 0; r < rows; r++)
          TableRowModel(
            cells: [
              for (var c = 0; c < columns; c++)
                TableCellModel(controller: newCellController()),
            ],
          ),
      ],
    );
    add(table);
    return table;
  }

  void insertRow(TableModel table, int index, {required int copyFrom}) {
    final source = table.rows[copyFrom];
    table.rows.insert(
      index,
      TableRowModel(
        propertiesXml: source.propertiesXml,
        cells: [
          for (final cell in source.cells)
            TableCellModel(
              controller: newCellController(),
              propertiesXml: _withoutVerticalMerge(cell.propertiesXml),
              gridSpan: cell.gridSpan,
              fill: cell.fill,
            ),
        ],
      ),
    );
    _structureChanged(table);
  }

  void removeRow(TableModel table, int index) {
    if (table.rows.length <= 1) return;
    table.rows.removeAt(index);
    _structureChanged(table);
  }

  void insertColumn(TableModel table, int index) {
    if (table.hasMergedCells) return;
    final copyFrom = index == 0 ? 0 : index - 1;
    final width = table.columnWidths[copyFrom];
    table.columnWidths.insert(index, width);
    for (final row in table.rows) {
      final source = row.cells[copyFrom];
      row.cells.insert(
        index,
        TableCellModel(
          controller: newCellController(),
          propertiesXml: source.propertiesXml,
          fill: source.fill,
        ),
      );
    }
    _structureChanged(table);
  }

  void removeColumn(TableModel table, int index) {
    if (table.hasMergedCells || table.columnWidths.length <= 1) return;
    table.columnWidths.removeAt(index);
    for (final row in table.rows) {
      row.cells.removeAt(index);
    }
    _structureChanged(table);
  }

  void _structureChanged(TableModel table) {
    table.changed();
    _edits.add(null);
  }

  static String? _withoutVerticalMerge(String? xml) =>
      xml?.replaceAll(RegExp(r'<w:vMerge\b[^>]*/>'), '');
}
