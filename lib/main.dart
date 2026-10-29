import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:voges_updater/voges_updater.dart'
    show UpdateCheck, UpdaterRequest, runUpdater, vogesWord;
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
import 'l10n/app_language.dart';
import 'l10n/l10n.dart';
import 'spell/spell_checker.dart';

Future<void> main(List<String> arguments) async {
  WidgetsFlutterBinding.ensureInitialized();
  // On Windows and Linux a copy of the app itself is the updater; on macOS
  // the updater is a separate app, because this one is sandboxed.
  if (!kIsWeb &&
      UpdaterRequest.isUpdaterLaunch(arguments, defaultTargetPlatform.name)) {
    final language = AppLanguage();
    await language.load();
    return runUpdater(
      arguments: arguments,
      host: vogesWord,
      locale: language.locale,
    );
  }
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

  final language = AppLanguage();
  await language.load();
  final locale = language.resolve(PlatformDispatcher.instance.locales);

  final tables = TableStore();
  final docx = DocxCodec(tables);
  final files = DocumentFiles();
  final session = EditorSession(
    docx: docx,
    plainText: PlainTextCodec(look: docx.createEmpty().look, tables: tables),
    files: files,
    tables: tables,
    locale: SessionLocale.of(lookupAppLocalizations(locale)),
  );

  final recents = RecentFiles(files);
  await recents.load();
  final windowButtons = await WindowButtonsLayout.forPlatform();
  final fonts = FontCatalog()..load().ignore();
  final backend = platformSpellBackend();
  final spelling = backend == null
      ? null
      : (SpellChecker(backend)
          ..language = spellingLanguage(locale)
          ..load());

  runApp(
    VogesWordApp(
      session: session,
      systemOpen: SystemOpen(files),
      recents: recents,
      fonts: fonts,
      launchArguments: arguments,
      language: language,
      windowButtons: windowButtons,
      recovery: RecoveryStore(),
      spelling: spelling,
      updates: isDesktopPlatform ? UpdateCheck.forPlatform(vogesWord) : null,
    ),
  );
}
