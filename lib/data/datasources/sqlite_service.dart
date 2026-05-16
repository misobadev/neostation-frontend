import 'dart:io';
import 'dart:convert';
import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart'; // Required for rootBundle
import 'package:path/path.dart' as path; // Required for path operations
import 'package:sqlite3/sqlite3.dart' as sqlite; // sqlite3 usage
import '../../services/android_service.dart';

import '../../models/system_model.dart';
import '../../models/system_configuration.dart';
import '../../models/emulator_model.dart';
import '../../models/core_emulator_model.dart';
// import '../models/neo_sync_models.dart'; // Removido si no se usa directamente aquí
import '../../models/database_game_model.dart';
import 'sqlite_migrations.dart';
import '../../services/config_service.dart'; // Required for ConfigService usage
import '../../services/json_config_service.dart';
import '../../services/logger_service.dart';

/// Defines the behavior when a constraint violation occurs during a database operation.
enum ConflictAlgorithm { rollback, abort, fail, ignore, replace }

/// Interface that defines common database execution operations.
///
/// This adapter facilitates consistent interaction with the underlying SQLite database,
/// providing methods for raw SQL execution and high-level query builders.
abstract class DatabaseExecutorAdapter {
  /// Executes a raw SQL statement with optional [arguments].
  Future<void> execute(String sql, [List<Object?>? arguments]);

  /// Executes an INSERT statement and returns the ID of the last inserted row.
  Future<int> rawInsert(String sql, [List<Object?>? arguments]);

  /// Executes an UPDATE statement and returns the number of modified rows.
  Future<int> rawUpdate(String sql, [List<Object?>? arguments]);

  /// Executes a DELETE statement and returns the number of deleted rows.
  Future<int> rawDelete(String sql, [List<Object?>? arguments]);

  /// Executes a raw SQL query and returns a list of result maps.
  Future<List<Map<String, Object?>>> rawQuery(
    String sql, [
    List<Object?>? arguments,
  ]);

  /// Performs a high-level query on a specific [table].
  Future<List<Map<String, Object?>>> query(
    String table, {
    bool? distinct,
    List<String>? columns,
    String? where,
    List<Object?>? whereArgs,
    String? groupBy,
    String? having,
    String? orderBy,
    int? limit,
    int? offset,
  });

  /// Inserts a map of [values] into the specified [table].
  Future<int> insert(
    String table,
    Map<String, Object?> values, {
    String? nullColumnHack,
    ConflictAlgorithm? conflictAlgorithm,
  });

  /// Updates rows in [table] with new [values] matching the [where] clause.
  Future<int> update(
    String table,
    Map<String, Object?> values, {
    String? where,
    List<Object?>? whereArgs,
    ConflictAlgorithm? conflictAlgorithm,
  });

  /// Deletes rows from [table] matching the [where] clause.
  Future<int> delete(String table, {String? where, List<Object?>? whereArgs});

  /// Creates a new batch operation for atomic execution.
  BatchAdapter batch();
}

/// Concrete implementation of [DatabaseExecutorAdapter] using `package:sqlite3`.
class DatabaseAdapter implements DatabaseExecutorAdapter {
  final sqlite.Database _db;
  DatabaseAdapter(this._db);

  /// Provides access to the raw sqlite3 database instance.
  sqlite.Database get rawDb => _db;

  /// Closes the database connection.
  Future<void> close() async {
    _db.close();
  }

  @override
  Future<void> execute(String sql, [List<Object?>? arguments]) async {
    if (arguments != null && arguments.isNotEmpty) {
      _db.execute(sql, arguments);
    } else {
      _db.execute(sql);
    }
  }

  @override
  Future<int> rawInsert(String sql, [List<Object?>? arguments]) async {
    _db.execute(sql, arguments ?? []);
    return _db.lastInsertRowId;
  }

  @override
  Future<int> rawUpdate(String sql, [List<Object?>? arguments]) async {
    _db.execute(sql, arguments ?? []);
    return _db.updatedRows;
  }

  @override
  Future<int> rawDelete(String sql, [List<Object?>? arguments]) async {
    _db.execute(sql, arguments ?? []);
    return _db.updatedRows;
  }

  @override
  Future<List<Map<String, Object?>>> rawQuery(
    String sql, [
    List<Object?>? arguments,
  ]) async {
    final results = _db.select(sql, arguments ?? []);
    return _resultSetToMap(results);
  }

  /// Converts an [sqlite.ResultSet] into a standard Dart list of maps.
  List<Map<String, dynamic>> _resultSetToMap(sqlite.ResultSet results) {
    if (results.isEmpty) return [];

    final keys = results.columnNames;
    // Map each row (which is a generic list of values) to a Map using column names
    return results.map((row) {
      final map = <String, dynamic>{};
      for (int i = 0; i < keys.length; i++) {
        // ignore: collection_methods_unrelated_type
        map[keys[i]] = row[i];
      }
      return map;
    }).toList();
  }

  @override
  Future<List<Map<String, Object?>>> query(
    String table, {
    bool? distinct,
    List<String>? columns,
    String? where,
    List<Object?>? whereArgs,
    String? groupBy,
    String? having,
    String? orderBy,
    int? limit,
    int? offset,
  }) async {
    final buffer = StringBuffer('SELECT ');
    if (distinct == true) buffer.write('DISTINCT ');
    if (columns != null && columns.isNotEmpty) {
      buffer.write(columns.join(', '));
    } else {
      buffer.write('*');
    }
    buffer.write(' FROM $table');
    if (where != null) buffer.write(' WHERE $where');
    if (groupBy != null) buffer.write(' GROUP BY $groupBy');
    if (having != null) buffer.write(' HAVING $having');
    if (orderBy != null) buffer.write(' ORDER BY $orderBy');
    if (limit != null) buffer.write(' LIMIT $limit');
    if (offset != null) buffer.write(' OFFSET $offset');

    return rawQuery(buffer.toString(), whereArgs);
  }

  @override
  Future<int> insert(
    String table,
    Map<String, Object?> values, {
    String? nullColumnHack,
    ConflictAlgorithm? conflictAlgorithm,
  }) async {
    if (values.isEmpty) {
      final nullCol = nullColumnHack ?? 'NULL';
      return rawInsert('INSERT INTO $table ($nullCol) VALUES (NULL)');
    }

    final conflictClause = _getConflictClause(conflictAlgorithm);
    final cols = values.keys.join(', ');
    final placeholders = List.filled(values.length, '?').join(', ');

    final sql =
        'INSERT $conflictClause INTO $table ($cols) VALUES ($placeholders)';
    return rawInsert(sql, values.values.toList());
  }

  @override
  Future<int> update(
    String table,
    Map<String, Object?> values, {
    String? where,
    List<Object?>? whereArgs,
    ConflictAlgorithm? conflictAlgorithm,
  }) async {
    if (values.isEmpty) return 0;

    final conflictClause = _getConflictClause(conflictAlgorithm);
    final sets = values.keys.map((key) => '$key = ?').join(', ');
    final sql =
        'UPDATE $conflictClause $table SET $sets${where != null ? ' WHERE $where' : ''}';

    final args = [...values.values, ...(whereArgs ?? [])];
    return rawUpdate(sql, args);
  }

  @override
  Future<int> delete(
    String table, {
    String? where,
    List<Object?>? whereArgs,
  }) async {
    final sql = 'DELETE FROM $table${where != null ? ' WHERE $where' : ''}';
    return rawDelete(sql, whereArgs);
  }

  String _getConflictClause(ConflictAlgorithm? algo) {
    if (algo == null) return '';
    switch (algo) {
      case ConflictAlgorithm.rollback:
        return 'OR ROLLBACK';
      case ConflictAlgorithm.abort:
        return 'OR ABORT';
      case ConflictAlgorithm.fail:
        return 'OR FAIL';
      case ConflictAlgorithm.ignore:
        return 'OR IGNORE';
      case ConflictAlgorithm.replace:
        return 'OR REPLACE';
    }
  }

  @override
  BatchAdapter batch() => BatchAdapter(_db);

  /// Executes a series of database operations within an atomic transaction.
  Future<T> transaction<T>(
    Future<T> Function(TransactionAdapter) action,
  ) async {
    final bool inTransaction = !_db.autocommit;
    if (inTransaction) {
      return await action(TransactionAdapter(_db));
    }

    _db.execute('BEGIN');
    try {
      final result = await action(TransactionAdapter(_db));
      _db.execute('COMMIT');
      return result;
    } catch (e) {
      if (!_db.autocommit) {
        _db.execute('ROLLBACK');
      }
      rethrow;
    }
  }
}

class TransactionAdapter extends DatabaseAdapter {
  TransactionAdapter(super.db);
}

class BatchAdapter {
  final sqlite.Database _db;
  final List<Future<Object?> Function()> _actions = [];

  BatchAdapter(this._db);

  void rawInsert(String sql, [List<Object?>? arguments]) {
    _actions.add(() async {
      final adapter = DatabaseAdapter(_db);
      return await adapter.rawInsert(sql, arguments);
    });
  }

  void insert(
    String table,
    Map<String, Object?> values, {
    String? nullColumnHack,
    ConflictAlgorithm? conflictAlgorithm,
  }) {
    _actions.add(() async {
      final adapter = DatabaseAdapter(_db);
      return await adapter.insert(
        table,
        values,
        nullColumnHack: nullColumnHack,
        conflictAlgorithm: conflictAlgorithm,
      );
    });
  }

  void rawUpdate(String sql, [List<Object?>? arguments]) {
    _actions.add(() async {
      final adapter = DatabaseAdapter(_db);
      return await adapter.rawUpdate(sql, arguments);
    });
  }

  void update(
    String table,
    Map<String, Object?> values, {
    String? where,
    List<Object?>? whereArgs,
    ConflictAlgorithm? conflictAlgorithm,
  }) {
    _actions.add(() async {
      final adapter = DatabaseAdapter(_db);
      return await adapter.update(
        table,
        values,
        where: where,
        whereArgs: whereArgs,
        conflictAlgorithm: conflictAlgorithm,
      );
    });
  }

  void rawDelete(String sql, [List<Object?>? arguments]) {
    _actions.add(() async {
      final adapter = DatabaseAdapter(_db);
      return await adapter.rawDelete(sql, arguments);
    });
  }

  void delete(String table, {String? where, List<Object?>? whereArgs}) {
    _actions.add(() async {
      final adapter = DatabaseAdapter(_db);
      return await adapter.delete(table, where: where, whereArgs: whereArgs);
    });
  }

  void execute(String sql, [List<Object?>? arguments]) {
    _actions.add(() async {
      final adapter = DatabaseAdapter(_db);
      return await adapter.execute(sql, arguments);
    });
  }

  void query(
    String table, {
    bool? distinct,
    List<String>? columns,
    String? where,
    List<Object?>? whereArgs,
    String? groupBy,
    String? having,
    String? orderBy,
    int? limit,
    int? offset,
  }) {
    _actions.add(() async {
      final adapter = DatabaseAdapter(_db);
      return await adapter.query(
        table,
        distinct: distinct,
        columns: columns,
        where: where,
        whereArgs: whereArgs,
        groupBy: groupBy,
        having: having,
        orderBy: orderBy,
        limit: limit,
        offset: offset,
      );
    });
  }

  void rawQuery(String sql, [List<Object?>? arguments]) {
    _actions.add(() async {
      final adapter = DatabaseAdapter(_db);
      return await adapter.rawQuery(sql, arguments);
    });
  }

  BatchAdapter batch() {
    throw UnimplementedError('BatchAdapter cannot create nested batches.');
  }

  Future<List<Object?>> commit({bool? noResult}) async {
    final results = <Object?>[];
    final bool inTransaction = !_db.autocommit;

    if (!inTransaction) _db.execute('BEGIN');
    try {
      for (final action in _actions) {
        final result = await action();
        if (noResult != true) results.add(result);
      }
      if (!inTransaction) _db.execute('COMMIT');
    } catch (e) {
      if (!inTransaction && !_db.autocommit) {
        _db.execute('ROLLBACK');
      }
      rethrow;
    }
    return results;
  }
}

/// Core SQLite service responsible for database initialization, schema management,
/// and high-level data access for the entire application.
class SqliteService {
  // Singleton pattern
  static final SqliteService _instance = SqliteService._internal();
  static SqliteService get instance => _instance;
  SqliteService._internal();

  // Database configuration
  static const int _databaseVersion = 81;
  static const String _databaseName = 'data.sqlite';

  DatabaseAdapter? _database;
  bool _initialized = false;

  // Logging system
  static final _log = LoggerService.instance;

  // Cache for systems to avoid repeated DB/JSON reads using getSystemByFolderName
  static List<SystemModel>? _cachedSystems;

  /// Injects a [DatabaseAdapter] for unit testing purposes.
  ///
  /// This bypasses normal filesystem initialization and should only be called
  /// from test code.
  @visibleForTesting
  static void setTestingDatabase(DatabaseAdapter adapter) {
    instance._database = adapter;
    instance._initialized = true;
    instance._initCompleter = null;
    _cachedSystems = null;
  }

  /// Loads system definitions from JSON assets and synchronizes them with
  /// the database to maintain referential integrity.
  static Future<List<SystemModel>> loadAndSyncSystems() async {
    final configurations = await JsonConfigService.instance.loadSystems();
    final synced = await syncSystems(configurations);
    _cachedSystems = synced;
    return synced;
  }

  /// Loads all registered systems directly from the database, enriching them
  /// with metadata and game counts.
  static Future<List<SystemModel>> loadSystemsFromDb() async {
    final db = await instance.database;

    // Retrieve base systems with user settings and calculated ROM counts
    final systemsResults = await db.rawQuery('''
      SELECT s.*,
             (SELECT COUNT(*) FROM user_roms ur WHERE ur.app_system_id = s.id) as rom_count,
             ss.recursive_scan,
             ss.custom_background_path,
             ss.custom_logo_path,
             ss.hide_logo,
             ss.hide_extension,
             ss.hide_parentheses,
             ss.hide_brackets
      FROM app_systems s
      LEFT JOIN user_system_settings ss ON s.id = ss.app_system_id
    ''');

    if (systemsResults.isEmpty) {
      // If the database is empty, force a synchronization from JSON resources.
      return await loadAndSyncSystems();
    }

    return await _enrichSystemsWithFoldersAndExtensions(db, systemsResults);
  }

  /// Synchronizes system configurations between JSON definitions and the local database.
  ///
  /// This process ensures that system IDs, metadata, and platform-specific assets
  /// are consistent, preserving user settings while updating core system data.
  static Future<List<SystemModel>> syncSystems(
    List<SystemConfiguration> configurations,
  ) async {
    final db = await instance.database;
    final syncedSystems = <SystemModel>[];
    final Set<String> syncedSystemIds = {};

    // Cache OS IDs
    final osMap = <String, int>{};
    final osResults = await db.query('app_os');
    for (final row in osResults) {
      osMap[row['name'].toString().toLowerCase()] =
          int.tryParse(row['id']?.toString() ?? '') ?? 0;
    }

    await db.transaction((txn) async {
      for (final config in configurations) {
        final jsonSystem = config.system;

        // Search by folder_name (the logical unique key)
        final existing = await txn.query(
          'app_systems',
          columns: ['id'],
          where: 'folder_name = ? COLLATE NOCASE',
          whereArgs: [jsonSystem.folderName],
          limit: 1,
        );

        String systemId;
        if (existing.isNotEmpty) {
          systemId = existing.first['id'].toString();
          await txn.update(
            'app_systems',
            {
              'real_name': jsonSystem.realName,
              'short_name': jsonSystem.shortName,
              'screenscraper_id': jsonSystem.screenscraperId,
              'ra_id': jsonSystem.raId,
              'description': jsonSystem.description,
              'launch_date': jsonSystem.launchDate,
              'manufacturer': jsonSystem.manufacturer,
              'type': jsonSystem.type,
              'color1': jsonSystem.color1,
              'color2': jsonSystem.color2,
            },
            where: 'id = ?',
            whereArgs: [systemId],
          );
        } else {
          systemId = jsonSystem.folderName;
          await txn.insert('app_systems', {
            'id': systemId,
            'real_name': jsonSystem.realName,
            'short_name': jsonSystem.shortName,
            'folder_name': jsonSystem.folderName,
            'screenscraper_id': jsonSystem.screenscraperId,
            'ra_id': jsonSystem.raId,
            'description': jsonSystem.description,
            'launch_date': jsonSystem.launchDate,
            'manufacturer': jsonSystem.manufacturer,
            'type': jsonSystem.type,
            'color1': jsonSystem.color1,
            'color2': jsonSystem.color2,
            'neosync_json': json.encode(jsonSystem.neosync.toJson()),
          });
        }

        // SYNC FOLDERS: Source of Truth is JSON. Overwrite DB.
        // 1. Delete all existing folders for this system
        await txn.delete(
          'app_system_folders',
          where: 'system_id = ?',
          whereArgs: [systemId],
        );

        // 2. Insert all folders from JSON
        for (final folder in jsonSystem.folders) {
          if (folder.isNotEmpty) {
            await txn.insert('app_system_folders', {
              'system_id': systemId,
              'folder_name': folder,
            }, conflictAlgorithm: ConflictAlgorithm.ignore);
          }
        }

        // 3. Convert singular folder_name to an entry if missing (legacy support/consistency)
        if (jsonSystem.folderName.isNotEmpty &&
            !jsonSystem.folders.contains(jsonSystem.folderName)) {
          await txn.insert('app_system_folders', {
            'system_id': systemId,
            'folder_name': jsonSystem.folderName,
          }, conflictAlgorithm: ConflictAlgorithm.ignore);
        }

        syncedSystemIds.add(systemId);

        // Sync Extensions
        // First delete existing extensions to ensure full sync
        await txn.delete(
          'app_system_extensions',
          where: 'system_id = ?',
          whereArgs: [systemId],
        );

        // Insert new extensions
        for (final extension in jsonSystem.extensions) {
          await txn.insert('app_system_extensions', {
            'system_id': systemId,
            'extension': extension.toLowerCase().replaceAll('.', ''),
          });
        }

        // Sync Emulators for this system
        await _syncEmulators(
          txn,
          systemId,
          config.emulators, // Non-nullable in SystemConfiguration
          osMap,
          jsonSystem.folderName,
        );

        syncedSystems.add(jsonSystem.copyWith(id: systemId));
      }

      // PRUNING: Remove systems that are no longer present in the JSON source.
      if (syncedSystemIds.isNotEmpty) {
        final placeholders = List.filled(syncedSystemIds.length, '?').join(',');
        await txn.delete(
          'app_systems',
          where: 'id NOT IN ($placeholders)',
          whereArgs: syncedSystemIds.toList(),
        );
      }
    });

    return syncedSystems;
  }

  static Future<void> _syncEmulators(
    TransactionAdapter txn,
    String systemId,
    List<EmulatorDefinition> emulators,
    Map<String, int> osMap,
    String systemFolderName,
  ) async {
    // Check if any default exists for this system (Core in app_emulators)
    final result = await txn.rawQuery(
      'SELECT COUNT(*) as count FROM app_emulators WHERE system_id = ? AND is_default = 1',
      [systemId],
    );
    final count = result.isNotEmpty
        ? (int.tryParse(result.first['count']?.toString() ?? '') ?? 0)
        : 0;

    // Also check if user has set a default standalone emulator
    final userResult = await txn.rawQuery(
      '''
      SELECT COUNT(*) as count 
      FROM user_emulator_config uc 
      JOIN app_emulators e ON uc.emulator_unique_id = e.unique_identifier 
      WHERE e.system_id = ? AND uc.is_user_default = 1
      ''',
      [systemId],
    );
    final userCount = userResult.isNotEmpty
        ? (int.tryParse(userResult.first['count']?.toString() ?? '') ?? 0)
        : 0;

    final hasDefaultInDB = count > 0 || userCount > 0;

    bool defaultSetInLoop = false;

    final Set<String> processedUniqueIds = {};

    for (final emuDef in emulators) {
      for (final platformEntry in emuDef.platforms.entries) {
        final osName = platformEntry.key.toLowerCase();

        // Case-insensitive lookup for OS ID
        int? osId = osMap[osName];
        if (osId == null) {
          // Try finding key case-insensitively
          for (final key in osMap.keys) {
            if (key.toLowerCase() == osName) {
              osId = osMap[key];
              break;
            }
          }
        }

        if (osId == null) continue;

        // --- FILTER: Android-specific emulators on Desktop ---
        // Prevents "RetroArch32" or "RetroArch64" from appearing on Linux/Windows/Mac
        // if they are just duplicates of the main RetroArch core with invalid configs.
        // We only allow these if the CURRENT platform key in JSON is strictly 'android'.
        // But the loop iterates all keys.
        // We need to check if we are inserting a Desktop OS entry for a "ra32/ra64" emulator.

        final isDesktopTarget = ['linux', 'windows', 'macos'].contains(osName);
        if (isDesktopTarget) {
          final lowerName = emuDef.name.toLowerCase();
          final isAndroidVariant =
              lowerName.contains('ra32') ||
              lowerName.contains('ra64') ||
              lowerName.contains('retroarch32') ||
              lowerName.contains('retroarch64');

          if (isAndroidVariant) {
            continue;
          }
        }
        // -----------------------------------------------------

        final platformData = platformEntry.value as Map<String, dynamic>;

        // Determine if core or standalone
        bool isStandalone = true;
        String? coreFilename;
        String? packageName;
        String? executable;

        if (osName == 'android') {
          packageName = platformData['package'];

          // Fallback: Parse launch_arguments if package is missing (new format)
          if (packageName == null &&
              platformData.containsKey('launch_arguments')) {
            final args = platformData['launch_arguments'].toString();

            // Extract package from "-n package/activity"
            final componentMatch = RegExp(r'-n\s+([^\s/]+)').firstMatch(args);
            if (componentMatch != null) {
              packageName = componentMatch.group(1);
            }

            // Check if RetroArch
            if (packageName != null && packageName.contains('retroarch')) {
              isStandalone = false;
              // Extract core from '--es LIBRETRO "corename"' or similar
              // Case insensitive check for LIBRETRO
              final coreMatch = RegExp(
                r'--es\s+LIBRETRO\s+"?([^"\s]+)"?',
                caseSensitive: false,
              ).firstMatch(args);
              if (coreMatch != null) {
                coreFilename = coreMatch.group(1);
              }
            }
          } else {
            // Legacy format check
            if (packageName != null && packageName.contains('retroarch')) {
              isStandalone = false;
              // Get core from extras
              final extras = platformData['extras'];
              if (extras != null && extras is List) {
                for (final extra in extras) {
                  if (extra['key'] == 'LIBRETRO') {
                    coreFilename = extra['value'];
                  }
                }
              }
            }
          }
        } else if (osName == 'windows') {
          executable = platformData['executable'];
          if (executable != null &&
              executable.toLowerCase().contains('retroarch')) {
            isStandalone = false;
          }
          final args = platformData['args'];
          if (args != null) {
            final match = RegExp(
              r'-L\s+(?:cores\\|cores/)?([\w_\-\.]+)',
            ).firstMatch(args);
            if (match != null) {
              coreFilename = match.group(1);
            }
          }
        } else if (osName == 'linux' || osName == 'macos') {
          executable = platformData['executable'];
          if (executable != null &&
              executable.toLowerCase().contains('retroarch')) {
            isStandalone = false;
          }
          final args = platformData['args'];
          if (args != null) {
            final match = RegExp(
              r'-L\s+(?:cores\\|cores/)?([\w_\-\.]+)',
            ).firstMatch(args);
            if (match != null) {
              coreFilename = match.group(1);
            }
          }
        }

        // Determine DB name (Unique per System+OS)
        String dbName = emuDef.name;
        if (osName == 'android' && packageName != null) {
          if (packageName == 'com.retroarch.aarch64') {
            dbName = '${emuDef.name} (64-bit)';
          } else if (packageName == 'com.retroarch.ra32') {
            dbName = '${emuDef.name} (32-bit)';
          }
        }

        // Determine if we should apply default from JSON
        final bool applyJsonDefault =
            !hasDefaultInDB && !defaultSetInLoop && emuDef.isDefault;

        if (applyJsonDefault) {
          defaultSetInLoop = true;
        }

        // Determine RetroAchievements compatibility
        final bool retroAchievementsCompatible =
            emuDef.isretroAchievementsCompatible ?? (!isStandalone);

        // Insert/Update
        final existing = await txn.query(
          'app_emulators',
          columns: ['unique_identifier'],
          where: 'unique_identifier = ? AND os_id = ?',
          whereArgs: [emuDef.uniqueId, osId],
        );

        if (existing.isNotEmpty) {
          processedUniqueIds.add(emuDef.uniqueId);

          final Map<String, Object?> updateData = {
            'name': dbName,
            'is_standalone': isStandalone ? 1 : 0,
            'core_filename': coreFilename,
            'android_package_name': packageName,
            'is_ra_compatible': retroAchievementsCompatible ? 1 : 0,
          };

          if (applyJsonDefault) {
            updateData['is_default'] = 1;
          }

          await txn.update(
            'app_emulators',
            updateData,
            where: 'unique_identifier = ? AND os_id = ?',
            whereArgs: [emuDef.uniqueId, osId],
          );
        } else {
          // Fallback: check by name for transition (old records without unique_identifier)
          final existingByName = await txn.query(
            'app_emulators',
            columns: ['unique_identifier'],
            where:
                'system_id = ? AND os_id = ? AND name = ? AND unique_identifier IS NULL',
            whereArgs: [systemId, osId, dbName],
          );

          if (existingByName.isNotEmpty) {
            // Update old record to add unique_identifier
            await txn.update(
              'app_emulators',
              {
                'unique_identifier': emuDef.uniqueId,
                'is_standalone': isStandalone ? 1 : 0,
                'core_filename': coreFilename,
                'android_package_name': packageName,
                'is_ra_compatible': retroAchievementsCompatible ? 1 : 0,
              },
              where:
                  'system_id = ? AND os_id = ? AND name = ? AND unique_identifier IS NULL',
              whereArgs: [systemId, osId, dbName],
            );
            processedUniqueIds.add(emuDef.uniqueId);
          } else {
            // New emulator
            await txn.insert('app_emulators', {
              'system_id': systemId,
              'os_id': osId,
              'name': dbName,
              'unique_identifier': emuDef.uniqueId,
              'is_standalone': isStandalone ? 1 : 0,
              'core_filename': coreFilename,
              'android_package_name': packageName,
              'is_default': applyJsonDefault ? 1 : 0,
              'is_ra_compatible': retroAchievementsCompatible ? 1 : 0,
            });
            processedUniqueIds.add(emuDef.uniqueId);
          }
        }
      }
    }

    // Prune logic: Delete emulators not in the processed list
    if (processedUniqueIds.isNotEmpty) {
      final placeholders = List.filled(
        processedUniqueIds.length,
        '?',
      ).join(',');

      // 1. Sever foreign key references in user_roms before deleting from app_emulators
      await txn.update(
        'user_roms',
        {'app_emulator_unique_id': null, 'app_emulator_os_id': null},
        where:
            'app_system_id = ? AND app_emulator_unique_id NOT IN ($placeholders)',
        whereArgs: [systemId, ...processedUniqueIds],
      );

      // 2. Clean up user_emulator_config
      final obsoleteEmulators = await txn.query(
        'app_emulators',
        columns: ['unique_identifier'],
        where: 'system_id = ? AND unique_identifier NOT IN ($placeholders)',
        whereArgs: [systemId, ...processedUniqueIds],
      );
      if (obsoleteEmulators.isNotEmpty) {
        final obsoleteIds = obsoleteEmulators
            .map((r) => r['unique_identifier'])
            .toList();
        final obsPlaceholders = List.filled(obsoleteIds.length, '?').join(',');
        await txn.delete(
          'user_emulator_config',
          where: 'emulator_unique_id IN ($obsPlaceholders)',
          whereArgs: obsoleteIds,
        );
      }

      // 3. Delete from app_emulators
      await txn.delete(
        'app_emulators',
        where: 'system_id = ? AND unique_identifier NOT IN ($placeholders)',
        whereArgs: [systemId, ...processedUniqueIds],
      );
    } else {
      // If no emulators were processed, delete all for this system
      // This handles the case where a system has no emulators defined in JSON
      if (emulators.isEmpty) {
        // 1. Sever foreign key references in user_roms
        await txn.update(
          'user_roms',
          {'app_emulator_unique_id': null, 'app_emulator_os_id': null},
          where: 'app_system_id = ?',
          whereArgs: [systemId],
        );

        // 2. Clean up user_emulator_config
        final obsoleteEmulators = await txn.query(
          'app_emulators',
          columns: ['unique_identifier'],
          where: 'system_id = ?',
          whereArgs: [systemId],
        );
        if (obsoleteEmulators.isNotEmpty) {
          final obsoleteIds = obsoleteEmulators
              .map((r) => r['unique_identifier'])
              .toList();
          final obsPlaceholders = List.filled(
            obsoleteIds.length,
            '?',
          ).join(',');
          await txn.delete(
            'user_emulator_config',
            where: 'emulator_unique_id IN ($obsPlaceholders)',
            whereArgs: obsoleteIds,
          );
        }

        // 3. Delete from app_emulators
        await txn.delete(
          'app_emulators',
          where: 'system_id = ?',
          whereArgs: [systemId],
        );
      }
    }
  }

  // Lock logging initialization to avoid recursion
  Completer<DatabaseAdapter>? _initCompleter;

  /// Provides the database instance (lazy initialization).
  Future<DatabaseAdapter> get database async {
    if (_database != null && _initialized) {
      return _database!;
    }

    // If an initialization is already in progress, wait for its completion.
    if (_initCompleter != null) {
      return _initCompleter!.future;
    }

    _initCompleter = Completer<DatabaseAdapter>();

    try {
      _database = await _initDatabase();
      _initCompleter!.complete(_database);
    } catch (e) {
      _initCompleter!.completeError(e);
      _initCompleter = null; // Allow retry on failure
      rethrow;
    }

    return _database!;
  }

  /// Initializes the database with versioning and migration support.
  Future<DatabaseAdapter> _initDatabase() async {
    try {
      _log.i('SQlite database init v$_databaseVersion');

      String dbPath;
      try {
        dbPath = await _getDatabasePath();
        _log.i('Database path: $dbPath');

        // Ensure the directory exists.
        final dbDir = Directory(path.dirname(dbPath));
        if (!await dbDir.exists()) {
          await dbDir.create(recursive: true);
        }
      } catch (e) {
        // On Android, this might fail if permissions haven't been granted yet.
        if (Platform.isAndroid && e.toString().contains('Permission denied')) {
          _log.w('Permission denied accessing DB. Waiting for SetupWizard...');
          // Rethrow to notify the provider/UI so SetupWizard can handle the retry later.
          throw Exception('StoragePermissionMissing');
        }
        rethrow;
      }

      // Android: Use legacy location directly.
      // Database path resolution is handled in _getDatabasePath.

      // Migration for Desktop platforms (Windows, Linux, MacOS)
      if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
        final userDataPath = await ConfigService.getUserDataPath();
        // User data path is .../folder/user-data. Root is .../folder
        final appRoot = Directory(userDataPath).parent;

        // Potential legacy locations:
        // 1. Root of the application (common in older portable versions)
        final oldPathRoot = path.join(appRoot.path, _databaseName);

        // 2. In a 'databases' subfolder at root (plugin default)
        final oldPathDbDir = path.join(
          appRoot.path,
          'databases',
          _databaseName,
        );

        // Attempt migration from legacy paths.
        if (await File(oldPathRoot).exists()) {
          await _attemptMigration(dbPath, File(oldPathRoot));
        } else if (await File(oldPathDbDir).exists()) {
          await _attemptMigration(dbPath, File(oldPathDbDir));
        }
      }

      final db = sqlite.sqlite3.open(dbPath);
      final adapter = DatabaseAdapter(db);

      await _onConfigure(adapter);

      // Simple version check mechanism as sqlite3 doesn't have onCreate/onUpgrade built-in like sqflite
      // We implement it manually using user_version pragma
      final versionResult = await adapter.rawQuery('PRAGMA user_version;');
      final currentVersion =
          int.tryParse(versionResult.first.values.first?.toString() ?? '') ?? 0;

      _log.i('Database version: $currentVersion');

      if (currentVersion == 0) {
        // Check for legacy installs that have tables but no version tracking.
        // Old app versions didn't set PRAGMA user_version, so they read as 0
        // even though user_config already exists. CREATE TABLE IF NOT EXISTS
        // is a no-op in that case, leaving new columns (e.g. app_language) missing.
        final existingTables = await adapter.rawQuery(
          "SELECT name FROM sqlite_master WHERE type='table' AND name='user_config';",
        );
        if (existingTables.isNotEmpty) {
          _log.i(
            'Legacy install detected (version=0 but tables exist). Running migrations.',
          );
          await _onUpgrade(adapter, 0, _databaseVersion);
        } else {
          await _onCreate(adapter, _databaseVersion);
        }
      } else if (currentVersion < _databaseVersion) {
        await _onUpgrade(adapter, currentVersion, _databaseVersion);
      } else if (currentVersion > _databaseVersion) {
        await _onDowngrade(adapter, currentVersion, _databaseVersion);
      }

      // Update version
      await adapter.execute('PRAGMA user_version = $_databaseVersion;');

      _initialized = true;
      _log.i('Database initialized');

      return adapter;
    } catch (e, stackTrace) {
      _log.e('Error initializing database', error: e, stackTrace: stackTrace);
      rethrow;
    }
  }

  /// Configures the database session (runs before schema creation/upgrades).
  Future<void> _onConfigure(DatabaseAdapter db) async {
    // Enable referential integrity
    await db.execute('PRAGMA foreign_keys = ON;');

    // Performance optimizations
    await db.execute('PRAGMA synchronous = NORMAL;');
    await db.execute('PRAGMA cache_size = 1000;');
    await db.execute('PRAGMA temp_store = memory;');
    await db.execute('PRAGMA journal_mode = WAL;');

    // Verify critical tables exist before attempting hotfixes.
    // This prevents "no such table" errors during fresh initializations.
    final tables = await db.rawQuery(
      "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%'",
    );
    final tableNames = tables.map((r) => r['name'].toString()).toSet();

    // Only run hotfixes if the target tables exist.

    // FIX: Ensure user_rom_folders exists even if migrations were skipped.
    // This is safe as it uses IF NOT EXISTS.
    await db.execute('''
      CREATE TABLE IF NOT EXISTS user_rom_folders (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        path TEXT NOT NULL UNIQUE
      );
    ''');

    // Add newly created table to known set.
    if (!tableNames.contains('user_rom_folders')) {
      tableNames.add('user_rom_folders');
    }

    // FIX: Ensure user_screenscraper_config columns are up to date (v29).
    await _ensureScreenScraperConfigColumns(db);

    // FIX: Resolve inconsistencies in default emulator assignments.
    if (tableNames.contains('app_systems') &&
        tableNames.contains('app_emulators')) {
      try {
        await _fixEmulatorDefaults(db);
      } catch (e) {
        _log.e('Minor fix for defaults failed (expected in first run): $e');
      }
    }

    // FIX: Mark standalone emulators as achievement compatible.
    if (tableNames.contains('app_emulators')) {
      try {
        await _fixAchievementCompatibility(db);
      } catch (e) {
        _log.e('Minor fix for achievements failed (expected in first run): $e');
      }
    }

    // FIX: Ensure user_system_settings includes v41 columns.
    if (tableNames.contains('user_system_settings')) {
      try {
        await _ensureSystemSettingsColumns(db);
      } catch (e) {
        _log.e('Minor fix for system settings failed: $e');
      }
    }

    // FIX: Ensure unique_identifier column in app_emulators.
    if (tableNames.contains('app_emulators')) {
      try {
        await _ensureEmulatorUniqueIdentifierColumn(db);
      } catch (e) {
        _log.e('Minor fix for emulator identifiers failed: $e');
      }
    }

    // FIX: Ensure app_neo_sync_state exists (legacy support for v58).
    await db.execute('''
      CREATE TABLE IF NOT EXISTS app_neo_sync_state (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        file_path TEXT NOT NULL UNIQUE,
        local_modified_at INTEGER NOT NULL,
        cloud_updated_at INTEGER NOT NULL,
        file_size INTEGER NOT NULL,
        file_hash TEXT
      );
    ''');
    await db.execute('''
      CREATE INDEX IF NOT EXISTS idx_neo_sync_state_file_path 
      ON app_neo_sync_state(file_path);
    ''');
  }

  /// Ensures the unique_identifier column exists in app_emulators.
  Future<void> _ensureEmulatorUniqueIdentifierColumn(DatabaseAdapter db) async {
    try {
      final tableInfo = await db.rawQuery('PRAGMA table_info(app_emulators)');
      final columns = tableInfo.map((c) => c['name'].toString()).toList();
      if (!columns.contains('unique_identifier')) {
        await db.execute(
          'ALTER TABLE app_emulators ADD COLUMN unique_identifier TEXT',
        );
      }
    } catch (e) {
      _log.e('Minor fix ensuring emulator unique identifier failed: $e');
      rethrow;
    }
  }

  /// Ensures core system columns exist in app_systems.
  Future<void> _ensureAppSystemsColumns(DatabaseAdapter db) async {
    try {
      final tableInfo = await db.rawQuery('PRAGMA table_info(app_systems)');
      final columns = tableInfo.map((c) => c['name'].toString()).toList();

      if (!columns.contains('manufacturer')) {
        await db.execute(
          'ALTER TABLE app_systems ADD COLUMN manufacturer TEXT',
        );
      }
      if (!columns.contains('type')) {
        await db.execute('ALTER TABLE app_systems ADD COLUMN type TEXT');
      }
    } catch (e) {
      _log.e('Minor fix ensuring app_systems columns failed: $e');
      rethrow;
    }
  }

  /// Ensures required columns exist in user_system_settings.
  Future<void> _ensureSystemSettingsColumns(DatabaseAdapter db) async {
    try {
      final tableInfo = await db.rawQuery(
        'PRAGMA table_info(user_system_settings)',
      );
      final columns = tableInfo.map((c) => c['name'].toString()).toList();

      if (!columns.contains('custom_background_path')) {
        await db.execute(
          'ALTER TABLE user_system_settings ADD COLUMN custom_background_path TEXT',
        );
      }
      if (!columns.contains('hide_logo')) {
        await db.execute(
          'ALTER TABLE user_system_settings ADD COLUMN hide_logo INTEGER DEFAULT 0',
        );
      }
      if (!columns.contains('hide_extension')) {
        await db.execute(
          'ALTER TABLE user_system_settings ADD COLUMN hide_extension INTEGER DEFAULT 0',
        );
      }
      if (!columns.contains('hide_parentheses')) {
        await db.execute(
          'ALTER TABLE user_system_settings ADD COLUMN hide_parentheses INTEGER DEFAULT 0',
        );
      }
      if (!columns.contains('hide_brackets')) {
        await db.execute(
          'ALTER TABLE user_system_settings ADD COLUMN hide_brackets INTEGER DEFAULT 0',
        );
      }
      if (!columns.contains('prefer_file_name')) {
        await db.execute(
          'ALTER TABLE user_system_settings ADD COLUMN prefer_file_name INTEGER DEFAULT 0',
        );
      }
      if (!columns.contains('custom_logo_path')) {
        await db.execute(
          'ALTER TABLE user_system_settings ADD COLUMN custom_logo_path TEXT',
        );
      }
    } catch (e) {
      _log.e('Minor fix ensuring system settings columns failed: $e');
      rethrow;
    }
  }

  /// Ensures required columns exist in user_screenscraper_config.
  Future<void> _ensureScreenScraperConfigColumns(DatabaseAdapter db) async {
    try {
      // Create table if missing.
      await db.execute('''
        CREATE TABLE IF NOT EXISTS user_screenscraper_config (
          id INTEGER PRIMARY KEY CHECK (id = 1),
          scrape_mode TEXT NOT NULL DEFAULT 'new_only',
          max_requests_per_minute INTEGER DEFAULT 10,
          timeout_seconds INTEGER DEFAULT 30,
          scrape_metadata INTEGER DEFAULT 1,
          scrape_images INTEGER DEFAULT 1,
          scrape_videos INTEGER DEFAULT 1,
          updated_at TEXT DEFAULT CURRENT_TIMESTAMP
        );
      ''');

      // Check for individual columns.
      final tableInfo = await db.rawQuery(
        'PRAGMA table_info(user_screenscraper_config)',
      );
      final columns = tableInfo.map((c) => c['name'].toString()).toList();

      if (!columns.contains('scrape_metadata')) {
        await db.execute(
          'ALTER TABLE user_screenscraper_config ADD COLUMN scrape_metadata INTEGER DEFAULT 1',
        );
      }
      if (!columns.contains('scrape_images')) {
        await db.execute(
          'ALTER TABLE user_screenscraper_config ADD COLUMN scrape_images INTEGER DEFAULT 1',
        );
      }
      if (!columns.contains('scrape_videos')) {
        await db.execute(
          'ALTER TABLE user_screenscraper_config ADD COLUMN scrape_videos INTEGER DEFAULT 1',
        );
      }

      // Ensure default configuration entry exists.
      final config = await db.query(
        'user_screenscraper_config',
        where: 'id = 1',
      );
      if (config.isEmpty) {
        await db.insert('user_screenscraper_config', {
          'id': 1,
          'scrape_mode': 'new_only',
          'max_requests_per_minute': 10,
          'timeout_seconds': 30,
          'scrape_metadata': 1,
          'scrape_images': 1,
          'scrape_videos': 1,
        });
      }
    } catch (e) {
      _log.e('Error ensuring ScreenScraper configuration integrity: $e');
      rethrow;
    }
  }

  /// Creates initial database tables during first run.
  Future<void> _onCreate(DatabaseAdapter db, int version) async {
    final stopwatch = Stopwatch()..start();

    try {
      // Create schema within an atomic transaction.
      await db.transaction((txn) async {
        await _createAppTables(txn);
        await _createUserTables(txn);
        await _createRetroArchTables(txn);
      });

      // Populate initial data.
      await _insertInitialData(db);

      // Initialize optimized indexes.
      await _createIndexes(db);

      // Defensive check for system columns.
      await _ensureAppSystemsColumns(db);

      stopwatch.stop();
    } catch (e, stackTrace) {
      _log.e(
        'Error creating initial database schema',
        error: e,
        stackTrace: stackTrace,
      );
      rethrow;
    }
  }

  /// Handles database schema upgrades.
  Future<void> _onUpgrade(
    DatabaseAdapter db,
    int oldVersion,
    int newVersion,
  ) async {
    for (int version = oldVersion + 1; version <= newVersion; version++) {
      await _migrateToVersion(db, version);
    }
  }

  /// Routes a version migration to the central migration manager.
  Future<void> _migrateToVersion(DatabaseAdapter db, int version) async {
    await SqliteMigrations.migrateToVersion(db.rawDb, version);
  }

  /// Handles database schema downgrades by recreating the schema.
  Future<void> _onDowngrade(
    DatabaseAdapter db,
    int oldVersion,
    int newVersion,
  ) async {
    await _recreateDatabase(db);
  }

  /// Completely drops and recreates the database schema.
  Future<void> _recreateDatabase(DatabaseAdapter db) async {
    final tables = await db.rawQuery(
      "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%';",
    );

    for (final table in tables) {
      final tableName = table['name'].toString();
      await db.execute('DROP TABLE IF EXISTS $tableName;');
    }

    await _onCreate(db, _databaseVersion);
  }

  /// Creates internal application tables (systems, emulators, etc.).
  Future<void> _createAppTables(DatabaseExecutorAdapter db) async {
    const appTables = [
      '''
      CREATE TABLE IF NOT EXISTS app_os (
          id INTEGER PRIMARY KEY,
          name TEXT NOT NULL UNIQUE
      );
      ''',
      '''
      CREATE TABLE IF NOT EXISTS app_systems (
          id TEXT PRIMARY KEY,
          screenscraper_id INTEGER,
          ra_id INTEGER,
          real_name TEXT NOT NULL,
          short_name TEXT,
          folder_name TEXT NOT NULL UNIQUE,
          launch_date DATE,
          description TEXT,
          manufacturer TEXT,
          type TEXT,
          color1 TEXT,
          color2 TEXT,
          neosync_json TEXT
      );
      ''',
      '''
      CREATE TABLE IF NOT EXISTS app_system_folders (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          system_id TEXT NOT NULL,
          folder_name TEXT NOT NULL,
          FOREIGN KEY (system_id) REFERENCES app_systems(id) ON DELETE CASCADE,
          UNIQUE(system_id, folder_name)
      );
      ''',
      '''
      CREATE TABLE IF NOT EXISTS app_system_extensions (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          system_id TEXT NOT NULL,
          extension TEXT NOT NULL,
          FOREIGN KEY (system_id) REFERENCES app_systems(id) ON DELETE CASCADE,
          UNIQUE(system_id, extension)
      );
      ''',
      '''
      CREATE TABLE IF NOT EXISTS app_emulators (
          unique_identifier TEXT NOT NULL,
          os_id INTEGER NOT NULL,
          system_id TEXT NOT NULL,
          name TEXT NOT NULL,
          is_standalone INTEGER NOT NULL DEFAULT 0,
          core_filename TEXT,
          is_default INTEGER NOT NULL DEFAULT 0,
          is_ra_compatible INTEGER NOT NULL DEFAULT 0,
          android_package_name TEXT,
          android_activity_name TEXT,
          PRIMARY KEY (os_id, unique_identifier),
          FOREIGN KEY (os_id) REFERENCES app_os(id) ON DELETE CASCADE,
          FOREIGN KEY (system_id) REFERENCES app_systems(id) ON DELETE CASCADE
      );
      ''',
    ];

    for (final sql in appTables) {
      await db.execute(sql.trim());
    }
  }

  /// Creates user-specific configuration and metadata tables.
  Future<void> _createUserTables(DatabaseExecutorAdapter db) async {
    const tables = [
      '''
      CREATE TABLE IF NOT EXISTS user_config (
        id INTEGER PRIMARY KEY CHECK (id = 1),
        last_scan TEXT,
        game_view_mode TEXT DEFAULT 'list',
        system_view_mode TEXT DEFAULT 'grid',
        palette_name TEXT DEFAULT 'system',
        video_sound INTEGER DEFAULT 1,
        ra_user TEXT,
        show_game_info INTEGER DEFAULT 0,
        is_fullscreen INTEGER DEFAULT 1,
        bartop_exit_poweroff INTEGER DEFAULT 0,
        scan_on_startup INTEGER DEFAULT 1,
        setup_completed INTEGER DEFAULT 0,
        hide_bottom_screen INTEGER DEFAULT 0,
        sfx_enabled INTEGER DEFAULT 1,
        system_sort_by TEXT DEFAULT 'alphabetical',
        system_sort_order TEXT DEFAULT 'asc',
        app_language TEXT DEFAULT 'en',
        active_theme TEXT DEFAULT '',
        hide_recent_card INTEGER DEFAULT 0,
        active_sync_provider TEXT DEFAULT 'neosync',
        systems_version TEXT DEFAULT '',
        neostation_app_version TEXT DEFAULT '',
        auto_update_app INTEGER DEFAULT 1,
        auto_update_systems INTEGER DEFAULT 1
      );
      ''',
      '''
      CREATE TABLE IF NOT EXISTS user_detected_systems (
        app_system_id TEXT NOT NULL,
        actual_folder_name TEXT,
        detected_at TEXT DEFAULT CURRENT_TIMESTAMP,
        is_hidden INTEGER DEFAULT 0,
        FOREIGN KEY (app_system_id) REFERENCES app_systems(id) ON DELETE CASCADE,
        UNIQUE(app_system_id)
      );
      ''',

      '''
      CREATE TABLE IF NOT EXISTS user_rom_folders (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        path TEXT NOT NULL UNIQUE COLLATE NOCASE
      );
      ''',

      '''
      CREATE TABLE IF NOT EXISTS user_emulator_config (
        emulator_unique_id TEXT NOT NULL,
        emulator_path TEXT NOT NULL,
        is_user_default INTEGER DEFAULT NULL,
        created_at TEXT DEFAULT CURRENT_TIMESTAMP,
        updated_at TEXT DEFAULT CURRENT_TIMESTAMP,
        PRIMARY KEY(emulator_unique_id)
      );
      ''',
      '''
      CREATE TABLE IF NOT EXISTS user_roms (
        app_system_id TEXT NOT NULL,
        app_emulator_unique_id TEXT,
        app_emulator_os_id INTEGER,
        app_alternative_emulators_id INTEGER,
        virtual_folder_name TEXT, -- DEPRECATED: Column to be removed in next migration
        filename TEXT NOT NULL,
        rom_path TEXT NOT NULL COLLATE NOCASE,
        ra_hash TEXT,
        ss_hash TEXT,
        id_ra INTEGER,
        is_favorite INTEGER DEFAULT 0,
        play_time INTEGER DEFAULT 0,
        last_played TEXT,
        cloud_sync_enabled INTEGER DEFAULT 1,
        title_id TEXT,
        title_name TEXT,
        description TEXT,
        year TEXT,
        developer TEXT,
        publisher TEXT,
        genre TEXT,
        players TEXT,
        created_at TEXT DEFAULT CURRENT_TIMESTAMP,
        updated_at TEXT DEFAULT CURRENT_TIMESTAMP,
        FOREIGN KEY (app_system_id) REFERENCES app_systems(id) ON DELETE CASCADE,
        FOREIGN KEY (app_emulator_os_id, app_emulator_unique_id) REFERENCES app_emulators(os_id, unique_identifier),
        UNIQUE(rom_path)
      );
      ''',
      '''
      CREATE TABLE IF NOT EXISTS user_screenscraper_credentials (
        id INTEGER PRIMARY KEY CHECK (id = 1),
        username TEXT,
        password TEXT,
        user_id TEXT,
        level TEXT,
        contribution TEXT,
        maxthreads TEXT,
        requests_today INTEGER DEFAULT 0,
        max_requests_per_day INTEGER DEFAULT 0,
        requests_ko_today INTEGER DEFAULT 0,
        max_requests_ko_per_day INTEGER DEFAULT 0,
        max_download_speed INTEGER DEFAULT 0,
        visites INTEGER DEFAULT 0,
        last_visit TEXT,
        fav_region TEXT,
        preferred_language TEXT DEFAULT 'en',
        updated_at TEXT DEFAULT CURRENT_TIMESTAMP
      );
      ''',
      '''
      CREATE TABLE IF NOT EXISTS user_screenscraper_config (
        id INTEGER PRIMARY KEY CHECK (id = 1),
        scrape_mode TEXT NOT NULL DEFAULT 'new_only',
        max_requests_per_minute INTEGER DEFAULT 10,
        timeout_seconds INTEGER DEFAULT 30,
        scrape_metadata INTEGER DEFAULT 1,
        scrape_images INTEGER DEFAULT 1,
        scrape_videos INTEGER DEFAULT 1,
        updated_at TEXT DEFAULT CURRENT_TIMESTAMP
      );
      ''',
      '''
      CREATE TABLE IF NOT EXISTS user_screenscraper_system_metadata (
        app_system_id TEXT NOT NULL,
        system_name TEXT,
        manufacturer TEXT,
        updated_at TEXT DEFAULT CURRENT_TIMESTAMP,
        FOREIGN KEY (app_system_id) REFERENCES app_systems(id) ON DELETE CASCADE,
        UNIQUE(app_system_id)
      );
      ''',
      '''
      CREATE TABLE IF NOT EXISTS user_screenscraper_metadata (
        app_system_id TEXT NOT NULL,
        filename TEXT NOT NULL,
        id_ra INTEGER,
        real_name TEXT,
        description_en TEXT,
        description_es TEXT,
        description_fr TEXT,
        description_de TEXT,
        description_it TEXT,
        description_pt TEXT,
        rating REAL,
        release_date TEXT,
        developer TEXT,
        publisher TEXT,
        genre TEXT,
        players TEXT,
        is_fully_scraped INTEGER DEFAULT 0,
        updated_at TEXT DEFAULT CURRENT_TIMESTAMP,
        FOREIGN KEY (app_system_id) REFERENCES app_systems(id) ON DELETE CASCADE,
        UNIQUE(app_system_id, filename)
      );
      ''',
      '''
      CREATE TABLE IF NOT EXISTS user_screenscraper_system_config (
          app_system_id TEXT PRIMARY KEY,
          enabled BOOLEAN NOT NULL DEFAULT 1,
          FOREIGN KEY (app_system_id) REFERENCES app_systems(id) ON DELETE CASCADE
      );
      ''',
      '''
      CREATE TABLE IF NOT EXISTS user_system_settings (
        app_system_id TEXT NOT NULL,
        recursive_scan INTEGER DEFAULT 1,
        hide_extension INTEGER DEFAULT 1,
        hide_parentheses INTEGER DEFAULT 1,
        hide_brackets INTEGER DEFAULT 1,
        custom_background_path TEXT,
        custom_logo_path TEXT,
        hide_logo INTEGER DEFAULT 0,
        prefer_file_name INTEGER DEFAULT 0,
        updated_at TEXT DEFAULT CURRENT_TIMESTAMP,
        FOREIGN KEY (app_system_id) REFERENCES app_systems(id) ON DELETE CASCADE,
        UNIQUE(app_system_id)
      );
      ''',
      '''
      CREATE TABLE IF NOT EXISTS app_neo_sync_state (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        file_path TEXT NOT NULL UNIQUE,
        local_modified_at INTEGER NOT NULL,
        cloud_updated_at INTEGER NOT NULL,
        file_size INTEGER NOT NULL,
        file_hash TEXT
      );
      ''',
    ];

    for (final sql in tables) {
      await db.execute(sql.trim());
    }
  }

  /// Creates tables dedicated to RetroAchievements game metadata.
  Future<void> _createRetroArchTables(DatabaseExecutorAdapter db) async {
    const raTables = [
      '''
      CREATE TABLE IF NOT EXISTS app_ra_game_list (
          id INTEGER,
          game_id INTEGER NOT NULL,
          title TEXT NOT NULL,
          console_id INTEGER NOT NULL,
          console_name TEXT NOT NULL,
          image_icon TEXT,
          num_achievements INTEGER NOT NULL DEFAULT 0,
          num_leaderboards INTEGER NOT NULL DEFAULT 0,
          points INTEGER NOT NULL DEFAULT 0,
          date_modified TEXT,
          forum_topic_id INTEGER,
          hash TEXT NOT NULL
      );
      ''',
    ];

    for (final sql in raTables) {
      await db.execute(sql.trim());
    }
  }

  /// Creates database indexes to optimize query performance across critical tables.
  Future<void> _createIndexes(DatabaseExecutorAdapter db) async {
    const indexes = [
      // Indexes for user_roms
      'CREATE INDEX IF NOT EXISTS idx_user_roms_app_system_id ON user_roms(app_system_id);',
      'CREATE INDEX IF NOT EXISTS idx_user_roms_ra_hash ON user_roms(ra_hash);',
      'CREATE INDEX IF NOT EXISTS idx_user_roms_ss_hash ON user_roms(ss_hash);',
      'CREATE INDEX IF NOT EXISTS idx_user_roms_filename ON user_roms(filename);',
      'CREATE INDEX IF NOT EXISTS idx_user_roms_is_favorite ON user_roms(is_favorite);',
      'CREATE INDEX IF NOT EXISTS idx_user_roms_id_ra ON user_roms(id_ra);',

      // Indexes for user_screenscraper_metadata
      'CREATE INDEX IF NOT EXISTS idx_user_screenscraper_metadata_filename ON user_screenscraper_metadata(filename);',
      'CREATE INDEX IF NOT EXISTS idx_user_screenscraper_metadata_app_system_id ON user_screenscraper_metadata(app_system_id);',
      'CREATE INDEX IF NOT EXISTS idx_user_screenscraper_metadata_developer ON user_screenscraper_metadata(developer);',
      'CREATE INDEX IF NOT EXISTS idx_user_screenscraper_metadata_publisher ON user_screenscraper_metadata(publisher);',
      'CREATE INDEX IF NOT EXISTS idx_user_screenscraper_metadata_genre ON user_screenscraper_metadata(genre);',
      'CREATE INDEX IF NOT EXISTS idx_user_screenscraper_metadata_release_date ON user_screenscraper_metadata(release_date);',
      'CREATE INDEX IF NOT EXISTS idx_user_screenscraper_metadata_is_fully_scraped ON user_screenscraper_metadata(is_fully_scraped);',

      // Indexes for RetroAchievements
      'CREATE INDEX IF NOT EXISTS idx_app_ra_game_list_console_id ON app_ra_game_list(console_id);',
      'CREATE INDEX IF NOT EXISTS idx_app_ra_game_list_game_id ON app_ra_game_list(game_id);',
      'CREATE INDEX IF NOT EXISTS idx_app_ra_game_list_hash ON app_ra_game_list(hash);',
      'CREATE INDEX IF NOT EXISTS idx_app_ra_game_list_title ON app_ra_game_list(title);',

      // 3. Indexes for app_systems (including virtual systems >= 1000)
      'CREATE INDEX IF NOT EXISTS idx_app_systems_folder_name ON app_systems(folder_name);',

      // 4. Index for app_system_folders (optimizes alternative folder name lookups)
      'CREATE INDEX IF NOT EXISTS idx_system_folders_name ON app_system_folders(folder_name);',

      // 5. Index for user_emulator_config
      'CREATE INDEX IF NOT EXISTS idx_user_emulator_config_is_user_default ON user_emulator_config(is_user_default);',

      // 6. Index for app_neo_sync_state
      'CREATE INDEX IF NOT EXISTS idx_neo_sync_state_file_path ON app_neo_sync_state(file_path);',
    ];

    for (final sql in indexes) {
      await db.execute(sql);
    }
  }

  /// Populates the database with initial seed data from SQL assets.
  Future<void> _insertInitialData(DatabaseAdapter db) async {
    final stopwatch = Stopwatch()..start();

    try {
      await db.transaction((txn) async {
        await txn.execute('''
          INSERT OR IGNORE INTO app_os (id, name) VALUES
          (1, 'windows'),
          (2, 'android'),
          (3, 'linux'),
          (4, 'macos'),
          (5, 'ios')
        ''');
        await txn.execute('''
          INSERT OR IGNORE INTO user_screenscraper_config (id, scrape_mode) VALUES (1, 'new_only')
        ''');
        await _executeSqlFileOptimized(
          txn,
          'assets/data/ra_insert.sql',
          'ra_insert',
        );

        // Insert "All Systems" virtual system for settings persistence
        await txn.execute('''
          INSERT OR IGNORE INTO app_systems (id, screenscraper_id, ra_id, real_name, folder_name, launch_date, description)
          VALUES ('all', 0, 0, 'All Systems', 'all', '2024-01-01', 
                  'Collection of all systems available in NeoStation.')
        ''');
      });

      stopwatch.stop();
    } catch (e, stackTrace) {
      _log.e('Error inserting initial data', error: e, stackTrace: stackTrace);
      rethrow;
    }
  }

  Future<void> _executeSqlFileOptimized(
    DatabaseExecutorAdapter db,
    String assetPath,
    String fileName, {
    bool useTransaction = true,
  }) async {
    final content = await rootBundle.loadString(assetPath);
    final statements = _parseSqlStatements(content);

    if (statements.isEmpty) return;

    if (useTransaction && db is DatabaseAdapter) {
      // Use internal transaction for standalone calls
      final database = db;
      await database.transaction((txn) async {
        final batch = txn.batch(); // Simulates batching in adapter
        for (final statement in statements) {
          final trimmed = statement.trim();
          if (trimmed.isNotEmpty && !_isCommentOrEmpty(trimmed)) {
            batch.execute(trimmed);
          }
        }
        await batch.commit(noResult: true);
      });
    } else {
      // Use existing executor (transaction already in progress)
      final batch = db.batch();
      for (final statement in statements) {
        final trimmed = statement.trim();
        if (trimmed.isNotEmpty && !_isCommentOrEmpty(trimmed)) {
          batch.execute(trimmed);
        }
      }
      await batch.commit(noResult: true);
    }
  }

  /// Robustly parses individual SQL statements from a multi-statement string.
  List<String> _parseSqlStatements(String content) {
    final statements = <String>[];
    final buffer = StringBuffer();
    bool inSingleQuote = false;
    bool inDoubleQuote = false;
    bool inBlockComment = false;
    bool inLineComment = false;

    for (int i = 0; i < content.length; i++) {
      final char = content[i];
      final nextChar = i + 1 < content.length ? content[i + 1] : '';

      // Handle block comments
      if (!inSingleQuote && !inDoubleQuote && !inLineComment) {
        if (char == '/' && nextChar == '*') {
          inBlockComment = true;
          i++; // Skip next char
          continue;
        }
        if (char == '*' && nextChar == '/') {
          inBlockComment = false;
          i++; // Skip next char
          continue;
        }
      }

      if (inBlockComment) continue;

      // Handle line comments
      if (!inSingleQuote && !inDoubleQuote && char == '-' && nextChar == '-') {
        inLineComment = true;
        i++; // Skip next char
        continue;
      }
      if (inLineComment && char == '\n') {
        inLineComment = false;
        continue;
      }
      if (inLineComment) continue;

      // Handle quotes
      if (char == "'" && !inDoubleQuote) {
        inSingleQuote = !inSingleQuote;
      } else if (char == '"' && !inSingleQuote) {
        inDoubleQuote = !inDoubleQuote;
      }

      // Check for statement terminator outside of quotes and comments
      if (char == ';' && !inSingleQuote && !inDoubleQuote) {
        final statement = buffer.toString().trim();
        if (statement.isNotEmpty) {
          statements.add(statement);
        }
        buffer.clear();
        continue;
      }

      buffer.write(char);
    }

    // Add final statement if exists
    final lastStatement = buffer.toString().trim();
    if (lastStatement.isNotEmpty) {
      statements.add(lastStatement);
    }

    return statements;
  }

  /// Checks if a line is a comment or effectively empty.
  bool _isCommentOrEmpty(String line) {
    final trimmed = line.trim();
    return trimmed.isEmpty ||
        trimmed.startsWith('--') ||
        trimmed.startsWith('/*') ||
        trimmed == ';';
  }

  /// Resolves the absolute path for the database file.
  Future<String> _getDatabasePath() async {
    // Standardize logic using ConfigService for platform-agnostic storage.
    final userDataPath = await ConfigService.getUserDataPath();
    final dbDir = Directory(userDataPath);

    if (!await dbDir.exists()) {
      await dbDir.create(recursive: true);
    }

    return path.join(userDataPath, _databaseName);
  }

  /// Closes the database connection and resets state.
  Future<void> close() async {
    if (_database != null) {
      await _database!.close();
      _database = null;
      _initialized = false;
      _initCompleter = null; // Allow fresh initialization after close.
    }
  }

  /// Forces database recreation by deleting the existing file (for debugging).
  Future<void> resetDatabase() async {
    await close();

    final dbPath = await _getDatabasePath();
    final file = File(dbPath);
    if (await file.exists()) {
      await file.delete();
    }

    // Re-initialize
    _database = await _initDatabase();
  }

  // ==========================================
  // VALIDATION & DEBUG METHODS
  // ==========================================

  /// Validates the database integrity and schema health.
  Future<bool> validateDatabase() async {
    try {
      final db = await database;

      // Verify presence of critical tables
      final criticalTables = [
        'app_system_extensions',
        'app_systems',
        'app_emulators',
        'user_config',
        'user_roms',
      ];

      for (final table in criticalTables) {
        final result = await db.rawQuery(
          "SELECT name FROM sqlite_master WHERE type='table' AND name=?",
          [table],
        );
        if (result.isEmpty) {
          _log.e('Critical table missing: $table');
          return false;
        }
      }

      // Check referential integrity
      await db.execute('PRAGMA foreign_key_check;');

      // Run full integrity check
      final integrityResult = await db.rawQuery('PRAGMA integrity_check;');
      final integrityStatus = integrityResult.first['integrity_check']
          ?.toString();

      if (integrityStatus != 'ok') {
        _log.e('Database integrity compromised: $integrityStatus');
        return false;
      }

      return true;
    } catch (e, stackTrace) {
      _log.e('Error validating database', error: e, stackTrace: stackTrace);
      return false;
    }
  }

  /// Collects operational statistics and storage usage from the database.
  Future<Map<String, dynamic>> getDatabaseStats() async {
    try {
      final db = await database;

      final stats = <String, dynamic>{};

      // Record counts per table
      final tables = [
        'app_os',
        'app_systems',
        'app_system_extensions',
        'app_emulators',
        'user_roms',
        'user_detected_systems',
      ];

      for (final table in tables) {
        final result = await db.rawQuery(
          'SELECT COUNT(*) as count FROM $table',
        );
        stats['${table}_count'] =
            int.tryParse(result.first['count']?.toString() ?? '') ?? 0;
      }

      // Database file metrics
      final dbPath = await _getDatabasePath();
      final file = File(dbPath);
      if (await file.exists()) {
        stats['database_size_bytes'] = await file.length();
        stats['database_size_mb'] = (await file.length()) / (1024 * 1024);
      }

      // Engine version
      final sqliteVersion = await db.rawQuery(
        'SELECT sqlite_version() as version',
      );
      stats['sqlite_version'] = sqliteVersion.first['version'].toString();

      return stats;
    } catch (e, stackTrace) {
      _log.e('Error getting database stats', error: e, stackTrace: stackTrace);
      return {};
    }
  }

  // ==========================================
  // LEGACY COMPATIBILITY METHODS
  // ==========================================

  /// Static alias for [database] to maintain backward compatibility.
  static Future<DatabaseAdapter> getDatabase() async => instance.database;

  /// Static alias for [close].
  static Future<void> closeDatabase() => instance.close();

  /// Static alias for database initialization.
  static Future<DatabaseAdapter> initDatabase() async {
    return await instance.database;
  }

  /// Retrieves the absolute file path of the current database.
  static Future<String> getActualDatabasePath() async {
    return await instance._getDatabasePath();
  }

  /// Manually triggers schema creation from a custom script.
  static Future<void> createDatabaseFromScript(
    DatabaseAdapter db,
    int version,
  ) async {
    await instance._onCreate(db, version);
  }

  /// Executes a table creation script with optimized transaction handling.
  static Future<void> executeCreateScript(
    DatabaseAdapter db,
    String assetPath,
  ) async {
    await instance._executeSqlFileOptimized(
      db,
      assetPath,
      path.basename(assetPath),
    );
  }

  /// Executes a data insertion script optimized for batch performance.
  static Future<void> executeInsertScript(
    DatabaseAdapter db,
    String assetPath,
  ) async {
    await instance._executeSqlFileOptimized(
      db,
      assetPath,
      path.basename(assetPath),
    );
  }

  /// Executes an index creation script within an optimized transaction.
  static Future<void> executeIndexScript(
    DatabaseAdapter db,
    String assetPath,
  ) async {
    await instance._executeSqlFileOptimized(
      db,
      assetPath,
      path.basename(assetPath),
    );
  }

  /// Initializes essential user configuration records after schema creation.
  static Future<void> initializeUserData(DatabaseAdapter db) async {
    try {
      // Default initial configuration
      await db.insert('user_config', {
        'id': 1,
        'last_scan': null,
        'system_view_mode': 'grid',
        'palette_name': 'system',
        'video_sound': 1,
        'ra_user': null,
        'show_game_info': 0,
        'is_fullscreen': 1,
      });
    } catch (e) {
      _log.e('Error creating initial user configuration', error: e);
    }
  }

  // ==========================================
  // USER CONFIGURATION METHODS
  // ==========================================

  /// Retrieves the current user configuration record.
  static Future<Map<String, dynamic>?> getUserConfig() async {
    final db = await instance.database;
    final results = await db.query('user_config', limit: 1);

    if (results.isNotEmpty) {
      return results.first;
    }
    return null;
  }

  /// Retrieves all configured ROM root directories.
  static Future<List<String>> getUserRomFolders() async {
    final db = await instance.database;
    final results = await db.query('user_rom_folders', orderBy: 'id ASC');
    return results.map((row) => row['path'].toString()).toList();
  }

  /// Persists a complete list of ROM directories, replacing existing ones.
  static Future<void> saveUserRomFolders(List<String> folders) async {
    final db = await instance.database;
    await db.transaction((txn) async {
      await txn.delete('user_rom_folders');
      for (final folder in folders) {
        if (folder.isNotEmpty) {
          await txn.insert('user_rom_folders', {'path': folder});
        }
      }
    });
  }

  /// Registers a new ROM directory.
  static Future<void> addRomFolder(String folderPath) async {
    if (folderPath.isEmpty) return;
    final db = await instance.database;
    await db.insert('user_rom_folders', {
      'path': folderPath,
    }, conflictAlgorithm: ConflictAlgorithm.ignore);
  }

  /// Removes a ROM directory from configuration.
  static Future<void> removeRomFolder(String folderPath) async {
    final db = await instance.database;
    await db.delete(
      'user_rom_folders',
      where: 'path = ?',
      whereArgs: [folderPath],
    );
  }

  /// Deletes all ROM records associated with a specific directory prefix.
  static Future<int> deleteRomsByFolderPath(String folderPath) async {
    final db = await instance.database;

    // Remove ROM entries where the path starts with the specified folder.
    // Handles both SAF URI separators (/) and Windows path separators (\).
    return await db.delete(
      'user_roms',
      where: 'rom_path LIKE ? OR rom_path LIKE ? OR rom_path = ?',
      whereArgs: ['$folderPath/%', '$folderPath\\%', folderPath],
    );
  }

  static Future<void> saveUserConfig({
    String? lastScan,
    String? gameViewMode,
    String? systemViewMode,
    String? paletteName,
    int? videoSound,
    String? raUser,
    int? showGameInfo,
    int? isFullscreen,
    int? bartopExitPoweroff,
    int? scanOnStartup,
    int? setupCompleted,
    int? hideBottomScreen,
    int? sfxEnabled,
    String? systemSortBy,
    String? systemSortOrder,
    String? appLanguage,
    String? activeTheme,
    int? hideRecentCard,
    String? activeSyncProvider,
    String? systemsVersion,
    String? neostationAppVersion,
    int? autoUpdateApp,
    int? autoUpdateSystems,
  }) async {
    final db = await instance.database;

    // First get existing config to not overwrite with nulls
    final currentConfig = await getUserConfig();
    final Map<String, dynamic> newConfig = currentConfig != null
        ? Map.from(currentConfig)
        : {};

    // Ensure ID
    newConfig['id'] = 1;

    // Update fields if provided
    if (lastScan != null) newConfig['last_scan'] = lastScan;
    if (gameViewMode != null) {
      newConfig['system_view_mode'] = gameViewMode; // Legacy mapping
      newConfig['game_view_mode'] = gameViewMode;
    }
    if (systemViewMode != null) newConfig['system_view_mode'] = systemViewMode;
    if (paletteName != null) newConfig['palette_name'] = paletteName;
    if (videoSound != null) newConfig['video_sound'] = videoSound;
    if (raUser != null) newConfig['ra_user'] = raUser;
    if (showGameInfo != null) newConfig['show_game_info'] = showGameInfo;
    if (isFullscreen != null) newConfig['is_fullscreen'] = isFullscreen;
    if (bartopExitPoweroff != null) {
      newConfig['bartop_exit_poweroff'] = bartopExitPoweroff;
    }
    if (scanOnStartup != null) {
      newConfig['scan_on_startup'] = scanOnStartup;
    }
    if (setupCompleted != null) {
      newConfig['setup_completed'] = setupCompleted;
    }
    if (hideBottomScreen != null) {
      newConfig['hide_bottom_screen'] = hideBottomScreen;
    }
    if (sfxEnabled != null) {
      newConfig['sfx_enabled'] = sfxEnabled;
    }
    if (systemSortBy != null) {
      newConfig['system_sort_by'] = systemSortBy;
    }
    if (systemSortOrder != null) {
      newConfig['system_sort_order'] = systemSortOrder;
    }
    if (appLanguage != null) {
      newConfig['app_language'] = appLanguage;
    }
    if (activeTheme != null) {
      newConfig['active_theme'] = activeTheme;
    }
    if (hideRecentCard != null) {
      newConfig['hide_recent_card'] = hideRecentCard;
    }
    if (activeSyncProvider != null) {
      newConfig['active_sync_provider'] = activeSyncProvider;
    }
    if (systemsVersion != null) {
      newConfig['systems_version'] = systemsVersion;
    }
    if (neostationAppVersion != null) {
      newConfig['neostation_app_version'] = neostationAppVersion;
    }
    if (autoUpdateApp != null) {
      newConfig['auto_update_app'] = autoUpdateApp;
    }
    if (autoUpdateSystems != null) {
      newConfig['auto_update_systems'] = autoUpdateSystems;
    }

    await db.insert(
      'user_config',
      newConfig,
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  /// Returns folder names of systems the user has hidden
  static Future<Set<String>> getHiddenSystems() async {
    final db = await instance.database;
    final results = await db.rawQuery(
      'SELECT actual_folder_name FROM user_detected_systems WHERE is_hidden = 1',
    );
    return results.map((r) => r['actual_folder_name'].toString()).toSet();
  }

  /// Sets a system's hidden state by its folder name
  static Future<void> setSystemHidden(String folderName, bool isHidden) async {
    final db = await instance.database;
    await db.rawUpdate(
      'UPDATE user_detected_systems SET is_hidden = ? WHERE actual_folder_name = ?',
      [isHidden ? 1 : 0, folderName],
    );
  }

  /// Retrieves the game view mode (grid/list).
  static Future<String> getGameViewMode() async {
    final config = await getUserConfig();
    return config?['game_view_mode']?.toString() ?? 'list';
  }

  /// Updates the game view mode.
  static Future<void> updateGameViewMode(String mode) async {
    await saveUserConfig(gameViewMode: mode);
  }

  /// Checks if recursive scan is enabled for a system.
  static Future<bool> getSystemRecursiveScan(String systemId) async {
    final db = await instance.database;
    final results = await db.query(
      'user_system_settings',
      where: 'app_system_id = ?',
      whereArgs: [systemId],
    );

    if (results.isEmpty) return false;
    // Check the 'recursive_scan' column value
    return (int.tryParse(results.first['recursive_scan']?.toString() ?? '1') ??
            1) ==
        1;
  }

  /// Sets whether recursive scan is enabled for a system.
  static Future<void> setSystemRecursiveScan(
    String systemId,
    bool enabled,
  ) async {
    await _updateSystemSetting(systemId, 'recursive_scan', enabled ? 1 : 0);
  }

  /// Sets whether to hide the file extension.
  static Future<void> setSystemHideExtension(
    String systemId,
    bool enabled,
  ) async {
    await _updateSystemSetting(systemId, 'hide_extension', enabled ? 1 : 0);
  }

  static Future<void> setSystemHideParentheses(
    String systemId,
    bool enabled,
  ) async {
    await _updateSystemSetting(systemId, 'hide_parentheses', enabled ? 1 : 0);
  }

  static Future<void> setSystemHideBrackets(
    String systemId,
    bool enabled,
  ) async {
    await _updateSystemSetting(systemId, 'hide_brackets', enabled ? 1 : 0);
  }

  static Future<void> setSystemHideLogo(String systemId, bool enabled) async {
    await _updateSystemSetting(systemId, 'hide_logo', enabled ? 1 : 0);
  }

  static Future<void> setSystemPreferFileName(
    String systemId,
    bool enabled,
  ) async {
    await _updateSystemSetting(systemId, 'prefer_file_name', enabled ? 1 : 0);
  }

  /// Retrieves the complete configuration for a system.
  static Future<Map<String, dynamic>> getSystemSettings(String systemId) async {
    final db = await instance.database;
    final results = await db.query(
      'user_system_settings',
      where: 'app_system_id = ?',
      whereArgs: [systemId],
      limit: 1,
    );

    if (results.isNotEmpty) {
      return results.first;
    }
    return {};
  }

  static Future<void> _updateSystemSetting(
    String systemId,
    String column,
    dynamic value,
  ) async {
    final db = await instance.database;
    await db.transaction((txn) async {
      // 1. Get existing record
      final existing = await txn.query(
        'user_system_settings',
        where: 'app_system_id = ?',
        whereArgs: [systemId],
        limit: 1,
      );

      final Map<String, dynamic> data = existing.isNotEmpty
          ? Map.from(existing.first)
          : {'app_system_id': systemId};

      data[column] = value;
      data['updated_at'] = DateTime.now().toIso8601String();

      await txn.insert(
        'user_system_settings',
        data,
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    });
  }

  /// Sets custom images for a system.
  static Future<void> setSystemCustomImages(
    String systemId, {
    String? backgroundPath,
    String? logoPath,
  }) async {
    final db = await instance.database;

    await db.transaction((txn) async {
      final existing = await txn.query(
        'user_system_settings',
        where: 'app_system_id = ?',
        whereArgs: [systemId],
        limit: 1,
      );

      final Map<String, dynamic> data = existing.isNotEmpty
          ? Map.from(existing.first)
          : {};

      data['app_system_id'] = systemId;
      data['updated_at'] = DateTime.now().toIso8601String();

      if (backgroundPath != null) {
        data['custom_background_path'] = backgroundPath;
      }
      if (logoPath != null) {
        data['custom_logo_path'] = logoPath;
      }

      await txn.insert(
        'user_system_settings',
        data,
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    });
  }

  /// Retrieves the system view mode.
  static Future<String> getSystemViewMode() async {
    final config = await getUserConfig();
    return config?['system_view_mode']?.toString() ?? 'grid';
  }

  /// Updates the system view mode.
  static Future<void> updateSystemViewMode(String mode) async {
    await saveUserConfig(systemViewMode: mode);
  }

  /// Updates the palette name.
  static Future<void> updatePaletteName(String paletteName) async {
    await saveUserConfig(paletteName: paletteName);
  }

  /// Retrieves the current palette name.
  static Future<String> getPaletteName() async {
    final config = await getUserConfig();
    return config?['palette_name']?.toString() ?? 'system';
  }

  /// Retrieves the active asset theme (neostation-assets).
  static Future<String> getActiveTheme() async {
    final config = await getUserConfig();
    return config?['active_theme']?.toString() ?? '';
  }

  /// Updates the active asset theme.
  static Future<void> updateActiveTheme(String themeFolder) async {
    await saveUserConfig(activeTheme: themeFolder);
  }

  /// Retrieves the locally stored systems manifest version.
  static Future<String> getSystemsVersion() async {
    final config = await getUserConfig();
    return config?['systems_version']?.toString() ?? '';
  }

  /// Persists the systems manifest version after a successful update.
  static Future<void> updateSystemsVersion(String version) async {
    await saveUserConfig(systemsVersion: version);
  }

  /// Retrieves the Neostation app version recorded at last startup.
  static Future<String> getNeostationAppVersion() async {
    final config = await getUserConfig();
    return config?['neostation_app_version']?.toString() ?? '';
  }

  /// Persists the current Neostation app version.
  static Future<void> updateNeostationAppVersion(String version) async {
    await saveUserConfig(neostationAppVersion: version);
  }

  /// Updates the video/sound configuration setting.
  static Future<void> updateVideoSound(int value) async {
    await saveUserConfig(videoSound: value);
  }

  /// Updates the RetroAchievements username.
  static Future<void> updateRAUser(String user) async {
    await saveUserConfig(raUser: user);
  }

  /// Updates the bartop power-off setting upon exit.
  static Future<void> updateBartopExitPoweroff(int value) async {
    await saveUserConfig(bartopExitPoweroff: value);
  }

  /// Configures whether the application should automatically scan for games on startup.
  static Future<void> updateScanOnStartup(int value) async {
    await saveUserConfig(scanOnStartup: value);
  }

  // ==========================================
  // SYSTEM DETECTION METHODS
  // ==========================================

  /// Retrieves all gaming systems detected on the current hardware or configured by the user.
  static Future<List<SystemModel>> getUserDetectedSystems() async {
    final db = await instance.database;

    final results = await db.rawQuery('''
      SELECT s.*, uds.actual_folder_name,
             (SELECT COUNT(*) FROM user_roms ur WHERE ur.app_system_id = s.id) as rom_count,
             ss.recursive_scan,
             ss.hide_extension,
             ss.hide_parentheses,
             ss.hide_brackets,
             ss.custom_background_path,
             ss.custom_logo_path,
             ss.hide_logo,
             ss.prefer_file_name
      FROM app_systems s
      LEFT JOIN user_detected_systems uds ON s.id = uds.app_system_id
      LEFT JOIN user_system_settings ss ON s.id = ss.app_system_id
      WHERE uds.app_system_id IS NOT NULL 
         OR (SELECT COUNT(*) FROM user_roms ur WHERE ur.app_system_id = s.id) > 0
      ORDER BY s.real_name ASC
    ''');

    return await _enrichSystemsWithFoldersAndExtensions(db, results);
  }

  /// Enriches raw system records with associated folder aliases and valid file extensions.
  static Future<List<SystemModel>> _enrichSystemsWithFoldersAndExtensions(
    DatabaseExecutorAdapter db,
    List<Map<String, Object?>> results,
  ) async {
    if (results.isEmpty) return [];

    // 1. Fetch all folder mappings in a single query to minimize IO overhead.
    final folderResults = await db.query('app_system_folders');
    final Map<String, List<String>> folderMap = {};
    for (final row in folderResults) {
      final sid = row['system_id'].toString();
      folderMap.putIfAbsent(sid, () => []).add(row['folder_name'].toString());
    }

    // 2. Fetch all extension mappings in a single query.
    final extensionResults = await db.query('app_system_extensions');
    final Map<String, List<String>> extensionMap = {};
    for (final row in extensionResults) {
      final sid = row['system_id'].toString();
      extensionMap.putIfAbsent(sid, () => []).add(row['extension'].toString());
    }

    // 3. Map records to SystemModel objects, injecting resolved metadata.
    return results.map((row) {
      final sid = row['id'].toString();
      final Map<String, dynamic> mutableRow = Map.from(row);

      mutableRow['folders'] = folderMap[sid] ?? [];
      mutableRow['extensions'] = extensionMap[sid] ?? [];

      // Parse cloud sync JSON configuration if available.
      final neosyncJson = row['neosync_json']?.toString();
      if (neosyncJson != null && neosyncJson.isNotEmpty) {
        try {
          mutableRow['neosync'] = json.decode(neosyncJson);
        } catch (e) {
          // Silent failure for malformed JSON.
        }
      }

      return SystemModel.fromJson(mutableRow);
    }).toList();
  }

  /// Registers a detected system folder.
  static Future<void> addDetectedSystem(
    String systemId,
    String actualFolderName,
  ) async {
    final db = await instance.database;
    await db.insert('user_detected_systems', {
      'app_system_id': systemId,
      'actual_folder_name': actualFolderName,
    }, conflictAlgorithm: ConflictAlgorithm.ignore);
  }

  /// Removes a system from the detected systems registry.
  static Future<void> removeDetectedSystem(String systemId) async {
    final db = await instance.database;
    await db.delete(
      'user_detected_systems',
      where: 'app_system_id = ?',
      whereArgs: [systemId],
    );
  }

  /// Synchronizes the list of detected systems based on a collection of physical folder names.
  static Future<void> updateDetectedSystems(List<String> folderNames) async {
    final db = await instance.database;

    await db.transaction((txn) async {
      // Preserve hidden states before wiping the table.
      final hiddenRows = await txn.query(
        'user_detected_systems',
        columns: ['actual_folder_name'],
        where: 'is_hidden = 1',
      );
      final hiddenFolders = hiddenRows
          .map((r) => r['actual_folder_name'] as String)
          .toSet();

      // Clear previous detections to avoid stale or duplicate entries.
      await txn.delete('user_detected_systems');

      for (final folder in folderNames) {
        // 1. Attempt primary folder name match (case-insensitive).
        var sys = await txn.query(
          'app_systems',
          columns: ['id'],
          where: 'folder_name = ? COLLATE NOCASE',
          whereArgs: [folder],
          limit: 1,
        );

        // 2. If not found, search within alternative folder aliases.
        if (sys.isEmpty) {
          sys = await txn.rawQuery(
            'SELECT system_id as id FROM app_system_folders WHERE folder_name = ? COLLATE NOCASE LIMIT 1',
            [folder],
          );
        }

        if (sys.isNotEmpty) {
          await txn.insert('user_detected_systems', {
            'app_system_id': sys.first['id'],
            'actual_folder_name': folder,
            'is_hidden': hiddenFolders.contains(folder) ? 1 : 0,
          }, conflictAlgorithm: ConflictAlgorithm.replace);
        }
      }
    });
  }

  /// Resolves a [SystemModel] based on its physical folder name.
  static Future<SystemModel> getSystemByFolderName(String folderName) async {
    // Attempt cache hit before hitting the database.
    final systems = _cachedSystems ?? await loadSystemsFromDb();

    try {
      SystemModel system = systems.firstWhere((s) {
        final lowerInput = folderName.toLowerCase();

        // Match primary folder name.
        if (s.folderName.toLowerCase() == lowerInput) return true;

        // Match alternative aliases.
        if (s.folders.any((f) => f.toLowerCase() == lowerInput)) return true;

        // Fallback for legacy normalization (stripping spaces).
        if (s.folderName.toLowerCase().replaceAll(' ', '') ==
            lowerInput.replaceAll(' ', '')) {
          return true;
        }

        return false;
      });

      // Synchronize exact ROM count from persistent storage.
      final romCount = await getRomCountForSystem(system.id!);
      system = system.copyWith(romCount: romCount);

      // Enrich with user-specific system overrides.
      final db = await instance.database;
      final settings = await db.query(
        'user_system_settings',
        columns: [
          'recursive_scan',
          'hide_extension',
          'hide_parentheses',
          'hide_brackets',
          'custom_background_path',
          'custom_logo_path',
          'hide_logo',
          'prefer_file_name',
        ],
        where: 'app_system_id = ?',
        whereArgs: [system.id],
      );

      if (settings.isNotEmpty) {
        final row = settings.first;
        return system.copyWith(
          recursiveScan:
              (int.tryParse(row['recursive_scan']?.toString() ?? '1') ?? 1) ==
              1,
          hideExtension:
              (int.tryParse(row['hide_extension']?.toString() ?? '1') ?? 1) ==
              1,
          hideParentheses:
              (int.tryParse(row['hide_parentheses']?.toString() ?? '1') ?? 1) ==
              1,
          hideBrackets:
              (int.tryParse(row['hide_brackets']?.toString() ?? '1') ?? 1) == 1,
          customBackgroundPath: row['custom_background_path']?.toString(),
          customLogoPath: row['custom_logo_path']?.toString(),
          hideLogo:
              (int.tryParse(row['hide_logo']?.toString() ?? '0') ?? 0) == 1,
          preferFileName:
              (int.tryParse(row['prefer_file_name']?.toString() ?? '0') ?? 0) ==
              1,
        );
      }

      return system;
    } catch (_) {
      throw Exception('System not found: $folderName');
    }
  }

  /// Calculates the total number of ROMs registered for a specific system.
  static Future<int> getRomCountForSystem(String systemId) async {
    final db = await instance.database;
    final results = await db.rawQuery(
      'SELECT COUNT(*) as count FROM user_roms WHERE app_system_id = ?',
      [systemId],
    );
    if (results.isEmpty) return 0;
    return int.tryParse(results.first['count']?.toString() ?? '0') ?? 0;
  }

  /// Retrieves all valid physical folder names (primary and aliases) for a system.
  static Future<List<String>> getAllFolderNamesForSystem(
    String systemId,
  ) async {
    final db = await instance.database;

    // Fetch primary folder name.
    final primary = await db.rawQuery(
      'SELECT folder_name FROM app_systems WHERE id = ?',
      [systemId],
    );

    // Fetch alternative alias names.
    final alternates = await db.rawQuery(
      'SELECT folder_name FROM app_system_folders WHERE system_id = ?',
      [systemId],
    );

    final names = <String>{};
    if (primary.isNotEmpty) {
      names.add(primary.first['folder_name'].toString());
    }
    for (final row in alternates) {
      names.add(row['folder_name'].toString());
    }

    return names.toList();
  }

  // ==========================================
  // EMULATOR DETECTION METHODS
  // ==========================================

  /// Retrieves a map of emulators detected on the host system, organized by their logical name.
  static Future<Map<String, EmulatorModel>> getUserDetectedEmulators() async {
    final db = await instance.database;

    // 1. Fetch standalone emulators explicitly configured by the user.
    final results = await db.rawQuery('''
      SELECT 
        e.name, 
        e.unique_identifier,
        e.is_standalone,
        uc.emulator_path,
        uc.created_at,
        uc.updated_at
      FROM user_emulator_config uc
      JOIN app_emulators e ON uc.emulator_unique_id = e.unique_identifier
      WHERE uc.emulator_path IS NOT NULL AND uc.emulator_path != ''
      ORDER BY uc.updated_at DESC
    ''');

    final emulators = <String, EmulatorModel>{};

    for (final row in results) {
      final name = row['name'].toString();
      final path = row['emulator_path'].toString();
      final uniqueIdentifier = row['unique_identifier']?.toString();

      if (!emulators.containsKey(name)) {
        emulators[name] = EmulatorModel(
          name: name,
          path: path,
          detected: true,
          lastDetection: row['updated_at'] != null
              ? DateTime.parse(row['updated_at'].toString())
              : DateTime.now(),
          uniqueId: uniqueIdentifier,
        );
      }
    }

    // 2. Fetch global RetroArch configuration (handles both standard and ra32 variants).
    final raResults = await db.rawQuery('''
      SELECT emulator_unique_id, emulator_path, updated_at 
      FROM user_emulator_config 
      WHERE emulator_unique_id IN ('ra', 'ra32') 
        AND emulator_path IS NOT NULL 
        AND emulator_path != ''
      ORDER BY updated_at DESC
      LIMIT 1
    ''');

    if (raResults.isNotEmpty) {
      final row = raResults.first;
      final path = row['emulator_path'].toString();
      final uniqueId = row['emulator_unique_id'].toString();

      // Consolidate under 'RetroArch' for standardized UI display.
      emulators['RetroArch'] = EmulatorModel(
        name: 'RetroArch',
        path: path,
        detected: true,
        lastDetection: row['updated_at'] != null
            ? DateTime.parse(row['updated_at'].toString())
            : DateTime.now(),
        uniqueId: uniqueId,
      );
    }

    return emulators;
  }

  /// Attempts a safe migration of an old database file to the new standardized location.
  Future<void> _attemptMigration(String newDbPath, File oldFile) async {
    if (await oldFile.exists()) {
      final file = File(newDbPath);

      // Perform migration only if the target file does not exist to prevent data loss.
      bool shouldMigrate = !await file.exists();

      if (shouldMigrate) {
        try {
          await file.parent.create(recursive: true);
          await oldFile.copy(newDbPath);

          // Clean up legacy file after successful migration.
          await oldFile.delete();
        } catch (e) {
          _log.e('Failed to migrate database to standardized path', error: e);
        }
      }
    }
  }

  /// Persists the executable path for a standalone emulator.
  static Future<void> saveDetectedEmulatorPath({
    required String emulatorName,
    required String emulatorPath,
  }) async {
    final db = await instance.database;
    final currentOs = getCurrentOs();

    await db.transaction((txn) async {
      // Specialized handling for RetroArch
      if (emulatorName == 'RetroArch') {
        const uniqueId = 'ra';

        await txn.insert('user_emulator_config', {
          'emulator_unique_id': uniqueId,
          'emulator_path': emulatorPath,
          'updated_at': DateTime.now().toIso8601String(),
        }, conflictAlgorithm: ConflictAlgorithm.replace);

        return;
      }

      // Logic for generic Standalone Emulators.
      // Retrieve the unique identifier based on name and current OS.
      final emulators = await txn.rawQuery(
        'SELECT unique_identifier FROM app_emulators WHERE name = ? AND os_id = (SELECT id FROM app_os WHERE name = ?)',
        [emulatorName, currentOs],
      );

      for (final row in emulators) {
        final uniqueId = row['unique_identifier']?.toString();
        if (uniqueId != null) {
          // Update existing configuration or insert a new one.
          final existing = await txn.query(
            'user_emulator_config',
            columns: ['emulator_unique_id'],
            where: 'emulator_unique_id = ?',
            whereArgs: [uniqueId],
          );

          if (existing.isNotEmpty) {
            await txn.update(
              'user_emulator_config',
              {
                'emulator_path': emulatorPath,
                'updated_at': DateTime.now().toIso8601String(),
              },
              where: 'emulator_unique_id = ?',
              whereArgs: [uniqueId],
            );
          } else {
            await txn.insert('user_emulator_config', {
              'emulator_unique_id': uniqueId,
              'emulator_path': emulatorPath,
              'is_user_default': 0,
              'created_at': DateTime.now().toIso8601String(),
              'updated_at': DateTime.now().toIso8601String(),
            });
          }
        }
      }
    });
  }

  /// Configures a standalone emulator path and sets it as the system default.
  static Future<void> setStandaloneEmulatorPath(
    String emulatorUniqueId,
    String path,
  ) async {
    final db = await instance.database;

    // 1. Resolve the associated system ID.
    final emuResult = await db.query(
      'app_emulators',
      columns: ['system_id'],
      where: 'unique_identifier = ?',
      whereArgs: [emulatorUniqueId],
      limit: 1,
    );

    String? systemId;
    if (emuResult.isNotEmpty) {
      systemId = emuResult.first['system_id']?.toString();
    }

    // 2. Persist path configuration.
    final existing = await db.query(
      'user_emulator_config',
      columns: ['emulator_unique_id'],
      where: 'emulator_unique_id = ?',
      whereArgs: [emulatorUniqueId],
    );

    if (existing.isNotEmpty) {
      await db.update(
        'user_emulator_config',
        {'emulator_path': path, 'updated_at': DateTime.now().toIso8601String()},
        where: 'emulator_unique_id = ?',
        whereArgs: [emulatorUniqueId],
      );
    } else {
      await db.insert('user_emulator_config', {
        'emulator_unique_id': emulatorUniqueId,
        'emulator_path': path,
        'is_user_default': 0,
        'created_at': DateTime.now().toIso8601String(),
        'updated_at': DateTime.now().toIso8601String(),
      });
    }

    // 3. Mark as default for the identified system.
    if (systemId != null) {
      await setDefaultStandaloneEmulator(systemId, emulatorUniqueId);
    }
  }

  // ==========================================
  // SYSTEM & EMULATOR QUERY METHODS
  // ==========================================

  /// Retrieves all available systems registered in the application.
  static Future<List<SystemModel>> getAllSystems() async {
    final db = await instance.database;

    // Fetch systems with comprehensive metadata and game statistics.
    final results = await db.rawQuery('''
      SELECT s.*,
             (SELECT COUNT(*) FROM user_roms ur WHERE ur.app_system_id = s.id) as rom_count,
             ss.recursive_scan,
             ss.custom_background_path,
             ss.custom_logo_path,
             ss.hide_logo,
             ss.hide_extension,
             ss.hide_parentheses,
             ss.hide_brackets,
             ss.prefer_file_name
      FROM app_systems s
      LEFT JOIN user_system_settings ss ON s.id = ss.app_system_id
      ORDER BY s.real_name ASC
    ''');

    return await _enrichSystemsWithFoldersAndExtensions(db, results);
  }

  /// Compatibility alias for [getAllSystems].
  static Future<List<SystemModel>> getAvailableSystems() async =>
      getAllSystems();

  /// Retrieves all emulator cores available for a specific system and operating system.
  static Future<List<CoreEmulatorModel>> getCoresBySystemId(
    String systemId,
  ) async {
    final db = await instance.database;
    final currentOs = getCurrentOs();

    // Ensure data corrections (like missing package names) have been applied.
    await _runDataCorrection();

    // Fetch non-standalone emulators (Libretro cores).
    final results = await db.rawQuery(
      '''
      SELECT e.*, os.name as os_name
      FROM app_emulators e
      JOIN app_os os ON e.os_id = os.id
      WHERE e.system_id = ? AND os.name = ? AND e.is_standalone = 0
      ORDER BY e.name ASC
      ''',
      [systemId, currentOs],
    );

    final processedResults = <Map<String, dynamic>>[];

    for (final row in results) {
      final newRow = Map<String, dynamic>.from(row);

      if (currentOs == 'android') {
        String? pkg = (row['android_package_name']?.toString() ?? '').trim();

        // Heuristic fallback for RetroArch variants on Android.
        if (pkg.isEmpty) {
          final uniqueId = row['unique_identifier']?.toString() ?? '';
          if (uniqueId.contains('.ra64.')) {
            pkg = 'com.retroarch.aarch64';
          } else if (uniqueId.contains('.ra32.')) {
            pkg = 'com.retroarch.ra32';
          } else if (uniqueId.contains('.ra.')) {
            pkg = 'com.retroarch';
          }
        }

        if (pkg.isNotEmpty) {
          bool isInstalled = await AndroidService.isPackageInstalled(pkg);
          newRow['is_installed'] = isInstalled ? 1 : 0;
        } else {
          newRow['is_installed'] = 0;
        }
      } else {
        newRow['is_installed'] = 1;
      }
      processedResults.add(newRow);
    }

    return processedResults
        .map((row) => CoreEmulatorModel.fromMap(row))
        .toList();
  }

  /// Corrects data inconsistencies in emulator records (e.g., missing package names).
  static Future<void> _runDataCorrection() async {
    final db = await instance.database;

    await db.transaction((txn) async {
      // Standardize 64-bit RetroArch package names.
      await txn.rawUpdate('''
        UPDATE app_emulators 
        SET android_package_name = 'com.retroarch.aarch64', is_standalone = 0
        WHERE os_id = 2 AND android_package_name IS NULL AND (unique_identifier LIKE '%.ra64.%' OR name LIKE '%RetroArch64%')
      ''');

      // Standardize 32-bit RetroArch package names.
      await txn.rawUpdate('''
        UPDATE app_emulators 
        SET android_package_name = 'com.retroarch.ra32', is_standalone = 0
        WHERE os_id = 2 AND android_package_name IS NULL AND (unique_identifier LIKE '%.ra32.%' OR name LIKE '%RetroArch32%')
      ''');

      // Standardize base RetroArch package names.
      await txn.rawUpdate('''
        UPDATE app_emulators 
        SET android_package_name = 'com.retroarch', is_standalone = 0
        WHERE os_id = 2 AND android_package_name IS NULL AND (unique_identifier LIKE '%.ra.%' OR (name LIKE '%RetroArch%' AND name NOT LIKE '%64%' AND name NOT LIKE '%32%'))
      ''');

      // Ensure all RetroArch variants are correctly flagged as cores.
      await txn.rawUpdate('''
        UPDATE app_emulators 
        SET is_standalone = 0
        WHERE os_id = 2 AND (unique_identifier LIKE '%.ra.%' OR name LIKE '%RetroArch%') AND is_standalone = 1
      ''');
    });
  }

  /// Sets the primary emulator core for a given system.
  static Future<void> setDefaultCore(
    String systemId,
    String uniqueIdentifier,
    int osId,
  ) async {
    final db = await instance.database;

    await db.transaction((txn) async {
      // Reset defaults for all cores within the target system and OS.
      await txn.rawUpdate(
        'UPDATE app_emulators SET is_default = 0 WHERE system_id = ? AND os_id = ? AND is_standalone = 0',
        [systemId, osId],
      );

      // Mutually exclusive: Disable standalone defaults when a core is selected.
      await txn.rawUpdate(
        'UPDATE user_emulator_config SET is_user_default = 0 '
        'WHERE emulator_unique_id IN (SELECT unique_identifier FROM app_emulators WHERE system_id = ? AND os_id = ? AND is_standalone = 1)',
        [systemId, osId],
      );

      // Assign the new default core.
      await txn.update(
        'app_emulators',
        {'is_default': 1},
        where: 'os_id = ? AND unique_identifier = ?',
        whereArgs: [osId, uniqueIdentifier],
      );
    });

    // Enforce disk persistence via WAL checkpoint.
    try {
      await db.execute('PRAGMA wal_checkpoint(FULL)');
    } catch (e) {
      _log.e(
        'Failed to finalize core default update via WAL checkpoint',
        error: e,
      );
    }
  }

  /// Retrieves standalone emulators compatible with a specific system.
  static Future<List<Map<String, dynamic>>> getStandaloneEmulatorsBySystemId(
    String systemId,
  ) async {
    final db = await instance.database;
    final currentOs = getCurrentOs();

    final results = await db.rawQuery(
      '''
      SELECT 
        e.*, 
        os.name as os_name, 
        uc.emulator_path, 
        uc.is_user_default
      FROM app_emulators e
      JOIN app_os os ON e.os_id = os.id
      LEFT JOIN user_emulator_config uc ON e.unique_identifier = uc.emulator_unique_id
      WHERE e.system_id = ? AND os.name = ? AND e.is_standalone = 1
      ORDER BY e.name ASC
      ''',
      [systemId, currentOs],
    );

    return results;
  }

  /// Assigns a standalone emulator as the default for a system, unsetting core defaults.
  static Future<void> setDefaultStandaloneEmulator(
    String systemId,
    String emulatorUniqueId,
  ) async {
    final db = await instance.database;

    final emulators = await getStandaloneEmulatorsBySystemId(systemId);

    await db.transaction((txn) async {
      // 1. Unset user defaults for all standalone emulators belonging to this system.
      for (final emu in emulators) {
        final uniqueId = emu['unique_identifier']?.toString();
        if (uniqueId != null) {
          await txn.rawUpdate(
            'UPDATE user_emulator_config SET is_user_default = 0 WHERE emulator_unique_id = ?',
            [uniqueId],
          );
        }
      }

      // 2. Unset core defaults for the system (exclusive relationship).
      final currentOs = getCurrentOs();
      await txn.rawUpdate(
        'UPDATE app_emulators SET is_default = 0 '
        'WHERE system_id = ? AND os_id = (SELECT id FROM app_os WHERE name = ?) AND is_standalone = 0',
        [systemId, currentOs],
      );

      // 3. Assign and persist the new standalone default.
      final existing = await txn.query(
        'user_emulator_config',
        columns: ['emulator_unique_id'],
        where: 'emulator_unique_id = ?',
        whereArgs: [emulatorUniqueId],
      );

      if (existing.isNotEmpty) {
        await txn.update(
          'user_emulator_config',
          {
            'is_user_default': 1,
            'updated_at': DateTime.now().toIso8601String(),
          },
          where: 'emulator_unique_id = ?',
          whereArgs: [emulatorUniqueId],
          conflictAlgorithm: ConflictAlgorithm.ignore,
        );
      } else {
        await txn.insert('user_emulator_config', {
          'emulator_unique_id': emulatorUniqueId,
          'emulator_path': '', // Path resolution is handled during launch.
          'is_user_default': 1,
          'created_at': DateTime.now().toIso8601String(),
          'updated_at': DateTime.now().toIso8601String(),
        });
      }
    });

    try {
      await db.execute('PRAGMA wal_checkpoint(FULL)');
    } catch (e) {
      _log.e('WAL checkpoint failed after standalone default update', error: e);
    }
  }

  /// Retrieves all emulators associated with a system across all platforms.
  static Future<List<CoreEmulatorModel>> getAllEmulatorsForSystem(
    String systemId,
  ) async {
    final db = await instance.database;
    final results = await db.rawQuery(
      '''
      SELECT e.*, os.name as os_name
      FROM app_emulators e
      JOIN app_os os ON e.os_id = os.id
      WHERE e.system_id = ?
      ORDER BY e.is_default DESC, e.name ASC
      ''',
      [systemId],
    );
    return results.map((row) => CoreEmulatorModel.fromMap(row)).toList();
  }

  /// Heuristic logic to fix inconsistencies in default emulator assignments.
  Future<void> _fixEmulatorDefaults(DatabaseExecutorAdapter db) async {
    try {
      final systems = await db.query(
        'app_systems',
        columns: ['id', 'folder_name'],
      );
      final currentOs = getCurrentOs();

      for (final system in systems) {
        final systemId = system['id'].toString();
        final folderName = system['folder_name'].toString();

        final cores = await db.rawQuery(
          'SELECT * FROM app_emulators WHERE system_id = ? AND is_standalone = 0 AND os_id = (SELECT id FROM app_os WHERE name = ?)',
          [systemId, currentOs],
        );
        final standalones = await db.rawQuery(
          '''
          SELECT e.*, uc.is_user_default 
          FROM app_emulators e 
          LEFT JOIN user_emulator_config uc ON e.unique_identifier = uc.emulator_unique_id 
          WHERE e.system_id = ? AND e.is_standalone = 1 AND e.os_id = (SELECT id FROM app_os WHERE name = ?)
          ''',
          [systemId, currentOs],
        );

        final coreDefault = cores.firstWhere(
          (c) => c['is_default'] == 1,
          orElse: () => {},
        );
        final standaloneDefault = standalones.firstWhere(
          (s) => s['is_user_default'] == 1,
          orElse: () => {},
        );

        bool hasCoreDefault = coreDefault.isNotEmpty;
        bool hasStandaloneDefault = standaloneDefault.isNotEmpty;

        // RULE: PS1/PSX systems should prioritize cores unless overridden.
        if (folderName == 'ps1' ||
            folderName == 'psx' ||
            folderName == 'sony-psx' ||
            folderName == 'playstation') {
          if (hasCoreDefault && hasStandaloneDefault) {
            await db.rawUpdate(
              'UPDATE user_emulator_config SET is_user_default = 0 '
              'WHERE emulator_unique_id IN (SELECT unique_identifier FROM app_emulators WHERE system_id = ? AND is_standalone = 1)',
              [systemId],
            );
          }
        }
        // GENERAL RULE: Prioritize user-selected standalone if both defaults are set.
        else if (hasCoreDefault && hasStandaloneDefault) {
          await db.rawUpdate(
            'UPDATE app_emulators SET is_default = 0 WHERE system_id = ? AND is_standalone = 0',
            [systemId],
          );
        }
        // FALLBACK: Assign the first available core if no default exists.
        else if (!hasCoreDefault && !hasStandaloneDefault) {
          if (cores.isNotEmpty) {
            await db.rawUpdate(
              'UPDATE app_emulators SET is_default = 1 WHERE unique_identifier = ? AND os_id = ?',
              [cores.first['unique_identifier'], cores.first['os_id']],
            );
          }
        }
      }
    } catch (e) {
      _log.e('Failed to normalize emulator defaults', error: e);
    }
  }

  /// Flags well-known standalone emulators as compatible with RetroAchievements.
  Future<void> _fixAchievementCompatibility(DatabaseExecutorAdapter db) async {
    try {
      final emuNames = [
        'PPSSPP Standalone',
        'NetherSX2 Standalone',
        'DuckStation Standalone',
        'PCSX2 Standalone',
      ];

      for (final name in emuNames) {
        await db.rawUpdate(
          'UPDATE app_emulators SET is_ra_compatible = 1 WHERE name = ?',
          [name],
        );
      }
    } catch (e) {
      _log.e('Failed to flag achievement-compatible emulators', error: e);
    }
  }

  /// Retrieves the effective default emulator for a system, respecting user overrides.
  static Future<CoreEmulatorModel?> getDefaultEmulatorForSystem(
    String systemId,
  ) async {
    final db = await instance.database;
    final currentOs = getCurrentOs();

    // 1. Check for user-selected standalone default.
    final userStandalone = await db.rawQuery(
      '''
      SELECT e.*, os.name as os_name, uc.emulator_path, uc.is_user_default
      FROM app_emulators e
      JOIN app_os os ON e.os_id = os.id
      JOIN user_emulator_config uc ON e.unique_identifier = uc.emulator_unique_id
      WHERE e.system_id = ? AND os.name = ? AND uc.is_user_default = 1
      LIMIT 1
      ''',
      [systemId, currentOs],
    );

    if (userStandalone.isNotEmpty) {
      return CoreEmulatorModel.fromMap(userStandalone.first);
    }

    // 2. Fallback to system-provided default (usually a core).
    final defaultEmu = await db.rawQuery(
      '''
      SELECT e.*, os.name as os_name
      FROM app_emulators e
      JOIN app_os os ON e.os_id = os.id
      WHERE e.system_id = ? AND os.name = ? AND e.is_default = 1
      LIMIT 1
      ''',
      [systemId, currentOs],
    );

    if (defaultEmu.isNotEmpty) {
      return CoreEmulatorModel.fromMap(defaultEmu.first);
    }

    // 3. Absolute fallback: pick any compatible emulator.
    final fallback = await db.rawQuery(
      '''
      SELECT e.*, os.name as os_name
      FROM app_emulators e
      JOIN app_os os ON e.os_id = os.id
      WHERE e.system_id = ? AND os.name = ?
      ORDER BY e.is_standalone ASC, e.name ASC
      LIMIT 1
      ''',
      [systemId, currentOs],
    );

    if (fallback.isNotEmpty) {
      return CoreEmulatorModel.fromMap(fallback.first);
    }

    return null;
  }

  /// Retrieves all games associated with a specific system.
  static Future<List<DatabaseGameModel>> getGamesBySystem(
    String systemId,
  ) async {
    final db = await instance.database;
    final results = await db.rawQuery(
      '''
      SELECT
        ur.filename, ur.rom_path, ur.is_favorite, ur.play_time, ur.last_played,
        ur.cloud_sync_enabled, ur.title_id, ur.title_name,
        ur.app_emulator_unique_id as emulator_name,
        s.id as system_id, s.real_name as system_real_name, s.folder_name as system_folder_name,
        s.short_name as system_short_name,
        COALESCE(usm.real_name, CASE WHEN s.folder_name IN ('android') THEN ur.title_name END, ur.filename) as game_display_name,
        usm.real_name as ss_real_name,
        COALESCE(usm.description_en, CASE WHEN s.folder_name IN ('android') THEN ur.description END) as description,
        usm.description_en, usm.description_es, usm.description_fr, usm.description_de, usm.description_it, usm.description_pt,
        usm.rating,
        COALESCE(usm.release_date, CASE WHEN s.folder_name IN ('android') THEN ur.year END) as year,
        COALESCE(usm.developer, CASE WHEN s.folder_name IN ('android') THEN ur.developer END) as developer,
        COALESCE(usm.publisher, CASE WHEN s.folder_name IN ('android') THEN ur.publisher END) as publisher,
        COALESCE(usm.genre, CASE WHEN s.folder_name IN ('android') THEN ur.genre END) as genre,
        COALESCE(usm.players, CASE WHEN s.folder_name IN ('android') THEN ur.players END) as players,
        usm.is_fully_scraped
      FROM user_roms ur
      JOIN app_systems s ON ur.app_system_id = s.id
      LEFT JOIN user_screenscraper_metadata usm ON ur.app_system_id = usm.app_system_id AND ur.filename = usm.filename
      WHERE ur.app_system_id = ?
      ORDER BY ur.is_favorite DESC, LOWER(game_display_name) ASC
''',
      [systemId],
    );

    return results.map((row) => DatabaseGameModel.fromJson(row)).toList();
  }

  /// Retrieves all games associated with a system folder name.
  static Future<List<DatabaseGameModel>> getRomsForSystem(
    String systemFolderName,
  ) async {
    final system = await getSystemByFolderName(systemFolderName);
    if (system.id == null) return [];
    return getGamesBySystem(system.id!);
  }

  /// Retrieves all games across all registered systems.
  static Future<List<DatabaseGameModel>> getAllGames() async {
    final db = await instance.database;
    final results = await db.rawQuery('''
      SELECT
        ur.filename, ur.rom_path, ur.is_favorite, ur.play_time, ur.last_played,
        ur.cloud_sync_enabled, ur.title_id, ur.title_name,
        ur.app_emulator_unique_id as emulator_name,
        s.id as system_id, s.real_name as system_real_name, s.folder_name as system_folder_name,
        s.short_name as system_short_name,
        COALESCE(usm.real_name, CASE WHEN s.folder_name IN ('android') THEN ur.title_name END, ur.filename) as game_display_name,
        usm.real_name as ss_real_name,
        COALESCE(usm.description_en, CASE WHEN s.folder_name IN ('android') THEN ur.description END) as description,
        usm.description_en, usm.description_es, usm.description_fr, usm.description_de, usm.description_it, usm.description_pt,
        usm.rating,
        COALESCE(usm.release_date, CASE WHEN s.folder_name IN ('android') THEN ur.year END) as year,
        COALESCE(usm.developer, CASE WHEN s.folder_name IN ('android') THEN ur.developer END) as developer,
        COALESCE(usm.publisher, CASE WHEN s.folder_name IN ('android') THEN ur.publisher END) as publisher,
        COALESCE(usm.genre, CASE WHEN s.folder_name IN ('android') THEN ur.genre END) as genre,
        COALESCE(usm.players, CASE WHEN s.folder_name IN ('android') THEN ur.players END) as players,
        usm.is_fully_scraped
      FROM user_roms ur
      JOIN app_systems s ON ur.app_system_id = s.id
      LEFT JOIN user_screenscraper_metadata usm ON ur.app_system_id = usm.app_system_id AND ur.filename = usm.filename
      ORDER BY ur.is_favorite DESC, LOWER(game_display_name) ASC
    ''');
    return results.map((row) => DatabaseGameModel.fromJson(row)).toList();
  }

  /// Retrieves only games marked as favorites across all registered systems.
  ///
  /// Excludes virtual/app systems that are not part of the standard ROM library.
  static Future<List<DatabaseGameModel>> getFavoriteGames() async {
    final db = await instance.database;
    final results = await db.rawQuery('''
      SELECT
        ur.filename, ur.rom_path, ur.is_favorite, ur.play_time, ur.last_played,
        ur.cloud_sync_enabled, ur.title_id, ur.title_name,
        ur.app_emulator_unique_id as emulator_name,
        s.id as system_id, s.real_name as system_real_name, s.folder_name as system_folder_name,
        s.short_name as system_short_name,
        COALESCE(usm.real_name, CASE WHEN s.folder_name IN ('android') THEN ur.title_name END, ur.filename) as game_display_name,
        usm.real_name as ss_real_name,
        COALESCE(usm.description_en, CASE WHEN s.folder_name IN ('android') THEN ur.description END) as description,
        usm.description_en, usm.description_es, usm.description_fr, usm.description_de, usm.description_it, usm.description_pt,
        usm.rating,
        COALESCE(usm.release_date, CASE WHEN s.folder_name IN ('android') THEN ur.year END) as year,
        COALESCE(usm.developer, CASE WHEN s.folder_name IN ('android') THEN ur.developer END) as developer,
        COALESCE(usm.publisher, CASE WHEN s.folder_name IN ('android') THEN ur.publisher END) as publisher,
        COALESCE(usm.genre, CASE WHEN s.folder_name IN ('android') THEN ur.genre END) as genre,
        COALESCE(usm.players, CASE WHEN s.folder_name IN ('android') THEN ur.players END) as players,
        usm.is_fully_scraped
      FROM user_roms ur
      JOIN app_systems s ON ur.app_system_id = s.id
      LEFT JOIN user_screenscraper_metadata usm ON ur.app_system_id = usm.app_system_id AND ur.filename = usm.filename
      WHERE ur.is_favorite = 1
        AND s.folder_name NOT IN ('android', 'music')
      ORDER BY ur.is_favorite DESC, LOWER(game_display_name) ASC
    ''');
    return results.map((row) => DatabaseGameModel.fromJson(row)).toList();
  }

  /// Retrieves a single game record based on its system and filename.
  static Future<DatabaseGameModel?> getSingleGame(
    String systemId,
    String filename,
  ) async {
    final db = await instance.database;
    final results = await db.rawQuery(
      '''
      SELECT
        ur.filename, ur.rom_path, ur.is_favorite, ur.play_time, ur.last_played,
        ur.cloud_sync_enabled, ur.title_id, ur.title_name,
        ur.app_emulator_unique_id as emulator_name,
        s.id as system_id, s.real_name as system_real_name, s.folder_name as system_folder_name,
        s.short_name as system_short_name,
        COALESCE(usm.real_name, CASE WHEN s.folder_name IN ('android') THEN ur.title_name END, ur.filename) as game_display_name,
        usm.real_name as ss_real_name,
        COALESCE(usm.description_en, CASE WHEN s.folder_name IN ('android') THEN ur.description END) as description,
        usm.description_en, usm.description_es, usm.description_fr, usm.description_de, usm.description_it, usm.description_pt,
        usm.rating,
        COALESCE(usm.release_date, CASE WHEN s.folder_name IN ('android') THEN ur.year END) as year,
        COALESCE(usm.developer, CASE WHEN s.folder_name IN ('android') THEN ur.developer END) as developer,
        COALESCE(usm.publisher, CASE WHEN s.folder_name IN ('android') THEN ur.publisher END) as publisher,
        COALESCE(usm.genre, CASE WHEN s.folder_name IN ('android') THEN ur.genre END) as genre,
        COALESCE(usm.players, CASE WHEN s.folder_name IN ('android') THEN ur.players END) as players,
        usm.is_fully_scraped
      FROM user_roms ur
      JOIN app_systems s ON ur.app_system_id = s.id
      LEFT JOIN user_screenscraper_metadata usm ON ur.app_system_id = usm.app_system_id AND ur.filename = usm.filename
      WHERE ur.app_system_id = ? AND ur.filename = ?
      LIMIT 1
      ''',
      [systemId, filename],
    );

    if (results.isNotEmpty) {
      return DatabaseGameModel.fromJson(results.first);
    }
    return null;
  }

  /// Updates the last played timestamp for a specific game.
  static Future<void> recordRomPlayed(String romPath) async {
    final db = await instance.database;
    final now = DateTime.now().toIso8601String();
    await db.update(
      'user_roms',
      {'last_played': now},
      where: 'rom_path = ?',
      whereArgs: [romPath],
    );
  }

  /// Increments the accumulated play time for a specific game.
  static Future<void> updatePlayTime(String romPath, int seconds) async {
    final db = await instance.database;
    var current = await db.query(
      'user_roms',
      columns: ['play_time'],
      where: 'rom_path = ?',
      whereArgs: [romPath],
    );
    if (current.isNotEmpty) {
      final newSeconds =
          (int.tryParse(current.first['play_time']?.toString() ?? '0') ?? 0) +
          seconds;
      await db.update(
        'user_roms',
        {
          'play_time': newSeconds,
          'last_played': DateTime.now().toIso8601String(),
        },
        where: 'rom_path = ?',
        whereArgs: [romPath],
      );
    }
  }

  /// Toggles the favorite status for a given game path.
  static Future<void> toggleRomFavorite(String romPath) async {
    final db = await instance.database;
    final current = await db.query(
      'user_roms',
      columns: ['is_favorite'],
      where: 'rom_path = ?',
      whereArgs: [romPath],
    );
    if (current.isNotEmpty) {
      final newVal =
          (int.tryParse(current.first['is_favorite']?.toString() ?? '0') ??
                  0) ==
              1
          ? 0
          : 1;
      await db.update(
        'user_roms',
        {'is_favorite': newVal},
        where: 'rom_path = ?',
        whereArgs: [romPath],
      );
    }
  }

  /// Determines if cloud synchronization is enabled for a specific game.
  static Future<bool> isRomCloudSyncEnabled(
    String systemFolderName,
    String filename,
  ) async {
    final system = await getSystemByFolderName(systemFolderName);
    final db = await instance.database;
    final results = await db.query(
      'user_roms',
      columns: ['cloud_sync_enabled'],
      where: 'app_system_id = ? AND filename = ?',
      whereArgs: [system.id, filename],
    );
    return results.isNotEmpty &&
        (int.tryParse(results.first['cloud_sync_enabled']?.toString() ?? '1') ??
                1) ==
            1;
  }

  /// Updates the cloud synchronization toggle for a specific game.
  static Future<void> updateRomCloudSyncEnabled(
    String systemFolderName,
    String filename,
    bool enabled,
  ) async {
    final db = await instance.database;
    final system = await getSystemByFolderName(systemFolderName);
    await db.update(
      'user_roms',
      {'cloud_sync_enabled': enabled ? 1 : 0},
      where: 'app_system_id = ? AND filename = ?',
      whereArgs: [system.id, filename],
    );
  }

  /// Resets a game's play statistics (time and last played) to zero.
  static Future<void> resetRomPlayTime(
    String systemFolderName,
    String filename,
  ) async {
    final db = await instance.database;
    final system = await getSystemByFolderName(systemFolderName);
    await db.update(
      'user_roms',
      {'play_time': 0, 'last_played': null},
      where: 'app_system_id = ? AND filename = ?',
      whereArgs: [system.id, filename],
    );
  }

  /// Overrides the emulator used for a specific game.
  static Future<void> setRomEmulatorOverride(
    String systemFolderName,
    String filename,
    String? emulatorUniqueId,
    int? emulatorOsId,
  ) async {
    final db = await instance.database;
    final system = await getSystemByFolderName(systemFolderName);
    await db.update(
      'user_roms',
      {
        'app_emulator_unique_id': emulatorUniqueId,
        'app_emulator_os_id': emulatorOsId,
      },
      where: 'app_system_id = ? AND filename = ?',
      whereArgs: [system.id, filename],
    );
  }

  /// Retrieves all emulators available for a system on the current operating system.
  static Future<List<CoreEmulatorModel>> getEmulatorsForSystemCurrentOs(
    String systemId,
  ) async {
    final db = await instance.database;
    final currentOs = getCurrentOs();
    final results = await db.rawQuery(
      '''
      SELECT e.*, os.name as os_name,
        CASE
          WHEN uc.emulator_path IS NOT NULL AND uc.emulator_path != '' THEN 1
          ELSE 0
        END as is_installed
      FROM app_emulators e
      JOIN app_os os ON e.os_id = os.id
      LEFT JOIN user_emulator_config uc ON uc.emulator_unique_id = e.unique_identifier
      WHERE e.system_id = ? AND os.name = ?
      ORDER BY e.is_default DESC, e.is_standalone ASC, e.name ASC
      ''',
      [systemId, currentOs],
    );
    return results.map((row) => CoreEmulatorModel.fromMap(row)).toList();
  }

  /// Registers a new game entry or updates an existing one with detailed metadata.
  static Future<void> saveRom({
    required String systemFolderName,
    required String filename,
    required String romPath,
    String? raHash,
    String? ssHash,
    int? raId,
    String? titleId,
    String? titleName,
    String? emulatorName,
    String? coreName,
    bool isFavorite = false,
    DateTime? lastPlayed,
    int playTime = 0,
  }) async {
    final db = await instance.database;
    final system = await getSystemByFolderName(systemFolderName);
    final defaultEmu = await getDefaultEmulatorForSystem(system.id!);

    await db.insert('user_roms', {
      'app_system_id': system.id,
      'app_emulator_unique_id': defaultEmu?.uniqueId,
      'app_emulator_os_id': defaultEmu?.osId,
      'filename': filename,
      'rom_path': romPath,
      'ra_hash': raHash,
      'ss_hash': ssHash,
      'id_ra': raId,
      'title_id': titleId,
      'title_name': titleName,
      'is_favorite': isFavorite ? 1 : 0,
      'last_played': lastPlayed?.toIso8601String(),
      'play_time': playTime,
      'created_at': DateTime.now().toIso8601String(),
      'updated_at': DateTime.now().toIso8601String(),
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  /// Retrieves the preferred language configured for game scraping operations.
  static Future<String> getScraperPreferredLanguage() async {
    try {
      final db = await instance.database;
      final results = await db.query(
        'user_screenscraper_credentials',
        columns: ['preferred_language'],
        where: 'id = 1',
      );

      if (results.isNotEmpty) {
        return results.first['preferred_language']?.toString() ?? 'en';
      }
    } catch (e) {
      _log.d('Failed to retrieve preferred language from database, error: $e');
    }
    return 'en'; // Global fallback
  }

  /// Resolves the localized description of a game based on user language preferences.
  static Future<String> getLocalizedGameDescription(
    String romName,
    String systemId,
  ) async {
    final game = await getSingleGame(systemId, romName);
    if (game == null) return '';

    final lang = await getScraperPreferredLanguage();
    return game.getDescriptionForLanguage(lang);
  }

  /// Retrieves the set of valid file extensions for a specific system.
  static Future<Set<String>> getExtensionsForSystem(String systemId) async {
    final db = await instance.database;
    final results = await db.query(
      'app_system_extensions',
      where: 'system_id = ?',
      whereArgs: [systemId],
    );
    return results
        .map((row) => (row['extension'].toString()).toLowerCase())
        .toSet();
  }

  /// Generates a mapping of system folder names to their supported file extensions.
  static Future<Map<String, Set<String>>> getSystemExtensionsMap() async {
    final db = await instance.database;
    final results = await db.rawQuery('''
      SELECT s.folder_name, e.extension
      FROM app_systems s
      JOIN app_system_extensions e ON s.id = e.system_id
    ''');
    final Map<String, Set<String>> extensionMap = {};
    for (final row in results) {
      final folderName = row['folder_name'].toString();
      extensionMap
          .putIfAbsent(folderName, () => {})
          .add((row['extension'].toString()).toLowerCase());
    }
    return extensionMap;
  }

  /// Retrieves all valid file extensions supported by any system in the database.
  static Future<Set<String>> getAllValidExtensions() async {
    final db = await instance.database;
    final results = await db.query('app_system_extensions');
    return results
        .map((row) => (row['extension'].toString()).toLowerCase())
        .toSet();
  }

  // ==========================================
  // NeoSync STATE TRACKING
  // ==========================================

  /// Persists local synchronization state for a file.
  ///
  /// This is used to track modifications and versioning for cloud sync, bypassing
  /// filesystem limitations on Android (e.g., restricted 'lastModified' modification).
  static Future<void> saveSyncState(
    String filePath,
    int localModifiedAt,
    int cloudUpdatedAt,
    int fileSize, {
    String? fileHash,
  }) async {
    try {
      final db = await instance.database;
      await db.insert('app_neo_sync_state', {
        'file_path': filePath,
        'local_modified_at': localModifiedAt,
        'cloud_updated_at': cloudUpdatedAt,
        'file_size': fileSize,
        'file_hash': fileHash,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
    } catch (e) {
      _log.e('Failed to save cloud synchronization state', error: e);
    }
  }

  /// Retrieves the recorded synchronization state for a specific file path.
  static Future<Map<String, dynamic>?> getSyncState(String filePath) async {
    try {
      final db = await instance.database;
      final results = await db.query(
        'app_neo_sync_state',
        where: 'file_path = ?',
        whereArgs: [filePath],
        limit: 1,
      );
      if (results.isNotEmpty) {
        return results.first;
      }
    } catch (e) {
      _log.e('Failed to retrieve cloud synchronization state', error: e);
    }
    return null;
  }

  /// Deletes all user-specific data, including configurations, ROM metadata, and scraper credentials.
  static Future<void> clearUserData() async {
    final db = await instance.database;
    await db.transaction((txn) async {
      await txn.delete('user_config');
      await txn.delete('user_roms');
      await txn.delete('user_emulator_config');
      await txn.delete('user_screenscraper_credentials');
      await txn.delete('user_screenscraper_metadata');
      await txn.delete('user_detected_systems');
      await txn.delete('user_retroarch_cores');
      await txn.delete('user_retroarch_paths');
    });
  }

  /// Retrieves a map of all emulators available in the database schema.
  static Future<Map<String, EmulatorModel>> getAvailableEmulators() async {
    final db = await instance.database;
    final results = await db.rawQuery('''
      SELECT DISTINCT e.unique_identifier, e.name, e.android_package_name, os.name as os_name
      FROM app_emulators e
      JOIN app_os os ON e.os_id = os.id
    ''');
    final emulators = <String, EmulatorModel>{};
    for (final row in results) {
      final name = row['name'].toString();
      emulators.putIfAbsent(
        name,
        () => EmulatorModel(
          name: name,
          path: '',
          detected: false,
          possiblePaths: {},
        ),
      );
    }
    return emulators;
  }

  /// Retrieves the RetroAchievements hash associated with a specific ROM.
  static Future<String?> getRomRaHash(String romPath) async {
    final db = await instance.database;
    final results = await db.query(
      'user_roms',
      columns: ['ra_hash'],
      where: 'rom_path = ?',
      whereArgs: [romPath],
      limit: 1,
    );
    if (results.isNotEmpty) {
      return results.first['ra_hash']?.toString();
    }
    return null;
  }

  /// Updates the RetroAchievements hash for a registered game.
  static Future<void> updateRomRaHash(String romPath, String hash) async {
    final db = await instance.database;
    await db.update(
      'user_roms',
      {'ra_hash': hash},
      where: 'rom_path = ?',
      whereArgs: [romPath],
    );
  }

  /// Resolves the RetroAchievements game ID based on its hash and console ID.
  static Future<int?> getRetroAchievementsGameIdByHash(
    String raHash,
    String raConsoleId,
  ) async {
    final db = await instance.database;
    final results = await db.rawQuery(
      'SELECT game_id FROM app_ra_game_list WHERE hash COLLATE NOCASE = ? AND console_id = ? LIMIT 1',
      [raHash, raConsoleId],
    );
    if (results.isNotEmpty) {
      return int.tryParse(results.first['game_id']?.toString() ?? '');
    }
    return null;
  }

  /// Retrieves high-level statistics about the local library (total games and systems).
  static Future<Map<String, dynamic>> getStats() async {
    final db = await instance.database;
    final totalGames = (await db.rawQuery(
      'SELECT COUNT(*) as count FROM user_roms',
    ));
    final totalGamesCount =
        int.tryParse(totalGames.first['count']?.toString() ?? '0') ?? 0;
    final systems = (await db.rawQuery(
      'SELECT COUNT(*) as count FROM user_detected_systems',
    )).first['count'];

    return {'totalGames': totalGamesCount, 'systems': systems};
  }

  /// Identifies the current host operating system as a standardized string.
  static String getCurrentOs() {
    if (Platform.isWindows) return 'windows';
    if (Platform.isLinux) return 'linux';
    if (Platform.isMacOS) return 'macos';
    if (Platform.isAndroid) return 'android';
    if (Platform.isIOS) return 'ios';
    return 'unknown';
  }

  /// Retrieves package names for all RetroArch variants available on Android.
  static Future<List<String>> getAndroidRetroArchPackages() async {
    final db = await instance.database;

    final results = await db.rawQuery('''
      SELECT DISTINCT android_package_name 
      FROM app_emulators 
      WHERE os_id = (SELECT id FROM app_os WHERE name = 'android') 
        AND (android_package_name LIKE 'com.retroarch%')
        AND android_package_name IS NOT NULL
      ''');

    return results
        .map((row) => row['android_package_name'].toString())
        .toList();
  }

  /// Retrieves a list of emulators for a system (legacy alias for [getCoresBySystemId]).
  static Future<List<Map<String, dynamic>>> getEmulatorsForSystem(
    String systemId,
  ) async {
    final cores = await getCoresBySystemId(systemId);
    return cores.map((e) => e.toMap()).toList();
  }

  /// Refreshes the local RetroAchievements game database from bundled SQL assets.
  Future<void> refreshRetroAchievementsData() async {
    try {
      final db = await database;
      await db.transaction((txn) async {
        _log.i('Refreshing local RetroAchievements game database...');

        // Purge existing data to ensure a clean sync.
        await txn.execute('DELETE FROM app_ra_game_list');

        // Batch insert data from the SQL seed file.
        await _executeSqlFileOptimized(
          txn,
          'assets/data/ra_insert.sql',
          'ra_insert',
        );
      });
      _log.i('RetroAchievements database synchronized successfully.');
    } catch (e, stackTrace) {
      _log.e(
        'Failed to refresh RetroAchievements data',
        error: e,
        stackTrace: stackTrace,
      );
      // Non-critical: allow initialization to proceed even if this sync fails.
    }
  }
}
