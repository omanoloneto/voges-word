import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:path/path.dart' as p;

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

  /// Size limits, in bytes: anything larger is not a Voges release.
  static const checksumsLimit = 64 * 1024;
  static const signatureLimit = 1024;
  static const assetLimit = 512 * 1024 * 1024;

  @override
  Future<VerifiedAsset> fetch(
    SuiteApp app,
    ReleaseVersion version,
    String asset,
    Directory into, {
    void Function(double progress)? onProgress,
    bool Function()? isCancelled,
  }) async {
    onProgress?.call(0);
    final checksums = await _verificationFile(
      app,
      version,
      checksumsAsset,
      checksumsLimit,
    );
    final signature = await _verificationFile(
      app,
      version,
      signatureAsset,
      signatureLimit,
    );
    final expected = (await verifier.verify(
      repository: app.repository,
      version: version,
      checksums: checksums,
      signature: signature,
    ))[asset];
    if (expected == null) {
      throw UpdateFailure(
        UpdateFailureKind.unavailable,
        detail: '${version.tag} has no $asset',
      );
    }
    final file = File(p.join(into.path, asset));
    final actual = await releases.download(
      app.repository,
      version,
      asset,
      file,
      maxBytes: assetLimit,
      onProgress: onProgress == null
          ? null
          : (received, total) {
              if (total != null && total > 0) onProgress(received / total);
            },
      isCancelled: isCancelled,
    );
    if (actual != expected) {
      try {
        await file.delete();
      } on FileSystemException {
        // still never installed: no VerifiedAsset points at it
      }
      throw UpdateFailure(
        UpdateFailureKind.verification,
        detail: '$asset does not match $checksumsAsset',
      );
    }
    onProgress?.call(1);
    return VerifiedAsset(file: file, sha256: actual);
  }

  Future<Uint8List> _verificationFile(
    SuiteApp app,
    ReleaseVersion version,
    String name,
    int maxBytes,
  ) async {
    try {
      return await releases.fetch(
        app.repository,
        version,
        name,
        maxBytes: maxBytes,
      );
    } on UpdateFailure catch (failure) {
      // a release without its checksums or their signature is never
      // trusted, so it fails like a bad signature, without a download link
      if (failure.kind != UpdateFailureKind.unavailable) rethrow;
      throw UpdateFailure(
        UpdateFailureKind.verification,
        detail: '${version.tag} has no $name',
      );
    }
  }
}
