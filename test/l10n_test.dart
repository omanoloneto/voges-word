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
}
