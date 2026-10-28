import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app_localizations.dart';

/// Languages offered in the File menu, in the order they are listed.
const appLanguages = [Locale('en'), Locale('pt'), Locale('es')];

/// Each language written in itself, as language pickers usually do.
String languageName(Locale locale) => switch (locale.languageCode) {
  'pt' => 'Português',
  'es' => 'Español',
  _ => 'English',
};

/// Language tag written in new documents, so Word checks their spelling in
/// the same language.
String documentLanguageTag(Locale locale) => switch (locale.languageCode) {
  'pt' => 'pt-BR',
  'es' => 'es-ES',
  _ => 'en-US',
};

/// Spell checking language for the system checker.
String spellingLanguage(Locale locale) => switch (locale.languageCode) {
  'pt' => 'pt_BR',
  'es' => 'es',
  _ => 'en',
};

/// The language picked in the File menu; null follows the system.
class AppLanguage extends ChangeNotifier {
  AppLanguage([this._locale]);

  static const _key = 'app_language';

  Locale? _locale;

  Locale? get locale => _locale;

  Future<void> load() async {
    try {
      final preferences = await SharedPreferences.getInstance();
      final code = preferences.getString(_key);
      _locale = appLanguages
          .where((locale) => locale.languageCode == code)
          .firstOrNull;
    } catch (_) {
      return;
    }
    notifyListeners();
  }

  void select(Locale? locale) {
    if (locale == _locale) return;
    _locale = locale;
    notifyListeners();
    SharedPreferences.getInstance()
        .then(
          (preferences) => locale == null
              ? preferences.remove(_key)
              : preferences.setString(_key, locale.languageCode),
        )
        .ignore();
  }

  /// The language in use: the chosen one or the best match for the system.
  Locale resolve(List<Locale> systemLocales) =>
      _locale ??
      basicLocaleListResolution(
        systemLocales,
        AppLocalizations.supportedLocales,
      );
}
