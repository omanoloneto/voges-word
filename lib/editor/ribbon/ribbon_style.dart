import 'package:flutter/material.dart';

/// Cores da faixa azul do topo (mesmas no tema claro e escuro).
abstract final class RibbonColors {
  static const background = Color(0xFF3D6FD8);
  static const panel = Color(0xFF3464CC);
  static const panelBorder = Color(0xFF5A86E4);
  static const field = Color(0xFF2C56B8);
  static const selected = Color(0xFF5E8AE8);
  static const hover = Color(0x26FFFFFF);
  static const text = Color(0xFFFFFFFF);
  static const muted = Color(0xFFC8D7F8);
  static const divider = Color(0x40FFFFFF);
  static const menu = Color(0xFF2F5BC2);
}

abstract final class RibbonText {
  static const label = TextStyle(color: RibbonColors.muted, fontSize: 11);
  static const control = TextStyle(color: RibbonColors.text, fontSize: 13);
  static const tab = TextStyle(color: RibbonColors.muted, fontSize: 13.5);
  static const activeTab = TextStyle(
    color: RibbonColors.text,
    fontSize: 13.5,
    fontWeight: FontWeight.w700,
  );
}

/// Tema dos menus abertos a partir da faixa.
MenuStyle ribbonMenuStyle() => const MenuStyle(
  backgroundColor: WidgetStatePropertyAll(RibbonColors.menu),
  surfaceTintColor: WidgetStatePropertyAll(Colors.transparent),
  shape: WidgetStatePropertyAll(
    RoundedRectangleBorder(borderRadius: BorderRadius.all(Radius.circular(10))),
  ),
  padding: WidgetStatePropertyAll(EdgeInsets.symmetric(vertical: 6)),
  maximumSize: WidgetStatePropertyAll(Size(340, 460)),
);

ButtonStyle ribbonMenuItemStyle() => ButtonStyle(
  foregroundColor: const WidgetStatePropertyAll(RibbonColors.text),
  iconColor: const WidgetStatePropertyAll(RibbonColors.text),
  overlayColor: const WidgetStatePropertyAll(RibbonColors.hover),
  textStyle: const WidgetStatePropertyAll(RibbonText.control),
  padding: const WidgetStatePropertyAll(EdgeInsets.symmetric(horizontal: 14)),
  minimumSize: const WidgetStatePropertyAll(Size(0, 38)),
  backgroundColor: WidgetStateProperty.resolveWith(
    (states) =>
        states.contains(WidgetState.disabled) ? null : Colors.transparent,
  ),
);
