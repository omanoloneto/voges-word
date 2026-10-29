import 'package:flutter_test/flutter_test.dart';
import 'package:voges_updater/core.dart';

void main() {
  test('parses major.minor.patch', () {
    expect(ReleaseVersion.tryParse('1.2.3'), const ReleaseVersion(1, 2, 3));
    expect(ReleaseVersion.tryParse('0.0.0'), const ReleaseVersion(0, 0, 0));
    expect(
      ReleaseVersion.tryParse('9999.9999.9999'),
      const ReleaseVersion(9999, 9999, 9999),
    );
  });

  test('rejects anything else', () {
    for (final text in [
      '',
      '1',
      '1.2',
      '1.2.3.4',
      '01.2.3',
      '1.02.3',
      '1.2.03',
      '1.2.3-beta',
      '1.2.3+4',
      'v1.2.3',
      ' 1.2.3',
      '1.2.3 ',
      '1.2.3\n',
      '10000.0.0',
      '-1.2.3',
      '1..3',
      '١.٢.٣',
    ]) {
      expect(ReleaseVersion.tryParse(text), isNull, reason: text);
    }
  });

  test('parses release tags only with a lowercase v', () {
    expect(ReleaseVersion.tryParseTag('v1.2.3'), const ReleaseVersion(1, 2, 3));
    for (final tag in ['1.2.3', 'V1.2.3', 'vv1.2.3', 'v1.2', 'v1.2.3-rc1']) {
      expect(ReleaseVersion.tryParseTag(tag), isNull, reason: tag);
    }
  });

  test('writes itself back as it was parsed', () {
    const version = ReleaseVersion(1, 10, 0);
    expect('$version', '1.10.0');
    expect(version.tag, 'v1.10.0');
    expect(ReleaseVersion.tryParseTag(version.tag), version);
  });

  test('compares numerically, not as text', () {
    const older = ReleaseVersion(1, 9, 9);
    const newer = ReleaseVersion(1, 10, 0);
    expect(newer.isNewerThan(older), isTrue);
    expect(older.isNewerThan(newer), isFalse);
    expect(newer.isNewerThan(newer), isFalse);
    expect(
      const ReleaseVersion(
        2,
        0,
        0,
      ).isNewerThan(const ReleaseVersion(1, 99, 99)),
      isTrue,
    );
    expect(
      const ReleaseVersion(1, 2, 4).isNewerThan(const ReleaseVersion(1, 2, 3)),
      isTrue,
    );
    expect([newer, const ReleaseVersion(0, 1, 0), older]..sort(), [
      const ReleaseVersion(0, 1, 0),
      older,
      newer,
    ]);
  });

  test('is equal by value', () {
    expect(ReleaseVersion.tryParse('1.2.3'), const ReleaseVersion(1, 2, 3));
    expect(
      ReleaseVersion.tryParse('1.2.3').hashCode,
      const ReleaseVersion(1, 2, 3).hashCode,
    );
    expect(const ReleaseVersion(1, 2, 3), isNot(const ReleaseVersion(1, 2, 4)));
  });
}
