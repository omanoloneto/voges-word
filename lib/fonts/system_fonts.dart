import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'font_names.dart';

const _channel = MethodChannel('voges_word/fonts');

/// Installed families that Flutter draws by name. On Android it does not find
/// the device's fonts by name; there, on iOS and on the web, only Google Fonts
/// are available.
Future<List<String>> systemFontFamilies() async {
  if (kIsWeb) return const [];
  if (Platform.isMacOS) {
    return await _channel.invokeListMethod<String>('families') ?? const [];
  }
  if (Platform.isLinux) return _fontconfigFamilies();
  if (Platform.isWindows) return compute(_windowsFamilies, null);
  return const [];
}

Future<List<String>> _fontconfigFamilies() async {
  final result = await Process.run('fc-list', ['--format', r'%{family[0]}\n']);
  if (result.exitCode != 0) return const [];
  return {
    for (final line in '${result.stdout}'.split('\n'))
      if (line.trim().isNotEmpty) line.trim(),
  }.toList();
}

List<String> _windowsFamilies(void _) {
  final windows = Platform.environment['WINDIR'] ?? r'C:\Windows';
  final local = Platform.environment['LOCALAPPDATA'];
  return fontFamiliesIn([
    '$windows\\Fonts',
    if (local != null) '$local\\Microsoft\\Windows\\Fonts',
  ]);
}
