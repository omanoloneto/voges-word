import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:voges_updater/core.dart';

import 'support/core_support.dart';

const _repository = 'owner/repo';
const _version = ReleaseVersion(1, 2, 3);
const _latest = 'github.com/$_repository/releases/latest';
const _tagPage = 'https://github.com/$_repository/releases/tag';

final _asset = vogesWord.macos.asset;
final _download = 'github.com/$_repository/releases/download/v1.2.3/$_asset';
const _cdn = 'release-assets.githubusercontent.com';

Matcher _fails(UpdateFailureKind kind) =>
    throwsA(isA<UpdateFailure>().having((f) => f.kind, 'kind', kind));

void main() {
  late LoopbackServer server;

  setUp(() async => server = await LoopbackServer.start());

  /// The production origin and redirect rules, with every connection sent
  /// to [server].
  GitHubReleases production({Duration? idleTimeout}) {
    final releases = GitHubReleases(
      client: server.routedClient(),
      idleTimeout: idleTimeout ?? const Duration(seconds: 30),
    );
    addTearDown(releases.close);
    return releases;
  }

  GitHubReleases loopback() {
    final releases = GitHubReleases(
      origin: server.origin,
      redirectHosts: const {'127.0.0.1'},
    );
    addTearDown(releases.close);
    return releases;
  }

  group('latest', () {
    Future<ReleaseVersion> latestAnswering(Answer answer) {
      server.routes = {_latest: answer};
      return production().latest(_repository);
    }

    test('reads the tag from the exact redirect, with HEAD', () async {
      expect(await latestAnswering(redirectTo('$_tagPage/v1.2.3')), _version);
      expect(server.requests, ['HEAD $_latest']);
      expect(server.userAgents, {'Voges-Updater'});
    });

    test('works with the loopback origin of a test build', () async {
      server.routes = {
        '127.0.0.1/$_repository/releases/latest': redirectTo(
          '${server.origin}/$_repository/releases/tag/v2.0.0',
        ),
      };
      expect(
        await loopback().latest(_repository),
        const ReleaseVersion(2, 0, 0),
      );
    });

    final refused = {
      'another repository': redirectTo(
        'https://github.com/owner/other/releases/tag/v1.2.3',
      ),
      'another host': redirectTo(
        'https://example.com/$_repository/releases/tag/v1.2.3',
      ),
      'http': redirectTo('http://github.com/$_repository/releases/tag/v1.2.3'),
      'another port': redirectTo(
        'https://github.com:8443/$_repository/releases/tag/v1.2.3',
      ),
      'the releases page': redirectTo(
        'https://github.com/$_repository/releases',
      ),
      'a pre-release tag': redirectTo('$_tagPage/v1.2.3-beta'),
      'a tag without v': redirectTo('$_tagPage/1.2.3'),
      'a padded version': redirectTo('$_tagPage/v01.2.3'),
      'a trailing slash': redirectTo('$_tagPage/v1.2.3/'),
      'a query': redirectTo('$_tagPage/v1.2.3?after=1'),
      'a relative location': redirectTo('/$_repository/releases/tag/v1.2.3'),
      'a redirect without location': status(HttpStatus.found),
      'status 200': bytes('v1.2.3'.codeUnits),
      'status 404': status(HttpStatus.notFound),
    };
    for (final MapEntry(key: name, value: answer) in refused.entries) {
      test('fails closed on $name', () async {
        await expectLater(
          latestAnswering(answer),
          _fails(UpdateFailureKind.network),
        );
      });
    }

    test('fails as network when nothing answers', () async {
      final releases = GitHubReleases(
        origin: Uri.parse('http://127.0.0.1:1'),
        redirectHosts: const {'127.0.0.1'},
      );
      addTearDown(releases.close);
      await expectLater(
        releases.latest(_repository),
        _fails(UpdateFailureKind.network),
      );
    });
  });

  group('redirects', () {
    Future<List<int>> fetchVia(Map<String, Answer> routes) {
      server.routes = routes;
      return production().fetch(_repository, _version, _asset, maxBytes: 1024);
    }

    test('follows GitHub to its file hosts', () async {
      for (final host in [_cdn, 'objects.githubusercontent.com']) {
        expect(
          await fetchVia({
            _download: redirectTo('https://$host/file?token=1'),
            '$host/file': bytes([1, 2, 3]),
          }),
          [1, 2, 3],
        );
      }
      expect(server.userAgents, {'Voges-Updater'});
    });

    test('resolves a relative location on the same host', () async {
      expect(
        await fetchVia({
          _download: redirectTo('/elsewhere'),
          'github.com/elsewhere': bytes([4]),
        }),
        [4],
      );
    });

    test('follows at most five redirects', () async {
      Map<String, Answer> chain(int hops) => {
        _download: redirectTo('https://$_cdn/hop/1'),
        for (var hop = 1; hop < hops; hop++)
          '$_cdn/hop/$hop': redirectTo('https://$_cdn/hop/${hop + 1}'),
        '$_cdn/hop/$hops': bytes([5]),
      };
      expect(await fetchVia(chain(5)), [5]);
      await expectLater(fetchVia(chain(6)), _fails(UpdateFailureKind.network));
    });

    final refused = {
      'another host': 'https://example.com/file',
      'a look-alike host': 'https://$_cdn.example.com/file',
      'http': 'http://$_cdn/file',
      'user info': 'https://user:secret@$_cdn/file',
      'another port': 'https://$_cdn:8443/file',
      'another scheme': 'ftp://$_cdn/file',
    };
    for (final MapEntry(key: name, value: location) in refused.entries) {
      test('refuses a redirect to $name', () async {
        await expectLater(
          fetchVia({
            _download: redirectTo(location),
            '$_cdn/file': bytes([6]),
            'example.com/file': bytes([6]),
          }),
          _fails(UpdateFailureKind.network),
        );
        expect(server.requests, ['GET $_download']);
      });
    }

    test('allows plain http only to the loopback origin and port', () async {
      final releases = loopback();
      final download =
          '127.0.0.1/$_repository/releases/download/v1.2.3/$_asset';
      server.routes = {
        download: redirectTo('${server.origin}/files/asset'),
        '127.0.0.1/files/asset': bytes([7]),
      };
      expect(await releases.fetch(_repository, _version, _asset, maxBytes: 8), [
        7,
      ]);

      for (final location in [
        'http://127.0.0.1:${server.port == 1 ? 2 : 1}/files/asset',
        'http://localhost:${server.port}/files/asset',
      ]) {
        server.routes = {download: redirectTo(location)};
        await expectLater(
          releases.fetch(_repository, _version, _asset, maxBytes: 8),
          _fails(UpdateFailureKind.network),
        );
      }
    });
  });

  group('fetch', () {
    test('maps 404 to unavailable and other statuses to network', () async {
      final releases = production();
      await expectLater(
        releases.fetch(_repository, _version, checksumsAsset, maxBytes: 8),
        _fails(UpdateFailureKind.unavailable),
      );
      server.routes = {_download: status(HttpStatus.internalServerError)};
      await expectLater(
        releases.fetch(_repository, _version, _asset, maxBytes: 8),
        _fails(UpdateFailureKind.network),
      );
    });

    test('refuses a Content-Length over the limit before reading', () async {
      // the body never arrives: only the header can fail this in time
      server.routes = {
        _download: stall([0], contentLength: 9),
      };
      await expectLater(
        production().fetch(_repository, _version, _asset, maxBytes: 8),
        _fails(UpdateFailureKind.network),
      );
    });

    test('refuses a body over the limit without Content-Length', () async {
      server.routes = {_download: bytes(List.filled(9, 0), chunked: true)};
      await expectLater(
        production().fetch(_repository, _version, _asset, maxBytes: 8),
        _fails(UpdateFailureKind.network),
      );
      server.routes = {_download: bytes(List.filled(8, 0), chunked: true)};
      expect(
        await production().fetch(_repository, _version, _asset, maxBytes: 8),
        hasLength(8),
      );
    });

    test('gives up on a server that stops sending', () async {
      server.routes = {
        _download: stall([1, 2], contentLength: 10),
      };
      await expectLater(
        production(
          idleTimeout: const Duration(milliseconds: 200),
        ).fetch(_repository, _version, _asset, maxBytes: 10),
        _fails(UpdateFailureKind.network),
      );
    });

    test('asks only for files of the releases', () {
      final releases = production();
      expect(
        () => releases.fetch(_repository, _version, 'other.txt', maxBytes: 8),
        throwsArgumentError,
      );
      expect(
        () => releases.fetch(
          '../owner/repo',
          _version,
          checksumsAsset,
          maxBytes: 8,
        ),
        throwsArgumentError,
      );
      expect(server.requests, isEmpty);
    });
  });

  group('download', () {
    late File target;

    setUp(() => target = File(p.join(temporaryFolder().path, _asset)));

    Future<String> download({
      int maxBytes = 1024,
      Duration? idleTimeout,
      void Function(int received, int? total)? onProgress,
      bool Function()? isCancelled,
    }) => production(idleTimeout: idleTimeout).download(
      _repository,
      _version,
      _asset,
      target,
      maxBytes: maxBytes,
      onProgress: onProgress,
      isCancelled: isCancelled,
    );

    test('streams the file and returns its SHA-256', () async {
      final body = List.generate(300000, (i) => i % 251);
      server.routes = {
        _download: redirectTo('https://$_cdn/file'),
        '$_cdn/file': bytes(body),
      };
      final progress = <(int, int?)>[];
      final hash = await download(
        maxBytes: body.length,
        onProgress: (received, total) => progress.add((received, total)),
      );
      expect(hash, sha256.convert(body).toString());
      expect(target.readAsBytesSync(), body);
      expect(progress.first, (0, body.length));
      expect(progress.last, (body.length, body.length));
    });

    test('deletes the partial file when the body is too large', () async {
      server.routes = {_download: bytes(List.filled(2000, 1), chunked: true)};
      await expectLater(
        download(maxBytes: 1000),
        _fails(UpdateFailureKind.network),
      );
      expect(target.existsSync(), isFalse);
    });

    test('writes nothing when Content-Length is too large', () async {
      server.routes = {
        _download: stall([1], contentLength: 2000),
      };
      await expectLater(
        download(maxBytes: 1000),
        _fails(UpdateFailureKind.network),
      );
      expect(target.existsSync(), isFalse);
    });

    test('deletes the partial file when the server stalls', () async {
      server.routes = {
        _download: stall([1, 2, 3], contentLength: 100),
      };
      await expectLater(
        download(idleTimeout: const Duration(milliseconds: 200)),
        _fails(UpdateFailureKind.network),
      );
      expect(target.existsSync(), isFalse);
    });

    test('stops and deletes the partial file when cancelled', () async {
      const size = 4 * 1024 * 1024;
      server.routes = {_download: bytes(List.filled(size, 1))};
      var cancelled = false;
      await expectLater(
        download(
          maxBytes: size,
          onProgress: (received, total) => cancelled = received > 0,
          isCancelled: () => cancelled,
        ),
        throwsA(
          isA<UpdateFailure>()
              .having((f) => f.kind, 'kind', UpdateFailureKind.network)
              .having((f) => f.detail, 'detail', 'cancelled'),
        ),
      );
      expect(target.existsSync(), isFalse);
    });

    test('does not start when already cancelled', () async {
      server.routes = {
        _download: bytes([1]),
      };
      await expectLater(
        download(isCancelled: () => true),
        _fails(UpdateFailureKind.network),
      );
      expect(server.requests, isEmpty);
    });
  });

  test('production talks to github.com without a test build define', () {
    final releases = GitHubReleases.production();
    addTearDown(releases.close);
    expect(releases.origin, Uri.parse('https://github.com'));
    expect(releases.redirectHosts, GitHubReleases.defaultRedirectHosts);
  });

  test('the release page is the tag page on github.com', () {
    expect(
      releasePage('omanoloneto/voges-word', _version),
      Uri.parse(
        'https://github.com/omanoloneto/voges-word/releases/tag/v1.2.3',
      ),
    );
  });
}
