import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voges_updater/core.dart';

import '../tool/release_signing.dart';
import 'support/core_support.dart';

const _version = ReleaseVersion(1, 2, 0);
final _app = vogesWord;
final _asset = _app.macos.asset;
final _seed = List.filled(32, 3);
final _installer = Uint8List.fromList(List.generate(200000, (i) => i % 253));

Matcher _fails(UpdateFailureKind kind) =>
    throwsA(isA<UpdateFailure>().having((f) => f.kind, 'kind', kind));

void main() {
  late LoopbackServer server;
  late Directory into;
  late String key;

  setUpAll(() async => key = await publicKeyOf(_seed));

  setUp(() async {
    server = await LoopbackServer.start();
    into = temporaryFolder();
  });

  String address(String name) =>
      '127.0.0.1/${_app.repository}/releases/download/v1.2.0/$name';

  /// Serves a release whose checksums list [listed] and are signed with
  /// [seed]; [files] replaces what is served.
  Future<void> serve({
    Map<String, List<int>>? listed,
    List<int>? seed,
    Map<String, Answer?> files = const {},
  }) async {
    final sums = utf8.encode(
      [
        for (final MapEntry(key: name, value: bytes)
            in (listed ?? {_asset: _installer}).entries)
          '${sha256.convert(bytes)}  $name\n',
      ].join(),
    );
    final routes = <String, Answer?>{
      address(_asset): bytes(_installer),
      address(checksumsAsset): bytes(sums),
      address(signatureAsset): bytes(
        await signChecksums(
          seed: seed ?? _seed,
          repository: _app.repository,
          version: _version,
          checksums: sums,
        ),
      ),
      ...files,
    };
    server.routes = {
      for (final MapEntry(key: path, value: answer) in routes.entries)
        path: ?answer,
    };
  }

  ReleaseDownloader downloader() {
    final releases = GitHubReleases(
      origin: server.origin,
      redirectHosts: const {'127.0.0.1'},
    );
    addTearDown(releases.close);
    return ReleaseDownloader(
      releases: releases,
      verifier: ReleaseVerifier(trustedKeys: [key]),
    );
  }

  Future<VerifiedAsset> fetch({
    void Function(double progress)? onProgress,
    bool Function()? isCancelled,
  }) => downloader().fetch(
    _app,
    _version,
    _asset,
    into,
    onProgress: onProgress,
    isCancelled: isCancelled,
  );

  test('downloads and verifies the installer', () async {
    await serve();
    final progress = <double>[];
    final asset = await fetch(onProgress: progress.add);
    expect(asset.file.parent.path, into.path);
    expect(asset.file.readAsBytesSync(), _installer);
    expect(asset.sha256, sha256.convert(_installer).toString());
    await asset.recheck();
    expect(progress.first, 0);
    expect(progress.last, 1);
    for (var i = 1; i < progress.length; i++) {
      expect(progress[i], greaterThanOrEqualTo(progress[i - 1]));
    }
    expect(server.requests, [
      'GET ${address(checksumsAsset)}',
      'GET ${address(signatureAsset)}',
      'GET ${address(_asset)}',
    ]);
  });

  test('deletes an installer that does not match the checksums', () async {
    final altered = Uint8List.fromList(_installer)..[100] ^= 0x01;
    await serve(files: {address(_asset): bytes(altered)});
    await expectLater(fetch(), _fails(UpdateFailureKind.verification));
    expect(into.listSync(), isEmpty);
  });

  test(
    'never downloads the installer of a release signed by another key',
    () async {
      await serve(seed: List.filled(32, 4));
      await expectLater(fetch(), _fails(UpdateFailureKind.verification));
      expect(server.requests, isNot(contains('GET ${address(_asset)}')));
    },
  );

  test(
    'treats a release without signature or checksums as unverified',
    () async {
      for (final missing in [signatureAsset, checksumsAsset]) {
        await serve(files: {address(missing): null});
        await expectLater(fetch(), _fails(UpdateFailureKind.verification));
      }
      expect(into.listSync(), isEmpty);
    },
  );

  test('reports a release without this installer as unavailable', () async {
    await serve(listed: {_app.linux.asset: _installer});
    await expectLater(fetch(), _fails(UpdateFailureKind.unavailable));
    expect(server.requests, isNot(contains('GET ${address(_asset)}')));
  });

  test('reports a listed installer that is missing as unavailable', () async {
    await serve(files: {address(_asset): null});
    await expectLater(fetch(), _fails(UpdateFailureKind.unavailable));
    expect(into.listSync(), isEmpty);
  });

  test('refuses checksums and signatures over their size limits', () async {
    await serve(
      files: {
        address(signatureAsset): bytes(
          List.filled(ReleaseDownloader.signatureLimit + 1, 0x41),
        ),
      },
    );
    await expectLater(fetch(), _fails(UpdateFailureKind.network));
    await serve(
      files: {
        address(checksumsAsset): bytes(
          List.filled(ReleaseDownloader.checksumsLimit + 1, 0x0a),
        ),
      },
    );
    await expectLater(fetch(), _fails(UpdateFailureKind.network));
  });

  test('leaves nothing behind when cancelled', () async {
    await serve();
    await expectLater(
      fetch(isCancelled: () => true),
      _fails(UpdateFailureKind.network),
    );
    expect(into.listSync(), isEmpty);
    expect(server.requests, isNot(contains('GET ${address(_asset)}')));
  });

  test('the recheck catches an installer changed on disk', () async {
    await serve();
    final asset = await fetch();
    asset.file.writeAsBytesSync([1, 2, 3], mode: FileMode.append);
    await expectLater(asset.recheck(), _fails(UpdateFailureKind.verification));
    asset.file.deleteSync();
    await expectLater(asset.recheck(), _fails(UpdateFailureKind.verification));
  });
}
