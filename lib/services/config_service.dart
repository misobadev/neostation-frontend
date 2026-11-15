import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter/services.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:neostation/services/logger_service.dart';
import 'package:neostation/utils/user_data_startup_check.dart';

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

  /// How long a drive's root may take to answer whether it is there: a
  /// network share that is offline can hold a check for the length of its
  /// timeout.
  static const Duration _volumeCheckTimeout = Duration(seconds: 5);

  static UserDataPlatform? _platformForTesting;
  static Duration? _androidStorageRetryDelayForTesting;
  static int? _androidStorageMaxAttemptsForTesting;
  static bool? _removableVolumeForTesting;

  /// Makes [getUserDataPath] treat a missing folder as on [platform] (null:
  /// the real one), the Android wait pause for [retryDelay] and look
  /// [maxAttempts] times, and the folder as on a removable volume or not
  /// ([removable]), so its Android paths can run in a host test.
  @visibleForTesting
  static void setUserDataPlatformForTesting(
    UserDataPlatform? platform, {
    Duration? retryDelay,
    int? maxAttempts,
    bool? removable,
  }) {
    _platformForTesting = platform;
    _androidStorageRetryDelayForTesting = retryDelay;
    _androidStorageMaxAttemptsForTesting = maxAttempts;
    _removableVolumeForTesting = removable;
  }

  static UserDataPlatform get _platform =>
      _platformForTesting ??
      (Platform.isAndroid
          ? UserDataPlatform.android
          : Platform.isWindows
          ? UserDataPlatform.windows
          : Platform.isMacOS
          ? UserDataPlatform.macos
          : UserDataPlatform.linux);

  /// In-flight Android cold-boot wait, shared by every concurrent caller so the
  /// retry loop runs once instead of once per consumer.
  static Future<String>? _androidStorageWait;

  /// Set once the configured folder at [_unavailableStoragePath] is known to
  /// be unusable: its drive never appeared (after the Android retry loop gave
  /// up), or the folder itself is missing. Later callers then fail fast
  /// instead of each blocking for another full timeout —
  /// `getUserDataPath()` has a dozen call sites, and serialising their waits
  /// used to stall startup for minutes — and nothing creates the folder.
  static UserDataProblem? _userDataProblem;
  static String? _unavailableStoragePath;

  /// Session-only opt-out: the user explicitly chose to continue with the
  /// platform default location after the configured folder or its drive was
  /// missing.
  static bool _useDefaultPathFallback = false;

  /// Marks the session that chose [continueWithDefaultUserDataPath], for the
  /// second screen's engine: a separate isolate in the same process, which
  /// shares no memory with this one but reads the same preferences.
  static const String _fallbackSessionKey = 'user_data_fallback_session';

  /// Whether the configured user-data folder was declared unusable this
  /// session. UI may use this to explain the state instead of silently
  /// presenting an empty library.
  static bool get storageUnavailable => _userDataProblem != null;

  /// Why the configured user-data folder is unusable, if it is.
  static UserDataProblem? get userDataProblem => _userDataProblem;

  /// The configured path that [storageUnavailable] refers to, if any.
  static String? get unavailableStoragePath => _unavailableStoragePath;

  /// Clears the cached "unavailable" verdict so the next resolution retries
  /// from scratch. Call after the configured path changes or when the user
  /// asks to retry.
  static void resetStorageAvailability() {
    _userDataProblem = null;
    _unavailableStoragePath = null;
    _useDefaultPathFallback = false;
  }

  /// Abandons the configured custom path for the remainder of this session and
  /// resolves to the platform default instead. This is the user's explicit
  /// escape hatch from a missing folder or drive. It lasts for this process
  /// only: the mark it leaves for the second screen names this process, so a
  /// later start ignores it.
  static Future<void> continueWithDefaultUserDataPath() async {
    _log.w('User opted to continue with the default user-data path');
    _userDataProblem = null;
    _useDefaultPathFallback = true;
    // Only Android has a second screen's engine to tell.
    if (_platform != UserDataPlatform.android) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      final session = _sessionId();
      if (session.isNotEmpty) {
        await prefs.setString(_fallbackSessionKey, session);
      }
    } catch (e) {
      _log.w('Could not mark the session fallback for the second screen: $e');
    }
  }

  /// This process, as told apart from a later one that reuses its id: the
  /// boot, the process id and the process's start time since that boot.
  static String _sessionId() {
    try {
      final boot = File('/proc/sys/kernel/random/boot_id')
          .readAsStringSync()
          .trim();
      final stat = File('/proc/self/stat').readAsStringSync();
      // The command name (field 2) is in parentheses and may hold spaces;
      // the start time is field 22, the 20th after it.
      final fields = stat.substring(stat.lastIndexOf(')') + 2).split(' ');
      return '$boot:$pid:${fields[19]}';
    } catch (e) {
      // Without them a later process could match: no marker at all.
      _log.w('No session id for the second screen: $e');
      return '';
    }
  }

  static Future<bool> _fallbackChosenThisSession(
    SharedPreferences prefs,
  ) async {
    if (_platform != UserDataPlatform.android) return false;
    final session = _sessionId();
    if (session.isEmpty) return false;
    try {
      // Written by the other engine: its cached copy is stale here.
      await prefs.reload();
    } catch (_) {
      // Keep the cached values.
    }
    return prefs.getString(_fallbackSessionKey) == session;
  }

  /// Creates the configured user-data folder that went missing, empty, at the
  /// user's explicit request, and clears the verdict so it is used. A folder
  /// that came back meanwhile is left as it is. Refused unless its drive is
  /// still there: on a drive unplugged or swapped meanwhile it would create
  /// a lookalike path.
  static Future<void> createMissingUserDataFolder() async {
    final prefs = await SharedPreferences.getInstance();
    final customPath = prefs.getString(_customPathKey);
    if (customPath == null || customPath.isEmpty) return;
    final present = await Directory(customPath)
        .exists()
        .timeout(_volumeCheckTimeout, onTimeout: () => false);
    if (!present &&
        await _missingUserDataProblem(customPath) !=
            UserDataProblem.folderMissing) {
      throw StateError('The drive of $customPath is not there');
    }
    _log.w('User chose to start with an empty user-data folder: $customPath');
    await Directory(customPath).create(recursive: true);
    resetStorageAvailability();
  }

  /// Resolves the user-data path once, up front, so the cold-boot wait happens
  /// while a loading UI is visible rather than piecemeal inside later callers.
  ///
  /// Returns false when the configured folder can't be used: its drive never
  /// became available, or the folder is missing ([userDataProblem]).
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
  /// Checks for a user-configured custom path first (stored in
  /// SharedPreferences). Falls back to the platform default if no custom path
  /// is set, or the user chose to continue without it this session. A custom
  /// folder that is missing is never created here: this throws a [StateError]
  /// and records why in [userDataProblem].
  static Future<String> getUserDataPath() async {
    final prefs = await SharedPreferences.getInstance();
    final customPath = prefs.getString(_customPathKey);
    if (customPath != null &&
        customPath.isNotEmpty &&
        !_useDefaultPathFallback) {
      final dir = Directory(customPath);
      // An offline network share can hold this for its whole timeout.
      if (await dir.exists().timeout(
        _volumeCheckTimeout,
        onTimeout: () => false,
      )) {
        return customPath;
      }

      // The main screen chose to continue without it (this engine being the
      // second screen's, which can't be told any other way).
      if (await _fallbackChosenThisSession(prefs)) {
        _useDefaultPathFallback = true;
        return getDefaultUserDataPath();
      }

      // Never created here: an empty folder in place of one that was moved,
      // renamed or deleted (or on a drive not mounted yet) opens NeoStation
      // on an empty library, and falling back to the default location on
      // its own does the same. The startup screen says what is missing and
      // the user decides.
      if (_userDataProblem != null && _unavailableStoragePath == customPath) {
        throw StateError(
          'Configured user-data storage is unavailable: $customPath',
        );
      }

      if (_platform == UserDataPlatform.android) {
        // A default launcher can start while the removable volume containing
        // the user data is still mounting. Wait for it.
        return _androidStorageWait ??= _startAndroidStorageWait(customPath);
      }
      _declareUnusable(customPath, await _missingUserDataProblem(customPath));
    }
    return getDefaultUserDataPath();
  }

  static Future<UserDataProblem> _missingUserDataProblem(String folder) async {
    final platform = _platform;
    var mounts = <String>{};
    var fstab = <String>{};
    if (platform == UserDataPlatform.linux) {
      mounts = parseMountPoints(await _readOrEmpty('/proc/self/mounts'));
      fstab = parseFstabMountPoints(await _readOrEmpty('/etc/fstab'));
    }
    return missingUserDataProblem(
      folder,
      platform,
      exists: (path) =>
          Directory(path)
              .exists()
              .timeout(_volumeCheckTimeout, onTimeout: () => false),
      mountPoints: mounts,
      fstabMountPoints: fstab,
      // A share that doesn't answer counts as a drive that isn't there.
      isDanglingLink: (path) async {
        try {
          if (await FileSystemEntity.type(
                path,
                followLinks: false,
              ).timeout(_volumeCheckTimeout) !=
              FileSystemEntityType.link) {
            return false;
          }
          return await FileSystemEntity.type(path)
                  .timeout(_volumeCheckTimeout) ==
              FileSystemEntityType.notFound;
        } on TimeoutException {
          return true;
        }
      },
    );
  }

  static Future<String> _readOrEmpty(String path) async {
    try {
      return await File(path).readAsString();
    } catch (_) {
      return '';
    }
  }

  static Never _declareUnusable(String customPath, UserDataProblem problem) {
    _userDataProblem = problem;
    _unavailableStoragePath = customPath;
    _log.w(
      'Configured user-data folder unusable (${problem.name}): $customPath',
    );
    throw StateError(
      'Configured user-data storage is unavailable: $customPath',
    );
  }

  /// Runs the Android cold-boot retry loop for [customPath] and clears the
  /// shared in-flight slot once it settles. A success does not need caching —
  /// the `exists()` check in [getUserDataPath] is cheap — while a failure is
  /// remembered via [_userDataProblem] so later callers fail fast.
  static Future<String> _startAndroidStorageWait(String customPath) {
    final wait = _waitForAndroidStorage(customPath);
    unawaited(
      wait
          .then((_) {}, onError: (Object _) {})
          .whenComplete(() => _androidStorageWait = null),
    );
    return wait;
  }

  /// Waits for the volume holding [customPath] to appear. Throws a
  /// [StateError] (and latches [storageUnavailable]) when it never shows up,
  /// or when it does but the folder isn't on it.
  static Future<String> _waitForAndroidStorage(String customPath) async {
    final dir = Directory(customPath);
    // A removable volume's folder can show for a moment before the card is
    // mounted in it (sdcardfs, Android 10 and older): a folder missing there
    // is only believed when it is still missing one pause later.
    var folderMissingSeen = false;
    final removable =
        _removableVolumeForTesting ?? isAndroidRemovableVolume(customPath);
    final maxAttempts =
        _androidStorageMaxAttemptsForTesting ?? _androidStorageMaxAttempts;
    for (var attempt = 1; attempt <= maxAttempts; attempt++) {
      if (await dir.exists()) return customPath;

      if (await _missingUserDataProblem(customPath) ==
          UserDataProblem.folderMissing) {
        if (folderMissingSeen || !removable) {
          _declareUnusable(customPath, UserDataProblem.folderMissing);
        }
        folderMissingSeen = true;
      } else {
        folderMissingSeen = false;
      }

      if (attempt < maxAttempts) {
        _log.i(
          'Waiting for custom user-data storage ($attempt/$maxAttempts): $customPath',
        );
        await Future<void>.delayed(
          _androidStorageRetryDelayForTesting ?? _androidStorageRetryDelay,
        );
      }
    }

    // A folder missing on a removable volume, seen only on the last look,
    // is not believed (see above): the volume is taken for still mounting.
    _declareUnusable(customPath, UserDataProblem.volumeMissing);
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
  /// When a custom user-data path is set, media lives inside it at `media/`
  /// (unless the user chose to continue without it this session, when the
  /// default is used). Otherwise falls back to platform-specific defaults.
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
        // Media lives in the user-data folder: unusable together, and the
        // default's when this session continues without it.
        final userDataPath = await getUserDataPath();
        if (userDataPath == customPath) {
          return path.join(customPath, 'media');
        }
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
