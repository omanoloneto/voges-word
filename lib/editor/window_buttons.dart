// ignore_for_file: experimental_member_use

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:window_manager/window_manager.dart';

import 'ribbon/ribbon_style.dart';

enum WindowButton { minimize, maximize, close }

/// Lado e ordem dos botões da janela desenhados pelo app (Windows e Linux).
class WindowButtonsLayout {
  const WindowButtonsLayout({
    this.leading = const [],
    this.trailing = const [],
  });

  static const right = WindowButtonsLayout(
    trailing: [
      WindowButton.minimize,
      WindowButton.maximize,
      WindowButton.close,
    ],
  );

  /// Formato do GNOME (gtk-decoration-layout), ex.: "appmenu:minimize,close".
  factory WindowButtonsLayout.parse(String value) {
    List<WindowButton> buttons(String side) => [
      for (final name in side.split(','))
        for (final button in WindowButton.values)
          if (button.name == name.trim()) button,
    ];
    final sides = value.replaceAll("'", '').trim().split(':');
    final layout = WindowButtonsLayout(
      leading: buttons(sides.first),
      trailing: sides.length > 1 ? buttons(sides[1]) : const [],
    );
    return layout.leading.isEmpty && layout.trailing.isEmpty ? right : layout;
  }

  final List<WindowButton> leading;
  final List<WindowButton> trailing;

  /// No Linux segue a configuração do sistema; sem ela, à direita.
  static Future<WindowButtonsLayout> forPlatform() async {
    if (kIsWeb || !Platform.isLinux) return right;
    try {
      final result = await Process.run('gsettings', [
        'get',
        'org.gnome.desktop.wm.preferences',
        'button-layout',
      ]);
      if (result.exitCode == 0) {
        return WindowButtonsLayout.parse('${result.stdout}');
      }
    } on ProcessException {
      return right;
    }
    return right;
  }
}

/// No macOS os botões são os do sistema, só centralizados na faixa azul.
Future<void> placeNativeWindowButtons(double titleBarHeight) async {
  if (kIsWeb || !Platform.isMacOS) return;
  try {
    await const MethodChannel(
      'voges_word/window',
    ).invokeMethod<void>('setTitleBarHeight', titleBarHeight);
  } on MissingPluginException {
    return;
  }
}

class WindowButtons extends StatelessWidget {
  const WindowButtons({
    required this.buttons,
    required this.isMaximized,
    required this.height,
    super.key,
  });

  final List<WindowButton> buttons;
  final bool isMaximized;
  final double height;

  static double widthOf(List<WindowButton> buttons) =>
      buttons.length *
          (defaultTargetPlatform == TargetPlatform.windows ? 46 : 36) +
      (buttons.isEmpty ? 0 : 8);

  @override
  Widget build(BuildContext context) {
    if (buttons.isEmpty) return const SizedBox.shrink();
    final windows = defaultTargetPlatform == TargetPlatform.windows;
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: windows ? 0 : 4),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (windows) const SizedBox(width: 8),
          for (final button in buttons)
            Tooltip(
              message: _label(button),
              child: Semantics(
                button: true,
                label: _label(button),
                child: windows
                    ? SizedBox(height: height, child: _windowsButton(button))
                    : SizedBox(
                        width: 36,
                        height: height,
                        child: Center(child: _RoundButton(button, isMaximized)),
                      ),
              ),
            ),
        ],
      ),
    );
  }

  String _label(WindowButton button) => switch (button) {
    WindowButton.minimize => 'Minimizar',
    WindowButton.maximize => isMaximized ? 'Restaurar' : 'Maximizar',
    WindowButton.close => 'Fechar',
  };

  Widget _windowsButton(WindowButton button) => switch (button) {
    WindowButton.minimize => WindowCaptionButton.minimize(
      brightness: Brightness.dark,
      onPressed: windowManager.minimize,
    ),
    WindowButton.maximize when isMaximized => WindowCaptionButton.unmaximize(
      brightness: Brightness.dark,
      onPressed: windowManager.unmaximize,
    ),
    WindowButton.maximize => WindowCaptionButton.maximize(
      brightness: Brightness.dark,
      onPressed: windowManager.maximize,
    ),
    WindowButton.close => WindowCaptionButton.close(
      brightness: Brightness.dark,
      onPressed: windowManager.close,
    ),
  };
}

/// Botão redondo no estilo do GNOME.
class _RoundButton extends StatelessWidget {
  const _RoundButton(this.button, this.isMaximized);

  final WindowButton button;
  final bool isMaximized;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: RibbonColors.field,
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        hoverColor: RibbonColors.hover,
        onTap: switch (button) {
          WindowButton.minimize => windowManager.minimize,
          WindowButton.maximize =>
            isMaximized ? windowManager.unmaximize : windowManager.maximize,
          WindowButton.close => windowManager.close,
        },
        child: SizedBox.square(
          dimension: 26,
          child: Icon(
            switch (button) {
              WindowButton.minimize => Icons.remove,
              WindowButton.maximize =>
                isMaximized ? Icons.filter_none : Icons.crop_square,
              WindowButton.close => Icons.close,
            },
            size: 15,
            color: RibbonColors.text,
          ),
        ),
      ),
    );
  }
}
