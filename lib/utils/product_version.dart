/// A product version as the release policy defines it: `X.Y.Z`, optionally with
/// a `-rc.N` candidate suffix.
///
/// Two things are deliberately not part of it:
///
///  * the `+B` build number. It is global history, not a version, and one
///    product version ships under many of them (CLAUDE.md → Releasing);
///  * a leading `android-` or `v`. Release *tags* carry them
///    (`android-v1.0.0-rc.1+3`, `v1.0.1-rc.2+5`), pubspec and release names do
///    not.
///
/// The ordering puts a candidate below the version it leads to, which is what
/// makes the update check behave: nobody running `1.0.1` is offered `1.0.1-rc.2`,
/// while everybody on a candidate is offered the `1.0.1` it led to.
class ProductVersion implements Comparable<ProductVersion> {
  const ProductVersion(this.major, this.minor, this.patch, [this.candidate]);

  final int major;
  final int minor;
  final int patch;

  /// The `N` of a `-rc.N` suffix, or null for a stable release.
  final int? candidate;

  // The whole grammar in one anchored pattern, deliberately strict: `android-`
  // and `v` are how release tags are spelled, `-rc.N` is the candidate suffix,
  // and `+B` is the build number. The build number is not part of the version,
  // but it *is* part of what we accept — so that `1.0.1+` is refused rather than
  // read as `1.0.1`, which is what the release tooling does with it too.
  static final RegExp _shape = RegExp(
    r'^(?:android-)?v?([0-9]+)\.([0-9]+)\.([0-9]+)(?:-rc\.([0-9]+))?(?:\+[0-9]+)?$',
  );

  /// Parses a version, a release name or a release tag.
  ///
  /// Returns null for anything else: a shape this does not know is a shape we
  /// may not act on, and a wrong "an update is available" is worse than none.
  static ProductVersion? tryParse(String raw) {
    final match = _shape.firstMatch(raw.trim());
    if (match == null) {
      return null;
    }
    final major = int.tryParse(match.group(1)!);
    final minor = int.tryParse(match.group(2)!);
    final patch = int.tryParse(match.group(3)!);
    if (major == null || minor == null || patch == null) {
      return null;
    }
    final candidate = match.group(4);
    return ProductVersion(major, minor, patch, candidate == null ? null : int.tryParse(candidate));
  }

  /// True when this version is strictly newer than [other].
  bool isNewerThan(ProductVersion other) => compareTo(other) > 0;

  @override
  int compareTo(ProductVersion other) {
    if (major != other.major) return major.compareTo(other.major);
    if (minor != other.minor) return minor.compareTo(other.minor);
    if (patch != other.patch) return patch.compareTo(other.patch);
    // Same X.Y.Z: the stable release outranks every candidate of it, and
    // candidates order among themselves by their number.
    if (candidate == other.candidate) return 0;
    if (candidate == null) return 1;
    if (other.candidate == null) return -1;
    return candidate!.compareTo(other.candidate!);
  }

  @override
  bool operator ==(Object other) =>
      other is ProductVersion &&
      other.major == major &&
      other.minor == minor &&
      other.patch == patch &&
      other.candidate == candidate;

  @override
  int get hashCode => Object.hash(major, minor, patch, candidate);

  @override
  String toString() =>
      '$major.$minor.$patch${candidate == null ? '' : '-rc.$candidate'}';
}
