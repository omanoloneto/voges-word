import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> _arb(String language) =>
    jsonDecode(File('lib/l10n/updater_$language.arb').readAsStringSync())
        as Map<String, dynamic>;

Set<String> _messages(Map<String, dynamic> arb) =>
    arb.keys.where((key) => !key.startsWith('@')).toSet();

/// `{name}` and the `{count, plural, …}` selector; the text of a plural
/// branch, such as `{1 window}`, isn't a placeholder.
Set<String> _placeholders(String message) =>
    RegExp(r'\{(\w+)[,}]').allMatches(message).map((m) => m.group(1)!).toSet();

void main() {
  final english = _arb('en');

  test('the English template declares every placeholder it uses', () {
    for (final key in _messages(english)) {
      final metadata = english['@$key'] as Map<String, dynamic>?;
      final declared = metadata?['placeholders'] as Map<String, dynamic>?;
      expect(
        _placeholders(english[key] as String),
        declared?.keys.toSet() ?? <String>{},
        reason: key,
      );
      expect(metadata?['description'], isA<String>(), reason: key);
    }
  });

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

    test('$language keeps the brand names', () {
      final translated = _arb(language);
      for (final key in _messages(english)) {
        for (final brand in ['Voges Updater', 'macOS']) {
          if ((english[key] as String).contains(brand)) {
            expect(translated[key], contains(brand), reason: key);
          }
        }
      }
    });
  }
}
