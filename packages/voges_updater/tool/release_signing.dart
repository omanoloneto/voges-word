/// Signs the releases of the Voges apps with the key kept in the owner's
/// login Keychain, on the owner's Mac:
///
///     dart run tool/release_signing.dart init
///     dart run tool/release_signing.dart publish <owner/repo> <vX.Y.Z> [--dry-run]
///
/// `init` creates the key once. `publish` signs the checksums of a draft
/// that the release workflow created, uploads the signature and publishes
/// the draft.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/dart.dart';
import 'package:path/path.dart' as p;
import 'package:voges_updater/core.dart';

Future<void> main(List<String> arguments) async {
  if (!Platform.isMacOS) {
    stderr.writeln(
      'The signing key lives in the macOS Keychain: run this on the Mac '
      'that holds it.',
    );
    exitCode = 1;
    return;
  }
  exitCode = await ReleaseSigning(
    runner: const SystemProcessRunner(),
    gh: _onPath('gh'),
  ).run(arguments);
}

/// The public key of the 32-byte Ed25519 [seed], in base64 as
/// `releaseSigningKeys` lists it.
Future<String> publicKeyOf(List<int> seed) async {
  final keyPair = await DartEd25519().newKeyPairFromSeed(seed);
  return base64.encode((await keyPair.extractPublicKey()).bytes);
}

/// The `SHA256SUMS.txt.sig` of [checksums] that `ReleaseVerifier` accepts.
Future<Uint8List> signChecksums({
  required List<int> seed,
  required String repository,
  required ReleaseVersion version,
  required Uint8List checksums,
}) async {
  final algorithm = DartEd25519();
  final signature = await algorithm.sign(
    signedMessage(repository, version, checksums),
    keyPair: await algorithm.newKeyPairFromSeed(seed),
  );
  return utf8.encode('${base64.encode(signature.bytes)}\n');
}

/// The `init` and `publish` commands. Every system tool runs through
/// [runner] and every message goes to [out] or [err], so tests replace them.
final class ReleaseSigning {
  ReleaseSigning({
    required this.runner,
    required this.gh,
    ReleaseVerifier? verifier,
    StringSink? out,
    StringSink? err,
  }) : verifier = verifier ?? ReleaseVerifier(),
       out = out ?? stdout,
       err = err ?? stderr;

  final ProcessRunner runner;

  /// Absolute path of the GitHub command line; null when it is missing.
  final String? gh;

  /// Checks the new signature against the keys the apps trust.
  final ReleaseVerifier verifier;

  final StringSink out;
  final StringSink err;

  static const security = '/usr/bin/security';
  static const keychainService = 'voges-release-signing';
  static const keychainAccount = 'voges';

  static const usage =
      'Usage:\n'
      '  dart run tool/release_signing.dart init\n'
      '  dart run tool/release_signing.dart publish <owner/repo> <vX.Y.Z> '
      '[--dry-run]';

  /// errSecItemNotFound, as `security` reports it.
  static const _itemNotFound = 44;

  /// The exit code for [arguments]: 0 when done, 1 when refused, 64 for
  /// arguments that are not a command.
  Future<int> run(List<String> arguments) async {
    try {
      switch (arguments) {
        case ['init']:
          await init();
        case ['publish', final repository, final tag]:
          await publish(repository, tag);
        case ['publish', final repository, final tag, '--dry-run']:
          await publish(repository, tag, dryRun: true);
        default:
          err.writeln(usage);
          return 64;
      }
      return 0;
    } on _Refused catch (refusal) {
      err.writeln(refusal.message);
      return 1;
    }
  }

  /// Creates the signing key in the login Keychain and prints its public
  /// key. Refuses when the key already exists.
  Future<void> init() async {
    final existing = await runner.run(security, [
      'find-generic-password',
      '-a',
      keychainAccount,
      '-s',
      keychainService,
    ]);
    if (existing.exitCode == 0) {
      _refuse(
        'The login Keychain already has "$keychainService". init never '
        'replaces it: the apps trust that key.',
      );
    }
    if (existing.exitCode != _itemNotFound) {
      _refuse(
        'security could not search the Keychain '
        '(exit ${existing.exitCode}).',
      );
    }
    final random = Random.secure();
    final seed = Uint8List.fromList([
      for (var i = 0; i < 32; i++) random.nextInt(256),
    ]);
    final encoded = base64.encode(seed);
    // The key goes through stdin because the arguments of a process are
    // visible to every other process, and the output of security is dropped
    // because an error message can repeat the command line. There is no
    // -T "": publish reads the key from a remote session, where nobody can
    // answer a Keychain prompt, and this key guards against a stolen GitHub
    // account, not against malware on this Mac.
    final process = await runner.start(security, ['-i']);
    final output = Future.wait([
      process.stdout.drain<void>(),
      process.stderr.drain<void>(),
    ]);
    process.stdin.writeln(
      'add-generic-password -a $keychainAccount -s $keychainService '
      '-w $encoded',
    );
    await process.stdin.close();
    final code = await process.exitCode;
    await output;
    if (code != 0) _refuse('security could not store the key (exit $code).');
    if (await _readKey() != encoded) {
      _refuse('The key read back from the Keychain is not the one stored.');
    }
    out
      ..writeln(
        'The signing key is in the login Keychain as '
        '"$keychainService".',
      )
      ..writeln(
        'Public key, for releaseSigningKeys in '
        'lib/src/release_trust.dart:',
      )
      ..writeln(await publicKeyOf(seed))
      ..writeln(
        'Back it up now: in Keychain Access, open "$keychainService", '
        'choose Show password and save it in your password manager.',
      );
  }

  /// Signs the checksums of the draft [tag] of [repository] and, unless
  /// [dryRun], uploads the signature and publishes the draft.
  Future<void> publish(
    String repository,
    String tag, {
    bool dryRun = false,
  }) async {
    final gh =
        this.gh ?? _refuse('gh, the GitHub command line, is not in PATH.');
    final app =
        vogesSuite.where((app) => app.repository == repository).firstOrNull ??
        _refuse('$repository is not an app of the Voges suite.');
    final version =
        ReleaseVersion.tryParseTag(tag) ??
        _refuse('$tag is not a release tag such as v1.2.0.');
    final installers = {app.macos.asset, app.windows.asset, app.linux.asset};

    final (draft, assets) = _draftAndAssets(
      await _gh(gh, [
        'release',
        'view',
        tag,
        '--repo',
        repository,
        '--json',
        'isDraft,assets',
      ]),
    );
    if (!draft) {
      _refuse(
        '$tag is already published: only a draft from the release '
        'workflow is signed.',
      );
    }
    if (assets.contains(signatureAsset)) {
      _refuse('$tag already has $signatureAsset.');
    }
    if (!_exactly(assets, {...installers, checksumsAsset})) {
      _refuse(
        '$tag should have exactly '
        '${[...installers, checksumsAsset].join(', ')}; '
        'it has ${assets.join(', ')}.',
      );
    }

    final folder = await Directory.systemTemp.createTemp('voges-release-');
    try {
      await _gh(gh, [
        'release',
        'download',
        tag,
        '--repo',
        repository,
        '--pattern',
        checksumsAsset,
        '--dir',
        folder.path,
      ]);
      final checksums = await _readChecksums(
        File(p.join(folder.path, checksumsAsset)),
      );
      final Map<String, String> sums;
      try {
        sums = parseChecksums(ascii.decode(checksums));
      } on FormatException catch (error) {
        _refuse('$checksumsAsset is malformed: ${error.message}.');
      }
      if (!_exactly(sums.keys, installers)) {
        _refuse(
          '$checksumsAsset should list exactly '
          '${installers.join(', ')}; it lists ${sums.keys.join(', ')}.',
        );
      }

      final signature = await signChecksums(
        seed: _seedOf(await _readKey()),
        repository: repository,
        version: version,
        checksums: checksums,
      );
      try {
        await verifier.verify(
          repository: repository,
          version: version,
          checksums: checksums,
          signature: signature,
        );
      } on UpdateFailure {
        _refuse(
          'The key in the Keychain is not in releaseSigningKeys, so '
          'the apps would reject this release. Nothing was uploaded.',
        );
      }
      if (dryRun) {
        out.writeln(
          'Dry run: $repository $tag is signed and the signature '
          'matches releaseSigningKeys. Nothing was uploaded.',
        );
        return;
      }

      final signatureFile = File(p.join(folder.path, signatureAsset));
      await signatureFile.writeAsBytes(signature, flush: true);
      await _gh(gh, [
        'release',
        'upload',
        tag,
        signatureFile.path,
        '--repo',
        repository,
      ]);
      await _gh(gh, [
        'release',
        'edit',
        tag,
        '--repo',
        repository,
        '--draft=false',
        '--latest',
      ]);
      out.writeln('Published $repository $tag with its signature.');
    } finally {
      await folder.delete(recursive: true);
    }
  }

  /// The key in base64, as stored by [init]. Never printed.
  Future<String> _readKey() async {
    final result = await runner.run(security, [
      'find-generic-password',
      '-a',
      keychainAccount,
      '-s',
      keychainService,
      '-w',
    ]);
    if (result.exitCode != 0) {
      _refuse(
        'Could not read "$keychainService" from the Keychain '
        '(exit ${result.exitCode}). Run init first.',
      );
    }
    return '${result.stdout}'.trim();
  }

  static Uint8List _seedOf(String key) {
    try {
      final seed = base64.decode(key);
      if (seed.length == 32) return seed;
    } on FormatException {
      // reported below, without the key
    }
    _refuse('"$keychainService" in the Keychain is not a 32-byte key.');
  }

  Future<String> _gh(String gh, List<String> arguments) async {
    final result = await runner.run(gh, arguments);
    if (result.exitCode != 0) {
      _refuse(
        'gh ${arguments.take(2).join(' ')} failed '
        '(exit ${result.exitCode}): ${'${result.stderr}'.trim()}',
      );
    }
    return '${result.stdout}';
  }

  static (bool, List<String>) _draftAndAssets(String json) {
    final Object? release;
    try {
      release = jsonDecode(json);
    } on FormatException {
      _refuse('gh release view did not answer JSON.');
    }
    if (release case {
      'isDraft': final bool draft,
      'assets': final List<Object?> assets,
    }) {
      return (
        draft,
        [
          for (final asset in assets)
            if (asset case {'name': final String name})
              name
            else
              _refuse('gh release view listed an asset without a name.'),
        ],
      );
    }
    _refuse('gh release view answered without isDraft and assets.');
  }

  static Future<Uint8List> _readChecksums(File file) async {
    if (await file.length() > ReleaseDownloader.checksumsLimit) {
      _refuse('$checksumsAsset is larger than the apps accept.');
    }
    return file.readAsBytes();
  }

  static bool _exactly(Iterable<String> names, Set<String> expected) =>
      names.length == expected.length && names.toSet().containsAll(expected);
}

final class _Refused implements Exception {
  const _Refused(this.message);

  final String message;
}

Never _refuse(String message) => throw _Refused(message);

String? _onPath(String name) {
  for (final folder in (Platform.environment['PATH'] ?? '').split(':')) {
    // a relative entry would depend on the folder this runs from
    if (!p.isAbsolute(folder)) continue;
    final candidate = p.join(folder, name);
    if (File(candidate).existsSync()) return candidate;
  }
  return null;
}
