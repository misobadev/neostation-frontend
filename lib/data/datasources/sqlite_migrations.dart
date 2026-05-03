import 'dart:async';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as path;
import 'package:sqlite3/sqlite3.dart';
import 'package:neostation/services/logger_service.dart';

/// Service responsible for managing SQLite database schema evolutions.
///
/// This system implements an incremental migration strategy where each version
/// represents a specific state of the database schema. Migrations are designed
/// to be idempotent, allowing them to be safely re-run if necessary.
class SqliteMigrations {
  static final _log = LoggerService.instance;

  /// Routes a specific version upgrade request to its corresponding migration logic.
  ///
  /// [db] is the active SQLite database connection.
  /// [version] is the target schema version to reach.
  static Future<void> migrateToVersion(Database db, int version) async {
    _log.i('Executing migration to version $version');

    switch (version) {
      case 5:
        await _migrateToVersion5(db);
        break;
      case 6:
        await _migrateToVersion6(db);
        break;
      case 7:
        await _migrateToVersion7(db);
        break;
      case 8:
        await _migrateToVersion8(db);
        break;
      case 9:
        await _migrateToVersion9(db);
        break;
      case 10:
        await _migrateToVersion10(db);
        break;
      case 11:
        await _migrateToVersion11(db);
        break;
      case 12:
        await _migrateToVersion12(db);
        break;
      case 13:
        await _migrateToVersion13(db);
        break;
      case 14:
        await _migrateToVersion14(db);
        break;
      case 15:
        await _migrateToVersion15(db);
        break;
      case 16:
        await _migrateToVersion16(db);
        break;
      case 17:
        await _migrateToVersion17(db);
        break;
      case 18:
        await _migrateToVersion18(db);
        break;
      case 19:
        await _migrateToVersion19(db);
        break;
      case 20:
        await _migrateToVersion20(db);
        break;
      case 21:
        await _migrateToVersion21(db);
        break;
      case 22:
        await _migrateToVersion22(db);
        break;
      case 23:
        await _migrateToVersion23(db);
        break;
      case 24:
        await _migrateToVersion24(db);
        break;
      case 25:
        await _migrateToVersion25(db);
        break;
      case 26:
        await _migrateToVersion26(db);
        break;
      case 27:
        await _migrateToVersion27(db);
        break;
      case 28:
        await _migrateToVersion28(db);
        break;

      case 29:
        await _migrateToVersion29(db);
        break;
      case 30:
        await _migrateToVersion30(db);
        break;
      case 31:
        await _migrateToVersion31(db);
        break;
      case 32:
        await _migrateToVersion32(db);
        break;
      case 33:
        await _migrateToVersion33(db);
        break;
      case 34:
        await _migrateToVersion34(db);
        break;
      case 35:
        await _migrateToVersion35(db);
        break;
      case 36:
        await _migrateToVersion36(db);
        break;
      case 37:
        await _migrateToVersion37(db);
        break;
      case 38:
        await _migrateToVersion38(db);
        break;
      case 39:
        await _migrateToVersion39(db);
        break;
      case 40:
        await _migrateToVersion40(db);
        break;
      case 41:
        await _migrateToVersion41(db);
        break;
      case 42:
        await _migrateToVersion42(db);
        break;
      case 43:
        await _migrateToVersion43(db);
        break;
      case 44:
        await _migrateToVersion44(db);
        break;
      case 45:
        await _migrateToVersion45(db);
        break;
      case 46:
        await _migrateToVersion46(db);
        break;
      case 47:
        await _migrateToVersion47(db);
        break;
      case 48:
        await _migrateToVersion48(db);
        break;
      case 49:
        await _migrateToVersion49(db);
        break;
      case 50:
        await _migrateToVersion50(db);
        break;
      case 51:
        await _migrateToVersion50(db); // Same as v50, just forcing re-run
        break;
      case 52:
        await _migrateToVersion52(db);
        break;
      case 53:
        await _migrateToVersion53(db);
        break;
      case 54:
        await _migrateToVersion54(db);
        break;
      case 55:
        await _migrateToVersion55(db);
        break;
      case 56:
        await _migrateToVersion56(db);
        break;
      case 57:
        await _migrateToVersion57(db);
        break;
      case 58:
        await _migrateToVersion58(db);
        break;
      case 59:
        await _migrateToVersion59(db);
        break;
      case 61:
        await _migrateToVersion61(db);
        break;
      case 62:
        await _migrateToVersion62(db);
        break;
      case 63:
        await _migrateToVersion63(db);
        break;
      case 64:
        await _migrateToVersion64(db);
        break;
      case 65:
        await _migrateToVersion65(db);
        break;
      case 66:
        await _migrateToVersion66(db);
        break;
      case 67:
        await _migrateToVersion67(db);
        break;
      case 68:
        await _migrateToVersion68(db);
        break;
      case 69:
        await _migrateToVersion69(db);
        break;
      case 70:
        await _migrateToVersion70(db);
        break;
      case 71:
        await _migrateToVersion71(db);
        break;
      case 72:
        await _migrateToVersion72(db);
        break;
      case 73:
        await _migrateToVersion73(db);
        break;
      case 74:
        await _migrateToVersion74(db);
        break;
      case 75:
        await _migrateToVersion75(db);
        break;
      case 76:
        await _migrateToVersion76(db);
        break;
      case 77:
        await _migrateToVersion77(db);
      case 78:
        await _migrateToVersion78(db);
        break;
      default:
        _log.w('No migration defined for version $version');
    }
  }

  /// Migration v26: Extends the [user_roms] table with additional metadata fields
  /// (description, year, developer, etc.) to support enhanced game information display.
  static Future<void> _migrateToVersion26(Database db) async {
    _log.i('Migration v26: Adding metadata columns to user_roms');

    try {
      final tableInfo = db.select('PRAGMA table_info(user_roms)');
      final columns = tableInfo.map((c) => c['name'].toString()).toList();

      if (!columns.contains('description')) {
        db.execute('ALTER TABLE user_roms ADD COLUMN description TEXT');
        _log.i('Column description added');
      }
      if (!columns.contains('year')) {
        db.execute('ALTER TABLE user_roms ADD COLUMN year TEXT');
        _log.i('Column year added');
      }
      if (!columns.contains('developer')) {
        db.execute('ALTER TABLE user_roms ADD COLUMN developer TEXT');
        _log.i('Column developer added');
      }
      if (!columns.contains('publisher')) {
        db.execute('ALTER TABLE user_roms ADD COLUMN publisher TEXT');
        _log.i('Column publisher added');
      }
      if (!columns.contains('genre')) {
        db.execute('ALTER TABLE user_roms ADD COLUMN genre TEXT');
        _log.i('Column genre added');
      }
      if (!columns.contains('players')) {
        db.execute('ALTER TABLE user_roms ADD COLUMN players TEXT');
        _log.i('Column players added');
      }

      _log.i('Migration v26 completed');
    } catch (e, stackTrace) {
      _log.e('Error in migration v26: $e');
      _log.e('   StackTrace: $stackTrace');
      rethrow;
    }
  }

  /// Migration v27: Updates the ScreenScraper platform ID for Android to ensure
  /// correct metadata mapping from the scraping API.
  static Future<void> _migrateToVersion27(Database db) async {
    _log.i('Migration v27: Updating Android ScreenScraper ID to 63');

    try {
      db.execute(
        "UPDATE app_systems SET screenscraper_id = 63, ra_id = 0 WHERE folder_name = 'android'",
      );
      _log.i('Android  ScreenScraper ID updated to 63');
    } catch (e, stackTrace) {
      _log.e('Error in migration v27: $e');
      _log.e('   StackTrace: $stackTrace');
      rethrow;
    }
  }

  /// Migration v24: Normalizes the `video_sound` configuration from a legacy string
  /// format ('on'/'off') to a standardized integer boolean (1/0).
  static Future<void> _migrateToVersion24(Database db) async {
    _log.i('Migration v24: Refactoring video_sound to INTEGER');

    try {
      // 1. Rename old table
      db.execute('ALTER TABLE user_config RENAME TO user_config_old');

      // 2. Create new table with INTEGER for video_sound
      db.execute('''
        CREATE TABLE user_config (
          id INTEGER PRIMARY KEY CHECK (id = 1),
          rom_folder TEXT,
          last_scan TEXT,
          game_view_mode TEXT DEFAULT 'list',
          system_view_mode TEXT DEFAULT 'grid',
          theme_name TEXT DEFAULT 'system',
          video_sound INTEGER DEFAULT 1,
          ra_user TEXT,
          show_game_info INTEGER DEFAULT 0,
          is_fullscreen INTEGER DEFAULT 1
        )
      ''');

      // 3. Migrate data, converting 'on' to 1 and 'off' to 0
      db.execute('''
        INSERT INTO user_config (
          id, rom_folder, last_scan, game_view_mode, system_view_mode, 
          theme_name, video_sound, ra_user, show_game_info, is_fullscreen
        )
        SELECT 
          id, rom_folder, last_scan, game_view_mode, system_view_mode, 
          theme_name, 
          CASE WHEN video_sound = 'off' THEN 0 ELSE 1 END,
          ra_user, show_game_info, is_fullscreen
        FROM user_config_old
      ''');

      // 4. Drop old table
      db.execute('DROP TABLE user_config_old');

      _log.i('Migration v24 completed: video_sound is now INTEGER');
    } catch (e, stackTrace) {
      _log.e('Error in migration v24: $e');
      _log.e('   StackTrace: $stackTrace');
      rethrow;
    }
  }

  /// Migration v47: Adds the `setup_completed` flag to [user_config] to track
  /// if the first-time setup wizard has been successfully finalized.
  static Future<void> _migrateToVersion47(Database db) async {
    _log.i('Migration v47: Adding setup_completed to user_config');

    try {
      final hasColumn = await _columnExists(
        db,
        'user_config',
        'setup_completed',
      );

      if (!hasColumn) {
        db.execute('''
          ALTER TABLE user_config 
          ADD COLUMN setup_completed INTEGER DEFAULT 0
        ''');
        _log.i('Column setup_completed added to user_config');
      } else {
        _log.i('Column setup_completed already exists');
      }
    } catch (e, stackTrace) {
      _log.e('Error in migration v47: $e');
      _log.e('   StackTrace: $stackTrace');
    }
  }

  /// Migration v25: Registers the native Android application system into the
  /// systems catalog, enabling Android apps to be managed alongside ROMs.
  static Future<void> _migrateToVersion25(Database db) async {
    _log.i('Migration v25: Adding Android Apps and Games systems');

    try {
      // 1. Insert "Android" (ID 54)
      db.execute('''
        INSERT OR IGNORE INTO app_systems (id, screenscraper_id, ra_id, real_name, folder_name, launch_date, description)
        VALUES (54, 135, 0, 'Android', 'android', '2008-09-23', 
                'Android is a mobile operating system based on a modified version of the Linux kernel and other open source software, designed primarily for touchscreen mobile devices such as smartphones and tablets.')
      ''');
      _log.i('System "Android" inserted');
    } catch (e, stackTrace) {
      _log.e('Error in migration v25: $e');
      _log.e('   StackTrace: $stackTrace');
      rethrow;
    }
  }

  /// Migration v23: Introduces the `is_fullscreen` setting to control window
  /// state on desktop platforms.
  static Future<void> _migrateToVersion23(Database db) async {
    _log.i('Migration v23: Adding is_fullscreen to user_config');

    try {
      final hasColumn = await _columnExists(db, 'user_config', 'is_fullscreen');

      if (!hasColumn) {
        // On desktop platforms (Windows, Linux, MacOS), fullscreen is enabled by default (1).
        // On Android/iOS, this is handled via platform-specific window managers.
        db.execute('''
          ALTER TABLE user_config 
          ADD COLUMN is_fullscreen INTEGER DEFAULT 1
        ''');
        _log.i('Column is_fullscreen added to user_config');
      } else {
        _log.i('Column is_fullscreen already exists');
      }
    } catch (e, stackTrace) {
      _log.e('Error in migration v23: $e');
      _log.e('   StackTrace: $stackTrace');
      rethrow;
    }
  }

  /// Migration v5: Configures default emulator support for PlayStation 2
  /// on Android devices.
  static Future<void> _migrateToVersion5(Database db) async {
    _log.i('Migration v5: Adding PlayStation 2 emulator for Android');

    try {
      // Check if PS2 emulator for Android already exists
      final existingEmulator = db.select('''
        SELECT id FROM app_emulators 
        WHERE id = 10120 AND os_id = 2 AND system_id = 21
        LIMIT 1
      ''');

      if (existingEmulator.isEmpty) {
        // Insert Play! emulator for PS2 on Android
        db.execute('''
          INSERT INTO app_emulators (id, os_id, system_id, name, is_standalone, core_filename, is_default, is_ra_compatible) 
          VALUES (10120, 2, 21, 'Play!', 0, 'play_libretro_android.so', 1, 0)
        ''');
        _log.i('PlayStation 2 emulator (Play!) added for Android');
      } else {
        _log.i('PlayStation 2 emulator already exists, skipping insertion');
      }
    } catch (e, stackTrace) {
      _log.e('Error in migration v5: $e');
      _log.e('   StackTrace: $stackTrace');
      rethrow;
    }
  }

  /// Migration v6: Initializes the [app_system_folders] table to support
  /// non-standard folder name aliases (e.g., matching ES-DE or LaunchBox conventions).
  static Future<void> _migrateToVersion6(Database db) async {
    _log.i('Migration v6: Creating alternate folder names table');

    try {
      // Check if table already exists
      final tableExists = db.select('''
        SELECT name FROM sqlite_master 
        WHERE type='table' AND name='app_system_folders'
        LIMIT 1
      ''');

      if (tableExists.isEmpty) {
        // Create alternate folder names table
        db.execute('''
          CREATE TABLE IF NOT EXISTS app_system_folders (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            system_id INTEGER NOT NULL,
            folder_name TEXT NOT NULL,
            FOREIGN KEY (system_id) REFERENCES app_systems(id) ON DELETE CASCADE,
            UNIQUE(system_id, folder_name)
          )
        ''');
        _log.i('Table app_system_folders created');

        // Create index for fast lookups
        db.execute('''
          CREATE INDEX IF NOT EXISTS idx_system_folders_name 
          ON app_system_folders(folder_name)
        ''');
        _log.i('Index idx_system_folders_name created');

        // For databases being migrated from v5 to v6, insert the data
        await _insertESDEFolderNames(db);
        _log.i('Alternate folder names inserted');
      } else {
        _log.i('Table app_system_folders already exists, skipping creation');
      }
    } catch (e, stackTrace) {
      _log.e('Error in migration v6: $e');
      _log.e('   StackTrace: $stackTrace');
      rethrow;
    }
  }

  /// Migration v7: Adds `actual_folder_name` to detected systems to preserve
  /// the physical directory name found on disk, decoupling it from the internal ID.
  static Future<void> _migrateToVersion7(Database db) async {
    _log.i('Migration v7: Adding actual_folder_name to user_detected_systems');

    try {
      // Check if column already exists
      final tableInfo = db.select('PRAGMA table_info(user_detected_systems)');
      final hasColumn = tableInfo.any(
        (col) => col['name'] == 'actual_folder_name',
      );

      if (!hasColumn) {
        // Add the new column
        db.execute('''
          ALTER TABLE user_detected_systems 
          ADD COLUMN actual_folder_name TEXT
        ''');
        _log.i('Column actual_folder_name added to user_detected_systems');
      } else {
        _log.i('Column actual_folder_name already exists, skipping');
      }

      // Populate existing rows with their primary folder_name from app_systems
      // This ensures backward compatibility with existing detected systems
      db.execute('''
        UPDATE user_detected_systems 
        SET actual_folder_name = (
          SELECT folder_name 
          FROM app_systems 
          WHERE app_systems.id = user_detected_systems.app_system_id
        )
        WHERE actual_folder_name IS NULL
      ''');
      _log.i('Populated actual_folder_name for existing detected systems');
    } catch (e, stackTrace) {
      _log.e('Error in migration v7: $e');
      _log.e('   StackTrace: $stackTrace');
      rethrow;
    }
  }

  /// Inserts alternate folder names
  static Future<void> _insertESDEFolderNames(Database db) async {
    final folderMappings = [
      {
        'system_id': 23,
        'folders': ['atari2600'],
      },
      {
        'system_id': 16,
        'folders': ['sega32x', 'sega32xjp', 'sega32xna'],
      },
      {
        'system_id': 51,
        'folders': ['n3ds'],
      },
      {
        'system_id': 24,
        'folders': ['atari7800'],
      },
      {
        'system_id': 48,
        'folders': ['pc88'],
      },
      {
        'system_id': 45,
        'folders': ['apple2', 'apple2gs'],
      },
      {
        'system_id': 50,
        'folders': ['arcadia'],
      },
      {
        'system_id': 40,
        'folders': ['arcade', 'consolearcade'],
      },
      {
        'system_id': 47,
        'folders': ['arduboy'],
      },
      {
        'system_id': 103,
        'folders': ['atomiswave'],
      },
      {
        'system_id': 43,
        'folders': ['channelf'],
      },
      {
        'system_id': 44,
        'folders': ['amstradcpc'],
      },
      {
        'system_id': 36,
        'folders': ['colecovision'],
      },
      {
        'system_id': 18,
        'folders': ['dreamcast'],
      },
      {
        'system_id': 7,
        'folders': ['nds'],
      },
      {
        'system_id': 39,
        'folders': ['megaduck'],
      },
      {
        'system_id': 1000,
        'folders': ['famicom', 'fds'],
      },
      {
        'system_id': 8,
        'folders': ['gamecube'],
      },
      {
        'system_id': 1002,
        'folders': ['genesiswide'],
      },
      {
        'system_id': 14,
        'folders': ['gamegear'],
      },
      {
        'system_id': 37,
        'folders': ['intellivision'],
      },
      {
        'system_id': 26,
        'folders': ['atarijaguar'],
      },
      {
        'system_id': 27,
        'folders': ['atarijaguarcd'],
      },
      {
        'system_id': 25,
        'folders': ['atarilynx'],
      },
      {
        'system_id': 1007,
        'folders': ['mame2010'],
      },
      {
        'system_id': 12,
        'folders': ['megadrive', 'megadrivejp'],
      },
      {
        'system_id': 9,
        'folders': ['pokemini'],
      },
      {
        'system_id': 35,
        'folders': ['odyssey2'],
      },
      {
        'system_id': 42,
        'folders': ['msx1', 'msx2', 'msxturbor'],
      },
      {
        'system_id': 32,
        'folders': ['neogeocd', 'neogeocdjp'],
      },
      {
        'system_id': 31,
        'folders': ['ngpc'],
      },
      {
        'system_id': 29,
        'folders': ['pcenginecd'],
      },
      {
        'system_id': 28,
        'folders': ['pcengine'],
      },
      {
        'system_id': 20,
        'folders': ['psx'],
      },
      {
        'system_id': 17,
        'folders': ['saturn', 'saturnjp'],
      },
      {
        'system_id': 15,
        'folders': ['segacd', 'megacd', 'megacdjp'],
      },
      {
        'system_id': 19,
        'folders': ['sg-1000'],
      },
      {
        'system_id': 13,
        'folders': ['mastersystem'],
      },
      {
        'system_id': 2,
        'folders': ['snesna'],
      },
      {
        'system_id': 1004,
        'folders': ['supergrafx'],
      },
      {
        'system_id': 1005,
        'folders': ['tg-cd'],
      },
      {
        'system_id': 46,
        'folders': ['uzebox'],
      },
      {
        'system_id': 10,
        'folders': ['virtualboy'],
      },
      {
        'system_id': 38,
        'folders': ['vectrex'],
      },
      {
        'system_id': 33,
        'folders': ['wonderswan', 'wonderswancolor'],
      },
      {
        'system_id': 34,
        'folders': ['supervision'],
      },
    ];

    db.execute('BEGIN TRANSACTION');
    try {
      final stmt = db.prepare(
        'INSERT OR IGNORE INTO app_system_folders (system_id, folder_name) VALUES (?, ?)',
      );
      for (final mapping in folderMappings) {
        final systemId =
            int.tryParse(mapping['system_id']?.toString() ?? '0') ?? 0;
        final folders = mapping['folders'] as List<String>;

        for (final folder in folders) {
          stmt.execute([systemId, folder]);
        }
      }
      stmt.close();
      db.execute('COMMIT');
    } catch (e) {
      db.execute('ROLLBACK');
      rethrow;
    }
  }

  /// Migration v8: Updates standalone emulator configuration to use a robust
  /// foreign key relationship with [app_emulators].
  static Future<void> _migrateToVersion8(Database db) async {
    _log.i('Migration v8: Updating standalone emulator FK references');

    try {
      // Check if user_standalone_emu_dir table exists
      final userStandaloneTableExists = db.select('''
        SELECT name FROM sqlite_master 
        WHERE type='table' AND name='user_standalone_emu_dir'
        LIMIT 1
      ''');

      if (userStandaloneTableExists.isEmpty) {
        // Create user_standalone_emu_dir table with new FK
        db.execute('''
          CREATE TABLE user_standalone_emu_dir (
            app_emulators_id INTEGER NOT NULL,
            emulator_path TEXT NOT NULL,
            is_user_default INTEGER DEFAULT NULL,
            created_at TEXT DEFAULT CURRENT_TIMESTAMP,
            updated_at TEXT DEFAULT CURRENT_TIMESTAMP,
            FOREIGN KEY (app_emulators_id) REFERENCES app_emulators(id) ON DELETE CASCADE,
            UNIQUE(app_emulators_id)
          )
        ''');
        _log.i('Table user_standalone_emu_dir created with new FK');

        // Create index
        db.execute('''
          CREATE INDEX idx_user_standalone_emu_dir_is_user_default 
          ON user_standalone_emu_dir(is_user_default)
        ''');
        _log.i('Index for user_standalone_emu_dir created');
      } else {
        // Table exists with old FK - need to migrate
        _log.i('Migrating user_standalone_emu_dir to use new FK...');

        // Check if old column exists
        final columns = db.select('PRAGMA table_info(user_standalone_emu_dir)');
        final hasOldColumn = columns.any(
          (col) => col['name'] == 'app_standalone_emu_id',
        );

        if (hasOldColumn) {
          // Rename old table
          db.execute(
            'ALTER TABLE user_standalone_emu_dir RENAME TO user_standalone_emu_dir_old',
          );

          // Create new table with updated FK
          db.execute('''
            CREATE TABLE user_standalone_emu_dir (
              app_emulators_id INTEGER NOT NULL,
              emulator_path TEXT NOT NULL,
              is_user_default INTEGER DEFAULT NULL,
              created_at TEXT DEFAULT CURRENT_TIMESTAMP,
              updated_at TEXT DEFAULT CURRENT_TIMESTAMP,
              FOREIGN KEY (app_emulators_id) REFERENCES app_emulators(id) ON DELETE CASCADE,
              UNIQUE(app_emulators_id)
            )
          ''');

          // Migrate data from old table (app_standalone_emu IDs should still exist in app_emulators)
          // Only copy data if app_emulators has the IDs
          db.execute('''
            INSERT INTO user_standalone_emu_dir (app_emulators_id, emulator_path, is_user_default, created_at, updated_at)
            SELECT old.app_standalone_emu_id, old.emulator_path, old.is_user_default, old.created_at, old.updated_at
            FROM user_standalone_emu_dir_old old
            WHERE EXISTS (SELECT 1 FROM app_emulators e WHERE e.id = old.app_standalone_emu_id AND e.is_standalone = 1)
          ''');

          // Drop old table
          db.execute('DROP TABLE user_standalone_emu_dir_old');

          // Create index
          db.execute('''
            CREATE INDEX idx_user_standalone_emu_dir_is_user_default 
            ON user_standalone_emu_dir(is_user_default)
          ''');

          _log.i('user_standalone_emu_dir migrated to new FK structure');
        } else {
          _log.i(
            'user_standalone_emu_dir already using new FK, skipping migration',
          );
        }
      }

      // Fix user_roms table to allow NULL in app_emulators_id (for standalone-only systems)
      // and add title_id, title_name columns for Switch games
      _log.i('Updating user_roms table...');

      // Check if columns already exist
      final tableInfo = db.select('PRAGMA table_info(user_roms)');
      final columnNames = tableInfo
          .map((col) => col['name'].toString())
          .toList();
      final hasTitleId = columnNames.contains('title_id');
      final hasTitleName = columnNames.contains('title_name');

      if (hasTitleId && hasTitleName) {
        _log.i(
          'Columns title_id and title_name already exist, skipping user_roms update',
        );
      } else {
        // SQLite doesn't have a direct way to modify column constraints, so we recreate the table
        db.execute('ALTER TABLE user_roms RENAME TO user_roms_old');
        db.execute('''
          CREATE TABLE user_roms (
            app_system_id INTEGER NOT NULL,
            app_emulators_id INTEGER,
            app_alternative_emulators_id INTEGER,
            virtual_folder_name TEXT,
            filename TEXT NOT NULL,
            rom_path TEXT NOT NULL,
            ra_hash TEXT,
            ss_hash TEXT,
            id_ra INTEGER,
            is_favorite INTEGER DEFAULT 0,
            play_time INTEGER DEFAULT 0,
            last_played TEXT,
            cloud_sync_enabled INTEGER DEFAULT 1,
            title_id TEXT,
            title_name TEXT,
            created_at TEXT DEFAULT CURRENT_TIMESTAMP,
            updated_at TEXT DEFAULT CURRENT_TIMESTAMP,
            FOREIGN KEY(app_system_id) REFERENCES app_systems(id) ON DELETE CASCADE,
            UNIQUE(rom_path)
          )
        ''');

        // Copy data from old table (explicitly listing columns to handle both old and new schemas)
        db.execute('''
          INSERT INTO user_roms 
          (app_system_id, app_emulators_id, app_alternative_emulators_id, virtual_folder_name, 
           filename, rom_path, ra_hash, ss_hash, id_ra, is_favorite, play_time, last_played, 
           cloud_sync_enabled, created_at, updated_at)
          SELECT app_system_id, app_emulators_id, app_alternative_emulators_id, virtual_folder_name,
                 filename, rom_path, ra_hash, ss_hash, id_ra, is_favorite, play_time, last_played,
                 cloud_sync_enabled, created_at, updated_at
          FROM user_roms_old
        ''');

        db.execute('DROP TABLE user_roms_old');
        _log.i(
          'user_roms table updated (NULL emulator IDs + title_id/title_name columns)',
        );
      }

      // Add android_package_name and android_activity_name columns to app_emulators if they don't exist
      _log.i('Adding Android package columns to app_emulators...');
      final emulatorTableInfo = db.select('PRAGMA table_info(app_emulators)');
      final emulatorColumnNames = emulatorTableInfo
          .map((col) => col['name'].toString())
          .toList();

      if (!emulatorColumnNames.contains('android_package_name')) {
        db.execute(
          'ALTER TABLE app_emulators ADD COLUMN android_package_name TEXT',
        );
        _log.i('Added android_package_name column to app_emulators');
      }

      if (!emulatorColumnNames.contains('android_activity_name')) {
        db.execute(
          'ALTER TABLE app_emulators ADD COLUMN android_activity_name TEXT',
        );
        _log.i('Added android_activity_name column to app_emulators');
      }

      // CRITICAL: Ensure the Nintendo Switch system is initialized before adding emulators.
      _log.i('Ensuring Nintendo Switch system exists...');
      final switchSystemCheck = db.select(
        'SELECT id FROM app_systems WHERE id = 53',
      );

      if (switchSystemCheck.isEmpty) {
        _log.i('Nintendo Switch system not found, inserting it...');
        db.execute('''
          INSERT INTO app_systems (id, screenscraper_id, ra_id, real_name, folder_name, launch_date, description)
          VALUES (53, 225, 0, 'Nintendo Switch', 'switch', '2017-03-03', 
                  'Nintendo''s hybrid console that can be played as a handheld or docked to a TV, featuring innovative Joy-Con controllers and a vast library of first and third-party games.')
        ''');
        _log.i('Nintendo Switch system inserted');
      } else {
        _log.i('Nintendo Switch system already exists');
      }

      // CRITICAL: If the user has a 'switch' folder in their ROM directory,
      // automatically register it in the detected systems.
      _log.i('Checking if user has Switch folder...');
      final userConfig = db.select(
        'SELECT rom_folder FROM user_config WHERE id = 1',
      );

      if (userConfig.isNotEmpty && userConfig.first['rom_folder'] != null) {
        final romFolder = userConfig.first['rom_folder'].toString();
        _log.i('   ROM folder: $romFolder');

        // Check for 'switch' directory existence (case-insensitive)
        try {
          final romDir = Directory(romFolder);
          if (await romDir.exists()) {
            final entities = await romDir.list().toList();
            bool hasSwitchFolder = false;
            String actualFolderName = 'switch';

            for (final entity in entities) {
              if (entity is Directory) {
                final folderName = path.basename(entity.path);
                if (folderName.toLowerCase() == 'switch') {
                  hasSwitchFolder = true;
                  actualFolderName = folderName;
                  break;
                }
              }
            }

            if (hasSwitchFolder) {
              // Verify if the system is already registered in the detection table.
              final existingDetection = db.select(
                'SELECT app_system_id FROM user_detected_systems WHERE app_system_id = 53',
              );

              if (existingDetection.isEmpty) {
                // Register the Switch system.
                db.execute(
                  '''
                  INSERT INTO user_detected_systems (app_system_id, actual_folder_name)
                  VALUES (53, ?)
                ''',
                  [actualFolderName],
                );
                _log.i(
                  'Switch system added to user_detected_systems with folder: $actualFolderName',
                );
              } else {
                _log.i('Switch already in user_detected_systems');
              }
            } else {
              _log.i(' No switch folder found in ROM directory');
            }
          }
        } catch (e) {
          _log.e('Could not check for switch folder: $e');
        }
      }

      // Insert Eden and Citron emulators if they don't exist
      _log.i('Inserting Eden and Citron emulators...');

      // Windows emulators (os_id = 1, system_id = 53)
      db.execute('''
        INSERT OR IGNORE INTO app_emulators (id, os_id, system_id, name, is_standalone, core_filename, is_default, is_ra_compatible)
        VALUES (121, 1, 53, 'Eden Standalone', 1, NULL, 1, 0)
      ''');
      db.execute('''
        INSERT OR IGNORE INTO app_emulators (id, os_id, system_id, name, is_standalone, core_filename, is_default, is_ra_compatible)
        VALUES (122, 1, 53, 'Citron Standalone', 1, NULL, 0, 0)
      ''');
      db.execute('''
        INSERT OR IGNORE INTO app_emulators (id, os_id, system_id, name, is_standalone, core_filename, is_default, is_ra_compatible)
        VALUES (123, 1, 53, 'Ryujinx Standalone', 1, NULL, 0, 0)
      ''');

      // Android emulators (os_id = 2, system_id = 53) with package names
      db.execute('''
        INSERT OR IGNORE INTO app_emulators (id, os_id, system_id, name, is_standalone, core_filename, is_default, is_ra_compatible, android_package_name, android_activity_name)
        VALUES (10121, 2, 53, 'Eden Standard Standalone', 1, NULL, 1, 0, 'dev.eden.eden_emulator', 'org.yuzu.yuzu_emu.activities.EmulationActivity')
      ''');
      db.execute('''
        INSERT OR IGNORE INTO app_emulators (id, os_id, system_id, name, is_standalone, core_filename, is_default, is_ra_compatible, android_package_name, android_activity_name)
        VALUES (10122, 2, 53, 'Citron Standalone', 1, NULL, 0, 0, 'org.citron.citron_emu', 'org.citron.citron_emu.activities.EmulationActivity')
      ''');

      // Linux emulators (os_id = 3, system_id = 53)
      db.execute('''
        INSERT OR IGNORE INTO app_emulators (id, os_id, system_id, name, is_standalone, core_filename, is_default, is_ra_compatible)
        VALUES (20120, 3, 53, 'Eden Standalone', 1, NULL, 1, 0)
      ''');
      db.execute('''
        INSERT OR IGNORE INTO app_emulators (id, os_id, system_id, name, is_standalone, core_filename, is_default, is_ra_compatible)
        VALUES (20121, 3, 53, 'Citron Standalone', 1, NULL, 0, 0)
      ''');
      db.execute('''
        INSERT OR IGNORE INTO app_emulators (id, os_id, system_id, name, is_standalone, core_filename, is_default, is_ra_compatible)
        VALUES (20122, 3, 53, 'Ryujinx Standalone', 1, NULL, 0, 0)
      ''');

      _log.i('Eden and Citron emulators inserted');

      // Update existing Android emulators with correct package information
      _log.i('Updating Android emulator package names...');
      db.execute('''
        UPDATE app_emulators 
        SET android_package_name = 'dev.eden.eden_emulator',
            android_activity_name = 'org.yuzu.yuzu_emu.activities.EmulationActivity'
        WHERE id = 10121 AND os_id = 2
      ''');
      _log.i('Eden Android package updated');

      db.execute('''
        UPDATE app_emulators 
        SET android_package_name = 'org.citron.citron_emu',
            android_activity_name = 'org.citron.citron_emu.activities.EmulationActivity'
        WHERE id = 10122 AND os_id = 2
      ''');
      _log.i('Citron Android package updated');

      // Insert possible paths for Eden and Citron
      _log.i('Inserting Eden and Citron possible paths...');

      // Windows paths (os_id = 1)
      db.execute('''
        INSERT OR IGNORE INTO app_emulator_possible_paths (os_id, possible_path, android_package_name, android_activity_name, description, is_default, priority)
        VALUES (1, 'C:\\Eden\\eden.exe', NULL, NULL, 'Eden Switch Emulator', 0, 20)
      ''');
      db.execute('''
        INSERT OR IGNORE INTO app_emulator_possible_paths (os_id, possible_path, android_package_name, android_activity_name, description, is_default, priority)
        VALUES (1, 'C:\\Program Files\\Eden\\eden.exe', NULL, NULL, 'Eden Switch Emulator', 0, 21)
      ''');
      db.execute('''
        INSERT OR IGNORE INTO app_emulator_possible_paths (os_id, possible_path, android_package_name, android_activity_name, description, is_default, priority)
        VALUES (1, 'D:\\Eden\\eden.exe', NULL, NULL, 'Eden Switch Emulator', 0, 22)
      ''');
      db.execute('''
        INSERT OR IGNORE INTO app_emulator_possible_paths (os_id, possible_path, android_package_name, android_activity_name, description, is_default, priority)
        VALUES (1, 'C:\\Citron\\citron.exe', NULL, NULL, 'Citron Switch Emulator', 0, 23)
      ''');
      db.execute('''
        INSERT OR IGNORE INTO app_emulator_possible_paths (os_id, possible_path, android_package_name, android_activity_name, description, is_default, priority)
        VALUES (1, 'C:\\Program Files\\Citron\\citron.exe', NULL, NULL, 'Citron Switch Emulator', 0, 24)
      ''');
      db.execute('''
        INSERT OR IGNORE INTO app_emulator_possible_paths (os_id, possible_path, android_package_name, android_activity_name, description, is_default, priority)
        VALUES (1, 'D:\\Citron\\citron.exe', NULL, NULL, 'Citron Switch Emulator', 0, 25)
      ''');

      // Android paths (os_id = 2)
      db.execute('''
        INSERT OR IGNORE INTO app_emulator_possible_paths (os_id, possible_path, android_package_name, android_activity_name, description, is_default, priority)
        VALUES (2, NULL, 'com.eden.emulator', 'com.eden.emulator.MainActivity', 'Eden Standard Switch Emulator', 1, 20)
      ''');
      db.execute('''
        INSERT OR IGNORE INTO app_emulator_possible_paths (os_id, possible_path, android_package_name, android_activity_name, description, is_default, priority)
        VALUES (2, NULL, 'org.citron.citron_emu', 'org.citron.citron_emu.ui.main.MainActivity', 'Citron Switch Emulator', 1, 21)
      ''');

      // Linux paths (os_id = 3)
      db.execute('''
        INSERT OR IGNORE INTO app_emulator_possible_paths (os_id, possible_path, android_package_name, android_activity_name, description, is_default, priority)
        VALUES (3, '~/Applications/Eden*.AppImage', NULL, NULL, 'Eden Switch Emulator', 0, 20)
      ''');
      db.execute('''
        INSERT OR IGNORE INTO app_emulator_possible_paths (os_id, possible_path, android_package_name, android_activity_name, description, is_default, priority)
        VALUES (3, '~/.local/bin/Eden*.AppImage', NULL, NULL, 'Eden Switch Emulator', 0, 21)
      ''');
      db.execute('''
        INSERT OR IGNORE INTO app_emulator_possible_paths (os_id, possible_path, android_package_name, android_activity_name, description, is_default, priority)
        VALUES (3, '~/Applications/Citron*.AppImage', NULL, NULL, 'Citron Switch Emulator', 0, 22)
      ''');
      db.execute('''
        INSERT OR IGNORE INTO app_emulator_possible_paths (os_id, possible_path, android_package_name, android_activity_name, description, is_default, priority)
        VALUES (3, '~/.local/bin/Citron*.AppImage', NULL, NULL, 'Citron Switch Emulator', 0, 23)
      ''');

      _log.i('Eden and Citron possible paths inserted');

      // Remove deprecated app_standalone_emu table if it exists
      _log.i('Checking for deprecated app_standalone_emu table...');
      final tableExists = db.select('''
        SELECT name FROM sqlite_master 
        WHERE type='table' AND name='app_standalone_emu'
        LIMIT 1
      ''');

      if (tableExists.isNotEmpty) {
        _log.i('Dropping app_standalone_emu table...');

        // Drop related indices first
        db.execute('DROP INDEX IF EXISTS idx_app_standalone_emu_system_id');
        db.execute('DROP INDEX IF EXISTS idx_app_standalone_emu_is_default');

        // Drop table
        db.execute('DROP TABLE app_standalone_emu');

        _log.i('app_standalone_emu table removed successfully');
      } else {
        _log.i('app_standalone_emu table does not exist, skipping');
      }
    } catch (e, stackTrace) {
      _log.e('Error in migration v8: $e');
      _log.e('   StackTrace: $stackTrace');
      rethrow;
    }
  }

  /// Migration v9: Registers file extensions commonly used for Nintendo Switch games.
  static Future<void> _migrateToVersion9(Database db) async {
    _log.i('Migration v9: Adding Nintendo Switch file extensions');

    try {
      // Insert Switch file extensions
      _log.i('Inserting Nintendo Switch file extensions...');
      db.execute('''
        INSERT OR IGNORE INTO app_system_extensions (system_id, extension, is_primary)
        VALUES (53, '.nsp', 1)
      ''');
      db.execute('''
        INSERT OR IGNORE INTO app_system_extensions (system_id, extension, is_primary)
        VALUES (53, '.NSP', 0)
      ''');
      db.execute('''
        INSERT OR IGNORE INTO app_system_extensions (system_id, extension, is_primary)
        VALUES (53, '.xci', 0)
      ''');
      db.execute('''
        INSERT OR IGNORE INTO app_system_extensions (system_id, extension, is_primary)
        VALUES (53, '.XCI', 0)
      ''');

      _log.i('Nintendo Switch file extensions inserted');
    } catch (e, stackTrace) {
      _log.e('Error in migration v9: $e');
      _log.e('   StackTrace: $stackTrace');
      rethrow;
    }
  }

  /// Migration v10: Synchronizes system folder name aliases with LaunchBox standards.
  static Future<void> _migrateToVersion10(Database db) async {
    _log.i('Migration v10: Adding LaunchBox folder names');

    try {
      // Insert LaunchBox folder names
      await _insertLaunchBoxFolderNames(db);
      _log.i('LaunchBox folder names inserted');
    } catch (e, stackTrace) {
      _log.e('Error in migration v10: $e');
      _log.e('   StackTrace: $stackTrace');
      rethrow;
    }
  }

  /// Migration v11: Registers Standalone PCSX2 (Windows/Linux) and NetherSX2 (Android)
  /// as available emulator options for PlayStation 2.
  static Future<void> _migrateToVersion11(Database db) async {
    _log.i(
      'Migration v11: Adding PS2 standalone emulators (PCSX2 and NetherSX2)',
    );

    db.execute('BEGIN TRANSACTION');
    try {
      try {
        // Update previous PS2 emulators to not be default anymore
        _log.i('Updating previous PS2 emulators to not be default...');

        // Windows LRPS2
        db.execute('''
          UPDATE app_emulators 
          SET is_default = 0
          WHERE id = 59 AND os_id = 1 AND system_id = 21
        ''');
        _log.i('Updated Windows LRPS2 (id: 59) to not be default');

        // Windows PCSX2 core
        db.execute('''
          UPDATE app_emulators 
          SET is_default = 0
          WHERE id = 60 AND os_id = 1 AND system_id = 21
        ''');
        _log.i('Updated Windows PCSX2 core (id: 60) to not be default');

        // Linux LRPS2
        db.execute('''
          UPDATE app_emulators 
          SET is_default = 0
          WHERE id = 20058 AND os_id = 3 AND system_id = 21
        ''');
        _log.i('Updated Linux LRPS2 (id: 20058) to not be default');

        // Linux PCSX2 core
        db.execute('''
          UPDATE app_emulators 
          SET is_default = 0
          WHERE id = 20059 AND os_id = 3 AND system_id = 21
        ''');
        _log.i('Updated Linux PCSX2 core (id: 20059) to not be default');

        // Android Play!
        db.execute('''
          UPDATE app_emulators 
          SET is_default = 0
          WHERE id = 10120 AND os_id = 2 AND system_id = 21
        ''');
        _log.i('Updated Android Play! (id: 10120) to not be default');

        // Check if PCSX2 Windows standalone already exists
        final pcsx2Windows = db.select('''
          SELECT id FROM app_emulators 
          WHERE os_id = 1 AND system_id = 21 AND name = 'PCSX2 Standalone' AND is_standalone = 1
          LIMIT 1
        ''');

        if (pcsx2Windows.isEmpty) {
          // Insert PCSX2 Standalone for Windows (ID 124)
          db.execute('''
            INSERT OR IGNORE INTO app_emulators (id, os_id, system_id, name, is_standalone, core_filename, is_default, is_ra_compatible, android_package_name, android_activity_name)
            VALUES (124, 1, 21, 'PCSX2 Standalone', 1, NULL, 1, 1, NULL, NULL)
          ''');
          _log.i('PCSX2 Standalone added for Windows');

          // Insert possible paths for Windows
          db.execute('''
            INSERT OR IGNORE INTO app_emulator_possible_paths (os_id, possible_path, android_package_name, android_activity_name, description, is_default, priority)
            VALUES (1, 'C:\\PCSX2\\pcsx2-qt.exe', NULL, NULL, 'PCSX2 Standalone', 0, 30)
          ''');
          db.execute('''
            INSERT OR IGNORE INTO app_emulator_possible_paths (os_id, possible_path, android_package_name, android_activity_name, description, is_default, priority)
            VALUES (1, 'C:\\Program Files\\PCSX2\\pcsx2-qt.exe', NULL, NULL, 'PCSX2 Standalone', 0, 31)
          ''');
          db.execute('''
            INSERT OR IGNORE INTO app_emulator_possible_paths (os_id, possible_path, android_package_name, android_activity_name, description, is_default, priority)
            VALUES (1, 'C:\\Program Files (x86)\\PCSX2\\pcsx2-qt.exe', NULL, NULL, 'PCSX2 Standalone', 0, 32)
          ''');
          db.execute('''
            INSERT OR IGNORE INTO app_emulator_possible_paths (os_id, possible_path, android_package_name, android_activity_name, description, is_default, priority)
            VALUES (1, 'D:\\PCSX2\\pcsx2-qt.exe', NULL, NULL, 'PCSX2 Standalone', 0, 33)
          ''');
          _log.i('PCSX2 Windows paths added');
        } else {
          _log.i('PCSX2 Standalone for Windows already exists, skipping');
        }

        // Check if NetherSX2 Android standalone already exists
        final nethersx2Android = db.select('''
          SELECT id FROM app_emulators 
          WHERE os_id = 2 AND system_id = 21 AND name = 'NetherSX2' AND is_standalone = 1
          LIMIT 1
        ''');

        if (nethersx2Android.isEmpty) {
          // Insert NetherSX2 for Android (ID 10123)
          db.execute('''
            INSERT OR IGNORE INTO app_emulators (id, os_id, system_id, name, is_standalone, core_filename, is_default, is_ra_compatible, android_package_name, android_activity_name)
            VALUES (10123, 2, 21, 'NetherSX2', 1, NULL, 1, 1, 'xyz.aethersx2.android', 'xyz.aethersx2.android.EmulationActivity')
          ''');
          _log.i('NetherSX2 added for Android');

          // Insert possible path for Android
          db.execute('''
            INSERT OR IGNORE INTO app_emulator_possible_paths (os_id, possible_path, android_package_name, android_activity_name, description, is_default, priority)
            VALUES (2, NULL, 'xyz.aethersx2.android', 'xyz.aethersx2.android.EmulationActivity', 'NetherSX2 PS2 Emulator', 1, 30)
          ''');
          _log.i('NetherSX2 Android path added');
        } else {
          _log.i('NetherSX2 for Android already exists, skipping');
        }

        // Check if PCSX2 Linux standalone already exists
        final pcsx2Linux = db.select('''
          SELECT id FROM app_emulators 
          WHERE os_id = 3 AND system_id = 21 AND name = 'PCSX2 Standalone' AND is_standalone = 1
          LIMIT 1
        ''');

        if (pcsx2Linux.isEmpty) {
          // Insert PCSX2 Standalone for Linux (ID 20060)
          db.execute('''
            INSERT OR IGNORE INTO app_emulators (id, os_id, system_id, name, is_standalone, core_filename, is_default, is_ra_compatible, android_package_name, android_activity_name)
            VALUES (20060, 3, 21, 'PCSX2 Standalone', 1, NULL, 0, 1, NULL, NULL)
          ''');
          _log.i('PCSX2 Standalone added for Linux');

          // Insert possible paths for Linux
          db.execute('''
            INSERT OR IGNORE INTO app_emulator_possible_paths (os_id, possible_path, android_package_name, android_activity_name, description, is_default, priority)
            VALUES (3, '/var/lib/flatpak/exports/bin/net.pcsx2.PCSX2', NULL, NULL, 'PCSX2 Flatpak', 1, 30)
          ''');
          db.execute('''
            INSERT OR IGNORE INTO app_emulator_possible_paths (os_id, possible_path, android_package_name, android_activity_name, description, is_default, priority)
            VALUES (3, '~/.local/share/flatpak/exports/bin/net.pcsx2.PCSX2', NULL, NULL, 'PCSX2 Flatpak User', 0, 31)
          ''');
          db.execute('''
            INSERT OR IGNORE INTO app_emulator_possible_paths (os_id, possible_path, android_package_name, android_activity_name, description, is_default, priority)
            VALUES (3, '~/Applications/PCSX2*.AppImage', NULL, NULL, 'PCSX2 AppImage', 0, 32)
          ''');
          db.execute('''
            INSERT OR IGNORE INTO app_emulator_possible_paths (os_id, possible_path, android_package_name, android_activity_name, description, is_default, priority)
            VALUES (3, '~/.local/bin/pcsx2-qt', NULL, NULL, 'PCSX2 Binary', 0, 33)
          ''');
          db.execute('''
            INSERT OR IGNORE INTO app_emulator_possible_paths (os_id, possible_path, android_package_name, android_activity_name, description, is_default, priority)
            VALUES (3, '/usr/bin/pcsx2-qt', NULL, NULL, 'PCSX2 System', 0, 34)
          ''');
          _log.i('PCSX2 Linux paths added');
        } else {
          _log.i('PCSX2 Standalone for Linux already exists, skipping');
        }
      } catch (e, stackTrace) {
        _log.e('Error in migration v11: $e');
        _log.e('   StackTrace: $stackTrace');
        rethrow;
      }
      db.execute('COMMIT');
    } catch (e) {
      db.execute('ROLLBACK');
      rethrow;
    }

    _log.i('Migration v11 complete');
  }

  /// Migration v12: Registers Standalone Dolphin support for GameCube and Wii.
  static Future<void> _migrateToVersion12(Database db) async {
    _log.i('Migration v12: Adding Dolphin Standalone emulator');

    db.execute('BEGIN TRANSACTION');
    try {
      try {
        // Remove default flag from Dolphin RetroArch cores
        _log.i('Removing default flag from Dolphin RetroArch cores...');
        db.execute('''
          UPDATE app_emulators 
          SET is_default = 0 
          WHERE name = 'Dolphin' AND is_standalone = 0 AND (system_id = 8 OR system_id = 52)
        ''');
        _log.i('Dolphin RetroArch cores default flag removed');

        // Insert Dolphin Standalone for Windows (GameCube and Wii)
        db.execute('''
          INSERT OR IGNORE INTO app_emulators 
          (id, os_id, system_id, name, is_standalone, core_filename, is_default, is_ra_compatible, android_package_name, android_activity_name) 
          VALUES 
          (125, 1, 8, 'Dolphin Standalone', 1, NULL, 1, 0, NULL, NULL),
          (126, 1, 52, 'Dolphin Standalone', 1, NULL, 1, 0, NULL, NULL)
        ''');
        _log.i('Dolphin Standalone added for Windows');

        // Insert Dolphin Standalone for Android (GameCube and Wii)
        db.execute('''
          INSERT OR IGNORE INTO app_emulators 
          (id, os_id, system_id, name, is_standalone, core_filename, is_default, is_ra_compatible, android_package_name, android_activity_name) 
          VALUES 
          (10125, 2, 8, 'Dolphin Standalone', 1, NULL, 1, 0, 'org.dolphinemu.dolphinemu', 'org.dolphinemu.dolphinemu.ui.main.MainActivity'),
          (10127, 2, 52, 'Dolphin Standalone', 1, NULL, 1, 0, 'org.dolphinemu.dolphinemu', 'org.dolphinemu.dolphinemu.ui.main.MainActivity')
        ''');
        _log.i('Dolphin Standalone added for Android');

        // Insert Dolphin Standalone for Linux (GameCube and Wii)
        db.execute('''
          INSERT OR IGNORE INTO app_emulators 
          (id, os_id, system_id, name, is_standalone, core_filename, is_default, is_ra_compatible, android_package_name, android_activity_name) 
          VALUES 
          (20125, 3, 8, 'Dolphin Standalone', 1, NULL, 1, 0, NULL, NULL),
          (20126, 3, 52, 'Dolphin Standalone', 1, NULL, 1, 0, NULL, NULL)
        ''');
        _log.i('Dolphin Standalone added for Linux');

        // Insert Dolphin possible path for Android
        db.execute('''
          INSERT OR IGNORE INTO app_emulator_possible_paths (os_id, possible_path, android_package_name, android_activity_name, description, is_default, priority)
          VALUES (2, NULL, 'org.dolphinemu.dolphinemu', 'org.dolphinemu.dolphinemu.ui.main.MainActivity', 'Dolphin Emulator', 1, 40)
        ''');
        _log.i('Dolphin possible path added for Android');
      } catch (e, stackTrace) {
        _log.e('Error in migration v12: $e');
        _log.e('   StackTrace: $stackTrace');
        rethrow;
      }
      db.execute('COMMIT');
    } catch (e) {
      db.execute('ROLLBACK');
      rethrow;
    }

    _log.i('Migration v12 complete');
  }

  /// Migration v13: Registers multiple popular standalone emulators (PPSSPP, Azahar/Lime3DS,
  /// DuckStation, MelonDS) across all supported platforms.
  static Future<void> _migrateToVersion13(Database db) async {
    _log.i(
      'Migration v13: Adding PPSSPP, Azahar, DuckStation and MelonDS standalone emulators',
    );

    db.execute('BEGIN TRANSACTION');
    try {
      try {
        // Remove default flag from RetroArch cores for PSP, 3DS, PS1 and DS
        _log.i('Removing default flag from RetroArch cores...');
        db.execute('''
          UPDATE app_emulators 
          SET is_default = 0 
          WHERE is_standalone = 0 
            AND ((name = 'PPSSPP' AND system_id = 22)
              OR (name = 'Citra' AND system_id = 51)
              OR (name IN ('Beetle PSX HW', 'Beetle PSX', 'SwanStation', 'PCSX ReARMed') AND system_id = 20)
              OR (name IN ('DeSmuME', 'melonDS', 'melonDS DS', 'DeSmuME 2015') AND system_id = 7))
        ''');
        _log.i('RetroArch cores default flags removed');

        // Insert for Windows
        db.execute('''
          INSERT OR IGNORE INTO app_emulators 
          (id, os_id, system_id, name, is_standalone, core_filename, is_default, is_ra_compatible, android_package_name, android_activity_name) 
          VALUES 
          (127, 1, 22, 'PPSSPP Standalone', 1, NULL, 0, 1, NULL, NULL),
          (128, 1, 51, 'Azahar Standalone', 1, NULL, 0, 0, NULL, NULL),
          (129, 1, 20, 'DuckStation Standalone', 1, NULL, 0, 1, NULL, NULL),
          (130, 1, 7, 'MelonDS Standalone', 1, NULL, 0, 1, NULL, NULL)
        ''');
        _log.i('Standalone emulators added for Windows');

        // Insert for Android
        db.execute('''
          INSERT OR IGNORE INTO app_emulators 
          (id, os_id, system_id, name, is_standalone, core_filename, is_default, is_ra_compatible, android_package_name, android_activity_name) 
          VALUES 
          (10128, 2, 22, 'PPSSPP Standalone', 1, NULL, 1, 1, 'org.ppsspp.ppsspp', 'org.ppsspp.ppsspp.PpssppActivity'),
          (10129, 2, 22, 'PPSSPP Gold Standalone', 1, NULL, 0, 1, 'org.ppsspp.ppssppgold', 'org.ppsspp.ppssppgold.PpssppActivity'),
          (10130, 2, 51, 'Azahar Standalone', 1, NULL, 1, 0, 'io.github.lime3ds.android', 'org.citra.citra_emu.activities.EmulationActivity'),
          (10131, 2, 20, 'DuckStation Standalone', 1, NULL, 0, 1, 'com.github.stenzek.duckstation', 'com.github.stenzek.duckstation.EmulationActivity')
        ''');
        _log.i('Standalone emulators added for Android');

        // Insert for Linux
        db.execute('''
          INSERT OR IGNORE INTO app_emulators 
          (id, os_id, system_id, name, is_standalone, core_filename, is_default, is_ra_compatible, android_package_name, android_activity_name) 
          VALUES 
          (20127, 3, 22, 'PPSSPP Standalone', 1, NULL, 0, 1, NULL, NULL),
          (20128, 3, 51, 'Azahar Standalone', 1, NULL, 0, 0, NULL, NULL),
          (20129, 3, 20, 'DuckStation Standalone', 1, NULL, 0, 1, NULL, NULL)
        ''');
        _log.i('Standalone emulators added for Linux');

        // Insert possible paths for Android
        db.execute('''
          INSERT OR IGNORE INTO app_emulator_possible_paths (os_id, possible_path, android_package_name, android_activity_name, description, is_default, priority)
          VALUES 
          (2, NULL, 'org.ppsspp.ppsspp', 'org.ppsspp.ppsspp.EmulationActivity', 'PPSSPP Emulator', 1, 50),
          (2, NULL, 'org.ppsspp.ppssppgold', 'org.ppsspp.ppssppgold.EmulationActivity', 'PPSSPP Gold Emulator', 1, 51),
          (2, NULL, 'io.github.lime3ds.android', 'org.citra.citra_emu.activities.EmulationActivity', 'Azahar Emulator', 1, 60),
          (2, NULL, 'com.github.stenzek.duckstation', 'com.github.stenzek.duckstation.EmulationActivity', 'DuckStation Emulator', 1, 70)
        ''');
        _log.i('Emulator possible paths added for Android');
      } catch (e, stackTrace) {
        _log.e('Error in migration v13: $e');
        _log.e('   StackTrace: $stackTrace');
        rethrow;
      }
      db.execute('COMMIT');
    } catch (e) {
      db.execute('ROLLBACK');
      rethrow;
    }

    _log.i('Migration v13 complete');
  }

  /// Inserts ES-DE and LaunchBox alternate folder names
  static Future<void> _insertLaunchBoxFolderNames(Database db) async {
    final folderMappings = [
      // Nintendo Systems
      {
        'system_id': 1,
        'folders': ['Nintendo Entertainment System'],
      },
      {
        'system_id': 2,
        'folders': ['Super Nintendo Entertainment System', 'snesna'],
      },
      {
        'system_id': 3,
        'folders': ['gameboy', 'Game Boy', 'Nintendo Game Boy'],
      },
      {
        'system_id': 4,
        'folders': ['gbcolor', 'Game Boy Color', 'Nintendo Game Boy Color'],
      },
      {
        'system_id': 5,
        'folders': ['Game Boy Advance', 'Nintendo Game Boy Advance'],
      },
      {
        'system_id': 6,
        'folders': ['Nintendo 64'],
      },
      {
        'system_id': 7,
        'folders': ['nds', 'Nintendo DS'],
      },
      {
        'system_id': 51,
        'folders': ['n3ds', 'Nintendo 3DS'],
      },
      {
        'system_id': 8,
        'folders': ['gamecube', 'GameCube', 'Nintendo GameCube'],
      },
      {
        'system_id': 9,
        'folders': ['pokemini', 'Pokemon Mini', 'Nintendo Pokemon Mini'],
      },
      {
        'system_id': 10,
        'folders': ['Virtual Boy', 'Nintendo Virtual Boy'],
      },
      {
        'system_id': 11,
        'folders': ['Nintendo DSi'],
      },
      {
        'system_id': 52,
        'folders': ['Nintendo Wii'],
      },
      {
        'system_id': 53,
        'folders': ['Nintendo Switch'],
      },
      // Sega Systems
      {
        'system_id': 12,
        'folders': ['megadrive', 'megadrivejp', 'Mega Drive', 'Sega Genesis'],
      },
      {
        'system_id': 13,
        'folders': ['mastersystem', 'Master System', 'Sega Master System'],
      },
      {
        'system_id': 14,
        'folders': ['gamegear', 'Game Gear', 'Sega Game Gear'],
      },
      {
        'system_id': 15,
        'folders': ['segacd', 'megacd', 'megacdjp', 'Sega CD'],
      },
      {
        'system_id': 16,
        'folders': ['sega32x', 'sega32xjp', 'sega32xna', '32X', 'Sega 32X'],
      },
      {
        'system_id': 17,
        'folders': ['saturn', 'saturnjp', 'Saturn', 'Sega Saturn'],
      },
      {
        'system_id': 18,
        'folders': ['dreamcast', 'Dreamcast', 'Sega Dreamcast'],
      },
      {
        'system_id': 19,
        'folders': ['sg-1000', 'SG-1000', 'Sega SG-1000'],
      },
      // Sony Systems
      {
        'system_id': 20,
        'folders': ['psx', 'PlayStation', 'Sony Playstation'],
      },
      {
        'system_id': 21,
        'folders': ['PlayStation 2', 'Sony Playstation 2'],
      },
      {
        'system_id': 22,
        'folders': ['PlayStation Portable', 'Sony PSP'],
      },
      // Atari Systems
      {
        'system_id': 23,
        'folders': ['atari2600', 'Atari 2600'],
      },
      {
        'system_id': 24,
        'folders': ['atari7800', 'Atari 7800'],
      },
      {
        'system_id': 25,
        'folders': ['atarilynx', 'Atari Lynx'],
      },
      {
        'system_id': 26,
        'folders': ['atarijaguar', 'Atari Jaguar'],
      },
      {
        'system_id': 27,
        'folders': ['atarijaguarcd', 'Atari Jaguar CD'],
      },
      // NEC Systems
      {
        'system_id': 28,
        'folders': ['pcengine', 'PC Engine', 'NEC TurboGrafx-16'],
      },
      {
        'system_id': 29,
        'folders': ['pcenginecd', 'PC Engine CD', 'NEC TurboGrafx-CD'],
      },
      {
        'system_id': 30,
        'folders': ['PC-FX', 'NEC PC-FX'],
      },
      // SNK Systems
      {
        'system_id': 31,
        'folders': ['ngpc', 'Neo Geo Pocket Color', 'SNK Neo Geo Pocket Color'],
      },
      {
        'system_id': 32,
        'folders': ['neogeocd', 'neogeocdjp', 'Neo Geo CD', 'SNK Neo Geo CD'],
      },
      // Other Handhelds
      {
        'system_id': 33,
        'folders': ['wonderswan', 'wonderswancolor', 'WonderSwan Color'],
      },
      {
        'system_id': 34,
        'folders': ['supervision', 'Watara Supervision'],
      },
      // Retro Computers/Consoles
      {
        'system_id': 35,
        'folders': ['odyssey2', 'Magnavox Odyssey 2'],
      },
      {
        'system_id': 36,
        'folders': ['colecovision'],
      },
      {
        'system_id': 37,
        'folders': ['intellivision', 'Intellivision', 'Mattel Intellivision'],
      },
      {
        'system_id': 38,
        'folders': ['vectrex', 'Vectrex', 'GCE Vectrex'],
      },
      {
        'system_id': 39,
        'folders': ['megaduck', 'Mega Duck'],
      },
      // Other Systems
      {
        'system_id': 40,
        'folders': ['arcade', 'consolearcade'],
      },
      {
        'system_id': 41,
        'folders': ['3DO Interactive Multiplayer'],
      },
      {
        'system_id': 42,
        'folders': ['msx1', 'msx2', 'msxturbor', 'Microsoft MSX'],
      },
      {
        'system_id': 43,
        'folders': ['channelf', 'Fairchild Channel F'],
      },
      {
        'system_id': 44,
        'folders': ['amstradcpc', 'Amstrad CPC'],
      },
      {
        'system_id': 45,
        'folders': ['apple2', 'apple2gs', 'Apple II'],
      },
      {
        'system_id': 46,
        'folders': ['uzebox'],
      },
      {
        'system_id': 47,
        'folders': ['arduboy'],
      },
      {
        'system_id': 48,
        'folders': ['pc88', 'PC-8000/8800', 'NEC PC-8801'],
      },
      {
        'system_id': 49,
        'folders': ['WASM-4'],
      },
      {
        'system_id': 50,
        'folders': ['arcadia', 'Arcadia 2001', 'Emerson Arcadia 2001'],
      },
      // Arcade Systems
      {
        'system_id': 100,
        'folders': ['NAOMI'],
      },
      {
        'system_id': 101,
        'folders': ['NAOMI 2'],
      },
      {
        'system_id': 102,
        'folders': ['NAOMI GD-ROM'],
      },
      {
        'system_id': 103,
        'folders': ['atomiswave', 'Atomiswave'],
      },
      // Virtual systems
      {
        'system_id': 1000,
        'folders': ['famicom', 'fds', 'Family Computer'],
      },
      {
        'system_id': 1001,
        'folders': ['Super Family Computer'],
      },
      {
        'system_id': 1002,
        'folders': ['genesiswide', 'Sega Genesis'],
      },
      {
        'system_id': 1003,
        'folders': ['Mark III'],
      },
      {
        'system_id': 1004,
        'folders': ['supergrafx', 'TurboGrafx-16', 'NEC TurboGrafx-16'],
      },
      {
        'system_id': 1005,
        'folders': ['tg-cd', 'TurboGrafx-CD', 'NEC TurboGrafx-CD'],
      },
      {
        'system_id': 1006,
        'folders': ['Final Burn Neo'],
      },
      {
        'system_id': 1007,
        'folders': ['mame2010'],
      },
      {
        'system_id': 1011,
        'folders': ['Neo Geo'],
      },
    ];

    db.execute('BEGIN TRANSACTION');
    try {
      final stmt = db.prepare(
        'INSERT OR IGNORE INTO app_system_folders (system_id, folder_name) VALUES (?, ?)',
      );
      for (final mapping in folderMappings) {
        final systemId =
            int.tryParse(mapping['system_id']?.toString() ?? '0') ?? 0;
        final folders = mapping['folders'] as List<String>;

        for (final folder in folders) {
          stmt.execute([systemId, folder]);
        }
      }
      stmt.close();
      db.execute('COMMIT');
    } catch (e) {
      db.execute('ROLLBACK');
      rethrow;
    }
  }

  /// Migration v14: Configures standalone Switch emulators (Eden, Citron, Ryujinx).
  static Future<void> _migrateToVersion14(Database db) async {
    _log.i(
      'Migration v14: Adding Switch emulators (Eden, Citron, Ryujinx) Standalone',
    );

    try {
      // Check if Switch system exists
      final switchSystem = db.select('SELECT * FROM app_systems WHERE id = ?', [
        53,
      ]);

      if (switchSystem.isEmpty) {
        _log.w(
          'Switch system (id=53) not found, skipping Switch emulator insertion',
        );
        return;
      }

      // Insert Eden Standalone for Windows
      db.execute('''
        INSERT OR IGNORE INTO app_emulators 
        (id, os_id, system_id, name, is_standalone, core_filename, is_default, is_ra_compatible, android_package_name, android_activity_name)
        VALUES (121, 1, 53, 'Eden Standalone', 1, NULL, 0, 0, NULL, NULL)
      ''');
      _log.i('Eden Standalone added for Windows');

      // Insert Eden Standalone for Android
      db.execute('''
        INSERT OR IGNORE INTO app_emulators 
        (id, os_id, system_id, name, is_standalone, core_filename, is_default, is_ra_compatible, android_package_name, android_activity_name)
        VALUES (10121, 2, 53, 'Eden Standalone', 1, NULL, 0, 0, 'com.jareddanieljames.eden', 'com.jareddanieljames.eden.ui.main.MainActivity')
      ''');
      _log.i('Eden Standalone added for Android');

      // Insert Eden Standalone for Linux
      db.execute('''
        INSERT OR IGNORE INTO app_emulators 
        (id, os_id, system_id, name, is_standalone, core_filename, is_default, is_ra_compatible, android_package_name, android_activity_name)
        VALUES (20120, 3, 53, 'Eden Standalone', 1, NULL, 0, 0, NULL, NULL)
      ''');
      _log.i('Eden Standalone added for Linux');

      // Insert Citron Standalone for Windows
      db.execute('''
        INSERT OR IGNORE INTO app_emulators 
        (id, os_id, system_id, name, is_standalone, core_filename, is_default, is_ra_compatible, android_package_name, android_activity_name)
        VALUES (122, 1, 53, 'Citron Standalone', 1, NULL, 0, 0, NULL, NULL)
      ''');
      _log.i('Citron Standalone added for Windows');

      // Insert Citron Standalone for Android
      db.execute('''
        INSERT OR IGNORE INTO app_emulators 
        (id, os_id, system_id, name, is_standalone, core_filename, is_default, is_ra_compatible, android_package_name, android_activity_name)
        VALUES (10122, 2, 53, 'Citron Standalone', 1, NULL, 0, 0, 'org.citron.citron_emu', 'org.citron.citron_emu.ui.main.MainActivity')
      ''');
      _log.i('Citron Standalone added for Android');

      // Insert Citron Standalone for Linux
      db.execute('''
        INSERT OR IGNORE INTO app_emulators 
        (id, os_id, system_id, name, is_standalone, core_filename, is_default, is_ra_compatible, android_package_name, android_activity_name)
        VALUES (20121, 3, 53, 'Citron Standalone', 1, NULL, 0, 0, NULL, NULL)
      ''');
      _log.i('Citron Standalone added for Linux');

      // Insert Ryujinx Standalone for Windows (no Android version)
      db.execute('''
        INSERT OR IGNORE INTO app_emulators 
        (id, os_id, system_id, name, is_standalone, core_filename, is_default, is_ra_compatible, android_package_name, android_activity_name)
        VALUES (123, 1, 53, 'Ryujinx Standalone', 1, NULL, 0, 0, NULL, NULL)
      ''');
      _log.i('Ryujinx Standalone added for Windows');

      // Insert Ryujinx Standalone for Linux
      db.execute('''
        INSERT OR IGNORE INTO app_emulators 
        (id, os_id, system_id, name, is_standalone, core_filename, is_default, is_ra_compatible, android_package_name, android_activity_name)
        VALUES (20122, 3, 53, 'Ryujinx Standalone', 1, NULL, 0, 0, NULL, NULL)
      ''');
      _log.i('Ryujinx Standalone added for Linux');
    } catch (e, stackTrace) {
      _log.e('Error in migration v14: $e');
      _log.e('   StackTrace: $stackTrace');
      rethrow;
    }
  }

  /// Migration v15: Updates [app_system_folders] with a comprehensive list of
  /// alternate folder names for cross-frontend compatibility.
  static Future<void> _migrateToVersion15(Database db) async {
    _log.i(
      'Migration v15: Updating app_system_folders with complete alternate folder names from compatibility page',
    );

    try {
      // Delete all existing entries (we'll re-insert with complete list)
      db.execute('DELETE FROM app_system_folders');
      _log.i('Cleared existing app_system_folders entries');

      // Re-insert with complete list from _insertLaunchBoxFolderNames
      await _insertLaunchBoxFolderNames(db);
      _log.i('All alternate folder names inserted from compatibility page');
    } catch (e, stackTrace) {
      _log.e('Error in migration v15: $e');
      _log.e('   StackTrace: $stackTrace');
      rethrow;
    }
  }

  /// Migration to version 16: Fix Dolphin activity name from EmulationActivity to MainActivity
  static Future<void> _migrateToVersion16(Database db) async {
    _log.i('Migration v16: Fixing Dolphin activity name to MainActivity');

    try {
      // Update Dolphin emulators to use MainActivity instead of EmulationActivity
      db.execute('''
        UPDATE app_emulators 
        SET android_activity_name = 'org.dolphinemu.dolphinemu.ui.main.MainActivity'
        WHERE android_package_name = 'org.dolphinemu.dolphinemu'
          AND android_activity_name = 'org.dolphinemu.dolphinemu.ui.main.EmulationActivity'
      ''');
      _log.i('Updated Dolphin emulators activity to MainActivity');

      // Also update app_emulator_possible_paths if it exists
      db.execute('''
        UPDATE app_emulator_possible_paths 
        SET android_activity_name = 'org.dolphinemu.dolphinemu.ui.main.MainActivity'
        WHERE android_package_name = 'org.dolphinemu.dolphinemu'
          AND android_activity_name = 'org.dolphinemu.dolphinemu.ui.main.EmulationActivity'
      ''');
      _log.i('Updated Dolphin in app_emulator_possible_paths');
    } catch (e, stackTrace) {
      _log.e('Error in migration v16: $e');
      _log.e('   StackTrace: $stackTrace');
      rethrow;
    }
  }

  /// Migration to version 17: Add macOS emulators from SQL file
  static Future<void> _migrateToVersion17(Database db) async {
    _log.i('Migration v17: Adding macOS emulators');

    try {
      // Execute the macOS emulators SQL file
      await _executeSqlFromAsset(
        db,
        'assets/data/06_app_insert_app_emulators[macos].sql',
      );
      _log.i('macOS emulators added successfully');
    } catch (e, stackTrace) {
      _log.e('Error in migration v17: $e');
      _log.e('   StackTrace: $stackTrace');
      rethrow;
    }
  }

  /// Migration to version 18: Adding RetroArch path for macOS
  static Future<void> _migrateToVersion18(Database db) async {
    _log.i('Migration v18: Adding RetroArch path for macOS');

    try {
      // Insert RetroArch path for macOS
      db.execute('''
        INSERT OR IGNORE INTO app_emulator_possible_paths 
        (os_id, possible_path, android_package_name, android_activity_name, description, is_default, priority) 
        VALUES (4, '/Applications/RetroArch.app', NULL, NULL, 'RetroArch macOS', 1, 1)
      ''');

      _log.i('RetroArch path for macOS added successfully');
    } catch (e, stackTrace) {
      _log.e('Error in migration v18: $e');
      _log.e('   StackTrace: $stackTrace');
      rethrow;
    }
  }

  /// Migration to version 19: Adds system_view_mode to user_config
  static Future<void> _migrateToVersion19(Database db) async {
    _log.i('Migration v19: Adding system_view_mode to user_config');
    try {
      // Check if column already exists to avoid errors
      final columns = db.select("PRAGMA table_info(user_config)");
      final hasColumn = columns.any((c) => c['name'] == 'system_view_mode');

      if (!hasColumn) {
        db.execute(
          "ALTER TABLE user_config ADD COLUMN system_view_mode TEXT DEFAULT 'grid'",
        );
        _log.i('system_view_mode column added to user_config');
      } else {
        _log.i('system_view_mode column already exists');
      }
    } catch (e, stackTrace) {
      _log.e('Error in migration v19: $e');
      _log.e('   StackTrace: $stackTrace');
      rethrow;
    }
  }

  /// Migration to version 20: Ensures system_view_mode exists and sets default to carousel
  static Future<void> _migrateToVersion20(Database db) async {
    _log.i('Migration v20: Ensuring system_view_mode column exists');
    try {
      // Check if column already exists
      final columns = db.select("PRAGMA table_info(user_config)");
      final hasColumn = columns.any((c) => c['name'] == 'system_view_mode');

      if (!hasColumn) {
        db.execute(
          "ALTER TABLE user_config ADD COLUMN system_view_mode TEXT DEFAULT 'grid'",
        );
        _log.i('system_view_mode column added to user_config');
      } else {
        _log.i('system_view_mode column already exists');
      }

      // Update existing rows that might have null or empty to grid
      db.execute(
        "UPDATE user_config SET system_view_mode = 'grid' WHERE system_view_mode IS NULL OR system_view_mode = ''",
      );
      _log.i('Existing rows updated to use grid as default');
    } catch (e, stackTrace) {
      _log.e('Error in migration v20: $e');
      _log.e('   StackTrace: $stackTrace');
      rethrow;
    }
  }

  /// Migration to version 21: Change default system_view_mode to carousel
  static Future<void> _migrateToVersion21(Database db) async {
    _log.i('Migration v21: Changing default system_view_mode to grid');
    try {
      // Update all existing rows to use carousel
      db.execute(
        "UPDATE user_config SET system_view_mode = 'grid' WHERE id = 1",
      );
      _log.i('system_view_mode changed to grid for all users');
    } catch (e, stackTrace) {
      _log.e('Error in migration v21: $e');
      _log.e('   StackTrace: $stackTrace');
      rethrow;
    }
  }

  /// Helper method to execute SQL from an asset file
  static Future<void> _executeSqlFromAsset(
    Database db,
    String assetPath,
  ) async {
    try {
      final content = await rootBundle.loadString(assetPath);
      final statements = _parseSqlStatements(content);

      if (statements.isEmpty) {
        _log.w('No SQL statements found in $assetPath');
        return;
      }

      _log.i('Executing ${statements.length} statements from $assetPath...');

      db.execute('BEGIN TRANSACTION');
      try {
        for (final statement in statements) {
          final trimmed = statement.trim();
          if (trimmed.isNotEmpty && !_isCommentOrEmpty(trimmed)) {
            db.execute(trimmed);
          }
        }
        db.execute('COMMIT');
      } catch (_) {
        db.execute('ROLLBACK');
        rethrow;
      }

      _log.i('SQL file executed successfully');
    } catch (e, stackTrace) {
      _log.e('Error executing SQL from asset: $e');
      _log.e('   StackTrace: $stackTrace');
      rethrow;
    }
  }

  /// Parse SQL statements from a string
  static List<String> _parseSqlStatements(String content) {
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
          i++;
          continue;
        }
        if (inBlockComment && char == '*' && nextChar == '/') {
          inBlockComment = false;
          i++;
          continue;
        }
      }

      // Handle line comments
      if (!inSingleQuote && !inDoubleQuote && !inBlockComment) {
        if (char == '-' && nextChar == '-') {
          inLineComment = true;
          i++;
          continue;
        }
      }

      if (inLineComment) {
        if (char == '\n') {
          inLineComment = false;
        }
        continue;
      }

      if (inBlockComment) continue;

      // Handle quotes
      if (char == "'" && !inDoubleQuote) {
        inSingleQuote = !inSingleQuote;
      } else if (char == '"' && !inSingleQuote) {
        inDoubleQuote = !inDoubleQuote;
      }

      // Add character to buffer
      buffer.write(char);

      // Check for statement terminator
      if (char == ';' && !inSingleQuote && !inDoubleQuote) {
        final statement = buffer.toString().trim();
        if (statement.isNotEmpty) {
          statements.add(statement);
        }
        buffer.clear();
      }
    }

    // Add any remaining content
    final remaining = buffer.toString().trim();
    if (remaining.isNotEmpty && !remaining.startsWith('--')) {
      statements.add(remaining);
    }

    return statements;
  }

  /// Check if a line is a comment or empty
  static bool _isCommentOrEmpty(String line) {
    final trimmed = line.trim();
    return trimmed.isEmpty ||
        trimmed.startsWith('--') ||
        trimmed.startsWith('/*') ||
        trimmed.startsWith('*/');
  }

  /// Migration to version 22: Add show_game_info to user_config
  static Future<void> _migrateToVersion22(Database db) async {
    _log.i('Migration v22: Adding show_game_info to user_config');

    try {
      final hasColumn = await _columnExists(
        db,
        'user_config',
        'show_game_info',
      );

      if (!hasColumn) {
        db.execute('''
          ALTER TABLE user_config 
          ADD COLUMN show_game_info INTEGER DEFAULT 0
        ''');
        _log.i('Column show_game_info added to user_config');
      } else {
        _log.i('Column show_game_info already exists');
      }
    } catch (e, stackTrace) {
      _log.e('Error in migration v22: $e');
      _log.e('   StackTrace: $stackTrace');
      rethrow;
    }
  }

  /// Migration to version 35: Create user_retroarch_config table
  static Future<void> _migrateToVersion35(Database db) async {
    _log.i('Migration v35: Creating user_retroarch_config table');

    try {
      db.execute('''
        CREATE TABLE IF NOT EXISTS user_retroarch_config (
          id INTEGER PRIMARY KEY CHECK (id = 1),
          config_path TEXT NOT NULL,
          system_directory TEXT,
          savefile_directory TEXT,
          savestate_directory TEXT,
          created_at TEXT DEFAULT CURRENT_TIMESTAMP,
          updated_at TEXT DEFAULT CURRENT_TIMESTAMP
        )
      ''');
      _log.i('Table user_retroarch_config created');
    } catch (e) {
      _log.e('Error in migration v35: \$e');
      rethrow;
    }
  }

  /// Migration to version 31: Add bartop_exit_poweroff to user_config
  static Future<void> _migrateToVersion31(Database db) async {
    _log.i('Migration v31: Adding bartop_exit_poweroff to user_config');

    try {
      final hasColumn = await _columnExists(
        db,
        'user_config',
        'bartop_exit_poweroff',
      );

      if (!hasColumn) {
        db.execute('''
          ALTER TABLE user_config 
          ADD COLUMN bartop_exit_poweroff INTEGER DEFAULT 0
        ''');
        _log.i('Column bartop_exit_poweroff added to user_config');
      } else {
        _log.i('Column bartop_exit_poweroff already exists');
      }
    } catch (e, stackTrace) {
      _log.e('Error in migration v31: $e');
      _log.e('   StackTrace: $stackTrace');
      rethrow;
    }
  }

  /// Migration to version 32: Add scan_on_startup to user_config
  static Future<void> _migrateToVersion32(Database db) async {
    _log.i('Migration v32: Adding scan_on_startup to user_config');

    try {
      final hasColumn = await _columnExists(
        db,
        'user_config',
        'scan_on_startup',
      );

      if (!hasColumn) {
        db.execute('''
          ALTER TABLE user_config 
          ADD COLUMN scan_on_startup INTEGER DEFAULT 1
        ''');
        _log.i('Column scan_on_startup added to user_config');
      } else {
        _log.i('Column scan_on_startup already exists');
      }
    } catch (e, stackTrace) {
      _log.e('Error in migration v32: $e');
      _log.e('   StackTrace: $stackTrace');
      rethrow;
    }
  }

  /// Helper to check if a column exists
  static Future<bool> _columnExists(
    Database db,
    String tableName,
    String columnName,
  ) async {
    final tableInfo = db.select('PRAGMA table_info($tableName)');
    return tableInfo.any((col) => col['name'] == columnName);
  }

  /// Migration v28: Introduces the [user_rom_folders] table to allow users to
  /// manage multiple physical directories for their ROM collection.
  static Future<void> _migrateToVersion28(Database db) async {
    _log.i('Migration v28: Creating user_rom_folders table');

    try {
      // 1. Create the new table
      db.execute('''
        CREATE TABLE IF NOT EXISTS user_rom_folders (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          path TEXT NOT NULL UNIQUE
        )
      ''');
      _log.i('Table user_rom_folders created');

      // 2. Migrate existing rom_folder from user_config if it's not empty
      final config = db.select(
        'SELECT rom_folder FROM user_config WHERE id = 1',
      );
      if (config.isNotEmpty) {
        final existingPath = config.first['rom_folder']?.toString();
        if (existingPath != null && existingPath.isNotEmpty) {
          db.execute(
            'INSERT OR IGNORE INTO user_rom_folders (path) VALUES (?)',
            [existingPath],
          );
          _log.i('Existing rom_folder migrated to user_rom_folders');
        }
      }

      _log.i('Migration v28 completed');
    } catch (e, stackTrace) {
      _log.e('Error in migration v28: $e');
      _log.e('   StackTrace: $stackTrace');
      rethrow;
    }
  }

  /// Migration v29: Implements granular scraping preferences (metadata vs media)
  /// in [user_screenscraper_config].
  static Future<void> _migrateToVersion29(Database db) async {
    _log.i('Migration v29: Adding granular scraping preferences');

    try {
      // Check if table exists
      final tableExists = db.select(
        "SELECT name FROM sqlite_master WHERE type='table' AND name='user_screenscraper_config'",
      );

      if (tableExists.isEmpty) {
        // Create if not exists with new columns
        db.execute('''
          CREATE TABLE user_screenscraper_config (
            id INTEGER PRIMARY KEY,
            scrape_mode TEXT,
            scrape_metadata INTEGER DEFAULT 1,
            scrape_images INTEGER DEFAULT 1,
            scrape_videos INTEGER DEFAULT 1,
            updated_at TEXT
          )
        ''');
        // Insert default
        db.execute(
          "INSERT INTO user_screenscraper_config (id, scrape_mode, scrape_metadata, scrape_images, scrape_videos) VALUES (1, 'new_only', 1, 1, 1)",
        );
        _log.i('Table user_screenscraper_config created with new columns');
      } else {
        // Add columns if they don't exist
        final columns = db
            .select("PRAGMA table_info(user_screenscraper_config)")
            .map((c) => c['name'].toString())
            .toList();

        if (!columns.contains('scrape_metadata')) {
          db.execute(
            "ALTER TABLE user_screenscraper_config ADD COLUMN scrape_metadata INTEGER DEFAULT 1",
          );
          _log.i('Column scrape_metadata added');
        }
        if (!columns.contains('scrape_images')) {
          db.execute(
            "ALTER TABLE user_screenscraper_config ADD COLUMN scrape_images INTEGER DEFAULT 1",
          );
          _log.i('Column scrape_images added');
        }
        if (!columns.contains('scrape_videos')) {
          db.execute(
            "ALTER TABLE user_screenscraper_config ADD COLUMN scrape_videos INTEGER DEFAULT 1",
          );
          _log.i('Column scrape_videos added');
        }
      }

      _log.i('Migration v29 completed');
    } catch (e, stackTrace) {
      _log.e('Error in migration v29: $e');
      _log.e('   StackTrace: $stackTrace');
      rethrow;
    }
  }

  /// Migration to version 30: Force check for granular scraping columns
  /// (Identical to v29 logic to ensure it runs for users who might have missed it)
  static Future<void> _migrateToVersion30(Database db) async {
    _log.i('Migration v30: Ensuring granular scraping columns exist');
    // Re-use logic from v29 as it is idempotent (checks if columns exist)
    await _migrateToVersion29(db);
  }

  /// Migration v33: Synchronizes Android system folder naming conventions.
  static Future<void> _migrateToVersion33(Database db) async {
    _log.i('Migration v33: Updating Android system folder names');

    try {
      // 1. Update folder_name in app_systems (ID 54 and 55)
      // This fix addresses users who had 'android' or 'androidapps'
      // instead of the new hyphenated names.
      db.execute('''
        UPDATE app_systems 
        SET folder_name = 'android' 
        WHERE id = 54
      ''');
      _log.i('Fixed primary folder names in app_systems');

      // 2. Update user_detected_systems if they already had the old names
      db.execute('''
        UPDATE user_detected_systems 
        SET folder_name = 'android' 
        WHERE app_system_id = 54
      ''');
      _log.i('Fixed folder names in user_detected_systems');

      // 3. Update user_roms to point to the new folder names for consistency
      db.execute('''
        UPDATE user_roms 
        SET system_folder_name = 'android' 
        WHERE app_system_id = 54
      ''');
      _log.i('Fixed system folder names in user_roms');
    } catch (e, stackTrace) {
      _log.e('Error in migration v33: $e');
      _log.e('   StackTrace: $stackTrace');
    }
  }

  /// Migration v34: Removes redundant MAME folder entries to prevent duplicate
  /// system detection.
  static Future<void> _migrateToVersion34(Database db) async {
    _log.i('Migration v34: Removing duplicate MAME folder name');

    try {
      db.execute('''
        DELETE FROM app_system_folders 
        WHERE system_id = 1007 AND folder_name = 'MAME'
      ''');
      _log.i('Redundant MAME folder name removed from app_system_folders');
    } catch (e, stackTrace) {
      _log.e('Error in migration v34: $e');
      _log.e('   StackTrace: $stackTrace');
      rethrow;
    }
  }

  /// Migration v36: Registers optimized and legacy variants of Switch emulators.
  static Future<void> _migrateToVersion36(Database db) async {
    _log.i('Migration v36: Re-indexing standalones and adding Eden variants');

    db.execute('BEGIN TRANSACTION');
    try {
      // 1. Rename existing Eden (10121)
      db.execute('''
        UPDATE app_emulators 
        SET name = 'Eden Standard Standalone'
        WHERE id = 10121 AND os_id = 2
      ''');

      // 3. Insert new Eden variants
      db.execute('''
        INSERT OR IGNORE INTO app_emulators (id, os_id, system_id, name, is_standalone, core_filename, is_default, is_ra_compatible, android_package_name, android_activity_name)
        VALUES (10132, 2, 53, 'Eden Legacy Standalone', 1, NULL, 0, 0, 'dev.legacy.eden_emulator', 'org.yuzu.yuzu_emu.activities.EmulationActivity')
      ''');
      db.execute('''
        INSERT OR IGNORE INTO app_emulators (id, os_id, system_id, name, is_standalone, core_filename, is_default, is_ra_compatible, android_package_name, android_activity_name)
        VALUES (10133, 2, 53, 'Eden Optimized Standalone', 1, NULL, 0, 0, 'com.miHoYo.Yuanshen', 'org.yuzu.yuzu_emu.activities.EmulationActivity')
      ''');

      // 4. Ensure app_emulator_possible_paths are updated
      db.execute('''
        INSERT OR IGNORE INTO app_emulator_possible_paths (os_id, android_package_name, android_activity_name, description, is_default, priority)
        VALUES (2, 'dev.legacy.eden_emulator', 'org.yuzu.yuzu_emu.ui.main.MainActivity', 'Eden Legacy Switch Emulator', 1, 21)
      ''');
      db.execute('''
        INSERT OR IGNORE INTO app_emulator_possible_paths (os_id, android_package_name, android_activity_name, description, is_default, priority)
        VALUES (2, 'com.miHoYo.Yuanshen', 'org.yuzu.yuzu_emu.ui.main.MainActivity', 'Eden Optimized Switch Emulator', 1, 22)
      ''');

      _log.i('New Eden variants and re-indexing complete');
      db.execute('COMMIT');
    } catch (e, stackTrace) {
      db.execute('ROLLBACK');
      _log.e('Error in migration v36: $e');
      _log.e('   StackTrace: $stackTrace');
      rethrow;
    }
  }

  /// Migration v37: Initializes the [user_system_settings] table for per-system
  /// UI and scanning preferences.
  static Future<void> _migrateToVersion37(Database db) async {
    _log.i('Migration v37: Adding user_system_settings table');

    try {
      db.execute('''
        CREATE TABLE IF NOT EXISTS user_system_settings (
          app_system_id INTEGER NOT NULL,
          recursive_scan INTEGER DEFAULT 0,
          updated_at TEXT DEFAULT CURRENT_TIMESTAMP,
          FOREIGN KEY (app_system_id) REFERENCES app_systems(id) ON DELETE CASCADE,
          UNIQUE(app_system_id)
        );
      ''');
      _log.i('Table user_system_settings created');
    } catch (e, stackTrace) {
      _log.e('Error in migration v37: $e');
      _log.e('   StackTrace: $stackTrace');
      rethrow;
    }
  }

  /// Migration v38: Registers the Nightly variant of Switch emulators.
  static Future<void> _migrateToVersion38(Database db) async {
    _log.i('Migration v38: Adding Eden Nightly version for Android');

    db.execute('BEGIN TRANSACTION');
    try {
      // 1. Insert Eden Nightly into app_emulators (Odin/Android OS id = 2)
      db.execute('''
        INSERT OR IGNORE INTO app_emulators (id, os_id, system_id, name, is_standalone, core_filename, is_default, is_ra_compatible, android_package_name, android_activity_name)
        VALUES (10134, 2, 53, 'Eden Nightly Standalone', 1, NULL, 0, 0, 'dev.eden.eden_nightly', 'org.yuzu.yuzu_emu.activities.EmulationActivity')
      ''');

      // 2. Add as a possible path/installation detection
      db.execute('''
        INSERT OR IGNORE INTO app_emulator_possible_paths (os_id, android_package_name, android_activity_name, description, is_default, priority)
        VALUES (2, 'dev.eden.eden_nightly', 'org.yuzu.yuzu_emu.ui.main.MainActivity', 'Eden Nightly Switch Emulator', 1, 23)
      ''');

      _log.i('Eden Nightly added to emulators and possible paths');
      db.execute('COMMIT');
    } catch (e, stackTrace) {
      db.execute('ROLLBACK');
      _log.e('Error in migration v38: $e');
      _log.e('   StackTrace: $stackTrace');
      rethrow;
    }
  }

  /// Migration v39: Extends ScreenScraper credentials to track API quota and usage statistics.
  static Future<void> _migrateToVersion39(Database db) async {
    _log.i('Migration v39: Adding more user info to screenscraper credentials');

    try {
      db.execute(
        'ALTER TABLE user_screenscraper_credentials ADD COLUMN requests_today INTEGER DEFAULT 0',
      );
      db.execute(
        'ALTER TABLE user_screenscraper_credentials ADD COLUMN max_requests_per_day INTEGER DEFAULT 0',
      );
      db.execute(
        'ALTER TABLE user_screenscraper_credentials ADD COLUMN requests_ko_today INTEGER DEFAULT 0',
      );
      db.execute(
        'ALTER TABLE user_screenscraper_credentials ADD COLUMN max_requests_ko_per_day INTEGER DEFAULT 0',
      );
      db.execute(
        'ALTER TABLE user_screenscraper_credentials ADD COLUMN max_download_speed INTEGER DEFAULT 0',
      );
      db.execute(
        'ALTER TABLE user_screenscraper_credentials ADD COLUMN visites INTEGER DEFAULT 0',
      );
      db.execute(
        'ALTER TABLE user_screenscraper_credentials ADD COLUMN last_visit TEXT',
      );
      db.execute(
        'ALTER TABLE user_screenscraper_credentials ADD COLUMN fav_region TEXT',
      );

      _log.i('Migration v39 complete');
    } catch (e, stackTrace) {
      _log.e('Error in migration v39: $e');
      _log.e('   StackTrace: $stackTrace');
      rethrow;
    }
  }

  /// Migration to version 40: Unify ROM paths with NOCASE and clean duplicates
  static Future<void> _migrateToVersion40(Database db) async {
    _log.i(
      'Migration v40: Unifying ROM paths with NOCASE and cleaning duplicates',
    );

    db.execute('BEGIN TRANSACTION');
    try {
      // 1. Create a temporary table to hold unique ROMs (Case Insensitive)
      // We group by lower(rom_path) and take the one that actually exists on disk if possible,
      // or just the first one.
      db.execute('''
        CREATE TABLE user_roms_temp AS
        SELECT * FROM user_roms
        GROUP BY lower(rom_path)
      ''');

      // 2. Drop the old table
      db.execute('DROP TABLE user_roms');

      // 3. Recreate the table with COLLATE NOCASE
      db.execute('''
        CREATE TABLE user_roms (
          app_system_id INTEGER NOT NULL,
          app_emulators_id INTEGER,
          app_alternative_emulators_id INTEGER,
          virtual_folder_name TEXT,
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
          created_at TEXT DEFAULT CURRENT_TIMESTAMP,
          updated_at TEXT DEFAULT CURRENT_TIMESTAMP,
          description TEXT,
          year TEXT,
          developer TEXT,
          publisher TEXT,
          genre TEXT,
          players TEXT,
          FOREIGN KEY (app_system_id) REFERENCES app_systems(id) ON DELETE CASCADE,
          UNIQUE(rom_path)
        )
      ''');

      // 4. Fill the new table
      db.execute('''
        INSERT INTO user_roms 
        SELECT 
          app_system_id, app_emulators_id, app_alternative_emulators_id, 
          virtual_folder_name, filename, rom_path, ra_hash, ss_hash, 
          id_ra, is_favorite, play_time, last_played, cloud_sync_enabled, 
          title_id, title_name, created_at, updated_at, description, 
          year, developer, publisher, genre, players
        FROM user_roms_temp
      ''');

      // 5. Drop the temporary table
      db.execute('DROP TABLE user_roms_temp');

      _log.i('Migration v40 completed');
      db.execute('COMMIT');
    } catch (e, stackTrace) {
      db.execute('ROLLBACK');
      _log.e('Error in migration v40: $e');
      _log.e('   StackTrace: $stackTrace');
      rethrow;
    }
  }

  /// Migration v41: Enables support for custom system logos in carousel and grid views.
  static Future<void> _migrateToVersion41(Database db) async {
    _log.i('Migration v41: Adding custom images to user_system_settings');

    try {
      // Check if columns exist (just in case)
      final hasCarousel = await _columnExists(
        db,
        'user_system_settings',
        'custom_carousel_logo',
      );
      final hasGrid = await _columnExists(
        db,
        'user_system_settings',
        'custom_grid_logo',
      );

      if (!hasCarousel) {
        db.execute('''
          ALTER TABLE user_system_settings 
          ADD COLUMN custom_carousel_logo TEXT
        ''');
        _log.i('Column custom_carousel_logo added');
      }

      if (!hasGrid) {
        db.execute('''
          ALTER TABLE user_system_settings 
          ADD COLUMN custom_grid_logo TEXT
        ''');
        _log.i('Column custom_grid_logo added');
      }
    } catch (e, stackTrace) {
      _log.e('Error in migration v41: $e');
      _log.e('   StackTrace: $stackTrace');
      rethrow;
    }
  }

  /// Migration v42: Adds preferences to control game name formatting (hiding extensions/brackets).
  static Future<void> _migrateToVersion42(Database db) async {
    _log.i(
      'Migration v42: Adding game name display options to user_system_settings',
    );

    try {
      final hasHideExtension = await _columnExists(
        db,
        'user_system_settings',
        'hide_extension',
      );
      final hasHideParentheses = await _columnExists(
        db,
        'user_system_settings',
        'hide_parentheses',
      );
      final hasHideBrackets = await _columnExists(
        db,
        'user_system_settings',
        'hide_brackets',
      );

      if (!hasHideExtension) {
        db.execute(
          'ALTER TABLE user_system_settings ADD COLUMN hide_extension INTEGER DEFAULT 1',
        );
        _log.i('Column hide_extension added');
      }

      if (!hasHideParentheses) {
        db.execute(
          'ALTER TABLE user_system_settings ADD COLUMN hide_parentheses INTEGER DEFAULT 1',
        );
        _log.i('Column hide_parentheses added');
      }

      if (!hasHideBrackets) {
        db.execute(
          'ALTER TABLE user_system_settings ADD COLUMN hide_brackets INTEGER DEFAULT 1',
        );
        _log.i('Column hide_brackets added');
      }
    } catch (e, stackTrace) {
      _log.e('Error in migration v42: $e');
      _log.e('   StackTrace: $stackTrace');
      rethrow;
    }
  }

  /// Migration v43: Adds `unique_identifier` to emulators for stable cross-platform mapping.
  static Future<void> _migrateToVersion43(Database db) async {
    _log.i('Migration v43: Adding unique_identifier to app_emulators');

    try {
      final hasColumn = await _columnExists(
        db,
        'app_emulators',
        'unique_identifier',
      );

      if (!hasColumn) {
        db.execute(
          'ALTER TABLE app_emulators ADD COLUMN unique_identifier TEXT',
        );
        _log.i('Column unique_identifier added to app_emulators');
      } else {
        _log.i('Column unique_identifier already exists');
      }
    } catch (e, stackTrace) {
      _log.e('Error in migration v43: $e');
      _log.e('   StackTrace: $stackTrace');
      rethrow;
    }
  }

  /// Migration to version 44: Remove UNIQUE(os_id, system_id, name) from app_emulators
  static Future<void> _migrateToVersion44(Database db) async {
    _log.i('Migration v44: Removing UNIQUE name constraint from app_emulators');

    // Recreating table is necessary to change UNIQUE constraints in SQLite
    db.execute('PRAGMA foreign_keys = OFF');
    db.execute('BEGIN TRANSACTION');
    try {
      // 1. Create new table with updated constraint
      db.execute('''
        CREATE TABLE app_emulators_new (
            id INTEGER PRIMARY KEY,
            os_id INTEGER NOT NULL,
            system_id INTEGER NOT NULL,
            name TEXT NOT NULL,
            is_standalone INTEGER NOT NULL DEFAULT 0,
            core_filename TEXT,
            is_default INTEGER NOT NULL DEFAULT 0,
            is_ra_compatible INTEGER NOT NULL DEFAULT 0,
            android_package_name TEXT,
            android_activity_name TEXT,
            unique_identifier TEXT,
            FOREIGN KEY (os_id) REFERENCES app_os(id) ON DELETE CASCADE,
            FOREIGN KEY (system_id) REFERENCES app_systems(id) ON DELETE CASCADE,
            UNIQUE(os_id, unique_identifier)
        );
      ''');

      // 2. Copy data. We might have duplicates in the old table if we had partial failures?
      // Actually, we skip duplicates if they exist, but normally they shouldn't.
      db.execute('''
        INSERT OR IGNORE INTO app_emulators_new 
        SELECT id, os_id, system_id, name, is_standalone, core_filename, is_default, is_ra_compatible, android_package_name, android_activity_name, unique_identifier
        FROM app_emulators
      ''');

      // 3. Swap tables
      db.execute('DROP TABLE app_emulators');
      db.execute('ALTER TABLE app_emulators_new RENAME TO app_emulators');

      db.execute('COMMIT');
      _log.i('Migration v44 completed successfully');
    } catch (e, stackTrace) {
      db.execute('ROLLBACK');
      _log.e('Error in migration v44: $e');
      _log.e('   StackTrace: $stackTrace');
      rethrow;
    } finally {
      db.execute('PRAGMA foreign_keys = ON');
    }
  }

  /// Migration v45: Updates emulator configuration to use the stable `unique_identifier`
  /// instead of volatile integer IDs.
  static Future<void> _migrateToVersion45(Database db) async {
    _log.i(
      'Migration v45: Migrating user_emulator_config to use unique_identifier',
    );

    // Recreate table to use unique_identifier instead of app_emulators_id
    // This table stores config for ALL emulators (standalone AND RetroArch)
    db.execute('PRAGMA foreign_keys = OFF');
    db.execute('BEGIN TRANSACTION');
    try {
      // 1. Create new table with unique_identifier as PK
      db.execute('''
        CREATE TABLE user_emulator_config (
            emulator_unique_id TEXT NOT NULL,
            emulator_path TEXT NOT NULL,
            is_user_default INTEGER DEFAULT NULL,
            created_at TEXT DEFAULT CURRENT_TIMESTAMP,
            updated_at TEXT DEFAULT CURRENT_TIMESTAMP,
            PRIMARY KEY(emulator_unique_id)
        );
      ''');

      // 2. Migrate data from old user_standalone_emu_dir table
      // JOIN with app_emulators to get the unique_identifier for each existing entry
      db.execute('''
        INSERT INTO user_emulator_config (emulator_unique_id, emulator_path, is_user_default, created_at, updated_at)
        SELECT 
            e.unique_identifier,
            old.emulator_path,
            old.is_user_default,
            old.created_at,
            old.updated_at
        FROM user_standalone_emu_dir old
        JOIN app_emulators e ON old.app_emulators_id = e.id
        WHERE e.unique_identifier IS NOT NULL
      ''');

      // 3. Drop old table
      db.execute('DROP TABLE user_standalone_emu_dir');

      // 4. Create index for performance
      db.execute('''
        CREATE INDEX idx_user_emulator_config_is_user_default 
        ON user_emulator_config(is_user_default)
      ''');

      db.execute('COMMIT');
      _log.i('Migration v45 completed successfully');
      _log.i('   user_standalone_emu_dir renamed to user_emulator_config');
      _log.i('   Now uses unique_identifier for stability across app restarts');
    } catch (e, stackTrace) {
      db.execute('ROLLBACK');
      _log.e('Error in migration v45: $e');
      _log.e('   StackTrace: $stackTrace');
      rethrow;
    } finally {
      db.execute('PRAGMA foreign_keys = ON');
    }
  }

  /// Migration to version 46: Safety net - ensure user_emulator_config exists
  /// This handles cases where v45 may have failed or users upgrading from older versions
  static Future<void> _migrateToVersion46(Database db) async {
    _log.i('Migration v46: Ensuring user_emulator_config table exists');

    try {
      // Check if old table still exists
      final oldTableExists = db.select('''
        SELECT name FROM sqlite_master 
        WHERE type='table' AND name='user_standalone_emu_dir'
        LIMIT 1
      ''');

      // Check if new table exists
      final newTableExists = db.select('''
        SELECT name FROM sqlite_master 
        WHERE type='table' AND name='user_emulator_config'
        LIMIT 1
      ''');

      if (oldTableExists.isNotEmpty && newTableExists.isEmpty) {
        // Old table exists but new doesn't - v45 didn't run, so run it now
        _log.w('Old table exists, new table missing - running v45 migration');
        await _migrateToVersion45(db);
      } else if (newTableExists.isEmpty) {
        // Neither table exists - create new one from scratch
        _log.i('Creating user_emulator_config table from scratch');
        db.execute('''
          CREATE TABLE user_emulator_config (
              emulator_unique_id TEXT NOT NULL,
              emulator_path TEXT NOT NULL,
              is_user_default INTEGER DEFAULT NULL,
              created_at TEXT DEFAULT CURRENT_TIMESTAMP,
              updated_at TEXT DEFAULT CURRENT_TIMESTAMP,
              PRIMARY KEY(emulator_unique_id)
          );
        ''');

        db.execute('''
          CREATE INDEX idx_user_emulator_config_is_user_default 
          ON user_emulator_config(is_user_default)
        ''');

        _log.i('user_emulator_config table created');
      } else if (oldTableExists.isNotEmpty && newTableExists.isNotEmpty) {
        // Both exist - v45 ran but didn't clean up old table
        _log.i('Both tables exist - dropping old table');
        db.execute('DROP TABLE user_standalone_emu_dir');
        _log.i('Old user_standalone_emu_dir table dropped');
      }
    } catch (e, stackTrace) {
      _log.e('Error in migration v46: $e');
      _log.e('   StackTrace: $stackTrace');
      rethrow;
    }
  }

  /// Migration v48: Refactors system identification to use string IDs (folder names)
  /// for better portability and consistency.
  static Future<void> _migrateToVersion48(Database db) async {
    _log.i('Migration v48: Refactoring app_systems to use String ID');

    db.execute('PRAGMA foreign_keys = OFF');
    db.execute('BEGIN TRANSACTION');

    try {
      // 1. app_systems -> app_systems_new
      db.execute('''
        CREATE TABLE app_systems_new (
          id TEXT PRIMARY KEY,
          screenscraper_id INTEGER,
          ra_id INTEGER,
          real_name TEXT NOT NULL,
          folder_name TEXT NOT NULL,
          launch_date TEXT,
          description TEXT
        )
      ''');
      db.execute('''
        INSERT INTO app_systems_new (id, screenscraper_id, ra_id, real_name, folder_name, launch_date, description)
        SELECT folder_name, screenscraper_id, ra_id, real_name, folder_name, launch_date, description
        FROM app_systems
      ''');

      // 2. app_system_folders -> app_system_folders_new
      db.execute('''
        CREATE TABLE app_system_folders_new (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          system_id TEXT NOT NULL,
          folder_name TEXT NOT NULL,
          FOREIGN KEY (system_id) REFERENCES app_systems(id) ON DELETE CASCADE,
          UNIQUE(system_id, folder_name)
        )
      ''');
      db.execute('''
        INSERT INTO app_system_folders_new (system_id, folder_name)
        SELECT s.folder_name, f.folder_name
        FROM app_system_folders f
        JOIN app_systems s ON f.system_id = s.id
      ''');

      // 3. app_system_extensions -> app_system_extensions_new
      db.execute('''
        CREATE TABLE app_system_extensions_new (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          system_id TEXT NOT NULL,
          extension TEXT NOT NULL,
          FOREIGN KEY (system_id) REFERENCES app_systems(id) ON DELETE CASCADE,
          UNIQUE(system_id, extension)
        )
      ''');
      db.execute('''
        INSERT INTO app_system_extensions_new (system_id, extension)
        SELECT s.folder_name, e.extension
        FROM app_system_extensions e
        JOIN app_systems s ON e.system_id = s.id
      ''');

      // 4. app_emulators -> app_emulators_new_str
      db.execute('''
        CREATE TABLE app_emulators_new_str (
            id INTEGER PRIMARY KEY,
            os_id INTEGER NOT NULL,
            system_id TEXT NOT NULL,
            name TEXT NOT NULL,
            is_standalone INTEGER NOT NULL DEFAULT 0,
            core_filename TEXT,
            is_default INTEGER NOT NULL DEFAULT 0,
            is_ra_compatible INTEGER NOT NULL DEFAULT 0,
            android_package_name TEXT,
            android_activity_name TEXT,
            unique_identifier TEXT,
            FOREIGN KEY (os_id) REFERENCES app_os(id) ON DELETE CASCADE,
            FOREIGN KEY (system_id) REFERENCES app_systems(id) ON DELETE CASCADE,
            UNIQUE(os_id, unique_identifier)
        )
      ''');
      db.execute('''
        INSERT INTO app_emulators_new_str 
        SELECT e.id, e.os_id, s.folder_name, e.name, e.is_standalone, e.core_filename, e.is_default, e.is_ra_compatible, e.android_package_name, e.android_activity_name, e.unique_identifier
        FROM app_emulators e
        JOIN app_systems s ON e.system_id = s.id
      ''');

      // 5. user_roms -> user_roms_new
      db.execute('''
        CREATE TABLE user_roms_new (
            app_system_id TEXT NOT NULL,
            app_emulators_id INTEGER,
            app_alternative_emulators_id INTEGER,
            virtual_folder_name TEXT,
            filename TEXT NOT NULL,
            rom_path TEXT NOT NULL,
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
            FOREIGN KEY(app_system_id) REFERENCES app_systems(id) ON DELETE CASCADE,
            UNIQUE(rom_path)
        )
      ''');

      final userRomsInfo = db.select('PRAGMA table_info(user_roms)');
      final userRomsCols = userRomsInfo
          .map((c) => c['name'].toString())
          .toList();

      String col(String name) =>
          userRomsCols.contains(name) ? 'r.$name' : 'NULL';

      db.execute('''
        INSERT INTO user_roms_new (
          app_system_id, app_emulators_id, app_alternative_emulators_id, virtual_folder_name, 
          filename, rom_path, ra_hash, ss_hash, id_ra, is_favorite, play_time, last_played, 
          cloud_sync_enabled, title_id, title_name, description, year, developer, publisher, 
          genre, players, created_at, updated_at
        )
        SELECT 
          s.folder_name, r.app_emulators_id, r.app_alternative_emulators_id, r.virtual_folder_name, 
          r.filename, r.rom_path, r.ra_hash, r.ss_hash, r.id_ra, r.is_favorite, r.play_time, 
          r.last_played, r.cloud_sync_enabled, ${col('title_id')}, ${col('title_name')}, 
          ${col('description')}, ${col('year')}, ${col('developer')}, ${col('publisher')}, 
          ${col('genre')}, ${col('players')}, r.created_at, r.updated_at
        FROM user_roms r
        JOIN app_systems s ON r.app_system_id = s.id
      ''');

      // 6. user_system_settings -> user_system_settings_new
      db.execute('''
        CREATE TABLE user_system_settings_new (
          app_system_id TEXT NOT NULL,
          recursive_scan INTEGER DEFAULT 0,
          hide_extension INTEGER DEFAULT 0,
          hide_parentheses INTEGER DEFAULT 0,
          hide_brackets INTEGER DEFAULT 0,
          custom_carousel_logo TEXT,
          custom_grid_logo TEXT,
          updated_at TEXT DEFAULT CURRENT_TIMESTAMP,
          FOREIGN KEY (app_system_id) REFERENCES app_systems(id) ON DELETE CASCADE,
          UNIQUE(app_system_id)
        )
      ''');
      final sysSettingsInfo = db.select(
        'PRAGMA table_info(user_system_settings)',
      );
      final sysSettingsCols = sysSettingsInfo
          .map((c) => c['name'].toString())
          .toList();

      String scol(String name) =>
          sysSettingsCols.contains(name) ? 'us.$name' : 'NULL';

      db.execute('''
        INSERT INTO user_system_settings_new (
          app_system_id, recursive_scan, hide_extension, hide_parentheses, 
          hide_brackets, custom_carousel_logo, custom_grid_logo, updated_at
        )
        SELECT 
          s.folder_name, us.recursive_scan, ${scol('hide_extension')}, 
          ${scol('hide_parentheses')}, ${scol('hide_brackets')}, 
          ${scol('custom_carousel_logo')}, ${scol('custom_grid_logo')}, us.updated_at
        FROM user_system_settings us
        JOIN app_systems s ON us.app_system_id = s.id
      ''');

      // 7. user_screenscraper_system_config -> user_screenscraper_system_config_new
      db.execute('''
        CREATE TABLE user_screenscraper_system_config_new (
            app_system_id TEXT PRIMARY KEY,
            enabled INTEGER DEFAULT 1,
            updated_at TEXT,
            FOREIGN KEY (app_system_id) REFERENCES app_systems(id) ON DELETE CASCADE
        )
      ''');
      db.execute('''
        INSERT INTO user_screenscraper_system_config_new (app_system_id, enabled)
        SELECT s.folder_name, ussc.enabled
        FROM user_screenscraper_system_config ussc
        JOIN app_systems s ON ussc.app_system_id = s.id
      ''');

      // 8. user_detected_systems -> user_detected_systems_new
      db.execute('''
        CREATE TABLE user_detected_systems_new (
          app_system_id TEXT NOT NULL,
          actual_folder_name TEXT,
          detected_at TEXT DEFAULT CURRENT_TIMESTAMP,
          FOREIGN KEY (app_system_id) REFERENCES app_systems(id) ON DELETE CASCADE,
          UNIQUE(app_system_id)
        )
      ''');
      db.execute('''
        INSERT INTO user_detected_systems_new (app_system_id, actual_folder_name, detected_at)
        SELECT s.folder_name, uds.actual_folder_name, uds.detected_at
        FROM user_detected_systems uds
        JOIN app_systems s ON uds.app_system_id = s.id
      ''');

      // 9. user_screenscraper_metadata -> user_screenscraper_metadata_new
      db.execute('''
        CREATE TABLE user_screenscraper_metadata_new (
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
        )
      ''');

      final metaInfo = db.select(
        'PRAGMA table_info(user_screenscraper_metadata)',
      );
      final metaCols = metaInfo.map((c) => c['name'].toString()).toList();

      String mcol(String name) => metaCols.contains(name) ? 'm.$name' : 'NULL';

      db.execute('''
        INSERT INTO user_screenscraper_metadata_new 
        SELECT 
          s.folder_name, m.filename, m.id_ra, m.real_name, 
          ${mcol('description_en')}, ${mcol('description_es')}, ${mcol('description_fr')}, 
          ${mcol('description_de')}, ${mcol('description_it')}, ${mcol('description_pt')}, 
          m.rating, m.release_date, ${mcol('developer')}, ${mcol('publisher')}, 
          ${mcol('genre')}, ${mcol('players')}, m.is_fully_scraped, m.updated_at
        FROM user_screenscraper_metadata m
        JOIN app_systems s ON m.app_system_id = s.id
      ''');

      // SWAP TABLES
      db.execute('DROP TABLE app_system_folders');
      db.execute(
        'ALTER TABLE app_system_folders_new RENAME TO app_system_folders',
      );

      db.execute('DROP TABLE app_system_extensions');
      db.execute(
        'ALTER TABLE app_system_extensions_new RENAME TO app_system_extensions',
      );

      db.execute('DROP TABLE app_emulators');
      db.execute('ALTER TABLE app_emulators_new_str RENAME TO app_emulators');

      db.execute('DROP TABLE user_roms');
      db.execute('ALTER TABLE user_roms_new RENAME TO user_roms');

      db.execute('DROP TABLE user_system_settings');
      db.execute(
        'ALTER TABLE user_system_settings_new RENAME TO user_system_settings',
      );

      db.execute('DROP TABLE user_screenscraper_system_config');
      db.execute(
        'ALTER TABLE user_screenscraper_system_config_new RENAME TO user_screenscraper_system_config',
      );

      db.execute('DROP TABLE user_detected_systems');
      db.execute(
        'ALTER TABLE user_detected_systems_new RENAME TO user_detected_systems',
      );

      db.execute('DROP TABLE user_screenscraper_metadata');
      db.execute(
        'ALTER TABLE user_screenscraper_metadata_new RENAME TO user_screenscraper_metadata',
      );

      db.execute('DROP TABLE app_systems');
      db.execute('ALTER TABLE app_systems_new RENAME TO app_systems');

      db.execute('COMMIT');
      _log.i('Migration v48 completed successfully');
    } catch (e, stackTrace) {
      db.execute('ROLLBACK');
      _log.e('Error in migration v48: $e');
      _log.e('   StackTrace: $stackTrace');
      rethrow;
    } finally {
      db.execute('PRAGMA foreign_keys = ON');
    }
  }

  /// Migration v49: Finalizes the transition of emulators to a unique string-based
  /// identification system.
  static Future<void> _migrateToVersion49(Database db) async {
    _log.i(
      'Migration v49: Refactoring app_emulators to use unique_identifier as PK',
    );

    try {
      db.execute('PRAGMA foreign_keys = OFF');
      db.execute('BEGIN TRANSACTION');

      // 1. Create new app_emulators table with unique_identifier as PK
      db.execute('''
        CREATE TABLE app_emulators_new (
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
        )
      ''');
      _log.i('Created app_emulators_new table');

      // 2. Copy data from old table (only rows with unique_identifier)
      db.execute('''
        INSERT INTO app_emulators_new 
        SELECT 
          unique_identifier,
          os_id,
          system_id,
          name,
          is_standalone,
          core_filename,
          is_default,
          is_ra_compatible,
          android_package_name,
          android_activity_name
        FROM app_emulators
        WHERE unique_identifier IS NOT NULL
      ''');
      _log.i('Copied data to app_emulators_new');

      // 3. Create new user_roms table with composite FK to app_emulators
      db.execute('''
        CREATE TABLE user_roms_new (
          app_system_id TEXT NOT NULL,
          app_emulator_unique_id TEXT,
          app_emulator_os_id INTEGER,
          app_alternative_emulators_id INTEGER,
          virtual_folder_name TEXT,
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
          FOREIGN KEY (app_emulator_os_id, app_emulator_unique_id) REFERENCES app_emulators_new(os_id, unique_identifier),
          UNIQUE(rom_path)
        )
      ''');
      _log.i('Created user_roms_new table');

      // 4. Migrate user_roms data (join with old app_emulators to get unique_identifier)
      final info = db.select('PRAGMA table_info(user_roms)');
      final cols = info.map((c) => c['name'].toString()).toList();

      String col49(String name) => cols.contains(name) ? 'r.$name' : 'NULL';

      db.execute('''
        INSERT INTO user_roms_new
        SELECT 
          r.app_system_id,
          e.unique_identifier,
          e.os_id,
          r.app_alternative_emulators_id,
          r.virtual_folder_name,
          r.filename,
          r.rom_path,
          r.ra_hash,
          r.ss_hash,
          r.id_ra,
          r.is_favorite,
          r.play_time,
          r.last_played,
          r.cloud_sync_enabled,
          ${col49('title_id')},
          ${col49('title_name')},
          ${col49('description')},
          ${col49('year')},
          ${col49('developer')},
          ${col49('publisher')},
          ${col49('genre')},
          ${col49('players')},
          r.created_at,
          r.updated_at
        FROM user_roms r
        LEFT JOIN app_emulators e ON r.app_emulators_id = e.id
      ''');
      _log.i('Migrated user_roms data');

      // 5. Drop old tables and rename new ones
      db.execute('DROP TABLE user_roms');
      db.execute('ALTER TABLE user_roms_new RENAME TO user_roms');
      _log.i('Renamed user_roms_new to user_roms');

      db.execute('DROP TABLE app_emulators');
      db.execute('ALTER TABLE app_emulators_new RENAME TO app_emulators');
      _log.i('Renamed app_emulators_new to app_emulators');

      // 6. Drop obsolete user_detected_emulator_path table if it exists
      // This table has a foreign key to the old app_emulators.id which no longer exists
      try {
        db.execute('DROP TABLE IF EXISTS user_detected_emulator_path');
        _log.i('Dropped obsolete user_detected_emulator_path table');
      } catch (e) {
        _log.w('Could not drop user_detected_emulator_path: $e');
      }

      db.execute('COMMIT');
      _log.i('Migration v49 completed successfully');
    } catch (e, stackTrace) {
      db.execute('ROLLBACK');
      _log.e('Error in migration v49: $e');
      _log.e('   StackTrace: $stackTrace');
      rethrow;
    } finally {
      db.execute('PRAGMA foreign_keys = ON');
    }
  }

  /// Migration to version 50: Drop obsolete user_detected_emulator_path table
  static Future<void> _migrateToVersion50(Database db) async {
    _log.i(
      'Migration v50: Dropping obsolete tables with incompatible foreign keys',
    );

    try {
      // Drop obsolete tables that have foreign keys to the old app_emulators.id
      db.execute('DROP TABLE IF EXISTS user_detected_emulator_path');
      _log.i('Dropped obsolete user_detected_emulator_path table');

      db.execute('DROP TABLE IF EXISTS app_alternative_emulators');
      _log.i('Dropped obsolete app_alternative_emulators table');
    } catch (e, stackTrace) {
      _log.e('Error in migration v50: $e');
      _log.e('   StackTrace: $stackTrace');
      // Don't rethrow - this is a cleanup operation
    }
  }

  /// Migration to version 52: Remove obsolete rom_folder column from user_config
  static Future<void> _migrateToVersion52(Database db) async {
    _log.i(
      'Migration v52: Removing obsolete rom_folder column from user_config',
    );

    db.execute('BEGIN TRANSACTION');
    try {
      // 1. Create new table without rom_folder
      db.execute('''
        CREATE TABLE user_config_new (
          id INTEGER PRIMARY KEY CHECK (id = 1),
          last_scan TEXT,
          game_view_mode TEXT DEFAULT 'list',
          system_view_mode TEXT DEFAULT 'grid',
          theme_name TEXT DEFAULT 'system',
          video_sound INTEGER DEFAULT 1,
          ra_user TEXT,
          show_game_info INTEGER DEFAULT 0,
          is_fullscreen INTEGER DEFAULT 1,
          bartop_exit_poweroff INTEGER DEFAULT 0,
          scan_on_startup INTEGER DEFAULT 1,
          setup_completed INTEGER DEFAULT 0
        )
      ''');

      // 2. Copy data from old table
      db.execute('''
        INSERT INTO user_config_new (
          id, last_scan, game_view_mode, system_view_mode, theme_name, 
          video_sound, ra_user, show_game_info, is_fullscreen, 
          bartop_exit_poweroff, scan_on_startup, setup_completed
        )
        SELECT 
          id, last_scan, game_view_mode, system_view_mode, theme_name, 
          video_sound, ra_user, show_game_info, is_fullscreen, 
          bartop_exit_poweroff, scan_on_startup, setup_completed
        FROM user_config
      ''');

      // 3. Drop old table and rename new one
      db.execute('DROP TABLE user_config');
      db.execute('ALTER TABLE user_config_new RENAME TO user_config');

      db.execute('COMMIT');
      _log.i('Migration v52 completed successfully');
    } catch (e, stackTrace) {
      db.execute('ROLLBACK');
      _log.e('Error in migration v52: $e');
      _log.e('   StackTrace: $stackTrace');
      rethrow;
    }
  }

  /// Migration to version 53: Reset setup if legacy (non-SAF) ROM paths are detected
  static Future<void> _migrateToVersion53(Database db) async {
    _log.i('Migration v53: Checking for legacy ROM paths');

    try {
      final results = db.select('SELECT path FROM user_rom_folders');
      bool hasLegacyPath = false;

      for (final row in results) {
        final path = row['path']?.toString() ?? '';
        if (path.isNotEmpty && !path.startsWith('content://')) {
          hasLegacyPath = true;
          _log.w('Legacy path detected: $path');
          break;
        }
      }

      if (hasLegacyPath) {
        _log.i('Resetting setup for legacy paths...');
        db.execute('BEGIN TRANSACTION');
        try {
          // Clear ROM folders
          db.execute('DELETE FROM user_rom_folders');

          // Reset setup_completed in user_config
          db.execute('UPDATE user_config SET setup_completed = 0');

          db.execute('COMMIT');
          _log.i(
            'Setup reset successfully. User will see SetupWizard on next launch.',
          );
        } catch (e) {
          db.execute('ROLLBACK');
          _log.e('Error resetting setup: $e');
          rethrow;
        }
      } else {
        _log.i('No legacy paths detected. Skipping reset.');
      }
    } catch (e) {
      _log.e('Error during v53 detection: $e');
      // If table doesn't exist, it's fine
    }
  }

  /// Migration to version 54: Add short_name column to app_systems
  static Future<void> _migrateToVersion54(Database db) async {
    _log.i('Migration v54: Adding short_name column to app_systems');

    try {
      final tableInfo = db.select('PRAGMA table_info(app_systems)');
      final columns = tableInfo.map((c) => c['name'].toString()).toList();

      if (!columns.contains('short_name')) {
        db.execute('ALTER TABLE app_systems ADD COLUMN short_name TEXT');
        _log.i('Column short_name added to app_systems');
      } else {
        _log.i('Column short_name already exists');
      }

      _log.i('Migration v54 completed');
    } catch (e, stackTrace) {
      _log.e('Error in migration v54: $e');
      _log.e('   StackTrace: $stackTrace');
      rethrow;
    }
  }

  /// Migration to version 55: Add neosync_json to app_systems
  static Future<void> _migrateToVersion55(Database db) async {
    _log.i('Migration v55: Adding neosync_json to app_systems');

    try {
      final tableInfo = db.select('PRAGMA table_info(app_systems)');
      final columns = tableInfo.map((c) => c['name'].toString()).toList();

      if (!columns.contains('neosync_json')) {
        db.execute('ALTER TABLE app_systems ADD COLUMN neosync_json TEXT');
        _log.i('Column neosync_json added to app_systems');
      }

      _log.i('Migration v55 completed');
    } catch (e, stackTrace) {
      _log.e('Error in migration v55: $e');
      _log.e('   StackTrace: $stackTrace');
      rethrow;
    }
  }

  /// Migration to version 56: Drop app_emulator_possible_paths
  static Future<void> _migrateToVersion56(Database db) async {
    _log.i('Migration v56: Dropping app_emulator_possible_paths');

    try {
      db.execute('DROP TABLE IF EXISTS app_emulator_possible_paths');
      _log.i('Table app_emulator_possible_paths dropped');

      _log.i('Migration v56 completed');
    } catch (e, stackTrace) {
      _log.e('Error in migration v56: $e');
      _log.e('   StackTrace: $stackTrace');
      rethrow;
    }
  }

  /// Migration to version 57: Drop app_arcade_names table
  static Future<void> _migrateToVersion57(Database db) async {
    _log.i('Migration v57: Dropping app_arcade_names table');

    try {
      db.execute('DROP TABLE IF EXISTS app_arcade_names');
      _log.i('Table app_arcade_names dropped');
    } catch (e, stackTrace) {
      _log.e('Error in migration v57: $e');
      _log.e('   StackTrace: $stackTrace');
      rethrow;
    }
  }

  /// Migration v58: Adds the [app_neo_sync_state] table for precise cloud save
  /// synchronization tracking.
  static Future<void> _migrateToVersion58(Database db) async {
    _log.i('Migration v58: Adding app_neo_sync_state table');

    try {
      final tableExists = db.select('''
        SELECT name FROM sqlite_master 
        WHERE type='table' AND name='app_neo_sync_state'
        LIMIT 1
      ''');

      if (tableExists.isEmpty) {
        db.execute('''
          CREATE TABLE app_neo_sync_state (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            file_path TEXT NOT NULL UNIQUE,
            local_modified_at INTEGER NOT NULL,
            cloud_updated_at INTEGER NOT NULL,
            file_size INTEGER NOT NULL,
            file_hash TEXT
          )
        ''');

        db.execute('''
          CREATE INDEX idx_neo_sync_state_file_path 
          ON app_neo_sync_state(file_path)
        ''');

        _log.i('Table app_neo_sync_state created gracefully');
      } else {
        _log.i('Table app_neo_sync_state already exists');
      }
    } catch (e, stackTrace) {
      _log.e('Error in migration v58: $e');
      _log.e('   StackTrace: $stackTrace');
      rethrow;
    }
  }

  /// Migration to version 59: Add color1 and color2 to app_systems
  static Future<void> _migrateToVersion59(Database db) async {
    _log.i('Migration v59: Adding color columns to app_systems');

    try {
      final tableInfo = db.select('PRAGMA table_info(app_systems)');
      final columns = tableInfo.map((c) => c['name'].toString()).toList();

      if (!columns.contains('color1')) {
        db.execute('ALTER TABLE app_systems ADD COLUMN color1 TEXT');
        _log.i('Column color1 added to app_systems');
      }
      if (!columns.contains('color2')) {
        db.execute('ALTER TABLE app_systems ADD COLUMN color2 TEXT');
        _log.i('Column color2 added to app_systems');
      }

      _log.i('Migration v59 completed');
    } catch (e, stackTrace) {
      _log.e('Error in migration v59: $e');
      _log.e('   StackTrace: $stackTrace');
      rethrow;
    }
  }

  /// Migration v61: Refactors system settings to support unified background paths
  /// and logo visibility.
  static Future<void> _migrateToVersion61(Database db) async {
    _log.i('Migration v61: Updating user_system_settings schema');

    try {
      // 1. Check if table exists
      final tableExists = db.select('''
        SELECT name FROM sqlite_master WHERE type='table' AND name='user_system_settings'
      ''');

      if (tableExists.isEmpty) {
        _log.w(
          'Migration v61: user_system_settings table does not exist, skipping',
        );
        return;
      }

      // 2. Create temporary table with new schema
      db.execute('''
        CREATE TABLE user_system_settings_new (
          app_system_id TEXT NOT NULL,
          recursive_scan INTEGER DEFAULT 1,
          hide_extension INTEGER DEFAULT 0,
          hide_parentheses INTEGER DEFAULT 0,
          hide_brackets INTEGER DEFAULT 0,
          custom_background_path TEXT,
          hide_logo INTEGER DEFAULT 0,
          updated_at TEXT DEFAULT CURRENT_TIMESTAMP,
          FOREIGN KEY (app_system_id) REFERENCES app_systems(id) ON DELETE CASCADE,
          UNIQUE(app_system_id)
        )
      ''');

      // 3. Copy data from old table to new table
      // Map custom_grid_logo to custom_background_path
      db.execute('''
        INSERT INTO user_system_settings_new (
          app_system_id, 
          recursive_scan, 
          hide_extension, 
          hide_parentheses, 
          hide_brackets, 
          custom_background_path, 
          updated_at
        )
        SELECT 
          app_system_id, 
          recursive_scan, 
          hide_extension, 
          hide_parentheses, 
          hide_brackets, 
          custom_grid_logo, 
          updated_at
        FROM user_system_settings
      ''');

      // 4. Drop old table
      db.execute('DROP TABLE user_system_settings');

      // 5. Rename new table to original name
      db.execute(
        'ALTER TABLE user_system_settings_new RENAME TO user_system_settings',
      );

      _log.i('Migration v61 completed successfully');
    } catch (e, stackTrace) {
      _log.e('Error in migration v61: $e');
      _log.e('   StackTrace: $stackTrace');
      rethrow;
    }
  }

  /// Migration to version 62: Add hide_bottom_screen to user_config
  static Future<void> _migrateToVersion62(Database db) async {
    _log.i('Migration v62: Adding hide_bottom_screen to user_config');

    try {
      final hasColumn = await _columnExists(
        db,
        'user_config',
        'hide_bottom_screen',
      );

      if (!hasColumn) {
        db.execute('''
          ALTER TABLE user_config 
          ADD COLUMN hide_bottom_screen INTEGER DEFAULT 0
        ''');
        _log.i('Column hide_bottom_screen added to user_config');
      } else {
        _log.i('Column hide_bottom_screen already exists');
      }
    } catch (e, stackTrace) {
      _log.e('Error in migration v62: $e');
      _log.e('   StackTrace: $stackTrace');
      rethrow;
    }
  }

  /// Migration to version 63: Set default recursive scan to 1 for all systems
  static Future<void> _migrateToVersion63(Database db) async {
    _log.i('Migration v63: Setting default recursive scan to 1');

    try {
      db.execute('''
        UPDATE user_system_settings 
        SET recursive_scan = 1
      ''');
      _log.i('Default recursive scan set to 1 for all systems');
    } catch (e, stackTrace) {
      _log.e('Error in migration v63: $e');
      _log.e('   StackTrace: $stackTrace');
      rethrow;
    }
  }

  /// Migration to version 64: Set default ROM display settings to 1 for all systems
  static Future<void> _migrateToVersion64(Database db) async {
    _log.i('Migration v64: Setting default ROM display settings to 1');

    try {
      db.execute('''
        UPDATE user_system_settings 
        SET hide_extension = 1,
            hide_parentheses = 1,
            hide_brackets = 1
      ''');
      _log.i('Default ROM display settings set to 1 for all systems');
    } catch (e, stackTrace) {
      _log.e('Error in migration v64: $e');
      _log.e('   StackTrace: $stackTrace');
      rethrow;
    }
  }

  /// Migration v65: Registers the virtual "All Systems" collection into the database.
  static Future<void> _migrateToVersion65(Database db) async {
    _log.i('Migration v65: Adding virtual system "All"');

    try {
      db.execute('''
        INSERT OR IGNORE INTO app_systems (id, screenscraper_id, ra_id, real_name, folder_name, launch_date, description)
        VALUES ('all', 0, 0, 'All Systems', 'all', '2024-01-01', 
                'Collection of all systems available in NeoStation.')
      ''');
      _log.i('System "All" registered in app_systems');
    } catch (e, stackTrace) {
      _log.e('Error in migration v65: $e');
      _log.e('   StackTrace: $stackTrace');
      rethrow;
    }
  }

  /// Migration to version 66: Fix 'all' system ID and ensure settings are preserved
  static Future<void> _migrateToVersion66(Database db) async {
    _log.i('Migration v66: Fixing system "All" ID compatibility');

    try {
      // 1. Check if we have the 9999 ID
      db.execute('''
        UPDATE app_systems SET id = 'all' WHERE id = '9999' AND folder_name = 'all'
      ''');

      // 2. Fix settings table
      db.execute('''
        UPDATE user_system_settings SET app_system_id = 'all' WHERE app_system_id = '9999'
      ''');

      // 3. Ensure "all" system exists (if it wasn't added in v65 or if it was deleted)
      db.execute('''
        INSERT OR IGNORE INTO app_systems (id, screenscraper_id, ra_id, real_name, folder_name, launch_date, description)
        VALUES ('all', 0, 0, 'All Systems', 'all', '2024-01-01', 
                'Collection of all systems available in NeoStation.')
      ''');

      _log.i('Migration v66 completed: "All" system ID is now "all"');
    } catch (e, stackTrace) {
      _log.e('Error in migration v66: $e');
      _log.e('   StackTrace: $stackTrace');
      rethrow;
    }
  }

  /// Migration to version 67: Ensure 'all' system is always in user_detected_systems
  static Future<void> _migrateToVersion67(Database db) async {
    _log.i('Migration v67: Ensuring "All" system is in user_detected_systems');

    try {
      // 1. Ensure it exists in app_systems (safety net)
      db.execute('''
        INSERT OR IGNORE INTO app_systems (id, screenscraper_id, ra_id, real_name, folder_name, launch_date, description)
        VALUES ('all', 0, 0, 'All Systems', 'all', '2024-01-01', 
                'Collection of all systems available in NeoStation.')
      ''');

      // 2. Insert into user_detected_systems if not present
      db.execute('''
        INSERT OR IGNORE INTO user_detected_systems (app_system_id, actual_folder_name)
        VALUES ('all', 'all')
      ''');

      _log.i(
        'Migration v67 completed: "All" system is now persistently detected',
      );
    } catch (e, stackTrace) {
      _log.e('Error in migration v67: $e');
      _log.e('   StackTrace: $stackTrace');
      rethrow;
    }
  }

  /// Migration to version 68: Ensure user_config columns are up to date
  static Future<void> _migrateToVersion68(Database db) async {
    _log.i('Migration v68: Ensuring user_config columns are up to date');

    try {
      final tableInfo = db.select('PRAGMA table_info(user_config)');
      final columns = tableInfo.map((c) => c['name'].toString()).toList();

      if (!columns.contains('bartop_exit_poweroff')) {
        db.execute(
          'ALTER TABLE user_config ADD COLUMN bartop_exit_poweroff INTEGER DEFAULT 0',
        );
        _log.i('Column bartop_exit_poweroff added');
      }
      if (!columns.contains('scan_on_startup')) {
        db.execute(
          'ALTER TABLE user_config ADD COLUMN scan_on_startup INTEGER DEFAULT 1',
        );
        _log.i('Column scan_on_startup added');
      }
      if (!columns.contains('hide_bottom_screen')) {
        db.execute(
          'ALTER TABLE user_config ADD COLUMN hide_bottom_screen INTEGER DEFAULT 0',
        );
        _log.i('Column hide_bottom_screen added');
      }
      if (!columns.contains('sfx_enabled')) {
        db.execute(
          'ALTER TABLE user_config ADD COLUMN sfx_enabled INTEGER DEFAULT 1',
        );
        _log.i('Column sfx_enabled added');
      }

      _log.i('Migration v68 completed');
    } catch (e, stackTrace) {
      _log.e('Error in migration v68: $e');
      _log.e('   StackTrace: $stackTrace');
      rethrow;
    }
  }

  /// Migration to version 69: Add prefer_file_name column to user_system_settings
  static Future<void> _migrateToVersion69(Database db) async {
    _log.i('Migration v69: Adding prefer_file_name to user_system_settings');

    try {
      final tableExists = db.select('''
        SELECT name FROM sqlite_master WHERE type='table' AND name='user_system_settings'
      ''');

      if (tableExists.isEmpty) {
        _log.w(
          'Migration v69: user_system_settings table does not exist, skipping',
        );
        return;
      }

      final tableInfo = db.select('PRAGMA table_info(user_system_settings)');
      final columns = tableInfo.map((c) => c['name'].toString()).toList();

      if (!columns.contains('prefer_file_name')) {
        db.execute(
          'ALTER TABLE user_system_settings ADD COLUMN prefer_file_name INTEGER DEFAULT 0',
        );
        _log.i('Column prefer_file_name added to user_system_settings');
      } else {
        _log.i('Column prefer_file_name already exists');
      }

      _log.i('Migration v69 completed');
    } catch (e, stackTrace) {
      _log.e('Error in migration v69: $e');
      _log.e('   StackTrace: $stackTrace');
      rethrow;
    }
  }

  /// Migration to version 70: Add system sorting preferences to user_config
  static Future<void> _migrateToVersion70(Database db) async {
    _log.i('Migration v70: Adding system sorting preferences to user_config');

    try {
      final tableInfo = db.select('PRAGMA table_info(user_config)');
      final columns = tableInfo.map((c) => c['name'].toString()).toList();

      if (!columns.contains('system_sort_by')) {
        db.execute(
          'ALTER TABLE user_config ADD COLUMN system_sort_by TEXT DEFAULT \'alphabetical\'',
        );
        _log.i('Column system_sort_by added to user_config');
      }

      if (!columns.contains('system_sort_order')) {
        db.execute(
          'ALTER TABLE user_config ADD COLUMN system_sort_order TEXT DEFAULT \'asc\'',
        );
        _log.i('Column system_sort_order added to user_config');
      }

      _log.i('Migration v70 completed');
    } catch (e, stackTrace) {
      _log.e('Error in migration v70: $e');
      _log.e('   StackTrace: $stackTrace');
      rethrow;
    }
  }

  static Future<void> _migrateToVersion71(Database db) async {
    _log.i(
      'Migration v71: Ensure system sorting columns exist (fix for devices that skipped v70 migration)',
    );

    try {
      final tableInfo = db.select('PRAGMA table_info(user_config)');
      final columns = tableInfo.map((c) => c['name'].toString()).toList();

      if (!columns.contains('system_sort_by')) {
        db.execute(
          'ALTER TABLE user_config ADD COLUMN system_sort_by TEXT DEFAULT \'alphabetical\'',
        );
        _log.i('Column system_sort_by added to user_config');
      }

      if (!columns.contains('system_sort_order')) {
        db.execute(
          'ALTER TABLE user_config ADD COLUMN system_sort_order TEXT DEFAULT \'asc\'',
        );
        _log.i('Column system_sort_order added to user_config');
      }

      _log.i('Migration v71 completed');
    } catch (e, stackTrace) {
      _log.e('Error in migration v71: $e');
      _log.e('   StackTrace: $stackTrace');
      rethrow;
    }
  }

  static Future<void> _migrateToVersion72(Database db) async {
    _log.i('Migration v72: Add app_language column to user_config');

    try {
      final tableInfo = db.select('PRAGMA table_info(user_config)');
      final columns = tableInfo.map((c) => c['name'].toString()).toList();

      if (!columns.contains('app_language')) {
        db.execute(
          "ALTER TABLE user_config ADD COLUMN app_language TEXT DEFAULT 'en'",
        );
        _log.i('Column app_language added to user_config');
      }

      _log.i('Migration v72 completed');
    } catch (e, stackTrace) {
      _log.e('Error in migration v72: $e');
      _log.e('   StackTrace: $stackTrace');
      rethrow;
    }
  }

  static Future<void> _migrateToVersion73(Database db) async {
    _log.i(
      'Migration v73: Add custom_logo_path to user_system_settings and active_theme to user_config',
    );

    try {
      final settingsInfo = db.select('PRAGMA table_info(user_system_settings)');
      final settingsCols = settingsInfo
          .map((c) => c['name'].toString())
          .toList();

      if (!settingsCols.contains('custom_logo_path')) {
        db.execute(
          'ALTER TABLE user_system_settings ADD COLUMN custom_logo_path TEXT',
        );
        _log.i('Column custom_logo_path added to user_system_settings');
      }

      final configInfo = db.select('PRAGMA table_info(user_config)');
      final configCols = configInfo.map((c) => c['name'].toString()).toList();

      if (!configCols.contains('active_theme')) {
        db.execute(
          "ALTER TABLE user_config ADD COLUMN active_theme TEXT DEFAULT ''",
        );
        _log.i('Column active_theme added to user_config');
      }

      _log.i('Migration v73 completed');
    } catch (e, stackTrace) {
      _log.e('Error in migration v73: $e');
      _log.e('   StackTrace: $stackTrace');
      rethrow;
    }
  }

  static Future<void> _migrateToVersion75(Database db) async {
    _log.i(
      'Migration v75: Add is_hidden to user_detected_systems and hide_recent_card to user_config',
    );

    try {
      final detectedInfo = db.select(
        'PRAGMA table_info(user_detected_systems)',
      );
      final detectedCols = detectedInfo
          .map((c) => c['name'].toString())
          .toList();

      if (!detectedCols.contains('is_hidden')) {
        db.execute(
          'ALTER TABLE user_detected_systems ADD COLUMN is_hidden INTEGER DEFAULT 0',
        );
        _log.i('Column is_hidden added to user_detected_systems');
      }

      final configInfo = db.select('PRAGMA table_info(user_config)');
      final configCols = configInfo.map((c) => c['name'].toString()).toList();

      if (!configCols.contains('hide_recent_card')) {
        db.execute(
          'ALTER TABLE user_config ADD COLUMN hide_recent_card INTEGER DEFAULT 0',
        );
        _log.i('Column hide_recent_card added to user_config');
      }

      _log.i('Migration v75 completed');
    } catch (e, stackTrace) {
      _log.e('Error in migration v75: $e');
      _log.e('   StackTrace: $stackTrace');
      rethrow;
    }
  }

  static Future<void> _migrateToVersion76(Database db) async {
    _log.i('Migration v76: Add active_sync_provider column to user_config');
    try {
      final tableInfo = db.select('PRAGMA table_info(user_config)');
      final columns = tableInfo.map((c) => c['name'].toString()).toList();

      if (!columns.contains('active_sync_provider')) {
        db.execute(
          "ALTER TABLE user_config ADD COLUMN active_sync_provider TEXT DEFAULT 'neosync'",
        );
        _log.i('Column active_sync_provider added to user_config');
      }

      _log.i('Migration v76 completed');
    } catch (e, stackTrace) {
      _log.e('Error in migration v76: $e');
      _log.e('   StackTrace: $stackTrace');
      rethrow;
    }
  }

  static Future<void> _migrateToVersion74(Database db) async {
    _log.i('Migration v74: Add manufacturer and type columns to app_systems');

    try {
      final tableInfo = db.select('PRAGMA table_info(app_systems)');
      final columns = tableInfo.map((c) => c['name'].toString()).toList();

      if (!columns.contains('manufacturer')) {
        db.execute('ALTER TABLE app_systems ADD COLUMN manufacturer TEXT');
        _log.i('Column manufacturer added to app_systems');
      }

      if (!columns.contains('type')) {
        db.execute('ALTER TABLE app_systems ADD COLUMN type TEXT');
        _log.i('Column type added to app_systems');
      }

      _log.i('Migration v74 completed');
    } catch (e, stackTrace) {
      _log.e('Error in migration v74: $e');
      _log.e('   StackTrace: $stackTrace');
      rethrow;
    }
  }

  // Migration v77: Defensive catch-up for user_config columns that may be
  // missing on DBs that were at version >=72 before migration 72 was corrected.
  static Future<void> _migrateToVersion78(Database db) async {
    _log.i('Migration v78: Add systems_version to user_config');
    try {
      final tableInfo = db.select('PRAGMA table_info(user_config)');
      final columns = tableInfo.map((c) => c['name'].toString()).toList();
      if (!columns.contains('systems_version')) {
        db.execute(
          "ALTER TABLE user_config ADD COLUMN systems_version TEXT DEFAULT ''",
        );
        _log.i('Column systems_version added to user_config');
      }
      _log.i('Migration v78 completed');
    } catch (e, stackTrace) {
      _log.e('Error in migration v78: $e');
      _log.e('   StackTrace: $stackTrace');
      rethrow;
    }
  }

  static Future<void> _migrateToVersion77(Database db) async {
    _log.i('Migration v77: Ensure all user_config columns exist');

    try {
      final tableInfo = db.select('PRAGMA table_info(user_config)');
      final columns = tableInfo.map((c) => c['name'].toString()).toList();

      if (!columns.contains('app_language')) {
        db.execute(
          "ALTER TABLE user_config ADD COLUMN app_language TEXT DEFAULT 'en'",
        );
        _log.i('Column app_language added to user_config');
      }

      if (!columns.contains('active_theme')) {
        db.execute(
          "ALTER TABLE user_config ADD COLUMN active_theme TEXT DEFAULT ''",
        );
        _log.i('Column active_theme added to user_config');
      }

      if (!columns.contains('hide_recent_card')) {
        db.execute(
          'ALTER TABLE user_config ADD COLUMN hide_recent_card INTEGER DEFAULT 0',
        );
        _log.i('Column hide_recent_card added to user_config');
      }

      if (!columns.contains('active_sync_provider')) {
        db.execute(
          "ALTER TABLE user_config ADD COLUMN active_sync_provider TEXT DEFAULT 'neosync'",
        );
        _log.i('Column active_sync_provider added to user_config');
      }

      _log.i('Migration v77 completed');
    } catch (e, stackTrace) {
      _log.e('Error in migration v77: $e');
      _log.e('   StackTrace: $stackTrace');
      rethrow;
    }
  }
}
