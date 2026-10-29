import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:voges_updater/core.dart';

import '../tool/release_signing.dart';

const _repository = 'omanoloneto/voges-word';
const _version = ReleaseVersion(1, 2, 0);
final _seed = List.filled(32, 7);
final _otherSeed = List.filled(32, 9);

final _hashA = 'a' * 64;
final _hashB = '0123456789abcdef' * 4;

Uint8List _sums(String text) => utf8.encode(text);

final _checksums = _sums(
  '$_hashA  VogesWord-macos.dmg\n$_hashB  voges-word-linux-amd64.deb\n',
);

Matcher get _verificationFailure => throwsA(
  isA<UpdateFailure>().having(
    (f) => f.kind,
    'kind',
    UpdateFailureKind.verification,
  ),
);

void main() {
  group('parseChecksums', () {
    test('reads the lines of sha256sum', () {
      expect(parseChecksums(utf8.decode(_checksums)), {
        'VogesWord-macos.dmg': _hashA,
        'voges-word-linux-amd64.deb': _hashB,
      });
    });

    test('accepts CRLF and skips empty lines', () {
      expect(parseChecksums('\r\n$_hashA  a.dmg\r\n\n$_hashB  b.deb\r\n'), {
        'a.dmg': _hashA,
        'b.deb': _hashB,
      });
      expect(parseChecksums(''), isEmpty);
    });

    test('has no entry for a file it does not list', () {
      expect(parseChecksums('$_hashA  a.dmg\n')['b.deb'], isNull);
    });

    final malformed = {
      'uppercase hex': '${'A' * 64}  a.dmg',
      'a short hash': '${'a' * 63}  a.dmg',
      'one space': '$_hashA a.dmg',
      'the binary marker': '$_hashA *a.dmg',
      'a path': '$_hashA  dir/a.dmg',
      'a parent folder': '$_hashA  ../a.dmg',
      'a space in the name': '$_hashA  a b.dmg',
      'trailing spaces': '$_hashA  a.dmg ',
      'a blank line with spaces': '$_hashA  a.dmg\n  \n',
      'a lone carriage return': '$_hashA  a.dmg\r\r\n',
      'a byte order mark': '﻿$_hashA  a.dmg',
      'a duplicate name': '$_hashA  a.dmg\n$_hashB  a.dmg\n',
    };
    for (final MapEntry(key: name, value: text) in malformed.entries) {
      test('rejects $name', () {
        expect(() => parseChecksums(text), throwsFormatException);
      });
    }
  });

  test('the signed message binds repository and tag to the checksums', () {
    expect(
      utf8.decode(signedMessage(_repository, _version, _sums('sums\n'))),
      'voges-release v1\n'
      'repository omanoloneto/voges-word\n'
      'tag v1.2.0\n'
      'sums\n',
    );
  });

  group('verify', () {
    late String key;
    late Uint8List signature;

    setUpAll(() async {
      key = await publicKeyOf(_seed);
      signature = await signChecksums(
        seed: _seed,
        repository: _repository,
        version: _version,
        checksums: _checksums,
      );
    });

    Future<Map<String, String>> verify({
      List<String>? keys,
      String repository = _repository,
      ReleaseVersion version = _version,
      Uint8List? checksums,
      Uint8List? signatureFile,
    }) => ReleaseVerifier(trustedKeys: keys ?? [key]).verify(
      repository: repository,
      version: version,
      checksums: checksums ?? _checksums,
      signature: signatureFile ?? signature,
    );

    String signatureText() => ascii.decode(signature).trimRight();

    test(
      'returns the checksums of a release signed by a trusted key',
      () async {
        expect(await verify(), parseChecksums(utf8.decode(_checksums)));
        expect(signature.last, 0x0a);
      },
    );

    test('accepts the signature without its trailing newline', () async {
      expect(
        await verify(signatureFile: ascii.encode(signatureText())),
        hasLength(2),
      );
    });

    test('trusts any of the keys, so a key can be rotated', () async {
      final other = await publicKeyOf(_otherSeed);
      expect(await verify(keys: [other, key]), hasLength(2));
    });

    test('rejects a release signed by another key', () async {
      await expectLater(
        verify(keys: [await publicKeyOf(_otherSeed)]),
        _verificationFailure,
      );
    });

    test('rejects altered checksums', () async {
      final altered = Uint8List.fromList(_checksums)..[0] ^= 0x01;
      await expectLater(verify(checksums: altered), _verificationFailure);
    });

    test('rejects the signature of another repository or tag', () async {
      await expectLater(
        verify(repository: 'omanoloneto/voges-sheets'),
        _verificationFailure,
      );
      await expectLater(
        verify(version: const ReleaseVersion(1, 2, 1)),
        _verificationFailure,
      );
    });

    final malformed = <String, Uint8List Function(String text)>{
      'a missing signature': (_) => Uint8List(0),
      'text that is not base64': (_) => ascii.encode('${'!' * 86}==\n'),
      'URL-safe base64': (text) =>
          ascii.encode(text.replaceAll('+', '-').replaceAll('/', '_')),
      'base64 without padding': (text) =>
          ascii.encode(text.replaceAll('=', '')),
      '63 bytes': (_) => ascii.encode(base64.encode(List.filled(63, 1))),
      '65 bytes': (_) => ascii.encode(base64.encode(List.filled(65, 1))),
      'a CRLF ending': (text) => ascii.encode('$text\r\n'),
      'two newlines': (text) => ascii.encode('$text\n\n'),
      'leading spaces': (text) => ascii.encode(' $text'),
      'the raw 64 bytes': (text) => base64.decode(text),
    };
    for (final MapEntry(key: name, value: make) in malformed.entries) {
      test('rejects $name', () async {
        final file = make(signatureText());
        expect(file, isNot(signature));
        await expectLater(verify(signatureFile: file), _verificationFailure);
      });
    }

    test('fails closed without trusted keys', () async {
      await expectLater(verify(keys: const []), _verificationFailure);
    });

    test('rejects a trusted key that is not 32 bytes of base64', () async {
      for (final bad in [
        base64.encode(List.filled(31, 1)),
        'not a key',
        key.substring(0, 43),
      ]) {
        await expectLater(verify(keys: [bad]), _verificationFailure);
      }
    });

    test('rejects signed checksums that are malformed', () async {
      final duplicated = _sums('$_hashA  a.dmg\n$_hashB  a.dmg\n');
      await expectLater(
        verify(
          checksums: duplicated,
          signatureFile: await signChecksums(
            seed: _seed,
            repository: _repository,
            version: _version,
            checksums: duplicated,
          ),
        ),
        _verificationFailure,
      );
    });

    test('a build without test defines trusts only the pinned keys', () async {
      expect(trustedReleaseKeys, releaseSigningKeys);
      expect(ReleaseVerifier().trustedKeys, releaseSigningKeys);
      await expectLater(
        ReleaseVerifier().verify(
          repository: _repository,
          version: _version,
          checksums: _checksums,
          signature: signature,
        ),
        _verificationFailure,
      );
    });
  });

  test('every pinned key is 32 bytes of standard base64', () {
    for (final key in releaseSigningKeys) {
      expect(base64.encode(base64.decode(key)), key);
      expect(base64.decode(key), hasLength(32));
    }
  });
}
