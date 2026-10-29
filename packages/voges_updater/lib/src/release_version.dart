/// A published version, `major.minor.patch` only: pre-releases and build
/// metadata are never offered as updates.
final class ReleaseVersion implements Comparable<ReleaseVersion> {
  const ReleaseVersion(this.major, this.minor, this.patch);

  final int major;
  final int minor;
  final int patch;

  static final _pattern = RegExp(
    r'^(0|[1-9]\d{0,3})\.(0|[1-9]\d{0,3})\.(0|[1-9]\d{0,3})$',
  );

  /// Parses `1.2.3`; null for anything else, such as `1.2`, `01.2.3` or
  /// `1.2.3-beta`.
  static ReleaseVersion? tryParse(String text) {
    final match = _pattern.firstMatch(text);
    if (match == null) return null;
    return ReleaseVersion(
      int.parse(match.group(1)!),
      int.parse(match.group(2)!),
      int.parse(match.group(3)!),
    );
  }

  /// Parses a release tag such as `v1.2.3`.
  static ReleaseVersion? tryParseTag(String tag) =>
      tag.startsWith('v') ? tryParse(tag.substring(1)) : null;

  String get tag => 'v$this';

  bool isNewerThan(ReleaseVersion other) => compareTo(other) > 0;

  @override
  int compareTo(ReleaseVersion other) {
    if (major != other.major) return major.compareTo(other.major);
    if (minor != other.minor) return minor.compareTo(other.minor);
    return patch.compareTo(other.patch);
  }

  @override
  bool operator ==(Object other) =>
      other is ReleaseVersion &&
      other.major == major &&
      other.minor == minor &&
      other.patch == patch;

  @override
  int get hashCode => Object.hash(major, minor, patch);

  @override
  String toString() => '$major.$minor.$patch';
}
