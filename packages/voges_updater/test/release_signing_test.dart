import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:voges_updater/core.dart';

import '../tool/release_signing.dart';

const _gh = '/opt/fake/bin/gh';
const _security = '/usr/bin/security';
const _git = '/usr/bin/git';
const _checkout = '/clone/packages/voges_updater';
const _bot = 'github-actions[bot]';
const _commit = '0123456789abcdef0123456789abcdef01234567';
const _tag = 'v1.2.0';
const _version = ReleaseVersion(1, 2, 0);
final _app = vogesWord;
final _repository = _app.repository;
final _installers = [_app.macos.asset, _app.windows.asset, _app.linux.asset];
final _seed = Uint8List.fromList(List.generate(32, (i) => i * 7 % 256));

Uint8List _sumsOf(Iterable<String> names) => utf8.encode(
  [
    for (final name in names) '${sha256.convert(utf8.encode(name))}  $name\n',
  ].join(),
);

/// The login Keychain as `security` shows it, and one release as `gh` shows
/// it. Nothing here touches the real ones.
final class _FakeSystem implements ProcessRunner {
  /// The stored key in base64, or null when there is none.
  String? keychain;
  int searchExitCode = 44;
  int addExitCode = 0;

  bool draft = true;
  List<String> assets = [..._installers, checksumsAsset];
  Uint8List checksums = _sumsOf(_installers);
  int viewExitCode = 0;

  String author = _bot;
  Map<String, String> uploaders = {};
  String? localCommit = _commit;
  String remoteCommit = _commit;
  bool sameTrustedKeys = true;
  bool trustFileAtTag = true;
  bool attested = true;

  /// The .sig already on the draft, when [assets] lists it.
  Uint8List? existingSignature;

  final calls = <List<String>>[];
  final interactiveInput = <String>[];
  Uint8List? uploaded;
  bool published = false;
  String? downloadFolder;

  bool get uploadedOrPublished => uploaded != null || published;

  @override
  Future<ProcessResult> run(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
  }) async {
    calls.add([executable, ...arguments]);
    return switch ((executable, arguments)) {
      (_security, ['find-generic-password', '-a', 'voges', '-s', _]) => _result(
        keychain == null ? searchExitCode : 0,
      ),
      (_security, ['find-generic-password', '-a', 'voges', '-s', _, '-w']) =>
        keychain == null ? _result(44) : _result(0, stdout: '$keychain\n'),
      (
        _gh,
        [
          'release',
          'view',
          _tag,
          '--repo',
          _,
          '--json',
          'isDraft,assets,databaseId',
        ],
      ) =>
        _result(
          viewExitCode,
          stdout: jsonEncode({
            'assets': [
              for (final name in assets) {'name': name, 'size': 1},
            ],
            'databaseId': 42,
            'isDraft': draft,
          }),
          stderr: viewExitCode == 0 ? '' : 'release not found',
        ),
      (_gh, ['api', 'repos/omanoloneto/voges-word/releases/42']) => _result(
        0,
        stdout: jsonEncode({
          'author': {'login': author},
          'assets': [
            for (final name in assets)
              {
                'name': name,
                'uploader': {
                  'login':
                      uploaders[name] ??
                      (name == signatureAsset ? 'omanoloneto' : _bot),
                },
              },
          ],
        }),
      ),
      (
        _gh,
        ['api', 'repos/omanoloneto/voges-word/commits/$_tag', '--jq', '.sha'],
      ) =>
        _result(0, stdout: '$remoteCommit\n'),
      (_git, ['-C', _checkout, 'rev-parse', '--verify', '$_tag^{commit}']) =>
        localCommit == null
            ? _result(128, stderr: 'fatal: Needed a single revision')
            : _result(0, stdout: '$localCommit\n'),
      (
        _git,
        [
          '-C',
          _checkout,
          'cat-file',
          '-e',
          '$_tag:./lib/src/release_trust.dart',
        ],
      ) =>
        _result(trustFileAtTag ? 0 : 128),
      (
        _git,
        [
          '-C',
          _checkout,
          'diff',
          '--quiet',
          _tag,
          '--',
          'lib/src/release_trust.dart',
        ],
      ) =>
        _result(sameTrustedKeys ? 0 : 1),
      (
        _gh,
        [
          'attestation',
          'verify',
          final file,
          '--repo',
          'omanoloneto/voges-word',
          '--signer-workflow',
          'omanoloneto/voges-word/.github/workflows/release.yml',
          '--source-ref',
          'refs/tags/$_tag',
          '--source-digest',
          final digest,
          '--deny-self-hosted-runners',
        ],
      ) =>
        attested &&
                digest == localCommit &&
                p.basename(file) == checksumsAsset &&
                File(file).existsSync()
            ? _result(0)
            : _result(1, stderr: 'no attestation matches'),
      (
        _gh,
        [
          'release',
          'download',
          _tag,
          '--repo',
          _,
          '--pattern',
          checksumsAsset,
          '--dir',
          final folder,
        ],
      ) =>
        _download(folder),
      (
        _gh,
        [
          'release',
          'download',
          _tag,
          '--repo',
          _,
          '--pattern',
          checksumsAsset,
          '--pattern',
          signatureAsset,
          '--dir',
          final folder,
        ],
      ) =>
        _download(folder, withSignature: true),
      (_gh, ['release', 'upload', _tag, final path, '--repo', _]) => _upload(
        path,
      ),
      (
        _gh,
        ['release', 'edit', _tag, '--repo', _, '--draft=false', '--latest'],
      ) =>
        _publish(),
      _ => throw StateError('unexpected call: $executable $arguments'),
    };
  }

  @override
  ProcessResult runSync(String executable, List<String> arguments) =>
      throw UnsupportedError('the release tool never runs tools synchronously');

  @override
  Future<Process> start(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
    ProcessStartMode mode = ProcessStartMode.normal,
  }) async {
    calls.add([executable, ...arguments]);
    if (executable != _security || arguments.join(' ') != '-i') {
      throw StateError('unexpected start: $executable $arguments');
    }
    return _InteractiveSecurity((input) {
      interactiveInput.add(input);
      final match = RegExp(
        r'^add-generic-password -a voges -s voges-release-signing -w (\S+)\n$',
      ).firstMatch(input);
      if (match != null && addExitCode == 0) keychain = match[1];
    }, addExitCode);
  }

  ProcessResult _download(String folder, {bool withSignature = false}) {
    downloadFolder = folder;
    File(p.join(folder, checksumsAsset)).writeAsBytesSync(checksums);
    if (withSignature) {
      File(p.join(folder, signatureAsset)).writeAsBytesSync(existingSignature!);
    }
    return _result(0);
  }

  ProcessResult _upload(String path) {
    expect(p.basename(path), signatureAsset);
    expect(draft, isTrue);
    uploaded = File(path).readAsBytesSync();
    return _result(0);
  }

  ProcessResult _publish() {
    expect(uploaded ?? existingSignature, isNotNull);
    published = true;
    draft = false;
    return _result(0);
  }

  static ProcessResult _result(
    int exitCode, {
    String stdout = '',
    String stderr = '',
  }) => ProcessResult(1, exitCode, stdout, stderr);
}

/// `security -i`: reads its commands from stdin.
final class _InteractiveSecurity implements Process {
  _InteractiveSecurity(void Function(String input) onInput, int code) {
    exitCode = utf8.decodeStream(_input.stream).then((input) {
      onInput(input);
      return code;
    });
  }

  final _input = StreamController<List<int>>();

  @override
  late final IOSink stdin = IOSink(_input);

  @override
  late final Future<int> exitCode;

  @override
  Stream<List<int>> get stdout => const Stream.empty();

  @override
  Stream<List<int>> get stderr => const Stream.empty();

  @override
  int get pid => 1;

  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) => false;
}

void main() {
  late _FakeSystem system;
  late StringBuffer out;
  late StringBuffer err;
  late String publicKey;

  setUpAll(() async => publicKey = await publicKeyOf(_seed));

  setUp(() {
    system = _FakeSystem();
    out = StringBuffer();
    err = StringBuffer();
  });

  Future<int> run(
    List<String> arguments, {
    String? gh = _gh,
    List<String>? trustedKeys,
  }) => ReleaseSigning(
    runner: system,
    gh: gh,
    checkout: _checkout,
    verifier: ReleaseVerifier(trustedKeys: trustedKeys ?? [publicKey]),
    out: out,
    err: err,
  ).run(arguments);

  group('init', () {
    test('stores a new key through stdin and prints its public key', () async {
      expect(await run(['init']), 0, reason: '$err');
      final stored = system.keychain!;
      final seed = base64.decode(stored);
      expect(seed, hasLength(32));
      expect(system.interactiveInput, [
        'add-generic-password -a voges -s voges-release-signing -w $stored\n',
      ]);
      expect(system.calls, contains(equals([_security, '-i'])));
      for (final call in system.calls) {
        expect(call.join(' '), isNot(contains(stored)));
      }
      expect('$out', contains(await publicKeyOf(seed)));
      expect('$out$err', isNot(contains(stored)));
    });

    test('makes a different key each time', () async {
      expect(await run(['init']), 0);
      final first = system.keychain;
      system = _FakeSystem();
      expect(await run(['init']), 0);
      expect(system.keychain, isNot(first));
    });

    test('never replaces a key that exists', () async {
      system.keychain = base64.encode(_seed);
      expect(await run(['init']), 1);
      expect('$err', contains('already'));
      expect(system.keychain, base64.encode(_seed));
      expect(system.interactiveInput, isEmpty);
      expect('$out$err', isNot(contains(base64.encode(_seed))));
    });

    test('stops when security fails', () async {
      system.searchExitCode = 51;
      expect(await run(['init']), 1);
      expect(system.interactiveInput, isEmpty);

      system
        ..searchExitCode = 44
        ..addExitCode = 45;
      expect(await run(['init']), 1);
      expect(system.keychain, isNull);
      expect('$out', isEmpty);
    });
  });

  group('public-key', () {
    test('prints the public key of the stored key, never the key', () async {
      system.keychain = base64.encode(_seed);

      expect(await run(['public-key']), 0);
      expect('$out'.trim(), publicKey);
      expect('$out$err', isNot(contains(system.keychain!)));
    });

    test('needs the key', () async {
      expect(await run(['public-key']), 1);
      expect('$err', contains('Run init first'));
    });
  });

  group('publish', () {
    setUp(() => system.keychain = base64.encode(_seed));

    test('signs the draft, uploads the signature and publishes', () async {
      expect(await run(['publish', _repository, _tag]), 0, reason: '$err');
      expect(system.published, isTrue);
      expect(
        await ReleaseVerifier(trustedKeys: [publicKey]).verify(
          repository: _repository,
          version: _version,
          checksums: system.checksums,
          signature: system.uploaded!,
        ),
        hasLength(3),
      );
      expect(system.calls.map((call) => call.take(3).join(' ')), [
        '$_gh release view',
        '$_gh api repos/omanoloneto/voges-word/releases/42',
        '$_git -C $_checkout',
        '$_gh api repos/omanoloneto/voges-word/commits/$_tag',
        '$_git -C $_checkout',
        '$_git -C $_checkout',
        '$_gh release download',
        '$_gh attestation verify',
        '$_security find-generic-password -a',
        '$_gh release upload',
        '$_gh release edit',
      ]);
      expect(Directory(system.downloadFolder!).existsSync(), isFalse);
      expect('$out$err', isNot(contains(system.keychain!)));
    });

    test('finishes a publish that stopped after the upload', () async {
      system
        ..assets = [...system.assets, signatureAsset]
        ..existingSignature = await signChecksums(
          seed: _seed,
          repository: _repository,
          version: _version,
          checksums: system.checksums,
        );

      expect(await run(['publish', _repository, _tag]), 0, reason: '$err');
      expect(system.uploaded, isNull);
      expect(system.published, isTrue);
    });

    test('a dry run signs and checks but changes nothing', () async {
      expect(await run(['publish', _repository, _tag, '--dry-run']), 0);
      expect(system.uploadedOrPublished, isFalse);
      expect('$out', contains('Dry run'));
    });

    test('refuses a key the apps do not trust', () async {
      final other = await publicKeyOf(List.filled(32, 1));
      expect(
        await run(['publish', _repository, _tag], trustedKeys: [other]),
        1,
      );
      expect('$err', contains('releaseSigningKeys'));
      expect(system.uploadedOrPublished, isFalse);
    });

    final refusals = <String, (void Function(_FakeSystem system), String)>{
      'a published release': (
        (system) => system.draft = false,
        'already published',
      ),
      'a signature this key did not make': (
        (system) => system
          ..assets = [...system.assets, signatureAsset]
          ..existingSignature = utf8.encode(
            '${base64.encode(List.filled(64, 7))}\n',
          ),
        'did not make',
      ),
      'a draft another account created': (
        (system) => system.author = 'someone',
        'created by someone',
      ),
      'an installer another account uploaded': (
        (system) => system.uploaders = {_installers.first: 'someone'},
        'uploaded by someone',
      ),
      'a tag that moved on GitHub': (
        (system) => system.remoteCommit = 'f' * 40,
        'on GitHub',
      ),
      'a tag missing from this clone': (
        (system) => system.localCommit = null,
        'not in this clone',
      ),
      'a tag without the trusted keys file': (
        (system) => system.trustFileAtTag = false,
        'has no lib/src/release_trust.dart',
      ),
      'a tag that trusts other keys': (
        (system) => system.sameTrustedKeys = false,
        'release_trust.dart',
      ),
      'checksums the workflow did not attest': (
        (system) => system.attested = false,
        'attestation verify',
      ),
      'a release without an installer': (
        (system) => system.assets = [_installers.first, checksumsAsset],
        'should have exactly',
      ),
      'a release with an extra file': (
        (system) => system.assets = [...system.assets, 'notes.txt'],
        'should have exactly',
      ),
      'checksums of other files': (
        (system) =>
            system.checksums = _sumsOf([..._installers.skip(1), 'other.dmg']),
        'should list exactly',
      ),
      'checksums missing an installer': (
        (system) => system.checksums = _sumsOf(_installers.skip(1)),
        'should list exactly',
      ),
      'malformed checksums': (
        (system) => system.checksums = utf8.encode('not checksums\n'),
        'is malformed',
      ),
      'a Keychain without the key': (
        (system) => system.keychain = null,
        'Run init first',
      ),
      'a Keychain item that is not a key': (
        (system) => system.keychain = base64.encode([1, 2, 3]),
        'not a 32-byte key',
      ),
      'a release gh cannot find': (
        (system) => system.viewExitCode = 1,
        'release not found',
      ),
    };
    for (final MapEntry(key: name, value: (arrange, reason))
        in refusals.entries) {
      test('refuses $name', () async {
        arrange(system);
        expect(await run(['publish', _repository, _tag]), 1);
        expect('$err', contains(reason));
        expect(system.uploadedOrPublished, isFalse);
      });
    }

    test('refuses repositories and tags outside the suite', () async {
      expect(await run(['publish', 'someone/else', _tag]), 1);
      for (final tag in ['1.2.0', 'v1.2', 'v1.2.0-rc1']) {
        expect(await run(['publish', _repository, tag]), 1, reason: tag);
      }
      expect(system.calls, isEmpty);
    });

    test('needs gh', () async {
      expect(await run(['publish', _repository, _tag], gh: null), 1);
      expect('$err', contains('gh'));
      expect(system.calls, isEmpty);
    });
  });

  test('prints the usage for anything else', () async {
    for (final arguments in [
      const <String>[],
      ['init', '--force'],
      ['public-key', 'extra'],
      ['publish', _repository],
      ['publish', _repository, _tag, '--draft'],
      ['sign', _repository, _tag],
    ]) {
      expect(await run(arguments), 64, reason: '$arguments');
    }
    expect('$err', contains('Usage'));
    expect(system.calls, isEmpty);
  });
}
