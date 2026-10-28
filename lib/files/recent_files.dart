import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'document_files.dart';

class RecentFile {
  const RecentFile({required this.name, required this.path, this.bookmark});

  factory RecentFile.fromJson(Map<String, dynamic> json) => RecentFile(
    name: json['name'] as String,
    path: json['path'] as String,
    bookmark: json['bookmark'] as String?,
  );

  final String name;
  final String path;

  /// No macOS, permissão guardada para reabrir o arquivo depois (sandbox).
  final String? bookmark;

  Map<String, dynamic> toJson() => {
    'name': name,
    'path': path,
    'bookmark': ?bookmark,
  };
}

/// Últimos arquivos abertos ou salvos; só no computador, onde há caminho fixo.
class RecentFiles extends ChangeNotifier {
  RecentFiles(this._files);

  static const _key = 'arquivos_recentes';
  static const _limit = 8;
  static const _bookmarks = MethodChannel('voges_word/bookmarks');

  final DocumentFiles _files;
  var _items = <RecentFile>[];

  List<RecentFile> get items => List.unmodifiable(_items);

  bool get isSupported => _files.canSaveInPlace;

  Future<void> load() async {
    if (!isSupported) return;
    try {
      final preferences = await SharedPreferences.getInstance();
      _items = [
        for (final entry in preferences.getStringList(_key) ?? const <String>[])
          RecentFile.fromJson(jsonDecode(entry) as Map<String, dynamic>),
      ];
    } catch (_) {
      _items = [];
    }
    notifyListeners();
  }

  Future<void> remember(String path) async {
    if (!isSupported) return;
    String? bookmark;
    if (Platform.isMacOS) {
      try {
        bookmark = await _bookmarks.invokeMethod<String>('create', path);
      } on PlatformException {
        bookmark = null;
      } on MissingPluginException {
        bookmark = null;
      }
    }
    final name = path.split(RegExp(r'[\\/]')).last;
    _items = [
      RecentFile(name: name, path: path, bookmark: bookmark),
      ..._items.where((item) => item.path != path),
    ].take(_limit).toList();
    notifyListeners();
    await _save();
  }

  Future<OpenedFile> open(RecentFile file) async {
    var path = file.path;
    final bookmark = file.bookmark;
    if (Platform.isMacOS && bookmark != null) {
      path = await _bookmarks.invokeMethod<String>('resolve', bookmark) ?? path;
    }
    return _files.read(path);
  }

  Future<void> forget(RecentFile file) async {
    _items = _items.where((item) => item.path != file.path).toList();
    notifyListeners();
    await _save();
  }

  Future<void> _save() async {
    try {
      final preferences = await SharedPreferences.getInstance();
      await preferences.setStringList(_key, [
        for (final item in _items) jsonEncode(item.toJson()),
      ]);
    } catch (_) {
      return;
    }
  }
}
