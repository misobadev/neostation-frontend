import '../data/datasources/sqlite_service.dart';
import '../models/database_game_model.dart';
import '../models/ra_game_list_entry.dart';
import '../models/ra_catalogue_game.dart';
import '../models/ra_hash_policy.dart';
import '../models/ra_match_candidate.dart';
import '../models/retro_achievements_dashboard_models.dart';
import '../services/credential_store.dart';
import '../services/logger_service.dart';

/// Repository for RetroAchievements data access.
class RetroAchievementsRepository {
  static final _log = LoggerService.instance;

  static Future<List<({int id, DateTime? refreshedAt})>>
  getLibraryRaConsoles() async {
    final db = await SqliteService.getDatabase();
    final rows = await db.rawQuery('''
      SELECT DISTINCT CAST(s.ra_id AS INTEGER) AS console_id, c.refreshed_at
      FROM app_systems s JOIN user_roms ur ON ur.app_system_id = s.id
      LEFT JOIN app_ra_catalogue_sync c ON c.console_id = CAST(s.ra_id AS INTEGER)
      WHERE CAST(s.ra_id AS INTEGER) > 0
      ORDER BY console_id
    ''');
    return rows
        .map(
          (r) => (
            id: r['console_id'] as int,
            refreshedAt: DateTime.tryParse(r['refreshed_at']?.toString() ?? ''),
          ),
        )
        .toList();
  }

  static Future<void> replaceRaCatalogue(
    int consoleId,
    List<RaCatalogueGame> games,
    DateTime refreshedAt,
  ) async {
    if (games.any((g) => g.metadata['console_id'] != consoleId)) {
      throw ArgumentError('Catalogue console mismatch');
    }
    final db = await SqliteService.getDatabase();
    await db.transaction((txn) async {
      await txn.delete(
        'app_ra_game_list',
        where: 'console_id = ?',
        whereArgs: [consoleId],
      );
      for (final game in games) {
        for (final hash in game.hashes) {
          await txn.insert('app_ra_game_list', {
            ...game.metadata,
            'hash': hash,
          });
        }
      }
      await txn.insert('app_ra_catalogue_sync', {
        'console_id': consoleId,
        'refreshed_at': refreshedAt.toUtc().toIso8601String(),
        'match_pending': 1,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
    });
  }

  static Future<bool> hasPendingRaCatalogueMatch() async {
    final db = await SqliteService.getDatabase();
    return (await db.rawQuery(
      'SELECT 1 FROM app_ra_catalogue_sync WHERE match_pending = 1 LIMIT 1',
    )).isNotEmpty;
  }

  static Future<void> completeRaCatalogueMatch() async {
    final db = await SqliteService.getDatabase();
    await db.execute('UPDATE app_ra_catalogue_sync SET match_pending = 0');
  }

  static const String _raApiKeyStorageKey = 'ra_api_key';

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
  /// Whether this launch rebuilt the bundled RetroAchievements game list.
  ///
  /// The lookup-only pass exists to recover matches after that list changes.
  /// When it has not, re-walking every hashed-but-unmatched ROM cannot answer
  /// differently than it did last launch, because those ROMs are not in the
  /// list at all.
  static bool get raSeedChangedThisLaunch =>
      SqliteService.raSeedChangedThisLaunch;

  static Future<String?> getRAUser() async {
    final config = await SqliteService.getUserConfig();
    final value = config?['ra_user']?.toString();
    return (value != null && value.isNotEmpty) ? value : null;
  }

  /// Persists the RA username.
  static Future<void> saveRAUser(String username) =>
      SqliteService.updateRAUser(username);

  /// Persists the RA API key securely, reporting where it ended up so the
  /// caller can tell the user when it will not survive a restart.
  static Future<CredentialWriteOutcome> saveRAApiKey(String apiKey) {
    return CredentialStore.write(_raApiKeyStorageKey, apiKey);
  }

  /// Returns the persisted RA API key, or null if not set.
  static Future<String?> getRAApiKey() {
    return CredentialStore.read(_raApiKeyStorageKey);
  }

  /// Clears the stored RA API key.
  static Future<void> clearRAApiKey() {
    return CredentialStore.delete(_raApiKeyStorageKey);
  }

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

  /// How a ROM's RetroAchievements match was established. Persisted in
  /// `user_roms.ra_match_source`; only [raMatchManual] survives an automatic
  /// re-match.
  static const String raMatchHash = 'hash';
  static const String raMatchFilename = 'filename';
  static const String raMatchTitle = 'title';

  /// RomM supplied the exact RetroAchievements game id for this download.
  ///
  /// This is automatic metadata, rather than a user override, so a later hash
  /// match may still correct it if the server's metadata becomes stale.
  static const String raMatchRomm = 'romm';
  static const String raMatchManual = 'manual';

  /// SQL fragment guarding automatic writes against overwriting a user's pick.
  static const String _notManuallyMatched =
      "(ra_match_source IS NULL OR ra_match_source != '$raMatchManual')";

  static Future<void> updateRomRaGameId(
    String romPath,
    int? gameId, {
    String matchSource = raMatchHash,
  }) async {
    final db = await SqliteService.getDatabase();
    await db.rawUpdate(
      'UPDATE user_roms SET id_ra = ?, ra_match_source = ? '
      'WHERE rom_path = ? AND $_notManuallyMatched',
      [gameId, matchSource, romPath],
    );
  }

  /// Assigns a RomM-provided RA game id once the download has been indexed.
  ///
  /// The scanner owns the actual path (especially for Android SAF URIs), so
  /// this deliberately addresses the row by its indexed filename and system.
  /// Manual picks remain authoritative.
  static Future<void> updateRommRomRaGameId(
    String filename,
    String systemId,
    int gameId,
  ) async {
    if (filename.isEmpty || systemId.isEmpty || gameId <= 0) return;
    final db = await SqliteService.getDatabase();
    await db.rawUpdate(
      'UPDATE user_roms SET id_ra = ?, ra_match_source = ? '
      'WHERE filename = ? AND app_system_id = ? AND $_notManuallyMatched',
      [gameId, raMatchRomm, filename, systemId],
    );
  }

  /// Records a match the user chose by hand. Unlike the automatic paths this
  /// always writes, and marks the row so later re-match passes leave it alone.
  static Future<void> setManualRomRaMatch(String romPath, int gameId) async {
    final db = await SqliteService.getDatabase();
    await db.rawUpdate(
      'UPDATE user_roms SET id_ra = ?, ra_match_source = ? WHERE rom_path = ?',
      [gameId, raMatchManual, romPath],
    );
  }

  /// Clears a manual override so the ROM is eligible for automatic matching again.
  static Future<void> clearManualRomRaMatch(String romPath) async {
    final db = await SqliteService.getDatabase();
    await db.rawUpdate(
      'UPDATE user_roms SET id_ra = NULL, ra_match_source = NULL '
      'WHERE rom_path = ?',
      [romPath],
    );
  }

  /// Returns the game id the user chose by hand for [romPath], or null when
  /// the match was established automatically (or not at all).
  ///
  /// Every resolution path must consult this before hashing: the automatic
  /// strategies re-derive an id from the ROM's hash on every read, so without
  /// this check a hand-picked match is written to the database and then
  /// silently ignored by the screen that offered the choice.
  static Future<int?> getManualRomRaGameId(String romPath) async {
    final db = await SqliteService.getDatabase();
    final rows = await db.rawQuery(
      'SELECT id_ra FROM user_roms '
      'WHERE rom_path = ? AND ra_match_source = ? LIMIT 1',
      [romPath, raMatchManual],
    );
    if (rows.isEmpty) return null;
    final value = rows.first['id_ra'];
    if (value == null) return null;
    return int.tryParse(value.toString());
  }

  /// Returns the match source for [romPath], or null if never matched.
  static Future<String?> getRomRaMatchSource(String romPath) async {
    final db = await SqliteService.getDatabase();
    final rows = await db.rawQuery(
      'SELECT ra_match_source FROM user_roms WHERE rom_path = ? LIMIT 1',
      [romPath],
    );
    if (rows.isEmpty) return null;
    return rows.first['ra_match_source']?.toString();
  }

  // ── Bulk match candidates ─────────────────────────────────────────────────

  /// Reasons a ROM could not be hashed, stored in `user_roms.ra_hash_skipped`.
  static const String raSkipMissing = 'missing';
  static const String raSkipOversize = 'oversize';
  static const String raSkipDisc = 'disc';
  static const String raSkipExtractFailed = 'extract_failed';
  static const String raSkipError = 'error';

  /// Systems the hash pass will walk: everything non-disc, plus disc systems
  /// whose policy declares an algorithm that reads inside the image. Without
  /// one, hashing the container produces something RetroAchievements has never
  /// registered. Which algorithms are disc algorithms is the policy's
  /// business, so the names come from it rather than being spelled out here.
  ///
  /// The candidate and coverage queries must share this clause (with
  /// [RaHashAlgo.discJsonNames] as its bound arguments), or the progress bar's
  /// denominator diverges from the work the pass actually does.
  static String get _hashEligibleSystemSql {
    final placeholders = List.filled(
      RaHashAlgo.discJsonNames.length,
      '?',
    ).join(', ');
    return '(COALESCE(s.multidisc, 0) = 0 '
        'OR s.ra_hash_algo IN ($placeholders))';
  }

  /// Rows to feed the bulk hashing pass: ROMs on a RetroAchievements-capable
  /// system that have never been hashed.
  ///
  /// Disc systems join the pass only once their policy declares a disc
  /// algorithm (see [_hashEligibleSystemSql]); RA identifies a disc by its
  /// primary executable rather than the whole image.
  ///
  /// ROMs parked by an earlier run (see [markRomRaHashSkipped]) are excluded
  /// too, so a file that can never be hashed does not reappear every run.
  static Future<List<RaMatchCandidate>> getRomsNeedingRaHash({
    bool includeSkipped = false,
  }) async {
    final db = await SqliteService.getDatabase();
    final rows = await db.rawQuery('''
      SELECT ur.rom_path, ur.filename, ur.ra_hash,
             s.folder_name AS system_folder_name,
             s.ra_id AS system_ra_id,
             s.ra_hash_algo, s.ra_hash_mode
      FROM user_roms ur
      JOIN app_systems s ON ur.app_system_id = s.id
      WHERE (ur.ra_hash IS NULL OR ur.ra_hash = '')
        AND ur.rom_path IS NOT NULL AND ur.rom_path != ''
        AND s.ra_id IS NOT NULL
        ${includeSkipped ? '' : 'AND ur.ra_hash_skipped IS NULL'}
        AND $_hashEligibleSystemSql
      ORDER BY s.folder_name, ur.filename
    ''', RaHashAlgo.discJsonNames);
    return rows.map((r) => RaMatchCandidate.fromRow(Map.from(r))).toList();
  }

  /// Records that [romPath] could not be hashed and why, so the bulk pass stops
  /// revisiting it on every run.
  static Future<void> markRomRaHashSkipped(
    String romPath,
    String reason,
  ) async {
    final db = await SqliteService.getDatabase();
    await db.rawUpdate(
      'UPDATE user_roms SET ra_hash_skipped = ? WHERE rom_path = ?',
      [reason, romPath],
    );
  }

  /// Clears every skip marker so a later pass retries them — for when the user
  /// has fixed the underlying problem (restored a file, replaced a bad dump).
  /// Returns the number of rows re-opened.
  static Future<int> clearRaHashSkips() async {
    final db = await SqliteService.getDatabase();
    return db.rawUpdate(
      'UPDATE user_roms SET ra_hash_skipped = NULL '
      'WHERE ra_hash_skipped IS NOT NULL',
    );
  }

  /// Skip reasons and how many ROMs each accounts for, so the gap can be
  /// reported rather than silently absorbed.
  static Future<Map<String, int>> getRaHashSkipCounts() async {
    final db = await SqliteService.getDatabase();
    final rows = await db.rawQuery('''
      SELECT ra_hash_skipped AS reason, COUNT(*) AS count
      FROM user_roms
      WHERE ra_hash_skipped IS NOT NULL
      GROUP BY ra_hash_skipped
    ''');
    return {
      for (final row in rows)
        row['reason'].toString():
            int.tryParse(row['count']?.toString() ?? '') ?? 0,
    };
  }

  /// How much of the hashable library has been hashed, for progress that
  /// reflects the library rather than the work left in one run.
  ///
  /// Without this the progress bar restarts at 0% on every run — the pass
  /// resumes correctly (hashed ROMs are excluded from the candidate query) but
  /// a per-run percentage makes it look like it started over.
  static Future<({int eligible, int hashed})> getRaHashCoverage() async {
    final db = await SqliteService.getDatabase();
    final rows = await db.rawQuery('''
      SELECT COUNT(*) AS eligible,
             SUM(CASE WHEN ur.ra_hash IS NOT NULL AND ur.ra_hash != ''
                      THEN 1 ELSE 0 END) AS hashed
      FROM user_roms ur
      JOIN app_systems s ON ur.app_system_id = s.id
      WHERE ur.rom_path IS NOT NULL AND ur.rom_path != ''
        AND s.ra_id IS NOT NULL
        AND ur.ra_hash_skipped IS NULL
        AND $_hashEligibleSystemSql
    ''', RaHashAlgo.discJsonNames);
    if (rows.isEmpty) return (eligible: 0, hashed: 0);
    return (
      eligible: int.tryParse(rows.first['eligible']?.toString() ?? '') ?? 0,
      hashed: int.tryParse(rows.first['hashed']?.toString() ?? '') ?? 0,
    );
  }

  /// Rows the cheap lookup-only pass can fix: a hash is already stored but no
  /// game id was ever resolved from it. No file I/O is needed to retry these,
  /// so this is safe to run after the bundled RA database changes.
  ///
  /// Manually matched rows are excluded — they are already correct by
  /// definition, and re-running the lookup on them would be wasted work.
  static Future<List<RaMatchCandidate>> getRomsNeedingRaGameId() async {
    final db = await SqliteService.getDatabase();
    final rows = await db.rawQuery('''
      SELECT ur.rom_path, ur.filename, ur.ra_hash,
             s.folder_name AS system_folder_name,
             s.ra_id AS system_ra_id,
             s.ra_hash_algo, s.ra_hash_mode
      FROM user_roms ur
      JOIN app_systems s ON ur.app_system_id = s.id
      WHERE ur.ra_hash IS NOT NULL AND ur.ra_hash != ''
        AND ur.id_ra IS NULL
        AND s.ra_id IS NOT NULL
        AND $_notManuallyMatched
      ORDER BY s.folder_name, ur.filename
    ''');
    return rows.map((r) => RaMatchCandidate.fromRow(Map.from(r))).toList();
  }

  // ── Manual match search ───────────────────────────────────────────────────

  /// Searches the local RA catalogue for games on [consoleRaId] whose title
  /// matches [query], for the "this isn't the right game" picker.
  ///
  /// The table holds one row per registered hash, so results are collapsed to
  /// one entry per game. Main sets sort ahead of subsets and hacks, which is
  /// what the user almost always wants; the rest are still listed.
  static Future<List<RaGameListEntry>> searchRaGamesByTitle(
    String consoleRaId,
    String query, {
    int limit = 60,
  }) async {
    final trimmed = query.trim();
    if (trimmed.isEmpty) return [];

    final db = await SqliteService.getDatabase();
    final pattern = '%${trimmed.replaceAll(' ', '%')}%';
    final rows = await db.rawQuery(
      '''
      SELECT game_id, title,
             MAX(num_achievements) AS num_achievements,
             MAX(points) AS points
      FROM app_ra_game_list
      WHERE console_id = ? AND title LIKE ?
      GROUP BY game_id, title
      ORDER BY
        CASE WHEN title LIKE '%[Subset%' THEN 1 ELSE 0 END,
        CASE WHEN title LIKE '~%' THEN 1 ELSE 0 END,
        LENGTH(title) ASC,
        title ASC
      LIMIT ?
      ''',
      [consoleRaId, pattern, limit],
    );
    return rows.map((r) => RaGameListEntry.fromRow(Map.from(r))).toList();
  }

  /// Returns the snapshot entry for [gameId], or null when the bundled
  /// database has no row for it.
  static Future<RaGameListEntry?> getRaGameById(int gameId) async {
    final db = await SqliteService.getDatabase();
    final rows = await db.rawQuery(
      '''
      SELECT game_id, title,
             MAX(num_achievements) AS num_achievements,
             MAX(points) AS points
      FROM app_ra_game_list
      WHERE game_id = ?
      GROUP BY game_id, title
      LIMIT 1
      ''',
      [gameId],
    );
    if (rows.isEmpty) return null;
    return RaGameListEntry.fromRow(Map.from(rows.first));
  }

  // ── Game ID lookups (for RA game matching) ────────────────────────────────

  /// Resolves RA game_id by MD5 hash, preferring the ROM's own console.
  ///
  /// Falls back to a console-agnostic lookup when the scoped one finds
  /// nothing. An MD5 is unique in practice, so restricting it to one console
  /// buys no safety — it only loses matches whenever a ROM sits in a folder
  /// whose RA console differs from the one its set is registered under: 32X
  /// titles kept in a Mega Drive folder, a Game Boy set for a ROM filed under
  /// Game Boy Color, an SG-1000 title in a Master System folder. Those are
  /// correct matches for the exact dump, and the lazy per-game path already
  /// accepted them, so the scoped-only lookup just made the two paths
  /// disagree.
  static Future<int?> getGameIdByHash(String raHash, String raConsoleId) async {
    final scoped = await SqliteService.getRetroAchievementsGameIdByHash(
      raHash,
      raConsoleId,
    );
    if (scoped != null && scoped != 0) return scoped;

    final anyConsole = await findGameIdByHash(raHash);
    return (anyConsole == null || anyConsole == 0) ? null : anyConsole;
  }

  // ── ROM RA-data update ─────────────────────────────────────────────────────

  /// Finds a matching entry in app_ra_game_list by [consoleName] LIKE and
  /// [titleLikePattern] LIKE. Normal games are preferred over subsets and
  /// hacks, unless [preferHackMatches] is true. Returns {hash, gameId} or null.
  static Future<({String hash, int? gameId})?> findRAHashByConsoleName(
    String consoleName,
    String titleLikePattern, {
    bool preferHackMatches = false,
  }) async {
    final db = await SqliteService.getDatabase();
    final results = await db.rawQuery(
      '''
      SELECT hash, game_id
      FROM app_ra_game_list
      WHERE console_name LIKE ? AND title LIKE ?
      ORDER BY
        CASE
          WHEN ? = 1 AND title LIKE '~Hack~%' THEN 0
          WHEN ? = 1 THEN 1
          WHEN ? = 0 AND title LIKE '~Hack~%' THEN 1
          ELSE 0
        END,
        CASE WHEN title LIKE '%[Subset%' THEN 1 ELSE 0 END,
        LENGTH(title) ASC,
        title ASC
      LIMIT 1
      ''',
      [
        '%$consoleName%',
        titleLikePattern,
        preferHackMatches ? 1 : 0,
        preferHackMatches ? 1 : 0,
        preferHackMatches ? 1 : 0,
      ],
    );
    if (results.isEmpty) return null;
    return (
      hash: results.first['hash'].toString(),
      gameId: int.tryParse(results.first['game_id']?.toString() ?? ''),
    );
  }

  /// Updates user_roms ra_hash and id_ra for a ROM identified by [filename] and [systemId].
  ///
  /// The hash is always refreshed; the match itself is left alone when the user
  /// set it by hand, so a re-hash pass never discards a manual choice.
  static Future<void> updateRomRAData(
    String filename,
    String systemId,
    String hash,
    int? gameId, {
    String matchSource = raMatchHash,
  }) async {
    final db = await SqliteService.getDatabase();
    await db.rawUpdate(
      'UPDATE user_roms SET ra_hash = ? WHERE filename = ? AND app_system_id = ?',
      [hash, filename, systemId],
    );
    await db.rawUpdate(
      'UPDATE user_roms SET id_ra = ?, ra_match_source = ? '
      'WHERE filename = ? AND app_system_id = ? AND $_notManuallyMatched',
      [gameId, matchSource, filename, systemId],
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
  ///
  /// Subsets are never returned. A `[Subset - ...]` entry is an extra
  /// achievement set bolted onto a game, so it is never the right answer for a
  /// plain ROM — but the deprioritising it used to get only applied among rows
  /// the LIKE pattern had already reached, and when the main set's title
  /// differs from the filename by punctuation the subset is the only candidate
  /// left and wins outright. That is issue #8's partial-set report. A user who
  /// genuinely wants the subset picks it in the manual match dialog, which
  /// lists them.
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
    final preferHackMatches = filenameWithoutExt.toLowerCase().contains('hack');

    // Several candidates are read rather than one so the runners-up can be
    // logged: a wrong filename match is otherwise invisible, and this path only
    // runs for systems with no usable hash algorithm, where it is the only
    // thing standing between a ROM and no match at all.
    final likeResults = await db.rawQuery(
      '''
      SELECT g.game_id, g.title
      FROM app_ra_game_list g
      WHERE g.console_id = ($consoleSubquery)
        AND g.title LIKE ?
        AND g.title NOT LIKE '%[Subset%'
      ORDER BY
        CASE
          WHEN ? = 1 AND g.title LIKE '~Hack~%' THEN 0
          WHEN ? = 1 THEN 1
          WHEN ? = 0 AND g.title LIKE '~Hack~%' THEN 1
          ELSE 0
        END,
        LENGTH(g.title) ASC,
        g.title ASC
      LIMIT 5
      ''',
      [
        systemFolderName,
        searchPattern,
        preferHackMatches ? 1 : 0,
        preferHackMatches ? 1 : 0,
        preferHackMatches ? 1 : 0,
      ],
    );
    if (likeResults.isEmpty) return null;

    if (likeResults.length > 1) {
      final runnersUp = likeResults
          .skip(1)
          .map((r) => r['title']?.toString() ?? '')
          .join(', ');
      _log.d(
        'RA filename match: "$filenameWithoutExt" -> '
        '"${likeResults.first['title']}" (also matched: $runnersUp)',
      );
    }

    return int.tryParse(likeResults.first['game_id']?.toString() ?? '0') ?? 0;
  }

  static Future<OwnedWeekGameResolution?> findBestLocalGameByRaGameId(
    int raGameId,
  ) async {
    final db = await SqliteService.getDatabase();
    final results = await db.rawQuery(
      '''
      SELECT
        ur.*,
        s.folder_name AS system_folder_name,
        s.real_name AS system_real_name,
        s.short_name AS system_short_name
      FROM user_roms ur
      JOIN app_systems s ON ur.app_system_id = s.id
      WHERE ur.id_ra = ?
      ORDER BY
        CASE WHEN ur.last_played IS NULL THEN 1 ELSE 0 END ASC,
        ur.last_played DESC,
        ur.is_favorite DESC,
        LOWER(COALESCE(ur.title_name, ur.filename)) ASC
      LIMIT 1
      ''',
      [raGameId],
    );
    if (results.isEmpty) return null;

    final game = DatabaseGameModel.fromJson(
      Map<String, dynamic>.from(results.first),
    );
    return OwnedWeekGameResolution(raGameId: raGameId, game: game);
  }
}
