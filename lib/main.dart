import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

import 'app.dart';
import 'docx/docx_codec.dart';
import 'document/plain_text_codec.dart';
import 'document/tables.dart';
import 'editor/editor_factory.dart';
import 'editor/editor_session.dart';
import 'editor/title_bar.dart';
import 'editor/window_buttons.dart';
import 'files/document_files.dart';
import 'files/recent_files.dart';
import 'files/recovery.dart';
import 'files/system_open.dart';
import 'fonts/font_catalog.dart';

Future<void> main(List<String> arguments) async {
  WidgetsFlutterBinding.ensureInitialized();
  if (isDesktopPlatform) {
    await windowManager.ensureInitialized();
    await windowManager.waitUntilReadyToShow(
      WindowOptions(
        title: 'Voges Word',
        size: const Size(1240, 880),
        minimumSize: const Size(480, 420),
        center: true,
        titleBarStyle: TitleBarStyle.hidden,
        windowButtonVisibility: true,
      ),
      () async {
        await placeNativeWindowButtons(titleBarHeight);
        await windowManager.setPreventClose(true);
        await windowManager.show();
        await windowManager.focus();
      },
    );
  }

  final tables = TableStore();
  final docx = DocxCodec(tables);
  final files = DocumentFiles();
  final session = EditorSession(
    docx: docx,
    plainText: PlainTextCodec(look: docx.createEmpty().look, tables: tables),
    files: files,
    tables: tables,
  );

  final recents = RecentFiles(files);
  await recents.load();
  final windowButtons = await WindowButtonsLayout.forPlatform();
  final fonts = FontCatalog()..load().ignore();

  runApp(
    VogesWordApp(
      session: session,
      systemOpen: SystemOpen(files),
      recents: recents,
      fonts: fonts,
      launchArguments: arguments,
      windowButtons: windowButtons,
      recovery: RecoveryStore(),
    ),
  );
}
