import '../models/game_model.dart';
import 'game_list_update.dart';

/// Builds the in-memory folder hierarchy used by the subfolder ROM view.
///
/// The ROM scanner stores every game with its full [GameModel.romPath] (it
/// already recurses into subfolders when a system has `recursiveScan` enabled),
/// so no database changes are needed: the tree is derived purely from each
/// game's path relative to its system's configured root folders.

/// A single row in the ROM list — either a [RomFolderEntry] the user can
/// descend into, or a [RomGameEntry] that launches a game.
sealed class RomListEntry {
  const RomListEntry();

  /// Text shown for the row (folder name or game name).
  String get label;
}

/// A navigable subfolder at the current level.
class RomFolderEntry extends RomListEntry {
  /// Display name — the folder's own name (last path segment).
  final String name;

  /// Path of this folder relative to the system root, using '/' separators
  /// (e.g. `Hacks (NES)` or `Hacks (NES)/Sub`). Pass this back as
  /// `currentRelPath` to descend into the folder.
  final String relPath;

  /// Total games contained anywhere beneath this folder (recursive).
  final int gameCount;

  const RomFolderEntry({
    required this.name,
    required this.relPath,
    required this.gameCount,
  });

  @override
  String get label => name;
}

/// A playable game at the current level.
class RomGameEntry extends RomListEntry {
  final GameModel game;

  const RomGameEntry(this.game);

  @override
  String get label => game.name.isNotEmpty ? game.name : game.romname;
}

/// Returns the entries to display for [currentRelPath] within the folder tree
/// derived from [games] and the system's [rootFolders].
///
/// Folders are listed first (alphabetical, case-insensitive), then games using
/// the same ordering as the flat list: favorites pinned first, then by name.
/// Games whose path is not under any root folder — or that have no path — are
/// surfaced at the root level so nothing silently disappears.
List<RomListEntry> buildRomLevel({
  required List<GameModel> games,
  required List<String> rootFolders,
  String currentRelPath = '',
  bool ignoreArticles = false,
}) {
  final normalizedRoots = rootFolders.map(_normalize).toList();
  final prefix = _normalize(currentRelPath);

  // Games whose relative path equals the current level — shown directly.
  final directGames = <GameModel>[];
  // Immediate child folder name -> recursive game count.
  final folderCounts = <String, int>{};

  for (final g in games) {
    final rel = _relativePath(g.romPath, normalizedRoots);

    if (rel == null) {
      // No path / outside every root: only ever visible at the root level.
      if (prefix.isEmpty) directGames.add(g);
      continue;
    }

    // Restrict to entries inside the current folder.
    if (prefix.isNotEmpty) {
      if (rel != prefix && !rel.startsWith('$prefix/')) continue;
    }

    final remainder = prefix.isEmpty
        ? rel
        : (rel == prefix ? '' : rel.substring(prefix.length + 1));

    if (remainder.isEmpty) {
      directGames.add(g);
    } else {
      final childFolder = remainder.split('/').first;
      folderCounts.update(childFolder, (v) => v + 1, ifAbsent: () => 1);
    }
  }

  final folders =
      folderCounts.entries
          .map(
            (e) => RomFolderEntry(
              name: e.key,
              relPath: prefix.isEmpty ? e.key : '$prefix/${e.key}',
              gameCount: e.value,
            ),
          )
          .toList()
        ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));

  directGames.sort((a, b) {
    final aFav = a.isFavorite == true;
    final bFav = b.isFavorite == true;
    if (aFav != bFav) return aFav ? -1 : 1;
    return compareGameNames(a, b, ignoreArticles: ignoreArticles);
  });

  return [...folders, ...directGames.map(RomGameEntry.new)];
}

/// Returns the games contained anywhere beneath [folderRelPath] (recursively),
/// ordered favorites-first then by name — matching [buildRomLevel]'s ordering,
/// so a folder's cover mosaic shows the same games the user would see inside.
///
/// [limit], when set, caps how many games are returned (after ordering).
List<GameModel> gamesUnderFolder({
  required List<GameModel> games,
  required List<String> rootFolders,
  required String folderRelPath,
  int? limit,
  bool ignoreArticles = false,
}) {
  final normalizedRoots = rootFolders.map(_normalize).toList();
  final prefix = _normalize(folderRelPath);
  if (prefix.isEmpty) return const [];

  final matched = <GameModel>[];
  for (final g in games) {
    final rel = _relativePath(g.romPath, normalizedRoots);
    if (rel == null) continue;
    if (rel == prefix || rel.startsWith('$prefix/')) matched.add(g);
  }

  matched.sort((a, b) {
    final aFav = a.isFavorite == true;
    final bFav = b.isFavorite == true;
    if (aFav != bFav) return aFav ? -1 : 1;
    return compareGameNames(a, b, ignoreArticles: ignoreArticles);
  });

  if (limit != null && matched.length > limit) {
    return matched.sublist(0, limit);
  }
  return matched;
}

/// The folder holding [romPath], relative to whichever root in [rootFolders]
/// contains it — `''` for a game sitting directly in the system root, or null
/// when the path is absent or outside every root.
///
/// Used to open the list at a deep-linked game's own level: search ("Go to
/// game") and the RetroAchievements dashboard hand [SystemGamesList] a rom
/// path, which is only findable once the folder level containing it is built.
String? folderRelPathFor(String? romPath, List<String> rootFolders) =>
    _relativePath(romPath, rootFolders.map(_normalize).toList());

/// Normalizes a ROM path so the tree logic is identical across platforms:
/// forward slashes, no trailing separator. On Android the path is a Storage
/// Access Framework content URI whose real path lives — URL-encoded — in the
/// document id (e.g. `content://.../document/primary%3Aemu%2Froms%2Fnes%2FGame.zip`);
/// that is decoded to `emu/roms/nes/Game.zip` so subfolders are recognized.
String normalizeRomPath(String path) {
  var p = path;

  const marker = '/document/';
  final docIdx = p.indexOf(marker);
  if (p.startsWith('content://') && docIdx != -1) {
    var doc = p.substring(docIdx + marker.length);
    try {
      doc = Uri.decodeComponent(doc);
    } catch (_) {
      // Leave undecodable ids as-is rather than dropping the entry.
    }
    // Drop the storage-volume prefix ("primary:", "1A2B-3C4D:", ...).
    final colon = doc.indexOf(':');
    if (colon != -1) doc = doc.substring(colon + 1);
    p = doc;
  }

  p = p.replaceAll('\\', '/');
  while (p.length > 1 && p.endsWith('/')) {
    p = p.substring(0, p.length - 1);
  }
  return p;
}

String _normalize(String path) => normalizeRomPath(path);

/// Returns [romPath] relative to whichever root in [normalizedRoots] contains
/// it (forward-slash, no leading separator), or null if it has no path or sits
/// outside every root.
String? _relativePath(String? romPath, List<String> normalizedRoots) {
  if (romPath == null || romPath.isEmpty) return null;
  final p = _normalize(romPath);

  for (final root in normalizedRoots) {
    if (p == root) return '';
    if (root.isNotEmpty && p.startsWith('$root/')) {
      final rel = p.substring(root.length + 1);
      // Drop the filename — we group by directory.
      final lastSlash = rel.lastIndexOf('/');
      return lastSlash == -1 ? '' : rel.substring(0, lastSlash);
    }
  }
  return null;
}
