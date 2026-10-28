import 'package:flutter/material.dart';

import '../../fonts/font_catalog.dart';
import '../../l10n/l10n.dart';
import '../editor_factory.dart';
import 'ribbon_controls.dart';
import 'ribbon_style.dart';

enum _RowKind { header, font, add }

typedef _Row = ({String text, _RowKind kind});

/// Searchable font field: the document's fonts, installed ones and Google's.
class FontPicker extends StatefulWidget {
  const FontPicker({
    required this.fonts,
    required this.current,
    required this.documentFonts,
    required this.onSelected,
    this.width = 148,
    super.key,
  });

  final FontCatalog fonts;
  final String? current;
  final Set<String> Function() documentFonts;
  final ValueChanged<String> onSelected;
  final double width;

  @override
  State<FontPicker> createState() => _FontPickerState();
}

class _FontPickerState extends State<FontPicker> {
  final _menu = MenuController();

  @override
  Widget build(BuildContext context) {
    return MenuAnchor(
      controller: _menu,
      style: ribbonMenuStyle(),
      menuChildren: [
        _FontPanel(
          fonts: widget.fonts,
          current: widget.current,
          documentFonts: widget.documentFonts(),
          onSelected: (family) {
            _menu.close();
            widget.onSelected(family);
          },
        ),
      ],
      builder: (context, menu, _) => Tooltip(
        message: context.l10n.groupFont,
        child: RibbonField(
          width: widget.width,
          onTap: () => menu.isOpen ? menu.close() : menu.open(),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  widget.current ?? context.l10n.defaultFont,
                  style: RibbonText.control,
                  overflow: TextOverflow.ellipsis,
                  maxLines: 1,
                ),
              ),
              const Icon(
                Icons.keyboard_arrow_down,
                size: 16,
                color: RibbonColors.text,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _FontPanel extends StatefulWidget {
  const _FontPanel({
    required this.fonts,
    required this.current,
    required this.documentFonts,
    required this.onSelected,
  });

  final FontCatalog fonts;
  final String? current;
  final Set<String> documentFonts;
  final ValueChanged<String> onSelected;

  @override
  State<_FontPanel> createState() => _FontPanelState();
}

class _FontPanelState extends State<_FontPanel> {
  var _query = '';

  List<_Row> _rows() {
    final query = _query.trim().toLowerCase();
    List<_Row> section(
      String title,
      Iterable<String> families, {
      _RowKind kind = _RowKind.font,
    }) {
      final found = [
        for (final family in families)
          if (family.toLowerCase().contains(query)) (text: family, kind: kind),
      ];
      return found.isEmpty
          ? const []
          : [(text: title, kind: _RowKind.header), ...found];
    }

    final fonts = widget.fonts;
    final l10n = context.l10n;
    return [
      ...section(
        l10n.fontsInDocument,
        widget.documentFonts.toList()
          ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase())),
      ),
      ...section(
        isDesktopPlatform ? l10n.fontsOnComputer : l10n.fontsOnDevice,
        fonts.systemFamilies,
      ),
      ...section('Google Fonts', fonts.googleFamilies),
      if (query.isNotEmpty)
        ...section(
          l10n.addFromGoogleFonts,
          fonts.unlistedGoogleFamilies,
          kind: _RowKind.add,
        ),
    ];
  }

  void _choose(_Row row) {
    if (row.kind == _RowKind.add) widget.fonts.add(row.text).ignore();
    widget.onSelected(row.text);
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 300,
      height: 430,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 4, 10, 6),
            child: TextField(
              autofocus: isDesktopPlatform,
              style: RibbonText.control,
              cursorColor: RibbonColors.text,
              decoration: InputDecoration(
                hintText: context.l10n.searchFont,
                hintStyle: RibbonText.control.copyWith(
                  color: RibbonColors.muted,
                ),
                prefixIcon: const Icon(
                  Icons.search,
                  size: 18,
                  color: RibbonColors.muted,
                ),
                isDense: true,
                filled: true,
                fillColor: RibbonColors.field,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: BorderSide.none,
                ),
              ),
              onChanged: (value) => setState(() => _query = value),
              onSubmitted: (_) {
                final first = _rows()
                    .where((row) => row.kind != _RowKind.header)
                    .firstOrNull;
                if (first != null) _choose(first);
              },
            ),
          ),
          Expanded(
            child: ListenableBuilder(
              listenable: widget.fonts,
              builder: (context, _) {
                final rows = _rows();
                if (rows.isEmpty) {
                  return Center(
                    child: Text(
                      context.l10n.noFontsFound,
                      style: RibbonText.label,
                    ),
                  );
                }
                return ListView.builder(
                  primary: false,
                  itemCount: rows.length,
                  itemExtent: 34,
                  itemBuilder: (context, index) {
                    final row = rows[index];
                    return switch (row.kind) {
                      _RowKind.header => _header(row.text),
                      _RowKind.font => _font(row),
                      _RowKind.add => _addable(row),
                    };
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _header(String title) => Padding(
    padding: const EdgeInsets.fromLTRB(14, 12, 14, 4),
    child: Text(title.toUpperCase(), style: RibbonText.label),
  );

  Widget _font(_Row row) {
    final family = row.text;
    final fonts = widget.fonts;
    final ready = fonts.isReady(family);
    final missing = !fonts.canProvide(family);
    return InkWell(
      onTap: () => _choose(row),
      hoverColor: RibbonColors.hover,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10),
        child: Row(
          children: [
            SizedBox(
              width: 26,
              child: family == widget.current
                  ? const Icon(Icons.check, size: 16, color: RibbonColors.text)
                  : null,
            ),
            Expanded(
              child: Text(
                family,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: ready
                    ? RibbonText.control.copyWith(
                        fontFamily: family,
                        fontSize: 15,
                      )
                    : RibbonText.control,
              ),
            ),
            if (missing)
              Tooltip(
                message: context.l10n.fontMissing,
                child: const Icon(
                  Icons.warning_amber_rounded,
                  size: 16,
                  color: RibbonColors.muted,
                ),
              )
            else if (!ready)
              Tooltip(
                message: context.l10n.fontDownloadsOnUse,
                child: const Icon(
                  Icons.cloud_download_outlined,
                  size: 16,
                  color: RibbonColors.muted,
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _addable(_Row row) => InkWell(
    onTap: () => _choose(row),
    hoverColor: RibbonColors.hover,
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10),
      child: Row(
        children: [
          const SizedBox(width: 26),
          Expanded(
            child: Text(
              row.text,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: RibbonText.control,
            ),
          ),
          Tooltip(
            message: context.l10n.addToList,
            child: const Icon(
              Icons.add_circle_outline,
              size: 16,
              color: RibbonColors.text,
            ),
          ),
        ],
      ),
    ),
  );
}
