import 'dart:convert';
import 'dart:io';
import 'package:neostation/constants/recent_card_sizes.dart';
import 'package:path/path.dart' as path;
import 'package:neostation/services/logger_service.dart';
import '../../models/config_model.dart';
import '../../models/system_model.dart';
import '../../models/emulator_model.dart';
import 'sqlite_service.dart';
import '../../services/config_service.dart';
import '../../repositories/system_repository.dart';

/// Configuration service that utilizes SQLite for persistent application state
/// and discovery logic.
///
/// Replaces the legacy JSON-based configuration service. Manages the orchestration
/// of user preferences, ROM folder discovery, system detection, and emulator
/// path resolution by interacting with [SqliteService].
class SqliteConfigService {
  static final _log = LoggerService.instance;

  /// Counts valid ROM files within a given directory.
  ///
  /// Filters files based on valid extensions retrieved from the database
  /// for the specified [systemId] (or all systems if null).
  static Future<int> _countRomsInDirectory(
    String directoryPath, {
    String? systemId,
    bool recursive = true,
  }) async {
    Set<String> validExtensions;
    try {
      if (systemId != null) {
        validExtensions = await SqliteService.getExtensionsForSystem(systemId);
      } else {
        validExtensions = await SqliteService.getAllValidExtensions();
      }
    } catch (e) {
      _log.e('Error getting extensions from DB: $e');
      return 0;
    }

    try {
      final directory = Directory(directoryPath);
      final files = await directory
          .list(recursive: recursive, followLinks: false)
          .where((entity) => entity is File)
          .cast<File>()
          .toList();

      int count = 0;
      for (final file in files) {
        String extension = path.extension(file.path).toLowerCase();
        if (extension.startsWith('.')) {
          extension = extension.substring(1);
        }
        if (validExtensions.contains(extension)) {
          count++;
        }
      }

      return count;
    } catch (e) {
      _log.e('Error counting ROMs in $directoryPath: $e');
      return 0;
    }
  }

  /// Retrieves the platform-specific user data directory path.
  static Future<String> getUserDataPath() async {
    return await ConfigService.getUserDataPath();
  }

  /// Retrieves the platform-specific media directory path.
  static Future<String> getMediaPath() async {
    return await ConfigService.getMediaPath();
  }

  /// Loads the global application configuration from SQLite.
  ///
  /// Aggregates data from user preferences, ROM folders, detected emulators,
  /// and detected systems.
  static Future<ConfigModel> loadConfig() async {
    try {
      final userConfig = await SqliteService.getUserConfig();
      var romFolders = await SqliteService.getUserRomFolders();
      if (Platform.isAndroid && romFolders.isEmpty) {
        final recoveredFolders =
            await SqliteService.recoverRomFoldersFromStoredRoms();
        if (recoveredFolders.isNotEmpty) {
          // Keep the existing library intact after a legacy-path migration (or
          // an interrupted save) has removed its folder table. Persist the
          // recovered roots immediately so the next startup uses the same
          // configured folders instead of treating the library as folderless.
          romFolders = recoveredFolders;
          await SqliteService.saveUserRomFolders(romFolders);
          _log.w(
            'Recovered ${romFolders.length} ROM folder(s) from stored games',
          );
        }
      }
      final detectedEmulators = await SqliteService.getUserDetectedEmulators();
      final detectedSystems = await SqliteService.getUserDetectedSystems();

      return ConfigModel(
        romFolders: romFolders,
        lastScan: userConfig?['last_scan'] != null
            ? DateTime.parse(userConfig!['last_scan'].toString())
            : null,
        detectedSystems: detectedSystems.map((s) => s.folderName).toList(),
        emulators: detectedEmulators,
        gameViewMode: userConfig?['game_view_mode']?.toString() ?? 'list',
        systemViewMode: userConfig?['system_view_mode']?.toString() ?? 'grid',
        showGameInfo:
            (int.tryParse(userConfig?['show_game_info']?.toString() ?? '0') ??
                0) ==
            1,
        isFullscreen:
            (int.tryParse(userConfig?['is_fullscreen']?.toString() ?? '1') ??
                1) ==
            1,
        bartopExitPoweroff:
            (int.tryParse(
                  userConfig?['bartop_exit_poweroff']?.toString() ?? '0',
                ) ??
                0) ==
            1,
        videoSound:
            (int.tryParse(userConfig?['video_sound']?.toString() ?? '1') ??
                1) ==
            1,
        scanOnStartup:
            (int.tryParse(userConfig?['scan_on_startup']?.toString() ?? '1') ??
                1) ==
            1,
        ignoreHiddenFiles:
            (int.tryParse(
                  userConfig?['ignore_hidden_files']?.toString() ?? '1',
                ) ??
                1) ==
            1,
        setupCompleted:
            (int.tryParse(userConfig?['setup_completed']?.toString() ?? '0') ??
                0) ==
            1,
        hideBottomScreen:
            (int.tryParse(
                  userConfig?['hide_bottom_screen']?.toString() ?? '0',
                ) ??
                0) ==
            1,
        sfxEnabled:
            (int.tryParse(userConfig?['sfx_enabled']?.toString() ?? '1') ??
                1) ==
            1,
        sfxVolume:
            (double.tryParse(userConfig?['sfx_volume']?.toString() ?? '0.75') ??
                    0.75)
                .clamp(0.0, 0.75)
                .toDouble(),
        use12HourClock:
            (int.tryParse(
                  userConfig?['use_12_hour_clock']?.toString() ?? '0',
                ) ??
                0) ==
            1,
        systemSortBy:
            userConfig?['system_sort_by']?.toString() ?? 'alphabetical',
        systemSortOrder: userConfig?['system_sort_order']?.toString() ?? 'asc',
        collectionSortBy:
            userConfig?['collection_sort_by']?.toString() ?? 'name',
        collectionSortOrder:
            userConfig?['collection_sort_order']?.toString() ?? 'asc',
        appLanguage: userConfig?['app_language']?.toString() ?? 'en',
        hideRecentCard:
            (int.tryParse(userConfig?['hide_recent_card']?.toString() ?? '0') ??
                0) ==
            1,
        // Missing column/row => the 3x2 block the card has always used.
        recentCardSize:
            userConfig?['recent_card_size']?.toString().isNotEmpty == true
            ? userConfig!['recent_card_size'].toString()
            : RecentCardSizes.defaultSize,
        // Missing column/row => the wheel tab (see migration v110).
        gameDetailsTab:
            userConfig?['game_details_tab']?.toString().isNotEmpty == true
            ? userConfig!['game_details_tab'].toString()
            : 'wheel',
        // Missing column/row => '0' => tab visible (see migration v106).
        hideTabSync:
            (int.tryParse(userConfig?['hide_tab_sync']?.toString() ?? '0') ??
                0) ==
            1,
        hideTabAchievements:
            (int.tryParse(
                  userConfig?['hide_tab_achievements']?.toString() ?? '0',
                ) ??
                0) ==
            1,
        hideTabScraper:
            (int.tryParse(userConfig?['hide_tab_scraper']?.toString() ?? '0') ??
                0) ==
            1,
        hideTabRomm:
            (int.tryParse(userConfig?['hide_tab_romm']?.toString() ?? '0') ??
                0) ==
            1,
        // Unset reads as hidden: the card is opt-in (see migration v158).
        hideSearchCard:
            (int.tryParse(userConfig?['hide_search_card']?.toString() ?? '1') ??
                1) ==
            1,
        activeSyncProvider:
            userConfig?['active_sync_provider']?.toString() ?? 'neosync',
        autoUpdateApp:
            (int.tryParse(userConfig?['auto_update_app']?.toString() ?? '1') ??
                1) ==
            1,
        autoUpdateSystems:
            (int.tryParse(
                  userConfig?['auto_update_systems']?.toString() ?? '1',
                ) ??
                1) ==
            1,
        systemGridColumns:
            userConfig?['system_grid_columns']?.toString() ?? 'M',
        gameGridColumns: userConfig?['game_grid_columns']?.toString() ?? 'M',
        gameCarouselCardStyle:
            userConfig?['game_carousel_card_style']?.toString() ?? 'fanart',
        dockApps: ConfigModel.normalizeDock(userConfig?['dock_apps']),
        dockEnabled:
            (int.tryParse(userConfig?['dock_enabled']?.toString() ?? '1') ??
                1) ==
            1,
        dockSlotCount:
            (int.tryParse(userConfig?['dock_slot_count']?.toString() ?? '3') ??
                    3)
                .clamp(
                  ConfigModel.dockMinSlotCount,
                  ConfigModel.dockMaxSlotCount,
                ),
        nowPlayingDimDelay:
            int.tryParse(
              userConfig?['now_playing_dim_delay']?.toString() ?? '3',
            ) ??
            3,
        nowPlayingDimLevel:
            (int.tryParse(
                      userConfig?['now_playing_dim_level']?.toString() ?? '100',
                    ) ??
                    100)
                .clamp(0, 100),
        fanartDimLevel:
            (int.tryParse(
                      userConfig?['fanart_dim_level']?.toString() ?? '25',
                    ) ??
                    25)
                .clamp(0, 100),
        esdeFolderPath: userConfig?['esde_folder_path']?.toString() ?? '',
        showAchievementsBadge:
            (int.tryParse(
                  userConfig?['show_achievements_badge']?.toString() ?? '0',
                ) ??
                0) ==
            1,
        showCloudSyncIcon:
            (int.tryParse(
                  userConfig?['show_cloud_sync_icon']?.toString() ?? '1',
                ) ??
                1) ==
            1,
        raMatchOnStartup:
            (int.tryParse(
                  userConfig?['ra_match_on_startup']?.toString() ?? '0',
                ) ??
                0) ==
            1,
        subfolderViewAll:
            (int.tryParse(
                  userConfig?['subfolder_view_all']?.toString() ?? '0',
                ) ??
                0) ==
            1,
        // Missing column/row => 0 => blur off (the default). The frosted blur
        // is only smooth on a powerful GPU, so it starts disabled.
        neoglassBlur:
            (int.tryParse(userConfig?['neoglass_blur']?.toString() ?? '0') ?? 0)
                .clamp(0, 2),
        // Missing column/row => 10 => the default transparency (0–30 scale).
        neoglassTransparency:
            (int.tryParse(
                      userConfig?['neoglass_transparency']?.toString() ?? '10',
                    ) ??
                    10)
                .clamp(0, 30),
        // Missing column/row => 2 => the feature's default rim stroke width.
        neoglassBorderWidth:
            (double.tryParse(
                      userConfig?['neoglass_border_width']?.toString() ?? '2',
                    ) ??
                    2)
                .clamp(0.0, 8.0),
      );
    } catch (e) {
      _log.e('Error applying configuration in loadConfig: $e');
      return ConfigModel.empty;
    }
  }

  /// Persists the provided [ConfigModel] to SQLite.
  ///
  /// Updates basic preferences, ROM folders, and detected emulator paths.
  ///
  /// Deliberately does NOT write `theme_name`: `ThemeProvider` owns that column
  /// and writes it directly on every theme change. [ConfigModel] carried a
  /// `themeName` that nothing updated after launch, so passing it here (this is
  /// a whole-config write) made every other settings change restore the
  /// launch-time theme — a theme picked and then followed by any other toggle
  /// was silently reverted on the next start. The field has since been removed
  /// from the model rather than merely skipped here, so there is no longer a
  /// theme on the model for a caller to believe this method persists.
  static Future<void> saveConfig(ConfigModel config) async {
    try {
      await SqliteService.saveUserConfig(
        lastScan: config.lastScan?.toIso8601String(),
        gameViewMode: config.gameViewMode,
        systemViewMode: config.systemViewMode,
        showGameInfo: config.showGameInfo ? 1 : 0,
        isFullscreen: config.isFullscreen ? 1 : 0,
        bartopExitPoweroff: config.bartopExitPoweroff ? 1 : 0,
        scanOnStartup: config.scanOnStartup ? 1 : 0,
        ignoreHiddenFiles: config.ignoreHiddenFiles ? 1 : 0,
        setupCompleted: config.setupCompleted ? 1 : 0,
        hideBottomScreen: config.hideBottomScreen ? 1 : 0,
        videoSound: config.videoSound ? 1 : 0,
        sfxEnabled: config.sfxEnabled ? 1 : 0,
        sfxVolume: config.sfxVolume,
        use12HourClock: config.use12HourClock ? 1 : 0,
        systemSortBy: config.systemSortBy,
        systemSortOrder: config.systemSortOrder,
        collectionSortBy: config.collectionSortBy,
        collectionSortOrder: config.collectionSortOrder,
        appLanguage: config.appLanguage,
        hideRecentCard: config.hideRecentCard ? 1 : 0,
        recentCardSize: config.recentCardSize,
        gameDetailsTab: config.gameDetailsTab,
        hideTabSync: config.hideTabSync ? 1 : 0,
        hideTabAchievements: config.hideTabAchievements ? 1 : 0,
        hideTabScraper: config.hideTabScraper ? 1 : 0,
        hideTabRomm: config.hideTabRomm ? 1 : 0,
        hideSearchCard: config.hideSearchCard ? 1 : 0,
        activeSyncProvider: config.activeSyncProvider,
        autoUpdateApp: config.autoUpdateApp ? 1 : 0,
        autoUpdateSystems: config.autoUpdateSystems ? 1 : 0,
        systemGridColumns: config.systemGridColumns,
        gameGridColumns: config.gameGridColumns,
        gameCarouselCardStyle: config.gameCarouselCardStyle,
        dockApps: jsonEncode(config.dockApps),
        dockEnabled: config.dockEnabled ? 1 : 0,
        dockSlotCount: config.dockSlotCount,
        nowPlayingDimDelay: config.nowPlayingDimDelay,
        nowPlayingDimLevel: config.nowPlayingDimLevel,
        fanartDimLevel: config.fanartDimLevel,
        esdeFolderPath: config.esdeFolderPath,
        showAchievementsBadge: config.showAchievementsBadge ? 1 : 0,
        showCloudSyncIcon: config.showCloudSyncIcon ? 1 : 0,
        raMatchOnStartup: config.raMatchOnStartup ? 1 : 0,
        subfolderViewAll: config.subfolderViewAll ? 1 : 0,
        neoglassBlur: config.neoglassBlur,
        neoglassTransparency: config.neoglassTransparency,
        neoglassBorderWidth: config.neoglassBorderWidth,
      );

      await SqliteService.saveUserRomFolders(config.romFolders);

      for (final entry in config.emulators.entries) {
        if (entry.value.detected && entry.value.path.isNotEmpty) {
          await SqliteService.saveDetectedEmulatorPath(
            emulatorName: entry.value.name,
            emulatorPath: entry.value.path,
          );
        }
      }
    } catch (e) {
      _log.e('Error saving config to SQLite: $e');
      rethrow;
    }
  }

  /// Retrieves all supported systems from the repository.
  static Future<List<SystemModel>> loadAvailableSystems() async {
    try {
      return await SystemRepository.getAllSystems();
    } catch (e) {
      _log.e('Error loading available systems: $e');
      return [];
    }
  }

  /// Retrieves all supported emulators from the database.
  static Future<Map<String, EmulatorModel>> loadAvailableEmulators() async {
    try {
      return await SqliteService.getAvailableEmulators();
    } catch (e) {
      _log.e('Error loading available emulators: $e');
      return {};
    }
  }

  /// Detects physical system folders within the configured ROM directories.
  ///
  /// Cross-references folder names against the internal system database
  /// (primary and alternate names) and counts valid ROMs within each
  /// discovered directory.
  static Future<List<SystemModel>> detectSystems({
    required List<String> romFolders,
    required List<SystemModel> availableSystems,
  }) async {
    final detectedSystemsMap = <String, SystemModel>{};

    for (final romFolder in romFolders) {
      if (!Directory(romFolder).existsSync()) {
        _log.w('ROM folder does not exist: $romFolder');
        continue;
      }

      final romDir = Directory(romFolder);
      List<FileSystemEntity> entities;
      try {
        entities = await romDir.list().toList();
      } catch (e) {
        _log.w('Error listing directory $romFolder: $e');
        continue;
      }

      for (final entity in entities) {
        if (entity is Directory) {
          final folderName = path.basename(entity.path);

          final matchingSystem = await _findSystemByFolderName(
            folderName,
            availableSystems,
          );

          if (matchingSystem != null) {
            final romCount = await SqliteConfigService._countRomsInDirectory(
              entity.path,
              systemId: matchingSystem.id,
              recursive: matchingSystem.recursiveScan,
            );

            final systemId = matchingSystem.id.toString();
            final existing = detectedSystemsMap[systemId];
            if (existing != null) {
              detectedSystemsMap[systemId] = existing.copyWith(
                romCount: (existing.romCount) + romCount,
              );
            } else {
              detectedSystemsMap[systemId] = matchingSystem.copyWith(
                folderName: folderName,
                detected: true,
                romCount: romCount,
              );
            }
          }
        }
      }
    }

    return detectedSystemsMap.values.toList();
  }

  /// Scans the host system for supported emulator installations.
  ///
  /// Persists detected paths to the database.
  static Future<Map<String, EmulatorModel>> detectEmulators() async {
    try {
      final availableEmulators = await SqliteService.getAvailableEmulators();
      final detectedEmulators = <String, EmulatorModel>{};

      for (final entry in availableEmulators.entries) {
        final detected = await entry.value.detect();
        detectedEmulators[entry.key] = detected;

        if (detected.detected) {
          await SqliteService.saveDetectedEmulatorPath(
            emulatorName: detected.name,
            emulatorPath: detected.path,
          );
        }
      }

      return detectedEmulators;
    } catch (e) {
      _log.e('Error detecting emulators: $e');
      return {};
    }
  }

  /// Initializer hook for future configuration service setup.
  static Future<void> initialize() async {
    try {} catch (e) {
      rethrow;
    }
  }

  /// Wipes all user-specific configuration data and preferences.
  static Future<void> clearUserConfig() async {
    try {
      await SqliteService.clearUserData();
    } catch (e) {
      _log.e('Error clearing user config: $e');
      rethrow;
    }
  }

  /// Resolves a directory name into a [SystemModel] by matching against
  /// physical and alternate folder name definitions.
  static Future<SystemModel?> _findSystemByFolderName(
    String folderName,
    List<SystemModel> availableSystems,
  ) async {
    try {
      final foundSystem = await SqliteService.getSystemByFolderName(folderName);

      final existingSystem = availableSystems
          .where((s) => s.id == foundSystem.id)
          .firstOrNull;

      if (existingSystem != null) {
        return existingSystem;
      }

      return foundSystem;
    } catch (e, stackTrace) {
      if (e.toString().contains('System not found')) {
        return null;
      }
      _log.e('Error in _findSystemByFolderName: $e');
      _log.e('Stack trace: $stackTrace');
      return null;
    }
  }

  /// Retrieves a list of all emulators currently detected on the system.
  static Future<List<EmulatorModel>> detectAvailableEmulators() async {
    try {
      return await SqliteService.getAvailableEmulators().then(
        (emulators) => emulators.values.toList(),
      );
    } catch (e) {
      _log.e('Error detecting emulators: $e');
      return [];
    }
  }

  /// Retrieves a list of emulators compatible with a specific system.
  static Future<List<EmulatorModel>> getEmulatorsForSystem(
    String systemId,
  ) async {
    try {
      final results = await SqliteService.getEmulatorsForSystem(systemId);
      return results
          .map(
            (row) => EmulatorModel(
              name: row['name'].toString(),
              path: row['core_filename']?.toString() ?? '',
              detected: true,
            ),
          )
          .toList();
    } catch (e) {
      _log.e('Error getting emulators for system $systemId: $e');
      return [];
    }
  }
}
