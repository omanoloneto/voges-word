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
    String? checkout,
    ReleaseVerifier? verifier,
    StringSink? out,
    StringSink? err,
  }) : checkout = checkout ?? _packageOf(Platform.script),
       verifier = verifier ?? ReleaseVerifier(),
       out = out ?? stdout,
       err = err ?? stderr;

  final ProcessRunner runner;

  /// Absolute path of the GitHub command line; null when it is missing.
  final String? gh;

  /// This package in the local clone, whose tags are the owner's. Paths
  /// given to git are relative to it, wherever the tool runs from.
  final String checkout;

  /// Checks the new signature against the keys the apps trust.
  final ReleaseVerifier verifier;

  final StringSink out;
  final StringSink err;

  static const security = '/usr/bin/security';
  static const git = '/usr/bin/git';
  static const keychainService = 'voges-release-signing';
  static const keychainAccount = 'voges';

  /// Who uploads every file of a release made by the release workflow.
  static const workflowBot = 'github-actions[bot]';

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
  ///
  /// A stolen GitHub token could replace the draft's files before they are
  /// signed, so only files that the release workflow built from the owner's
  /// tag are signed: the bot uploaded them, the tag is the same here and on
  /// GitHub, and GitHub attests that this workflow made SHA256SUMS.txt from
  /// that commit.
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

    final release = _releaseOf(
      await _gh(gh, [
        'release',
        'view',
        tag,
        '--repo',
        repository,
        '--json',
        'isDraft,assets,databaseId',
      ]),
    );
    if (!release.draft) {
      _refuse(
        '$tag is already published: only a draft from the release '
        'workflow is signed.',
      );
    }
    final signed = release.assets.contains(signatureAsset);
    final built = release.assets.where((name) => name != signatureAsset);
    if (!_exactly(built, {...installers, checksumsAsset})) {
      _refuse(
        '$tag should have exactly '
        '${[...installers, checksumsAsset].join(', ')}; '
        'it has ${release.assets.join(', ')}.',
      );
    }
    _uploadedByWorkflow(
      await _gh(gh, ['api', 'repos/$repository/releases/${release.id}']),
      built.toSet(),
    );
    final commit = await _tagCommit(gh, repository, tag);
    await _sameTrustedKeys(tag);

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
        if (signed) ...['--pattern', signatureAsset],
        '--dir',
        folder.path,
      ]);
      final checksumsFile = File(p.join(folder.path, checksumsAsset));
      await _gh(gh, [
        'attestation',
        'verify',
        checksumsFile.path,
        '--repo',
        repository,
        '--signer-workflow',
        '$repository/.github/workflows/release.yml',
        '--source-ref',
        'refs/tags/$tag',
        '--source-digest',
        commit,
        '--deny-self-hosted-runners',
      ]);
      final checksums = await _readChecksums(checksumsFile);
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
      // Ed25519 signatures are deterministic: a signature left by a publish
      // that stopped halfway is byte for byte the one made now
      final signatureFile = File(p.join(folder.path, signatureAsset));
      if (signed && !_same(await signatureFile.readAsBytes(), signature)) {
        _refuse(
          '$tag already has a $signatureAsset that this key did not make. '
          'Delete it only if you know where it came from.',
        );
      }
      if (dryRun) {
        out.writeln(
          'Dry run: $repository $tag is signed and the signature '
          'matches releaseSigningKeys. Nothing was uploaded.',
        );
        return;
      }

      if (!signed) {
        await signatureFile.writeAsBytes(signature, flush: true);
        await _gh(gh, [
          'release',
          'upload',
          tag,
          signatureFile.path,
          '--repo',
          repository,
        ]);
      }
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

  /// The commit of [tag], which must be the same in this clone and on
  /// GitHub: a tag moved on GitHub would point the build somewhere else.
  Future<String> _tagCommit(String gh, String repository, String tag) async {
    final local = await runner.run(git, [
      '-C',
      checkout,
      'rev-parse',
      '--verify',
      '$tag^{commit}',
    ]);
    if (local.exitCode != 0) {
      _refuse(
        '$tag is not in this clone. Tag the commit you reviewed here and '
        'push that tag: fetching it would trust the copy on GitHub.',
      );
    }
    final commit = '${local.stdout}'.trim();
    final remote = (await _gh(gh, [
      'api',
      'repos/$repository/commits/$tag',
      '--jq',
      '.sha',
    ])).trim();
    if (remote != commit) {
      _refuse(
        '$tag is $commit here but $remote on GitHub. Nothing was signed.',
      );
    }
    return commit;
  }

  /// The release must trust the key it is signed with: the apps built from
  /// [tag] check updates against the releaseSigningKeys of that commit.
  Future<void> _sameTrustedKeys(String tag) async {
    final atTag = await runner.run(git, [
      '-C',
      checkout,
      'cat-file',
      '-e',
      '$tag:./lib/src/release_trust.dart',
    ]);
    if (atTag.exitCode != 0) {
      _refuse('$tag has no lib/src/release_trust.dart in this package.');
    }
    final diff = await runner.run(git, [
      '-C',
      checkout,
      'diff',
      '--quiet',
      tag,
      '--',
      'lib/src/release_trust.dart',
    ]);
    if (diff.exitCode != 0) {
      _refuse(
        'lib/src/release_trust.dart here differs from $tag. Check out $tag '
        'and run publish from there.',
      );
    }
  }

  static void _uploadedByWorkflow(String json, Set<String> built) {
    final Object? release;
    try {
      release = jsonDecode(json);
    } on FormatException {
      _refuse('gh api did not answer JSON for the release.');
    }
    if (release case {
      'author': {'login': final String author},
      'assets': final List<Object?> assets,
    }) {
      if (author != workflowBot) {
        _refuse(
          'The draft was created by $author, not by the release workflow.',
        );
      }
      for (final asset in assets) {
        if (asset case {
          'name': final String name,
          'uploader': {'login': final String uploader},
        }) {
          if (built.contains(name) && uploader != workflowBot) {
            _refuse(
              '$name was uploaded by $uploader, not by the release workflow.',
            );
          }
        } else {
          _refuse('gh api listed an asset without its name or uploader.');
        }
      }
      return;
    }
    _refuse('gh api answered without the author and assets of the release.');
  }

  static bool _same(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
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

  static ({bool draft, List<String> assets, int id}) _releaseOf(String json) {
    final Object? release;
    try {
      release = jsonDecode(json);
    } on FormatException {
      _refuse('gh release view did not answer JSON.');
    }
    if (release case {
      'isDraft': final bool draft,
      'assets': final List<Object?> assets,
      'databaseId': final int id,
    }) {
      return (
        draft: draft,
        id: id,
        assets: [
          for (final asset in assets)
            if (asset case {'name': final String name})
              name
            else
              _refuse('gh release view listed an asset without a name.'),
        ],
      );
    }
    _refuse('gh release view answered without isDraft, assets and databaseId.');
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

/// The package folder of the tool at [script] (`<package>/tool/x.dart`).
String _packageOf(Uri script) => p.dirname(p.dirname(script.toFilePath()));

String? _onPath(String name) {
  for (final folder in (Platform.environment['PATH'] ?? '').split(':')) {
    // a relative entry would depend on the folder this runs from
    if (!p.isAbsolute(folder)) continue;
    final candidate = p.join(folder, name);
    if (File(candidate).existsSync()) return candidate;
  }
  return null;
}
