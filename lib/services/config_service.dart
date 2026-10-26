import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter/services.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:neostation/services/logger_service.dart';
import '../models/system_model.dart';
import '../models/config_model.dart';
import '../models/emulator_model.dart';
import '../repositories/system_repository.dart';

/// Service responsible for managing application paths, file I/O for configurations,
/// and discovery of emulation systems and standalone emulators.
///
/// Provides platform-agnostic abstractions for directory resolution across
/// Windows, Android, Linux, and macOS.
class ConfigService {
  static final _log = LoggerService.instance;

  /// Determines the base execution path for Windows installations.
  ///
  /// In development mode (`flutter run`), it targets the project root.
  /// In production mode, it targets the directory containing the executable (portable behavior).
  static String _getWindowsBasePath() {
    final exePath = Platform.resolvedExecutable;
    if (exePath.contains(r'build\windows') ||
        exePath.contains(r'build/windows')) {
      return Directory.current.path;
    }
    return path.dirname(exePath);
  }

  static const String _customPathKey = 'custom_user_data_path';

  static String? _defaultUserDataPathForTesting;

  /// Replaces the platform default user-data folder (and the default media
  /// folder) for tests, so a test run never reads or writes a real profile.
  /// A custom user-data path still takes precedence.
  /// `test/flutter_test_config.dart` sets this for every test file; passing
  /// null points the rest of that file back at the real default.
  @visibleForTesting
  static void setDefaultUserDataPathForTesting(String? userDataPath) {
    _defaultUserDataPathForTesting = userDataPath;
  }

  static const Duration _androidStorageRetryDelay = Duration(seconds: 3);
  static const int _androidStorageMaxAttempts = 20;

  /// In-flight Android cold-boot wait, shared by every concurrent caller so the
  /// retry loop runs once instead of once per consumer.
  static Future<String>? _androidStorageWait;

  /// Set when the retry loop has already given up on [_unavailableStoragePath].
  /// Later callers then fail fast instead of each blocking for another full
  /// timeout — `getUserDataPath()` has a dozen call sites, and serialising
  /// their waits used to stall startup for minutes.
  static bool _androidStorageUnavailable = false;
  static String? _unavailableStoragePath;

  /// Session-only opt-out: the user explicitly chose to continue with the
  /// platform default location after the configured volume never appeared.
  static bool _useDefaultPathFallback = false;

  /// Whether the configured user-data volume was declared unreachable this
  /// session. UI may use this to explain the state instead of silently
  /// presenting an empty library.
  static bool get storageUnavailable => _androidStorageUnavailable;

  /// The configured path that [storageUnavailable] refers to, if any.
  static String? get unavailableStoragePath => _unavailableStoragePath;

  /// Clears the cached "unavailable" verdict so the next resolution retries
  /// from scratch. Call after the configured path changes or when the user
  /// asks to retry.
  static void resetStorageAvailability() {
    _androidStorageUnavailable = false;
    _unavailableStoragePath = null;
    _useDefaultPathFallback = false;
  }

  /// Abandons the configured custom path for the remainder of this session and
  /// resolves to the platform default instead. This is the user's explicit
  /// escape hatch from an unmountable volume; it is deliberately not persisted.
  static void continueWithDefaultUserDataPath() {
    _log.w('User opted to continue with the default user-data path');
    _androidStorageUnavailable = false;
    _useDefaultPathFallback = true;
  }

  /// Resolves the user-data path once, up front, so the cold-boot wait happens
  /// while a loading UI is visible rather than piecemeal inside later callers.
  ///
  /// Returns false when the configured volume never became available.
  static Future<bool> ensureUserDataStorageReady() async {
    try {
      await getUserDataPath();
      return true;
    } catch (e) {
      _log.e('User-data storage is not ready: $e');
      return false;
    }
  }

  /// Resolves the absolute path to the user's local data directory.
  ///
  /// Checks for a user-configured custom path first (stored in SharedPreferences).
  /// Falls back to the platform default if no custom path is set.
  static Future<String> getUserDataPath() async {
    final prefs = await SharedPreferences.getInstance();
    final customPath = prefs.getString(_customPathKey);
    if (customPath != null &&
        customPath.isNotEmpty &&
        !_useDefaultPathFallback) {
      final dir = Directory(customPath);
      if (await dir.exists()) {
        return customPath;
      }

      if (Platform.isAndroid) {
        // A default launcher can start while the removable volume containing
        // the user data is still mounting. Falling back to the app-private
        // default here creates a second, empty database and makes the whole
        // app look freshly installed. Wait for the configured volume instead.
        if (_androidStorageUnavailable &&
            _unavailableStoragePath == customPath) {
          throw StateError(
            'Configured user-data storage is unavailable: $customPath',
          );
        }

        return _androidStorageWait ??= _startAndroidStorageWait(customPath);
      }

      // Directory missing — try to create it (first-run on new device or new location).
      // On desktop, falling back keeps the application usable when a removable
      // custom path has genuinely been removed.
      try {
        await dir.create(recursive: true);
        return customPath;
      } catch (e) {
        _log.w(
          'ConfigService: custom path "$customPath" inaccessible ($e). '
          'Falling back to default path.',
        );
        return getDefaultUserDataPath();
      }
    }
    return getDefaultUserDataPath();
  }

  /// Runs the Android cold-boot retry loop for [customPath] and clears the
  /// shared in-flight slot once it settles. A success does not need caching —
  /// the `exists()` check in [getUserDataPath] is cheap — while a failure is
  /// remembered via [_androidStorageUnavailable] so later callers fail fast.
  static Future<String> _startAndroidStorageWait(String customPath) {
    final wait = _waitForAndroidStorage(customPath);
    unawaited(
      wait
          .then((_) {}, onError: (Object _) {})
          .whenComplete(() => _androidStorageWait = null),
    );
    return wait;
  }

  /// Waits for the volume holding [customPath] to appear, creating the final
  /// directory only once its parent volume is mounted. Throws a [StateError]
  /// (and latches [storageUnavailable]) when it never shows up.
  static Future<String> _waitForAndroidStorage(String customPath) async {
    final dir = Directory(customPath);
    for (var attempt = 1; attempt <= _androidStorageMaxAttempts; attempt++) {
      if (await dir.exists()) return customPath;

      // A missing last directory is safe to create only once its parent
      // volume is available. Do not create a lookalike path before that.
      if (await dir.parent.exists()) {
        await dir.create(recursive: true);
        return customPath;
      }

      if (attempt < _androidStorageMaxAttempts) {
        _log.i(
          'Waiting for custom user-data storage ($attempt/$_androidStorageMaxAttempts): $customPath',
        );
        await Future<void>.delayed(_androidStorageRetryDelay);
      }
    }

    _androidStorageUnavailable = true;
    _unavailableStoragePath = customPath;
    throw StateError(
      'Configured user-data storage is unavailable: $customPath',
    );
  }

  /// Returns the platform default user-data path, ignoring any custom override.
  static Future<String> getDefaultUserDataPath() async {
    return _computeDefaultUserDataPath();
  }

  /// Platform-specific strategies:
  /// - Android: Application-specific external storage (`/Android/data/.../files/user-data`).
  /// - macOS: Standard application support directory (`~/Library/Application Support/...`).
  /// - Linux: AppImage-aware persistence or `~/.neostation`.
  /// - Windows: Portable directory relative to the binary.
  static Future<String> _computeDefaultUserDataPath() async {
    final testingPath = _defaultUserDataPathForTesting;
    if (testingPath != null) return testingPath;
    if (Platform.isAndroid) {
      final externalDir = await getExternalStorageDirectory();
      final dir = externalDir ?? await getApplicationDocumentsDirectory();
      final userDataPath = path.join(dir.path, 'user-data');

      final userDataDir = Directory(userDataPath);
      if (!await userDataDir.exists()) {
        try {
          await userDataDir.create(recursive: true);
        } catch (e) {
          _log.e('Failed to create Android user data directory: $e');
        }
      }
      return userDataPath;
    } else if (Platform.isIOS) {
      final directory = await getApplicationDocumentsDirectory();
      return path.join(directory.path, 'user-data');
    } else {
      String basePath;

      if (Platform.isLinux) {
        final executable = Platform.resolvedExecutable;
        if (executable.contains('/.mount_') ||
            executable.endsWith('.AppImage')) {
          final home = Platform.environment['HOME'];
          if (home != null) {
            basePath = path.join(home, '.neostation');
          } else {
            basePath = Directory.current.path;
          }
        } else {
          basePath = Directory.current.path;
        }
      } else if (Platform.isMacOS) {
        final home = getRealHomePath();
        basePath = path.join(
          home,
          'Library',
          'Application Support',
          'com.neogamelab.neostation',
        );
      } else {
        basePath = _getWindowsBasePath();
      }

      return path.join(basePath, 'user-data');
    }
  }

  /// Retrieves the user's home directory path, bypassing sandbox limitations on macOS.
  static String getRealHomePath() {
    if (Platform.isMacOS) {
      final user = Platform.environment['USER'];
      if (user != null && user.isNotEmpty) {
        return '/Users/$user';
      }
    }
    return Platform.environment['HOME'] ?? '';
  }

  /// Replaces logical placeholders (e.g., `{HOME}`, `{USERPROFILE}`) within a path string
  /// with their corresponding absolute filesystem paths.
  static String resolvePath(String pathStr) {
    if (pathStr.isEmpty) return pathStr;

    String resolved = pathStr;

    if (resolved.contains('{HOME}')) {
      resolved = resolved.replaceFirst('{HOME}', getRealHomePath());
    }

    if (resolved.contains('{USERPROFILE}')) {
      resolved = resolved.replaceFirst(
        '{USERPROFILE}',
        Platform.environment['USERPROFILE'] ?? getRealHomePath(),
      );
    }

    return resolved;
  }

  /// Resolves the absolute path for storing media assets (thumbnails, videos).
  ///
  /// When a custom user-data path is set, media always lives inside it at `media/`.
  /// Otherwise falls back to platform-specific defaults.
  static Future<String> getMediaPath() async {
    if (Platform.isAndroid) {
      // On Android getUserDataPath() already handles the custom override.
      final userDataPath = await getUserDataPath();
      final mediaPath = path.join(userDataPath, 'media');

      final mediaDir = Directory(mediaPath);
      if (!await mediaDir.exists()) {
        try {
          await mediaDir.create(recursive: true);
        } catch (e) {
          _log.e('Failed to create Android media directory: $e');
        }
      }
      return mediaPath;
    } else if (Platform.isIOS) {
      final directory = await getApplicationDocumentsDirectory();
      return path.join(directory.path, 'media');
    } else {
      // Check custom path first — media lives inside it when overridden.
      final prefs = await SharedPreferences.getInstance();
      final customPath = prefs.getString(_customPathKey);
      if (customPath != null && customPath.isNotEmpty) {
        return path.join(customPath, 'media');
      }
      final testingPath = _defaultUserDataPathForTesting;
      if (testingPath != null) return path.join(testingPath, 'media');

      String basePath;

      if (Platform.isLinux) {
        final executable = Platform.resolvedExecutable;
        if (executable.contains('/.mount_') ||
            executable.endsWith('.AppImage')) {
          final home = Platform.environment['HOME'];
          if (home != null) {
            basePath = path.join(home, '.neostation');
          } else {
            basePath = Directory.current.path;
          }
        } else {
          basePath = Directory.current.path;
        }
      } else if (Platform.isMacOS) {
        final home = getRealHomePath();
        basePath = path.join(
          home,
          'Library',
          'Application Support',
          'com.neogamelab.neostation',
        );
      } else {
        basePath = _getWindowsBasePath();
        return path.join(basePath, 'user-data', 'media');
      }

      return path.join(basePath, 'media');
    }
  }

  /// Returns the path to the application's global JSON configuration file.
  static Future<String> getConfigFilePath() async {
    final userDataPath = await getUserDataPath();
    return path.join(userDataPath, 'config.json');
  }

  /// Returns the path to the current session log file.
  static Future<String> getLogFilePath() async {
    final userDataPath = await getUserDataPath();
    return path.join(userDataPath, 'app.log');
  }

  /// Deserializes the application configuration from the local `config.json` file.
  static Future<ConfigModel> loadConfig() async {
    try {
      final configPath = await getConfigFilePath();
      final file = File(configPath);
      if (await file.exists()) {
        final content = await file.readAsString();
        final json = jsonDecode(content) as Map<String, dynamic>;
        final config = ConfigModel.fromJson(json);
        return config;
      }
    } catch (e) {
      _log.e('Error loading configuration: $e');
    }
    return ConfigModel.empty;
  }

  /// Serializes and persists the provided [ConfigModel] to disk.
  static Future<void> saveConfig(ConfigModel config) async {
    try {
      final configPath = await getConfigFilePath();
      final file = File(configPath);
      await file.parent.create(recursive: true);
      final json = jsonEncode(config.toJson());
      await file.writeAsString(json);
    } catch (e) {
      _log.e('Error saving configuration: $e');
      rethrow;
    }
  }

  /// Loads the static registry of supported systems from application assets.
  static Future<List<SystemModel>> loadAvailableSystems() async {
    try {
      final content = await rootBundle.loadString(
        'assets/system-data/systems.json',
      );
      final List<dynamic> json = jsonDecode(content);
      return json.map((system) => SystemModel.fromJson(system)).toList();
    } catch (e) {
      _log.e('Error loading available systems: $e');
      return [];
    }
  }

  /// Loads the metadata and launch arguments for external emulators from assets.
  static Future<Map<String, EmulatorModel>> loadAvailableEmulators() async {
    try {
      final content = await rootBundle.loadString(
        'assets/system-data/emulator.json',
      );
      final Map<String, dynamic> json = jsonDecode(content);
      final emulatorsData = json['emulators'] as Map<String, dynamic>;

      final Map<String, EmulatorModel> emulators = {};
      for (final entry in emulatorsData.entries) {
        emulators[entry.key] = EmulatorModel.fromJson(
          entry.key,
          entry.value as Map<String, dynamic>,
        );
      }

      return emulators;
    } catch (e) {
      _log.e('Error loading available emulators: $e');
      return {};
    }
  }

  /// Identifies supported emulation systems based on the folder structure of [romFolders].
  ///
  /// Performs a shallow scan to match subdirectory names with [availableSystems].
  static Future<List<SystemModel>> detectSystems({
    required List<String> romFolders,
    required List<SystemModel> availableSystems,
  }) async {
    final Map<String, SystemModel> detectedSystemsMap = {};

    try {
      for (final romFolder in romFolders) {
        final romDir = Directory(romFolder);
        if (!await romDir.exists()) continue;

        final entities = await romDir
            .list()
            .where((entity) => entity is Directory)
            .toList();

        for (final entity in entities) {
          final folderName = path.basename(entity.path);

          final matchingSystem = availableSystems.firstWhere(
            (system) =>
                system.folderName.toLowerCase() == folderName.toLowerCase(),
            orElse: () => SystemModel(
              folderName: folderName,
              realName: 'Unknown System',
              iconImage: '/assets/images/systems/unknown-icon.png',
              color: '#607d8b',
            ),
          );

          final romCount = await _countRomsInFolder(
            entity.path,
            matchingSystem.id,
          );

          final existing = detectedSystemsMap[matchingSystem.id];
          if (existing != null) {
            detectedSystemsMap[matchingSystem.id!] = existing.copyWith(
              romCount: (existing.romCount) + romCount,
            );
          } else {
            detectedSystemsMap[matchingSystem.id!] = matchingSystem.copyWith(
              romCount: romCount,
              detected: true,
            );
          }
        }
      }
      return detectedSystemsMap.values.toList();
    } catch (e) {
      _log.e('Error detecting systems: $e');
      return [];
    }
  }

  /// Recursively counts files within a folder that match valid ROM extensions.
  static Future<int> _countRomsInFolder(
    String folderPath, [
    String? systemId,
  ]) async {
    try {
      final folder = Directory(folderPath);
      if (!await folder.exists()) return 0;

      Set<String> romExtensions;
      if (systemId != null) {
        romExtensions = await SystemRepository.getExtensionsForSystem(systemId);
      } else {
        romExtensions = await SystemRepository.getAllValidExtensions();
      }

      int count = 0;
      await for (final entity in folder.list(recursive: true)) {
        if (entity is File) {
          final extension = path.extension(entity.path).toLowerCase();
          if (romExtensions.contains(extension)) {
            count++;
          }
        }
      }

      return count;
    } catch (e) {
      _log.e('Error counting ROMs in $folderPath: $e');
      return 0;
    }
  }

  /// Scans the host system for installed standalone emulators defined in [availableEmulators].
  ///
  /// Verifies existence across all platform-specific `possiblePaths`.
  static Future<Map<String, EmulatorModel>> detectEmulators({
    required Map<String, EmulatorModel> availableEmulators,
  }) async {
    final Map<String, EmulatorModel> detectedEmulators = {};

    try {
      for (final entry in availableEmulators.entries) {
        final emulatorName = entry.key;
        final emulator = entry.value;

        String? detectedPath;
        final platform = _getCurrentPlatform();
        final possiblePaths = emulator.possiblePaths[platform] ?? [];

        for (final possiblePath in possiblePaths) {
          final file = File(possiblePath);
          if (await file.exists()) {
            detectedPath = possiblePath;
            break;
          }
        }

        detectedEmulators[emulatorName] = emulator.copyWith(
          path: detectedPath ?? '',
          detected: detectedPath != null,
          lastDetection: detectedPath != null ? DateTime.now() : null,
        );
      }

      return detectedEmulators;
    } catch (e) {
      _log.e('Error detecting emulators: $e');
      return detectedEmulators;
    }
  }

  /// Returns the current OS platform identifier.
  static String _getCurrentPlatform() {
    if (Platform.isWindows) return 'windows';
    if (Platform.isLinux) return 'linux';
    if (Platform.isMacOS) return 'macos';
    if (Platform.isAndroid) return 'android';
    return 'unknown';
  }
}
