import 'dart:convert';

import '../data/datasources/sqlite_service.dart';
import 'package:neostation/services/logger_service.dart';

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

  /// Persists encrypted ScreenScraper credentials and user tier information.
  static Future<bool> saveCredentials(
    String username,
    String password, [
    Map<String, dynamic>? userInfo,
    String? preferredLanguage,
  ]) async {
    try {
      final db = await SqliteService.getDatabase();
      final encryptedPassword = base64Encode(utf8.encode(password));

      final dataToSave = <String, dynamic>{
        'id': 1,
        'username': username,
        'password': encryptedPassword,
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
        final encryptedPassword = row['password'].toString();
        final password = utf8.decode(base64Decode(encryptedPassword));

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

  /// Deletes saved credentials from the local database.
  static Future<bool> clearCredentials() async {
    try {
      final db = await SqliteService.getDatabase();
      await db.delete('user_screenscraper_credentials');
      return true;
    } catch (e) {
      _log.e('Error clearing scraper credentials: $e');
      return false;
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
          'region_priority': row['region_priority']?.toString() ??
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
        'region_priority': '["wor","us","eu","jp","sp","fr","de","it","kr","cn"]',
      };
    } catch (e) {
      _log.e('Error getting scraper config: $e');
      return {
        'scrape_mode': 'new_only',
        'scrape_metadata': true,
        'scrape_images': true,
        'scrape_videos': true,
        'region_priority': '["wor","us","eu","jp","sp","fr","de","it","kr","cn"]',
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
      return await saveScraperConfig({
        'region_priority': jsonEncode(regions),
      });
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
      final jsonStr = config['scrape_media_types']?.toString() ??
          defaultScrapeMediaTypes;
      final List<dynamic> decoded = jsonDecode(jsonStr);
      return decoded.cast<String>();
    } catch (e) {
      _log.e('Error getting enabled media types: $e');
      return ['fanart', 'ss', 'wheel', 'box2D', 'video'];
    }
  }

  static Future<bool> saveEnabledMediaTypes(List<String> types) async {
    try {
      return await saveScraperConfig({
        'scrape_media_types': jsonEncode(types),
      });
    } catch (e) {
      _log.e('Error saving enabled media types: $e');
      return false;
    }
  }
}
