import 'dart:typed_data';

import 'release_version.dart';

/// Reads a `SHA256SUMS.txt`: file name to lowercase SHA-256.
Map<String, String> parseChecksums(String text) {
  throw UnimplementedError();
}

/// The bytes the release signature covers: the repository and tag, so a
/// signature cannot be replayed on another release, then the checksums.
Uint8List signedMessage(
  String repository,
  ReleaseVersion version,
  Uint8List checksums,
) {
  throw UnimplementedError();
}

/// Checks the Ed25519 signature of a release's checksums against the keys
/// compiled into the app.
final class ReleaseVerifier {
  ReleaseVerifier({List<String>? trustedKeys});

  /// The checksums, once the signature is valid; throws an `UpdateFailure`
  /// of kind verification otherwise.
  Future<Map<String, String>> verify({
    required String repository,
    required ReleaseVersion version,
    required Uint8List checksums,
    required Uint8List signature,
  }) {
    throw UnimplementedError();
  }
}
