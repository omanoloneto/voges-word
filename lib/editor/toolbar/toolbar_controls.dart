import 'package:flutter/material.dart';

class ToolButton extends StatelessWidget {
  const ToolButton({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    this.selected = false,
    super.key,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      icon: Icon(icon),
      tooltip: tooltip,
      isSelected: selected,
      onPressed: onPressed,
      iconSize: 20,
      visualDensity: VisualDensity.compact,
      style:
          IconButton.styleFrom(
            minimumSize: const Size(40, 40),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(6),
            ),
          ).copyWith(
            backgroundColor: WidgetStateProperty.resolveWith(
              (states) => states.contains(WidgetState.selected)
                  ? Theme.of(context).colorScheme.secondaryContainer
                  : null,
            ),
          ),
    );
  }
}

class ToolGroupDivider extends StatelessWidget {
  const ToolGroupDivider({super.key});

  @override
  Widget build(BuildContext context) => const SizedBox(
    height: 28,
    child: VerticalDivider(width: 12, indent: 2, endIndent: 2),
  );
}

class MenuOption<T> {
  const MenuOption(this.value, this.label, {this.style});

  final T value;
  final String label;
  final TextStyle? style;
}

/// Caixa de seleção compacta (estilo, fonte, tamanho).
class ToolDropdown<T> extends StatelessWidget {
  const ToolDropdown({
    required this.tooltip,
    required this.label,
    required this.options,
    required this.selected,
    required this.onSelected,
    this.width = 120,
    super.key,
  });

  final String tooltip;
  final String label;
  final List<MenuOption<T>> options;
  final T? selected;
  final ValueChanged<T> onSelected;
  final double width;

  @override
  Widget build(BuildContext context) {
    return MenuAnchor(
      style: const MenuStyle(
        maximumSize: WidgetStatePropertyAll(Size(320, 420)),
      ),
      menuChildren: [
        for (final option in options)
          MenuItemButton(
            onPressed: () => onSelected(option.value),
            leadingIcon: Icon(
              Icons.check,
              size: 16,
              color: option.value == selected ? null : Colors.transparent,
            ),
            child: Text(option.label, style: option.style),
          ),
      ],
      builder: (context, controller, child) => Tooltip(
        message: tooltip,
        child: SizedBox(
          width: width,
          height: 36,
          child: OutlinedButton(
            onPressed: () =>
                controller.isOpen ? controller.close() : controller.open(),
            style: OutlinedButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(6),
              ),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    label,
                    overflow: TextOverflow.ellipsis,
                    maxLines: 1,
                  ),
                ),
                const Icon(Icons.arrow_drop_down, size: 18),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class ColorChoice {
  const ColorChoice(this.hex, this.name);

  /// Nulo remove a cor.
  final String? hex;
  final String name;
}

/// Botão com paleta curta, sem seletor de cor completo.
class ColorPaletteButton extends StatelessWidget {
  const ColorPaletteButton({
    required this.icon,
    required this.tooltip,
    required this.choices,
    required this.current,
    required this.onSelected,
    required this.clearLabel,
    super.key,
  });

  final IconData icon;
  final String tooltip;
  final List<ColorChoice> choices;
  final String? current;
  final ValueChanged<String?> onSelected;
  final String clearLabel;

  static Color colorOf(String hex) =>
      Color(int.parse('FF${hex.replaceFirst('#', '')}', radix: 16));

  @override
  Widget build(BuildContext context) {
    final indicator = current == null ? Colors.transparent : colorOf(current!);
    return MenuAnchor(
      menuChildren: [
        MenuItemButton(
          onPressed: () => onSelected(null),
          leadingIcon: const Icon(Icons.format_color_reset, size: 18),
          child: Text(clearLabel),
        ),
        Padding(
          padding: const EdgeInsets.all(8),
          child: SizedBox(
            width: 5 * 34,
            child: Wrap(
              spacing: 4,
              runSpacing: 4,
              children: [
                for (final choice in choices)
                  Tooltip(
                    message: choice.name,
                    child: Builder(
                      builder: (context) => InkWell(
                        onTap: () {
                          onSelected(choice.hex);
                          MenuController.maybeOf(context)?.close();
                        },
                        child: Container(
                          width: 30,
                          height: 30,
                          decoration: BoxDecoration(
                            color: colorOf(choice.hex!),
                            border: Border.all(
                              color: choice.hex == current
                                  ? Theme.of(context).colorScheme.primary
                                  : const Color(0x33000000),
                              width: choice.hex == current ? 2 : 1,
                            ),
                            borderRadius: BorderRadius.circular(4),
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
      builder: (context, controller, child) => IconButton(
        tooltip: tooltip,
        visualDensity: VisualDensity.compact,
        iconSize: 20,
        onPressed: () =>
            controller.isOpen ? controller.close() : controller.open(),
        icon: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 18),
            Container(width: 18, height: 4, color: indicator),
          ],
        ),
      ),
    );
  }
}

/// Grade para escolher linhas x colunas de uma tabela nova.
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
    final colors = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.all(10),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('Tabela $_rows × $_columns'),
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
                              ? colors.primaryContainer
                              : colors.surface,
                          border: Border.all(color: colors.outline, width: 0.8),
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
