import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

const _channel = MethodChannel('voges_word/print');

/// macOS e Android abrem a janela de impressão do sistema; Windows e Linux
/// abrem o PDF no visualizador padrão, de onde se imprime.
bool get printsWithDialog =>
    !kIsWeb && (Platform.isMacOS || Platform.isAndroid);

bool get printsFromViewer =>
    !kIsWeb && (Platform.isWindows || Platform.isLinux);

Future<void> printPdf(Uint8List pdf, String name) async {
  if (printsWithDialog) {
    await _channel.invokeMethod<void>('print', {'bytes': pdf, 'name': name});
    return;
  }
  if (!printsFromViewer) throw UnsupportedError('Impressão indisponível');
  final directory = await getTemporaryDirectory();
  final file = File(
    '${directory.path}${Platform.pathSeparator}${safeFileName(name)}.pdf',
  );
  await file.writeAsBytes(pdf, flush: true);
  await Process.run(Platform.isWindows ? 'explorer' : 'xdg-open', [file.path]);
}

String safeFileName(String name) =>
    name.replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1F]'), '_').trim();
