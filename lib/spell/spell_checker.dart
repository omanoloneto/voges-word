import 'dart:async';
import 'dart:io';
import 'dart:ui' show Locale;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

class Misspelling {
  const Misspelling(this.start, this.end, this.suggestions);

  /// Offsets within the paragraph's text.
  final int start;
  final int end;
  final List<String> suggestions;
}

/// The system spell checker: NSSpellChecker on macOS and the keyboard's spell
/// checking service on phones. Windows, Linux and the web have none for now.
abstract interface class SpellBackend {
  /// [language] is a code like `pt_BR`, `es` or `en`.
  Future<List<List<Misspelling>>> check(List<String> texts, String language);
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
  Future<List<List<Misspelling>>> check(
    List<String> texts,
    String language,
  ) async {
    final results =
        await _channel.invokeListMethod<Object?>('check', {
          'texts': texts,
          'language': language,
        }) ??
        const [];
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
  Future<List<List<Misspelling>>> check(
    List<String> texts,
    String language,
  ) async {
    final [code, ...region] = language.split('_');
    final locale = Locale(code, region.firstOrNull);
    return [
      for (final text in texts)
        [
          for (final span
              in await _service.fetchSpellCheckSuggestions(locale, text) ??
                  const <SuggestionSpan>[])
            Misspelling(span.range.start, span.range.end, span.suggestions),
        ],
    ];
  }
}

/// What the backend found in a paragraph.
final class _Checked {
  _Checked(this.misspellings, this.round);

  final List<Misspelling> misspellings;

  /// The announcement round in which it was checked or last asked for.
  int round;
}

/// Paragraph spelling, checked in the background and cached by each
/// paragraph's text; ignored words apply to every document.
class SpellChecker extends ChangeNotifier {
  SpellChecker(this._backend);

  // Stored on the user's device; renaming these keys loses their data.
  static const _ignoredKey = 'ortografia_ignoradas';
  static const _enabledKey = 'ortografia_ligada';

  static const _batchSize = 20;
  static const _maxResults = 4000;

  final SpellBackend _backend;
  final _results = <String, _Checked>{};
  final _queue = <String>{};
  var _ignored = <String>{};
  var _enabled = true;
  var _language = 'en';
  Timer? _timer;
  var _running = false;
  var _disposed = false;

  /// Counts the announcements of new results; each one rebuilds the editor,
  /// which asks again for every paragraph it shows.
  var _round = 0;

  bool get enabled => _enabled;

  String get language => _language;

  /// Results of another language are dropped and the text is checked again.
  set language(String value) {
    if (value == _language) return;
    _language = value;
    _results.clear();
    _queue.clear();
    if (!_disposed) notifyListeners();
  }

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

  /// Null while the paragraph has not been checked yet.
  List<Misspelling>? misspellingsOf(String text) {
    if (!_enabled || text.trim().isEmpty) return null;
    final result = _results[text];
    if (result == null) {
      _enqueue(text);
      return null;
    }
    result.round = _round;
    return [
      for (final misspelling in result.misspellings)
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
    var checked = 0;
    var announced = 0;
    try {
      while (_queue.isNotEmpty && !_disposed) {
        final batch = _queue.take(_batchSize).toList();
        _queue.removeAll(batch);
        final language = _language;
        final found = await _backend.check(batch, language);
        if (language != _language) continue;
        for (var i = 0; i < batch.length && i < found.length; i++) {
          _results[batch[i]] = _Checked(found[i], _round);
        }
        checked += batch.length;
        // Each announcement rebuilds the whole editor, so a long check
        // announces only when its results double, about log2(n) times. A
        // short queue, as while typing, is announced after every batch.
        if (checked >= 2 * announced || _queue.length < _batchSize) {
          announced = checked;
          _announce();
        }
      }
    } catch (_) {
      _queue.clear();
    } finally {
      _running = false;
      if (checked > announced) _announce();
    }
  }

  void _announce() {
    if (_disposed) return;
    _trim();
    _round++;
    notifyListeners();
  }

  /// Drops the oldest results beyond [_maxResults] that were neither checked
  /// nor asked for in the last two rounds. The editor asks for every
  /// paragraph it shows after each announcement, so dropping one of those
  /// would only queue it again.
  void _trim() {
    final excess = _results.length - _maxResults;
    if (excess <= 0) return;
    final unused = [
      for (final MapEntry(:key, :value) in _results.entries)
        if (value.round < _round - 1) key,
    ];
    for (final text in unused.take(excess)) {
      _results.remove(text);
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
