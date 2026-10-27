import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_quill/flutter_quill.dart';

import 'editor/editor_screen.dart';
import 'editor/editor_session.dart';
import 'files/system_open.dart';

const brandColor = Color(0xFF1F5FAD);

class VogesWordApp extends StatelessWidget {
  const VogesWordApp({
    required this.session,
    required this.systemOpen,
    required this.launchArguments,
    super.key,
  });

  final EditorSession session;
  final SystemOpen systemOpen;
  final List<String> launchArguments;

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
        launchArguments: launchArguments,
      ),
    );
  }
}
