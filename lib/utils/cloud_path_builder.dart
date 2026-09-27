import '../models/neo_sync_models.dart';

/// Builds and parses the canonical NeoSync cloud paths.
///
/// Format (applies to both saves and states), always under the `v2/` namespace
/// so it can never collide with legacy v1 paths (`saves/...` on GCS):
///   `v2/saves/<system>/<emulator-slug>/<scope>/[<game>/]<file>`
///   `v2/states/<system>/<emulator-slug>/<scope>/[<game>/]<file>`
///
/// - `system`: the system folder name (e.g. `ps2`, `ps1`, `dc`).
/// - `emulator-slug`: stable identifier for the emulator that produced the
///   save (e.g. `retroarch.pcsx2`, `armsx2`, `duckstation`). RetroArch
///   variants (RA/RA64/RA32) that share a core collapse into one slug so the
///   save is portable between them.
/// - `scope`: `shared` for memory cards / VMU that hold many games, or
///   `game` for a save that belongs to a single game.
/// - `game`: sanitized game name, present only when scope is `game`.
/// - `file`: the real file name (optionally with emulator-internal folders).
class CloudPathBuilder {
  CloudPathBuilder._();

  static const namespaceV2 = 'v2';
  static const rootSave = 'saves';
  static const rootState = 'states';

  /// The legacy (v1) namespace prefix, e.g. `saves/`.
  static const legacySavePrefix = 'saves/';
  static const legacyStatePrefix = 'states/';

  /// Whether a path belongs to the legacy v1 layout (no `v2/` prefix).
  static bool isLegacy(String cloudPath) {
    return !cloudPath.startsWith('$namespaceV2/');
  }

  /// Builds a cloud path for a save or state under the `v2/` namespace.
  ///
  /// [scope] must be `shared` or `game`. When [scope] is `game`, [gameName]
  /// is included. [filePath] may contain emulator-internal folders, which are
  /// preserved after the game/scope segment.
  static String build({
    required String system,
    required String emulatorSlug,
    required String scope,
    required String filePath,
    String? gameName,
    bool isState = false,
  }) {
    final root = isState ? rootState : rootSave;
    final segments = <String>[namespaceV2, root, system, emulatorSlug, scope];
    if (scope == 'game' && gameName != null && gameName.isNotEmpty) {
      segments.add(sanitizeGameName(gameName));
    }
    segments.add(filePath);
    return segments.join('/').replaceAll('\\', '/');
  }

  /// Parses a standard v2 cloud path into its structured components.
  ///
  /// Returns null when the path does not match the standard layout.
  static ParsedCloudPath? parse(String cloudPath) {
    final isState = cloudPath.startsWith('$namespaceV2/$rootState/');
    if (!isState && !cloudPath.startsWith('$namespaceV2/$rootSave/')) {
      return null;
    }

    final segments = cloudPath.split('/');
    // v2/saves/<system>/<emulator>/<scope>/... is at least 6 segments.
    if (segments.length < 6) return null;

    final system = segments[2];
    final emulatorSlug = segments[3];
    final scope = segments[4];
    if (scope != 'shared' && scope != 'game') return null;

    final rest = segments.sublist(5);
    final String filePath;
    final String? gameName;
    if (scope == 'game' && rest.length >= 2) {
      gameName = rest.first;
      filePath = rest.sublist(1).join('/');
    } else {
      gameName = null;
      filePath = rest.join('/');
    }

    return ParsedCloudPath(
      isState: isState,
      system: system,
      emulatorSlug: emulatorSlug,
      scope: scope,
      gameName: gameName,
      filePath: filePath,
    );
  }

  /// Sanitizes a game name so it can be used as a path segment.
  static String sanitizeGameName(String name) {
    return name.replaceAll(RegExp(r'[<>:"/\\|?*]'), '_');
  }

  /// Canonical, OS-independent key for a save path.
  ///
  /// Drops the `saves/`/`states/` root and normalizes separators and case, so
  /// Windows/macOS (case-insensitive filesystems) and Android/Linux
  /// (case-sensitive) agree on the identity of a save. This is what lets a save
  /// stay in sync across every operating system.
  static String canonicalSaveKey(String rawPath) {
    var p = rawPath.replaceAll('\\', '/');
    if (p.startsWith(legacySavePrefix)) {
      p = p.substring(legacySavePrefix.length);
    } else if (p.startsWith(legacyStatePrefix)) {
      p = p.substring(legacyStatePrefix.length);
    }
    return p.toLowerCase();
  }

  /// Canonical NeoSync file kind for [path]: `state`, `shared` or `save`.
  ///
  /// Derived only from the file itself, never from the cloud namespace, so the
  /// same save is classified identically on every device and OS.
  static String syncTypeForPath(String path, {required bool isState}) {
    if (isState) return 'state';
    final lower = path.toLowerCase();
    final isSharedCard =
        lower.endsWith('.ps2') ||
        lower.endsWith('.mcr') ||
        lower.endsWith('.mcd') ||
        lower.endsWith('.vmu') ||
        lower.endsWith('.vmp') ||
        lower.contains('vmu_save');
    return isSharedCard ? 'shared' : 'save';
  }

  /// Whether [cloudPath] refers to the same save as the local [localPath].
  ///
  /// The `type` is cross-checked against the local `saves/`/`states/` root so a
  /// save and a save state that share a basename never match each other.
  static bool cloudMatchesLocalPath(
    String cloudPath,
    String localPath, {
    required String cloudType,
  }) {
    if (canonicalSaveKey(cloudPath) != canonicalSaveKey(localPath)) {
      return false;
    }
    final localIsState = localPath
        .replaceAll('\\', '/')
        .toLowerCase()
        .startsWith(legacyStatePrefix);
    return localIsState ? cloudType == 'state' : cloudType != 'state';
  }

  /// Collapses cloud rows that represent the same logical save (same canonical
  /// path + kind) keeping the one with the newest content.
  ///
  /// Legacy duplicate rows (from the unstable cloud namespace) must never make
  /// the client pick an older version just because it was uploaded later.
  static List<NeoSyncFile> dedupeCloudFiles(List<NeoSyncFile> files) {
    final byKey = <String, NeoSyncFile>{};
    for (final file in files) {
      final pathKey = file.filePath.isNotEmpty ? file.filePath : file.fileName;
      final key = '${canonicalSaveKey(pathKey)}|${file.type}';
      final current = byKey[key];
      if (current == null) {
        byKey[key] = file;
        continue;
      }
      final currentTs = current.fileModifiedAtTimestamp ?? 0;
      final candidateTs = file.fileModifiedAtTimestamp ?? 0;
      if (candidateTs > currentTs ||
          (candidateTs == currentTs &&
              file.uploadedAt.isAfter(current.uploadedAt))) {
        byKey[key] = file;
      }
    }
    return byKey.values.toList();
  }

  /// Derives a RetroArch core slug from the core identifier or display name.
  ///
  /// Examples: `mednafen_psx_hw` -> `retroarch.mednafen-psx-hw`,
  /// `pcsx2_libretro` -> `retroarch.pcsx2`,
  /// `pcsx2_libretro.dll` -> `retroarch.pcsx2` (the binary extension is
  /// stripped so the seeded slug matches the runtime derivation from the
  /// emulator's unique id, which never carries the extension).
  static String retroArchCoreSlug(String coreNameOrIdentifier) {
    var input = coreNameOrIdentifier.trim();
    // Strip known binary/library extensions so desktop core filenames
    // (`pcsx2_libretro.dll`, `mednafen_psx_hw_libretro.so`) collapse to the
    // same slug the runtime derives from the unique id (`retroarch.pcsx2`).
    final extMatch = RegExp(
      r'\.(dll|so|dylib|appimage|exe|bin)$',
    ).firstMatch(input.toLowerCase());
    if (extMatch != null) {
      input = input.substring(0, extMatch.start);
    }
    final core = input
        .replaceAll('_libretro', '')
        .trim()
        .toLowerCase()
        .replaceAll(RegExp(r'\s+'), '-')
        .replaceAll('_', '-')
        .replaceAll(RegExp(r'[^a-z0-9.\-]'), '');
    return 'retroarch.$core';
  }

  /// Derives a standalone emulator slug from its unique identifier.
  ///
  /// Example: `ps2.come.nanodata.armsx2` -> `armsx2`. The last dotted segment
  /// is used and slugified so Android package fragments stay usable.
  static String standaloneSlugFromUniqueId(String uniqueId) {
    final parts = uniqueId.split('.');
    if (parts.isEmpty) return 'standalone';
    final last = parts.last.trim().toLowerCase().replaceAll(
      RegExp(r'[^a-z0-9\-]'),
      '',
    );
    return last.isEmpty ? 'standalone' : last;
  }

  /// Derives the emulator slug from an emulator unique id, deciding whether the
  /// emulator is a RetroArch core (`.ra.`/`.ra64.`/`.ra32.`) or standalone.
  ///
  /// Examples:
  ///   `ps2.ra.pcsx2`                -> `retroarch.pcsx2`
  ///   `ps1.ra64.mednafen_psx_hw`    -> `retroarch.mednafen-psx-hw`
  ///   `ps2.come.nanodata.armsx2`    -> `armsx2`
  static String slugFromEmulatorUniqueId(String uniqueId) {
    final lower = uniqueId.toLowerCase();
    if (lower.contains('.ra64.')) {
      final core = uniqueId.split('.ra64.').last;
      return retroArchCoreSlug(core);
    }
    if (lower.contains('.ra32.')) {
      final core = uniqueId.split('.ra32.').last;
      return retroArchCoreSlug(core);
    }
    if (lower.contains('.ra.')) {
      final core = uniqueId.split('.ra.').last;
      return retroArchCoreSlug(core);
    }
    return standaloneSlugFromUniqueId(uniqueId);
  }
}

/// Structured components of a standard NeoSync cloud path.
class ParsedCloudPath {
  final bool isState;
  final String system;
  final String emulatorSlug;
  final String scope;
  final String? gameName;
  final String filePath;

  const ParsedCloudPath({
    required this.isState,
    required this.system,
    required this.emulatorSlug,
    required this.scope,
    this.gameName,
    required this.filePath,
  });

  bool get isShared => scope == 'shared';
}
