// ignore_for_file: experimental_member_use

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_quill/flutter_quill.dart';
import 'package:window_manager/window_manager.dart';

import 'app_logo.dart';
import 'editor_factory.dart';
import 'editor_session.dart';
import 'ribbon/ribbon_controls.dart';
import 'ribbon/ribbon_style.dart';

bool get _isDesktop =>
    !kIsWeb && (Platform.isMacOS || Platform.isWindows || Platform.isLinux);

/// Título fica dentro da faixa azul no macOS e no Windows (sem barra do
/// sistema); no Linux a barra nativa continua.
bool get usesCustomTitleBar =>
    !kIsWeb && (Platform.isMacOS || Platform.isWindows);

class AppTitleBar extends StatelessWidget {
  const AppTitleBar({
    required this.session,
    required this.onFile,
    required this.isMaximized,
    super.key,
  });

  final EditorSession session;
  final VoidCallback onFile;
  final bool isMaximized;

  String get _mod => isApplePlatform ? '⌘' : 'Ctrl+';

  @override
  Widget build(BuildContext context) {
    final macOS = !kIsWeb && Platform.isMacOS && usesCustomTitleBar;
    final windows = !kIsWeb && Platform.isWindows;
    final wide = MediaQuery.sizeOf(context).width > 720;

    final bar = SizedBox(
      height: 46,
      child: Stack(
        children: [
          if (_isDesktop)
            const Positioned.fill(
              child: DragToMoveArea(child: SizedBox.expand()),
            ),
          Align(
            alignment: Alignment.centerLeft,
            child: Padding(
              padding: EdgeInsets.only(left: macOS ? 80 : 8),
              child: ValueListenableBuilder<QuillController>(
                valueListenable: session.activeController,
                builder: (context, controller, _) => ListenableBuilder(
                  listenable: controller,
                  builder: (context, _) => Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      RibbonIconButton(
                        icon: Icons.undo,
                        tooltip: 'Desfazer (${_mod}Z)',
                        onPressed: controller.hasUndo ? controller.undo : null,
                      ),
                      RibbonIconButton(
                        icon: Icons.redo,
                        tooltip: 'Refazer (${_mod}Y)',
                        onPressed: controller.hasRedo ? controller.redo : null,
                      ),
                      if (wide) ...[
                        const SizedBox(width: 8),
                        RibbonIconButton(
                          icon: Icons.content_copy,
                          tooltip: 'Copiar (${_mod}C)',
                          onPressed: controller.selection.isCollapsed
                              ? null
                              : () => controller.clipboardSelection(true),
                        ),
                        RibbonIconButton(
                          icon: Icons.content_cut,
                          tooltip: 'Recortar (${_mod}X)',
                          onPressed: controller.selection.isCollapsed
                              ? null
                              : () => controller.clipboardSelection(false),
                        ),
                        RibbonIconButton(
                          icon: Icons.content_paste,
                          tooltip: 'Colar (${_mod}V)',
                          onPressed: () => controller.clipboardPaste(),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ),
          Align(
            alignment: wide ? Alignment.center : Alignment.centerRight,
            child: Padding(
              padding: EdgeInsets.only(right: wide ? 0 : 8),
              child: _FilePill(session: session, onTap: onFile),
            ),
          ),
          if (windows && usesCustomTitleBar)
            Align(
              alignment: Alignment.topRight,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  WindowCaptionButton.minimize(
                    brightness: Brightness.dark,
                    onPressed: windowManager.minimize,
                  ),
                  if (isMaximized)
                    WindowCaptionButton.unmaximize(
                      brightness: Brightness.dark,
                      onPressed: windowManager.unmaximize,
                    )
                  else
                    WindowCaptionButton.maximize(
                      brightness: Brightness.dark,
                      onPressed: windowManager.maximize,
                    ),
                  WindowCaptionButton.close(
                    brightness: Brightness.dark,
                    onPressed: windowManager.close,
                  ),
                ],
              ),
            ),
        ],
      ),
    );
    return bar;
  }
}

class _FilePill extends StatelessWidget {
  const _FilePill({required this.session, required this.onTap});

  final EditorSession session;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    return ListenableBuilder(
      listenable: session,
      builder: (context, _) => Material(
        color: RibbonColors.field,
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(8),
          hoverColor: RibbonColors.hover,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const AppLogo(size: 18, outlined: true),
                const SizedBox(width: 8),
                const Text('Arquivo', style: RibbonText.activeTab),
                Container(
                  width: 1,
                  height: 18,
                  margin: const EdgeInsets.symmetric(horizontal: 10),
                  color: RibbonColors.divider,
                ),
                ConstrainedBox(
                  constraints: BoxConstraints(
                    maxWidth: width < 520 ? 120 : 280,
                  ),
                  child: Text(
                    session.name,
                    overflow: TextOverflow.ellipsis,
                    style: RibbonText.control,
                  ),
                ),
                if (session.dirty) ...[
                  const SizedBox(width: 6),
                  const Tooltip(
                    message: 'Alterações não salvas',
                    child: Icon(
                      Icons.circle,
                      size: 8,
                      color: RibbonColors.muted,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
