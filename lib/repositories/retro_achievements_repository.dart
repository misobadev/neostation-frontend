import '../data/datasources/sqlite_service.dart';

/// Repository for RetroAchievements data access.
class RetroAchievementsRepository {
  /// Returns local ROM counts: total and RA-compatible (has ra_hash).
  static Future<({int totalRoms, int raCompatibleRoms})>
  getLocalRomStats() async {
    final db = await SqliteService.getDatabase();

    final totalResult = await db.rawQuery(
      'SELECT COUNT(*) as total FROM user_roms',
    );
    final compatibleResult = await db.rawQuery('''
      SELECT COUNT(*) as compatible
      FROM user_roms
      WHERE ra_hash IS NOT NULL AND ra_hash != ''
    ''');

    return (
      totalRoms:
          int.tryParse(totalResult.first['total']?.toString() ?? '0') ?? 0,
      raCompatibleRoms:
          int.tryParse(
            compatibleResult.first['compatible']?.toString() ?? '0',
          ) ??
          0,
    );
  }

  /// Returns the persisted RA username, or null if not set.
  static Future<String?> getRAUser() async {
    final config = await SqliteService.getUserConfig();
    final value = config?['ra_user']?.toString();
    return (value != null && value.isNotEmpty) ? value : null;
  }

  /// Persists the RA username.
  static Future<void> saveRAUser(String username) =>
      SqliteService.updateRAUser(username);

  /// Clears the stored RA username.
  static Future<void> clearRAUser() async {
    final db = await SqliteService.getDatabase();
    await db.update('user_config', {'ra_user': null});
  }

  // ── ROM RA hash operations ────────────────────────────────────────────────

  static Future<String?> getRomRaHash(String romPath) =>
      SqliteService.getRomRaHash(romPath);

  static Future<void> updateRomRaHash(String romPath, String hash) =>
      SqliteService.updateRomRaHash(romPath, hash);

  static Future<void> updateRomRaGameId(String romPath, int? gameId) async {
    final db = await SqliteService.getDatabase();
    await db.rawUpdate('UPDATE user_roms SET id_ra = ? WHERE rom_path = ?', [
      gameId,
      romPath,
    ]);
  }

  // ── Game ID lookups (for RA game matching) ────────────────────────────────

  /// Resolves RA game_id by MD5 hash and console ID string.
  static Future<int?> getGameIdByHash(String raHash, String raConsoleId) =>
      SqliteService.getRetroAchievementsGameIdByHash(raHash, raConsoleId);

  // ── ROM RA-data update ─────────────────────────────────────────────────────

  /// Finds a matching entry in app_ra_game_list by [consoleName] LIKE and
  /// [titleLikePattern] LIKE. Returns {hash, gameId} or null.
  static Future<({String hash, int? gameId})?> findRAHashByConsoleName(
    String consoleName,
    String titleLikePattern,
  ) async {
    final db = await SqliteService.getDatabase();
    final results = await db.rawQuery(
      'SELECT hash, game_id FROM app_ra_game_list WHERE console_name LIKE ? AND title LIKE ? LIMIT 1',
      ['%$consoleName%', titleLikePattern],
    );
    if (results.isEmpty) return null;
    return (
      hash: results.first['hash'].toString(),
      gameId: int.tryParse(results.first['game_id']?.toString() ?? ''),
    );
  }

  /// Updates user_roms ra_hash and id_ra for a ROM identified by [filename] and [systemId].
  static Future<void> updateRomRAData(
    String filename,
    String systemId,
    String hash,
    int? gameId,
  ) async {
    final db = await SqliteService.getDatabase();
    await db.rawUpdate(
      'UPDATE user_roms SET ra_hash = ?, id_ra = ? WHERE filename = ? AND app_system_id = ?',
      [hash, gameId, filename, systemId],
    );
  }

  // ── Game ID lookups (for RA game matching) ────────────────────────────────

  /// Finds RA game_id by exact MD5 hash match in app_ra_game_list.
  /// Returns 0 (not found) or the game_id.
  static Future<int?> findGameIdByHash(String md5Hash) async {
    final db = await SqliteService.getDatabase();
    final results = await db.rawQuery(
      '''
      SELECT game_id
      FROM app_ra_game_list
      WHERE hash COLLATE NOCASE = ?
      LIMIT 1
      ''',
      [md5Hash],
    );
    if (results.isEmpty) return null;
    return int.tryParse(results.first['game_id']?.toString() ?? '0') ?? 0;
  }

  /// Finds RA game_id by filename for a system, using exact then LIKE matching.
  /// [filenameWithoutExt] should already be sanitized (no brackets/parens).
  /// Returns the game_id, or null if not found.
  static Future<int?> findGameIdByFilename(
    String systemFolderName,
    String filenameWithoutExt,
  ) async {
    final db = await SqliteService.getDatabase();

    const consoleSubquery = '''
      SELECT asys.ra_id
      FROM app_systems asys
      WHERE asys.folder_name = ?
    ''';

    // Exact title match
    final exactResults = await db.rawQuery(
      '''
      SELECT g.game_id
      FROM app_ra_game_list g
      WHERE g.console_id = ($consoleSubquery)
        AND g.title = ?
      ORDER BY g.title DESC
      LIMIT 1
      ''',
      [systemFolderName, filenameWithoutExt],
    );
    if (exactResults.isNotEmpty) {
      return int.tryParse(exactResults.first['game_id']?.toString() ?? '0') ??
          0;
    }

    // LIKE match with normalized search pattern
    final searchPattern =
        '%${filenameWithoutExt.replaceAll(' - ', ' ').replaceAll(':', '').replaceAll(' ', '%').trim()}%';

    final likeResults = await db.rawQuery(
      '''
      SELECT g.game_id
      FROM app_ra_game_list g
      WHERE g.console_id = ($consoleSubquery)
        AND g.title LIKE ? 
      ORDER BY
        CASE
          WHEN g.title LIKE '~Hack~%' THEN 1
          WHEN g.title LIKE '%Subset%' THEN 1
          ELSE 0
        END,
        g.title ASC
      LIMIT 1
      ''',
      [systemFolderName, searchPattern],
    );
    if (likeResults.isNotEmpty) {
      return int.tryParse(likeResults.first['game_id']?.toString() ?? '0') ?? 0;
    }

    return null;
  }
}
