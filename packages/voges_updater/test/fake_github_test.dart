import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:voges_updater/core.dart';

import '../tool/fake_github.dart';
import '../tool/release_signing.dart';
import 'support/core_support.dart';

const _version = ReleaseVersion(9, 9, 9);
final _app = vogesWord;
final _asset = _app.macos.asset;
final _seed = List.filled(32, 5);
final _installer = Uint8List.fromList(List.generate(150000, (i) => i % 241));

Matcher _fails(UpdateFailureKind kind) =>
    throwsA(isA<UpdateFailure>().having((f) => f.kind, 'kind', kind));

void main() {
  late Directory folder;
  late File installer;
  late String key;

  setUpAll(() async => key = await publicKeyOf(_seed));

  setUp(() {
    folder = temporaryFolder();
    installer = File(p.join(folder.path, 'build', _asset))
      ..createSync(recursive: true)
      ..writeAsBytesSync(_installer);
  });

  GitHubReleases releasesAt(Uri origin) {
    final releases = GitHubReleases(
      origin: origin,
      redirectHosts: const {'127.0.0.1'},
    );
    addTearDown(releases.close);
    return releases;
  }

  Future<VerifiedAsset> fetchFrom(Uri origin) {
    final into = Directory(p.join(folder.path, 'downloads'))..createSync();
    return ReleaseDownloader(
      releases: releasesAt(origin),
      verifier: ReleaseVerifier(trustedKeys: [key]),
    ).fetch(_app, _version, _asset, into);
  }

  Future<FakeGitHub> start({bool tamper = false, bool unsigned = false}) async {
    final fake = await FakeGitHub.start(
      repository: _app.repository,
      version: _version,
      assets: {_asset: installer},
      seed: _seed,
      tamper: tamper,
      unsigned: unsigned,
    );
    addTearDown(fake.close);
    return fake;
  }

  test('a signed release goes through the downloader intact', () async {
    final fake = await start();
    expect(parseTestOrigin('${fake.origin}'), fake.origin);
    expect(await releasesAt(fake.origin).latest(_app.repository), _version);
    final asset = await fetchFrom(fake.origin);
    expect(asset.file.readAsBytesSync(), _installer);
    await asset.recheck();
  });

  test('a tampered release is rejected and its download deleted', () async {
    final fake = await start(tamper: true);
    await expectLater(
      fetchFrom(fake.origin),
      _fails(UpdateFailureKind.verification),
    );
    expect(Directory(p.join(folder.path, 'downloads')).listSync(), isEmpty);
  });

  test('an unsigned release is rejected', () async {
    final fake = await start(unsigned: true);
    await expectLater(
      fetchFrom(fake.origin),
      _fails(UpdateFailureKind.verification),
    );
  });

  group('command line', () {
    Future<ProcessResult> run(List<String> arguments) => Process.run(
      dartExecutable(),
      ['run', 'tool/fake_github.dart', ...arguments],
    );

    test(
      'init-key writes a private key once and prints its public key',
      () async {
        final keyFile = File(p.join(folder.path, 'test.seed'));
        final result = await run(['init-key', '--key-file', keyFile.path]);
        expect(result.exitCode, 0, reason: '${result.stderr}');
        final seed = keyFile.readAsBytesSync();
        expect(seed, hasLength(32));
        expect('${result.stdout}'.trim(), await publicKeyOf(seed));
        if (!Platform.isWindows) {
          expect(keyFile.statSync().mode & 0x1ff, 0x180);
        }

        final again = await run(['init-key', '--key-file', keyFile.path]);
        expect(again.exitCode, isNot(0));
        expect(keyFile.readAsBytesSync(), seed);
      },
      timeout: const Timeout(Duration(minutes: 2)),
    );

    test(
      'serve answers like GitHub until it is stopped',
      () async {
        final keyFile = File(p.join(folder.path, 'test.seed'))
          ..writeAsBytesSync(_seed);
        final process = await Process.start(dartExecutable(), [
          'run',
          'tool/fake_github.dart',
          'serve',
          '--port',
          '0',
          '--repository',
          _app.repository,
          '--tag',
          _version.tag,
          '--key-file',
          keyFile.path,
          installer.path,
        ]);
        addTearDown(process.kill);
        final errors = process.stderr.transform(utf8.decoder).join();
        final line = await process.stdout
            .transform(utf8.decoder)
            .transform(const LineSplitter())
            .first;
        final origin = Uri.parse(
          RegExp(r'http://127\.0\.0\.1:\d+').firstMatch(line)![0]!,
        );

        expect(await releasesAt(origin).latest(_app.repository), _version);
        expect((await fetchFrom(origin)).file.readAsBytesSync(), _installer);

        if (!Platform.isWindows) {
          process.kill(ProcessSignal.sigint);
          expect(await process.exitCode, 0, reason: await errors);
        }
      },
      timeout: const Timeout(Duration(minutes: 2)),
    );

    test(
      'refuses arguments it does not know',
      () async {
        for (final arguments in [
          const <String>[],
          ['serve', '--port', 'x'],
          ['serve', '--tamper'],
          ['init-key'],
        ]) {
          expect((await run(arguments)).exitCode, 64, reason: '$arguments');
        }
      },
      timeout: const Timeout(Duration(minutes: 2)),
    );
  });
}
