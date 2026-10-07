import 'package:path/path.dart' as p;

/// Containment checks for file names that come from outside the app.
///
/// Servers (NeoSync, RomM, NeoAssets, ScreenScraper) and archives supply the
/// names of the files we write, and `path.join` trusts them completely: an
/// absolute name replaces the root outright and `..` walks out of it. These
/// helpers refuse any name that would land outside the intended directory.
///
/// Both `/` and `\` count as separators on every platform. A name built for
/// Windows must not slip past a check that only knows POSIX separators (and
/// then escape when Windows joins it), and a backslash is never part of a
/// genuine save, ROM or asset name.

final RegExp _driveLetter = RegExp(r'^[A-Za-z]:');

/// Resolves [untrusted] — a file name or relative path supplied by a server,
/// catalog or archive — under [root], or returns null if it would land
/// anywhere else.
///
/// Refused: empty names, absolute paths (`/x`, `\x`, `\\server\share`, `C:x`),
/// and any `..` segment, even one that would stay inside [root]. `.` and empty
/// segments are dropped. The result is a normalised path strictly inside
/// [root]; [root] itself is never returned.
String? safeJoin(String root, String untrusted, {p.Context? context}) {
  final ctx = context ?? p.context;
  final relative = untrusted.replaceAll('\\', '/');
  if (relative.isEmpty ||
      relative.startsWith('/') ||
      _driveLetter.hasMatch(relative)) {
    return null;
  }
  final segments = relative.split('/').where((s) => s.isNotEmpty && s != '.');
  if (segments.isEmpty || segments.contains('..')) return null;

  final base = ctx.normalize(ctx.absolute(root));
  final resolved = ctx.normalize(ctx.joinAll([base, ...segments]));
  return ctx.isWithin(base, resolved) ? resolved : null;
}

/// Whether [name] is a single, ordinary file or folder name: not empty, not
/// `.` or `..`, no `/` or `\`, and no drive prefix.
bool isSafeFileName(String name) =>
    name.isNotEmpty &&
    name != '.' &&
    name != '..' &&
    !name.contains('/') &&
    !name.contains('\\') &&
    !_driveLetter.hasMatch(name);
