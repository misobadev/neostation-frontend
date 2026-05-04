import 'dart:io';
import 'package:flutter/services.dart';
import 'package:neostation/services/logger_service.dart';
import 'package:neostation/services/saf_directory_service.dart';
import 'package:path/path.dart' as path;
import '../repositories/emulator_repository.dart';

/// Service responsible for detecting Nintendo Switch save data for emulators such as Yuzu, Citron, and Eden.
///
/// Locates save files by parsing emulator configuration files and searching within NAND directories
/// using specific Title IDs.
class SwitchSaveDetector {
  static final _log = LoggerService.instance;

  /// Retrieves a list of potential configuration file paths based on the current platform.
  static List<String> _getConfigPaths() {
    final paths = <String>[];

    if (Platform.isAndroid) {
      // Standard Android data paths for supported emulators.
      final androidDataBase = '/storage/emulated/0/Android/data';

      // Eden Variants
      paths.add(
        path.join(
          androidDataBase,
          'dev.eden.eden_emulator',
          'files',
          'config',
          'config.ini',
        ),
      );
      paths.add(
        path.join(
          androidDataBase,
          'dev.legacy.eden_emulator',
          'files',
          'config',
          'config.ini',
        ),
      );
      paths.add(
        path.join(
          androidDataBase,
          'com.miHoYo.Yuanshen',
          'files',
          'config',
          'config.ini',
        ),
      );
      paths.add(
        path.join(
          androidDataBase,
          'dev.eden.eden_nightly',
          'files',
          'config',
          'config.ini',
        ),
      );

      // Citron
      paths.add(
        path.join(
          androidDataBase,
          'org.citron.citron_emu',
          'files',
          'config',
          'config.ini',
        ),
      );
    } else if (Platform.isWindows) {
      final appData = Platform.environment['APPDATA'];

      // Standard Roaming AppData paths.
      if (appData != null) {
        paths.add(path.join(appData, 'eden', 'config', 'qt-config.ini'));
        paths.add(path.join(appData, 'yuzu', 'config', 'qt-config.ini'));
      }
    } else if (Platform.isLinux) {
      final home = Platform.environment['HOME'];

      if (home != null) {
        // Standard and Flatpak paths.
        paths.add(
          path.join(home, '.local', 'share', 'yuzu', 'config', 'qt-config.ini'),
        );
        paths.add(
          path.join(home, '.local', 'share', 'eden', 'config', 'qt-config.ini'),
        );
        paths.add(
          path.join(
            home,
            '.var',
            'app',
            'org.yuzu_emu.yuzu',
            'config',
            'yuzu',
            'qt-config.ini',
          ),
        );
      }
    } else if (Platform.isMacOS) {
      final home = Platform.environment['HOME'];
      if (home != null) {
        paths.add(
          path.join(
            home,
            'Library',
            'Application Support',
            'eden',
            'config',
            'qt-config.ini',
          ),
        );
        paths.add(
          path.join(
            home,
            'Library',
            'Application Support',
            'citron',
            'config',
            'qt-config.ini',
          ),
        );
      }
    }

    return paths;
  }

  /// Parses an INI configuration file to extract the `nand_directory` or `save_directory`.
  static String? _parseNandDirectory(
    String configContent, {
    bool isAndroid = false,
  }) {
    try {
      final lines = configContent.split('\n');

      if (isAndroid) {
        String? nandValue;
        String? saveValue;

        // Simple key-value parsing for Android INI files.
        for (var line in lines) {
          line = line.trim();
          if (line.startsWith('nand_directory=')) {
            nandValue = line.substring('nand_directory='.length).trim();
          } else if (line.startsWith('save_directory=')) {
            saveValue = line.substring('save_directory='.length).trim();
          }
        }
        return (saveValue != null && saveValue.isNotEmpty)
            ? saveValue
            : nandValue;
      } else {
        // Qt-style INI parsing for desktop platforms.
        bool inDataStorageSection = false;
        String? nandValue;
        String? saveValue;

        for (var line in lines) {
          line = line.trim();

          if (line == '[Data%20Storage]' || line == '[Data Storage]') {
            inDataStorageSection = true;
            continue;
          }

          if (line.startsWith('[') && inDataStorageSection) break;

          if (inDataStorageSection) {
            if (line.startsWith('nand_directory=')) {
              nandValue = line.substring('nand_directory='.length).trim();
            } else if (line.startsWith('save_directory=')) {
              saveValue = line.substring('save_directory='.length).trim();
            }
          }
        }

        final bestValue = (saveValue != null && saveValue.isNotEmpty)
            ? saveValue
            : nandValue;
        if (bestValue != null && bestValue.isNotEmpty) {
          // Normalize path separators from Qt format (/) to native format.
          return bestValue.replaceAll('/', Platform.pathSeparator);
        }
      }
    } catch (e) {
      _log.e('Error parsing configuration file: $e');
    }
    return null;
  }

  /// Checks if a directory exists without throwing on permission errors.
  static Future<bool> _directoryExistsSafe(String dirPath) async {
    try {
      if (dirPath.startsWith('content://')) {
        await SafDirectoryService.listFiles(dirPath);
        return true; // If list succeeds, directory exists and is accessible
      }
      return await Directory(dirPath).exists();
    } on PathAccessException catch (_) {
      return false;
    } catch (e) {
      _log.d('Directory existence check failed for $dirPath: $e');
      return false;
    }
  }

  /// Lists a directory handling both filesystem paths and SAF URIs.
  static Future<List<dynamic>> _listDirectory(String dirPath) async {
    if (dirPath.startsWith('content://')) {
      return SafDirectoryService.listFiles(dirPath);
    }
    return Directory(dirPath).list().toList();
  }

  /// Checks if a directory is non-empty.
  static Future<bool> _isDirectoryNonEmpty(String dirPath) async {
    if (dirPath.startsWith('content://')) {
      final entries = await SafDirectoryService.listFiles(dirPath);
      return entries.isNotEmpty;
    }
    try {
      return await Directory(dirPath).list().isEmpty == false;
    } catch (e) {
      return false;
    }
  }

  /// Attempts to mirror the emulator's NAND directory to local app storage.
  /// Uses native tricks (zero-width bypass, SAF external provider) on Android 11+.
  static Future<String?> _mirrorEmulatorNandNative(
    String packageName,
    String emulatorName,
  ) async {
    try {
      _log.i('Mirroring NAND for $packageName ($emulatorName) via native...');
      const platform = MethodChannel('com.neogamelab.neostation/game');
      final mirrorPath = await platform.invokeMethod<String>(
        'mirrorEmulatorNand',
        {'packageName': packageName, 'emulatorName': emulatorName},
      );
      if (mirrorPath != null) {
        _log.i('Native mirror success for $emulatorName: $mirrorPath');
      } else {
        _log.w('Native mirror failed for $emulatorName');
      }
      return mirrorPath;
    } catch (e) {
      _log.d('Native mirror error for $packageName: $e');
      return null;
    }
  }

  /// Detects all active emulator installations and their respective NAND directories.
  static Future<List<EmulatorNandInfo>> detectEmulatorNandPaths() async {
    final results = <EmulatorNandInfo>[];

    if (Platform.isAndroid) {
      final androidDataBase = '/storage/emulated/0/Android/data';
      final androidEmulators = [
        {'name': 'Eden', 'package': 'dev.eden.eden_emulator'},
        {'name': 'Eden Legacy', 'package': 'dev.legacy.eden_emulator'},
        {'name': 'Eden Optimized', 'package': 'com.miHoYo.Yuanshen'},
        {'name': 'Eden Nightly', 'package': 'dev.eden.eden_nightly'},
        {'name': 'Citron', 'package': 'org.citron.citron_emu'},
      ];

      for (var emu in androidEmulators) {
        String? detectedNandPath;
        String? detectedConfigPath;
        bool detectedViaSaf = false;

        try {
          final packageName = emu['package']!;
          final defaultNandPath = path.join(
            androidDataBase,
            packageName,
            'files',
            'nand',
          );
          final configPath = path.join(
            androidDataBase,
            packageName,
            'files',
            'config',
            'config.ini',
          );

          detectedConfigPath = configPath;
          String nandPath = defaultNandPath;

          // Try filesystem access first
          try {
            final configFile = File(configPath);
            if (await configFile.exists()) {
              final content = await configFile.readAsString();
              final customNandPath = _parseNandDirectory(
                content,
                isAndroid: true,
              );
              if (customNandPath != null && customNandPath.isNotEmpty) {
                nandPath = customNandPath;
              }
            }
          } catch (_) {
            // Config may be inaccessible due to scoped storage
          }

          if (await _directoryExistsSafe(nandPath)) {
            detectedNandPath = nandPath;
          } else {
            // Fallback: try native mirror with bypass tricks
            final mirrorPath = await _mirrorEmulatorNandNative(
              packageName,
              emu['name']!,
            );
            if (mirrorPath != null) {
              detectedNandPath = mirrorPath;
              detectedViaSaf = true;
            }
          }

          if (detectedNandPath != null) {
            results.add(
              EmulatorNandInfo(
                emulatorName: emu['name']!,
                configPath: detectedConfigPath,
                nandDirectory: detectedNandPath,
                isSafUri: detectedViaSaf,
              ),
            );
          }
        } catch (e) {
          _log.e('Error detecting Android emulator ${emu['name']}: $e');
        }
      }
    } else {
      final configPaths = _getConfigPaths();

      // For Windows, explicitly query the active emulator defined in the database.
      if (Platform.isWindows) {
        try {
          final emulators =
              await EmulatorRepository.getStandaloneEmulatorsBySystemId(
                'switch',
              );
          for (final emu in emulators) {
            if (emu['is_user_default'] == 1 || emu['is_default'] == 1) {
              final exePath = emu['emulator_path']?.toString();
              if (exePath != null && exePath.trim().isNotEmpty) {
                // Check for portable configuration folders.
                final portableConfig = path.join(
                  path.dirname(exePath),
                  'user',
                  'config',
                  'qt-config.ini',
                );
                if (!configPaths.contains(portableConfig)) {
                  configPaths.add(portableConfig);
                }
              }
            }
          }
        } catch (e) {
          _log.e('Error querying active emulators from database: $e');
        }
      }

      for (var configPath in configPaths) {
        try {
          final configFile = File(configPath);
          if (await configFile.exists()) {
            final content = await configFile.readAsString();
            final nandPath = _parseNandDirectory(content, isAndroid: false);

            if (nandPath != null &&
                nandPath.isNotEmpty &&
                await Directory(nandPath).exists()) {
              String emulatorName = 'Unknown';
              final lowerPath = configPath.toLowerCase();

              if (lowerPath.contains('eden')) {
                emulatorName = 'Eden';
              } else if (lowerPath.contains('citron')) {
                emulatorName = 'Citron';
              } else {
                continue; // Skip unrecognized emulators for NeoSync compatibility.
              }

              results.add(
                EmulatorNandInfo(
                  emulatorName: emulatorName,
                  configPath: configPath,
                  nandDirectory: nandPath,
                  isSafUri: false,
                ),
              );
            }
          }
        } catch (e) {
          _log.e('Error verifying configuration at $configPath: $e');
        }
      }

      // Linux Fallback: check default paths if config parsing failed or was skipped.
      if (Platform.isLinux) {
        final home = Platform.environment['HOME'];
        if (home != null) {
          final linuxDefaults = [
            {
              'name': 'Eden',
              'nand': path.join(home, '.local', 'share', 'eden', 'nand'),
              'config': path.join(
                home,
                '.local',
                'share',
                'eden',
                'config',
                'qt-config.ini',
              ),
            },
            {
              'name': 'Citron',
              'nand': path.join(home, '.local', 'share', 'citron', 'nand'),
              'config': path.join(
                home,
                '.local',
                'share',
                'citron',
                'config',
                'qt-config.ini',
              ),
            },
          ];

          for (var def in linuxDefaults) {
            final nandDir = def['nand']!;
            if (!results.any(
                  (r) =>
                      r.emulatorName == def['name'] &&
                      r.nandDirectory == nandDir,
                ) &&
                await Directory(nandDir).exists()) {
              results.add(
                EmulatorNandInfo(
                  emulatorName: def['name']!,
                  configPath: def['config']!,
                  nandDirectory: nandDir,
                  isSafUri: false,
                ),
              );
            }
          }
        }
      }
    }

    return results;
  }

  /// Locates the save data for a specific Title ID within a given NAND directory.
  static Future<SwitchSaveInfo?> findSaveForTitleId(
    String nandDirectory,
    String titleId,
  ) async {
    try {
      // Standard save path structure: nand/user/save/0000000000000000/[USER_ID]/[TITLE_ID]/
      final saveBasePath = path.join(
        nandDirectory,
        'user',
        'save',
        '0000000000000000',
      );

      if (!await _directoryExistsSafe(saveBasePath)) return null;

      final userIdEntries = await _listDirectory(saveBasePath);

      for (var userIdEntity in userIdEntries) {
        String userIdPath;
        if (nandDirectory.startsWith('content://')) {
          if (userIdEntity is! Map || userIdEntity['is_directory'] != true) {
            continue;
          }
          userIdPath = userIdEntity['uri']!.toString();
        } else {
          if (userIdEntity is! Directory) continue;
          userIdPath = userIdEntity.path;
        }

        final titleIdPath = path.join(userIdPath, titleId);

        if (await _directoryExistsSafe(titleIdPath) &&
            await _isDirectoryNonEmpty(titleIdPath)) {
          return SwitchSaveInfo(
            titleId: titleId,
            savePath: titleIdPath,
            userId: path.basename(userIdPath),
            nandDirectory: nandDirectory,
          );
        }
      }
    } catch (e) {
      _log.e('Error locating save for Title ID $titleId: $e');
    }
    return null;
  }

  /// Searches for a specific Title ID's save data across all detected emulators.
  static Future<List<SwitchSaveInfo>> findSaveAcrossEmulators(
    String titleId,
  ) async {
    final results = <SwitchSaveInfo>[];
    final emulators = await detectEmulatorNandPaths();

    for (var emulator in emulators) {
      final saveInfo = await findSaveForTitleId(
        emulator.nandDirectory,
        titleId,
      );
      if (saveInfo != null) {
        results.add(
          SwitchSaveInfo(
            titleId: saveInfo.titleId,
            savePath: saveInfo.savePath,
            userId: saveInfo.userId,
            nandDirectory: saveInfo.nandDirectory,
            emulatorName: emulator.emulatorName,
          ),
        );
      }
    }
    return results;
  }

  /// Lists all available save data entries found in a specific NAND directory.
  static Future<List<SwitchSaveInfo>> listAllSavesInNand(
    String nandDirectory,
  ) async {
    final results = <SwitchSaveInfo>[];

    try {
      final saveBasePath = path.join(
        nandDirectory,
        'user',
        'save',
        '0000000000000000',
      );
      if (!await _directoryExistsSafe(saveBasePath)) return results;

      final userIdEntries = await _listDirectory(saveBasePath);

      for (var userIdEntity in userIdEntries) {
        String userIdPath;
        String userId;
        if (nandDirectory.startsWith('content://')) {
          if (userIdEntity is! Map || userIdEntity['is_directory'] != true) {
            continue;
          }
          userIdPath = userIdEntity['uri']!.toString();
          userId = userIdEntity['name']!.toString();
        } else {
          if (userIdEntity is! Directory) continue;
          userIdPath = userIdEntity.path;
          userId = path.basename(userIdPath);
        }

        final titleIdEntries = await _listDirectory(userIdPath);

        for (var titleIdEntity in titleIdEntries) {
          String titleIdPath;
          String titleId;
          if (nandDirectory.startsWith('content://')) {
            if (titleIdEntity is! Map ||
                titleIdEntity['is_directory'] != true) {
              continue;
            }
            titleIdPath = titleIdEntity['uri']!.toString();
            titleId = titleIdEntity['name']!.toString();
          } else {
            if (titleIdEntity is! Directory) continue;
            titleIdPath = titleIdEntity.path;
            titleId = path.basename(titleIdPath);
          }

          // Validate Title ID format (16 hexadecimal characters).
          if (RegExp(r'^[0-9A-F]{16}$').hasMatch(titleId)) {
            if (await _isDirectoryNonEmpty(titleIdPath)) {
              results.add(
                SwitchSaveInfo(
                  titleId: titleId,
                  savePath: titleIdPath,
                  userId: userId,
                  nandDirectory: nandDirectory,
                ),
              );
            }
          }
        }
      }
    } catch (e) {
      _log.e('Error listing save entries: $e');
    }
    return results;
  }

  /// Aggregates all save data found across all detected emulators.
  static Future<Map<String, List<SwitchSaveInfo>>>
  listAllSavesAcrossEmulators() async {
    final results = <String, List<SwitchSaveInfo>>{};
    final emulators = await detectEmulatorNandPaths();

    for (var emulator in emulators) {
      final saves = await listAllSavesInNand(emulator.nandDirectory);
      results[emulator.emulatorName] = saves
          .map(
            (save) => SwitchSaveInfo(
              titleId: save.titleId,
              savePath: save.savePath,
              userId: save.userId,
              nandDirectory: save.nandDirectory,
              emulatorName: emulator.emulatorName,
            ),
          )
          .toList();
    }
    return results;
  }

  /// Recursively calculates the total size in bytes of a save directory.
  static Future<int> calculateSaveSize(String savePath) async {
    int totalSize = 0;
    try {
      if (!await _directoryExistsSafe(savePath)) return 0;

      if (savePath.startsWith('content://')) {
        totalSize = await _calculateSafSaveSize(savePath);
      } else {
        await for (var entity in Directory(
          savePath,
        ).list(recursive: true, followLinks: false)) {
          if (entity is File) {
            totalSize += (await entity.stat()).size;
          }
        }
      }
    } catch (e) {
      _log.e('Error calculating save size: $e');
    }
    return totalSize;
  }

  /// Recursively calculates save size for SAF URIs.
  static Future<int> _calculateSafSaveSize(String uri) async {
    int totalSize = 0;
    final entries = await SafDirectoryService.listFiles(uri);
    for (final entry in entries) {
      if (entry['is_directory'] == true) {
        totalSize += await _calculateSafSaveSize(entry['uri']!.toString());
      } else {
        totalSize += await SafDirectoryService.getFileSize(
          entry['uri']!.toString(),
        );
      }
    }
    return totalSize;
  }
}

/// Holds NAND location and metadata for a specific emulator installation.
class EmulatorNandInfo {
  final String emulatorName;
  final String configPath;
  final String nandDirectory;
  final bool isSafUri;

  EmulatorNandInfo({
    required this.emulatorName,
    required this.configPath,
    required this.nandDirectory,
    this.isSafUri = false,
  });

  @override
  String toString() => '$emulatorName: $nandDirectory';
}

/// Metadata identifying a specific Nintendo Switch save entry.
class SwitchSaveInfo {
  /// The 16-character hexadecimal Title ID of the game.
  final String titleId;

  /// Full filesystem path to the save directory.
  final String savePath;

  /// The 32-character hexadecimal User ID hash associated with the save.
  final String userId;

  /// The root NAND directory containing this save.
  final String nandDirectory;

  /// The name of the emulator where this save was located.
  final String? emulatorName;

  SwitchSaveInfo({
    required this.titleId,
    required this.savePath,
    required this.userId,
    required this.nandDirectory,
    this.emulatorName,
  });

  @override
  String toString() {
    final emu = emulatorName != null ? '[$emulatorName] ' : '';
    return '${emu}Title: $titleId, Path: $savePath';
  }

  /// Unique identifier generated from the Title ID and User ID.
  String get uniqueId => '$titleId-$userId';
}
