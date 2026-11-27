/// Version parsing for the OTA update check.
///
/// Kept pure and dependency-free so the comparison can be tested directly.
///
/// Release tags and on-device version names follow SemVer with a `v` prefix
/// and Flutter build metadata: `v1.0.0-rc.1+3001` on GitHub, `1.0.0-rc.1` on
/// the device. Build metadata never counts; a pre-release suffix does, so a
/// release candidate is offered the next candidate and then the release
/// itself: `1.0.0-rc.1 < 1.0.0-rc.2 < 1.0.0`. Anything that cannot be read as
/// a version is treated as "cannot compare" rather than throwing.
library;

/// A parsed version: the three numbers and the pre-release identifiers.
class SemVersion {
  const SemVersion(this.core, this.preRelease);

  /// Major, minor and patch.
  final List<int> core;

  /// The dot-separated identifiers after `-` (`['rc', '1']`), empty for a
  /// release.
  final List<String> preRelease;

  bool get isPreRelease => preRelease.isNotEmpty;

  /// SemVer precedence: negative when this is older than [other].
  int compareTo(SemVersion other) {
    for (var i = 0; i < 3; i++) {
      if (core[i] != other.core[i]) return core[i].compareTo(other.core[i]);
    }
    // A release ranks above every pre-release of the same version.
    if (preRelease.isEmpty || other.preRelease.isEmpty) {
      if (preRelease.isEmpty && other.preRelease.isEmpty) return 0;
      return preRelease.isEmpty ? 1 : -1;
    }
    for (var i = 0; i < preRelease.length && i < other.preRelease.length; i++) {
      final order = _compareIdentifier(preRelease[i], other.preRelease[i]);
      if (order != 0) return order;
    }
    // `rc` < `rc.1`: more identifiers rank higher when the rest are equal.
    return preRelease.length.compareTo(other.preRelease.length);
  }

  /// Numeric identifiers compare as numbers and rank below alphanumeric
  /// ones; alphanumeric ones compare as text (`alpha` < `beta` < `rc`).
  static int _compareIdentifier(String a, String b) {
    final na = int.tryParse(a);
    final nb = int.tryParse(b);
    if (na != null && nb != null) return na.compareTo(nb);
    if (na != null) return -1;
    if (nb != null) return 1;
    return a.compareTo(b);
  }
}

/// Parses [raw] (`1.0.0`, `v1.0.0-rc.1+3001`, `1.2`) into a [SemVersion],
/// padding missing numbers with 0. Returns null when it holds no usable
/// version.
SemVersion? parseSemVersion(String raw) {
  var value = raw.trim();
  if (value.isEmpty) return null;

  if (value.startsWith('v') || value.startsWith('V')) {
    value = value.substring(1);
  }
  value = value.split('+').first.trim();
  final dash = value.indexOf('-');
  final coreText = (dash < 0 ? value : value.substring(0, dash)).trim();
  final preText = dash < 0 ? '' : value.substring(dash + 1).trim();
  // A trailing `-` names no pre-release: not a version.
  if (coreText.isEmpty || (dash >= 0 && preText.isEmpty)) return null;

  final parts = coreText.split('.');
  final core = <int>[];
  for (var i = 0; i < 3; i++) {
    if (i >= parts.length) {
      core.add(0);
      continue;
    }
    final component = int.tryParse(parts[i].trim());
    if (component == null || component < 0) return null;
    core.add(component);
  }

  final preRelease = preText.isEmpty
      ? const <String>[]
      : preText.split('.').map((part) => part.trim()).toList();
  if (dash >= 0 && preRelease.any((part) => part.isEmpty)) return null;
  return SemVersion(core, preRelease);
}

/// Parses [raw] into exactly three numbers, ignoring any pre-release suffix
/// and build metadata. Returns null when it holds no usable version.
List<int>? parseVersion(String raw) => parseSemVersion(raw)?.core;

/// Whether [raw] is a pre-release (`1.0.0-rc.1`). False when unparseable.
bool isPreReleaseVersion(String raw) =>
    parseSemVersion(raw)?.isPreRelease ?? false;

/// Whether [latest] is a strictly newer release than [current], by SemVer
/// precedence: `0.16.1 < 1.0.0-rc.1 < 1.0.0-rc.2 < 1.0.0 < 1.0.1`.
///
/// Returns false when either version is unparseable: an update check that
/// cannot read its own inputs must not offer an update.
bool isNewerVersion(String current, String latest) {
  final currentVersion = parseSemVersion(current);
  final latestVersion = parseSemVersion(latest);
  if (currentVersion == null || latestVersion == null) return false;
  return latestVersion.compareTo(currentVersion) > 0;
}
