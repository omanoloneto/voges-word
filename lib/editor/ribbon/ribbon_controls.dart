import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../l10n/l10n.dart';

import 'ribbon_style.dart';

class RibbonIconButton extends StatelessWidget {
  const RibbonIconButton({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    this.selected = false,
    this.child,
    super.key,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;
  final bool selected;

  /// Replaces the icon (e.g. an icon with a small color bar).
  final Widget? child;

  @override
  Widget build(BuildContext context) {
    final enabled = onPressed != null;
    return Tooltip(
      message: tooltip,
      child: Semantics(
        button: true,
        selected: selected,
        label: tooltip,
        child: Material(
          color: selected ? RibbonColors.selected : Colors.transparent,
          borderRadius: BorderRadius.circular(6),
          child: InkWell(
            onTap: onPressed,
            borderRadius: BorderRadius.circular(6),
            hoverColor: RibbonColors.hover,
            child: SizedBox(
              width: 32,
              height: 30,
              child: Center(
                child: IconTheme(
                  data: IconThemeData(
                    color: enabled
                        ? RibbonColors.text
                        : RibbonColors.text.withValues(alpha: 0.35),
                    size: 19,
                  ),
                  child: child ?? Icon(icon),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Big button (icon on top, label below) of the Insert, Layout and View tabs.
class RibbonBigButton extends StatelessWidget {
  const RibbonBigButton({
    required this.icon,
    required this.label,
    required this.onPressed,
    this.selected = false,
    this.tooltip,
    super.key,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onPressed;
  final bool selected;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    final button = Material(
      color: selected ? RibbonColors.selected : Colors.transparent,
      borderRadius: BorderRadius.circular(8),
      child: InkWell(
        onTap: onPressed,
        borderRadius: BorderRadius.circular(8),
        hoverColor: RibbonColors.hover,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minWidth: 64),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, color: RibbonColors.text, size: 24),
                const SizedBox(height: 4),
                Text(label, style: RibbonText.control.copyWith(fontSize: 12)),
              ],
            ),
          ),
        ),
      ),
    );
    return Semantics(
      button: true,
      selected: selected,
      child: tooltip == null
          ? button
          : Tooltip(message: tooltip!, child: button),
    );
  }
}

/// Ribbon group: content on top and label below, as in Word.
class RibbonGroup extends StatelessWidget {
  const RibbonGroup({required this.label, required this.child, super.key});

  final String label;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(height: 68, child: Center(child: child)),
          const SizedBox(height: 2),
          Text(label, style: RibbonText.label),
        ],
      ),
    );
  }
}

class RibbonGroupDivider extends StatelessWidget {
  const RibbonGroupDivider({super.key});

  @override
  Widget build(BuildContext context) =>
      Container(width: 1, height: 70, color: RibbonColors.divider);
}

class RibbonOption<T> {
  const RibbonOption(this.value, this.label, {this.style});

  final T value;
  final String label;
  final TextStyle? style;
}

/// Field with a drop-down list (font, size, spacing…).
class RibbonDropdown<T> extends StatelessWidget {
  const RibbonDropdown({
    required this.tooltip,
    required this.label,
    required this.options,
    required this.selected,
    required this.onSelected,
    this.width = 140,
    super.key,
  });

  final String tooltip;
  final String label;
  final List<RibbonOption<T>> options;
  final T? selected;
  final ValueChanged<T> onSelected;
  final double width;

  @override
  Widget build(BuildContext context) {
    return MenuAnchor(
      style: ribbonMenuStyle(),
      menuChildren: [
        for (final option in options)
          MenuItemButton(
            style: ribbonMenuItemStyle(),
            onPressed: () => onSelected(option.value),
            leadingIcon: Icon(
              Icons.check,
              size: 16,
              color: option.value == selected
                  ? RibbonColors.text
                  : Colors.transparent,
            ),
            child: Text(
              option.label,
              style: RibbonText.control.merge(option.style),
            ),
          ),
      ],
      builder: (context, menu, _) => Tooltip(
        message: tooltip,
        child: RibbonField(
          width: width,
          onTap: () => menu.isOpen ? menu.close() : menu.open(),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  label,
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

class RibbonField extends StatelessWidget {
  const RibbonField({required this.child, this.width, this.onTap, super.key});

  final Widget child;
  final double? width;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: RibbonColors.field,
      borderRadius: BorderRadius.circular(6),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(6),
        hoverColor: RibbonColors.hover,
        child: SizedBox(
          width: width,
          height: 30,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: child,
          ),
        ),
      ),
    );
  }
}

/// Font size with − and +, and a list when the number is tapped.
class SizeStepper extends StatelessWidget {
  const SizeStepper({
    required this.label,
    required this.sizes,
    required this.current,
    required this.onSelected,
    super.key,
  });

  final String label;
  final List<num> sizes;
  final num current;
  final ValueChanged<num> onSelected;

  num? _neighbor(int direction) {
    final sorted = [...sizes]..sort();
    if (direction > 0) {
      for (final size in sorted) {
        if (size > current) return size;
      }
      return null;
    }
    for (final size in sorted.reversed) {
      if (size < current) return size;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final smaller = _neighbor(-1);
    final larger = _neighbor(1);
    return RibbonField(
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _StepButton(
            icon: Icons.remove,
            tooltip: l10n.decreaseFontSize,
            onPressed: smaller == null ? null : () => onSelected(smaller),
          ),
          MenuAnchor(
            style: ribbonMenuStyle(),
            menuChildren: [
              for (final size in sizes)
                MenuItemButton(
                  style: ribbonMenuItemStyle(),
                  onPressed: () => onSelected(size),
                  child: Text(
                    formatRibbonNumber(size, l10n.localeName),
                    style: RibbonText.control,
                  ),
                ),
            ],
            builder: (context, menu, _) => InkWell(
              onTap: () => menu.isOpen ? menu.close() : menu.open(),
              child: SizedBox(
                width: 34,
                child: Text(
                  label,
                  textAlign: TextAlign.center,
                  style: RibbonText.control,
                ),
              ),
            ),
          ),
          _StepButton(
            icon: Icons.add,
            tooltip: l10n.increaseFontSize,
            onPressed: larger == null ? null : () => onSelected(larger),
          ),
        ],
      ),
    );
  }
}

class _StepButton extends StatelessWidget {
  const _StepButton({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onPressed,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 2),
          child: Icon(
            icon,
            size: 15,
            color: onPressed == null
                ? RibbonColors.text.withValues(alpha: 0.35)
                : RibbonColors.text,
          ),
        ),
      ),
    );
  }
}

String formatRibbonNumber(num value, String locale) =>
    NumberFormat.decimalPattern(locale).format(value);

enum ColorName {
  black,
  darkGray,
  lightGray,
  gray,
  darkRed,
  red,
  orange,
  gold,
  yellow,
  brightGreen,
  green,
  olive,
  turquoise,
  lightBlue,
  blue,
  darkBlue,
  purple,
  violet,
  pink;

  String label(AppLocalizations l10n) => switch (this) {
    black => l10n.colorBlack,
    darkGray => l10n.colorDarkGray,
    lightGray => l10n.colorLightGray,
    gray => l10n.colorGray,
    darkRed => l10n.colorDarkRed,
    red => l10n.colorRed,
    orange => l10n.colorOrange,
    gold => l10n.colorGold,
    yellow => l10n.colorYellow,
    brightGreen => l10n.colorBrightGreen,
    green => l10n.colorGreen,
    olive => l10n.colorOlive,
    turquoise => l10n.colorTurquoise,
    lightBlue => l10n.colorLightBlue,
    blue => l10n.colorBlue,
    darkBlue => l10n.colorDarkBlue,
    purple => l10n.colorPurple,
    violet => l10n.colorViolet,
    pink => l10n.colorPink,
  };
}

class ColorChoice {
  const ColorChoice(this.hex, this.name);

  final String hex;
  final ColorName name;

  Color get color => colorOfHex(hex);
}

Color colorOfHex(String hex) =>
    Color(int.parse('FF${hex.replaceFirst('#', '')}', radix: 16));

/// Color button + quick swatches + full palette under ▾.
class ColorRow extends StatelessWidget {
  const ColorRow({
    required this.icon,
    required this.tooltip,
    required this.quick,
    required this.palette,
    required this.current,
    required this.lastUsed,
    required this.clearLabel,
    required this.onSelected,
    super.key,
  });

  final IconData icon;
  final String tooltip;
  final List<ColorChoice> quick;
  final List<ColorChoice> palette;
  final String? current;
  final String lastUsed;
  final String clearLabel;
  final ValueChanged<String?> onSelected;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        RibbonIconButton(
          icon: icon,
          tooltip: tooltip,
          selected: current != null,
          onPressed: () => onSelected(current == null ? lastUsed : null),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 17),
              Container(width: 16, height: 3, color: colorOfHex(lastUsed)),
            ],
          ),
        ),
        const SizedBox(width: 2),
        for (final choice in quick)
          Tooltip(
            message: choice.name.label(context.l10n),
            child: InkWell(
              customBorder: const CircleBorder(),
              onTap: () => onSelected(choice.hex),
              child: Padding(
                padding: const EdgeInsets.all(4),
                child: Container(
                  width: 12,
                  height: 12,
                  decoration: BoxDecoration(
                    color: choice.color,
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: choice.hex == current
                          ? RibbonColors.text
                          : const Color(0x55FFFFFF),
                      width: choice.hex == current ? 2 : 1,
                    ),
                  ),
                ),
              ),
            ),
          ),
        MenuAnchor(
          style: ribbonMenuStyle(),
          menuChildren: [
            MenuItemButton(
              style: ribbonMenuItemStyle(),
              leadingIcon: const Icon(Icons.format_color_reset, size: 18),
              onPressed: () => onSelected(null),
              child: Text(clearLabel),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
              child: SizedBox(
                width: 6 * 30,
                child: Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (final choice in palette)
                      Tooltip(
                        message: choice.name.label(context.l10n),
                        child: Builder(
                          builder: (context) => InkWell(
                            onTap: () {
                              onSelected(choice.hex);
                              MenuController.maybeOf(context)?.close();
                            },
                            child: Container(
                              width: 24,
                              height: 24,
                              decoration: BoxDecoration(
                                color: choice.color,
                                borderRadius: BorderRadius.circular(5),
                                border: Border.all(
                                  color: choice.hex == current
                                      ? RibbonColors.text
                                      : const Color(0x40FFFFFF),
                                  width: choice.hex == current ? 2 : 1,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ],
          builder: (context, menu, _) => Tooltip(
            message: context.l10n.moreColors,
            child: InkWell(
              onTap: () => menu.isOpen ? menu.close() : menu.open(),
              child: const Padding(
                padding: EdgeInsets.all(2),
                child: Icon(
                  Icons.keyboard_arrow_down,
                  size: 16,
                  color: RibbonColors.text,
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// Grid to pick rows × columns for a new table.
class TableSizePicker extends StatefulWidget {
  const TableSizePicker({required this.onSelected, super.key});

  final void Function(int rows, int columns) onSelected;

  @override
  State<TableSizePicker> createState() => _TableSizePickerState();
}

class _TableSizePickerState extends State<TableSizePicker> {
  static const _max = 8;
  var _rows = 2;
  var _columns = 3;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            context.l10n.tableSize(_rows, _columns),
            style: RibbonText.control,
          ),
          const SizedBox(height: 8),
          for (var r = 1; r <= _max; r++)
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (var c = 1; c <= _max; c++)
                  MouseRegion(
                    onEnter: (_) => setState(() {
                      _rows = r;
                      _columns = c;
                    }),
                    child: GestureDetector(
                      onTap: () {
                        widget.onSelected(r, c);
                        MenuController.maybeOf(context)?.close();
                      },
                      child: Container(
                        width: 22,
                        height: 22,
                        margin: const EdgeInsets.all(1.5),
                        decoration: BoxDecoration(
                          color: r <= _rows && c <= _columns
                              ? RibbonColors.selected
                              : RibbonColors.field,
                          border: Border.all(
                            color: RibbonColors.panelBorder,
                            width: 0.8,
                          ),
                          borderRadius: BorderRadius.circular(3),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
        ],
      ),
    );
  }
}
