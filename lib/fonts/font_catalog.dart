import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'system_fonts.dart';

/// Fontes do Office trocadas pelas equivalentes de mesma métrica do Google
/// Fonts, para o texto quebrar nas mesmas linhas que no Word.
const metricCompatibleFonts = {
  'Arial': 'Arimo',
  'Calibri': 'Carlito',
  'Cambria': 'Caladea',
  'Courier New': 'Cousine',
  'Georgia': 'Gelasio',
  'Helvetica': 'Arimo',
  'Times New Roman': 'Tinos',
};

/// Fontes instaladas e do Google Fonts; as do Google são baixadas quando o
/// documento ou o usuário usa, conferidas pelo hash e guardadas no aparelho.
class FontCatalog extends ChangeNotifier {
  FontCatalog({
    Future<List<String>> Function() listSystemFonts = systemFontFamilies,
    Future<String> Function()? readGoogleCatalog,
    Future<Uint8List> Function(Uri url)? download,
    Future<Directory?> Function()? cacheDirectory,
  }) : _listSystemFonts = listSystemFonts,
       _readGoogleCatalog = readGoogleCatalog ?? _bundledCatalog,
       _download = download ?? _httpDownload,
       _cacheDirectory = cacheDirectory ?? _defaultCacheDirectory;

  final Future<List<String>> Function() _listSystemFonts;
  final Future<String> Function() _readGoogleCatalog;
  final Future<Uint8List> Function(Uri url) _download;
  final Future<Directory?> Function() _cacheDirectory;

  var _system = const <String>[];
  var _systemNames = const <String>{};
  var _google = const <String, List<String>>{};
  var _listed = const <String>{};
  var _added = <String>{};
  var _googleNames = const <String>[];
  var _unlisted = const <String>[];
  final _registered = <String>{};
  final _pending = <String, Future<bool>>{};
  Future<void>? _loading;

  List<String> get systemFamilies => _system;

  /// O terço mais popular do catálogo, as adicionadas pelo usuário e os
  /// nomes do Office atendidos pelas equivalentes do Google.
  List<String> get googleFamilies => _googleNames;

  /// Fora da lista: aparecem na busca, para adicionar.
  List<String> get unlistedGoogleFamilies => _unlisted;

  Future<void> load() => _loading ??= _load();

  Future<void> _load() async {
    try {
      _system = _sorted(await _listSystemFonts());
    } catch (_) {
      _system = const [];
    }
    _systemNames = _system.toSet();
    final google = <String, List<String>>{};
    final listed = <String>{};
    try {
      for (final line in (await _readGoogleCatalog()).split('\n')) {
        if (line.split('\t') case [final name, final files, final inList]) {
          google[name] = files.split(' ');
          if (inList == '1') listed.add(name);
        }
      }
    } catch (_) {
      google.clear();
    }
    _google = google;
    _listed = listed;
    _added = await _readAdded();
    _refreshLists();
    notifyListeners();
  }

  void _refreshLists() {
    bool listed(String name) => _listed.contains(name) || _added.contains(name);
    _googleNames = _sorted([
      ..._google.keys.where(listed),
      for (final MapEntry(:key, :value) in metricCompatibleFonts.entries)
        if (_google.containsKey(value)) key,
    ]).where((name) => !_systemNames.contains(name)).toList();
    _unlisted = _sorted(
      _google.keys.where(
        (name) => !listed(name) && !_systemNames.contains(name),
      ),
    );
  }

  /// Põe uma fonte do Google na lista do usuário; fica salva no aparelho.
  Future<void> add(String family) async {
    await load();
    if (!_google.containsKey(family) || !_added.add(family)) return;
    _refreshLists();
    notifyListeners();
    try {
      final preferences = await SharedPreferences.getInstance();
      await preferences.setStringList(_addedKey, _added.toList()..sort());
    } catch (_) {
      return;
    }
  }

  Future<Set<String>> _readAdded() async {
    try {
      final preferences = await SharedPreferences.getInstance();
      return {...?preferences.getStringList(_addedKey)};
    } catch (_) {
      return {};
    }
  }

  /// Pode ser desenhada agora, sem baixar nada.
  bool isReady(String family) =>
      _systemNames.contains(family) || _registered.contains(family);

  bool canProvide(String family) =>
      isReady(family) || _filesFor(family) != null;

  List<String>? _filesFor(String family) =>
      _google[family] ?? _google[metricCompatibleFonts[family]];

  /// Baixa (ou lê do cache) e registra a família; falso se não deu.
  Future<bool> ensureLoaded(String family) async {
    await load();
    if (isReady(family)) return true;
    final files = _filesFor(family);
    if (files == null) return false;
    return _pending[family] ??= _register(family, files).whenComplete(() {
      _pending.remove(family);
    });
  }

  Future<bool> _register(String family, List<String> files) async {
    try {
      final faces = await Future.wait(files.map(_face));
      final loader = FontLoader(family);
      for (final face in faces) {
        loader.addFont(Future.value(ByteData.sublistView(face)));
      }
      await loader.load();
    } catch (_) {
      return false;
    }
    _registered.add(family);
    notifyListeners();
    return true;
  }

  Future<Uint8List> _face(String hash) async {
    final directory = await _cacheDirectory();
    final cached = directory == null
        ? null
        : File('${directory.path}/$hash.ttf');
    if (cached != null && await cached.exists()) {
      final bytes = await cached.readAsBytes();
      if (_matches(bytes, hash)) return bytes;
    }
    final bytes = await _download(
      Uri.https('fonts.gstatic.com', '/s/a/$hash.ttf'),
    );
    if (!_matches(bytes, hash)) {
      throw const FormatException('Fonte baixada não confere com o catálogo.');
    }
    if (cached != null) {
      await cached.parent.create(recursive: true);
      await cached.writeAsBytes(bytes, flush: true);
    }
    return bytes;
  }
}

const _addedKey = 'fontes_adicionadas';

bool _matches(Uint8List bytes, String hash) =>
    sha256.convert(bytes).toString() == hash;

List<String> _sorted(Iterable<String> names) =>
    names
        .where((name) => name.isNotEmpty && !name.startsWith('.'))
        .toSet()
        .toList()
      ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));

Future<String> _bundledCatalog() =>
    rootBundle.loadString('assets/fonts/google_fonts.txt');

Future<Uint8List> _httpDownload(Uri url) async {
  final response = await http.get(url).timeout(const Duration(seconds: 30));
  if (response.statusCode != 200) {
    throw HttpException('HTTP ${response.statusCode}', uri: url);
  }
  return response.bodyBytes;
}

Future<Directory?> _defaultCacheDirectory() async {
  if (kIsWeb) return null;
  return Directory('${(await getApplicationSupportDirectory()).path}/fonts');
}
