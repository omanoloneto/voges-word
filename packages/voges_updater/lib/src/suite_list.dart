import 'dart:convert';
import 'dart:typed_data';

import 'catalog.dart';

/// The suite list that the website publishes, signed with the release key,
/// so apps that are already installed learn about an app that came later.
///
/// It carries only the name and the Windows AppId of each app; everything
/// else follows from the name through [SuiteApp.conventional]:
///
///     {"format": 1, "serial": 3, "apps": [
///       {"name": "Voges Word", "windowsAppId": "{237302D4-…}"}
///     ]}
final class SuiteList {
  const SuiteList({required this.serial, required this.apps});

  /// Grows with every list published, so an older list is never taken for
  /// the newest one.
  final int serial;

  final List<SuiteApp> apps;

  static const format = 1;

  /// More apps than this is not the Voges suite.
  static const maxApps = 32;

  /// A serial past this is a mistake: no list could come after it.
  static const maxSerial = 1000000;

  /// Reads the bytes of a list. Any key, type or value out of place throws
  /// a [FormatException]: a list is taken whole or not at all.
  factory SuiteList.parse(Uint8List bytes) {
    final Object? root = jsonDecode(utf8.decode(bytes));
    if (root is! Map<String, Object?> ||
        !_hasExactly(root, const {'format', 'serial', 'apps'})) {
      throw const FormatException('Not a suite list');
    }
    if (root['format'] != format) {
      throw FormatException('Unknown format', root['format']);
    }
    final serial = root['serial'];
    if (serial is! int || serial < 1 || serial > maxSerial) {
      throw FormatException('Not a serial', serial);
    }
    final entries = root['apps'];
    if (entries is! List<Object?> ||
        entries.isEmpty ||
        entries.length > maxApps) {
      throw const FormatException('Not a list of apps');
    }
    final apps = <SuiteApp>[];
    for (final entry in entries) {
      if (entry is! Map<String, Object?> ||
          !_hasExactly(entry, const {'name', 'windowsAppId'})) {
        throw const FormatException('Not a suite app');
      }
      final name = entry['name'];
      final appId = entry['windowsAppId'];
      if (name is! String || appId is! String) {
        throw const FormatException('Not a suite app');
      }
      final app = SuiteApp.conventional(name: name, windowsAppId: appId);
      if (apps.any((other) => _sameName(other, app) || _sameId(other, app))) {
        throw FormatException('Listed twice', name);
      }
      apps.add(app);
    }
    return SuiteList(serial: serial, apps: List.unmodifiable(apps));
  }

  /// The bytes of the list of [apps] that [SuiteList.parse] reads back.
  static Uint8List encode({required int serial, required List<SuiteApp> apps}) {
    const encoder = JsonEncoder.withIndent('  ');
    return utf8.encode(
      '${encoder.convert({
        'format': format,
        'serial': serial,
        'apps': [
          for (final app in apps) {'name': app.name, 'windowsAppId': app.windows.appId},
        ],
      })}\n',
    );
  }

  /// [builtIn] followed by the apps that only this list knows. The apps
  /// compiled into the build are never replaced: a list that gives one of
  /// them another AppId, or gives its AppId to another app, throws a
  /// [FormatException].
  List<SuiteApp> mergedInto(List<SuiteApp> builtIn) {
    final merged = [...builtIn];
    for (final app in apps) {
      final known = builtIn.where((own) => _sameName(own, app)).firstOrNull;
      if (known != null) {
        if (!_sameId(known, app)) {
          throw FormatException('Another AppId for an app', app.name);
        }
        continue;
      }
      if (builtIn.any((own) => _sameId(own, app))) {
        throw FormatException('The AppId of another app', app.name);
      }
      merged.add(app);
    }
    return List.unmodifiable(merged);
  }

  static bool _hasExactly(Map<String, Object?> map, Set<String> keys) =>
      map.length == keys.length && map.keys.every(keys.contains);

  // File systems and bundle ids do not tell upper from lower case, and
  // the spaces of a name are dropped in its files
  static bool _sameName(SuiteApp a, SuiteApp b) => _key(a) == _key(b);

  static String _key(SuiteApp app) =>
      app.name.replaceAll(' ', '').toLowerCase();

  static bool _sameId(SuiteApp a, SuiteApp b) =>
      a.windows.appId == b.windows.appId;
}
