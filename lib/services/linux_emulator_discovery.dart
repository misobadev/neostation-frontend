import 'dart:io';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:path/path.dart' as p;

import 'logger_service.dart';

/// Locates emulator executables on Linux and SteamOS without asking the user to
/// hunt for them in a file picker.
///
/// On Linux an emulator is almost never a plain binary sitting next to the
/// frontend. It is usually one of:
///
/// - an **EmuDeck launcher script** in `<Emulation>/tools/launchers/*.sh`, which
///   wraps whatever EmuDeck actually installed (a Flatpak for RetroArch and
///   Dolphin, a bare AppImage for Azahar, DuckStation, PCSX2…) and forwards
///   `"$@"` to it. This is the only entry point that is uniform across those
///   cases, which is why it is tried first;
/// - a **Flatpak export wrapper** at `…/flatpak/exports/bin/<app-id>`;
/// - a distro package on `PATH`;
/// - an **AppImage** dropped in `~/Applications`.
///
/// The per-emulator knowledge (Flatpak app id, launcher script name) lives in
/// the systems JSON under `platforms.linux`, not here, so it can be corrected by
/// a systems update instead of an app release:
///
/// ```json
/// "linux": {
///   "executable": "dolphin",
///   "flatpak": "org.DolphinEmu.dolphin-emu",
///   "emudeck_launcher": "dolphin-emu.sh",
///   "args": "-e \"{file.path}\""
/// }
/// ```
///
/// Everything here is a read-only probe of paths the user already has; nothing
/// is installed, written, or executed during discovery.
class LinuxEmulatorDiscovery {
  LinuxEmulatorDiscovery._();

  static final _log = LoggerService.instance;

  /// Resolved executables, keyed by the hints that produced them.
  static final Map<String, String?> _resolveCache = {};

  /// Resolved EmuDeck `tools/launchers` directory (`null` = probed, not found).
  static String? _launchersDir;
  static bool _launchersDirProbed = false;

  /// Clears every cached probe result.
  ///
  /// Discovery caches aggressively because a single emulator-list rebuild asks
  /// about dozens of emulators. Call this after the user installs something or
  /// changes an emulator path so the next lookup re-probes the filesystem.
  static void invalidateCache() {
    _resolveCache.clear();
    _launchersDir = null;
    _launchersDirProbed = false;
  }

  /// Stands in for the host platform under test.
  ///
  /// Discovery is Linux-only in production, but its resolution order is pure
  /// path probing and has to be exercisable on any CI host (macOS included).
  @visibleForTesting
  static bool linuxOverride = false;

  static bool get _isLinux => linuxOverride || Platform.isLinux;

  /// Resolves an absolute, existing path to an emulator executable, or `null`
  /// when none of the known locations hold it.
  ///
  /// [executable] is the bare name from the systems JSON (`retroarch`,
  /// `azahar.AppImage`); [flatpakId] and [emudeckLauncher] are the optional
  /// hints from the same block. Returning `null` is a real answer — the caller
  /// should keep whatever the user configured rather than substitute a guess.
  static Future<String?> resolveExecutable({
    String? executable,
    String? flatpakId,
    String? emudeckLauncher,
  }) async {
    if (!_isLinux) return null;

    final cacheKey = '$executable|$flatpakId|$emudeckLauncher';
    if (_resolveCache.containsKey(cacheKey)) return _resolveCache[cacheKey];

    // Discovery runs inside the launch path and is only ever an optimisation
    // over asking the user for a path, so a probe that fails for a reason we
    // did not anticipate must degrade to "not found" rather than take the
    // launch down with it.
    String? resolved;
    try {
      resolved = await _resolve(
        executable: executable,
        flatpakId: flatpakId,
        emudeckLauncher: emudeckLauncher,
      );
    } catch (e) {
      _log.w('LinuxEmulatorDiscovery: probe for "$executable" failed: $e');
      resolved = null;
    }

    if (resolved != null) {
      _log.i(
        'LinuxEmulatorDiscovery: resolved '
        '"${executable ?? flatpakId ?? emudeckLauncher}" to $resolved',
      );
    }
    _resolveCache[cacheKey] = resolved;
    return resolved;
  }

  static Future<String?> _resolve({
    String? executable,
    String? flatpakId,
    String? emudeckLauncher,
  }) async {
    // 1. EmuDeck launcher script. Preferred over probing the Flatpak or the
    //    AppImage directly: the script also applies EmuDeck's own per-emulator
    //    setup (save-sync hooks, netplay flags) that a raw invocation skips.
    if (emudeckLauncher != null && emudeckLauncher.isNotEmpty) {
      final dir = await _emuDeckLaunchersDir();
      if (dir != null) {
        final script = p.join(dir, emudeckLauncher);
        if (await _isRunnable(script)) return script;
      }
    }

    // 2. Flatpak export wrapper, user installation before system-wide.
    if (flatpakId != null && flatpakId.isNotEmpty) {
      for (final dir in _flatpakExportBinDirs()) {
        final wrapper = p.join(dir, flatpakId);
        if (await _isRunnable(wrapper)) return wrapper;
      }
    }

    if (executable == null || executable.isEmpty) return null;

    // 3. An absolute path in the JSON is authoritative when it exists.
    if (p.isAbsolute(executable)) {
      return await _isRunnable(executable) ? executable : null;
    }

    // 4. PATH, then the usual system locations for distro packages.
    for (final dir in _binarySearchDirs()) {
      final candidate = p.join(dir, executable);
      if (await _isRunnable(candidate)) return candidate;
    }

    // 5. AppImages. EmuDeck drops these in ~/Applications under names that
    //    carry a version suffix (`Azahar-2120.AppImage`), so match by prefix
    //    the same way EmuDeck's own launchers do.
    return await _findAppImage(executable);
  }

  // ── EmuDeck layout ─────────────────────────────────────────────────────────

  /// Locates EmuDeck's `tools/launchers` directory.
  ///
  /// EmuDeck records the user's chosen install root in
  /// `~/.config/EmuDeck/settings.sh`, which matters because the Deck's
  /// `Emulation` folder is frequently on the SD card rather than in `$HOME`.
  /// The declared path wins; the documented defaults are only fallbacks.
  static Future<String?> _emuDeckLaunchersDir() async {
    if (_launchersDirProbed) return _launchersDir;
    _launchersDirProbed = true;

    final candidates = <String>[];

    final settings = await _readEmuDeckSettings();
    final toolsPath = settings['toolsPath'];
    if (toolsPath != null) candidates.add(p.join(toolsPath, 'launchers'));
    final emulationPath = settings['emulationPath'];
    if (emulationPath != null) {
      candidates.add(p.join(emulationPath, 'tools', 'launchers'));
    }

    final home = _home();
    if (home != null) {
      candidates.add(p.join(home, 'Emulation', 'tools', 'launchers'));
    }

    for (final dir in candidates) {
      if (await _dirExists(dir)) return _rememberLaunchersDir(dir);
    }

    // Only if none of the recorded or default locations answered: SteamOS
    // mounts removable media under /run/media, either directly or nested under
    // the user name depending on the OS version. Searching it is a last resort
    // because it walks mount points belonging to other users.
    for (final dir in await _globEmulationRoots(removableMediaRoot)) {
      return _rememberLaunchersDir(dir);
    }
    return null;
  }

  /// Where removable media is mounted. Overridable so the scan — including the
  /// unreadable-mount case that a real Deck has — can be exercised against a
  /// fixture tree instead of the host's actual `/run/media`.
  @visibleForTesting
  static String removableMediaRoot = '/run/media';

  static String _rememberLaunchersDir(String dir) {
    _log.i('LinuxEmulatorDiscovery: EmuDeck launchers at $dir');
    _launchersDir = dir;
    return dir;
  }

  /// Parses the `key=value` assignments EmuDeck writes to its settings file.
  ///
  /// This is a shell script, but the path entries are plain assignments, so a
  /// line scan is enough — and far safer than sourcing it.
  static Future<Map<String, String>> _readEmuDeckSettings() async {
    final home = _home();
    if (home == null) return const {};

    final file = File(p.join(home, '.config', 'EmuDeck', 'settings.sh'));

    try {
      if (!await file.exists()) return const {};
      final result = <String, String>{};
      final wanted = {'toolsPath', 'emulationPath'};
      for (final raw in await file.readAsLines()) {
        final line = raw.trim();
        if (line.isEmpty || line.startsWith('#')) continue;
        final eq = line.indexOf('=');
        if (eq <= 0) continue;
        final key = line.substring(0, eq).trim();
        if (!wanted.contains(key)) continue;
        final expanded = _expandHome(_unquote(line.substring(eq + 1).trim()));
        if (expanded != null && expanded.isNotEmpty) result[key] = expanded;
      }
      return result;
    } catch (e) {
      _log.w('LinuxEmulatorDiscovery: could not read EmuDeck settings: $e');
      return const {};
    }
  }

  /// Removes the quoting from a shell assignment value.
  ///
  /// EmuDeck quotes only the *install root* and concatenates the rest onto it —
  /// a real Steam Deck writes
  /// `toolsPath="/run/media/deck/Deck"/Emulation/tools`. The shell joins those
  /// segments into a single word, so the quotes sit mid-value rather than
  /// around it; stripping only a matched outer pair leaves them embedded and
  /// yields a path that can never exist.
  static String _unquote(String value) {
    final out = StringBuffer();
    String? open;
    for (var i = 0; i < value.length; i++) {
      final ch = value[i];
      if (open == null && (ch == '"' || ch == "'")) {
        open = ch;
      } else if (open == ch) {
        open = null;
      } else {
        out.write(ch);
      }
    }
    return out.toString();
  }

  /// Expands the `$HOME` / `${HOME}` / `~` forms EmuDeck writes into its
  /// settings file. Any other shell expansion is left alone and rejected,
  /// because a half-expanded path would probe a directory that is not the
  /// user's.
  static String? _expandHome(String value) {
    final home = _home();
    if (home == null) return value.contains(r'$') ? null : value;

    var out = value;
    if (out == '~') return home;
    if (out.startsWith('~/')) out = p.join(home, out.substring(2));
    out = out.replaceAll(r'${HOME}', home).replaceAll(r'$HOME', home);

    // Anything still holding a shell variable is not a path we can trust.
    return out.contains(r'$') ? null : out;
  }

  /// Finds `Emulation/tools/launchers` directories under a removable-media root.
  ///
  /// Scans at most two levels (`/run/media/<label>` and
  /// `/run/media/<user>/<label>`), which covers both SteamOS mount layouts
  /// without walking the whole card.
  static Future<List<String>> _globEmulationRoots(String root) async {
    final found = <String>[];
    final dir = Directory(root);
    if (!await _dirExists(root)) return found;

    Future<void> scan(Directory d, int depth) async {
      if (depth > 2) return;
      List<FileSystemEntity> entries;
      try {
        entries = await d.list(followLinks: false).toList();
      } catch (_) {
        return; // unreadable mount point — not an error worth surfacing
      }
      for (final entry in entries) {
        if (entry is! Directory) continue;
        final candidate = p.join(entry.path, 'Emulation', 'tools', 'launchers');
        if (await _dirExists(candidate)) {
          found.add(candidate);
        } else if (depth < 2) {
          await scan(entry, depth + 1);
        }
      }
    }

    await scan(dir, 1);
    return found;
  }

  // ── Search locations ───────────────────────────────────────────────────────

  /// Flatpak's exported-binary directories, user installation first.
  static List<String> _flatpakExportBinDirs() {
    final dirs = <String>[];
    final home = _home();
    final xdgData = Platform.environment['XDG_DATA_HOME'];

    if (xdgData != null && xdgData.isNotEmpty) {
      dirs.add(p.join(xdgData, 'flatpak', 'exports', 'bin'));
    }
    if (home != null) {
      dirs.add(p.join(home, '.local', 'share', 'flatpak', 'exports', 'bin'));
    }
    dirs.add('/var/lib/flatpak/exports/bin');
    return dirs;
  }

  /// `PATH` entries followed by the standard binary locations, de-duplicated.
  static List<String> _binarySearchDirs() {
    final dirs = <String>[];
    final path = Platform.environment['PATH'] ?? '';
    for (final dir in path.split(':')) {
      if (dir.isNotEmpty) dirs.add(dir);
    }
    dirs.addAll(const ['/usr/bin', '/usr/local/bin', '/bin', '/usr/games']);

    final home = _home();
    if (home != null) {
      dirs.add(p.join(home, '.local', 'bin'));
      dirs.add(p.join(home, 'Applications'));
    }
    return dirs.toSet().toList();
  }

  /// Directories where AppImage-based emulators land, EmuDeck's first.
  static List<String> _appImageDirs() {
    final home = _home();
    if (home == null) return const [];
    return [
      p.join(home, 'Applications'),
      p.join(home, '.local', 'bin'),
      p.join(home, 'Applications', 'AppImages'),
      p.join(home, 'Desktop'),
      p.join(home, 'Downloads'),
    ];
  }

  /// Finds an AppImage whose name starts with [executable]'s base name.
  ///
  /// AppImages carry version suffixes that change on every update, so an exact
  /// filename match would go stale immediately. When several match, the last in
  /// sort order wins — the same "newest build" heuristic EmuDeck's launchers
  /// use.
  static Future<String?> _findAppImage(String executable) async {
    var base = executable;
    if (base.toLowerCase().endsWith('.appimage')) {
      base = base.substring(0, base.length - '.appimage'.length);
    }
    if (base.isEmpty) return null;
    final needle = base.toLowerCase();

    for (final dir in _appImageDirs()) {
      final directory = Directory(dir);
      if (!await _dirExists(dir)) continue;

      final matches = <String>[];
      try {
        await for (final entry in directory.list(followLinks: false)) {
          if (entry is! File) continue;
          final name = p.basename(entry.path).toLowerCase();
          if (name.startsWith(needle) && name.endsWith('.appimage')) {
            matches.add(entry.path);
          }
        }
      } catch (_) {
        continue;
      }

      if (matches.isNotEmpty) {
        matches.sort();
        final best = matches.last;
        if (await _isRunnable(best)) return best;
      }
    }
    return null;
  }

  // ── RetroArch cores ────────────────────────────────────────────────────────

  /// Resolves the directory holding RetroArch's libretro cores for the install
  /// that [retroArchPath] points at.
  ///
  /// The cores are not next to the executable for either of the two ways Linux
  /// users actually get RetroArch. A Flatpak keeps them under
  /// `~/.var/app/org.libretro.RetroArch/config/retroarch/cores`, and an EmuDeck
  /// launcher script is a `flatpak run` wrapper, so it lands in the same place
  /// while looking nothing like a Flatpak path. Both are probed before falling
  /// back to a native layout.
  ///
  /// Returns the first candidate that exists, or `null` when none do — the
  /// caller is expected to report that rather than launch into a missing core.
  static Future<String?> resolveRetroArchCoresDir(String retroArchPath) async {
    for (final dir in retroArchCoresDirCandidates(retroArchPath)) {
      if (await _dirExists(dir)) return dir;
    }
    return null;
  }

  /// The ordered cores-directory candidates for [retroArchPath].
  ///
  /// Exposed separately so callers can report what was searched when nothing
  /// matched.
  static List<String> retroArchCoresDirCandidates(String retroArchPath) {
    final candidates = <String>[];
    final home = _home();

    if (home != null) {
      // Flatpak, however it was launched: an exports/bin wrapper, an EmuDeck
      // tools/launchers script, or `flatpak run` by hand.
      candidates.add(
        p.join(
          home,
          '.var',
          'app',
          'org.libretro.RetroArch',
          'config',
          'retroarch',
          'cores',
        ),
      );
      candidates.add(p.join(home, '.config', 'retroarch', 'cores'));
      candidates.add(p.join(home, '.local', 'share', 'retroarch', 'cores'));
    }

    // Native and AppImage installs keep cores beside the binary or under the
    // distro's library directory.
    if (retroArchPath.isNotEmpty) {
      candidates.add(p.join(p.dirname(retroArchPath), 'cores'));
    }
    candidates.add('/usr/lib/libretro');
    candidates.add('/usr/lib64/libretro');
    candidates.add('/usr/local/lib/libretro');

    return candidates.toSet().toList();
  }

  // ── Helpers ────────────────────────────────────────────────────────────────

  /// Stands in for `$HOME` under test.
  ///
  /// Every location this service probes hangs off the home directory, and Dart
  /// cannot rewrite its own environment, so a fixture tree is the only way to
  /// exercise the real resolution order rather than a re-implementation of it.
  @visibleForTesting
  static String? homeOverride;

  static String? _home() {
    if (homeOverride != null) return homeOverride;
    final home = Platform.environment['HOME'];
    return (home == null || home.isEmpty) ? null : home;
  }

  /// Whether [path] is a directory that can be read.
  ///
  /// `Directory.exists()` throws rather than returning false when a parent is
  /// unreadable — `/run/media/root` on a Steam Deck is mode 700 and owned by
  /// another user, so probing it raises `PathAccessException`. Discovery runs
  /// inside the launch path, where an escaping exception aborts the launch
  /// outright, and "I am not allowed to look" is indistinguishable from "not
  /// there" for our purposes.
  static Future<bool> _dirExists(String path) async {
    try {
      return await Directory(path).exists();
    } catch (_) {
      return false;
    }
  }

  /// Whether [path] is a file the user could actually execute.
  ///
  /// Flatpak wrappers and EmuDeck launchers are scripts, and a non-executable
  /// match is a stale leftover rather than something we should hand to
  /// `Process.start`, so the mode bits are checked as well as existence.
  static Future<bool> _isRunnable(String path) async {
    try {
      final stat = await FileStat.stat(path);
      if (stat.type == FileSystemEntityType.notFound) return false;
      if (stat.type == FileSystemEntityType.directory) return false;
      return (stat.mode & 0x49) != 0; // any of the three execute bits
    } catch (_) {
      return false;
    }
  }
}
