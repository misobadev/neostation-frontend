import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;
import 'package:neostation/data/datasources/sqlite_migrations.dart';
import 'package:neostation/data/datasources/sqlite_service.dart';

/// Helper for setting up an in-memory SQLite database for repository tests.
class DatabaseTestHelper {
  late sqlite.Database _db;
  late DatabaseAdapter _adapter;

  /// Initializes a fresh in-memory database and injects it into [SqliteService].
  Future<DatabaseAdapter> setUp() async {
    SharedPreferences.setMockInitialValues({});
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
        ra_hash_algo TEXT,
        ra_hash_mode TEXT,
        short_name TEXT,
        description TEXT,
        launch_date TEXT,
        manufacturer TEXT,
        type TEXT,
        color1 TEXT,
        color2 TEXT,
        multidisc INTEGER NOT NULL DEFAULT 0,
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
        description TEXT,
        year TEXT,
        developer TEXT,
        publisher TEXT,
        genre TEXT,
        players TEXT,
        app_system_id TEXT,
        ra_hash TEXT,
        ss_hash TEXT,
        rom_crc32 TEXT,
        rom_size INTEGER,
        rom_fingerprint_skipped TEXT,
        id_ra INTEGER,
        ra_match_source TEXT,
        ra_hash_skipped TEXT,
        is_favorite INTEGER DEFAULT 0,
        is_hidden INTEGER DEFAULT 0,
        play_time INTEGER DEFAULT 0,
        last_played TEXT,
        cloud_sync_enabled INTEGER DEFAULT 0,
        created_at TEXT,
        updated_at TEXT,
        app_emulator_unique_id TEXT,
        app_emulator_os_id INTEGER,
        app_alternative_emulators_id INTEGER,
        box2d_aspect_ratio TEXT
      )
    ''');

    await db.execute('''
      -- Mirrors the production user_config (sqlite_service.dart) closely enough
      -- that writes behave the same: the CHECK makes the row a real singleton
      -- (saveUserConfig's WHERE-less UPDATE relies on it) and the DEFAULTs are
      -- what a bare `INSERT INTO user_config (id) VALUES (1)` falls back to.
      -- Without both, tests of the write path pass against a table that cannot
      -- reproduce production behaviour.
      CREATE TABLE user_config (
        id INTEGER PRIMARY KEY CHECK (id = 1),
        last_scan TEXT,
        system_view_mode TEXT DEFAULT 'grid',
        theme_name TEXT DEFAULT 'system',
        video_sound INTEGER DEFAULT 1,
        ra_user TEXT,
        show_game_info INTEGER DEFAULT 0,
        is_fullscreen INTEGER DEFAULT 1,
        bartop_exit_poweroff INTEGER DEFAULT 0,
        scan_on_startup INTEGER DEFAULT 1,
        ignore_hidden_files INTEGER DEFAULT 1,
        setup_completed INTEGER DEFAULT 0,
        hide_bottom_screen INTEGER DEFAULT 0,
        sfx_enabled INTEGER DEFAULT 1,
        sfx_volume REAL DEFAULT 0.75,
        system_sort_by TEXT DEFAULT 'alphabetical',
        system_sort_order TEXT DEFAULT 'asc',
        collection_sort_by TEXT DEFAULT 'name',
        collection_sort_order TEXT DEFAULT 'asc',
        app_language TEXT DEFAULT 'en',
        active_theme TEXT DEFAULT '',
        hide_recent_card INTEGER DEFAULT 0,
        recent_card_size TEXT DEFAULT 'default',
        active_sync_provider TEXT DEFAULT 'neosync',
        game_view_mode TEXT DEFAULT 'list',
        rom_folders TEXT,
        systems_version TEXT DEFAULT '',
        neostation_app_version TEXT DEFAULT '',
        auto_update_app INTEGER DEFAULT 1,
        auto_update_systems INTEGER DEFAULT 1,
        system_grid_columns TEXT DEFAULT 'M',
        use_12_hour_clock INTEGER DEFAULT 0,
        game_details_tab TEXT DEFAULT 'wheel',
        esde_folder_path TEXT,
        -- Kept in step with the real user_config (sqlite_service.dart) so a
        -- whole-row write via SqliteConfigService.saveConfig works in tests.
        legend_hidden INTEGER DEFAULT 0,
        hide_tab_sync INTEGER DEFAULT 0,
        hide_tab_achievements INTEGER DEFAULT 0,
        hide_tab_scraper INTEGER DEFAULT 0,
        hide_tab_romm INTEGER DEFAULT 0,
        hide_tab_search INTEGER DEFAULT 0,
        game_grid_columns TEXT DEFAULT 'M',
        game_carousel_card_style TEXT DEFAULT 'fanart',
        dock_apps TEXT,
        dock_enabled INTEGER DEFAULT 1,
        dock_slot_count INTEGER DEFAULT 3,
        now_playing_dim_delay INTEGER DEFAULT 3,
        now_playing_dim_level INTEGER DEFAULT 100,
        fanart_dim_level INTEGER DEFAULT 25,
        show_achievements_badge INTEGER DEFAULT 0,
        show_cloud_sync_icon INTEGER DEFAULT 1,
        ra_match_on_startup INTEGER DEFAULT 0,
        subfolder_view_all INTEGER DEFAULT 0,
        hide_system_logos INTEGER DEFAULT 0,
        neoglass_blur INTEGER DEFAULT 0,
        neoglass_transparency INTEGER DEFAULT 10,
        neoglass_border_width REAL DEFAULT 2
      )
    ''');

    await db.execute('''
      CREATE TABLE user_rom_folders (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        path TEXT
      )
    ''');

    await db.execute('''
      CREATE TABLE user_custom_save_folders (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        system_folder_name TEXT NOT NULL,
        emulator_slug TEXT NOT NULL,
        folder_path TEXT NOT NULL,
        UNIQUE(system_folder_name, emulator_slug)
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
        android_activity_name TEXT,
        is_default INTEGER,
        is_default_core INTEGER,
        is_default_standalone INTEGER NOT NULL DEFAULT 0,
        is_ra_compatible INTEGER,
        neosync_slug TEXT
      )
    ''');

    await db.execute('''
      CREATE TABLE user_emulator_config (
        emulator_unique_id TEXT PRIMARY KEY,
        emulator_path TEXT,
        is_user_default INTEGER,
        created_at TEXT DEFAULT CURRENT_TIMESTAMP,
        updated_at TEXT DEFAULT CURRENT_TIMESTAMP
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
        subfolder_view INTEGER DEFAULT 0,
        custom_background_path TEXT,
        custom_logo_path TEXT,
        esde_media_dir TEXT,
        updated_at TEXT
      )
    ''');

    await db.execute('''
      CREATE TABLE app_ra_game_list (
        id INTEGER,
        hash TEXT,
        game_id INTEGER,
        console_id TEXT,
        console_name TEXT,
        title TEXT,
        image_icon TEXT,
        num_achievements INTEGER NOT NULL DEFAULT 0,
        num_leaderboards INTEGER NOT NULL DEFAULT 0,
        points INTEGER NOT NULL DEFAULT 0,
        date_modified TEXT,
        forum_topic_id INTEGER
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
        esde_media_subdir TEXT,
        esde_imported INTEGER DEFAULT 0,
        updated_at TEXT,
        UNIQUE(app_system_id, filename)
      )
    ''');

    await db.execute(SqliteMigrations.createAppNeoSyncStateTableSql);
    await db.execute(SqliteMigrations.createAppNeoSyncStateIndexSql);

    // The production DDL rather than a copy, so the singleton CHECK and the
    // nullable secret columns behave exactly as they do on a device.
    await db.execute(SqliteMigrations.createUserRommConfigTableSql);
  }
}
