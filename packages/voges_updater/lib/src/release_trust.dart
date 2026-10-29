/// Public Ed25519 keys (base64) that sign the Voges releases. A list, so a
/// new key can be added before the old one is retired.
const releaseSigningKeys = <String>[
  // created on 2026-10-29; the private key is in the owner's login Keychain
  'nW7yqL9fJaQ3zrkEfOPptjWrNrjW7bP5Vi9LTGrp+g0=',
];

const _testOriginDefine = String.fromEnvironment('VOGES_UPDATE_TEST_ORIGIN');
const _testKeyDefine = String.fromEnvironment('VOGES_UPDATE_TEST_KEY');

/// The loopback origin of a test build (`--dart-define`), or null.
Uri? get testOrigin => parseTestOrigin(_testOriginDefine);

/// [releaseSigningKeys], or the test key of a test build.
List<String> get trustedReleaseKeys =>
    testOrigin != null && _testKeyDefine.isNotEmpty
    ? const [_testKeyDefine]
    : releaseSigningKeys;

/// [value] when it is exactly `http://127.0.0.1:<port>`; null for anything
/// else, so a test build can only ever be pointed at this computer.
Uri? parseTestOrigin(String value) {
  final match = _loopbackOrigin.firstMatch(value);
  if (match == null || int.parse(match[1]!) > 65535) return null;
  return Uri.parse(value);
}

final _loopbackOrigin = RegExp(r'^http://127\.0\.0\.1:([1-9][0-9]{0,4})$');
