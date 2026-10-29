import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:voges_updater/core.dart';

// Compares the catalog with Voges Word's own build files, so it goes away
// when the package moves to a repository of its own.
String _read(String path) => File(
  p.joinAll([Directory.current.path, '..', '..', ...p.posix.split(path)]),
).readAsStringSync();

String? _first(String pattern, String text) =>
    RegExp(pattern, multiLine: true).firstMatch(text)?[1];

void main() {
  final installers = {
    vogesWord.macos.asset,
    vogesWord.windows.asset,
    vogesWord.linux.asset,
  };

  test('the release workflow checksums exactly the catalog assets', () {
    final workflow = _read('.github/workflows/release.yml');
    final command = RegExp(r'sha256sum\s([^>]*)>\s*(\S+)').firstMatch(workflow);
    expect(command, isNotNull);
    final listed = command![1]!
        .split(RegExp(r'[\s\\]+'))
        .where((name) => name.isNotEmpty);
    expect(listed.toSet(), installers);
    expect(listed, hasLength(installers.length));
    expect(command[2], checksumsAsset);

    final uploaded = RegExp(
      r'^\s*path:\s*(\S+)\s*$',
      multiLine: true,
    ).allMatches(workflow).map((match) => p.posix.basename(match[1]!));
    expect(uploaded, containsAll(installers));
  });

  test('the Windows installer has the catalog AppId and executable', () {
    final setup = _read('packaging/windows/voges_word.iss');
    // Inno Setup writes the opening brace of the AppId as {{
    expect(
      _first(r'^AppId=\{(\{[0-9A-F-]+\})\r?$', setup),
      vogesWord.windows.appId,
    );
    expect(
      _first(r'^#define AppExe "([^"]+)"', setup),
      vogesWord.windows.executable,
    );
    expect(
      '${_first(r'^OutputBaseFilename=(\S+?)\r?$', setup)}.exe',
      vogesWord.windows.asset,
    );
    expect(
      '${_first(r'^set\(BINARY_NAME "([^"]+)"\)', _read('windows/CMakeLists.txt'))}.exe',
      vogesWord.windows.executable,
    );
  });

  test('the Debian package has the catalog package, binary and launcher', () {
    final script = _read('packaging/linux/build_deb.sh');
    expect(_first(r'^Package: (\S+)$', script), vogesWord.linux.package);
    expect(_first(r'^Architecture: (\S+)$', script), 'amd64');
    expect(vogesWord.linux.asset, endsWith('-amd64.deb'));

    final link = RegExp(r'ln -s (\S+) "\$root(/\S+)"').firstMatch(script);
    expect(link, isNotNull);
    expect(link![2], vogesWord.linux.launcher);
    expect(
      p.posix.normalize(p.posix.join(p.posix.dirname(link[2]!), link[1]!)),
      vogesWord.linux.binary,
    );
    expect(
      script,
      contains(
        'cp -r "\$bundle/." "\$root${p.posix.dirname(vogesWord.linux.binary)}/"',
      ),
    );
    expect(
      _first(r'^set\(BINARY_NAME "([^"]+)"\)', _read('linux/CMakeLists.txt')),
      p.posix.basename(vogesWord.linux.binary),
    );
  });

  test('the macOS app has the catalog bundle id and name', () {
    final info = _read('macos/Runner/Configs/AppInfo.xcconfig');
    expect(
      _first(r'^PRODUCT_BUNDLE_IDENTIFIER = (\S+)$', info),
      vogesWord.macos.bundleId,
    );
    expect(
      '${_first(r'^PRODUCT_NAME = (.+)$', info)}.app',
      vogesWord.macos.bundleName,
    );
  });

  test('every app can be named in the checksums and requested', () {
    final names = <String>{checksumsAsset, signatureAsset};
    for (final app in vogesSuite) {
      expect(
        app.repository,
        matches(RegExp(r'^[A-Za-z0-9-]+/[A-Za-z0-9_][A-Za-z0-9._-]*$')),
      );
      expect(Uri.parse(app.downloadPage).scheme, 'https');
      for (final asset in [
        app.macos.asset,
        app.windows.asset,
        app.linux.asset,
      ]) {
        expect(asset, matches(RegExp(r'^[A-Za-z0-9._-]+$')));
        expect(names.add(asset), isTrue, reason: '$asset appears twice');
      }
    }
  });
}
