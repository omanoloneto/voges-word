import 'dart:async';
import 'dart:io';
import 'dart:ui' show Locale;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

class Misspelling {
  const Misspelling(this.start, this.end, this.suggestions);

  /// Posições dentro do texto do parágrafo.
  final int start;
  final int end;
  final List<String> suggestions;
}

/// Corretor do sistema: NSSpellChecker no macOS; no celular, o serviço de
/// ortografia do teclado. Windows, Linux e web ficam sem por enquanto.
abstract interface class SpellBackend {
  Future<List<List<Misspelling>>> check(List<String> texts);
}

SpellBackend? platformSpellBackend() {
  if (kIsWeb) return null;
  if (Platform.isMacOS) return const _NativeSpellBackend();
  if (Platform.isAndroid || Platform.isIOS) return _MobileSpellBackend();
  return null;
}

class _NativeSpellBackend implements SpellBackend {
  const _NativeSpellBackend();

  static const _channel = MethodChannel('voges_word/spell');

  @override
  Future<List<List<Misspelling>>> check(List<String> texts) async {
    final results =
        await _channel.invokeListMethod<Object?>('check', texts) ?? const [];
    return [
      for (final found in results)
        [
          for (final item in (found! as List).cast<Map<Object?, Object?>>())
            Misspelling(
              item['start']! as int,
              item['end']! as int,
              (item['suggestions']! as List).cast<String>(),
            ),
        ],
    ];
  }
}

class _MobileSpellBackend implements SpellBackend {
  final _service = DefaultSpellCheckService();

  @override
  Future<List<List<Misspelling>>> check(List<String> texts) async => [
    for (final text in texts)
      [
        for (final span
            in await _service.fetchSpellCheckSuggestions(
                  const Locale('pt', 'BR'),
                  text,
                ) ??
                const <SuggestionSpan>[])
          Misspelling(span.range.start, span.range.end, span.suggestions),
      ],
  ];
}

/// Ortografia dos parágrafos, verificada em segundo plano e guardada pelo
/// texto de cada um; palavras ignoradas valem para todos os documentos.
class SpellChecker extends ChangeNotifier {
  SpellChecker(this._backend);

  static const _ignoredKey = 'ortografia_ignoradas';
  static const _enabledKey = 'ortografia_ligada';

  final SpellBackend _backend;
  final _results = <String, List<Misspelling>>{};
  final _queue = <String>{};
  var _ignored = <String>{};
  var _enabled = true;
  Timer? _timer;
  var _running = false;
  var _disposed = false;

  bool get enabled => _enabled;

  Future<void> load() async {
    try {
      final preferences = await SharedPreferences.getInstance();
      _ignored = {...?preferences.getStringList(_ignoredKey)};
      _enabled = preferences.getBool(_enabledKey) ?? true;
    } catch (_) {
      return;
    }
    if (!_disposed) notifyListeners();
  }

  set enabled(bool value) {
    if (_enabled == value) return;
    _enabled = value;
    notifyListeners();
    _save((preferences) => preferences.setBool(_enabledKey, value));
  }

  /// Nulo enquanto o parágrafo ainda não foi verificado.
  List<Misspelling>? misspellingsOf(String text) {
    if (!_enabled || text.trim().isEmpty) return null;
    final found = _results[text];
    if (found == null) {
      _enqueue(text);
      return null;
    }
    return [
      for (final misspelling in found)
        if (misspelling.end <= text.length &&
            !_ignored.contains(
              text.substring(misspelling.start, misspelling.end).toLowerCase(),
            ))
          misspelling,
    ];
  }

  void ignore(String word) {
    if (!_ignored.add(word.toLowerCase())) return;
    notifyListeners();
    final words = _ignored.toList()..sort();
    _save((preferences) => preferences.setStringList(_ignoredKey, words));
  }

  void _enqueue(String text) {
    if (!_queue.add(text)) return;
    _timer?.cancel();
    _timer = Timer(const Duration(milliseconds: 400), _drain);
  }

  Future<void> _drain() async {
    if (_running) return;
    _running = true;
    try {
      while (_queue.isNotEmpty && !_disposed) {
        final batch = _queue.take(20).toList();
        _queue.removeAll(batch);
        final found = await _backend.check(batch);
        for (var i = 0; i < batch.length && i < found.length; i++) {
          _results[batch[i]] = found[i];
        }
        if (_results.length > 4000) {
          _results.remove(_results.keys.first);
        }
        if (!_disposed) notifyListeners();
      }
    } catch (_) {
      _queue.clear();
    } finally {
      _running = false;
    }
  }

  void _save(Future<void> Function(SharedPreferences) write) {
    SharedPreferences.getInstance().then(write).catchError((_) {});
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    super.dispose();
  }
}
