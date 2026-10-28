// ignore_for_file: experimental_member_use

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:window_manager/window_manager.dart';

import '../l10n/l10n.dart';
import 'ribbon/ribbon_style.dart';

enum WindowButton { minimize, maximize, close }

/// Side and order of the window buttons the app draws (Windows and Linux).
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

  /// GNOME format (gtk-decoration-layout), e.g. "appmenu:minimize,close".
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

  /// On Linux it follows the system setting; without one, on the right.
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

/// On macOS the buttons are the system ones, just centered in the blue ribbon.
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
              message: _label(context.l10n, button),
              child: Semantics(
                button: true,
                label: _label(context.l10n, button),
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

  String _label(AppLocalizations l10n, WindowButton button) => switch (button) {
    WindowButton.minimize => l10n.minimize,
    WindowButton.maximize => isMaximized ? l10n.restore : l10n.maximize,
    WindowButton.close => l10n.close,
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

/// Round button in the GNOME style.
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
