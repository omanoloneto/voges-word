import 'dart:io';
import 'dart:typed_data';

import 'release_version.dart';

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
       redirectHosts = redirectHosts ?? defaultRedirectHosts;

  /// github.com, or the loopback test origin of a test build.
  factory GitHubReleases.production() => throw UnimplementedError();

  static const defaultRedirectHosts = {
    'github.com',
    'release-assets.githubusercontent.com',
    'objects.githubusercontent.com',
  };

  final HttpClient _client;
  final Uri origin;
  final Set<String> redirectHosts;
  final Duration connectTimeout;
  final Duration idleTimeout;

  @override
  Future<ReleaseVersion> latest(String repository) {
    throw UnimplementedError();
  }

  /// A small file of [version], such as the checksums or their signature.
  Future<Uint8List> fetch(
    String repository,
    ReleaseVersion version,
    String name, {
    required int maxBytes,
  }) {
    throw UnimplementedError();
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
  }) {
    throw UnimplementedError();
  }

  void close() => _client.close(force: true);
}
