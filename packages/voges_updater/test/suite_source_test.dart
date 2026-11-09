import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:voges_updater/core.dart';

import '../tool/release_signing.dart';
import 'support/core_support.dart';

final _seed = List.filled(32, 7);
final _otherSeed = List.filled(32, 9);

final _slides = SuiteApp.conventional(
  name: 'Voges Slides',
  windowsAppId: '{00000000-0000-0000-0000-0000000000A1}',
);
final _flash = SuiteApp.conventional(
  name: 'Voges Flash',
  windowsAppId: '{00000000-0000-0000-0000-0000000000A2}',
);

typedef _Signed = ({Uint8List list, Uint8List signature});

Future<_Signed> _sign(
  int serial,
  List<SuiteApp> apps, {
  List<int>? seed,
}) async {
  final list = SuiteList.encode(serial: serial, apps: apps);
  return (
    list: list,
    signature: await signSuiteList(seed: seed ?? _seed, list: list),
  );
}

List<String> _names(List<SuiteApp> apps) => [for (final app in apps) app.name];

final _builtIn = _names(vogesSuite);

void main() {
  late LoopbackServer server;
  late Directory cache;
  late String key;

  setUpAll(() async => key = await publicKeyOf(_seed));

  setUp(() async {
    server = await LoopbackServer.start();
    cache = Directory(p.join(temporaryFolder().path, 'Voges'));
  });

  String route([String suffix = '']) => '127.0.0.1/voges/suite.json$suffix';

  void publish(_Signed signed) => server.routes = {
    route(): bytes(signed.list),
    route('.sig'): bytes(signed.signature),
  };

  File kept(String name) => File(p.join(cache.path, name));

  void keep(_Signed signed) {
    cache.createSync(recursive: true);
    kept('suite.json').writeAsBytesSync(signed.list);
    kept('suite.json.sig').writeAsBytesSync(signed.signature);
  }

  PublishedSuite suite({Duration timeout = const Duration(seconds: 8)}) =>
      PublishedSuite(
        verifier: ReleaseVerifier(trustedKeys: [key]),
        cache: () => cache,
        url: server.origin.resolve('/voges/suite.json'),
        timeout: timeout,
      );

  Future<List<String>> names() async => _names(await suite().apps());

  group('a published list', () {
    test('adds its new apps after those of the build', () async {
      publish(await _sign(2, [...vogesSuite, _slides]));
      final apps = await suite().apps();
      expect(apps.take(vogesSuite.length), vogesSuite);
      expect(_names(apps.skip(vogesSuite.length).toList()), ['Voges Slides']);
      expect(server.requests, ['GET ${route()}', 'GET ${route('.sig')}']);
      expect(server.userAgents, {'Voges-Updater'});
    });

    test('is kept, byte for byte, as the newest list seen', () async {
      final signed = await _sign(2, [...vogesSuite, _slides]);
      publish(signed);
      await suite().apps();
      expect(kept('suite.json').readAsBytesSync(), signed.list);
      expect(kept('suite.json.sig').readAsBytesSync(), signed.signature);
      expect(cache.listSync(), hasLength(2));
    });

    test('is ignored when signed by another key', () async {
      publish(await _sign(2, [...vogesSuite, _slides], seed: _otherSeed));
      expect(await names(), _builtIn);
      expect(cache.existsSync(), isFalse);
    });

    test('is ignored when its bytes are not the signed ones', () async {
      final signed = await _sign(2, [...vogesSuite, _slides]);
      final other = await _sign(2, [...vogesSuite, _flash]);
      publish((list: other.list, signature: signed.signature));
      expect(await names(), _builtIn);
      expect(cache.existsSync(), isFalse);
    });

    test('is ignored without its signature', () async {
      final signed = await _sign(2, [...vogesSuite, _slides]);
      server.routes = {route(): bytes(signed.list)};
      expect(await names(), _builtIn);
      expect(cache.existsSync(), isFalse);
    });

    test('is ignored when it changes an app of the build', () async {
      final moved = SuiteApp.conventional(
        name: vogesWord.name,
        windowsAppId: _slides.windows.appId,
      );
      publish(await _sign(2, [moved, _slides]));
      expect(await names(), _builtIn);
      expect(cache.existsSync(), isFalse);
    });

    test('never asks for the signature of a list that is not there', () async {
      expect(await names(), _builtIn);
      expect(server.requests, ['GET ${route()}']);
    });

    test('is never followed through a redirect', () async {
      final signed = await _sign(2, [...vogesSuite, _slides]);
      server.routes = {
        route(): redirectTo('/elsewhere/suite.json'),
        route('.sig'): bytes(signed.signature),
        '127.0.0.1/elsewhere/suite.json': bytes(signed.list),
      };
      expect(await names(), _builtIn);
      expect(server.requests, ['GET ${route()}']);
    });

    for (final code in [
      HttpStatus.partialContent,
      HttpStatus.notModified,
      HttpStatus.forbidden,
      HttpStatus.internalServerError,
    ]) {
      test('is ignored with the status $code', () async {
        final signed = await _sign(2, [...vogesSuite, _slides]);
        server.routes = {
          route(): (response) {
            response.statusCode = code;
            if (code != HttpStatus.notModified) response.add(signed.list);
          },
          route('.sig'): bytes(signed.signature),
        };
        expect(await names(), _builtIn);
      });
    }

    test('is ignored when larger than a suite list can be', () async {
      final signed = await _sign(2, [...vogesSuite, _slides]);
      final padded = Uint8List(PublishedSuite.listLimit + 1)
        ..fillRange(0, PublishedSuite.listLimit + 1, 0x20)
        ..setAll(0, signed.list);
      for (final chunked in [false, true]) {
        server.routes = {
          route(): bytes(padded, chunked: chunked),
          route('.sig'): bytes(signed.signature),
        };
        expect(await names(), _builtIn, reason: 'chunked: $chunked');
      }
      expect(server.requests, ['GET ${route()}', 'GET ${route()}']);
    });

    test('is ignored when its signature is larger than one can be', () async {
      final signed = await _sign(2, [...vogesSuite, _slides]);
      server.routes = {
        route(): bytes(signed.list),
        route('.sig'): bytes(Uint8List(PublishedSuite.signatureLimit + 1)),
      };
      expect(await names(), _builtIn);
    });

    test('does not hold the updates back when the website stalls', () async {
      final signed = await _sign(2, [...vogesSuite, _slides]);
      server.routes = {
        route(): stall(
          signed.list.sublist(0, 10),
          contentLength: signed.list.length,
        ),
      };
      final watch = Stopwatch()..start();
      final apps = await suite(
        timeout: const Duration(milliseconds: 300),
      ).apps();
      expect(_names(apps), _builtIn);
      expect(watch.elapsed, lessThan(const Duration(seconds: 5)));
    });

    test('is ignored when nothing answers', () async {
      final source = PublishedSuite(
        verifier: ReleaseVerifier(trustedKeys: [key]),
        cache: () => cache,
        url: Uri.parse('http://127.0.0.1:1/voges/suite.json'),
      );
      expect(_names(await source.apps()), _builtIn);
      expect(server.requests, isEmpty);
    });
  });

  group('the newest list seen', () {
    test('wins over an older list that the website sends again', () async {
      final newest = await _sign(5, [...vogesSuite, _slides, _flash]);
      keep(newest);
      publish(await _sign(3, [...vogesSuite, _slides]));
      expect(await names(), [..._builtIn, 'Voges Slides', 'Voges Flash']);
      expect(kept('suite.json').readAsBytesSync(), newest.list);
      expect(kept('suite.json.sig').readAsBytesSync(), newest.signature);
    });

    test('gives way to a newer one, which replaces it', () async {
      keep(await _sign(5, [...vogesSuite, _slides]));
      final newer = await _sign(6, [...vogesSuite, _slides, _flash]);
      publish(newer);
      expect(await names(), [..._builtIn, 'Voges Slides', 'Voges Flash']);
      expect(kept('suite.json').readAsBytesSync(), newer.list);
      expect(kept('suite.json.sig').readAsBytesSync(), newer.signature);
      expect(cache.listSync(), hasLength(2));
    });

    test('is not written again for the same serial', () async {
      final seen = await _sign(5, [...vogesSuite, _slides]);
      keep(seen);
      publish(await _sign(5, [...vogesSuite, _flash]));
      expect(await names(), [..._builtIn, 'Voges Flash']);
      expect(kept('suite.json').readAsBytesSync(), seen.list);
    });

    test('is used when the website does not answer', () async {
      keep(await _sign(5, [...vogesSuite, _slides]));
      expect(await names(), [..._builtIn, 'Voges Slides']);
    });

    test('is used when the website sends a list that does not pass', () async {
      keep(await _sign(5, [...vogesSuite, _slides]));
      publish(await _sign(9, [...vogesSuite, _flash], seed: _otherSeed));
      expect(await names(), [..._builtIn, 'Voges Slides']);
    });

    test('counts for nothing when it was changed on disk', () async {
      final seen = await _sign(5, [...vogesSuite, _slides]);
      final forged = await _sign(99, [...vogesSuite, _flash], seed: _otherSeed);
      keep((list: forged.list, signature: seen.signature));
      expect(await names(), _builtIn);

      final published = await _sign(2, [...vogesSuite, _slides]);
      publish(published);
      expect(await names(), [..._builtIn, 'Voges Slides']);
      expect(kept('suite.json').readAsBytesSync(), published.list);
    });

    test('counts for nothing when a file is larger than it can be', () async {
      final seen = await _sign(5, [...vogesSuite, _slides]);
      keep(seen);
      kept(
        'suite.json.sig',
      ).writeAsBytesSync(Uint8List(PublishedSuite.signatureLimit + 1));
      expect(await names(), _builtIn);
    });

    test('counts for nothing with only one of its two files', () async {
      keep(await _sign(5, [...vogesSuite, _slides]));
      kept('suite.json.sig').deleteSync();
      expect(await names(), _builtIn);
    });
  });

  test('without a cache folder the suite is the one of the build, and the '
      'website is not asked', () async {
    publish(await _sign(2, [...vogesSuite, _slides]));
    final source = PublishedSuite(
      verifier: ReleaseVerifier(trustedKeys: [key]),
      cache: () => throw StateError('no home'),
      url: server.origin.resolve('/voges/suite.json'),
    );
    expect(await source.apps(), same(vogesSuite));
    expect(server.requests, isEmpty);
  });

  test('a list that cannot be kept is still used', () async {
    final blocker = File(p.join(temporaryFolder().path, 'Voges'))
      ..writeAsStringSync('not a folder');
    publish(await _sign(2, [...vogesSuite, _slides]));
    final source = PublishedSuite(
      verifier: ReleaseVerifier(trustedKeys: [key]),
      cache: () => Directory(blocker.path),
      url: server.origin.resolve('/voges/suite.json'),
    );
    expect(_names(await source.apps()), [..._builtIn, 'Voges Slides']);
  });

  test('production reads the list of the website', () {
    final source = PublishedSuite.production(verifier: ReleaseVerifier());
    expect(PublishedSuite.address, 'https://omanoloneto.pro/voges/suite.json');
    expect(source.url, Uri.parse(PublishedSuite.address));
    expect(source.builtIn, same(vogesSuite));
  });

  test('a fixed suite is the one of the build unless told otherwise', () async {
    expect(await const FixedSuite().apps(), same(vogesSuite));
    expect(await FixedSuite([vogesWord, _slides]).apps(), [vogesWord, _slides]);
  });
}
