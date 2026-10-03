import 'dart:convert';

import '../data/datasources/sqlite_service.dart';
import '../models/rom_fingerprint.dart';
import '../services/credential_store.dart';
import 'package:neostation/services/logger_service.dart';

class MetadataTransferResult {
  final String appSystemId;
  final bool metadataTransferred;

  const MetadataTransferResult({
    required this.appSystemId,
    required this.metadataTransferred,
  });
}

/// Repository for ScreenScraper system configuration data access.
class ScraperRepository {
  static final _log = LoggerService.instance;

  /// Returns detected systems that have a ScreenScraper ID, ordered by name.
  static Future<List<Map<String, dynamic>>> getScraperSystems() async {
    final db = await SqliteService.getDatabase();

    final results = await db.rawQuery('''
      SELECT
        s.id,
        s.real_name,
        s.folder_name,
        s.screenscraper_id,
        s.ra_id
      FROM user_detected_systems uds
      JOIN app_systems s ON uds.app_system_id = s.id
      WHERE s.folder_name != 'android-apps'
        AND s.screenscraper_id IS NOT NULL
        AND s.screenscraper_id != 0
      ORDER BY s.real_name
    ''');

    return results
        .map(
          (row) => {
            'id': row['id'].toString(),
            'screenscraper_id': int.tryParse(
              row['screenscraper_id']?.toString() ?? '',
            ),
            'ra_id': int.tryParse(row['ra_id']?.toString() ?? ''),
            'name': row['real_name'].toString(),
            'folder_name': row['folder_name'].toString(),
            'color': '#9E9E9E',
          },
        )
        .toList();
  }

  /// Returns current enabled/disabled config per system ID.
  /// Defaults all to enabled when no config row exists.
  static Future<Map<String, bool>> getSystemScraperConfig() async {
    final db = await SqliteService.getDatabase();

    final results = await db.query('user_screenscraper_system_config');

    if (results.isEmpty) {
      final systems = await getScraperSystems();
      return {for (final s in systems) s['id'].toString(): true};
    }

    return {
      for (final row in results)
        row['app_system_id'].toString():
            (int.tryParse(row['enabled']?.toString() ?? '0') ?? 0) == 1,
    };
  }

  /// Saves the enabled state for a single system. Returns false on error.
  static Future<bool> saveSystemConfig(String systemId, bool enabled) async {
    try {
      final db = await SqliteService.getDatabase();
      await db.rawInsert(
        'INSERT OR REPLACE INTO user_screenscraper_system_config (app_system_id, enabled) VALUES (?, ?)',
        [systemId, enabled ? 1 : 0],
      );
      return true;
    } catch (e) {
      _log.e('Error saving scraper system config: $e');
      return false;
    }
  }

  /// Saves the enabled state for all given system IDs in a single transaction.
  static Future<void> saveAllSystemsConfig(
    List<String> systemIds,
    bool enabled,
  ) async {
    final db = await SqliteService.getDatabase();
    await db.execute('BEGIN');
    try {
      for (final id in systemIds) {
        await db.rawInsert(
          'INSERT OR REPLACE INTO user_screenscraper_system_config (app_system_id, enabled) VALUES (?, ?)',
          [id, enabled ? 1 : 0],
        );
      }
      await db.execute('COMMIT');
    } catch (e) {
      _log.e('Error saving all scraper systems config: $e');
      await db.execute('ROLLBACK');
      rethrow;
    }
  }

  // ── Credentials ───────────────────────────────────────────────────────────

  /// Credential store key for the ScreenScraper password. Stable: changing it
  /// strands existing logins.
  static const String _passwordKey = 'screenscraper_password';

  /// Persists ScreenScraper credentials and user tier information.
  ///
  /// The password goes to [CredentialStore]; everything else, including all the
  /// non-secret tier data, stays in `user_screenscraper_credentials`. The
  /// `password` column is only written when nothing could store the secret.
  static Future<bool> saveCredentials(
    String username,
    String password, [
    Map<String, dynamic>? userInfo,
    String? preferredLanguage,
  ]) async {
    try {
      final db = await SqliteService.getDatabase();
      final passwordColumn = await _storeSecret(password);

      final dataToSave = <String, dynamic>{
        'id': 1,
        'username': username,
        'password': passwordColumn,
      };

      if (userInfo != null) {
        dataToSave['user_id'] = userInfo['numid']?.toString() ?? '';
        dataToSave['level'] = userInfo['niveau']?.toString() ?? '';
        dataToSave['contribution'] = userInfo['contribution']?.toString() ?? '';
        dataToSave['maxthreads'] = userInfo['maxthreads']?.toString() ?? '';
        dataToSave['requests_today'] =
            int.tryParse(userInfo['requeststoday']?.toString() ?? '0') ?? 0;
        dataToSave['max_requests_per_day'] =
            int.tryParse(userInfo['maxrequestsperday']?.toString() ?? '0') ?? 0;
        dataToSave['requests_ko_today'] =
            int.tryParse(userInfo['requestskotoday']?.toString() ?? '0') ?? 0;
        dataToSave['max_requests_ko_per_day'] =
            int.tryParse(userInfo['maxrequestskoperday']?.toString() ?? '0') ??
            0;
        dataToSave['max_download_speed'] =
            int.tryParse(userInfo['maxdownloadspeed']?.toString() ?? '0') ?? 0;
        dataToSave['visites'] =
            int.tryParse(userInfo['visites']?.toString() ?? '0') ?? 0;
        dataToSave['last_visit'] =
            userInfo['datedernierevisite']?.toString() ?? '';
        dataToSave['fav_region'] = userInfo['fav_region']?.toString() ?? '';
      }

      if (preferredLanguage != null) {
        dataToSave['preferred_language'] = preferredLanguage;
      }

      await db.insert(
        'user_screenscraper_credentials',
        dataToSave,
        conflictAlgorithm: ConflictAlgorithm.replace,
      );

      return true;
    } catch (e) {
      _log.e('Error saving scraper credentials: $e');
      return false;
    }
  }

  /// Retrieves the saved ScreenScraper credentials from the database.
  static Future<Map<String, String>?> getSavedCredentials() async {
    try {
      final db = await SqliteService.getDatabase();
      final result = await db.query('user_screenscraper_credentials');

      if (result.isNotEmpty) {
        final row = result.first;
        final password = await _readSecret(row['password']);

        return {
          'username': row['username'].toString(),
          'password': password,
          'id': row['user_id']?.toString() ?? '',
          'level': row['level']?.toString() ?? '',
          'contribution': row['contribution']?.toString() ?? '',
          'maxthreads': row['maxthreads']?.toString() ?? '',
          'requests_today':
              (int.tryParse(row['requests_today']?.toString() ?? '0') ?? 0)
                  .toString(),
          'max_requests_per_day':
              (int.tryParse(row['max_requests_per_day']?.toString() ?? '0') ??
                      0)
                  .toString(),
          'requests_ko_today':
              (int.tryParse(row['requests_ko_today']?.toString() ?? '0') ?? 0)
                  .toString(),
          'max_requests_ko_per_day':
              (int.tryParse(
                        row['max_requests_ko_per_day']?.toString() ?? '0',
                      ) ??
                      0)
                  .toString(),
          'max_download_speed':
              (int.tryParse(row['max_download_speed']?.toString() ?? '0') ?? 0)
                  .toString(),
          'visites': (int.tryParse(row['visites']?.toString() ?? '0') ?? 0)
              .toString(),
          'last_visit': row['last_visit']?.toString() ?? '',
          'fav_region': row['fav_region']?.toString() ?? '',
          'preferred_language': row['preferred_language']?.toString() ?? 'en',
        };
      }

      return null;
    } catch (e) {
      _log.e('Error getting scraper credentials: $e');
      return null;
    }
  }

  /// Deletes saved credentials from the local database and the credential
  /// store. The store is cleared first and unconditionally, so a failure to
  /// delete the row cannot leave an orphaned password in the keychain.
  static Future<bool> clearCredentials() async {
    await CredentialStore.delete(_passwordKey);

    try {
      final db = await SqliteService.getDatabase();
      await db.delete('user_screenscraper_credentials');
      return true;
    } catch (e) {
      _log.e('Error clearing scraper credentials: $e');
      return false;
    }
  }

  /// Moves a legacy base64 password out of the database at startup.
  ///
  /// Unlike RomM, nothing reads ScreenScraper credentials on launch, so a user
  /// who set the scraper up once and never scraped again would keep their
  /// password in `data.sqlite` indefinitely. This sweep is the only thing that
  /// reaches them. It is a no-op once the column is empty, so it costs one
  /// query per launch after the first.
  ///
  /// Best effort by design: it must never throw into app startup, and it
  /// deliberately does nothing when there is no legacy value to move.
  static Future<void> migrateLegacyPasswordToCredentialStore() async {
    try {
      final db = await SqliteService.getDatabase();
      final result = await db.query(
        'user_screenscraper_credentials',
        columns: ['password'],
        limit: 1,
      );
      if (result.isEmpty) return;

      final legacy = _decodeSecret(result.first['password']);
      if (legacy.isEmpty) return;

      final outcome = await CredentialStore.write(_passwordKey, legacy);
      if (outcome == CredentialWriteOutcome.sessionOnly) {
        _log.w(
          'ScreenScraper: the password could not be persisted; '
          'leaving it in the database',
        );
        return;
      }

      await _blankPasswordColumn();
      _log.i(
        'ScreenScraper: moved the password out of the database into the '
        'credential store',
      );
    } catch (e) {
      _log.e('Error migrating the ScreenScraper password: $e');
    }
  }

  /// Persists [value] and returns what the `password` column should hold:
  /// empty once the credential store has it, or the base64 fallback when
  /// nothing could be persisted.
  static Future<String> _storeSecret(String value) async {
    if (value.isEmpty) {
      await CredentialStore.delete(_passwordKey);
      return '';
    }

    final outcome = await CredentialStore.write(_passwordKey, value);
    if (outcome == CredentialWriteOutcome.sessionOnly) {
      _log.w(
        'ScreenScraper: the password could not be persisted; '
        'keeping it in the database',
      );
      return base64Encode(utf8.encode(value));
    }
    return '';
  }

  /// Returns the password, preferring [CredentialStore] and falling back to the
  /// legacy base64 [column], writing through and emptying the column only once
  /// the store confirms a persistent write.
  ///
  /// Any read failure means "could not look", never "no password": the column
  /// is used as-is and left untouched.
  static Future<String> _readSecret(Object? column) async {
    try {
      final stored = await CredentialStore.read(_passwordKey);
      if (stored != null && stored.isNotEmpty) return stored;
    } catch (e) {
      _log.w('ScreenScraper: credential store unreadable: $e');
      return _decodeSecret(column);
    }

    final legacy = _decodeSecret(column);
    if (legacy.isEmpty) return '';

    final outcome = await CredentialStore.write(_passwordKey, legacy);
    if (outcome == CredentialWriteOutcome.sessionOnly) {
      _log.w(
        'ScreenScraper: the password could not be persisted; '
        'leaving it in the database',
      );
      return legacy;
    }

    await _blankPasswordColumn();
    _log.i(
      'ScreenScraper: moved the password out of the database into the '
      'credential store',
    );
    return legacy;
  }

  /// Empties the legacy `password` column once the value lives in the
  /// credential store. Best effort: a failure only delays the cleanup to the
  /// next read.
  static Future<void> _blankPasswordColumn() async {
    try {
      final db = await SqliteService.getDatabase();
      await db.update(
        'user_screenscraper_credentials',
        {'password': ''},
        where: 'id = ?',
        whereArgs: [1],
      );
    } catch (e) {
      _log.e('Error clearing the ScreenScraper password column: $e');
    }
  }

  /// Decodes a legacy base64 secret, tolerating a null/absent column and any
  /// value that isn't valid base64 (both read back as "not set"). The old read
  /// path decoded unguarded, so a null column threw and was reported as having
  /// no credentials at all.
  static String _decodeSecret(Object? stored) {
    final encoded = stored?.toString();
    if (encoded == null || encoded.isEmpty || encoded == 'null') return '';
    try {
      return utf8.decode(base64Decode(encoded));
    } catch (_) {
      return '';
    }
  }

  // ── Scraper config ────────────────────────────────────────────────────────

  /// Retrieves the current scraper configuration (modes and media types to fetch).
  static Future<Map<String, dynamic>> getScraperConfig() async {
    try {
      final db = await SqliteService.getDatabase();
      final result = await db.query('user_screenscraper_config');

      if (result.isNotEmpty) {
        final row = result.first;
        return {
          'scrape_mode': row['scrape_mode'].toString(),
          'scrape_metadata':
              (int.tryParse(row['scrape_metadata']?.toString() ?? '1') ?? 1) ==
              1,
          'scrape_images':
              (int.tryParse(row['scrape_images']?.toString() ?? '1') ?? 1) == 1,
          'scrape_videos':
              (int.tryParse(row['scrape_videos']?.toString() ?? '1') ?? 1) == 1,
          'region_priority':
              row['region_priority']?.toString() ??
              '["wor","us","eu","jp","sp","fr","de","it","kr","cn"]',
          'scrape_media_types': _parseMediaTypes(row),
        };
      }

      await db.insert('user_screenscraper_config', {
        'id': 1,
        'scrape_mode': 'new_only',
        'scrape_metadata': 1,
        'scrape_images': 1,
        'scrape_videos': 1,
        'scrape_media_types': '["fanart","ss","wheel","box2D","video"]',
      });

      return {
        'scrape_mode': 'new_only',
        'scrape_metadata': true,
        'scrape_images': true,
        'scrape_videos': true,
        'region_priority':
            '["wor","us","eu","jp","sp","fr","de","it","kr","cn"]',
      };
    } catch (e) {
      _log.e('Error getting scraper config: $e');
      return {
        'scrape_mode': 'new_only',
        'scrape_metadata': true,
        'scrape_images': true,
        'scrape_videos': true,
        'region_priority':
            '["wor","us","eu","jp","sp","fr","de","it","kr","cn"]',
        'scrape_media_types': '["fanart","ss","wheel","box2D","video"]',
      };
    }
  }

  /// Updates the scraper configuration.
  static Future<bool> saveScraperConfig(Map<String, dynamic> config) async {
    try {
      final db = await SqliteService.getDatabase();
      final dataToUpdate = <String, dynamic>{
        'updated_at': DateTime.now().toIso8601String(),
      };

      if (config.containsKey('scrape_mode')) {
        dataToUpdate['scrape_mode'] = config['scrape_mode'];
      }
      if (config.containsKey('scrape_metadata')) {
        dataToUpdate['scrape_metadata'] = (config['scrape_metadata'] as bool)
            ? 1
            : 0;
      }
      if (config.containsKey('scrape_images')) {
        dataToUpdate['scrape_images'] = (config['scrape_images'] as bool)
            ? 1
            : 0;
      }
      if (config.containsKey('scrape_videos')) {
        dataToUpdate['scrape_videos'] = (config['scrape_videos'] as bool)
            ? 1
            : 0;
      }
      if (config.containsKey('region_priority')) {
        dataToUpdate['region_priority'] = config['region_priority'];
      }
      if (config.containsKey('scrape_media_types')) {
        dataToUpdate['scrape_media_types'] = config['scrape_media_types'];
      }

      await db.update(
        'user_screenscraper_config',
        dataToUpdate,
        where: 'id = ?',
        whereArgs: [1],
      );

      return true;
    } catch (e) {
      _log.e('Error saving scraper config: $e');
      return false;
    }
  }

  // ── System mappings ───────────────────────────────────────────────────────

  /// Retrieves the internal system mappings for enabled ScreenScraper integration.
  static Future<List<Map<String, dynamic>>> getSystemMappings() async {
    try {
      final db = await SqliteService.getDatabase();
      final mappings = await db.rawQuery('''
        SELECT
          asys.id as app_system_id,
          asys.screenscraper_id as screenscraper_system_id,
          asys.folder_name as folder_name,
          asys.folder_name as primary_folder_name,
          asys.screenscraper_id as screenscraper_id,
          asys.real_name as real_name
        FROM app_systems asys
        INNER JOIN user_screenscraper_system_config ussc ON asys.id = ussc.app_system_id
        WHERE asys.screenscraper_id IS NOT NULL 
        AND asys.screenscraper_id > 0
        AND ussc.enabled = 1
      ''');
      return mappings;
    } catch (e) {
      _log.e('Error getting system mappings: $e');
      return [];
    }
  }

  /// Returns the count of systems without a ScreenScraper ID mapping.
  static Future<int> getUnmappedSystemsCount() async {
    final db = await SqliteService.getDatabase();
    final result = await db.rawQuery('''
      SELECT COUNT(*) as count
      FROM user_detected_systems uds
      JOIN app_systems asys ON uds.app_system_id = asys.id
      WHERE asys.screenscraper_id IS NULL
    ''');
    return int.tryParse(result.first['count']?.toString() ?? '0') ?? 0;
  }

  /// Returns detected systems with their current ScreenScraper IDs.
  static Future<List<Map<String, dynamic>>>
  getDetectedSystemsWithScraperIds() async {
    final db = await SqliteService.getDatabase();
    return await db.rawQuery('''
      SELECT
        asys.id,
        asys.folder_name as folder_name,
        asys.real_name as real_name,
        asys.screenscraper_id as screenscraper_id
      FROM user_detected_systems uds
      JOIN app_systems asys ON uds.app_system_id = asys.id
    ''');
  }

  /// Updates the ScreenScraper ID for a given app system.
  static Future<void> updateSystemScraperId(
    String appSystemId,
    int screenscraperId,
  ) async {
    final db = await SqliteService.getDatabase();
    await db.update(
      'app_systems',
      {'screenscraper_id': screenscraperId},
      where: 'id = ?',
      whereArgs: [appSystemId],
    );
  }

  /// Returns the app system ID that corresponds to a given ScreenScraper ID.
  static Future<String?> getAppSystemIdByScraperId(
    String screenscraperId,
  ) async {
    final db = await SqliteService.getDatabase();
    final results = await db.query(
      'app_systems',
      columns: ['id'],
      where: 'screenscraper_id = ?',
      whereArgs: [screenscraperId],
    );
    if (results.isNotEmpty) {
      return results.first['id'].toString();
    }
    return null;
  }

  /// Returns the ScreenScraper ID for a given app system ID.
  static Future<int?> getScreenScraperIdByAppSystemId(
    String appSystemId,
  ) async {
    final db = await SqliteService.getDatabase();
    final results = await db.query(
      'app_systems',
      columns: ['screenscraper_id'],
      where: 'id = ?',
      whereArgs: [appSystemId],
    );
    if (results.isNotEmpty) {
      return int.tryParse(results.first['screenscraper_id']?.toString() ?? '');
    }
    return null;
  }

  /// Returns the folder name for a given app system ID.
  static Future<String?> getSystemFolderNameById(String appSystemId) async {
    final db = await SqliteService.getDatabase();
    final results = await db.query(
      'app_systems',
      columns: ['folder_name'],
      where: 'id = ?',
      whereArgs: [appSystemId],
    );
    if (results.isNotEmpty) {
      return results.first['folder_name'].toString();
    }
    return null;
  }

  /// Initializes system-specific scraper configurations (enabled/disabled states).
  static Future<void> initializeScraperSystemConfig() async {
    final db = await SqliteService.getDatabase();
    final mapped = await db.rawQuery(
      'SELECT id as app_system_id FROM app_systems WHERE screenscraper_id IS NOT NULL AND screenscraper_id > 0',
    );
    if (mapped.isEmpty) return;

    final existing = (await db.query(
      'user_screenscraper_system_config',
    )).map((r) => r['app_system_id'].toString()).toSet();
    for (final s in mapped) {
      final id = s['app_system_id'].toString();
      if (!existing.contains(id)) {
        await db.insert('user_screenscraper_system_config', {
          'app_system_id': id,
          'enabled': 1,
        });
      }
    }
  }

  // ── Metadata ──────────────────────────────────────────────────────────────

  /// Returns the raw metadata row for a game, or null when it was never
  /// scraped. Column names match the table (`real_name`, `description_en`,
  /// `developer`, …).
  static Future<Map<String, dynamic>?> getGameMetadata(
    String appSystemId,
    String filename,
  ) async {
    try {
      final db = await SqliteService.getDatabase();
      final rows = await db.query(
        'user_screenscraper_metadata',
        where: 'app_system_id = ? AND filename = ? COLLATE NOCASE',
        whereArgs: [appSystemId, filename],
        limit: 1,
      );
      return rows.isEmpty ? null : rows.first;
    } catch (e) {
      _log.e('Error reading game metadata: $e');
      return null;
    }
  }

  /// Partially updates editable metadata [fields] for a game. Only the
  /// provided columns are touched; a minimal row is created when the game
  /// has no metadata yet. Used by the manual metadata editor.
  static Future<bool> updateGameMetadata(
    String appSystemId,
    String filename,
    Map<String, dynamic> fields,
  ) async {
    if (fields.isEmpty) return false;
    try {
      final db = await SqliteService.getDatabase();
      final existing = await db.query(
        'user_screenscraper_metadata',
        columns: const ['app_system_id'],
        where: 'app_system_id = ? AND filename = ? COLLATE NOCASE',
        whereArgs: [appSystemId, filename],
        limit: 1,
      );

      final values = Map<String, dynamic>.from(fields)
        ..remove('app_system_id')
        ..remove('filename')
        ..remove('is_fully_scraped')
        ..remove('updated_at')
        ..['updated_at'] = DateTime.now().toIso8601String();

      if (existing.isEmpty) {
        values['app_system_id'] = appSystemId;
        values['filename'] = filename;
        values['is_fully_scraped'] = 0;
        await db.insert(
          'user_screenscraper_metadata',
          values,
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      } else {
        await db.update(
          'user_screenscraper_metadata',
          values,
          where: 'app_system_id = ? AND filename = ? COLLATE NOCASE',
          whereArgs: [appSystemId, filename],
        );
      }
      return true;
    } catch (e) {
      _log.e('Error updating game metadata: $e');
      return false;
    }
  }

  /// Saves the metadata to the local user_screenscraper_metadata table.
  static Future<bool> saveGameMetadata(
    Map<String, dynamic> metadata,
    String appSystemId, {
    bool isFullyScraped = false,
  }) async {
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

  /// Merges ES-DE-imported metadata into `user_screenscraper_metadata`,
  /// writing only columns that are currently empty (fill-gaps precedence).
  ///
  /// [esde] maps column names (`real_name`, `description_en`, `rating`, …) to
  /// candidate values; null / blank values are ignored. Existing non-empty
  /// NeoStation-scraped values are never overwritten. `is_fully_scraped` is
  /// left at 0 so a later NeoStation scrape still upgrades the entry.
  ///
  /// Returns true if a row was created or at least one column was filled.
  static Future<bool> mergeEsdeMetadata(
    String appSystemId,
    String filename,
    Map<String, dynamic> esde, {
    String? mediaSubdir,
  }) async {
    try {
      final db = await SqliteService.getDatabase();
      final existing = await db.query(
        'user_screenscraper_metadata',
        where: 'app_system_id = ? AND filename = ? COLLATE NOCASE',
        whereArgs: [appSystemId, filename],
        limit: 1,
      );
      final row = existing.isNotEmpty ? existing.first : null;

      final toWrite = buildEsdeMetadataWrite(
        appSystemId: appSystemId,
        filename: filename,
        row: row,
        esde: esde,
        mediaSubdir: mediaSubdir,
      );
      if (toWrite == null) return false;

      if (row == null) {
        await db.insert(
          'user_screenscraper_metadata',
          toWrite,
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      } else {
        await db.update(
          'user_screenscraper_metadata',
          toWrite,
          where: 'app_system_id = ? AND filename = ? COLLATE NOCASE',
          whereArgs: [appSystemId, filename],
        );
      }
      return true;
    } catch (e) {
      _log.e('Error merging ES-DE metadata: $e');
      return false;
    }
  }

  /// Computes the fill-gaps write for [esde] against [row] — the game's current
  /// `user_screenscraper_metadata` row, or null when it has none.
  ///
  /// Returns null when nothing needs writing. When [row] is null the returned
  /// map is a complete insert (keys, `is_fully_scraped`, provenance marker);
  /// otherwise it holds only the columns to update.
  ///
  /// Pure — no database access — so a bulk importer that already has the rows
  /// in hand can reuse the precedence rules and batch the writes itself.
  static Map<String, dynamic>? buildEsdeMetadataWrite({
    required String appSystemId,
    required String filename,
    required Map<String, Object?>? row,
    required Map<String, dynamic> esde,
    String? mediaSubdir,
  }) {
    final toWrite = <String, dynamic>{};
    esde.forEach((col, val) {
      if (val == null) return;
      if (val is String && val.trim().isEmpty) return;
      final cur = row?[col];
      final curEmpty = cur == null || (cur is String && cur.trim().isEmpty);
      if (curEmpty) toWrite[col] = val;
    });

    // Media subfolder is ES-DE bookkeeping (mirrors the ROM's subfolder inside
    // downloaded_media), not user-visible metadata — always keep it current so
    // read-time fallback can resolve nested artwork, even when nothing else
    // needs filling.
    if (mediaSubdir != null &&
        (row == null || row['esde_media_subdir'] != mediaSubdir)) {
      toWrite['esde_media_subdir'] = mediaSubdir;
    }

    if (toWrite.isEmpty) return null;
    toWrite['updated_at'] = DateTime.now().toIso8601String();

    if (row == null) {
      toWrite['app_system_id'] = appSystemId;
      toWrite['filename'] = filename;
      toWrite['is_fully_scraped'] = 0;
      // Provenance marker so reset() can remove ES-DE-created rows without
      // touching NeoStation's own partially-scraped rows. Only set on insert
      // (rows the import creates from scratch); gap-fills into pre-existing
      // NeoStation rows are left unmarked so reset() won't delete them.
      toWrite['esde_imported'] = 1;
    }
    return toWrite;
  }

  /// Resolves an ES-DE system folder name (e.g. `psx`, `megadrive`) to a
  /// NeoStation system. Checks the ES-DE/LaunchBox alias table first
  /// (`app_system_folders`), then falls back to a direct `app_systems`
  /// folder-name match. Returns `{app_system_id, folder_name}` or null.
  static Future<Map<String, String>?> resolveSystemByFolderName(
    String folderName,
  ) async {
    try {
      final db = await SqliteService.getDatabase();
      final aliased = await db.rawQuery(
        '''SELECT s.id AS id, s.folder_name AS folder_name
           FROM app_system_folders f
           JOIN app_systems s ON s.id = f.system_id
           WHERE f.folder_name = ? COLLATE NOCASE LIMIT 1''',
        [folderName],
      );
      if (aliased.isNotEmpty) {
        return {
          'app_system_id': aliased.first['id'].toString(),
          'folder_name': aliased.first['folder_name'].toString(),
        };
      }
      final direct = await db.query(
        'app_systems',
        columns: ['id', 'folder_name'],
        where: 'folder_name = ? COLLATE NOCASE',
        whereArgs: [folderName],
        limit: 1,
      );
      if (direct.isNotEmpty) {
        return {
          'app_system_id': direct.first['id'].toString(),
          'folder_name': direct.first['folder_name'].toString(),
        };
      }
      return null;
    } catch (e) {
      _log.e('Error resolving system for folder "$folderName": $e');
      return null;
    }
  }

  /// Marks a game's metadata as fully scraped.
  static Future<void> markGameFullyScraped(String filename) async {
    final db = await SqliteService.getDatabase();
    await db.update(
      'user_screenscraper_metadata',
      {'is_fully_scraped': 1, 'updated_at': DateTime.now().toIso8601String()},
      where: 'filename = ?',
      whereArgs: [filename],
    );
  }

  /// Transfers scraped metadata from the first matching source ROM to a newly
  /// created multi-disc playlist. Source paths keep the update scoped to the
  /// correct system, even where different systems contain identically named
  /// files. Existing playlist metadata is never overwritten.
  static Future<MetadataTransferResult?> transferMetadataToPlaylist({
    required List<String> sourceRomPaths,
    required List<String> sourceFilenames,
    required String playlistFilename,
  }) async {
    if (sourceRomPaths.isEmpty && sourceFilenames.isEmpty) return null;

    try {
      final db = await SqliteService.getDatabase();
      return await db.transaction((txn) async {
        for (var index = 0; index < sourceRomPaths.length; index++) {
          final sourceRomPath = sourceRomPaths[index];
          final sourceFilename = index < sourceFilenames.length
              ? sourceFilenames[index]
              : null;
          var sourceRows = await txn.rawQuery(
            '''
            SELECT ur.app_system_id, ur.filename
            FROM user_roms ur
            INNER JOIN user_screenscraper_metadata usm
              ON usm.app_system_id = ur.app_system_id
              AND usm.filename = ur.filename
            WHERE ur.rom_path = ?
            ''',
            [sourceRomPath],
          );

          if (sourceRows.isEmpty && sourceFilename != null) {
            final filenameMatches = await txn.rawQuery(
              '''
              SELECT ur.app_system_id, ur.filename
              FROM user_roms ur
              INNER JOIN user_screenscraper_metadata usm
                ON usm.app_system_id = ur.app_system_id
                AND usm.filename = ur.filename
              WHERE ur.filename = ?
              ''',
              [sourceFilename],
            );

            if (filenameMatches.length == 1) {
              sourceRows = filenameMatches;
              _log.i(
                'Transferring metadata for $sourceFilename using filename fallback.',
              );
            } else if (filenameMatches.length > 1) {
              _log.w(
                'Metadata transfer skipped for $sourceFilename: filename matches multiple systems.',
              );
            }
          }

          for (final source in sourceRows) {
            final appSystemId = source['app_system_id'].toString();
            final matchedFilename = source['filename'].toString();
            final updated = await txn.rawUpdate(
              '''
              UPDATE user_screenscraper_metadata
              SET filename = ?, updated_at = ?
              WHERE app_system_id = ? AND filename = ?
                AND NOT EXISTS (
                  SELECT 1
                  FROM user_screenscraper_metadata
                  WHERE app_system_id = ? AND filename = ?
                )
              ''',
              [
                playlistFilename,
                DateTime.now().toIso8601String(),
                appSystemId,
                matchedFilename,
                appSystemId,
                playlistFilename,
              ],
            );
            if (updated > 0) {
              _log.i(
                'Transferred metadata from $matchedFilename to $playlistFilename.',
              );
              return MetadataTransferResult(
                appSystemId: appSystemId,
                metadataTransferred: true,
              );
            }

            final targetExists = await txn.query(
              'user_screenscraper_metadata',
              columns: ['filename'],
              where: 'app_system_id = ? AND filename = ?',
              whereArgs: [appSystemId, playlistFilename],
              limit: 1,
            );
            if (targetExists.isNotEmpty) {
              return MetadataTransferResult(
                appSystemId: appSystemId,
                metadataTransferred: false,
              );
            }
          }
        }
        _log.i('No scraped metadata found to transfer to $playlistFilename.');
        return null;
      });
    } catch (e) {
      _log.e('Error transferring metadata to playlist: $e');
      return null;
    }
  }

  // ── Bulk scraping ─────────────────────────────────────────────────────────

  /// Returns the count of ROMs eligible for scraping for a given system.
  static Future<int> getRomCountForScraping(
    String appSystemId,
    String scrapeMode,
  ) async {
    final db = await SqliteService.getDatabase();
    final result = await db.rawQuery(
      '''SELECT COUNT(*) as count FROM user_roms ur LEFT JOIN user_screenscraper_metadata usm ON ur.filename = usm.filename 
       WHERE ur.app_system_id = ? ${scrapeMode == 'new_only' ? 'AND (usm.filename IS NULL OR usm.is_fully_scraped = 0)' : ''}''',
      [appSystemId],
    );
    return int.tryParse(result.first['count']?.toString() ?? '0') ?? 0;
  }

  /// Returns the list of ROMs eligible for scraping for a given system.
  static Future<List<Map<String, dynamic>>> getRomsForScraping(
    String appSystemId,
    String scrapeMode,
  ) async {
    final db = await SqliteService.getDatabase();
    return await db.rawQuery(
      '''SELECT ur.filename, ur.rom_path, ur.title_name, usm.is_fully_scraped 
       FROM user_roms ur LEFT JOIN user_screenscraper_metadata usm ON ur.filename = usm.filename 
       WHERE ur.app_system_id = ? ${scrapeMode == 'new_only' ? 'AND (usm.filename IS NULL OR usm.is_fully_scraped = 0)' : ''}''',
      [appSystemId],
    );
  }

  // ── Steam scraper operations ──────────────────────────────────────────────

  static Future<List<Map<String, dynamic>>> getSteamGamesWithScrapeStatus(
    String steamSystemId,
  ) async {
    final db = await SqliteService.getDatabase();
    return await db.rawQuery(
      '''
      SELECT ur.filename, ur.rom_path, ur.title_id, usm.is_fully_scraped
      FROM user_roms ur
      LEFT JOIN user_screenscraper_metadata usm 
        ON ur.app_system_id = usm.app_system_id AND ur.filename = usm.filename
      WHERE ur.app_system_id = ? 
        AND ur.title_id IS NOT NULL
      ''',
      [steamSystemId],
    );
  }

  static Future<void> upsertSteamMetadata(Map<String, dynamic> metadata) async {
    final db = await SqliteService.getDatabase();
    await db.insert(
      'user_screenscraper_metadata',
      metadata,
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  static Future<String> getPreferredLanguage() async {
    try {
      final db = await SqliteService.getDatabase();
      final result = await db.query(
        'user_screenscraper_credentials',
        columns: ['preferred_language'],
        limit: 1,
      );
      if (result.isNotEmpty) {
        return result.first['preferred_language']?.toString() ?? 'en';
      }
    } catch (e) {
      _log.e('Error getting preferred language: $e');
    }
    return 'en';
  }

  static const String defaultRegionPriority =
      '["wor","us","eu","jp","sp","fr","de","it","kr","cn"]';

  static Future<List<String>> getRegionPriority() async {
    try {
      final config = await getScraperConfig();
      final jsonStr =
          config['region_priority']?.toString() ?? defaultRegionPriority;
      final List<dynamic> decoded = jsonDecode(jsonStr);
      return decoded.cast<String>();
    } catch (e) {
      _log.e('Error getting region priority: $e');
      return ['wor', 'us', 'eu', 'jp', 'sp', 'fr', 'de', 'it', 'kr', 'cn'];
    }
  }

  static Future<bool> saveRegionPriority(List<String> regions) async {
    try {
      return await saveScraperConfig({'region_priority': jsonEncode(regions)});
    } catch (e) {
      _log.e('Error saving region priority: $e');
      return false;
    }
  }

  static const String defaultScrapeMediaTypes =
      '["fanart","ss","wheel","box2D","video"]';

  static String _parseMediaTypes(Map<String, dynamic> row) {
    final jsonStr = row['scrape_media_types']?.toString();
    if (jsonStr != null && jsonStr.isNotEmpty) return jsonStr;

    final imagesEnabled =
        (int.tryParse(row['scrape_images']?.toString() ?? '1') ?? 1) == 1;
    final videosEnabled =
        (int.tryParse(row['scrape_videos']?.toString() ?? '1') ?? 1) == 1;

    final types = <String>[];
    if (imagesEnabled) types.addAll(['fanart', 'ss', 'wheel', 'box2D']);
    if (videosEnabled) types.add('video');
    return jsonEncode(types);
  }

  static Future<List<String>> getEnabledMediaTypes() async {
    try {
      final config = await getScraperConfig();
      final jsonStr =
          config['scrape_media_types']?.toString() ?? defaultScrapeMediaTypes;
      final List<dynamic> decoded = jsonDecode(jsonStr);
      return decoded.cast<String>();
    } catch (e) {
      _log.e('Error getting enabled media types: $e');
      return ['fanart', 'ss', 'wheel', 'box2D', 'video'];
    }
  }

  static Future<bool> saveEnabledMediaTypes(List<String> types) async {
    try {
      return await saveScraperConfig({'scrape_media_types': jsonEncode(types)});
    } catch (e) {
      _log.e('Error saving enabled media types: $e');
      return false;
    }
  }

  /// Returns the cached dump identity for [romPath], or null if it has never
  /// been fingerprinted.
  ///
  /// A row with only a crc32 is normal and complete: the zip fast path yields
  /// crc and size without ever decompressing, and crc alone resolves a
  /// ScreenScraper lookup.
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

  // ── Games identified by hand ──────────────────────────────────────────────

  /// Records the ScreenScraper game the user picked for [romPath] with
  /// Identify…. Every later scrape of this ROM asks for that game by id
  /// instead of matching it by dump hash or filename.
  ///
  /// Returns false when no ROM row has that path, so the pick was not stored.
  static Future<bool> setManualScreenScraperGameId(
    String romPath,
    int gameId,
  ) async {
    final db = await SqliteService.getDatabase();
    final updated = await db.rawUpdate(
      'UPDATE user_roms SET ss_manual_game_id = ? WHERE rom_path = ?',
      [gameId, romPath],
    );
    return updated > 0;
  }

  /// Forgets the user's pick, so the ROM is matched automatically again.
  static Future<void> clearManualScreenScraperGameId(String romPath) async {
    final db = await SqliteService.getDatabase();
    await db.rawUpdate(
      'UPDATE user_roms SET ss_manual_game_id = NULL WHERE rom_path = ?',
      [romPath],
    );
  }

  /// The ScreenScraper game the user picked for [romPath], or null when the
  /// ROM is matched automatically.
  static Future<int?> getManualScreenScraperGameId(String romPath) async {
    try {
      final db = await SqliteService.getDatabase();
      final rows = await db.rawQuery(
        'SELECT ss_manual_game_id FROM user_roms WHERE rom_path = ? LIMIT 1',
        [romPath],
      );
      if (rows.isEmpty) return null;
      final value = rows.first['ss_manual_game_id'];
      if (value == null) return null;
      return int.tryParse(value.toString());
    } catch (e) {
      _log.e('Error reading the identified game for $romPath: $e');
      return null;
    }
  }
}
