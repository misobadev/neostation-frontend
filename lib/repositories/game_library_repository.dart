import '../constants/system_folder_names.dart';
import '../data/datasources/sqlite_service.dart';
import '../models/rom_fingerprint.dart';
import '../services/logger_service.dart';

/// The scraped game library every metadata provider reads and writes: the
/// detected systems, the ROMs still to scrape, each game's metadata row and
/// the ROM fingerprints matching uses.
///
/// Provider-neutral on purpose. The game lists read this one library, so a
/// game keeps what was scraped for it whichever provider is active. Each
/// provider keeps its own account and settings elsewhere.
///
/// The metadata table keeps its historical name,
/// `user_screenscraper_metadata`.
class GameLibraryRepository {
  GameLibraryRepository._();

  static final _log = LoggerService.instance;

  /// `user_screenscraper_metadata.is_fully_scraped` once a game's media have
  /// downloaded: "New content only" leaves the game alone.
  static const int scrapedFully = 1;

  /// `is_fully_scraped` for a game scraped while every media type was switched
  /// off: "New content only" leaves it alone until a media type is switched
  /// on, then fetches its media.
  static const int scrapedMetadataOnly = 2;

  /// Returns every detected system, ordered by name, with its short name and
  /// visible game count, whatever metadata provider knows it. Callers filter by what their provider supports.
  static Future<List<Map<String, dynamic>>> getDetectedSystems() async {
    final db = await SqliteService.getDatabase();
    final results = await db.rawQuery('''
      SELECT s.id, s.real_name, s.short_name, s.folder_name,
             (SELECT COUNT(*) FROM user_roms ur
               WHERE ur.app_system_id = s.id AND ur.is_hidden = 0) AS rom_count
      FROM user_detected_systems uds
      JOIN app_systems s ON uds.app_system_id = s.id
      WHERE s.folder_name != 'android-apps'
      ORDER BY s.real_name
    ''');
    return results
        .map(
          (row) => {
            'id': row['id'].toString(),
            'name': row['real_name'].toString(),
            'short_name': (row['short_name'] ?? row['real_name']).toString(),
            'folder_name': row['folder_name'].toString(),
            'rom_count': row['rom_count'] as int? ?? 0,
          },
        )
        .toList();
  }

  /// The app language (`user_config.app_language`), English by default.
  static Future<String> getAppLanguage() async {
    try {
      final db = await SqliteService.getDatabase();
      final rows = await db.rawQuery(
        'SELECT app_language FROM user_config LIMIT 1',
      );
      final value = rows.isEmpty ? null : rows.first['app_language'];
      final code = value?.toString() ?? '';
      return code.isEmpty ? 'en' : code;
    } catch (e) {
      _log.w('Could not read the app language: $e');
      return 'en';
    }
  }

  /// Saves the metadata to the local user_screenscraper_metadata table.
  static Future<bool> saveGameMetadata(
    Map<String, dynamic> metadata,
    String appSystemId, {
    bool isFullyScraped = false,
  }) async {
    // "Android Games" rows, and so their metadata, live under `android`.
    appSystemId = SystemFolderNames.rowSystemFolder(appSystemId);
    try {
      final db = await SqliteService.getDatabase();
      metadata['app_system_id'] = appSystemId;
      metadata['is_fully_scraped'] = isFullyScraped ? 1 : 0;
      metadata['updated_at'] = DateTime.now().toIso8601String();

      await db.insert(
        'user_screenscraper_metadata',
        metadata,
        conflictAlgorithm: ConflictAlgorithm.replace,
      );

      return true;
    } catch (e) {
      _log.e('Error saving game metadata: $e');
      return false;
    }
  }

  /// Saves a provider's match for a "New content only" session without
  /// replacing what the game already has.
  ///
  /// With no row this is [saveGameMetadata]. An existing row keeps every
  /// non-empty column and only its empty ones are filled from [metadata]: the
  /// session reaches games not yet fully scraped, and their metadata may be
  /// the user's own (the metadata editor) or an ES-DE import, which a match
  /// with less information would otherwise blank. Columns the match doesn't
  /// carry (ES-DE's media subfolder, the RetroAchievements id) stay as they
  /// are.
  ///
  /// The file name is matched exactly, as the session's selection and
  /// [markGameFullyScraped] match it: a row differing only in case isn't this
  /// game's, so the match gets a row of its own, as [saveGameMetadata] gives it.
  ///
  /// As with [saveGameMetadata], the game isn't finished until its media are
  /// (`is_fully_scraped` = 0), and it no longer counts as an ES-DE import, so
  /// an ES-DE reset keeps it.
  static Future<bool> fillGameMetadataGaps(
    Map<String, dynamic> metadata,
    String appSystemId,
  ) async {
    // "Android Games" rows, and so their metadata, live under `android`.
    appSystemId = SystemFolderNames.rowSystemFolder(appSystemId);
    try {
      final db = await SqliteService.getDatabase();
      final filename = metadata['filename'];
      final existing = await db.query(
        'user_screenscraper_metadata',
        where: 'app_system_id = ? AND filename = ?',
        whereArgs: [appSystemId, filename],
        limit: 1,
      );
      if (existing.isEmpty) {
        return await saveGameMetadata(metadata, appSystemId);
      }

      final row = existing.first;
      final toWrite = <String, dynamic>{};
      // Regional names drive the title on a language change, so they only
      // come along when the title is the match's too: a title the game
      // already has (the user's, or an import) must not be replaced later.
      if (!_isBlank(row['real_name']) &&
          row['real_name'] != metadata['real_name']) {
        metadata = Map<String, dynamic>.from(metadata)
          ..remove('regional_names');
      }
      metadata.forEach((col, val) {
        if (const {
          'app_system_id',
          'filename',
          'is_fully_scraped',
          'updated_at',
        }.contains(col)) {
          return;
        }
        if (!_isBlank(val) && _isBlank(row[col])) toWrite[col] = val;
      });
      toWrite['is_fully_scraped'] = 0;
      toWrite['esde_imported'] = 0;
      toWrite['updated_at'] = DateTime.now().toIso8601String();

      await db.update(
        'user_screenscraper_metadata',
        toWrite,
        where: 'app_system_id = ? AND filename = ?',
        whereArgs: [appSystemId, filename],
      );
      return true;
    } catch (e) {
      _log.e('Error filling game metadata gaps: $e');
      return false;
    }
  }

  /// The games on [appSystemId] with a NeoAssets video link (see
  /// `video_url`), as file name and link.
  static Future<List<({String filename, String url})>> getVideoLinks(
    String appSystemId,
  ) async {
    // "Android Games" rows, and so their metadata, live under `android`.
    appSystemId = SystemFolderNames.rowSystemFolder(appSystemId);
    try {
      final db = await SqliteService.getDatabase();
      final rows = await db.query(
        'user_screenscraper_metadata',
        columns: ['filename', 'video_url'],
        where:
            "app_system_id = ? AND video_url IS NOT NULL AND video_url != ''",
        whereArgs: [appSystemId],
      );
      return [
        for (final row in rows)
          (
            filename: row['filename'].toString(),
            url: row['video_url'].toString(),
          ),
      ];
    } catch (e) {
      _log.w('Could not read the video links of $appSystemId: $e');
      return [];
    }
  }

  /// Marks a game's metadata on [appSystemId] as fully scraped, or, with
  /// [metadataOnly], as scraped while every media type was switched off.
  static Future<void> markGameFullyScraped(
    String appSystemId,
    String filename, {
    bool metadataOnly = false,
  }) async {
    // "Android Games" rows, and so their metadata, live under `android`.
    appSystemId = SystemFolderNames.rowSystemFolder(appSystemId);
    final db = await SqliteService.getDatabase();
    await db.update(
      'user_screenscraper_metadata',
      {
        'is_fully_scraped': metadataOnly ? scrapedMetadataOnly : scrapedFully,
        'updated_at': DateTime.now().toIso8601String(),
      },
      where: 'app_system_id = ? AND filename = ?',
      whereArgs: [appSystemId, filename],
    );
  }

  /// Clears a game's finished mark on [appSystemId] while its media are
  /// fetched again, so "New content only" retries the game if they fail.
  /// Saving metadata clears the mark too; this is for when none is saved.
  static Future<void> markGameUnfinished(
    String appSystemId,
    String filename,
  ) async {
    // "Android Games" rows, and so their metadata, live under `android`.
    appSystemId = SystemFolderNames.rowSystemFolder(appSystemId);
    final db = await SqliteService.getDatabase();
    await db.update(
      'user_screenscraper_metadata',
      {'is_fully_scraped': 0, 'updated_at': DateTime.now().toIso8601String()},
      where: 'app_system_id = ? AND filename = ? AND is_fully_scraped != 0',
      whereArgs: [appSystemId, filename],
    );
  }

  /// The `WHERE` condition that limits a scrape to what [scrapeMode] still
  /// has to do: for "New content only", games never scraped or not finished,
  /// plus games scraped for metadata only once [mediaWanted] (the provider has
  /// a media type switched on).
  static String _scrapeModeFilter(
    String scrapeMode, {
    required bool mediaWanted,
  }) {
    if (scrapeMode != 'new_only') return '';
    final metadataOnly = mediaWanted
        ? ' OR usm.is_fully_scraped = $scrapedMetadataOnly'
        : '';
    return 'AND (usm.filename IS NULL OR usm.is_fully_scraped = 0$metadataOnly)';
  }

  /// Returns the count of ROMs eligible for scraping for a given system.
  static Future<int> getRomCountForScraping(
    String appSystemId,
    String scrapeMode, {
    required bool mediaWanted,
  }) async {
    final filter = _scrapeModeFilter(scrapeMode, mediaWanted: mediaWanted);
    final db = await SqliteService.getDatabase();
    final result = await db.rawQuery(
      '''SELECT COUNT(*) as count FROM user_roms ur LEFT JOIN user_screenscraper_metadata usm ON ur.app_system_id = usm.app_system_id AND ur.filename = usm.filename
       WHERE ur.app_system_id = ? $filter''',
      [appSystemId],
    );
    return int.tryParse(result.first['count']?.toString() ?? '0') ?? 0;
  }

  /// Returns the list of ROMs eligible for scraping for a given system.
  static Future<List<Map<String, dynamic>>> getRomsForScraping(
    String appSystemId,
    String scrapeMode, {
    required bool mediaWanted,
  }) async {
    final filter = _scrapeModeFilter(scrapeMode, mediaWanted: mediaWanted);
    final db = await SqliteService.getDatabase();
    return await db.rawQuery(
      '''SELECT ur.filename, ur.rom_path, ur.title_name, usm.is_fully_scraped
       FROM user_roms ur LEFT JOIN user_screenscraper_metadata usm ON ur.app_system_id = usm.app_system_id AND ur.filename = usm.filename
       WHERE ur.app_system_id = ? $filter''',
      [appSystemId],
    );
  }

  /// Returns the "Android Games" apps eligible for scraping: the `android`
  /// rows the user marked as games, with the same columns and [scrapeMode]
  /// filter as [getRomsForScraping].
  static Future<List<Map<String, dynamic>>> getAndroidGamesForScraping(
    String scrapeMode, {
    required bool mediaWanted,
  }) async {
    final filter = _scrapeModeFilter(scrapeMode, mediaWanted: mediaWanted);
    final db = await SqliteService.getDatabase();
    return await db.rawQuery(
      '''SELECT ur.filename, ur.rom_path, ur.title_name, usm.is_fully_scraped
       FROM user_roms ur LEFT JOIN user_screenscraper_metadata usm ON ur.app_system_id = usm.app_system_id AND ur.filename = usm.filename
       WHERE ur.app_system_id = ? AND ${SqliteService.androidGameFlagSql} $filter''',
      [SystemFolderNames.android],
    );
  }

  /// Returns the cached dump identity for [romPath], or null if it has never
  /// been fingerprinted.
  ///
  /// A row with only a crc32 is normal and complete: the zip fast path yields
  /// crc and size without ever decompressing, and crc alone resolves a
  /// metadata lookup.
  static Future<RomFingerprint?> getRomFingerprint(String romPath) async {
    try {
      final db = await SqliteService.getDatabase();
      final rows = await db.rawQuery(
        'SELECT ss_hash, rom_crc32, rom_size FROM user_roms '
        'WHERE rom_path = ? LIMIT 1',
        [romPath],
      );
      if (rows.isEmpty) return null;

      final row = rows.first;
      final crc = row['rom_crc32']?.toString();
      final md5 = row['ss_hash']?.toString();
      if ((crc == null || crc.isEmpty) && (md5 == null || md5.isEmpty)) {
        return null;
      }

      return RomFingerprint(
        crc32: crc ?? '',
        md5: (md5 != null && md5.isNotEmpty) ? md5 : null,
        sizeBytes: (row['rom_size'] as int?) ?? 0,
      );
    } catch (e) {
      _log.e('Error reading ROM fingerprint for $romPath: $e');
      return null;
    }
  }

  /// Returns why [romPath] was parked by an earlier fingerprint attempt, or
  /// null if it is not parked. The read half of [markRomFingerprintSkipped]:
  /// without it the marker is write-only and every scrape re-walks the ROM.
  static Future<String?> getRomFingerprintSkipReason(String romPath) async {
    try {
      final db = await SqliteService.getDatabase();
      final rows = await db.rawQuery(
        'SELECT rom_fingerprint_skipped FROM user_roms '
        'WHERE rom_path = ? LIMIT 1',
        [romPath],
      );
      if (rows.isEmpty) return null;
      final reason = rows.first['rom_fingerprint_skipped']?.toString();
      return (reason == null || reason.isEmpty) ? null : reason;
    } catch (e) {
      _log.e('Error reading fingerprint skip reason for $romPath: $e');
      return null;
    }
  }

  /// Caches [fingerprint] against [romPath] and clears any skip marker, since
  /// a value now exists.
  static Future<void> updateRomFingerprint(
    String romPath,
    RomFingerprint fingerprint,
  ) async {
    try {
      final db = await SqliteService.getDatabase();
      await db.rawUpdate(
        'UPDATE user_roms SET rom_crc32 = ?, rom_size = ?, '
        // Never blank an md5 the slow path already produced: the cheap zip
        // path returns crc only, and re-running it must not lose the md5.
        'ss_hash = COALESCE(?, ss_hash), rom_fingerprint_skipped = NULL '
        'WHERE rom_path = ?',
        [fingerprint.crc32, fingerprint.sizeBytes, fingerprint.md5, romPath],
      );
    } catch (e) {
      _log.e('Error saving ROM fingerprint for $romPath: $e');
    }
  }

  /// Records that [romPath] could not be fingerprinted and why, so a bulk pass
  /// stops revisiting it. Mirrors `markRomRaHashSkipped`.
  static Future<void> markRomFingerprintSkipped(
    String romPath,
    String reason,
  ) async {
    try {
      final db = await SqliteService.getDatabase();
      await db.rawUpdate(
        'UPDATE user_roms SET rom_fingerprint_skipped = ? WHERE rom_path = ?',
        [reason, romPath],
      );
    } catch (e) {
      _log.e('Error marking ROM fingerprint skipped for $romPath: $e');
    }
  }

  /// Null, or a string with nothing but white space.
  static bool _isBlank(Object? value) =>
      value == null || (value is String && value.trim().isEmpty);
}
