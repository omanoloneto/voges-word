import 'package:flutter/material.dart';
import 'package:flutter_quill/flutter_quill.dart';
import 'package:intl/intl.dart';

import '../../document/document_look.dart';
import '../../document/page_setup.dart';
import '../../fonts/font_catalog.dart';
import '../../l10n/l10n.dart';
import '../../spell/spell_checker.dart';
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
  home,
  insert,
  layout,
  view,
  table;

  String label(AppLocalizations l10n) => switch (this) {
    home => l10n.tabHome,
    insert => l10n.tabInsert,
    layout => l10n.tabLayout,
    view => l10n.tabView,
    table => l10n.tabTable,
  };
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
  ColorChoice('#C00000', ColorName.darkRed),
  ColorChoice('#0070C0', ColorName.blue),
  ColorChoice('#00B050', ColorName.green),
  ColorChoice('#ED7D31', ColorName.orange),
];

const _textPalette = [
  ColorChoice('#000000', ColorName.black),
  ColorChoice('#595959', ColorName.darkGray),
  ColorChoice('#A6A6A6', ColorName.lightGray),
  ColorChoice('#C00000', ColorName.darkRed),
  ColorChoice('#FF0000', ColorName.red),
  ColorChoice('#ED7D31', ColorName.orange),
  ColorChoice('#BF8F00', ColorName.gold),
  ColorChoice('#00B050', ColorName.green),
  ColorChoice('#00B0F0', ColorName.lightBlue),
  ColorChoice('#0070C0', ColorName.blue),
  ColorChoice('#002060', ColorName.darkBlue),
  ColorChoice('#7030A0', ColorName.purple),
];

/// Word's highlight colors, saved back as real highlighting in the .docx.
const _quickHighlights = [
  ColorChoice('#FFFF00', ColorName.yellow),
  ColorChoice('#00FF00', ColorName.brightGreen),
  ColorChoice('#00FFFF', ColorName.turquoise),
  ColorChoice('#FF00FF', ColorName.pink),
];

const _highlightPalette = [
  ..._quickHighlights,
  ColorChoice('#C0C0C0', ColorName.gray),
  ColorChoice('#FF0000', ColorName.red),
  ColorChoice('#0000FF', ColorName.blue),
  ColorChoice('#008000', ColorName.green),
  ColorChoice('#800080', ColorName.violet),
  ColorChoice('#808000', ColorName.olive),
];

const _lineSpacings = [1.0, 1.15, 1.5, 2.0];

String get _mod => isApplePlatform ? '⌘' : 'Ctrl+';

String _pageNumberLabel(AppLocalizations l10n, PageNumberPosition position) =>
    switch (position) {
      PageNumberPosition.topRight => l10n.pageNumberTopRight,
      PageNumberPosition.topCenter => l10n.pageNumberTopCenter,
      PageNumberPosition.bottomRight => l10n.pageNumberBottomRight,
      PageNumberPosition.bottomCenter => l10n.pageNumberBottomCenter,
    };

String _marginName(AppLocalizations l10n, MarginPresetName name) =>
    switch (name) {
      MarginPresetName.normal => l10n.marginsNormal,
      MarginPresetName.abnt => l10n.marginsAbnt,
      MarginPresetName.narrow => l10n.marginsNarrow,
      MarginPresetName.moderate => l10n.marginsModerate,
      MarginPresetName.wide => l10n.marginsWide,
    };

String _marginDescription(AppLocalizations l10n, EdgeInsets margins) {
  String cm(double points) =>
      NumberFormat('0.##', l10n.localeName).format(points / 28.35);
  final EdgeInsets(:left, :top, :right, :bottom) = margins;
  if (left == top && top == right && right == bottom) {
    return l10n.marginsAllSides(cm(top));
  }
  if (top == bottom && left == right) {
    return l10n.marginsTopBottomSides(cm(top), cm(left));
  }
  if (top == left && bottom == right) {
    return l10n.marginsTopLeftBottomRight(cm(top), cm(bottom));
  }
  return l10n.marginsEachSide(cm(top), cm(bottom), cm(left), cm(right));
}

String _paperName(AppLocalizations l10n, PaperName name) => switch (name) {
  PaperName.a4 => 'A4',
  PaperName.letter => l10n.paperLetter,
  PaperName.legal => l10n.paperLegal,
  PaperName.a5 => 'A5',
};

String _paperDescription(AppLocalizations l10n, PaperSize paper) {
  String cm(double points) =>
      NumberFormat('0.#', l10n.localeName).format(points / 28.35);
  return '${cm(paper.width)} × ${cm(paper.height)} cm';
}

class Ribbon extends StatefulWidget {
  const Ribbon({
    required this.session,
    required this.fonts,
    required this.actions,
    this.spelling,
    super.key,
  });

  final EditorSession session;
  final FontCatalog fonts;
  final RibbonActions actions;
  final SpellChecker? spelling;

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
      SnackBar(content: Text(context.l10n.fontDownloadFailed(family))),
    );
  }

  Widget _homeTab() => _withController((controller) {
    final l10n = context.l10n;
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
          label: l10n.groupFont,
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
                    label: formatRibbonNumber(size, l10n.localeName),
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
                          '${l10n.bold} (${_mod}B)',
                        ),
                        (
                          Attribute.italic,
                          Icons.format_italic,
                          '${l10n.italic} (${_mod}I)',
                        ),
                        (
                          Attribute.underline,
                          Icons.format_underlined,
                          '${l10n.underline} (${_mod}U)',
                        ),
                        (
                          Attribute.strikeThrough,
                          Icons.strikethrough_s,
                          l10n.strikethrough,
                        ),
                        (
                          Attribute.superscript,
                          Icons.superscript,
                          l10n.superscript,
                        ),
                        (Attribute.subscript, Icons.subscript, l10n.subscript),
                      ])
                    RibbonIconButton(
                      icon: icon,
                      tooltip: tip,
                      selected: controller.isActive(attribute),
                      onPressed: () => controller.toggle(attribute),
                    ),
                  RibbonIconButton(
                    icon: Icons.format_clear,
                    tooltip: l10n.clearFormatting,
                    onPressed: controller.clearFormatting,
                  ),
                ],
              ),
            ],
          ),
        ),
        const RibbonGroupDivider(),
        RibbonGroup(
          label: l10n.groupColor,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              ColorRow(
                icon: Icons.format_color_text,
                tooltip: l10n.fontColor,
                quick: _quickTextColors,
                palette: _textPalette,
                current: controller.valueOf<String>(Attribute.color.key),
                lastUsed: _lastTextColor,
                clearLabel: l10n.automaticColor,
                onSelected: (hex) => _apply(() {
                  if (hex != null) setState(() => _lastTextColor = hex);
                  controller.setInline(Attribute.color, hex);
                }),
              ),
              const SizedBox(height: 6),
              ColorRow(
                icon: Icons.border_color,
                tooltip: l10n.highlightColor,
                quick: _quickHighlights,
                palette: _highlightPalette,
                current: controller.valueOf<String>(Attribute.background.key),
                lastUsed: _lastHighlight,
                clearLabel: l10n.noHighlight,
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
          label: l10n.groupParagraph,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (final (value, icon, tip, key) in [
                    ('left', Icons.format_align_left, l10n.alignLeft, 'L'),
                    (
                      'center',
                      Icons.format_align_center,
                      l10n.alignCenter,
                      'E',
                    ),
                    ('right', Icons.format_align_right, l10n.alignRight, 'R'),
                    ('justify', Icons.format_align_justify, l10n.justify, 'J'),
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
                    tooltip: l10n.decreaseIndent,
                    onPressed: () => controller.indentSelection(false),
                  ),
                  RibbonIconButton(
                    icon: Icons.format_indent_increase,
                    tooltip: l10n.increaseIndent,
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
                    tooltip: l10n.bullets,
                    selected: list == 'bullet',
                    onPressed: () => controller.toggleList(Attribute.ul),
                  ),
                  RibbonIconButton(
                    icon: Icons.format_list_numbered,
                    tooltip: l10n.numbering,
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
                    tooltip: '${l10n.pageBreak} ($_mod${'Enter'})',
                    onPressed: controller.insertPageBreak,
                  ),
                ],
              ),
            ],
          ),
        ),
        const RibbonGroupDivider(),
        RibbonGroup(
          label: l10n.groupStyles,
          child: _StyleGallery(
            look: look,
            current: header,
            onSelected: (level) => _apply(() => controller.setHeading(level)),
          ),
        ),
      ],
    );
  });

  Widget _insertTab() {
    final l10n = context.l10n;
    return Row(
      children: [
        RibbonGroup(
          label: l10n.groupIllustrations,
          child: RibbonBigButton(
            icon: Icons.image_outlined,
            label: l10n.picture,
            tooltip: '${l10n.insertPicture} ($_mod${'G'})',
            onPressed: widget.actions.insertImage,
          ),
        ),
        const RibbonGroupDivider(),
        RibbonGroup(
          label: l10n.groupTables,
          child: MenuAnchor(
            style: ribbonMenuStyle(),
            menuChildren: [
              TableSizePicker(onSelected: widget.actions.insertTable),
            ],
            builder: (context, menu, _) => RibbonBigButton(
              icon: Icons.table_chart_outlined,
              label: l10n.table,
              onPressed: () => menu.isOpen ? menu.close() : menu.open(),
            ),
          ),
        ),
        const RibbonGroupDivider(),
        RibbonGroup(
          label: l10n.groupLinks,
          child: RibbonBigButton(
            icon: Icons.link,
            label: l10n.link,
            tooltip: '${l10n.insertLink} ($_mod${'K'})',
            onPressed: widget.actions.editLink,
          ),
        ),
        const RibbonGroupDivider(),
        RibbonGroup(
          label: l10n.groupPages,
          child: RibbonBigButton(
            icon: Icons.insert_page_break_outlined,
            label: l10n.pageBreak,
            tooltip: '${l10n.pageBreakTooltip} ($_mod${'Enter'})',
            onPressed: () =>
                _apply(session.activeController.value.insertPageBreak),
          ),
        ),
        const RibbonGroupDivider(),
        RibbonGroup(
          label: l10n.groupHeaderFooter,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              RibbonBigButton(
                icon: Icons.web_asset_outlined,
                label: l10n.headerFooter,
                tooltip: l10n.headerFooterTooltip,
                onPressed: widget.actions.editHeadersFooters,
              ),
              ListenableBuilder(
                listenable: session,
                builder: (context, _) {
                  final stories = session.headersFooters;
                  final current = pageNumberPosition(stories);
                  return _MenuBigButton(
                    icon: Icons.tag,
                    label: l10n.pageNumber,
                    items: [
                      for (final position in PageNumberPosition.values)
                        _MenuItem(
                          _pageNumberLabel(l10n, position),
                          checked: position == current,
                          onTap: () => session.setHeadersFooters(
                            withPageNumber(stories, position),
                          ),
                        ),
                      _MenuItem(
                        l10n.firstPageWithoutNumber,
                        subtitle: l10n.forCoverPage,
                        checked: stories.differentFirstPage,
                        onTap: () => session.setHeadersFooters(
                          stories.copyWith(
                            differentFirstPage: !stories.differentFirstPage,
                          ),
                        ),
                      ),
                      if (current != null)
                        _MenuItem(
                          l10n.removePageNumbers,
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
  }

  Widget _layoutTab() => ListenableBuilder(
    listenable: session,
    builder: (context, _) {
      final l10n = context.l10n;
      final look = session.look;
      final landscape = look.isLandscape;
      final portraitWidth = landscape ? look.pageHeight : look.pageWidth;
      final portraitHeight = landscape ? look.pageWidth : look.pageHeight;
      return Row(
        children: [
          RibbonGroup(
            label: l10n.groupPageSetup,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                _MenuBigButton(
                  icon: Icons.border_outer,
                  label: l10n.margins,
                  items: [
                    for (final preset in marginPresets)
                      _MenuItem(
                        _marginName(l10n, preset.name),
                        subtitle: _marginDescription(l10n, preset.margins),
                        checked: preset.matches(look.margins),
                        onTap: () =>
                            session.setPageSetup(margins: preset.margins),
                      ),
                  ],
                ),
                _MenuBigButton(
                  icon: Icons.screen_rotation_alt_outlined,
                  label: l10n.orientation,
                  items: [
                    _MenuItem(
                      l10n.portrait,
                      checked: !landscape,
                      onTap: () {
                        session.setPageSetup(
                          width: portraitWidth,
                          height: portraitHeight,
                        );
                      },
                    ),
                    _MenuItem(
                      l10n.landscape,
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
                  label: l10n.paperSize,
                  items: [
                    for (final paper in paperSizes)
                      _MenuItem(
                        _paperName(l10n, paper.name),
                        subtitle: _paperDescription(l10n, paper),
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
    final l10n = context.l10n;
    final zoom = widget.actions.zoom;
    final index = zoomLevels.indexWhere(
      (level) => (level - zoom).abs() < 0.001,
    );
    return Row(
      children: [
        RibbonGroup(
          label: l10n.groupViews,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              RibbonBigButton(
                icon: Icons.auto_stories_outlined,
                label: l10n.viewPages,
                tooltip: l10n.viewPagesTooltip,
                selected: widget.actions.pagesView,
                onPressed: () => widget.actions.onPagesView(true),
              ),
              RibbonBigButton(
                icon: Icons.view_day_outlined,
                label: l10n.viewContinuous,
                tooltip: l10n.viewContinuousTooltip,
                selected: !widget.actions.pagesView,
                onPressed: () => widget.actions.onPagesView(false),
              ),
            ],
          ),
        ),
        const RibbonGroupDivider(),
        RibbonGroup(
          label: l10n.groupZoom,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              RibbonIconButton(
                icon: Icons.zoom_out,
                tooltip: '${l10n.zoomOut} ($_mod-)',
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
                tooltip: '${l10n.zoomIn} ($_mod=)',
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
        if (widget.spelling case final spelling?) ...[
          const RibbonGroupDivider(),
          RibbonGroup(
            label: l10n.groupProofing,
            child: ListenableBuilder(
              listenable: spelling,
              builder: (context, _) => RibbonBigButton(
                icon: Icons.spellcheck,
                label: l10n.spelling,
                tooltip: l10n.spellingTooltip,
                selected: spelling.enabled,
                onPressed: () => spelling.enabled = !spelling.enabled,
              ),
            ),
          ),
        ],
      ],
    );
  }

  Widget _tableTab(TableCellRef cell) {
    final l10n = context.l10n;
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
          label: l10n.groupRowsColumns,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              RibbonBigButton(
                icon: Icons.vertical_align_top,
                label: l10n.rowAbove,
                tooltip: l10n.insertRowAbove,
                onPressed: () => change(
                  () => tables.insertRow(table, cell.row, copyFrom: cell.row),
                ),
              ),
              RibbonBigButton(
                icon: Icons.vertical_align_bottom,
                label: l10n.rowBelow,
                tooltip: l10n.insertRowBelow,
                onPressed: () => change(
                  () =>
                      tables.insertRow(table, cell.row + 1, copyFrom: cell.row),
                ),
              ),
              RibbonBigButton(
                icon: Icons.border_left,
                label: l10n.columnLeft,
                tooltip: merged
                    ? l10n.unavailableWithMergedCells
                    : l10n.insertColumnLeft,
                onPressed: merged
                    ? null
                    : () =>
                          change(() => tables.insertColumn(table, cell.column)),
              ),
              RibbonBigButton(
                icon: Icons.border_right,
                label: l10n.columnRight,
                tooltip: merged
                    ? l10n.unavailableWithMergedCells
                    : l10n.insertColumnRight,
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
          label: l10n.groupDelete,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              RibbonBigButton(
                icon: Icons.table_rows_outlined,
                label: l10n.row,
                onPressed: table.rows.length > 1
                    ? () => change(() => tables.removeRow(table, cell.row))
                    : null,
              ),
              RibbonBigButton(
                icon: Icons.view_column_outlined,
                label: l10n.column,
                onPressed: merged || table.columnWidths.length <= 1
                    ? null
                    : () =>
                          change(() => tables.removeColumn(table, cell.column)),
              ),
              RibbonBigButton(
                icon: Icons.delete_outline,
                label: l10n.table,
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
            tab.label(context.l10n),
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
              NumberFormat('0.0#', context.l10n.localeName).format(value),
            ),
          ),
      ],
      builder: (context, menu, _) => RibbonIconButton(
        icon: Icons.format_line_spacing,
        tooltip: context.l10n.lineSpacing,
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

/// Style gallery with an "Abcd" preview, like Word's.
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
    final l10n = context.l10n;
    final names = [
      l10n.styleNormal,
      for (var level = 1; level <= 3; level++) l10n.styleHeading(level),
    ];
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
