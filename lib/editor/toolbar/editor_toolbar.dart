import 'package:flutter/material.dart';
import 'package:flutter_quill/flutter_quill.dart';

import '../document_commands.dart';
import '../editor_factory.dart';
import '../editor_session.dart';
import 'toolbar_controls.dart';

class ToolbarActions {
  const ToolbarActions({
    required this.insertImage,
    required this.editLink,
    required this.insertTable,
    required this.removeTable,
    required this.refocus,
  });

  final VoidCallback insertImage;
  final VoidCallback editLink;
  final void Function(int rows, int columns) insertTable;
  final VoidCallback removeTable;
  final VoidCallback refocus;
}

const _fonts = [
  'Arial',
  'Calibri',
  'Cambria',
  'Courier New',
  'Georgia',
  'Times New Roman',
  'Verdana',
];

const _sizes = [8, 9, 10, 10.5, 11, 12, 14, 16, 18, 20, 24, 28, 36, 48, 72];

const _headings = ['Normal', 'Título 1', 'Título 2', 'Título 3'];

const _textColors = [
  ColorChoice('#000000', 'Preto'),
  ColorChoice('#595959', 'Cinza escuro'),
  ColorChoice('#A6A6A6', 'Cinza claro'),
  ColorChoice('#C00000', 'Vermelho escuro'),
  ColorChoice('#FF0000', 'Vermelho'),
  ColorChoice('#ED7D31', 'Laranja'),
  ColorChoice('#BF8F00', 'Dourado'),
  ColorChoice('#00B050', 'Verde'),
  ColorChoice('#00B0F0', 'Azul claro'),
  ColorChoice('#0070C0', 'Azul'),
  ColorChoice('#002060', 'Azul escuro'),
  ColorChoice('#7030A0', 'Roxo'),
];

const _highlights = [
  ColorChoice('#FFFF00', 'Amarelo'),
  ColorChoice('#00FF00', 'Verde-limão'),
  ColorChoice('#00FFFF', 'Turquesa'),
  ColorChoice('#FF00FF', 'Rosa'),
  ColorChoice('#C0C0C0', 'Cinza'),
  ColorChoice('#FF0000', 'Vermelho'),
  ColorChoice('#0000FF', 'Azul'),
  ColorChoice('#008000', 'Verde'),
  ColorChoice('#800080', 'Violeta'),
  ColorChoice('#808000', 'Oliva'),
];

const _lineSpacings = [1.0, 1.15, 1.5, 2.0];

String get _mod => isApplePlatform ? '⌘' : 'Ctrl+';

String _formatNumber(num value) => value == value.roundToDouble()
    ? '${value.toInt()}'
    : '$value'.replaceAll('.', ',');

class EditorToolbar extends StatelessWidget {
  const EditorToolbar({
    required this.session,
    required this.actions,
    super.key,
  });

  final EditorSession session;
  final ToolbarActions actions;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<QuillController>(
      valueListenable: session.activeController,
      builder: (context, controller, _) => ListenableBuilder(
        listenable: Listenable.merge([controller, session.activeCell]),
        builder: (context, _) => SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          child: Row(children: _controls(context, controller)),
        ),
      ),
    );
  }

  List<Widget> _controls(BuildContext context, QuillController controller) {
    final look = session.look;
    final header = controller.valueOf<int>(Attribute.header.key) ?? 0;
    final base = header == 0 ? look.body : look.heading(header);
    final font =
        controller.valueOf<String>(Attribute.font.key) ?? base.fontFamily;
    final sizeValue = controller
        .getSelectionStyle()
        .attributes[Attribute.size.key]
        ?.value;
    final size = num.tryParse('${sizeValue ?? ''}') ?? base.fontSize;
    final align = controller.valueOf<String>(Attribute.align.key) ?? 'left';
    final list = controller.valueOf<String>(Attribute.list.key);
    final lineSpacing =
        (controller
                    .getSelectionStyle()
                    .attributes[Attribute.lineHeight.key]
                    ?.value
                as num?)
            ?.toDouble();

    void apply(VoidCallback change) {
      change();
      actions.refocus();
    }

    return [
      ToolButton(
        icon: Icons.undo,
        tooltip: 'Desfazer (${_mod}Z)',
        onPressed: controller.hasUndo ? controller.undo : null,
      ),
      ToolButton(
        icon: Icons.redo,
        tooltip: 'Refazer (${_mod}Y)',
        onPressed: controller.hasRedo ? controller.redo : null,
      ),
      const ToolGroupDivider(),
      ToolDropdown<int>(
        tooltip: 'Estilo do parágrafo',
        label: header < _headings.length ? _headings[header] : 'Título $header',
        width: 112,
        selected: header,
        options: [
          for (var level = 0; level < _headings.length; level++)
            MenuOption(
              level,
              _headings[level],
              style: level == 0
                  ? null
                  : TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 17 - level.toDouble(),
                    ),
            ),
        ],
        onSelected: (level) => apply(() => controller.setHeading(level)),
      ),
      const SizedBox(width: 6),
      ToolDropdown<String>(
        tooltip: 'Fonte',
        label: font ?? 'Padrão',
        width: 150,
        selected: font,
        options: [
          for (final family in {..._fonts, ?font}.toList()..sort())
            MenuOption(family, family, style: TextStyle(fontFamily: family)),
        ],
        onSelected: (family) => apply(
          () => controller.setInline(
            Attribute.font,
            family == base.fontFamily ? null : family,
          ),
        ),
      ),
      const SizedBox(width: 6),
      ToolDropdown<num>(
        tooltip: 'Tamanho da fonte',
        label: _formatNumber(size),
        width: 68,
        selected: size,
        options: [
          for (final option in {..._sizes, size}.toList()..sort())
            MenuOption(option, _formatNumber(option)),
        ],
        onSelected: (value) => apply(
          () => controller.setInline(
            Attribute.size,
            value == base.fontSize
                ? null
                : _formatNumber(value).replaceAll(',', '.'),
          ),
        ),
      ),
      const ToolGroupDivider(),
      ToolButton(
        icon: Icons.format_bold,
        tooltip: 'Negrito (${_mod}B)',
        selected: controller.isActive(Attribute.bold),
        onPressed: () => controller.toggle(Attribute.bold),
      ),
      ToolButton(
        icon: Icons.format_italic,
        tooltip: 'Itálico (${_mod}I)',
        selected: controller.isActive(Attribute.italic),
        onPressed: () => controller.toggle(Attribute.italic),
      ),
      ToolButton(
        icon: Icons.format_underlined,
        tooltip: 'Sublinhado (${_mod}U)',
        selected: controller.isActive(Attribute.underline),
        onPressed: () => controller.toggle(Attribute.underline),
      ),
      ToolButton(
        icon: Icons.strikethrough_s,
        tooltip: 'Tachado',
        selected: controller.isActive(Attribute.strikeThrough),
        onPressed: () => controller.toggle(Attribute.strikeThrough),
      ),
      ColorPaletteButton(
        icon: Icons.format_color_text,
        tooltip: 'Cor da fonte',
        clearLabel: 'Automática',
        choices: _textColors,
        current: controller.valueOf<String>(Attribute.color.key),
        onSelected: (hex) =>
            apply(() => controller.setInline(Attribute.color, hex)),
      ),
      ColorPaletteButton(
        icon: Icons.border_color,
        tooltip: 'Cor de realce',
        clearLabel: 'Sem realce',
        choices: _highlights,
        current: controller.valueOf<String>(Attribute.background.key),
        onSelected: (hex) =>
            apply(() => controller.setInline(Attribute.background, hex)),
      ),
      ToolButton(
        icon: Icons.format_clear,
        tooltip: 'Limpar formatação',
        onPressed: controller.clearFormatting,
      ),
      const ToolGroupDivider(),
      for (final (value, icon, label, key) in const [
        ('left', Icons.format_align_left, 'Alinhar à esquerda', 'L'),
        ('center', Icons.format_align_center, 'Centralizar', 'E'),
        ('right', Icons.format_align_right, 'Alinhar à direita', 'R'),
        ('justify', Icons.format_align_justify, 'Justificar', 'J'),
      ])
        ToolButton(
          icon: icon,
          tooltip: '$label ($_mod$key)',
          selected: align == value,
          onPressed: () => controller.setAlignment(value),
        ),
      const ToolGroupDivider(),
      ToolButton(
        icon: Icons.format_list_bulleted,
        tooltip: 'Marcadores',
        selected: list == 'bullet',
        onPressed: () => controller.toggleList(Attribute.ul),
      ),
      ToolButton(
        icon: Icons.format_list_numbered,
        tooltip: 'Numeração',
        selected: list == 'ordered',
        onPressed: () => controller.toggleList(Attribute.ol),
      ),
      ToolButton(
        icon: Icons.format_indent_decrease,
        tooltip: 'Diminuir recuo',
        onPressed: () => controller.indentSelection(false),
      ),
      ToolButton(
        icon: Icons.format_indent_increase,
        tooltip: 'Aumentar recuo',
        onPressed: () => controller.indentSelection(true),
      ),
      _LineSpacingButton(
        current: lineSpacing ?? look.lineSpacing,
        onSelected: (value) => apply(
          () => controller.setLineSpacing(
            (value - look.lineSpacing).abs() < 0.01 ? null : value,
          ),
        ),
      ),
      const ToolGroupDivider(),
      ToolButton(
        icon: Icons.link,
        tooltip: 'Link (${_mod}K)',
        selected: controller.valueOf<String>(Attribute.link.key) != null,
        onPressed: actions.editLink,
      ),
      ToolButton(
        icon: Icons.image_outlined,
        tooltip: 'Inserir imagem',
        onPressed: actions.insertImage,
      ),
      MenuAnchor(
        menuChildren: [TableSizePicker(onSelected: actions.insertTable)],
        builder: (context, menu, _) => ToolButton(
          icon: Icons.table_chart_outlined,
          tooltip: 'Inserir tabela',
          onPressed: () => menu.isOpen ? menu.close() : menu.open(),
        ),
      ),
      ToolButton(
        icon: Icons.insert_page_break_outlined,
        tooltip: 'Quebra de página (${_mod}Enter)',
        onPressed: controller.insertPageBreak,
      ),
      if (session.activeCell.value != null) ...[
        const ToolGroupDivider(),
        _TableMenu(session: session, onRemoveTable: actions.removeTable),
      ],
    ];
  }
}

class _LineSpacingButton extends StatelessWidget {
  const _LineSpacingButton({required this.current, required this.onSelected});

  final double current;
  final ValueChanged<double> onSelected;

  @override
  Widget build(BuildContext context) {
    return MenuAnchor(
      menuChildren: [
        for (final value in _lineSpacings)
          MenuItemButton(
            onPressed: () => onSelected(value),
            leadingIcon: Icon(
              Icons.check,
              size: 16,
              color: (value - current).abs() < 0.01 ? null : Colors.transparent,
            ),
            child: Text(
              value.toStringAsFixed(value == 1.15 ? 2 : 1).replaceAll('.', ','),
            ),
          ),
      ],
      builder: (context, menu, _) => ToolButton(
        icon: Icons.format_line_spacing,
        tooltip: 'Espaçamento entre linhas',
        onPressed: () => menu.isOpen ? menu.close() : menu.open(),
      ),
    );
  }
}

class _TableMenu extends StatelessWidget {
  const _TableMenu({required this.session, required this.onRemoveTable});

  final EditorSession session;
  final VoidCallback onRemoveTable;

  @override
  Widget build(BuildContext context) {
    final cell = session.activeCell.value!;
    final table = cell.table;
    final tables = session.tables;
    final merged = table.hasMergedCells;

    void change(VoidCallback action) {
      action();
      session.focusMain();
    }

    return MenuAnchor(
      menuChildren: [
        MenuItemButton(
          leadingIcon: const Icon(Icons.vertical_align_top, size: 18),
          onPressed: () => change(
            () => tables.insertRow(table, cell.row, copyFrom: cell.row),
          ),
          child: const Text('Inserir linha acima'),
        ),
        MenuItemButton(
          leadingIcon: const Icon(Icons.vertical_align_bottom, size: 18),
          onPressed: () => change(
            () => tables.insertRow(table, cell.row + 1, copyFrom: cell.row),
          ),
          child: const Text('Inserir linha abaixo'),
        ),
        MenuItemButton(
          leadingIcon: const Icon(Icons.border_left, size: 18),
          onPressed: merged
              ? null
              : () => change(() => tables.insertColumn(table, cell.column)),
          child: const Text('Inserir coluna à esquerda'),
        ),
        MenuItemButton(
          leadingIcon: const Icon(Icons.border_right, size: 18),
          onPressed: merged
              ? null
              : () => change(() => tables.insertColumn(table, cell.column + 1)),
          child: const Text('Inserir coluna à direita'),
        ),
        const Divider(height: 8),
        MenuItemButton(
          leadingIcon: const Icon(Icons.remove, size: 18),
          onPressed: table.rows.length > 1
              ? () => change(() => tables.removeRow(table, cell.row))
              : null,
          child: const Text('Excluir linha'),
        ),
        MenuItemButton(
          leadingIcon: const Icon(Icons.remove, size: 18),
          onPressed: merged || table.columnWidths.length <= 1
              ? null
              : () => change(() => tables.removeColumn(table, cell.column)),
          child: const Text('Excluir coluna'),
        ),
        MenuItemButton(
          leadingIcon: const Icon(Icons.delete_outline, size: 18),
          onPressed: onRemoveTable,
          child: const Text('Excluir tabela'),
        ),
      ],
      builder: (context, menu, _) => TextButton.icon(
        onPressed: () => menu.isOpen ? menu.close() : menu.open(),
        icon: const Icon(Icons.table_rows_outlined, size: 18),
        label: const Text('Tabela'),
      ),
    );
  }
}
