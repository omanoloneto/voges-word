/// Public Ed25519 keys (base64) that sign the Voges releases. A list, so a
/// new key can be added before the old one is retired.
const releaseSigningKeys = <String>[];

/// The loopback origin of a test build (`--dart-define`), or null.
Uri? get testOrigin => throw UnimplementedError();

/// [releaseSigningKeys], or the test key of a test build.
List<String> get trustedReleaseKeys => throw UnimplementedError();
