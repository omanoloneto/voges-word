import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_quill/flutter_quill.dart';

import '../../document/embeds.dart';
import '../../document/tables.dart';

class TableCellRef {
  const TableCellRef(this.table, this.row, this.column);

  final TableModel table;
  final int row;
  final int column;

  TableCellModel get cell => table.rows[row].cells[column];
}

typedef CellFocusCallback =
    void Function(TableCellRef cell, FocusNode focusNode);

typedef CellEditorBuilder =
    Widget Function(
      TableCellRef cell,
      FocusNode focusNode,
      ScrollController scrollController,
    );

class TableEmbedBuilder extends EmbedBuilder {
  const TableEmbedBuilder({
    required this.tables,
    required this.cellEditor,
    required this.maxWidth,
    required this.onCellFocused,
  });

  final TableStore tables;
  final CellEditorBuilder cellEditor;

  /// Largura útil da página em pixels; tabelas maiores são reduzidas.
  final double maxWidth;
  final CellFocusCallback onCellFocused;

  @override
  String get key => EmbedTypes.table;

  @override
  String toPlainText(Embed node) => '';

  @override
  Widget build(BuildContext context, EmbedContext embedContext) {
    final table = tables[tableIdOf(embedContext.node.value.data)];
    if (table == null) {
      return const Text(
        '[tabela indisponível]',
        style: TextStyle(color: Color(0xFF9E9E9E)),
      );
    }
    return TableView(
      key: ObjectKey(table),
      table: table,
      cellEditor: cellEditor,
      maxWidth: maxWidth,
      onCellFocused: onCellFocused,
    );
  }
}

class TableView extends StatelessWidget {
  const TableView({
    required this.table,
    required this.cellEditor,
    required this.maxWidth,
    required this.onCellFocused,
    super.key,
  });

  final TableModel table;
  final CellEditorBuilder cellEditor;
  final double maxWidth;
  final CellFocusCallback onCellFocused;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: table,
      builder: (context, _) {
        final scaler = MediaQuery.textScalerOf(context);
        final widths = [
          for (final twips in table.columnWidths) scaler.scale(twips / 20),
        ];
        final total = widths.fold<double>(0, (sum, width) => sum + width);
        final fit = total > maxWidth && total > 0 ? maxWidth / total : 1.0;
        final padding = scaler.scale(5.4);
        final lineColor = table.bordered
            ? const Color(0xFF000000)
            : const Color(0xFFD0D0D0);
        final border = BorderSide(color: lineColor, width: 0.8);

        final rows = <Widget>[];
        for (var r = 0; r < table.rows.length; r++) {
          final row = table.rows[r];
          final cells = <Widget>[];
          var column = 0;
          for (var c = 0; c < row.cells.length; c++) {
            final cell = row.cells[c];
            final span = math.max(cell.gridSpan, 1);
            var width = 0.0;
            for (
              var i = column;
              i < math.min(column + span, widths.length);
              i++
            ) {
              width += widths[i];
            }
            if (width <= 0) width = 40;
            final mergesDown = _continuesBelow(r, column);
            column += span;

            cells.add(
              SizedBox(
                width: width * fit,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: cell.fill,
                    border: Border(
                      left: c == 0 ? border : BorderSide.none,
                      top: r == 0 ? border : BorderSide.none,
                      right: border,
                      bottom: mergesDown ? BorderSide.none : border,
                    ),
                  ),
                  child: cell.verticalMerge == VerticalMerge.continuation
                      ? const SizedBox.shrink()
                      : Padding(
                          padding: EdgeInsets.symmetric(
                            horizontal: padding,
                            vertical: 1,
                          ),
                          child: _CellEditor(
                            key: ObjectKey(cell.controller),
                            cell: TableCellRef(table, r, c),
                            builder: cellEditor,
                            onFocused: onCellFocused,
                          ),
                        ),
                ),
              ),
            );
          }
          rows.add(
            IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisSize: MainAxisSize.min,
                children: cells,
              ),
            ),
          );
        }
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: rows,
          ),
        );
      },
    );
  }

  bool _continuesBelow(int row, int gridColumn) {
    if (row + 1 >= table.rows.length) return false;
    var column = 0;
    for (final cell in table.rows[row + 1].cells) {
      if (column == gridColumn) {
        return cell.verticalMerge == VerticalMerge.continuation;
      }
      column += math.max(cell.gridSpan, 1);
      if (column > gridColumn) return false;
    }
    return false;
  }
}

class _CellEditor extends StatefulWidget {
  const _CellEditor({
    required this.cell,
    required this.builder,
    required this.onFocused,
    super.key,
  });

  final TableCellRef cell;
  final CellEditorBuilder builder;
  final CellFocusCallback onFocused;

  @override
  State<_CellEditor> createState() => _CellEditorState();
}

class _CellEditorState extends State<_CellEditor> {
  final _focusNode = FocusNode(debugLabel: 'table-cell');
  final _scrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    _focusNode.addListener(() {
      if (_focusNode.hasFocus) widget.onFocused(widget.cell, _focusNode);
    });
  }

  @override
  void dispose() {
    _focusNode.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      widget.builder(widget.cell, _focusNode, _scrollController);
}
