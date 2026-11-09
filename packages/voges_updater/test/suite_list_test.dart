import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:voges_updater/core.dart';

const _tablesId = '{1A75A94C-0C6B-4F0F-8F00-6056405F6F37}';
const _slidesId = '{00000000-0000-0000-0000-0000000000A1}';
const _otherId = '{00000000-0000-0000-0000-0000000000A2}';

Uint8List _json(Object? value) => utf8.encode(jsonEncode(value));

Map<String, Object?> _entry(String name, String appId) => {
  'name': name,
  'windowsAppId': appId,
};

Map<String, Object?> _list({
  Object? format = 1,
  Object? serial = 1,
  Object? apps,
}) => {
  'format': format,
  'serial': serial,
  'apps': apps ?? [_entry('Voges Slides', _slidesId)],
};

/// Every field of [app] in one string, to compare two apps by value.
String _fields(SuiteApp app) => [
  app.name,
  app.repository,
  app.downloadPage,
  app.macos.bundleId,
  app.macos.bundleName,
  app.macos.asset,
  app.windows.appId,
  app.windows.executable,
  app.windows.asset,
  app.linux.package,
  app.linux.binary,
  app.linux.launcher,
  app.linux.asset,
].join('\n');

void main() {
  group('SuiteApp.conventional', () {
    test('spells every app of the build exactly as the catalog does', () {
      for (final app in vogesSuite) {
        final derived = SuiteApp.conventional(
          name: app.name,
          windowsAppId: app.windows.appId,
        );
        expect(_fields(derived), _fields(app), reason: app.name);
      }
    });

    test('spells a name of several words', () {
      final app = SuiteApp.conventional(
        name: 'Voges Mind Map',
        windowsAppId: _slidesId,
      );
      expect(app.repository, 'omanoloneto/voges-mind-map');
      expect(app.downloadPage, 'https://omanoloneto.pro/voges/mind-map/');
      expect(app.macos.bundleId, 'com.omanoloneto.vogesMindMap');
      expect(app.macos.bundleName, 'Voges Mind Map.app');
      expect(app.macos.asset, 'VogesMindMap-macos.dmg');
      expect(app.windows.appId, _slidesId);
      expect(app.windows.executable, 'voges_mind_map.exe');
      expect(app.windows.asset, 'VogesMindMap-windows-setup.exe');
      expect(app.linux.package, 'voges-mind-map');
      expect(app.linux.binary, '/usr/lib/voges-mind-map/voges_mind_map');
      expect(app.linux.launcher, '/usr/bin/voges-mind-map');
      expect(app.linux.asset, 'voges-mind-map-linux-amd64.deb');
    });

    final badNames = {
      'no app word': 'Voges',
      'another brand': 'Other Word',
      'a lowercase word': 'Voges word',
      'an uppercase word': 'Voges WORD',
      'a digit': 'Voges Word2',
      'a dash': 'Voges Mind-Map',
      'a path': 'Voges Word/../X',
      'a dot': 'Voges Word.app',
      'two spaces': 'Voges  Word',
      'a leading space': ' Voges Word',
      'a trailing space': 'Voges Word ',
      'a trailing newline': 'Voges Word\n',
      'a letter with an accent': 'Voges Café',
      'four words': 'Voges One Two Three Four',
      'a word too long for a file name': 'Voges A${'b' * 21}',
      'nothing': '',
    };
    for (final MapEntry(key: reason, value: name) in badNames.entries) {
      test('refuses a name with $reason', () {
        expect(
          () => SuiteApp.conventional(name: name, windowsAppId: _slidesId),
          throwsFormatException,
        );
      });
    }

    final badIds = {
      'no braces': '00000000-0000-0000-0000-0000000000A1',
      'lowercase hex': '{00000000-0000-0000-0000-0000000000a1}',
      'a short group': '{0000000-0000-0000-0000-0000000000A1}',
      'a registry path': r'{00000000-0000-0000-0000-0000000000A1}\..\X',
      'a trailing newline': '{00000000-0000-0000-0000-0000000000A1}\n',
      'nothing': '',
    };
    for (final MapEntry(key: reason, value: appId) in badIds.entries) {
      test('refuses an AppId with $reason', () {
        expect(
          () =>
              SuiteApp.conventional(name: 'Voges Slides', windowsAppId: appId),
          throwsFormatException,
        );
      });
    }
  });

  group('SuiteList.parse', () {
    test('reads the serial and the apps, in order', () {
      final list = SuiteList.parse(
        _json(
          _list(
            serial: 7,
            apps: [
              _entry('Voges Tables', _tablesId),
              _entry('Voges Slides', _slidesId),
            ],
          ),
        ),
      );
      expect(list.serial, 7);
      expect(
        [for (final app in list.apps) app.name],
        ['Voges Tables', 'Voges Slides'],
      );
      expect(_fields(list.apps.first), _fields(vogesTables));
      expect(list.apps.last.repository, 'omanoloneto/voges-slides');
      expect(() => list.apps.add(vogesWord), throwsUnsupportedError);
    });

    test('reads back what encode writes', () {
      final bytes = SuiteList.encode(serial: 3, apps: vogesSuite);
      final list = SuiteList.parse(bytes);
      expect(list.serial, 3);
      expect(
        [for (final app in list.apps) _fields(app)],
        [for (final app in vogesSuite) _fields(app)],
      );
      expect(utf8.decode(bytes), endsWith('}\n'));
    });

    final malformed = <String, Object?>{
      'a list at the root': [_list()],
      'a string at the root': 'Voges Slides',
      'an extra key': {..._list(), 'repository': 'evil/repo'},
      'a missing key': {'format': 1, 'serial': 1},
      'another format': _list(format: 2),
      'the format as text': _list(format: '1'),
      'no serial': _list(serial: null),
      'serial zero': _list(serial: 0),
      'a negative serial': _list(serial: -1),
      'a fractional serial': _list(serial: 1.5),
      'the serial as text': _list(serial: '1'),
      'a serial that nothing could come after': _list(
        serial: SuiteList.maxSerial + 1,
      ),
      'apps that are not a list': _list(apps: {'name': 'Voges Slides'}),
      'no app': _list(apps: <Object?>[]),
      'more apps than the suite can have': _list(
        apps: [
          for (var i = 0; i <= SuiteList.maxApps; i++)
            _entry(
              'Voges ${String.fromCharCode(65 + i ~/ 26)}'
                  '${String.fromCharCode(97 + i % 26)}x',
              '{00000000-0000-0000-0000-${'$i'.padLeft(12, '0')}}',
            ),
        ],
      ),
      'an app that is text': _list(apps: ['Voges Slides']),
      'an app with an extra key': _list(
        apps: [
          {..._entry('Voges Slides', _slidesId), 'repository': 'evil/repo'},
        ],
      ),
      'an app without AppId': _list(
        apps: [
          {'name': 'Voges Slides'},
        ],
      ),
      'a name that is not text': _list(
        apps: [_entry('Voges Slides', _slidesId)..['name'] = 1],
      ),
      'a name outside the convention': _list(
        apps: [_entry('Voges ../Evil', _slidesId)],
      ),
      'an AppId outside its shape': _list(
        apps: [_entry('Voges Slides', 'not-an-id')],
      ),
      'the same name twice': _list(
        apps: [
          _entry('Voges Slides', _slidesId),
          _entry('Voges Slides', _otherId),
        ],
      ),
      'two names with the same files': _list(
        apps: [
          _entry('Voges Mindmap', _slidesId),
          _entry('Voges Mind Map', _otherId),
        ],
      ),
      'the same AppId twice': _list(
        apps: [
          _entry('Voges Slides', _slidesId),
          _entry('Voges Flash', _slidesId),
        ],
      ),
    };
    for (final MapEntry(key: reason, value: content) in malformed.entries) {
      test('refuses $reason', () {
        expect(() => SuiteList.parse(_json(content)), throwsFormatException);
      });
    }

    test('refuses bytes that are not JSON or not UTF-8', () {
      for (final bytes in [
        utf8.encode(''),
        utf8.encode('{"format": 1,'),
        Uint8List.fromList([0xff, 0xfe, 0x7b, 0x7d]),
      ]) {
        expect(() => SuiteList.parse(bytes), throwsFormatException);
      }
    });

    test('accepts the longest word and the last serial', () {
      final name = 'Voges A${'b' * 20}';
      final list = SuiteList.parse(
        _json(
          _list(serial: SuiteList.maxSerial, apps: [_entry(name, _slidesId)]),
        ),
      );
      expect(list.serial, SuiteList.maxSerial);
      expect(list.apps.single.name, name);
    });

    test('accepts exactly as many apps as the limit', () {
      final list = SuiteList.parse(
        _json(
          _list(
            apps: [
              for (var i = 0; i < SuiteList.maxApps; i++)
                _entry(
                  'Voges ${String.fromCharCode(65 + i ~/ 26)}'
                      '${String.fromCharCode(97 + i % 26)}x',
                  '{00000000-0000-0000-0000-${'$i'.padLeft(12, '0')}}',
                ),
            ],
          ),
        ),
      );
      expect(list.apps, hasLength(SuiteList.maxApps));
    });
  });

  group('mergedInto', () {
    SuiteList listOf(List<Map<String, Object?>> apps) =>
        SuiteList.parse(_json(_list(apps: apps)));

    test('keeps the apps of the build and adds the new ones after them', () {
      final merged = listOf([
        _entry('Voges Slides', _slidesId),
        _entry('Voges Tables', _tablesId),
        _entry('Voges Word', vogesWord.windows.appId),
      ]).mergedInto(vogesSuite);
      expect(merged.take(3), [
        same(vogesWord),
        same(vogesPencil),
        same(vogesTables),
      ]);
      expect([for (final app in merged.skip(3)) app.name], ['Voges Slides']);
      expect(() => merged.add(vogesWord), throwsUnsupportedError);
    });

    test('never drops an app of the build that the list leaves out', () {
      final merged = listOf([
        _entry('Voges Slides', _slidesId),
      ]).mergedInto(vogesSuite);
      expect(merged.take(3), vogesSuite);
      expect(merged, hasLength(4));
    });

    test('refuses a list that gives an app of the build another AppId', () {
      expect(
        () => listOf([_entry('Voges Word', _slidesId)]).mergedInto(vogesSuite),
        throwsFormatException,
      );
    });

    test('refuses a list that gives the AppId of an app of the build to '
        'another app', () {
      expect(
        () => listOf([
          _entry('Voges Slides', vogesWord.windows.appId),
        ]).mergedInto(vogesSuite),
        throwsFormatException,
      );
    });
  });
}
