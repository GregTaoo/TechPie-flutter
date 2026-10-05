/// A product version — the number a user sees (`X.Y.Z`, optionally an `-rc.N`
/// candidate) together with the `+B` build number that tells two builds of one
/// version apart (CLAUDE.md → Releasing).
///
/// Unlike the release *name*, this keeps the build number: our own policy ships
/// many builds of a single `X.Y.Z` (`+B` is one global, never-reused counter), so
/// two builds of the same version must compare unequal or an in-app update check on
/// `1.0.1+12` would call `1.0.1+13` "the same version". The build number is
/// the last tiebreak; the version itself still compares first.
///
/// A leading `android-` or `v` is how release *tags* are spelled
/// (`android-v1.0.0-rc.1+3`, `v1.0.1-rc.2+5`) and is not part of the version.
///
/// The ordering puts a candidate below the version it leads to, which is what makes
/// the update check: nobody running `1.0.1` is offered `1.0.1-rc.2`, while
/// everybody on a candidate is offered the `1.0.1` it led to.
class ProductVersion implements Comparable<ProductVersion> {
  const ProductVersion(this.major, this.minor, this.patch, [this.candidate, this.build]);

  final int major;
  final int minor;
  final int patch;

  /// The `N` of an `-rc.N` suffix, or null for a stable release.
  final int? candidate;

  /// The `B` of a `+B` build number, or null when the shape carried none.
  final int? build;

  // The whole grammar in one anchored pattern, deliberately strict: `android-`
  // and `v` are how release tags are spelled, `-rc.N` is the candidate suffix,
  // and `+B` is the build number. `+` with no number is refused — it is what
  // the release tooling would also reject — so that `1.0.1+` cannot read as
  // `1.0.1`.
  static final RegExp _shape = RegExp(
    r'^(?:android-)?v?([0-9]+)\.([0-9]+)\.([0-9]+)(?:-rc\.([0-9]+))?(?:\+([0-9]+))?$',
  );

  /// Parses a version, a release name or a release tag.
  ///
  /// Returns null for anything else: a shape this does not know is a shape we may
  /// not act on, and a wrong "an update is available" is worse than none.
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
    return ProductVersion(
      major,
      minor,
      patch,
      int.tryParse(match.group(4) ?? ''),
      int.tryParse(match.group(5) ?? ''),
    );
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
    if (candidate != other.candidate) {
      if (candidate == null) return 1;
      if (other.candidate == null) return -1;
      return candidate!.compareTo(other.candidate!);
    }
    // Same version and release shape, so the build number decides. When a shape
    // carried no `+B` we cannot say one build is above another — and inventing an
    // order could offer a build the user already has — so they compare equal.
    if (build == null || other.build == null) return 0;
    return build!.compareTo(other.build!);
  }

  @override
  bool operator ==(Object other) =>
      other is ProductVersion &&
      other.major == major &&
      other.minor == minor &&
      other.patch == patch &&
      other.candidate == candidate &&
      other.build == build;

  @override
  int get hashCode => Object.hash(major, minor, patch, candidate, build);

  @override
  String toString() =>
      '$major.$minor.$patch${candidate == null ? '' : '-rc.$candidate'}';
}
