import 'package:sqlite3/sqlite3.dart' as sqlite;
import 'package:neostation/data/datasources/sqlite_service.dart';

/// Helper for setting up an in-memory SQLite database for repository tests.
class DatabaseTestHelper {
  late sqlite.Database _db;
  late DatabaseAdapter _adapter;

  /// Initializes a fresh in-memory database and injects it into [SqliteService].
  Future<DatabaseAdapter> setUp() async {
    _db = sqlite.sqlite3.openInMemory();
    _adapter = DatabaseAdapter(_db);
    SqliteService.setTestingDatabase(_adapter);
    await createMinimalSchema(_adapter);
    return _adapter;
  }

  /// Closes the in-memory database and resets [SqliteService].
  Future<void> tearDown() async {
    _db.close();
    // Reset the singleton so subsequent tests get a fresh instance.
    SqliteService.setTestingDatabase(
      DatabaseAdapter(sqlite.sqlite3.openInMemory()),
    );
  }

  /// Creates the minimal set of tables required by repository tests.
  Future<void> createMinimalSchema(DatabaseAdapter db) async {
    await db.execute('''
      CREATE TABLE app_systems (
        id TEXT PRIMARY KEY,
        real_name TEXT,
        folder_name TEXT,
        screenscraper_id INTEGER,
        ra_id TEXT,
        short_name TEXT,
        description TEXT,
        launch_date TEXT,
        manufacturer TEXT,
        type TEXT,
        color1 TEXT,
        color2 TEXT,
        neosync_json TEXT
      )
    ''');

    await db.execute('''
      CREATE TABLE app_system_folders (
        system_id TEXT,
        folder_name TEXT
      )
    ''');

    await db.execute('''
      CREATE TABLE app_system_extensions (
        system_id TEXT,
        extension TEXT
      )
    ''');

    await db.execute('''
      CREATE TABLE user_roms (
        filename TEXT,
        rom_path TEXT PRIMARY KEY,
        title_name TEXT,
        title_id TEXT,
        app_system_id TEXT,
        ra_hash TEXT,
        id_ra INTEGER,
        is_favorite INTEGER DEFAULT 0,
        play_time INTEGER DEFAULT 0,
        last_played TEXT,
        created_at TEXT,
        updated_at TEXT,
        app_emulator_unique_id TEXT,
        app_emulator_os_id INTEGER
      )
    ''');

    await db.execute('''
      CREATE TABLE user_config (
        id INTEGER PRIMARY KEY DEFAULT 1,
        last_scan TEXT,
        system_view_mode TEXT,
        theme_name TEXT,
        palette_name TEXT,
        video_sound INTEGER,
        ra_user TEXT,
        show_game_info INTEGER,
        is_fullscreen INTEGER,
        bartop_exit_poweroff INTEGER,
        scan_on_startup INTEGER,
        ignore_hidden_files INTEGER DEFAULT 1,
        setup_completed INTEGER,
        hide_bottom_screen INTEGER,
        sfx_enabled INTEGER,
        system_sort_by TEXT,
        system_sort_order TEXT,
        app_language TEXT,
        active_theme TEXT,
        hide_recent_card INTEGER,
        active_sync_provider TEXT,
        game_view_mode TEXT,
        rom_folders TEXT,
        systems_version TEXT,
        neostation_app_version TEXT,
        auto_update_app INTEGER,
        auto_update_systems INTEGER
      )
    ''');

    await db.execute('''
      CREATE TABLE user_rom_folders (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        path TEXT
      )
    ''');

    await db.execute('''
      CREATE TABLE app_emulators (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        system_id TEXT,
        os_id INTEGER,
        name TEXT,
        unique_identifier TEXT,
        is_standalone INTEGER,
        core_filename TEXT,
        android_package_name TEXT,
        is_default INTEGER,
        is_ra_compatible INTEGER
      )
    ''');

    await db.execute('''
      CREATE TABLE user_emulator_config (
        emulator_unique_id TEXT PRIMARY KEY,
        emulator_path TEXT,
        is_user_default INTEGER
      )
    ''');

    await db.execute('''
      CREATE TABLE app_os (
        id INTEGER PRIMARY KEY,
        name TEXT
      )
    ''');

    await db.execute('''
      CREATE TABLE user_detected_systems (
        app_system_id TEXT PRIMARY KEY,
        actual_folder_name TEXT,
        is_hidden INTEGER DEFAULT 0
      )
    ''');

    await db.execute('''
      CREATE TABLE user_system_settings (
        app_system_id TEXT PRIMARY KEY,
        recursive_scan INTEGER DEFAULT 1,
        hide_extension INTEGER DEFAULT 1,
        hide_parentheses INTEGER DEFAULT 1,
        hide_brackets INTEGER DEFAULT 1,
        hide_logo INTEGER DEFAULT 0,
        prefer_file_name INTEGER DEFAULT 0,
        custom_background_path TEXT,
        custom_logo_path TEXT,
        updated_at TEXT
      )
    ''');

    await db.execute('''
      CREATE TABLE app_ra_game_list (
        hash TEXT,
        game_id INTEGER,
        console_id TEXT,
        console_name TEXT,
        title TEXT
      )
    ''');

    await db.execute('''
      CREATE TABLE user_screenscraper_credentials (
        id INTEGER PRIMARY KEY DEFAULT 1,
        username TEXT,
        password TEXT,
        user_id TEXT,
        level TEXT,
        contribution TEXT,
        maxthreads TEXT,
        requests_today INTEGER,
        max_requests_per_day INTEGER,
        requests_ko_today INTEGER,
        max_requests_ko_per_day INTEGER,
        max_download_speed INTEGER,
        visites INTEGER,
        last_visit TEXT,
        fav_region TEXT,
        preferred_language TEXT
      )
    ''');

    await db.execute('''
      CREATE TABLE user_screenscraper_config (
        id INTEGER PRIMARY KEY DEFAULT 1,
        scrape_mode TEXT,
        scrape_metadata INTEGER,
        scrape_images INTEGER,
        scrape_videos INTEGER,
        updated_at TEXT
      )
    ''');
    await db.execute(
      "INSERT INTO user_screenscraper_config (id, scrape_mode, scrape_metadata, scrape_images, scrape_videos) VALUES (1, 'new_only', 1, 1, 1)",
    );

    await db.execute('''
      CREATE TABLE user_screenscraper_system_config (
        app_system_id TEXT PRIMARY KEY,
        enabled INTEGER
      )
    ''');

    await db.execute('''
      CREATE TABLE user_screenscraper_metadata (
        app_system_id TEXT NOT NULL,
        filename TEXT NOT NULL,
        id_ra INTEGER,
        real_name TEXT,
        title TEXT,
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
        updated_at TEXT,
        UNIQUE(app_system_id, filename)
      )
    ''');

    await db.execute('''
      CREATE TABLE app_neo_sync_state (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        file_path TEXT NOT NULL UNIQUE,
        local_modified_at INTEGER NOT NULL,
        cloud_updated_at INTEGER NOT NULL,
        file_size INTEGER NOT NULL,
        file_hash TEXT
      )
    ''');
  }
}
