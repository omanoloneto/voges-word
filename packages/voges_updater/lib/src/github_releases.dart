import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;

import 'catalog.dart';
import 'release_trust.dart';
import 'release_version.dart';
import 'update_failure.dart';

/// Where the latest version of each suite app comes from.
abstract interface class ReleaseFeed {
  /// The newest published version of [repository] (`owner/repo`).
  Future<ReleaseVersion> latest(String repository);
}

/// The page of [version] on GitHub, for "What's new".
Uri releasePage(String repository, ReleaseVersion version) =>
    Uri.parse('https://github.com/$repository/releases/tag/${version.tag}');

/// Reads releases straight from github.com: the latest version from the
/// redirect of `/releases/latest`, and files from `/releases/download/`.
final class GitHubReleases implements ReleaseFeed {
  GitHubReleases({
    HttpClient? client,
    Uri? origin,
    Set<String>? redirectHosts,
    this.connectTimeout = const Duration(seconds: 15),
    this.idleTimeout = const Duration(seconds: 30),
  }) : _client = client ?? HttpClient(),
       origin = origin ?? Uri.parse('https://github.com'),
       redirectHosts = redirectHosts ?? defaultRedirectHosts {
    _client
      ..connectionTimeout = connectTimeout
      ..userAgent = userAgent;
  }

  /// github.com, or the loopback test origin of a test build.
  factory GitHubReleases.production() {
    final loopback = testOrigin;
    return loopback == null
        ? GitHubReleases()
        : GitHubReleases(origin: loopback, redirectHosts: const {'127.0.0.1'});
  }

  static const defaultRedirectHosts = {
    'github.com',
    'release-assets.githubusercontent.com',
    'objects.githubusercontent.com',
  };

  /// Sent with every request; nothing in it identifies the user.
  static const userAgent = 'Voges-Updater';

  static const maxRedirects = 5;

  final HttpClient _client;
  final Uri origin;
  final Set<String> redirectHosts;
  final Duration connectTimeout;
  final Duration idleTimeout;

  @override
  Future<ReleaseVersion> latest(String repository) async {
    final prefix = _url(repository, 'releases/tag/').toString();
    try {
      final response = await _send('HEAD', _url(repository, 'releases/latest'));
      await _discard(response);
      // only the redirect to the tag page is trusted; any other answer
      // means GitHub changed, and the check fails rather than guess
      final location = response.headers[HttpHeaders.locationHeader];
      final version =
          response.isRedirect &&
              location?.length == 1 &&
              location!.single.startsWith(prefix)
          ? ReleaseVersion.tryParseTag(location.single.substring(prefix.length))
          : null;
      if (version == null) {
        throw UpdateFailure(
          UpdateFailureKind.network,
          detail:
              'unexpected answer for the latest release: '
              '${response.statusCode} $location',
        );
      }
      return version;
    } on Exception catch (error) {
      throw _failure(error);
    }
  }

  /// A small file of [version], such as the checksums or their signature.
  Future<Uint8List> fetch(
    String repository,
    ReleaseVersion version,
    String name, {
    required int maxBytes,
  }) async {
    final url = _fileUrl(repository, version, name);
    try {
      final response = await _get(url);
      await _refuseLarger(response, maxBytes, name);
      final bytes = BytesBuilder(copy: false);
      await for (final chunk in response.timeout(idleTimeout)) {
        if (bytes.length + chunk.length > maxBytes) {
          throw _tooLarge(name, maxBytes);
        }
        bytes.add(chunk);
      }
      return bytes.takeBytes();
    } on Exception catch (error) {
      throw _failure(error);
    }
  }

  /// Streams [name] of [version] into [target] and returns its SHA-256 in
  /// lowercase hex.
  Future<String> download(
    String repository,
    ReleaseVersion version,
    String name,
    File target, {
    required int maxBytes,
    void Function(int received, int? total)? onProgress,
    bool Function()? isCancelled,
  }) async {
    final url = _fileUrl(repository, version, name);
    RandomAccessFile? output;
    try {
      _stopIfCancelled(isCancelled);
      final response = await _get(url);
      await _refuseLarger(response, maxBytes, name);
      final total = response.contentLength < 0 ? null : response.contentLength;
      output = await target.open(mode: FileMode.writeOnly);
      final digest = _DigestSink();
      final hash = crypto.sha256.startChunkedConversion(digest);
      var received = 0;
      onProgress?.call(0, total);
      await for (final chunk in response.timeout(idleTimeout)) {
        _stopIfCancelled(isCancelled);
        received += chunk.length;
        if (received > maxBytes) throw _tooLarge(name, maxBytes);
        hash.add(chunk);
        await output.writeFrom(chunk);
        onProgress?.call(received, total);
      }
      hash.close();
      await output.close();
      return digest.value.toString();
    } catch (error) {
      try {
        await output?.close();
      } on FileSystemException {
        // already closed
      }
      try {
        await target.delete();
      } on FileSystemException {
        // never created
      }
      if (error is Exception) throw _failure(error);
      rethrow;
    }
  }

  void close() => _client.close(force: true);

  static final _repository = RegExp(
    r'^[A-Za-z0-9-]+/[A-Za-z0-9_][A-Za-z0-9._-]*$',
  );

  /// The only files ever requested: what the catalog names, so a tampered
  /// answer can never make the updater fetch something else.
  static final _releaseFiles = {
    checksumsAsset,
    signatureAsset,
    for (final app in vogesSuite) ...[
      app.macos.asset,
      app.windows.asset,
      app.linux.asset,
    ],
  };

  Uri _url(String repository, String path) {
    if (!_repository.hasMatch(repository)) {
      throw ArgumentError.value(repository, 'repository', 'not owner/repo');
    }
    return origin.replace(path: '/$repository/$path');
  }

  Uri _fileUrl(String repository, ReleaseVersion version, String name) {
    if (!_releaseFiles.contains(name)) {
      throw ArgumentError.value(name, 'name', 'not a file of the releases');
    }
    return _url(repository, 'releases/download/${version.tag}/$name');
  }

  /// GETs [url], following redirects by hand so every hop is checked.
  Future<HttpClientResponse> _get(Uri url) async {
    var current = url;
    for (var redirects = 0; ; redirects++) {
      final response = await _send('GET', current);
      if (!response.isRedirect) {
        if (response.statusCode == HttpStatus.ok) return response;
        await _discard(response);
        throw UpdateFailure(
          response.statusCode == HttpStatus.notFound
              ? UpdateFailureKind.unavailable
              : UpdateFailureKind.network,
          detail: 'HTTP ${response.statusCode} from ${_withoutQuery(current)}',
        );
      }
      await _discard(response);
      final location = response.headers[HttpHeaders.locationHeader];
      if (redirects == maxRedirects || location?.length != 1) {
        throw UpdateFailure(
          UpdateFailureKind.network,
          detail: 'redirect refused at ${_withoutQuery(current)}',
        );
      }
      final next = current.resolve(location!.single);
      if (!_mayFollow(next)) {
        throw UpdateFailure(
          UpdateFailureKind.network,
          detail: 'redirect to ${_withoutQuery(next)} refused',
        );
      }
      current = next;
    }
  }

  bool _mayFollow(Uri url) {
    if (url.userInfo.isNotEmpty || !redirectHosts.contains(url.host)) {
      return false;
    }
    if (url.scheme == 'https') return url.port == 443;
    // plain http only for the fake GitHub of a test build, on this computer
    return url.scheme == 'http' &&
        origin.scheme == 'http' &&
        origin.host == '127.0.0.1' &&
        url.host == origin.host &&
        url.port == origin.port;
  }

  Future<HttpClientResponse> _send(String method, Uri url) async {
    final request = await _client.openUrl(method, url);
    request.followRedirects = false;
    try {
      return await request.close().timeout(idleTimeout);
    } on TimeoutException {
      request.abort();
      rethrow;
    }
  }

  /// Drops a body that is not needed; cancelling, unlike draining, never
  /// reads what a server may keep sending.
  static Future<void> _discard(HttpClientResponse response) =>
      response.listen(null).cancel();

  static Future<void> _refuseLarger(
    HttpClientResponse response,
    int maxBytes,
    String name,
  ) async {
    if (response.contentLength <= maxBytes) return;
    await _discard(response);
    throw _tooLarge(name, maxBytes);
  }

  static UpdateFailure _tooLarge(String name, int maxBytes) => UpdateFailure(
    UpdateFailureKind.network,
    detail: '$name is larger than $maxBytes bytes',
  );

  static void _stopIfCancelled(bool Function()? isCancelled) {
    if (isCancelled?.call() ?? false) {
      throw const UpdateFailure(UpdateFailureKind.network, detail: 'cancelled');
    }
  }

  static UpdateFailure _failure(Exception error) => switch (error) {
    UpdateFailure failure => failure,
    FileSystemException() => UpdateFailure(
      UpdateFailureKind.failed,
      detail: '$error',
    ),
    _ => UpdateFailure(UpdateFailureKind.network, detail: '$error'),
  };

  /// Download links of GitHub carry short-lived tokens in the query, and a
  /// refused redirect may carry a password: neither has a place in logs.
  static String _withoutQuery(Uri url) =>
      '${url.scheme}://${url.host}${url.hasPort ? ':${url.port}' : ''}'
      '${url.path}';
}

final class _DigestSink implements Sink<crypto.Digest> {
  late crypto.Digest value;

  @override
  void add(crypto.Digest data) => value = data;

  @override
  void close() {}
}
