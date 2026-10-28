import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'document_files.dart';

/// Files the system asked to open (double-click, "Open With").
class SystemOpen {
  SystemOpen(this._files);

  static const _channel = MethodChannel('voges_word/open');

  final DocumentFiles _files;

  Future<List<OpenedFile>> pending(List<String> launchArguments) async {
    final files = <OpenedFile>[];
    for (final argument in launchArguments) {
      if (argument.startsWith('-')) continue;
      try {
        files.add(await _files.read(argument));
      } catch (_) {
        continue;
      }
    }
    if (kIsWeb) return files;
    try {
      final received = await _channel.invokeListMethod<Object?>('pending');
      for (final item in received ?? const []) {
        final file = await _fromPlatform(item);
        if (file != null) files.add(file);
      }
    } on MissingPluginException {
      return files;
    }
    return files;
  }

  void listen(ValueChanged<OpenedFile> onOpen) {
    if (kIsWeb) return;
    _channel.setMethodCallHandler((call) async {
      if (call.method != 'open') return;
      for (final item in call.arguments as List<Object?>) {
        final file = await _fromPlatform(item);
        if (file != null) onOpen(file);
      }
    });
  }

  Future<OpenedFile?> _fromPlatform(Object? item) async {
    if (item is! Map) return null;
    final path = item['path'] as String?;
    final bytes = item['bytes'] as Uint8List?;
    if (bytes != null) {
      return OpenedFile(
        name: item['name'] as String? ?? 'Document.docx',
        bytes: bytes,
      );
    }
    if (path == null) return null;
    try {
      return await _files.read(path);
    } catch (_) {
      return null;
    }
  }
}
