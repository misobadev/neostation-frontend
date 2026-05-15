import '../../models/database_game_model.dart';
import '../../models/system_model.dart';
import '../../models/emulator_model.dart';
import '../../utils/switch_title_extractor.dart';
import 'sqlite_service.dart';
import 'sqlite_config_service.dart';
import '../../utils/vita_title_extractor.dart';
import 'package:neostation/services/android_service.dart';
import 'package:neostation/services/saf_directory_service.dart';
import 'package:neostation/services/logger_service.dart';
import 'dart:io';
import 'dart:convert';
import 'package:path/path.dart' as path;

/// Summary report of a ROM scanning operation for a specific system.
class ScanSummary {
  /// Number of new ROMs discovered and added to the database.
  final int added;

  /// Number of orphaned ROMs (deleted from disk) removed from the database.
  final int removed;

  /// Total count of ROMs for the system after the scan.
  final int total;

  /// Human-readable name of the system scanned.
  final String systemName;

  ScanSummary({
    required this.added,
    required this.removed,
    required this.total,
    required this.systemName,
  });

  /// Returns true if any files were added or removed during the scan.
  bool get hasChanges => added > 0 || removed > 0;
}

/// Lightweight container for file discovery metadata.
class RomEntry {
  /// Absolute file system path or SAF URI.
  final String path;

  /// Base name of the file with extension.
  final String filename;

  /// File size in bytes.
  final int size;

  RomEntry({required this.path, required this.filename, this.size = 0});
}

/// Service responsible for managing ROM discovery, filesystem synchronization,
/// and metadata extraction using SQLite.
///
/// Features:
/// - Cross-platform scanning (Standard Filesystem and Android SAF).
/// - Recursive and case-insensitive directory traversal.
/// - Playlist-aware filtering (M3U) and redundancy deduplication (CUE/BIN).
/// - Specialized metadata extraction for Switch (Title ID/Name) and Vita games.
/// - Batch database operations with performance-tuned SQLite PRAGMAs.
class SqliteDatabaseService {
  static final _log = LoggerService.instance;

  /// Retrieves the complete game database, grouped by system folder name.
  static Future<Map<String, List<DatabaseGameModel>>> loadDatabase() async {
    try {
      final detectedSystems = await SqliteService.getUserDetectedSystems();
      final database = <String, List<DatabaseGameModel>>{};

      for (final system in detectedSystems) {
        final games = await SqliteService.getRomsForSystem(system.folderName);
        database[system.folderName] = games;
      }

      return database;
    } catch (e) {
      _log.e('Error loading database from SQLite: $e');
      return {};
    }
  }

  /// Fetches all games registered for a specific system folder.
  static Future<List<DatabaseGameModel>> loadGamesForSystem(
    String systemFolderName,
  ) async {
    try {
      final systemId = await _getSystemIdByFolderName(systemFolderName);
      if (systemId != null) {
        return await SqliteService.getGamesBySystem(systemId);
      }
      return await SqliteService.getRomsForSystem(systemFolderName);
    } catch (e) {
      _log.e('Error loading games for $systemFolderName: $e');
      return [];
    }
  }

  /// Initiates an optimized ROM scan for a specific system across multiple folders.
  ///
  /// Includes time-out protection (10 minutes) and specific handling for
  /// the integrated Android application system.
  static Future<ScanSummary> scanSystemRoms(
    SystemModel system,
    List<String> romFolders, {
    Map<String, Map<String, String>>? rootFoldersMap,
  }) async {
    if (system.id == null) {
      _log.e('System without ID: ${system.realName}');
      return ScanSummary(
        added: 0,
        removed: 0,
        total: 0,
        systemName: system.realName,
      );
    }

    final validExtensions = await SqliteService.getExtensionsForSystem(
      system.id!,
    );
    final validExtensionsSet = validExtensions
        .map((e) => e.toLowerCase())
        .toSet();

    // Support for metadata-only .steam files
    validExtensionsSet.add('steam');

    return await Future.any([
      _performSystemScan(
        system,
        romFolders,
        validExtensionsSet,
        rootFoldersMap: rootFoldersMap,
      ),
      Future.delayed(const Duration(minutes: 10), () {
        throw Exception('Timeout scanning ${system.realName}');
      }),
    ]).catchError((error) {
      _log.e('Error or timeout scanning ${system.realName}: $error');
      return ScanSummary(
        added: 0,
        removed: 0,
        total: 0,
        systemName: system.realName,
      );
    });
  }

  /// Orchestrates the physical directory scan and database synchronization logic.
  static Future<ScanSummary> _performSystemScan(
    SystemModel system,
    List<String> romFolders,
    Set<String> validExtensionsSet, {
    Map<String, Map<String, String>>? rootFoldersMap,
  }) async {
    final initialCount = await SqliteService.getRomCountForSystem(system.id!);

    if (Platform.isAndroid && (system.folderName == 'android')) {
      await _performAndroidSystemScan(system, system.folderName);
      final finalCount = await SqliteService.getRomCountForSystem(system.id!);
      return ScanSummary(
        added: (finalCount - initialCount).clamp(0, 999999),
        removed: 0,
        total: finalCount,
        systemName: system.realName,
      );
    }

    final stopwatch = Stopwatch()..start();
    final allPossibleFolderNames =
        await SqliteService.getAllFolderNamesForSystem(system.id!);

    final List<RomEntry> romEntries = [];

    for (final romFolder in romFolders) {
      final bool useSaf =
          Platform.isAndroid && romFolder.startsWith('content://');
      final Map<String, String>? subdirsForRoot = rootFoldersMap?[romFolder];

      for (final folderToScan in allPossibleFolderNames) {
        try {
          List<RomEntry> entries;

          if (subdirsForRoot != null) {
            final folderLower = folderToScan.toLowerCase();
            final resolvedPath = subdirsForRoot[folderLower];

            if (resolvedPath != null) {
              if (useSaf) {
                entries = await _scanSafUri(
                  resolvedPath,
                  validExtensionsSet,
                  system.recursiveScan,
                );
              } else {
                entries = await _scanStandardPath(
                  resolvedPath,
                  validExtensionsSet,
                  system.recursiveScan,
                );
              }
            } else {
              continue;
            }
          } else {
            if (useSaf) {
              entries = await _scanSafFolder(
                romFolder,
                folderToScan,
                validExtensionsSet,
                system.recursiveScan,
              );
            } else {
              entries = await _scanStandardFolder(
                romFolder,
                folderToScan,
                validExtensionsSet,
                system.recursiveScan,
              );
            }
          }

          if (entries.isNotEmpty) {
            romEntries.addAll(entries);
          }
        } catch (e) {
          _log.e('Error scanning folder $folderToScan in $romFolder: $e');
        }
      }
    }

    // Apply M3U and redundancy filters
    if (validExtensionsSet.contains('m3u') && romEntries.isNotEmpty) {
      final bool useSaf =
          Platform.isAndroid &&
          romFolders.any((f) => f.startsWith('content://'));
      final m3uFiltered = await _filterM3uReferencedFiles(romEntries, useSaf);
      romEntries
        ..clear()
        ..addAll(m3uFiltered);
    }

    final deduplicatedEntries = _filterDeduplicatedRoms(romEntries);
    romEntries
      ..clear()
      ..addAll(deduplicatedEntries);

    // Clean orphaned entries (files deleted from disk)
    final removedCount = await _cleanupOrphanedRomsOptimized(
      system.id!,
      romEntries.map((e) => e.path).toSet(),
    );

    if (romEntries.isEmpty) {
      final finalCount = await SqliteService.getRomCountForSystem(system.id!);
      return ScanSummary(
        added: 0,
        removed: removedCount,
        total: finalCount,
        systemName: system.realName,
      );
    }

    // Batch insertion with dynamic batch size tuning
    final batchSize = _calculateOptimalBatchSize(romEntries.length);
    final batches = <List<RomEntry>>[];
    for (int i = 0; i < romEntries.length; i += batchSize) {
      batches.add(
        romEntries.sublist(
          i,
          (i + batchSize < romEntries.length)
              ? i + batchSize
              : romEntries.length,
        ),
      );
    }

    final primaryFolderName = system.folderName;
    for (final batch in batches) {
      await _batchInsertRoms(primaryFolderName, batch);
    }

    stopwatch.stop();
    final finalCount = await SqliteService.getRomCountForSystem(system.id!);
    final addedCount = (finalCount - initialCount + removedCount).clamp(
      0,
      999999,
    );

    return ScanSummary(
      added: addedCount,
      removed: removedCount,
      total: finalCount,
      systemName: system.realName,
    );
  }

  /// Toggles the favorite status of a game.
  static Future<void> toggleFavorite(
    String systemFolderName,
    String filename,
  ) async {
    try {
      final system = await SqliteService.getSystemByFolderName(
        systemFolderName,
      );
      final game = await SqliteService.getSingleGame(system.id!, filename);
      if (game != null && game.romPath.isNotEmpty) {
        await SqliteService.toggleRomFavorite(game.romPath);
      }
    } catch (e) {
      _log.e('Error toggling favorite: $e');
      rethrow;
    }
  }

  /// Updates the last played timestamp and execution statistics for a game.
  static Future<void> recordGamePlayed(
    String systemFolderName,
    String filename,
  ) async {
    try {
      final system = await SqliteService.getSystemByFolderName(
        systemFolderName,
      );
      final game = await SqliteService.getSingleGame(system.id!, filename);
      if (game != null && game.romPath.isNotEmpty) {
        await SqliteService.recordRomPlayed(game.romPath);
      }
    } catch (e) {
      _log.e('Error recording game played: $e');
      rethrow;
    }
  }

  /// Updates the database record for a specific game, including metadata and emulator assignment.
  static Future<void> updateGame(
    String systemFolderName,
    DatabaseGameModel updatedGame,
  ) async {
    try {
      if (updatedGame.emulatorName == null) {
        throw Exception('Emulator name is required to update game');
      }
      await SqliteService.saveRom(
        systemFolderName: systemFolderName,
        filename: updatedGame.filename,
        romPath: updatedGame.romPath,
        emulatorName: updatedGame.emulatorName!,
        coreName: updatedGame.coreName,
        isFavorite: updatedGame.isFavorite,
        lastPlayed: updatedGame.lastPlayed,
        playTime: updatedGame.playTime ?? 0,
      );
    } catch (e) {
      _log.e('Error updating game: $e');
      rethrow;
    }
  }

  /// Retrieves global application statistics (total systems, ROMs, favorites).
  static Future<Map<String, dynamic>> getStats() async {
    try {
      return await SqliteService.getStats();
    } catch (e) {
      _log.e('Error getting stats: $e');
      return {
        'totalSystems': 0,
        'totalRoms': 0,
        'favoriteRoms': 0,
        'playedRoms': 0,
      };
    }
  }

  /// Retrieves the current ROM count for all detected systems.
  static Future<Map<String, int>> getRomCounts() async {
    try {
      final detectedSystems = await SqliteService.getUserDetectedSystems();
      final counts = <String, int>{};
      for (final system in detectedSystems) {
        final games = await SqliteService.getGamesBySystem(system.id!);
        counts[system.folderName] = games.length;
      }
      return counts;
    } catch (e) {
      _log.e('Error getting ROM counts: $e');
      return {};
    }
  }

  /// Scans for supported emulator installations.
  static Future<Map<String, EmulatorModel>> detectEmulators() async {
    return await SqliteConfigService.detectEmulators();
  }

  /// Optimizes the SQLite database engine for high-concurrency and batch I/O operations.
  ///
  /// Configures synchronous mode, WAL journaling, cache size, and memory mapping.
  static Future<void> initialize() async {
    try {
      final db = await SqliteService.getDatabase();
      await db.execute('PRAGMA synchronous = NORMAL');
      await db.execute('PRAGMA cache_size = 10000');
      await db.execute('PRAGMA temp_store = MEMORY');
      await db.execute('PRAGMA mmap_size = 268435456');
    } catch (e) {
      _log.e('Error initializing SQLite database: $e');
      rethrow;
    }
  }

  /// Calculates a tuned batch size for insertions based on the total file count.
  static int _calculateOptimalBatchSize(int totalFiles) {
    if (totalFiles <= 10) return totalFiles;
    if (totalFiles <= 50) return 10;
    if (totalFiles <= 200) return 20;
    return 25;
  }

  /// Executes a high-performance batch insertion of multiple ROM entries.
  ///
  /// Handles platform-specific metadata extraction (Switch title info, Vita
  /// Title IDs, Steam App IDs) during the operation.
  static Future<void> _batchInsertRoms(
    String systemFolderName,
    List<RomEntry> romEntries,
  ) async {
    if (romEntries.isEmpty) return;

    final db = await SqliteService.getDatabase();
    final system = await SqliteService.getSystemByFolderName(systemFolderName);
    final systemId = system.id!;
    final isSwitch = systemId == 'switch' || systemId == 'nintendo-switch';

    if (isSwitch) await SwitchTitleExtractor.loadKeys();

    await db.transaction((txn) async {
      const sql = '''
        INSERT INTO user_roms
        (app_system_id, app_emulator_unique_id, app_emulator_os_id, filename, rom_path, title_id, title_name, created_at)
        VALUES (
          ?,
          (SELECT e.unique_identifier FROM app_emulators e WHERE e.system_id = ? AND e.os_id = 1 AND e.is_default = 1 LIMIT 1),
          (SELECT e.os_id FROM app_emulators e WHERE e.system_id = ? AND e.os_id = 1 AND e.is_default = 1 LIMIT 1),
          ?, ?, ?, ?, datetime('now')
        )
        ON CONFLICT(rom_path) DO UPDATE SET
          title_id = COALESCE(EXCLUDED.title_id, title_id),
          title_name = COALESCE(EXCLUDED.title_name, title_name),
          updated_at = datetime('now')
      ''';

      final batch = txn.batch();
      for (final entry in romEntries) {
        String? titleId;
        String? titleName;

        if (isSwitch && !entry.path.startsWith('content://')) {
          try {
            final info = await SwitchTitleExtractor.extractGameInfo(entry.path);
            if (info != null) {
              titleId = info.titleId;
              titleName = info.gameName;
            }
          } catch (_) {}
        }

        if (entry.filename.toLowerCase().endsWith('.psvita')) {
          titleId = await VitaTitleExtractor.extractTitleId(entry.path);
        }

        if (entry.filename.toLowerCase().endsWith('.steam')) {
          try {
            final bool isSaf = entry.path.startsWith('content://');
            String? content;
            if (isSaf) {
              final bytes = await SafDirectoryService.readRange(
                entry.path,
                0,
                entry.size > 0 ? entry.size : 1024,
              );
              if (bytes != null) content = utf8.decode(bytes);
            } else {
              final file = File(entry.path);
              if (await file.exists()) content = await file.readAsString();
            }
            if (content != null) {
              final trimmed = content.trim();
              if (RegExp(r'^\d+$').hasMatch(trimmed)) titleId = trimmed;
            }
          } catch (_) {}
        }

        const windowsIdExts = {
          '.localgameid',
          '.steam',
          '.epic',
          '.gog',
          '.amazon',
          '.pcgame',
          '.customgame',
        };
        if (titleId == null &&
            windowsIdExts.any(entry.filename.toLowerCase().endsWith)) {
          try {
            final bool isSaf = entry.path.startsWith('content://');
            String? content;
            if (isSaf) {
              final bytes = await SafDirectoryService.readRange(
                entry.path,
                0,
                1024,
              );
              if (bytes != null) content = utf8.decode(bytes);
            } else {
              final file = File(entry.path);
              if (await file.exists()) content = await file.readAsString();
            }
            if (content != null && content.trim().isNotEmpty) {
              titleId = content.trim();
            }
          } catch (_) {}
        }

        batch.rawInsert(sql, [
          systemId,
          systemId,
          systemId,
          entry.filename,
          entry.path,
          titleId,
          titleName,
        ]);
      }
      await batch.commit(noResult: true);
    });
  }

  /// Filters out redundant game files listed within M3U playlists.
  static Future<List<RomEntry>> _filterM3uReferencedFiles(
    List<RomEntry> entries,
    bool useSaf,
  ) async {
    final m3uEntries = entries
        .where((e) => path.extension(e.filename).toLowerCase() == '.m3u')
        .toList();
    // No M3U files present → return a copy (never the same reference, to avoid
    // the ..clear()..addAll() aliasing bug in the caller).
    if (m3uEntries.isEmpty) return List<RomEntry>.from(entries);

    final referencedFilenames = <String>{};
    for (final m3u in m3uEntries) {
      try {
        List<String> lines;
        if (useSaf) {
          final bytes = await SafDirectoryService.readRange(m3u.path, 0, 65536);
          if (bytes == null) continue;
          lines = utf8.decode(bytes).split('\n');
        } else {
          lines = await File(m3u.path).readAsLines();
        }
        for (final line in lines) {
          final trimmed = line.trim();
          if (trimmed.isEmpty || trimmed.startsWith('#')) continue;
          referencedFilenames.add(path.basename(trimmed).toLowerCase());
        }
      } catch (_) {}
    }

    // No references found → return copy (same aliasing protection).
    if (referencedFilenames.isEmpty) return List<RomEntry>.from(entries);
    return entries.where((e) {
      if (path.extension(e.filename).toLowerCase() == '.m3u') return true;
      return !referencedFilenames.contains(e.filename.toLowerCase());
    }).toList();
  }

  /// Deduplicates ROM entries by identifying master files (CUE/GDI/M3U) and
  /// excluding their constituent tracks (BIN/ISO/WAV).
  static List<RomEntry> _filterDeduplicatedRoms(List<RomEntry> entries) {
    if (entries.isEmpty) return List<RomEntry>.from(entries);

    final Map<String, List<RomEntry>> grouped = {};
    for (final entry in entries) {
      final dir = path.dirname(entry.path);
      grouped.putIfAbsent(dir, () => []).add(entry);
    }

    final List<RomEntry> filtered = [];
    final masterExts = {'.cue', '.gdi', '.m3u', '.ccd'};
    final candidateExts = {
      '.bin',
      '.iso',
      '.img',
      '.sub',
      '.dat',
      '.wav',
      '.flac',
    };
    final trackRegex = RegExp(
      r'[\s_\-]\(?[Tt]rack\s?\d+\)?',
      caseSensitive: false,
    );

    for (final dirEntries in grouped.values) {
      final masters = dirEntries
          .where(
            (e) =>
                masterExts.contains(path.extension(e.filename).toLowerCase()),
          )
          .toList();
      if (masters.isEmpty) {
        filtered.addAll(dirEntries);
        continue;
      }

      final masterBaseNames = masters
          .map((m) => path.basenameWithoutExtension(m.filename).toLowerCase())
          .toSet();
      for (final entry in dirEntries) {
        final ext = path.extension(entry.filename).toLowerCase();
        if (!masterExts.contains(ext) && candidateExts.contains(ext)) {
          final baseName = path
              .basenameWithoutExtension(entry.filename)
              .toLowerCase();
          if (masterBaseNames.contains(baseName) ||
              trackRegex.hasMatch(baseName)) {
            continue;
          }
        }
        filtered.add(entry);
      }
    }
    return filtered;
  }

  /// Resolves a folder name into its corresponding system ID.
  static Future<String?> _getSystemIdByFolderName(String folderName) async {
    try {
      final system = await SqliteService.getSystemByFolderName(folderName);
      return system.id;
    } catch (e) {
      _log.e('Error getting system_id for folder $folderName: $e');
      return null;
    }
  }

  /// Removes database records for ROMs that are no longer physically present
  /// on the storage device.
  static Future<int> _cleanupOrphanedRomsOptimized(
    String systemId,
    Set<String> existingRomPaths,
  ) async {
    try {
      final db = await SqliteService.getDatabase();
      final existingRoms = await db.rawQuery(
        'SELECT rom_path FROM user_roms WHERE app_system_id = ?',
        [systemId],
      );
      if (existingRoms.isEmpty) return 0;

      final romsToDelete = existingRoms
          .where(
            (rom) => !existingRomPaths.contains(rom['rom_path'].toString()),
          )
          .toList();
      if (romsToDelete.isEmpty) return 0;

      await db.transaction((txn) async {
        const batchSize = 100;
        for (int i = 0; i < romsToDelete.length; i += batchSize) {
          final batch = romsToDelete.sublist(
            i,
            (i + batchSize < romsToDelete.length)
                ? i + batchSize
                : romsToDelete.length,
          );
          final paths = batch.map((r) => r['rom_path'].toString()).toList();
          final placeholders = List.filled(paths.length, '?').join(',');
          await txn.rawDelete(
            'DELETE FROM user_roms WHERE rom_path IN ($placeholders)',
            paths,
          );
        }
      });
      return romsToDelete.length;
    } catch (e) {
      _log.e('Error cleaning up orphaned ROMs for system $systemId: $e');
      return 0;
    }
  }

  /// Performs a specialized scan of installed Android applications.
  static Future<List<DatabaseGameModel>> _performAndroidSystemScan(
    SystemModel system,
    String folderName,
  ) async {
    try {
      final installedApps = await AndroidService.getInstalledApps(
        includeSystemApps: true,
      );
      final List<DatabaseGameModel> scannedGames = [];

      for (var app in installedApps) {
        final String packageName = app['package'];
        scannedGames.add(
          DatabaseGameModel(
            filename: packageName,
            romPath: packageName,
            realName: app['name'],
            emulatorName: 'Android',
            systemFolderName: folderName,
            descriptions: {'en': 'Android Application'},
          ),
        );
      }

      await _cleanupOrphanedRomsOptimized(
        system.id!,
        scannedGames.map((g) => g.romPath).toSet(),
      );
      await _batchInsertAndroidApps(
        system.folderName,
        scannedGames,
        system.id!,
      );
      return scannedGames;
    } catch (e) {
      _log.e('Error scanning Android apps: $e');
      return [];
    }
  }

  /// High-performance batch operation for registering Android applications
  /// in the ROM database.
  static Future<void> _batchInsertAndroidApps(
    String folderName,
    List<DatabaseGameModel> games,
    String systemId,
  ) async {
    final db = await SqliteService.getDatabase();
    final batch = db.batch();

    for (final game in games) {
      final List<Map<String, dynamic>> existing = await db.query(
        'user_roms',
        columns: ['rom_path'],
        where: 'rom_path = ? AND app_system_id = ?',
        whereArgs: [game.romPath, systemId],
      );
      if (existing.isEmpty) {
        batch.insert('user_roms', {
          'rom_path': game.romPath,
          'filename': game.filename,
          'virtual_folder_name': folderName,
          'app_system_id': systemId,
          'title_name': game.realName,
          'description': game.descriptions?['en'],
          'is_favorite': 0,
          'play_time': 0,
        });
      } else {
        batch.update(
          'user_roms',
          {
            'title_name': game.realName,
            'description': game.descriptions?['en'],
          },
          where: 'rom_path = ? AND app_system_id = ?',
          whereArgs: [game.romPath, systemId],
        );
      }
    }
    await batch.commit(noResult: true);
  }

  /// Quickly identifies existing subdirectories within multiple ROM root folders.
  static Future<Map<String, Map<String, String>>> getExistingSubdirectories(
    List<String> romFolders,
  ) async {
    final Map<String, Map<String, String>> result = {};
    for (final folder in romFolders) {
      final Map<String, String> subdirs = {};
      try {
        if (Platform.isAndroid && folder.startsWith('content://')) {
          final children = await SafDirectoryService.listFiles(folder);
          for (final child in children) {
            if (child['isDirectory'] == true) {
              subdirs[child['name'].toString().toLowerCase()] = child['uri']
                  .toString();
            }
          }
        } else {
          final dir = Directory(folder);
          if (await dir.exists()) {
            final entities = await dir.list().toList();
            for (final entity in entities) {
              if (entity is Directory) {
                subdirs[path.basename(entity.path).toLowerCase()] = entity.path;
              }
            }
          }
        }
      } catch (_) {}
      result[folder] = subdirs;
    }
    return result;
  }

  /// Scans for a system-specific subdirectory within a SAF root URI.
  static Future<List<RomEntry>> _scanSafFolder(
    String romFolderUri,
    String folderName,
    Set<String> validExtensions,
    bool recursive,
  ) async {
    try {
      final children = await SafDirectoryService.listFiles(romFolderUri);
      if (children.isEmpty) return [];
      String? systemTargetUri;
      for (final child in children) {
        if (child['isDirectory'] == true &&
            child['name'].toString().toLowerCase() ==
                folderName.toLowerCase()) {
          systemTargetUri = child['uri'].toString();
          break;
        }
      }
      if (systemTargetUri == null) return [];
      return await _scanSafUri(systemTargetUri, validExtensions, recursive);
    } catch (_) {
      return [];
    }
  }

  /// Recursively lists files within a SAF URI, filtering by extension.
  static Future<List<RomEntry>> _scanSafUri(
    String uri,
    Set<String> validExtensions,
    bool recursive,
  ) async {
    final entries = <RomEntry>[];
    try {
      final content = await SafDirectoryService.listFiles(uri);
      for (final item in content) {
        final name = item['name'].toString();
        final itemUri = item['uri'].toString();
        if (item['isDirectory'] == true) {
          if (recursive) {
            entries.addAll(
              await _scanSafUri(itemUri, validExtensions, recursive),
            );
          }
        } else {
          final ext = path.extension(name).toLowerCase();
          if (validExtensions.contains(ext.replaceAll('.', '')) ||
              validExtensions.isEmpty) {
            entries.add(
              RomEntry(
                path: itemUri,
                filename: name,
                size: (item['size'] as num?)?.toInt() ?? 0,
              ),
            );
          }
        }
      }
    } catch (_) {}
    return entries;
  }

  /// Scans for a system-specific subdirectory within a standard filesystem path.
  static Future<List<RomEntry>> _scanStandardFolder(
    String romFolderPath,
    String folderName,
    Set<String> validExtensions,
    bool recursive,
  ) async {
    try {
      final rootDir = Directory(romFolderPath);
      if (!await rootDir.exists()) return [];
      String? systemPath;
      try {
        final List<FileSystemEntity> children = await rootDir.list().toList();
        for (final child in children) {
          if (child is Directory &&
              path.basename(child.path).toLowerCase() ==
                  folderName.toLowerCase()) {
            systemPath = child.path;
            break;
          }
        }
      } catch (_) {
        final directPath = path.join(romFolderPath, folderName);
        if (await Directory(directPath).exists()) systemPath = directPath;
      }
      if (systemPath == null) return [];
      return await _scanStandardPath(systemPath, validExtensions, recursive);
    } catch (_) {
      return [];
    }
  }

  /// Recursively lists files within a standard filesystem path, filtering by extension.
  static Future<List<RomEntry>> _scanStandardPath(
    String pathStr,
    Set<String> validExtensions,
    bool recursive,
  ) async {
    final entries = <RomEntry>[];
    try {
      final entities = await Directory(
        pathStr,
      ).list(recursive: recursive, followLinks: false).toList();
      for (final entity in entities) {
        if (entity is File) {
          final filename = path.basename(entity.path);
          final ext = path.extension(filename).toLowerCase();
          if (validExtensions.contains(ext.replaceAll('.', '')) ||
              validExtensions.isEmpty) {
            entries.add(
              RomEntry(
                path: entity.path,
                filename: filename,
                size: await entity.length(),
              ),
            );
          }
        }
      }
    } catch (_) {}
    return entries;
  }
}
