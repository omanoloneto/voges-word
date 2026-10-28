import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_quill/flutter_quill.dart';

import 'editor/editor_screen.dart';
import 'editor/editor_session.dart';
import 'editor/window_buttons.dart';
import 'files/recent_files.dart';
import 'files/recovery.dart';
import 'files/system_open.dart';
import 'fonts/font_catalog.dart';
import 'spell/spell_checker.dart';

const brandColor = Color(0xFF3D6FD8);

class VogesWordApp extends StatelessWidget {
  const VogesWordApp({
    required this.session,
    required this.systemOpen,
    required this.recents,
    required this.fonts,
    required this.launchArguments,
    this.windowButtons = WindowButtonsLayout.right,
    this.recovery,
    this.spelling,
    super.key,
  });

  final EditorSession session;
  final SystemOpen systemOpen;
  final RecentFiles recents;
  final FontCatalog fonts;
  final List<String> launchArguments;
  final WindowButtonsLayout windowButtons;
  final RecoveryStore? recovery;
  final SpellChecker? spelling;

  ThemeData _theme(Brightness brightness) => ThemeData(
    colorScheme: ColorScheme.fromSeed(
      seedColor: brandColor,
      brightness: brightness,
    ),
    visualDensity: VisualDensity.standard,
    tooltipTheme: const TooltipThemeData(
      waitDuration: Duration(milliseconds: 400),
    ),
  );

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Voges Word',
      debugShowCheckedModeBanner: false,
      theme: _theme(Brightness.light),
      darkTheme: _theme(Brightness.dark),
      locale: const Locale('pt', 'BR'),
      supportedLocales: const [Locale('pt', 'BR'), Locale('en')],
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
        FlutterQuillLocalizations.delegate,
      ],
      home: EditorScreen(
        session: session,
        systemOpen: systemOpen,
        recents: recents,
        fonts: fonts,
        launchArguments: launchArguments,
        windowButtons: windowButtons,
        recovery: recovery,
        spelling: spelling,
      ),
    );
  }
}
