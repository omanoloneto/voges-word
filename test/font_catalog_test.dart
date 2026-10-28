import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:voges_word/fonts/font_catalog.dart';
import 'package:voges_word/fonts/font_names.dart';

Uint8List _fakeFont(int seed) =>
    Uint8List.fromList(List.generate(256, (i) => (i * seed) & 0xFF));

List<int> _u16(int value) => [value >> 8 & 0xFF, value & 0xFF];

List<int> _u32(int value) => [..._u16(value >> 16), ..._u16(value & 0xFFFF)];

/// Minimal font with only the 'name' table, starting at [base] in the file.
Uint8List _sfnt(Map<int, String> names, {int platform = 3, int base = 0}) {
  final strings = <int>[];
  final records = <int>[];
  names.forEach((id, value) {
    final encoded = platform == 3
        ? [for (final unit in value.codeUnits) ..._u16(unit)]
        : latin1.encode(value);
    records.addAll([
      ..._u16(platform),
      ..._u16(platform == 3 ? 1 : 0),
      ..._u16(platform == 3 ? 0x409 : 0),
      ..._u16(id),
      ..._u16(encoded.length),
      ..._u16(strings.length),
    ]);
    strings.addAll(encoded);
  });
  final table = [
    ..._u16(0),
    ..._u16(names.length),
    ..._u16(6 + records.length),
    ...records,
    ...strings,
  ];
  return Uint8List.fromList([
    ..._u32(0x00010000),
    ..._u16(1),
    ..._u16(16),
    ..._u16(0),
    ..._u16(0),
    ..._u32(0x6E616D65),
    ..._u32(0),
    ..._u32(base + 28),
    ..._u32(table.length),
    ...table,
  ]);
}

Set<String> _families(Uint8List bytes) =>
    familyNamesOf((offset, length) => bytes.sublist(offset, offset + length));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  const google = 'Lato\taa\t1\nArimo\tbb\t1\nCarlito\tcc\t0\nPacifico\tdd\t0\n';

  test('splits installed fonts, the Google list and unlisted fonts', () async {
    final catalog = FontCatalog(
      listSystemFonts: () async => ['Georgia', '.SF NS', 'Arial'],
      readGoogleCatalog: () async => google,
    );
    await catalog.load();

    expect(catalog.systemFamilies, ['Arial', 'Georgia']);
    expect(catalog.googleFamilies, ['Arimo', 'Calibri', 'Helvetica', 'Lato']);
    expect(catalog.unlistedGoogleFamilies, ['Carlito', 'Pacifico']);
    expect(catalog.isReady('Georgia'), isTrue);
    expect(catalog.canProvide('Calibri'), isTrue);
    expect(catalog.canProvide('Aptos'), isFalse);
  });

  test('an added font joins the list and is saved', () async {
    FontCatalog catalog() => FontCatalog(
      listSystemFonts: () async => const [],
      readGoogleCatalog: () async => google,
    );
    final first = catalog();
    await first.add('Pacifico');
    await first.add('Inexistente');

    expect(first.googleFamilies, contains('Pacifico'));
    expect(first.unlistedGoogleFamilies, isNot(contains('Pacifico')));
    final reopened = catalog();
    await reopened.load();
    expect(reopened.googleFamilies, contains('Pacifico'));
    expect(reopened.googleFamilies, isNot(contains('Inexistente')));
  });

  test(
    'downloads, checks the hash, caches and registers the requested name',
    () async {
      final font = _fakeFont(3);
      final hash = sha256.convert(font).toString();
      final cache = Directory.systemTemp.createTempSync('fontes');
      addTearDown(() => cache.deleteSync(recursive: true));
      final requested = <Uri>[];
      FontCatalog catalog() => FontCatalog(
        listSystemFonts: () async => const [],
        readGoogleCatalog: () async => 'Carlito\t$hash\t0\n',
        download: (url) async {
          requested.add(url);
          return font;
        },
        cacheDirectory: () async => cache,
      );

      final first = catalog();
      expect(await first.ensureLoaded('Calibri'), isTrue);
      expect(first.isReady('Calibri'), isTrue);
      expect(File('${cache.path}/$hash.ttf').readAsBytesSync(), font);

      expect(await catalog().ensureLoaded('Carlito'), isTrue);
      expect(requested, [Uri.parse('https://fonts.gstatic.com/s/a/$hash.ttf')]);
    },
  );

  test('rejects a file that does not match the catalog', () async {
    final catalog = FontCatalog(
      listSystemFonts: () async => const [],
      readGoogleCatalog: () async => 'Lato\t${'0' * 64}\t1\n',
      download: (_) async => _fakeFont(5),
      cacheDirectory: () async => null,
    );

    expect(await catalog.ensureLoaded('Lato'), isFalse);
    expect(catalog.isReady('Lato'), isFalse);
    expect(await catalog.ensureLoaded('Aptos'), isFalse);
  });

  test('reads the family name, preferring the typographic one', () {
    expect(_families(_sfnt({1: 'Segoe UI Semibold', 16: 'Segoe UI'})), {
      'Segoe UI',
    });
    expect(_families(_sfnt({1: 'Avenir'}, platform: 1)), {'Avenir'});
  });

  test('reads every font of a .ttc collection', () {
    final first = _sfnt({1: 'Cambria'}, base: 20);
    final second = _sfnt({1: 'Cambria Math'}, base: 20 + first.length);
    final collection = Uint8List.fromList([
      ..._u32(0x74746366),
      ..._u32(0x00010000),
      ..._u32(2),
      ..._u32(20),
      ..._u32(20 + first.length),
      ...first,
      ...second,
    ]);

    expect(_families(collection), {'Cambria', 'Cambria Math'});
  });
}
