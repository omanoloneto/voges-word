import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:cryptography/dart.dart';

import 'catalog.dart';
import 'release_trust.dart';
import 'release_version.dart';
import 'update_failure.dart';

/// Reads a `SHA256SUMS.txt`: file name to lowercase SHA-256. Every line that
/// is not empty must be `<sha256>  <name>`, and a name may appear only once;
/// anything else throws a [FormatException].
Map<String, String> parseChecksums(String text) {
  final checksums = <String, String>{};
  for (final rawLine in text.split('\n')) {
    final line = rawLine.endsWith('\r')
        ? rawLine.substring(0, rawLine.length - 1)
        : rawLine;
    if (line.isEmpty) continue;
    final match = _checksumLine.firstMatch(line);
    if (match == null) throw FormatException('Not a checksum line', line);
    final name = match[2]!;
    if (checksums.containsKey(name)) {
      throw FormatException('More than one checksum for $name');
    }
    checksums[name] = match[1]!;
  }
  return checksums;
}

final _checksumLine = RegExp(r'^([0-9a-f]{64})  ([A-Za-z0-9._-]+)$');

/// The bytes the release signature covers: the repository and tag, so a
/// signature cannot be replayed on another release, then the checksums.
Uint8List signedMessage(
  String repository,
  ReleaseVersion version,
  Uint8List checksums,
) {
  final header = utf8.encode(
    'voges-release v1\nrepository $repository\ntag ${version.tag}\n',
  );
  return Uint8List(header.length + checksums.length)
    ..setAll(0, header)
    ..setAll(header.length, checksums);
}

/// Checks the Ed25519 signature of a release's checksums against the keys
/// compiled into the app.
final class ReleaseVerifier {
  ReleaseVerifier({List<String>? trustedKeys})
    : trustedKeys = trustedKeys ?? trustedReleaseKeys;

  /// Public keys in base64; a release signed by any of them is trusted.
  final List<String> trustedKeys;

  /// The checksums, once the signature is valid; throws an `UpdateFailure`
  /// of kind verification otherwise.
  Future<Map<String, String>> verify({
    required String repository,
    required ReleaseVersion version,
    required Uint8List checksums,
    required Uint8List signature,
  }) async {
    final signatureBytes = _signatureBytes(signature);
    final message = signedMessage(repository, version, checksums);
    final algorithm = DartEd25519();
    for (final key in trustedKeys) {
      final keyBytes = _decodeExactly(key, 32);
      if (keyBytes == null) throw _failure('a trusted key is not valid');
      final trusted = await algorithm.verify(
        message,
        signature: Signature(
          signatureBytes,
          publicKey: SimplePublicKey(keyBytes, type: KeyPairType.ed25519),
        ),
      );
      if (!trusted) continue;
      try {
        return parseChecksums(ascii.decode(checksums));
      } on FormatException catch (error) {
        throw _failure('$checksumsAsset: ${error.message}');
      }
    }
    throw _failure(
      trustedKeys.isEmpty
          ? 'this build trusts no release key'
          : 'not signed by a trusted key',
    );
  }

  /// The `.sig` file: standard base64 of the 64-byte signature, optionally
  /// followed by one newline.
  static Uint8List _signatureBytes(Uint8List file) {
    final text = latin1.decode(file);
    final bytes = _decodeExactly(
      text.endsWith('\n') ? text.substring(0, text.length - 1) : text,
      64,
    );
    if (bytes == null) throw _failure('the signature file is malformed');
    return bytes;
  }

  /// [text] decoded only when it is the canonical base64 of [length] bytes,
  /// so no other spelling of the same bytes is accepted.
  static Uint8List? _decodeExactly(String text, int length) {
    try {
      final bytes = base64.decode(text);
      return bytes.length == length && base64.encode(bytes) == text
          ? bytes
          : null;
    } on FormatException {
      return null;
    }
  }

  static UpdateFailure _failure(String detail) =>
      UpdateFailure(UpdateFailureKind.verification, detail: detail);
}
