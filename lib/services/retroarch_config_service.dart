import 'dart:io';
import 'package:neostation/models/retroarch_config_model.dart';
import 'package:neostation/services/permission_service.dart';
import '../repositories/emulator_repository.dart';
import 'package:neostation/services/config_service.dart';
import 'package:path/path.dart' as path;
import 'package:flutter/foundation.dart';
import 'package:neostation/services/logger_service.dart';

/// Service responsible for discovering, parsing, and resolving RetroArch
/// configuration settings across all supported platforms.
///
/// Locates `retroarch.cfg` by checking system-specific default paths and the
/// local application database. Resolves key directories for system files (BIOS),
/// save files, and save states, handling relative paths and platform-specific
/// environment variables.
class RetroArchConfigService {
  static final RetroArchConfigService _instance =
      RetroArchConfigService._internal();
  factory RetroArchConfigService() => _instance;
  RetroArchConfigService._internal();

  static final _log = LoggerService.instance;

  /// In-memory cache of the last successfully resolved configuration.
  RetroArchConfig? _cachedConfig;

  /// Signature of the last resolution written to the log, so the uncached
  /// fallback path does not repeat the same line on every call.
  String? _lastLoggedResolution;

  /// Flatpak app id RetroArch ships under; the same id EmuDeck installs.
  static const String _retroArchFlatpakId = 'org.libretro.RetroArch';

  /// Candidate `retroarch.cfg` locations on Linux, in probe order, for the case
  /// where no config sits beside the executable.
  ///
  /// A Flatpak RetroArch — which is what EmuDeck installs, and therefore what a
  /// Steam Deck actually runs — keeps its config under
  /// `~/.var/app/org.libretro.RetroArch/config/retroarch/`, not in
  /// `~/.config/retroarch/`. Neither install puts a `retroarch.cfg` next to the
  /// binary the launcher resolves (a Flatpak export wrapper or an EmuDeck
  /// `retroarch.sh`), so without the Flatpak candidate below discovery fell
  /// through to the `~/.config/retroarch/{saves,states}` *defaults* — a tree no
  /// RetroArch on the machine reads or writes. Saves then synced into a dead
  /// directory while real save data sat elsewhere, silently, with the sync
  /// reporting success.
  ///
  /// When both installs are present the resolved [exePath] breaks the tie, so
  /// the config that wins belongs to the RetroArch we actually launch.
  @visibleForTesting
  static List<String> linuxConfigCandidates({String? exePath}) {
    final home = ConfigService.getRealHomePath();
    final flatpakCfg = path.join(
      home,
      '.var',
      'app',
      _retroArchFlatpakId,
      'config',
      'retroarch',
      'retroarch.cfg',
    );
    final xdgCfg = path.join(home, '.config', 'retroarch', 'retroarch.cfg');

    // A Flatpak export wrapper or an EmuDeck launcher script both name the app
    // id in their path; treat either as "this machine runs the Flatpak".
    final looksFlatpak =
        exePath != null &&
        (exePath.contains(_retroArchFlatpakId) || exePath.contains('flatpak'));

    return looksFlatpak ? [flatpakCfg, xdgCfg] : [xdgCfg, flatpakCfg];
  }

  /// Attempts to locate the `retroarch.cfg` file on Android by checking
  /// standard package data directories.
  Future<String?> detectAndroidConfigPath() async {
    if (!Platform.isAndroid) return null;

    if (!await PermissionService.hasStoragePermissions()) {
      debugPrint('Missing storage permissions to detect RetroArch config');
      return null;
    }

    final possiblePaths = [
      '/storage/emulated/0/Android/data/com.retroarch/files/retroarch.cfg',
      '/storage/emulated/0/Android/data/com.retroarch.aarch64/files/retroarch.cfg',
      '/storage/emulated/0/Android/data/com.retroarch.ra32/files/retroarch.cfg',
    ];

    for (final p in possiblePaths) {
      if (await File(p).exists()) {
        return p;
      }
    }

    return null;
  }

  /// Parses the `retroarch.cfg` file and extracts directory configurations.
  ///
  /// Targets `system_directory`, `savefile_directory`, and `savestate_directory`.
  Future<RetroArchConfig> parseConfig(String configPath) async {
    final file = File(configPath);
    if (!await file.exists()) {
      throw Exception('RetroArch config file not found at $configPath');
    }

    String? systemDir;
    String? saveDir;
    String? stateDir;
    var sortSaves = false;
    var sortStates = false;

    try {
      final lines = await file.readAsLines();

      for (final line in lines) {
        final timmedLine = line.trim();
        if (timmedLine.isEmpty || timmedLine.startsWith('#')) continue;

        if (timmedLine.startsWith('system_directory')) {
          systemDir = _extractValue(timmedLine);
        } else if (timmedLine.startsWith('savefile_directory')) {
          saveDir = _extractValue(timmedLine);
        } else if (timmedLine.startsWith('savestate_directory')) {
          stateDir = _extractValue(timmedLine);
        } else if (timmedLine.startsWith('sort_savefiles_enable')) {
          sortSaves = _extractBool(timmedLine);
        } else if (timmedLine.startsWith('sort_savestates_enable')) {
          sortStates = _extractBool(timmedLine);
        }
      }
    } catch (e) {
      _log.e('Error parsing RetroArch config: $e');
      rethrow;
    }

    final resolvedConfig = RetroArchConfig(
      configPath: configPath,
      systemDirectory: _normalizePath(systemDir, configPath),
      savefileDirectory: _normalizePath(saveDir, configPath),
      savestateDirectory: _normalizePath(stateDir, configPath),
      sortSavefilesByCore: sortSaves,
      sortSavestatesByCore: sortStates,
    );

    return resolvedConfig;
  }

  /// Reads a RetroArch boolean setting, which the config file writes as a
  /// quoted `"true"`/`"false"` rather than a bare literal.
  bool _extractBool(String line) =>
      _extractValue(line)?.trim().toLowerCase() == 'true';

  /// RetroArch's per-core subfolder name for the emulator display name
  /// [emulatorName], or null when the emulator is not a RetroArch core.
  ///
  /// With `sort_savefiles_enable`/`sort_savestates_enable` on, RetroArch files
  /// saves under the core's own name — `FCEUmm`, `Mesen-S`, `Beetle PSX HW`.
  /// Our emulator entries name the same cores as `RetroArch <Core>` (or
  /// `RetroArch64 <Core>` on Android), so dropping that prefix reproduces the
  /// folder. Verified against a real device: 7 of the 8 core folders present
  /// matched exactly, the miss being a core upstream has since renamed
  /// (`Beetle WonderSwan` is now `Beetle Cygne`) — which is why callers treat
  /// this as a hint and prefer an observed local layout when one exists.
  ///
  /// On Android the stored name also carries the RetroArch build as a
  /// ` (64-bit)`/` (32-bit)` suffix (see `SqliteService`), which is ours, not
  /// the core's: keeping it sent RomM downloads to `saves/FCEUmm (64-bit)/`,
  /// a folder RetroArch never reads (issue #511).
  static String? coreFolderName(String? emulatorName) {
    if (emulatorName == null) return null;
    final match = RegExp(
      r'^RetroArch(?:32|64)?\s+(.+?)(?:\s+\((?:32|64)-bit\))?$',
    ).firstMatch(emulatorName.trim());
    final core = match?.group(1)?.trim();
    return (core == null || core.isEmpty) ? null : core;
  }

  /// Extracts the configuration value from a line, stripping quotes and
  /// whitespace.
  String? _extractValue(String line) {
    if (!line.contains('=')) return null;

    final parts = line.split('=');
    if (parts.length < 2) return null;

    var value = parts[1].trim();

    if (value.startsWith('"') && value.endsWith('"')) {
      value = value.substring(1, value.length - 1);
    } else if (value.startsWith("'") && value.endsWith("'")) {
      value = value.substring(1, value.length - 1);
    }

    if (value == 'default' || value.isEmpty) return null;

    return value;
  }

  /// Normalizes a directory path string.
  ///
  /// Handles home directory expansion (`~`) and Windows-specific relative paths
  /// (`:\` or `:/`).
  String? _normalizePath(String? dirPath, String configPath) {
    if (dirPath == null) return null;

    var normalized = dirPath;

    if ((Platform.isMacOS || Platform.isLinux) && normalized.startsWith('~')) {
      final home = ConfigService.getRealHomePath();
      normalized = normalized.replaceFirst('~', home);
    }

    if (normalized.startsWith(':\\') || normalized.startsWith(':/')) {
      final parentDir = File(configPath).parent.path;
      return path.join(parentDir, normalized.substring(2));
    }

    if (normalized == 'default') return null;

    return normalized;
  }

  /// Returns the merged configuration by discovering the platform's standard
  /// config path and applying defaults for missing fields.
  ///
  /// Uses heuristics to find the installation directory based on user emulator
  /// settings in the local database.
  Future<RetroArchConfig> getMergedConfig({bool forceRefresh = false}) async {
    if (_cachedConfig != null && !forceRefresh) {
      return _cachedConfig!;
    }

    String? configPath;
    if (Platform.isAndroid) {
      configPath = await detectAndroidConfigPath();
    } else if (Platform.isWindows) {
      try {
        final exePath = await EmulatorRepository.getRetroArchExecutablePath();
        if (exePath != null) {
          final dir = path.dirname(exePath);
          final possibleCfg = path.join(dir, 'retroarch.cfg');
          if (await File(possibleCfg).exists()) {
            configPath = possibleCfg;
          } else {
            _log.w('retroarch.cfg not found at: $possibleCfg');
          }
        } else {
          _log.w('No RetroArch emulator path found in user_emulator_config!');
        }
      } catch (e) {
        _log.e('Error checking database for RetroArch: $e');
      }

      if (configPath == null) {
        final possiblePaths = [
          'C:\\RetroArch-Win64\\retroarch.cfg',
          'C:\\RetroArch\\retroarch.cfg',
          path.join(
            Platform.environment['APPDATA'] ?? '',
            'RetroArch',
            'retroarch.cfg',
          ),
        ];
        for (final p in possiblePaths) {
          if (await File(p).exists()) {
            configPath = p;
            break;
          }
        }
      }
    } else if (Platform.isLinux) {
      String? linuxExePath;
      try {
        linuxExePath = await EmulatorRepository.getRetroArchExecutablePath();
        if (linuxExePath != null) {
          final dir = path.dirname(linuxExePath);
          final possibleCfg = path.join(dir, 'retroarch.cfg');
          if (await File(possibleCfg).exists()) {
            configPath = possibleCfg;
          }
        }
      } catch (e) {
        _log.e('Error checking database for RetroArch: $e');
      }

      if (configPath == null) {
        for (final p in linuxConfigCandidates(exePath: linuxExePath)) {
          if (await File(p).exists()) {
            configPath = p;
            break;
          }
        }
      }
    } else if (Platform.isMacOS) {
      try {
        final exePath = await EmulatorRepository.getRetroArchExecutablePath();
        if (exePath != null) {
          final dir = path.dirname(exePath);
          final possibleCfg = path.join(dir, 'retroarch.cfg');
          if (await File(possibleCfg).exists()) {
            configPath = possibleCfg;
          }
        }
      } catch (e) {
        _log.e('Error checking database for RetroArch: $e');
      }

      if (configPath == null) {
        final home = ConfigService.getRealHomePath();
        final possiblePaths = [
          path.join(
            home,
            'Library',
            'Application Support',
            'RetroArch',
            'config',
            'retroarch.cfg',
          ),
          path.join(home, 'Documents', 'RetroArch', 'retroarch.cfg'),
        ];
        for (final p in possiblePaths) {
          if (await File(p).exists()) {
            configPath = p;
            break;
          }
        }
      }
    }

    if (configPath != null) {
      try {
        _cachedConfig = await parseConfig(configPath);
        _logResolution(_cachedConfig!);
        return _cachedConfig!;
      } catch (e) {
        _log.e('Error parsing RetroArch config at $configPath: $e');
      }
    }

    var finalConfig = RetroArchConfig(
      configPath: configPath ?? '',
      systemDirectory: null,
      savefileDirectory: null,
      savestateDirectory: null,
    );

    if (Platform.isMacOS) {
      final home = ConfigService.getRealHomePath();
      final defaultSaveDir = path.join(home, 'Documents', 'RetroArch');

      String? saveDir = finalConfig.savefileDirectory;
      if (saveDir == null || !Directory(saveDir).existsSync()) {
        saveDir = defaultSaveDir;
      }

      String? stateDir = finalConfig.savestateDirectory;
      if (stateDir == null || !Directory(stateDir).existsSync()) {
        stateDir = defaultSaveDir;
      }

      finalConfig = RetroArchConfig(
        configPath: finalConfig.configPath,
        systemDirectory: finalConfig.systemDirectory,
        savefileDirectory: saveDir,
        savestateDirectory: stateDir,
      );
    }

    if (Platform.isLinux) {
      final home = ConfigService.getRealHomePath();
      final defaultSaveDir = path.join(home, '.config', 'retroarch', 'saves');
      final defaultStateDir = path.join(home, '.config', 'retroarch', 'states');

      String? saveDir = finalConfig.savefileDirectory;
      if (saveDir == null || !Directory(saveDir).existsSync()) {
        saveDir = defaultSaveDir;
      }

      String? stateDir = finalConfig.savestateDirectory;
      if (stateDir == null || !Directory(stateDir).existsSync()) {
        stateDir = defaultStateDir;
      }

      finalConfig = RetroArchConfig(
        configPath: finalConfig.configPath,
        systemDirectory: finalConfig.systemDirectory,
        savefileDirectory: saveDir,
        savestateDirectory: stateDir,
      );
    }

    if (Platform.isAndroid) {
      const defaultSaveDir = '/storage/emulated/0/RetroArch/saves';
      const defaultStateDir = '/storage/emulated/0/RetroArch/states';

      String? saveDir = finalConfig.savefileDirectory;
      if (saveDir == null || !Directory(saveDir).existsSync()) {
        saveDir = defaultSaveDir;
      }

      String? stateDir = finalConfig.savestateDirectory;
      if (stateDir == null || !Directory(stateDir).existsSync()) {
        stateDir = defaultStateDir;
      }

      finalConfig = RetroArchConfig(
        configPath: finalConfig.configPath,
        systemDirectory: finalConfig.systemDirectory,
        savefileDirectory: saveDir,
        savestateDirectory: stateDir,
      );
    }

    // Logged because this resolution is exactly where a save-sync failure hides:
    // when no config is found the directory *defaults* below are used, and if
    // those point somewhere no RetroArch actually reads, sync moves bytes into
    // a dead tree and still reports success. An empty `cfg=` in this line is
    // the tell.
    _logResolution(finalConfig);

    return finalConfig;
  }

  /// Logs where RetroArch's directories were resolved to, de-duplicated so the
  /// uncached no-config-found path doesn't repeat it on every call.
  ///
  /// This resolution is exactly where a save-sync failure hides: when no config
  /// file is found the platform *defaults* are used, and if those point
  /// somewhere no RetroArch actually reads, sync moves bytes into a dead tree
  /// and still reports success. An empty `cfg=""` in this line is the tell.
  void _logResolution(RetroArchConfig cfg) {
    final signature =
        '${cfg.configPath}|${cfg.savefileDirectory}|${cfg.savestateDirectory}|'
        '${cfg.sortSavefilesByCore}|${cfg.sortSavestatesByCore}';
    if (signature == _lastLoggedResolution) return;
    _lastLoggedResolution = signature;
    _log.i(
      'RetroArch config resolved: cfg="${cfg.configPath}" '
      'saves="${cfg.savefileDirectory}" states="${cfg.savestateDirectory}" '
      'sortSaves=${cfg.sortSavefilesByCore} '
      'sortStates=${cfg.sortSavestatesByCore}',
    );
  }

  /// Clears the in-memory configuration cache.
  void clearCache() {
    _cachedConfig = null;
  }

  /// Returns the expected absolute paths for the 4 Dreamcast VMU save files
  /// based on the provided RetroArch system directory.
  List<String> getDreamcastSavePaths(String systemDir) {
    final dcFolder = path.join(systemDir, 'dc');

    return [
      path.join(dcFolder, 'vmu_save_A1.bin'),
      path.join(dcFolder, 'vmu_save_B1.bin'),
      path.join(dcFolder, 'vmu_save_C1.bin'),
      path.join(dcFolder, 'vmu_save_D1.bin'),
    ];
  }
}
