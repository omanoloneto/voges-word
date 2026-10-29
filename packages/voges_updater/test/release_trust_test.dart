import 'package:flutter_test/flutter_test.dart';
import 'package:voges_updater/core.dart';

void main() {
  test('accepts only http://127.0.0.1:<port> as the test origin', () {
    for (final origin in [
      'http://127.0.0.1:8765',
      'http://127.0.0.1:1',
      'http://127.0.0.1:65535',
    ]) {
      expect(parseTestOrigin(origin), Uri.parse(origin), reason: origin);
    }
    for (final origin in [
      '',
      'http://127.0.0.1',
      'http://127.0.0.1:',
      'http://127.0.0.1:0',
      'http://127.0.0.1:65536',
      'http://127.0.0.1:08765',
      'http://127.0.0.1:8765/',
      'http://127.0.0.1:8765/owner/repo',
      'http://127.0.0.1:8765?x=1',
      'http://127.0.0.1:8765\n',
      ' http://127.0.0.1:8765',
      'https://127.0.0.1:8765',
      'HTTP://127.0.0.1:8765',
      'http://localhost:8765',
      'http://127.0.0.2:8765',
      'http://[::1]:8765',
      'http://user@127.0.0.1:8765',
      'http://127.0.0.1.example.com:8765',
      'https://github.com',
    ]) {
      expect(parseTestOrigin(origin), isNull, reason: origin);
    }
  });

  test('a build without the defines has no test origin', () {
    expect(testOrigin, isNull);
    expect(trustedReleaseKeys, same(releaseSigningKeys));
  });
}
