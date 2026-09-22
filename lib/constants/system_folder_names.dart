class SystemFolderNames {
  static const String favorites = 'favorites';
  static const String all = 'all';
  static const String music = 'music';
  static const String android = 'android';

  /// Systems the "Recursive Scan" setting cannot apply to: they own no ROM
  /// folder to walk. [all] and [favorites] aggregate games that belong to other
  /// systems, [android] lists installed apps, and [collections] lists the
  /// user's collections.
  ///
  /// Offering the switch on one of these is not merely inert: flipping it
  /// triggers a real scan for a folder of that name, which would file whatever
  /// it found under a system that is supposed to hold nothing of its own.
  ///
  /// [music] is deliberately absent — it owns a real folder that can nest.
  ///
  /// A new virtual system belongs here the moment it is added to
  /// `assets/systems/`, together with a migration that clears both flags on
  /// databases that already carry a row for it.
  static const Set<String> recursiveScanExcluded = {
    all,
    favorites,
    android,
    collections,
  };

  /// Systems the subfolder view cannot apply to: everything in
  /// [recursiveScanExcluded], plus the music library, which owns a folder but
  /// is browsed as a playlist rather than a folder tree. The game list skips
  /// the setting for these, so the global "Show Subfolders" toggle leaves them
  /// alone rather than writing a flag nothing will ever read. A single
  /// collection (`collection:<uuid>`) never has an `app_systems` row, so it is
  /// not listed here; [isAggregate] covers it where a synthesized system can
  /// appear.
  ///
  /// This must stay a superset of [recursiveScanExcluded]: the per-system
  /// settings dialog stacks "Show Subfolders" directly under "Recursive Scan"
  /// and addresses both by position, so a system may never drop the recursive
  /// row while keeping the subfolder one.
  static const Set<String> subfolderViewExcluded = {
    ...recursiveScanExcluded,
    music,
  };

  /// The parent virtual system that lists the user's collections.
  static const String collections = 'collections';

  /// The Search card on the systems screen, which opens the library-wide
  /// search. Unlike the other virtual systems it has no `assets/systems/` entry
  /// and no `app_systems` row: `buildSystemsList` synthesizes the card, so it
  /// never reaches anything that walks `detectedSystems` (scans, per-system
  /// settings, artwork downloads).
  static const String search = 'search';

  /// Prefix of a single collection's synthesized folder name
  /// (`collection:<uuid>`). Collections are user data, not `app_systems` rows,
  /// so they only ever exist as synthesized [SystemModel]s carrying this.
  static const String collectionPrefix = 'collection:';

  /// Whether [folderName] identifies one user collection.
  static bool isCollection(String? folderName) =>
      folderName != null && folderName.startsWith(collectionPrefix);

  /// The collection id inside a `collection:<uuid>` folder name, or null.
  static String? collectionIdOf(String? folderName) => isCollection(folderName)
      ? folderName!.substring(collectionPrefix.length)
      : null;

  /// Whether [folderName] is an aggregate view: one whose games come from many
  /// hardware systems rather than a single one (`all`, `favorites`,
  /// `collections`, `collection:<uuid>`).
  ///
  /// Two things follow from this and both matter:
  /// * each game carries its own `systemFolderName`, so artwork, launching and
  ///   per-system settings must resolve against the *game's* system, never the
  ///   list's;
  /// * there is no folder tree behind the list, so the subfolder view has
  ///   nothing to build from.
  static bool isAggregate(String? folderName) =>
      folderName == all ||
      folderName == favorites ||
      folderName == collections ||
      isCollection(folderName);
}
