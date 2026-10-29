import 'dart:io';

import 'package:crypto/crypto.dart' as crypto;

import 'catalog.dart';
import 'github_releases.dart';
import 'release_verifier.dart';
import 'release_version.dart';
import 'update_failure.dart';

/// A downloaded installer whose SHA-256 matched the signed checksums.
final class VerifiedAsset {
  const VerifiedAsset({required this.file, required this.sha256});

  final File file;

  /// Lowercase hex.
  final String sha256;

  /// Hashes the file again right before it is used, in case it changed on
  /// disk after the download.
  Future<void> recheck() async {
    final crypto.Digest digest;
    try {
      digest = await crypto.sha256.bind(file.openRead()).first;
    } on FileSystemException catch (error) {
      throw UpdateFailure(UpdateFailureKind.verification, detail: '$error');
    }
    if (digest.toString() != sha256) {
      throw const UpdateFailure(
        UpdateFailureKind.verification,
        detail: 'the installer changed on disk',
      );
    }
  }
}

abstract interface class UpdateDownloader {
  /// Downloads [asset] of [version] into [into] and checks it against the
  /// release's signed checksums.
  Future<VerifiedAsset> fetch(
    SuiteApp app,
    ReleaseVersion version,
    String asset,
    Directory into, {
    void Function(double progress)? onProgress,
    bool Function()? isCancelled,
  });
}

/// Downloads the checksums, their signature and the installer from GitHub.
final class ReleaseDownloader implements UpdateDownloader {
  ReleaseDownloader({required this.releases, required this.verifier});

  final GitHubReleases releases;
  final ReleaseVerifier verifier;

  @override
  Future<VerifiedAsset> fetch(
    SuiteApp app,
    ReleaseVersion version,
    String asset,
    Directory into, {
    void Function(double progress)? onProgress,
    bool Function()? isCancelled,
  }) {
    throw UnimplementedError();
  }
}
