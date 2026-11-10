import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:voges_updater/core.dart';

import '../tool/release_signing.dart';
import 'support/core_support.dart';

final _seed = List.filled(32, 7);
final _otherSeed = List.filled(32, 9);

final _notes = SuiteApp.conventional(
  name: 'Voges Notes',
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

  File kept() => File(p.join(cache.path, 'suite.signed'));

  /// The one file a list is kept in: its signature line, then its bytes.
  List<int> together(_Signed signed) => [...signed.signature, ...signed.list];

  void keep(_Signed signed) {
    cache.createSync(recursive: true);
    kept().writeAsBytesSync(together(signed));
  }

  PublishedSuite suite({
    Duration timeout = const Duration(seconds: 8),
    Duration diskTimeout = const Duration(seconds: 2),
  }) => PublishedSuite(
    verifier: ReleaseVerifier(trustedKeys: [key]),
    cache: () => cache,
    url: server.origin.resolve('/voges/suite.json'),
    timeout: timeout,
    diskTimeout: diskTimeout,
  );

  Future<List<String>> names() async => _names(await suite().apps());

  group('a published list', () {
    test('adds its new apps after those of the build', () async {
      publish(await _sign(2, [...vogesSuite, _notes]));
      final apps = await suite().apps();
      expect(apps.take(vogesSuite.length), vogesSuite);
      expect(_names(apps.skip(vogesSuite.length).toList()), ['Voges Notes']);
      expect(server.requests, ['GET ${route()}', 'GET ${route('.sig')}']);
      expect(server.userAgents, {'Voges-Updater'});
    });

    test('is kept, byte for byte, as the newest list seen', () async {
      final signed = await _sign(2, [...vogesSuite, _notes]);
      publish(signed);
      await suite().apps();
      expect(kept().readAsBytesSync(), together(signed));
      expect(cache.listSync(), hasLength(1));
    });

    test('is kept the same when its signature has no line break', () async {
      final signed = await _sign(2, [...vogesSuite, _notes]);
      publish((
        list: signed.list,
        signature: signed.signature.sublist(0, signed.signature.length - 1),
      ));
      expect(await names(), [..._builtIn, 'Voges Notes']);
      expect(kept().readAsBytesSync(), together(signed));
      expect(await names(), [..._builtIn, 'Voges Notes']);
    });

    test('is ignored when signed by another key', () async {
      publish(await _sign(2, [...vogesSuite, _notes], seed: _otherSeed));
      expect(await names(), _builtIn);
      expect(cache.existsSync(), isFalse);
    });

    test('is ignored when its bytes are not the signed ones', () async {
      final signed = await _sign(2, [...vogesSuite, _notes]);
      final other = await _sign(2, [...vogesSuite, _flash]);
      publish((list: other.list, signature: signed.signature));
      expect(await names(), _builtIn);
      expect(cache.existsSync(), isFalse);
    });

    test('is ignored without its signature', () async {
      final signed = await _sign(2, [...vogesSuite, _notes]);
      server.routes = {route(): bytes(signed.list)};
      expect(await names(), _builtIn);
      expect(cache.existsSync(), isFalse);
    });

    test('is ignored when it changes an app of the build', () async {
      final moved = SuiteApp.conventional(
        name: vogesWord.name,
        windowsAppId: _notes.windows.appId,
      );
      publish(await _sign(2, [moved, _notes]));
      expect(await names(), _builtIn);
      expect(cache.existsSync(), isFalse);
    });

    test('never asks for the signature of a list that is not there', () async {
      expect(await names(), _builtIn);
      expect(server.requests, ['GET ${route()}']);
    });

    test('is never followed through a redirect', () async {
      final signed = await _sign(2, [...vogesSuite, _notes]);
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
        final signed = await _sign(2, [...vogesSuite, _notes]);
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
      final signed = await _sign(2, [...vogesSuite, _notes]);
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
      final signed = await _sign(2, [...vogesSuite, _notes]);
      server.routes = {
        route(): bytes(signed.list),
        route('.sig'): bytes(Uint8List(PublishedSuite.signatureLimit + 1)),
      };
      expect(await names(), _builtIn);
    });

    test('does not hold the updates back when the website stalls', () async {
      final signed = await _sign(2, [...vogesSuite, _notes]);
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
      final newest = await _sign(5, [...vogesSuite, _notes, _flash]);
      keep(newest);
      publish(await _sign(3, [...vogesSuite, _notes]));
      expect(await names(), [..._builtIn, 'Voges Notes', 'Voges Flash']);
      expect(kept().readAsBytesSync(), together(newest));
    });

    test('gives way to a newer one, which replaces it', () async {
      keep(await _sign(5, [...vogesSuite, _notes]));
      final newer = await _sign(6, [...vogesSuite, _notes, _flash]);
      publish(newer);
      expect(await names(), [..._builtIn, 'Voges Notes', 'Voges Flash']);
      expect(kept().readAsBytesSync(), together(newer));
      expect(cache.listSync(), hasLength(1));
    });

    test('wins over another list signed with the same serial', () async {
      final seen = await _sign(5, [...vogesSuite, _notes]);
      keep(seen);
      publish(await _sign(5, [...vogesSuite, _flash]));
      expect(await names(), [..._builtIn, 'Voges Notes']);
      expect(kept().readAsBytesSync(), together(seen));
    });

    test('is used when the website does not answer', () async {
      keep(await _sign(5, [...vogesSuite, _notes]));
      expect(await names(), [..._builtIn, 'Voges Notes']);
    });

    test('is used when the website sends a list that does not pass', () async {
      keep(await _sign(5, [...vogesSuite, _notes]));
      publish(await _sign(9, [...vogesSuite, _flash], seed: _otherSeed));
      expect(await names(), [..._builtIn, 'Voges Notes']);
    });

    test('counts for nothing when it was changed on disk', () async {
      final seen = await _sign(5, [...vogesSuite, _notes]);
      final forged = await _sign(99, [...vogesSuite, _flash], seed: _otherSeed);
      keep((list: forged.list, signature: seen.signature));
      expect(await names(), _builtIn);

      final published = await _sign(2, [...vogesSuite, _notes]);
      publish(published);
      expect(await names(), [..._builtIn, 'Voges Notes']);
      expect(kept().readAsBytesSync(), together(published));
    });

    test('counts for nothing when larger than it can be', () async {
      final seen = await _sign(5, [...vogesSuite, _notes]);
      cache.createSync(recursive: true);
      kept().writeAsBytesSync([
        ...together(seen),
        ...Uint8List(PublishedSuite.signatureLimit + PublishedSuite.listLimit),
      ]);
      expect(await names(), _builtIn);
    });

    test('counts for nothing without its signature line', () async {
      final seen = await _sign(5, [...vogesSuite, _notes]);
      cache.createSync(recursive: true);
      kept().writeAsBytesSync(seen.list);
      expect(await names(), _builtIn);
      kept().writeAsBytesSync(seen.signature);
      expect(await names(), _builtIn);
    });

    test(
      'counts for nothing when it never answers, and is replaced',
      () async {
        cache.createSync(recursive: true);
        expect((await Process.run('mkfifo', [kept().path])).exitCode, 0);
        // a writer that says nothing, so reading it never ends
        final writer = kept().open(mode: FileMode.writeOnly);
        addTearDown(() async => (await writer).close());
        final published = await _sign(2, [...vogesSuite, _notes]);
        publish(published);

        final apps = await suite(
          diskTimeout: const Duration(milliseconds: 300),
        ).apps();
        expect(_names(apps), [..._builtIn, 'Voges Notes']);
        expect(kept().statSync().type, FileSystemEntityType.file);
        expect(kept().readAsBytesSync(), together(published));
      },
      skip: Platform.isWindows ? 'no named pipes in a folder' : null,
    );
  });

  test('without a cache folder the suite is the one of the build, and the '
      'website is not asked', () async {
    publish(await _sign(2, [...vogesSuite, _notes]));
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
    publish(await _sign(2, [...vogesSuite, _notes]));
    final source = PublishedSuite(
      verifier: ReleaseVerifier(trustedKeys: [key]),
      cache: () => Directory(blocker.path),
      url: server.origin.resolve('/voges/suite.json'),
    );
    expect(_names(await source.apps()), [..._builtIn, 'Voges Notes']);
  });

  test('production reads the list of the website', () {
    final source = PublishedSuite.production(verifier: ReleaseVerifier());
    expect(PublishedSuite.address, 'https://omanoloneto.pro/voges/suite.json');
    expect(source.url, Uri.parse(PublishedSuite.address));
    expect(source.builtIn, same(vogesSuite));
  });

  test('a fixed suite is the one of the build unless told otherwise', () async {
    expect(await const FixedSuite().apps(), same(vogesSuite));
    expect(await FixedSuite([vogesWord, _notes]).apps(), [vogesWord, _notes]);
  });
}
