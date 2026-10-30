import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> _arb(String language) =>
    jsonDecode(File('lib/l10n/app_$language.arb').readAsStringSync())
        as Map<String, dynamic>;

Set<String> _messages(Map<String, dynamic> arb) =>
    arb.keys.where((key) => !key.startsWith('@')).toSet();

Set<String> _placeholders(String message) =>
    RegExp(r'\{(\w+)').allMatches(message).map((m) => m.group(1)!).toSet();

/// Keys that appear more than once in an object of [json], which jsonDecode
/// would silently reduce to the last one.
List<String> _repeatedKeys(String json) {
  final repeated = <String>[];
  final objects = <Set<String>>[];
  final tokens = RegExp(r'("(?:[^"\\]|\\.)*")(\s*:)?|[{}]');
  for (final token in tokens.allMatches(json)) {
    if (token[0] == '{') {
      objects.add({});
    } else if (token[0] == '}') {
      objects.removeLast();
    } else if (token[2] != null) {
      final key = jsonDecode(token[1]!) as String;
      if (!objects.last.add(key)) repeated.add(key);
    }
  }
  return repeated;
}

void main() {
  final english = _arb('en');

  for (final language in ['pt', 'es']) {
    test('$language has every message of the English template', () {
      final translated = _arb(language);
      expect(_messages(translated), _messages(english));
    });

    test('$language keeps the placeholders of each message', () {
      final translated = _arb(language);
      for (final key in _messages(english)) {
        expect(
          _placeholders(translated[key] as String),
          _placeholders(english[key] as String),
          reason: key,
        );
      }
    });
  }

  test('each .arb file has each key once, and all have the same messages', () {
    expect(_repeatedKeys('{"a": "{x}", "b": {"a": 1}, "a": "\\"a\\":"}'), [
      'a',
    ]);
    final files = {
      for (final file in Directory('lib/l10n').listSync().whereType<File>())
        if (RegExp(r'app_(\w+)\.arb$').firstMatch(file.path) case final match?)
          match[1]!: file.readAsStringSync(),
    };
    expect(files.keys, unorderedEquals(['en', 'pt', 'es']));
    for (final MapEntry(key: language, value: json) in files.entries) {
      expect(_repeatedKeys(json), isEmpty, reason: language);
      expect(
        _messages(jsonDecode(json) as Map<String, dynamic>),
        _messages(english),
        reason: language,
      );
    }
  });

  test('protected content and pictures only promise to be kept in .docx', () {
    for (final language in ['en', 'pt', 'es']) {
      final arb = _arb(language);
      for (final key in [
        'protectedContentTooltip',
        'keptAsIs',
        'unsupportedImage',
        'pictureTooLarge',
      ]) {
        expect(arb[key], contains('.docx'), reason: '$language $key');
      }
    }
  });
}
