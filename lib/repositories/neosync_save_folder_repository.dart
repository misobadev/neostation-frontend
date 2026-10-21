import '../data/datasources/sqlite_service.dart';

/// Repository for the NeoSync module's per-system custom save folders.
///
/// Standalone emulators with relocatable data directories (ARMSX2, ARMSX1,
/// DuckStation, etc.) cannot be resolved from the system definitions alone.
/// This repository reads and persists the folder the user selects for each
/// system + emulator pair in its own dedicated table, keeping the NeoSync
/// module's configuration separate from the global [SqliteService] user config.
class NeoSyncSaveFolderRepository {
  static const _table = 'user_custom_save_folders';

  /// Returns the user-selected save folder for a system + emulator, or null.
  static Future<String?> getFolder(
    String systemFolderName,
    String emulatorSlug,
  ) async {
    final db = await SqliteService.getDatabase();
    final results = await db.query(
      _table,
      where: 'system_folder_name = ? AND emulator_slug = ?',
      whereArgs: [systemFolderName, emulatorSlug],
      limit: 1,
    );
    if (results.isEmpty) return null;
    return results.first['folder_path']?.toString();
  }

  /// Returns all configured folders for a system, keyed by emulator slug.
  static Future<Map<String, String>> getFoldersForSystem(
    String systemFolderName,
  ) async {
    final db = await SqliteService.getDatabase();
    final results = await db.query(
      _table,
      where: 'system_folder_name = ?',
      whereArgs: [systemFolderName],
    );
    return {
      for (final row in results)
        if (row['emulator_slug'] != null && row['folder_path'] != null)
          row['emulator_slug'].toString(): row['folder_path'].toString(),
    };
  }

  /// Returns all configured save folders keyed by `system_folder_name`.
  static Future<Map<String, String>> getAllFolders() async {
    final db = await SqliteService.getDatabase();
    final results = await db.query(_table);
    return {
      for (final row in results)
        if (row['system_folder_name'] != null && row['folder_path'] != null)
          row['system_folder_name'].toString(): row['folder_path'].toString(),
    };
  }

  /// Returns every configured save folder, for every system and emulator.
  static Future<List<String>> getAllFolderPaths() async {
    final db = await SqliteService.getDatabase();
    final results = await db.query(_table, columns: ['folder_path']);
    return [
      for (final row in results)
        if (row['folder_path'] != null) row['folder_path'].toString(),
    ];
  }

  /// A configured custom save folder entry.
  static const folderEntryFields = (
    systemField: 'system_folder_name',
    emulatorField: 'emulator_slug',
    pathField: 'folder_path',
  );

  /// Returns every configured folder as `(system, emulatorSlug, path)`.
  static Future<List<(String, String, String)>> getAllEntries() async {
    final db = await SqliteService.getDatabase();
    final results = await db.query(_table);
    return [
      for (final row in results)
        if (row['system_folder_name'] != null &&
            row['emulator_slug'] != null &&
            row['folder_path'] != null)
          (
            row['system_folder_name'].toString(),
            row['emulator_slug'].toString(),
            row['folder_path'].toString(),
          ),
    ];
  }

  /// Persists the selected save folder for a system + emulator, upserting.
  static Future<void> saveFolder(
    String systemFolderName,
    String emulatorSlug,
    String folderPath,
  ) async {
    final db = await SqliteService.getDatabase();
    await db.insert(_table, {
      'system_folder_name': systemFolderName,
      'emulator_slug': emulatorSlug,
      'folder_path': folderPath,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  /// Removes the configured save folder for a system + emulator, if any.
  static Future<void> removeFolder(
    String systemFolderName,
    String emulatorSlug,
  ) async {
    final db = await SqliteService.getDatabase();
    await db.delete(
      _table,
      where: 'system_folder_name = ? AND emulator_slug = ?',
      whereArgs: [systemFolderName, emulatorSlug],
    );
  }
}
