import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../document/document_codec.dart';

class RecoverySnapshot {
  const RecoverySnapshot({
    required this.name,
    required this.format,
    required this.bytes,
    required this.savedAt,
    this.path,
    DocumentFormat? content,
  }) : content = content ?? format;

  final String name;
  final String? path;

  /// Format of the document's file.
  final DocumentFormat format;

  /// Format of [bytes].
  final DocumentFormat content;
  final Uint8List bytes;
  final DateTime savedAt;
}

/// Copy of the document with unsaved changes, kept in the app's folder.
/// It never writes to the user's file: a conversion error would ruin the
/// original.
class RecoveryStore {
  RecoveryStore({Future<Directory?> Function()? directory})
    : _directory = directory ?? _defaultDirectory;

  final Future<Directory?> Function() _directory;

  Future<void> save(RecoverySnapshot snapshot) async {
    final directory = await _directory();
    if (directory == null) return;
    await directory.create(recursive: true);
    await _replace(File('${directory.path}/documento.bin'), snapshot.bytes);
    await _replace(
      File('${directory.path}/documento.json'),
      utf8.encode(
        jsonEncode({
          'name': snapshot.name,
          'path': snapshot.path,
          'format': snapshot.format.name,
          'content': snapshot.content.name,
          'savedAt': snapshot.savedAt.toIso8601String(),
          'sha256': sha256.convert(snapshot.bytes).toString(),
        }),
      ),
    );
  }

  /// Null if there is no copy or it was left half-written.
  Future<RecoverySnapshot?> load() async {
    try {
      final directory = await _directory();
      if (directory == null) return null;
      final info = File('${directory.path}/documento.json');
      final content = File('${directory.path}/documento.bin');
      if (!await info.exists() || !await content.exists()) return null;
      final json =
          jsonDecode(await info.readAsString()) as Map<String, dynamic>;
      final bytes = await content.readAsBytes();
      if (sha256.convert(bytes).toString() != json['sha256']) return null;
      return RecoverySnapshot(
        name: json['name'] as String,
        path: json['path'] as String?,
        format: DocumentFormat.values.byName(json['format'] as String),
        // copies from 1.2.0 have no content: the bytes are in their format
        content: switch (json['content']) {
          final String content => DocumentFormat.values.byName(content),
          _ => null,
        },
        bytes: bytes,
        savedAt: DateTime.parse(json['savedAt'] as String),
      );
    } catch (_) {
      return null;
    }
  }

  Future<void> clear() async {
    try {
      final directory = await _directory();
      if (directory == null || !await directory.exists()) return;
      await directory.delete(recursive: true);
    } catch (_) {
      return;
    }
  }

  static Future<void> _replace(File file, List<int> bytes) async {
    final temporary = File('${file.path}.tmp');
    await temporary.writeAsBytes(bytes, flush: true);
    await temporary.rename(file.path);
  }
}

Future<Directory?> _defaultDirectory() async {
  if (kIsWeb) return null;
  final support = await getApplicationSupportDirectory();
  // This folder and its documento.bin and documento.json files are stored on
  // the user's device; renaming any of them loses their data.
  return Directory('${support.path}/recuperacao');
}
