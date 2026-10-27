import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

import 'app.dart';
import 'docx/docx_codec.dart';
import 'document/plain_text_codec.dart';
import 'document/tables.dart';
import 'editor/editor_screen.dart';
import 'editor/editor_session.dart';
import 'files/document_files.dart';
import 'files/system_open.dart';

Future<void> main(List<String> arguments) async {
  WidgetsFlutterBinding.ensureInitialized();
  if (isDesktop) {
    await windowManager.ensureInitialized();
    await windowManager.waitUntilReadyToShow(
      const WindowOptions(
        title: 'Voges Word',
        size: Size(1180, 860),
        minimumSize: Size(420, 360),
        center: true,
      ),
      () async {
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

  runApp(
    VogesWordApp(
      session: session,
      systemOpen: SystemOpen(files),
      launchArguments: arguments,
    ),
  );
}
