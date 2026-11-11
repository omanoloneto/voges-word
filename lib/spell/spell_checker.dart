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

/// A backend that finds a word's suggestions only when asked: finding them
/// for every mistake is most of what checking costs.
abstract interface class SpellSuggester {
  Future<List<String>> suggest(String word, String language);
}

SpellBackend? platformSpellBackend() {
  if (kIsWeb) return null;
  if (Platform.isMacOS) return const _NativeSpellBackend();
  if (Platform.isAndroid || Platform.isIOS) return _MobileSpellBackend();
  return null;
}

class _NativeSpellBackend implements SpellBackend, SpellSuggester {
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
              (item['suggestions'] as List?)?.cast<String>() ?? const [],
            ),
        ],
    ];
  }

  @override
  Future<List<String>> suggest(String word, String language) async =>
      await _channel.invokeListMethod<String>('suggest', {
        'word': word,
        'language': language,
      }) ??
      const [];
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
  SpellChecker(this._backend, {@visibleForTesting this.maxResults = 20000});

  // Stored on the user's device; renaming these keys loses their data.
  static const _ignoredKey = 'ortografia_ignoradas';
  static const _enabledKey = 'ortografia_ligada';

  static const _batchSize = 20;

  /// How many paragraph texts keep their results. The editor keeps what each
  /// paragraph it shows found and asks again when the results read
  /// differently, as after an ignored word, so a long book fits.
  final int maxResults;

  final SpellBackend _backend;
  final _results = <String, _Checked>{};
  final _queue = <String>{};
  var _ignored = <String>{};
  var _enabled = true;
  var _language = 'en';
  Timer? _timer;
  var _running = false;
  var _disposed = false;

  /// Counts the announcements of new results.
  var _round = 0;

  var _generation = 0;

  /// Changes with every announcement of new results.
  int get round => _round;

  /// Changes whenever results already given may read differently: another
  /// language, words ignored, checking turned on or off.
  int get generation => _generation;

  bool get enabled => _enabled;

  String get language => _language;

  /// Results of another language are dropped and the text is checked again.
  set language(String value) {
    if (value == _language) return;
    _language = value;
    _results.clear();
    _queue.clear();
    _generation++;
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
    _generation++;
    if (!_disposed) notifyListeners();
  }

  set enabled(bool value) {
    if (_enabled == value) return;
    _enabled = value;
    _generation++;
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

  /// Whether the backend finds suggestions only when [suggestionsFor] asks.
  bool get suggestsOnRequest => _backend is SpellSuggester;

  /// What [word] could be, from a backend that finds it only when asked.
  Future<List<String>> suggestionsFor(String word) async {
    if (_backend case final SpellSuggester suggester) {
      try {
        return await suggester.suggest(word, _language);
      } catch (_) {
        return const [];
      }
    }
    return const [];
  }

  void ignore(String word) {
    if (!_ignored.add(word.toLowerCase())) return;
    _generation++;
    notifyListeners();
    final words = _ignored.toList()..sort();
    _save((preferences) => preferences.setStringList(_ignoredKey, words));
  }

  /// Whether [text] waits for the backend; it has results once it does not.
  bool isWaiting(String text) => _queue.contains(text);

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
        // A batch stays queued until its results are in, so it is waiting
        // all along.
        final batch = _queue.take(_batchSize).toList();
        final language = _language;
        final found = await _backend.check(batch, language);
        if (language != _language) continue;
        for (var i = 0; i < batch.length && i < found.length; i++) {
          _results[batch[i]] = _Checked(found[i], _round);
        }
        _queue.removeAll(batch);
        // The editor builds again only the paragraphs of the batch, so each
        // one shows its results as soon as they are in.
        _announce();
      }
    } catch (_) {
      _queue.clear();
    } finally {
      _running = false;
    }
  }

  void _announce() {
    if (_disposed) return;
    _trim();
    _round++;
    notifyListeners();
  }

  /// Drops the oldest results beyond [maxResults] that were neither checked
  /// nor asked for in the last two rounds. The editor keeps what each
  /// paragraph it shows found, so a dropped one is checked again only when
  /// its paragraph changes.
  void _trim() {
    final excess = _results.length - maxResults;
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
