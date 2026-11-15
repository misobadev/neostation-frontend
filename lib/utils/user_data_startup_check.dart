import 'package:path/path.dart' as p;

/// Why the user-data folder stored in the settings can't be used at startup.
enum UserDataProblem {
  /// The drive it is on isn't there: an SD card or USB drive that isn't
  /// mounted (yet). It may come back by itself.
  volumeMissing,

  /// The drive is there but the folder isn't: it was moved, renamed or
  /// deleted. Creating it again would open NeoStation on an empty library.
  folderMissing,
}

/// The platforms whose drive layouts [missingUserDataProblem] knows.
enum UserDataPlatform { android, linux, macos, windows }

/// The Android storage volume [path] sits on.
///
/// Android mounts the primary shared storage at `/storage/emulated/<user>`
/// and every removable volume at `/storage/<UUID>`, so the volume is a fixed
/// number of leading segments. `/sdcard` is the historical link to primary
/// shared storage. A path of any other shape is returned as it is.
String androidVolumeRoot(String path) {
  final normalized = p.posix.normalize(path);
  if (normalized == '/sdcard' || normalized.startsWith('/sdcard/')) {
    return '/storage/emulated/0';
  }
  if (!normalized.startsWith('/storage/')) return normalized;
  final segments = p.posix.split(normalized);
  // p.split('/storage/emulated/0/roms') -> ['/', 'storage', 'emulated', '0', …]
  final wanted = segments.length > 2 && segments[2] == 'emulated' ? 4 : 3;
  if (segments.length < wanted) return normalized;
  return p.posix.joinAll(segments.take(wanted));
}

/// Whether [path] is on a removable Android volume (an SD card or USB drive),
/// not primary shared storage.
bool isAndroidRemovableVolume(String path) {
  final root = androidVolumeRoot(path);
  return root.startsWith('/storage/') &&
      !root.startsWith('/storage/emulated') &&
      root != '/storage/self';
}

/// Where Linux desktops mount drives that come and go: udisks
/// (`/media/<user>/<label>`, `/run/media/<user>/<label>`, and SteamOS's
/// `/run/media/<device>`), and the usual places for fstab mounts.
const _linuxRemovableAreas = ['/media', '/run/media', '/mnt', '/var/mnt'];

/// The mount points listed in `/proc/self/mounts` (or `/etc/mtab`): the
/// second field of each line, with the kernel's octal escapes for spaces,
/// tabs, newlines and backslashes undone.
Set<String> parseMountPoints(String mounts) => {
  for (final line in mounts.split('\n'))
    if (line.trim().split(RegExp(r'\s+')) case [_, final point, ...])
      _unescapeMount(point),
};

/// The mount points in `/etc/fstab`, comments and swap left out.
Set<String> parseFstabMountPoints(String fstab) => {
  for (final line in fstab.split('\n'))
    if (!line.trimLeft().startsWith('#'))
      if (line.trim().split(RegExp(r'\s+')) case [_, final point, ...])
        if (point.startsWith('/')) _unescapeMount(point),
};

String _unescapeMount(String field) => field.replaceAllMapped(
  RegExp(r'\\([0-7]{3})'),
  (m) => String.fromCharCode(int.parse(m[1]!, radix: 8)),
);

/// What is missing when the user-data [folder] isn't there: the drive it is
/// on, or the folder itself.
///
/// [exists] says whether a path exists. On Linux, [mountPoints] are the
/// file systems mounted now and [fstabMountPoints] those set up to be
/// mounted: a folder below a mount point that isn't mounted, or in one of the
/// places removable drives are mounted, is on a missing drive even when the
/// empty mount-point folder is still there. [isDanglingLink] says whether a
/// path is a symbolic link to something that isn't there (a link into a
/// drive that isn't mounted).
///
/// On Android a folder on no known volume is judged by its parent, as
/// before: a missing parent is taken for a volume still mounting.
Future<UserDataProblem> missingUserDataProblem(
  String folder,
  UserDataPlatform platform, {
  required Future<bool> Function(String path) exists,
  Set<String> mountPoints = const {},
  Set<String> fstabMountPoints = const {},
  Future<bool> Function(String path)? isDanglingLink,
}) async {
  Future<UserDataProblem> byRoot(String root) async => await exists(root)
      ? UserDataProblem.folderMissing
      : UserDataProblem.volumeMissing;

  switch (platform) {
    case UserDataPlatform.windows:
      final root = p.windows.rootPrefix(folder);
      return root.isEmpty ? UserDataProblem.folderMissing : byRoot(root);
    case UserDataPlatform.android:
      final root = androidVolumeRoot(folder);
      if (root != p.posix.normalize(folder) || root.startsWith('/storage/')) {
        return byRoot(root);
      }
      return byRoot(p.posix.dirname(folder));
    case UserDataPlatform.macos:
      final parts = p.posix.split(p.posix.normalize(folder));
      if (await _anyDanglingLink(parts, isDanglingLink)) {
        return UserDataProblem.volumeMissing;
      }
      if (parts.length > 2 && parts[1] == 'Volumes') {
        return byRoot(p.posix.joinAll(parts.take(3)));
      }
      return UserDataProblem.folderMissing;
    case UserDataPlatform.linux:
      final normalized = p.posix.normalize(folder);
      final parts = p.posix.split(normalized);
      if (await _anyDanglingLink(parts, isDanglingLink)) {
        return UserDataProblem.volumeMissing;
      }
      // Within a removable area, only a mount point below the area's root is
      // a drive: the area itself can be a mount (a Flatpak's bind mount of
      // /run/media, a /mnt of its own).
      final area = _linuxRemovableAreas
          .where((area) => p.posix.isWithin(area, normalized))
          .firstOrNull;
      final lowest = area == null ? 1 : p.posix.split(area).length;
      // The nearest mount point above the folder decides: mounted, the drive
      // is there; set up in fstab but not mounted, it isn't.
      for (var n = parts.length; n > lowest; n--) {
        final ancestor = p.posix.joinAll(parts.take(n));
        if (mountPoints.contains(ancestor)) {
          return UserDataProblem.folderMissing;
        }
        if (fstabMountPoints.contains(ancestor)) {
          return UserDataProblem.volumeMissing;
        }
      }
      return area != null
          ? UserDataProblem.volumeMissing
          : UserDataProblem.folderMissing;
  }
}

Future<bool> _anyDanglingLink(
  List<String> parts,
  Future<bool> Function(String path)? isDanglingLink,
) async {
  if (isDanglingLink == null) return false;
  for (var n = 2; n <= parts.length; n++) {
    if (await isDanglingLink(p.posix.joinAll(parts.take(n)))) return true;
  }
  return false;
}
