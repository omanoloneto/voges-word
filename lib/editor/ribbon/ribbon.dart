import 'package:flutter/material.dart';
import 'package:flutter_quill/flutter_quill.dart';

import '../../document/document_look.dart';
import '../../document/page_setup.dart';
import '../../fonts/font_catalog.dart';
import '../document_commands.dart';
import '../editor_factory.dart';
import '../editor_session.dart';
import '../page_numbers.dart';
import '../embeds/table_embed.dart';
import 'font_picker.dart';
import 'ribbon_controls.dart';
import 'ribbon_style.dart';

class RibbonActions {
  const RibbonActions({
    required this.insertImage,
    required this.editLink,
    required this.insertTable,
    required this.removeTable,
    required this.editHeadersFooters,
    required this.refocus,
    required this.pagesView,
    required this.onPagesView,
    required this.zoom,
    required this.onZoom,
  });

  final VoidCallback insertImage;
  final VoidCallback editLink;
  final void Function(int rows, int columns) insertTable;
  final VoidCallback removeTable;
  final VoidCallback editHeadersFooters;
  final VoidCallback refocus;
  final bool pagesView;
  final ValueChanged<bool> onPagesView;
  final double zoom;
  final ValueChanged<double> onZoom;
}

enum RibbonTab {
  home('Início'),
  insert('Inserir'),
  layout('Layout'),
  view('Exibir'),
  table('Tabela');

  const RibbonTab(this.label);

  final String label;
}

const zoomLevels = [0.5, 0.75, 0.9, 1.0, 1.1, 1.25, 1.5, 1.75, 2.0];

const _sizes = <num>[
  8,
  9,
  10,
  10.5,
  11,
  12,
  14,
  16,
  18,
  20,
  24,
  28,
  36,
  48,
  72,
];

const _quickTextColors = [
  ColorChoice('#C00000', 'Vermelho escuro'),
  ColorChoice('#0070C0', 'Azul'),
  ColorChoice('#00B050', 'Verde'),
  ColorChoice('#ED7D31', 'Laranja'),
];

const _textPalette = [
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

/// Cores de realce do Word, que voltam como realce de verdade no .docx.
const _quickHighlights = [
  ColorChoice('#FFFF00', 'Amarelo'),
  ColorChoice('#00FF00', 'Verde-limão'),
  ColorChoice('#00FFFF', 'Turquesa'),
  ColorChoice('#FF00FF', 'Rosa'),
];

const _highlightPalette = [
  ..._quickHighlights,
  ColorChoice('#C0C0C0', 'Cinza'),
  ColorChoice('#FF0000', 'Vermelho'),
  ColorChoice('#0000FF', 'Azul'),
  ColorChoice('#008000', 'Verde'),
  ColorChoice('#800080', 'Violeta'),
  ColorChoice('#808000', 'Oliva'),
];

const _lineSpacings = [1.0, 1.15, 1.5, 2.0];

String get _mod => isApplePlatform ? '⌘' : 'Ctrl+';

String _number(num value) => value == value.roundToDouble()
    ? '${value.toInt()}'
    : '$value'.replaceAll('.', ',');

class Ribbon extends StatefulWidget {
  const Ribbon({
    required this.session,
    required this.fonts,
    required this.actions,
    super.key,
  });

  final EditorSession session;
  final FontCatalog fonts;
  final RibbonActions actions;

  @override
  State<Ribbon> createState() => _RibbonState();
}

class _RibbonState extends State<Ribbon> {
  var _tab = RibbonTab.home;
  var _lastTextColor = '#C00000';
  var _lastHighlight = '#FFFF00';

  EditorSession get session => widget.session;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder(
      valueListenable: session.activeCell,
      builder: (context, cell, _) {
        final inTable = cell != null;
        final tab = _tab == RibbonTab.table && !inTable ? RibbonTab.home : _tab;
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Align(
              alignment: Alignment.centerLeft,
              child: SizedBox(
                height: 34,
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: Row(
                    children: [
                      for (final item in RibbonTab.values)
                        if (item != RibbonTab.table || inTable)
                          _TabButton(
                            tab: item,
                            active: item == tab,
                            contextual: item == RibbonTab.table,
                            onTap: () => setState(() => _tab = item),
                          ),
                    ],
                  ),
                ),
              ),
            ),
            Container(
              margin: const EdgeInsets.fromLTRB(8, 0, 8, 8),
              decoration: BoxDecoration(
                color: RibbonColors.panel,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                  color: RibbonColors.panelBorder.withValues(alpha: 0.5),
                ),
              ),
              child: SizedBox(
                height: 94,
                width: double.infinity,
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 4,
                    vertical: 4,
                  ),
                  child: switch (tab) {
                    RibbonTab.home => _homeTab(),
                    RibbonTab.insert => _insertTab(),
                    RibbonTab.layout => _layoutTab(),
                    RibbonTab.view => _viewTab(),
                    RibbonTab.table => _tableTab(cell!),
                  },
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _withController(Widget Function(QuillController controller) builder) {
    return ValueListenableBuilder<QuillController>(
      valueListenable: session.activeController,
      builder: (context, controller, _) => ListenableBuilder(
        listenable: controller,
        builder: (context, _) => builder(controller),
      ),
    );
  }

  void _apply(VoidCallback change) {
    change();
    widget.actions.refocus();
  }

  Future<void> _loadFont(String family) async {
    final fonts = widget.fonts;
    if (await fonts.ensureLoaded(family) || !fonts.canProvide(family)) return;
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          'Não foi possível baixar a fonte "$family". Verifique a internet.',
        ),
      ),
    );
  }

  Widget _homeTab() => _withController((controller) {
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
            ?.toDouble() ??
        look.lineSpacing;

    return Row(
      children: [
        RibbonGroup(
          label: 'Fonte',
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  FontPicker(
                    fonts: widget.fonts,
                    current: font,
                    documentFonts: session.fontsInUse,
                    onSelected: (family) {
                      _apply(
                        () => controller.setInline(
                          Attribute.font,
                          family == base.fontFamily ? null : family,
                        ),
                      );
                      _loadFont(family);
                    },
                  ),
                  const SizedBox(width: 6),
                  SizeStepper(
                    label: _number(size),
                    sizes: _sizes,
                    current: size,
                    onSelected: (value) => _apply(
                      () => controller.setInline(
                        Attribute.size,
                        value == base.fontSize ? null : '$value',
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (final (attribute, icon, tip)
                      in <(Attribute, IconData, String)>[
                        (
                          Attribute.bold,
                          Icons.format_bold,
                          'Negrito (${_mod}B)',
                        ),
                        (
                          Attribute.italic,
                          Icons.format_italic,
                          'Itálico (${_mod}I)',
                        ),
                        (
                          Attribute.underline,
                          Icons.format_underlined,
                          'Sublinhado (${_mod}U)',
                        ),
                        (
                          Attribute.strikeThrough,
                          Icons.strikethrough_s,
                          'Tachado',
                        ),
                        (
                          Attribute.superscript,
                          Icons.superscript,
                          'Sobrescrito',
                        ),
                        (Attribute.subscript, Icons.subscript, 'Subscrito'),
                      ])
                    RibbonIconButton(
                      icon: icon,
                      tooltip: tip,
                      selected: controller.isActive(attribute),
                      onPressed: () => controller.toggle(attribute),
                    ),
                  RibbonIconButton(
                    icon: Icons.format_clear,
                    tooltip: 'Limpar formatação',
                    onPressed: controller.clearFormatting,
                  ),
                ],
              ),
            ],
          ),
        ),
        const RibbonGroupDivider(),
        RibbonGroup(
          label: 'Cor',
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              ColorRow(
                icon: Icons.format_color_text,
                tooltip: 'Cor da fonte',
                quick: _quickTextColors,
                palette: _textPalette,
                current: controller.valueOf<String>(Attribute.color.key),
                lastUsed: _lastTextColor,
                clearLabel: 'Automática',
                onSelected: (hex) => _apply(() {
                  if (hex != null) setState(() => _lastTextColor = hex);
                  controller.setInline(Attribute.color, hex);
                }),
              ),
              const SizedBox(height: 6),
              ColorRow(
                icon: Icons.border_color,
                tooltip: 'Cor de realce',
                quick: _quickHighlights,
                palette: _highlightPalette,
                current: controller.valueOf<String>(Attribute.background.key),
                lastUsed: _lastHighlight,
                clearLabel: 'Sem realce',
                onSelected: (hex) => _apply(() {
                  if (hex != null) setState(() => _lastHighlight = hex);
                  controller.setInline(Attribute.background, hex);
                }),
              ),
            ],
          ),
        ),
        const RibbonGroupDivider(),
        RibbonGroup(
          label: 'Parágrafo',
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (final (value, icon, tip, key) in const [
                    (
                      'left',
                      Icons.format_align_left,
                      'Alinhar à esquerda',
                      'L',
                    ),
                    ('center', Icons.format_align_center, 'Centralizar', 'E'),
                    (
                      'right',
                      Icons.format_align_right,
                      'Alinhar à direita',
                      'R',
                    ),
                    ('justify', Icons.format_align_justify, 'Justificar', 'J'),
                  ])
                    RibbonIconButton(
                      icon: icon,
                      tooltip: '$tip ($_mod$key)',
                      selected: align == value,
                      onPressed: () => controller.setAlignment(value),
                    ),
                  const SizedBox(width: 6),
                  RibbonIconButton(
                    icon: Icons.format_indent_decrease,
                    tooltip: 'Diminuir recuo',
                    onPressed: () => controller.indentSelection(false),
                  ),
                  RibbonIconButton(
                    icon: Icons.format_indent_increase,
                    tooltip: 'Aumentar recuo',
                    onPressed: () => controller.indentSelection(true),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  RibbonIconButton(
                    icon: Icons.format_list_bulleted,
                    tooltip: 'Marcadores',
                    selected: list == 'bullet',
                    onPressed: () => controller.toggleList(Attribute.ul),
                  ),
                  RibbonIconButton(
                    icon: Icons.format_list_numbered,
                    tooltip: 'Numeração',
                    selected: list == 'ordered',
                    onPressed: () => controller.toggleList(Attribute.ol),
                  ),
                  const SizedBox(width: 6),
                  _LineSpacingMenu(
                    current: lineSpacing,
                    onSelected: (value) => _apply(
                      () => controller.setLineSpacing(
                        (value - look.lineSpacing).abs() < 0.01 ? null : value,
                      ),
                    ),
                  ),
                  RibbonIconButton(
                    icon: Icons.insert_page_break_outlined,
                    tooltip: 'Quebra de página ($_mod${'Enter'})',
                    onPressed: controller.insertPageBreak,
                  ),
                ],
              ),
            ],
          ),
        ),
        const RibbonGroupDivider(),
        RibbonGroup(
          label: 'Estilos',
          child: _StyleGallery(
            look: look,
            current: header,
            onSelected: (level) => _apply(() => controller.setHeading(level)),
          ),
        ),
      ],
    );
  });

  Widget _insertTab() => Row(
    children: [
      RibbonGroup(
        label: 'Ilustrações',
        child: RibbonBigButton(
          icon: Icons.image_outlined,
          label: 'Imagem',
          tooltip: 'Inserir imagem ($_mod${'G'})',
          onPressed: widget.actions.insertImage,
        ),
      ),
      const RibbonGroupDivider(),
      RibbonGroup(
        label: 'Tabelas',
        child: MenuAnchor(
          style: ribbonMenuStyle(),
          menuChildren: [
            TableSizePicker(onSelected: widget.actions.insertTable),
          ],
          builder: (context, menu, _) => RibbonBigButton(
            icon: Icons.table_chart_outlined,
            label: 'Tabela',
            onPressed: () => menu.isOpen ? menu.close() : menu.open(),
          ),
        ),
      ),
      const RibbonGroupDivider(),
      RibbonGroup(
        label: 'Links',
        child: RibbonBigButton(
          icon: Icons.link,
          label: 'Link',
          tooltip: 'Inserir link ($_mod${'K'})',
          onPressed: widget.actions.editLink,
        ),
      ),
      const RibbonGroupDivider(),
      RibbonGroup(
        label: 'Páginas',
        child: RibbonBigButton(
          icon: Icons.insert_page_break_outlined,
          label: 'Quebra de página',
          tooltip: 'Começa uma página nova ($_mod${'Enter'})',
          onPressed: () =>
              _apply(session.activeController.value.insertPageBreak),
        ),
      ),
      const RibbonGroupDivider(),
      RibbonGroup(
        label: 'Cabeçalho e rodapé',
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            RibbonBigButton(
              icon: Icons.web_asset_outlined,
              label: 'Cabeçalho e rodapé',
              tooltip: 'Editar o texto do topo e da base das páginas',
              onPressed: widget.actions.editHeadersFooters,
            ),
            ListenableBuilder(
              listenable: session,
              builder: (context, _) {
                final stories = session.headersFooters;
                final current = pageNumberPosition(stories);
                return _MenuBigButton(
                  icon: Icons.tag,
                  label: 'Número de página',
                  items: [
                    for (final position in PageNumberPosition.values)
                      _MenuItem(
                        position.label,
                        checked: position == current,
                        onTap: () => session.setHeadersFooters(
                          withPageNumber(stories, position),
                        ),
                      ),
                    _MenuItem(
                      'Primeira página sem número',
                      subtitle: 'Para capa',
                      checked: stories.differentFirstPage,
                      onTap: () => session.setHeadersFooters(
                        stories.copyWith(
                          differentFirstPage: !stories.differentFirstPage,
                        ),
                      ),
                    ),
                    if (current != null)
                      _MenuItem(
                        'Remover números',
                        onTap: () => session.setHeadersFooters(
                          withoutPageNumbers(stories),
                        ),
                      ),
                  ],
                );
              },
            ),
          ],
        ),
      ),
    ],
  );

  Widget _layoutTab() => ListenableBuilder(
    listenable: session,
    builder: (context, _) {
      final look = session.look;
      final landscape = look.isLandscape;
      final portraitWidth = landscape ? look.pageHeight : look.pageWidth;
      final portraitHeight = landscape ? look.pageWidth : look.pageHeight;
      return Row(
        children: [
          RibbonGroup(
            label: 'Configurar página',
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                _MenuBigButton(
                  icon: Icons.border_outer,
                  label: 'Margens',
                  items: [
                    for (final preset in marginPresets)
                      _MenuItem(
                        preset.name,
                        subtitle: preset.description,
                        checked: preset.matches(look.margins),
                        onTap: () =>
                            session.setPageSetup(margins: preset.margins),
                      ),
                  ],
                ),
                _MenuBigButton(
                  icon: Icons.screen_rotation_alt_outlined,
                  label: 'Orientação',
                  items: [
                    _MenuItem(
                      'Retrato',
                      checked: !landscape,
                      onTap: () {
                        session.setPageSetup(
                          width: portraitWidth,
                          height: portraitHeight,
                        );
                      },
                    ),
                    _MenuItem(
                      'Paisagem',
                      checked: landscape,
                      onTap: () {
                        session.setPageSetup(
                          width: portraitHeight,
                          height: portraitWidth,
                        );
                      },
                    ),
                  ],
                ),
                _MenuBigButton(
                  icon: Icons.description_outlined,
                  label: 'Tamanho',
                  items: [
                    for (final paper in paperSizes)
                      _MenuItem(
                        paper.name,
                        subtitle: paper.description,
                        checked: paper.matches(look.pageWidth, look.pageHeight),
                        onTap: () => session.setPageSetup(
                          width: landscape ? paper.height : paper.width,
                          height: landscape ? paper.width : paper.height,
                        ),
                      ),
                  ],
                ),
              ],
            ),
          ),
        ],
      );
    },
  );

  Widget _viewTab() {
    final zoom = widget.actions.zoom;
    final index = zoomLevels.indexWhere(
      (level) => (level - zoom).abs() < 0.001,
    );
    return Row(
      children: [
        RibbonGroup(
          label: 'Modo de exibição',
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              RibbonBigButton(
                icon: Icons.auto_stories_outlined,
                label: 'Páginas',
                tooltip: 'Mostra o documento em páginas, como vai imprimir',
                selected: widget.actions.pagesView,
                onPressed: () => widget.actions.onPagesView(true),
              ),
              RibbonBigButton(
                icon: Icons.view_day_outlined,
                label: 'Contínuo',
                tooltip: 'Texto corrido, sem divisão de páginas',
                selected: !widget.actions.pagesView,
                onPressed: () => widget.actions.onPagesView(false),
              ),
            ],
          ),
        ),
        const RibbonGroupDivider(),
        RibbonGroup(
          label: 'Zoom',
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              RibbonIconButton(
                icon: Icons.zoom_out,
                tooltip: 'Diminuir zoom ($_mod-)',
                onPressed: index > 0
                    ? () => widget.actions.onZoom(zoomLevels[index - 1])
                    : null,
              ),
              SizedBox(
                width: 52,
                child: Text(
                  '${(zoom * 100).round()}%',
                  textAlign: TextAlign.center,
                  style: RibbonText.control,
                ),
              ),
              RibbonIconButton(
                icon: Icons.zoom_in,
                tooltip: 'Aumentar zoom ($_mod=)',
                onPressed: index < zoomLevels.length - 1
                    ? () => widget.actions.onZoom(zoomLevels[index + 1])
                    : null,
              ),
              const SizedBox(width: 8),
              RibbonBigButton(
                icon: Icons.fit_screen_outlined,
                label: '100%',
                onPressed: () => widget.actions.onZoom(1),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _tableTab(TableCellRef cell) {
    final table = cell.table;
    final tables = session.tables;
    final merged = table.hasMergedCells;

    void change(VoidCallback action) {
      action();
      session.focusMain();
      widget.actions.refocus();
    }

    return Row(
      children: [
        RibbonGroup(
          label: 'Linhas e colunas',
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              RibbonBigButton(
                icon: Icons.vertical_align_top,
                label: 'Acima',
                tooltip: 'Inserir linha acima',
                onPressed: () => change(
                  () => tables.insertRow(table, cell.row, copyFrom: cell.row),
                ),
              ),
              RibbonBigButton(
                icon: Icons.vertical_align_bottom,
                label: 'Abaixo',
                tooltip: 'Inserir linha abaixo',
                onPressed: () => change(
                  () =>
                      tables.insertRow(table, cell.row + 1, copyFrom: cell.row),
                ),
              ),
              RibbonBigButton(
                icon: Icons.border_left,
                label: 'À esquerda',
                tooltip: merged
                    ? 'Indisponível em tabela com células mescladas'
                    : 'Inserir coluna à esquerda',
                onPressed: merged
                    ? null
                    : () =>
                          change(() => tables.insertColumn(table, cell.column)),
              ),
              RibbonBigButton(
                icon: Icons.border_right,
                label: 'À direita',
                tooltip: merged
                    ? 'Indisponível em tabela com células mescladas'
                    : 'Inserir coluna à direita',
                onPressed: merged
                    ? null
                    : () => change(
                        () => tables.insertColumn(table, cell.column + 1),
                      ),
              ),
            ],
          ),
        ),
        const RibbonGroupDivider(),
        RibbonGroup(
          label: 'Excluir',
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              RibbonBigButton(
                icon: Icons.table_rows_outlined,
                label: 'Linha',
                onPressed: table.rows.length > 1
                    ? () => change(() => tables.removeRow(table, cell.row))
                    : null,
              ),
              RibbonBigButton(
                icon: Icons.view_column_outlined,
                label: 'Coluna',
                onPressed: merged || table.columnWidths.length <= 1
                    ? null
                    : () =>
                          change(() => tables.removeColumn(table, cell.column)),
              ),
              RibbonBigButton(
                icon: Icons.delete_outline,
                label: 'Tabela',
                onPressed: widget.actions.removeTable,
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _TabButton extends StatelessWidget {
  const _TabButton({
    required this.tab,
    required this.active,
    required this.contextual,
    required this.onTap,
  });

  final RibbonTab tab;
  final bool active;
  final bool contextual;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      selected: active,
      button: true,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(6),
        hoverColor: RibbonColors.hover,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
          child: Text(
            tab.label,
            style: (active ? RibbonText.activeTab : RibbonText.tab).copyWith(
              color: contextual && !active ? const Color(0xFFFFE08A) : null,
            ),
          ),
        ),
      ),
    );
  }
}

class _LineSpacingMenu extends StatelessWidget {
  const _LineSpacingMenu({required this.current, required this.onSelected});

  final double current;
  final ValueChanged<double> onSelected;

  @override
  Widget build(BuildContext context) {
    return MenuAnchor(
      style: ribbonMenuStyle(),
      menuChildren: [
        for (final value in _lineSpacings)
          MenuItemButton(
            style: ribbonMenuItemStyle(),
            onPressed: () => onSelected(value),
            leadingIcon: Icon(
              Icons.check,
              size: 16,
              color: (value - current).abs() < 0.01
                  ? RibbonColors.text
                  : Colors.transparent,
            ),
            child: Text(
              value.toStringAsFixed(value == 1.15 ? 2 : 1).replaceAll('.', ','),
            ),
          ),
      ],
      builder: (context, menu, _) => RibbonIconButton(
        icon: Icons.format_line_spacing,
        tooltip: 'Espaçamento entre linhas',
        onPressed: () => menu.isOpen ? menu.close() : menu.open(),
      ),
    );
  }
}

class _MenuItem {
  const _MenuItem(
    this.label, {
    required this.onTap,
    this.subtitle,
    this.checked = false,
  });

  final String label;
  final String? subtitle;
  final bool checked;
  final VoidCallback onTap;
}

class _MenuBigButton extends StatelessWidget {
  const _MenuBigButton({
    required this.icon,
    required this.label,
    required this.items,
  });

  final IconData icon;
  final String label;
  final List<_MenuItem> items;

  @override
  Widget build(BuildContext context) {
    return MenuAnchor(
      style: ribbonMenuStyle(),
      menuChildren: [
        for (final item in items)
          MenuItemButton(
            style: ribbonMenuItemStyle().copyWith(
              minimumSize: const WidgetStatePropertyAll(Size(0, 46)),
            ),
            onPressed: item.onTap,
            leadingIcon: Icon(
              Icons.check,
              size: 16,
              color: item.checked ? RibbonColors.text : Colors.transparent,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(item.label, style: RibbonText.control),
                if (item.subtitle != null)
                  Text(item.subtitle!, style: RibbonText.label),
              ],
            ),
          ),
      ],
      builder: (context, menu, _) => RibbonBigButton(
        icon: icon,
        label: label,
        onPressed: () => menu.isOpen ? menu.close() : menu.open(),
      ),
    );
  }
}

/// Galeria de estilos com prévia "Abcd", como a do Word.
class _StyleGallery extends StatelessWidget {
  const _StyleGallery({
    required this.look,
    required this.current,
    required this.onSelected,
  });

  final DocumentLook look;
  final int current;
  final ValueChanged<int> onSelected;

  @override
  Widget build(BuildContext context) {
    const names = ['Normal', 'Título 1', 'Título 2', 'Título 3'];
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var level = 0; level < names.length; level++)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 2),
            child: Material(
              color: level == current
                  ? RibbonColors.selected
                  : const Color(0x14FFFFFF),
              borderRadius: BorderRadius.circular(8),
              child: InkWell(
                onTap: () => onSelected(level),
                borderRadius: BorderRadius.circular(8),
                hoverColor: RibbonColors.hover,
                child: SizedBox(
                  width: 74,
                  height: 62,
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(
                        'Abcd',
                        style: TextStyle(
                          color: RibbonColors.text,
                          fontFamily:
                              (level == 0 ? look.body : look.heading(level))
                                  .fontFamily,
                          fontWeight: level == 0
                              ? FontWeight.w400
                              : FontWeight.w700,
                          fontSize: const [15.0, 18.0, 16.5, 15.0][level],
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        names[level],
                        style: RibbonText.label.copyWith(fontSize: 10.5),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}
