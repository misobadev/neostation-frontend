import 'dart:convert';
import 'dart:io';
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
      final romFolders = await SqliteService.getUserRomFolders();
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
        paletteName: userConfig?['palette_name']?.toString() ?? 'system',
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
        use12HourClock:
            (int.tryParse(
                  userConfig?['use_12_hour_clock']?.toString() ?? '0',
                ) ??
                0) ==
            1,
        systemSortBy:
            userConfig?['system_sort_by']?.toString() ?? 'alphabetical',
        systemSortOrder: userConfig?['system_sort_order']?.toString() ?? 'asc',
        appLanguage: userConfig?['app_language']?.toString() ?? 'en',
        hideRecentCard:
            (int.tryParse(userConfig?['hide_recent_card']?.toString() ?? '0') ??
                0) ==
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
      );
    } catch (e) {
      _log.e('Error applying configuration in loadConfig: $e');
      return ConfigModel.empty;
    }
  }

  /// Persists the provided [ConfigModel] to SQLite.
  ///
  /// Updates basic preferences, ROM folders, and detected emulator paths.
  static Future<void> saveConfig(ConfigModel config) async {
    try {
      await SqliteService.saveUserConfig(
        lastScan: config.lastScan?.toIso8601String(),
        gameViewMode: config.gameViewMode,
        systemViewMode: config.systemViewMode,
        // paletteName intentionally omitted: managed exclusively by
        // PaletteProvider via ConfigRepository.updatePaletteName().
        showGameInfo: config.showGameInfo ? 1 : 0,
        isFullscreen: config.isFullscreen ? 1 : 0,
        bartopExitPoweroff: config.bartopExitPoweroff ? 1 : 0,
        scanOnStartup: config.scanOnStartup ? 1 : 0,
        ignoreHiddenFiles: config.ignoreHiddenFiles ? 1 : 0,
        setupCompleted: config.setupCompleted ? 1 : 0,
        hideBottomScreen: config.hideBottomScreen ? 1 : 0,
        videoSound: config.videoSound ? 1 : 0,
        sfxEnabled: config.sfxEnabled ? 1 : 0,
        use12HourClock: config.use12HourClock ? 1 : 0,
        systemSortBy: config.systemSortBy,
        systemSortOrder: config.systemSortOrder,
        appLanguage: config.appLanguage,
        hideRecentCard: config.hideRecentCard ? 1 : 0,
        activeSyncProvider: config.activeSyncProvider,
        autoUpdateApp: config.autoUpdateApp ? 1 : 0,
        autoUpdateSystems: config.autoUpdateSystems ? 1 : 0,
        systemGridColumns: config.systemGridColumns,
        gameGridColumns: config.gameGridColumns,
        dockApps: jsonEncode(config.dockApps),
        dockEnabled: config.dockEnabled ? 1 : 0,
        dockSlotCount: config.dockSlotCount,
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
