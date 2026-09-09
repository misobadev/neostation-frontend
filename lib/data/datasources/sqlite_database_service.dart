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
import 'dart:isolate';
import 'dart:convert';
import 'package:path/path.dart' as path;
import 'package:flutter/foundation.dart';

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
    bool ignoreHiddenFiles = true,
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
        ignoreHiddenFiles: ignoreHiddenFiles,
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
    bool ignoreHiddenFiles = true,
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

    // Resolve every alias folder to a concrete directory before walking any of
    // them. A system's aliases can name the same physical directory: EmuDeck
    // ships roms/gamecube as a symlink to roms/gc, and both are aliases of the
    // GameCube system, so walking each alias in turn finds every file twice and
    // stores it under two different rom_path spellings.
    final scanTargets =
        <({String dirPath, String canonicalPath, bool useSaf})>[];

    for (final romFolder in romFolders) {
      final bool useSaf =
          Platform.isAndroid && romFolder.startsWith('content://');
      final Map<String, String>? subdirsForRoot = rootFoldersMap?[romFolder];

      for (final folderToScan in allPossibleFolderNames) {
        try {
          final String? dirPath;

          if (subdirsForRoot != null) {
            dirPath = subdirsForRoot[folderToScan.toLowerCase()];
          } else if (useSaf) {
            dirPath = await _resolveSafSubfolderUri(
              romFolder,
              folderToScan,
              ignoreHiddenFiles: ignoreHiddenFiles,
            );
          } else {
            dirPath = await _resolveStandardSubfolderPath(
              romFolder,
              folderToScan,
              ignoreHiddenFiles: ignoreHiddenFiles,
            );
          }

          if (dirPath == null) continue;

          scanTargets.add((
            dirPath: dirPath,
            canonicalPath: await _canonicalScanPath(dirPath, useSaf: useSaf),
            useSaf: useSaf,
          ));
        } catch (e) {
          _log.e('Error resolving folder $folderToScan in $romFolder: $e');
        }
      }
    }

    // Walk real directories before symlinked aliases so the stored rom_path
    // names the physical location: if the user later drops the alias link, the
    // rows that survived still resolve.
    final orderedTargets = [
      ...scanTargets.where((t) => t.dirPath == t.canonicalPath),
      ...scanTargets.where((t) => t.dirPath != t.canonicalPath),
    ];

    final walkedDirs = <String>{};
    _log.i(
      'Scan[${system.realName}]: ${scanTargets.length} target(s) resolved '
      '(folders=${allPossibleFolderNames.join(', ')}, romFolders=${romFolders.length})',
    );
    for (final target in orderedTargets) {
      // An alias pointing at a directory already walked for this system.
      if (!walkedDirs.add(target.canonicalPath)) continue;

      try {
        final entries = target.useSaf
            ? await _scanSafUri(
                target.dirPath,
                validExtensionsSet,
                system.recursiveScan,
                ignoreHiddenFiles: ignoreHiddenFiles,
              )
            : await scanStandardPath(
                target.dirPath,
                validExtensionsSet,
                system.recursiveScan,
                ignoreHiddenFiles: ignoreHiddenFiles,
              );

        _log.i(
          'Scan[${system.realName}]: walked ${target.dirPath} -> '
          '${entries.length} entries',
        );
        if (entries.isNotEmpty) {
          romEntries.addAll(entries);
        }
      } catch (e) {
        _log.e('Error scanning folder ${target.dirPath}: $e');
      }
    }

    _log.i(
      'Scan[${system.realName}]: ${romEntries.length} raw entries before '
      'dedup/filter',
    );

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
    final cleanup = await _cleanupOrphanedRomsOptimized(
      system.id!,
      romEntries.map((e) => e.path).toSet(),
    );
    final removedCount = cleanup.removed;

    if (romEntries.isEmpty) {
      final finalCount = await SqliteService.getRomCountForSystem(system.id!);
      return ScanSummary(
        added: 0,
        removed: removedCount,
        total: finalCount,
        systemName: system.realName,
      );
    }

    // Only rows the database does not already carry need writing. A warm
    // rescan finds nothing new, so this turns ~9k pointless upserts (and the
    // 399 transactions around them) into zero work. Entries whose row is
    // populated from the file itself are always re-upserted so a previously
    // failed extraction still gets another chance.
    final entriesToWrite = romEntries
        .where(
          (e) =>
              !cleanup.knownPaths.contains(e.path) ||
              _needsMetadataExtraction(system.id!, e),
        )
        .toList();

    if (entriesToWrite.isEmpty) {
      return ScanSummary(
        added: 0,
        removed: removedCount,
        total: (initialCount - removedCount).clamp(0, 999999),
        systemName: system.realName,
      );
    }

    // Batch insertion with dynamic batch size tuning
    final batchSize = _calculateOptimalBatchSize(entriesToWrite.length);
    final batches = <List<RomEntry>>[];
    for (int i = 0; i < entriesToWrite.length; i += batchSize) {
      batches.add(
        entriesToWrite.sublist(
          i,
          (i + batchSize < entriesToWrite.length)
              ? i + batchSize
              : entriesToWrite.length,
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
  /// Each PRAGMA is wrapped individually so a filesystem error on one doesn't
  /// block subsequent operations.
  static Future<void> initialize() async {
    final db = await SqliteService.getDatabase();
    try {
      await db.execute('PRAGMA synchronous = NORMAL');
    } catch (e) {
      _log.w('Could not set PRAGMA synchronous = NORMAL: $e');
    }
    try {
      await db.execute('PRAGMA cache_size = 10000');
    } catch (e) {
      _log.w('Could not set PRAGMA cache_size = 10000: $e');
    }
    try {
      await db.execute('PRAGMA temp_store = MEMORY');
    } catch (e) {
      _log.w('Could not set PRAGMA temp_store = MEMORY: $e');
    }
    try {
      await db.execute('PRAGMA mmap_size = 268435456');
    } catch (e) {
      _log.w('Could not set PRAGMA mmap_size = 268435456: $e');
    }
  }

  /// Whether [entry] carries metadata that [_batchInsertRoms] derives by reading
  /// the file itself (Switch title info, Vita Title ID, Steam App ID).
  ///
  /// Rows like these are re-upserted on every scan even when the path is already
  /// known, so an extraction that failed once — unreadable file, missing Switch
  /// keys — is retried later instead of being frozen out by the path diff.
  static bool _needsMetadataExtraction(String systemId, RomEntry entry) {
    if (systemId == 'switch' || systemId == 'nintendo-switch') return true;
    final lower = entry.filename.toLowerCase();
    return lower.endsWith('.psvita') || lower.endsWith('.steam');
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
      // app_emulator_unique_id/os_id are left NULL = "inherit the system
      // default", resolved live at launch. Do NOT freeze the default here:
      // stamping it made per-game settings stale/"whack-a-mole" and bypassed
      // the installed-aware default resolution at launch.
      const sql = '''
        INSERT INTO user_roms
        (app_system_id, app_emulator_unique_id, app_emulator_os_id, filename, rom_path, title_id, title_name, created_at)
        VALUES (
          ?,
          NULL,
          NULL,
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
          } catch (e) {
            _log.e('Error extracting Switch game info for ${entry.path}: $e');
          }
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
          } catch (e) {
            _log.e('Error reading Steam ID file ${entry.path}: $e');
          }
        }

        const windowsIdExts = {
          '.localgameid',
          '.steam',
          '.epic',
          '.gog',
          '.amazon',
          '.pcgame',
          '.customgame',
          '.xcloud',
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
          } catch (e) {
            _log.e('Error reading Windows ID file ${entry.path}: $e');
          }
        }

        batch.rawInsert(sql, [
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
      } catch (e) {
        _log.e('Error reading M3U file ${m3u.path}: $e');
      }
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
  ///
  /// Returns the number of rows deleted along with the set of `rom_path` values
  /// that remain in the database for [systemId]. The caller uses that set to
  /// skip re-upserting rows it already has: the query it comes from has to run
  /// anyway, so the diff is free. On error the known-path set comes back empty,
  /// which degrades to the old behaviour (upsert everything) rather than
  /// silently skipping inserts.
  static Future<({int removed, Set<String> knownPaths})>
  _cleanupOrphanedRomsOptimized(
    String systemId,
    Set<String> existingRomPaths,
  ) async {
    try {
      final db = await SqliteService.getDatabase();
      final existingRoms = await db.rawQuery(
        'SELECT rom_path FROM user_roms WHERE app_system_id = ?',
        [systemId],
      );
      if (existingRoms.isEmpty) {
        return (removed: 0, knownPaths: <String>{});
      }

      final knownPaths = <String>{};
      final romsToDelete = <String>[];
      for (final rom in existingRoms) {
        final path = rom['rom_path'].toString();
        if (existingRomPaths.contains(path)) {
          knownPaths.add(path);
        } else {
          romsToDelete.add(path);
        }
      }
      if (romsToDelete.isEmpty) {
        return (removed: 0, knownPaths: knownPaths);
      }

      // Rows stored before the scan learned to skip symlinked alias folders
      // still spell the path through the alias (…/roms/gamecube/x.rvz for a
      // file the scan now keeps as …/roms/gc/x.rvz). Those files are not
      // missing, so their play time, favourite flag and scraped ids have to be
      // folded into the surviving row before the delete below discards them.
      final renamed = await _mergeAliasDuplicateRoms(
        romsToDelete,
        existingRomPaths,
        knownPaths,
      );
      if (renamed.isNotEmpty) {
        romsToDelete.removeWhere(renamed.containsKey);
        knownPaths.addAll(renamed.values);
        if (romsToDelete.isEmpty) {
          return (removed: 0, knownPaths: knownPaths);
        }
      }

      await db.transaction((txn) async {
        const batchSize = 100;
        for (int i = 0; i < romsToDelete.length; i += batchSize) {
          final paths = romsToDelete.sublist(
            i,
            (i + batchSize < romsToDelete.length)
                ? i + batchSize
                : romsToDelete.length,
          );
          final placeholders = List.filled(paths.length, '?').join(',');
          await txn.rawDelete(
            'DELETE FROM user_roms WHERE rom_path IN ($placeholders)',
            paths,
          );
        }
      });
      return (removed: romsToDelete.length, knownPaths: knownPaths);
    } catch (e) {
      _log.e('Error cleaning up orphaned ROMs for system $systemId: $e');
      return (removed: 0, knownPaths: <String>{});
    }
  }

  /// Folds rows that reach an already-scanned file through a symlinked alias
  /// folder into the row the scan keeps, and returns the ones that were instead
  /// renamed in place (orphan path -> surviving path).
  ///
  /// Only runs when a scan found orphans at all, so a warm rescan never pays
  /// for it, and it resolves one directory at a time rather than one file at a
  /// time. `content://` paths are skipped outright: a SAF URI is an opaque
  /// DocumentsProvider identifier with no symbolic link to resolve.
  static Future<Map<String, String>> _mergeAliasDuplicateRoms(
    List<String> orphanPaths,
    Set<String> scannedPaths,
    Set<String> knownPaths,
  ) async {
    final dirCache = <String, String?>{};

    Future<String?> canonicalDirOf(String dirPath) async {
      if (dirCache.containsKey(dirPath)) return dirCache[dirPath];
      String? resolved;
      try {
        resolved = await Directory(dirPath).resolveSymbolicLinks();
      } catch (e) {
        resolved = null;
      }
      dirCache[dirPath] = resolved;
      return resolved;
    }

    // Index the scanned files by canonical path, so a row spelled through an
    // alias can find the row the scan kept whatever the two spellings are.
    final canonicalToScanned = <String, String>{};
    for (final scanned in scannedPaths) {
      if (scanned.startsWith('content://')) continue;
      final dir = await canonicalDirOf(path.dirname(scanned));
      if (dir == null) continue;
      canonicalToScanned[path.join(dir, path.basename(scanned))] = scanned;
    }
    if (canonicalToScanned.isEmpty) return const {};

    final renames = <String, String>{};
    final merges = <String, String>{};
    final claimed = <String>{};

    for (final orphanPath in orphanPaths) {
      if (orphanPath.startsWith('content://')) continue;
      final dir = await canonicalDirOf(path.dirname(orphanPath));
      if (dir == null) continue; // The directory is gone: a genuine orphan.

      final survivor =
          canonicalToScanned[path.join(dir, path.basename(orphanPath))];
      if (survivor == null || survivor == orphanPath) continue;

      if (knownPaths.contains(survivor) || claimed.contains(survivor)) {
        merges[orphanPath] = survivor;
      } else {
        // Only the alias spelling was ever stored, so the row can simply move
        // to the surviving path and keep everything it carries.
        renames[orphanPath] = survivor;
        claimed.add(survivor);
      }
    }

    if (renames.isEmpty && merges.isEmpty) return const {};

    int asInt(Object? value) =>
        value is int ? value : int.tryParse('${value ?? ''}') ?? 0;

    String? latest(Object? a, Object? b) {
      final x = (a == null || a.toString().isEmpty) ? null : a.toString();
      final y = (b == null || b.toString().isEmpty) ? null : b.toString();
      if (x == null) return y;
      if (y == null) return x;
      return x.compareTo(y) >= 0 ? x : y;
    }

    const columns =
        'is_favorite, play_time, last_played, id_ra, ra_hash, ss_hash, '
        'rom_crc32, rom_size, rom_fingerprint_skipped, '
        'app_emulator_unique_id, app_emulator_os_id, '
        'app_alternative_emulators_id';

    final db = await SqliteService.getDatabase();
    await db.transaction((txn) async {
      for (final entry in renames.entries) {
        await txn.rawUpdate(
          "UPDATE user_roms SET rom_path = ?, updated_at = datetime('now') "
          'WHERE rom_path = ?',
          [entry.value, entry.key],
        );
      }

      for (final entry in merges.entries) {
        final duplicateRows = await txn.rawQuery(
          'SELECT $columns FROM user_roms WHERE rom_path = ?',
          [entry.key],
        );
        final survivorRows = await txn.rawQuery(
          'SELECT $columns FROM user_roms WHERE rom_path = ?',
          [entry.value],
        );
        if (duplicateRows.isEmpty || survivorRows.isEmpty) continue;

        final d = duplicateRows.first;
        final s = survivorRows.first;

        // The surviving row wins every scalar it already carries; the duplicate
        // only fills gaps. Play time is summed because each launch was recorded
        // against exactly one of the two rows.
        await txn.rawUpdate(
          '''
          UPDATE user_roms SET
            is_favorite = ?,
            play_time = ?,
            last_played = ?,
            id_ra = ?,
            ra_hash = ?,
            ss_hash = ?,
            rom_crc32 = ?,
            rom_size = ?,
            rom_fingerprint_skipped = ?,
            app_emulator_unique_id = ?,
            app_emulator_os_id = ?,
            app_alternative_emulators_id = ?,
            updated_at = datetime('now')
          WHERE rom_path = ?
          ''',
          [
            (asInt(s['is_favorite']) == 1 || asInt(d['is_favorite']) == 1)
                ? 1
                : 0,
            asInt(s['play_time']) + asInt(d['play_time']),
            latest(s['last_played'], d['last_played']),
            s['id_ra'] ?? d['id_ra'],
            s['ra_hash'] ?? d['ra_hash'],
            s['ss_hash'] ?? d['ss_hash'],
            // Both paths are the same file (a symlinked duplicate), so the
            // dump identity transfers verbatim; a computed fingerprint on
            // either row beats losing it and re-reading the ROM.
            s['rom_crc32'] ?? d['rom_crc32'],
            s['rom_size'] ?? d['rom_size'],
            s['rom_fingerprint_skipped'] ?? d['rom_fingerprint_skipped'],
            s['app_emulator_unique_id'] ?? d['app_emulator_unique_id'],
            s['app_emulator_os_id'] ?? d['app_emulator_os_id'],
            s['app_alternative_emulators_id'] ??
                d['app_alternative_emulators_id'],
            entry.value,
          ],
        );
      }
    });

    return renames;
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
      } catch (e) {
        _log.e('Error listing subdirectories for $folder: $e');
      }
      result[folder] = subdirs;
    }
    return result;
  }

  /// Locates a system-specific subdirectory within a SAF root URI.
  static Future<String?> _resolveSafSubfolderUri(
    String romFolderUri,
    String folderName, {
    bool ignoreHiddenFiles = true,
  }) async {
    try {
      final children = await SafDirectoryService.listFiles(romFolderUri);
      if (children.isEmpty) return null;
      for (final child in children) {
        if (_shouldSkipSafEntry(child, ignoreHiddenFiles: ignoreHiddenFiles)) {
          continue;
        }
        if (child['isDirectory'] == true &&
            child['name'].toString().toLowerCase() ==
                folderName.toLowerCase()) {
          return child['uri'].toString();
        }
      }
      return null;
    } catch (e) {
      _log.e('Error resolving SAF folder $romFolderUri for $folderName: $e');
      return null;
    }
  }

  /// Returns the key identifying a scan target's physical directory, so alias
  /// folders resolving to one place are only walked once.
  ///
  /// SAF URIs are opaque DocumentsProvider identifiers rather than filesystem
  /// paths, so they are returned untouched: resolving symbolic links is
  /// meaningless there, and quietly falling back to a real path would break the
  /// `content://` rom_path identity the launcher depends on.
  static Future<String> _canonicalScanPath(
    String dirPath, {
    required bool useSaf,
  }) async {
    if (useSaf) return dirPath;
    try {
      return await Directory(dirPath).resolveSymbolicLinks();
    } catch (e) {
      // Unreadable, or gone between listing and resolving. Fall back to the
      // literal path so the directory is still walked exactly once.
      return dirPath;
    }
  }

  /// Recursively lists files within a SAF URI, filtering by extension.
  static Future<List<RomEntry>> _scanSafUri(
    String uri,
    Set<String> validExtensions,
    bool recursive, {
    bool ignoreHiddenFiles = true,
  }) async {
    final entries = <RomEntry>[];

    // Fast path: walk the tree with direct filesystem I/O in one native call
    // instead of a DocumentsProvider query per directory. Returns null when it
    // cannot prove equivalence (non-primary volume, permission not held), in
    // which case the SAF walk below runs unchanged — as it also does when the
    // fast walk claims a directory is empty and the DocumentsProvider disagrees.
    final fastEntries = await SafDirectoryService.fastWalkTree(
      uri,
      recursive: recursive,
      extensions: validExtensions,
      ignoreHiddenFiles: ignoreHiddenFiles,
    );
    if (fastEntries != null && fastEntries.isNotEmpty) {
      for (final item in fastEntries) {
        entries.add(
          RomEntry(
            path: item['uri'].toString(),
            filename: item['name'].toString(),
            size: (item['size'] as num?)?.toInt() ?? 0,
          ),
        );
      }
      _log.i(
        'SafScan[${path.basename(uri)}]: fast walk found ${entries.length} '
        'entries',
      );
      return entries;
    }

    // An empty result is the one answer the fast walk must not be taken at its
    // word on. `File.listFiles()` returns null on an I/O or permission failure,
    // and a storage mount that has not caught up with MANAGE_EXTERNAL_STORAGE
    // makes that failure indistinguishable from an empty directory: the path
    // still reports as a readable directory, it just lists nothing. The scan
    // then reads "no files" as "every ROM for this system was deleted" and
    // prunes the rows, taking favourites, play time and per-game settings with
    // them. Ask the DocumentsProvider, which reads the tree by a wholly
    // different route, before believing it.
    //
    // The extra query lands only where the fast path saved nothing: a directory
    // that really is empty answers immediately, and one that turns out to hold
    // files needed the query anyway.
    if (fastEntries != null) {
      final visibleChildren = visibleSafChildren(
        await SafDirectoryService.listFiles(uri),
        ignoreHiddenFiles: ignoreHiddenFiles,
      );
      if (visibleChildren.isEmpty) {
        _log.i(
          'SafScan[${path.basename(uri)}]: fast walk found 0 entries '
          '(confirmed empty by the DocumentsProvider)',
        );
        return entries;
      }
      final directoryCount = visibleChildren
          .where((child) => child['isDirectory'] == true)
          .length;
      _log.w(
        'SafScan[${path.basename(uri)}]: fast walk found 0 entries but the '
        'DocumentsProvider lists ${visibleChildren.length} child(ren) '
        '($directoryCount directories) - distrusting the fast walk and '
        're-walking with SAF',
      );
      // Falls through to the SAF walk below.
    }

    try {
      final content = await SafDirectoryService.listFiles(uri);
      // _scanSafUri recurses through subdirectories on this slow path, so this
      // line fires once per directory — keep it at debug level to avoid
      // flooding (and rotating away) the production log.
      _log.d(
        'SafScan[${path.basename(uri)}]: SAF walk returned ${content.length} '
        'items',
      );
      for (final item in content) {
        final name = item['name'].toString();
        final itemUri = item['uri'].toString();
        if (_shouldSkipSafEntry(item, ignoreHiddenFiles: ignoreHiddenFiles)) {
          continue;
        }
        if (item['isDirectory'] == true) {
          if (recursive) {
            entries.addAll(
              await _scanSafUri(
                itemUri,
                validExtensions,
                recursive,
                ignoreHiddenFiles: ignoreHiddenFiles,
              ),
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
    } catch (e) {
      _log.e('Error scanning SAF URI $uri: $e');
    }
    return entries;
  }

  /// Locates a system-specific subdirectory within a standard filesystem path.
  static Future<String?> _resolveStandardSubfolderPath(
    String romFolderPath,
    String folderName, {
    bool ignoreHiddenFiles = true,
  }) async {
    try {
      final rootDir = Directory(romFolderPath);
      if (!await rootDir.exists()) return null;
      try {
        final List<FileSystemEntity> children = await rootDir.list().toList();
        for (final child in children) {
          if (_shouldSkipStandardEntity(
            child,
            ignoreHiddenFiles: ignoreHiddenFiles,
          )) {
            continue;
          }
          if (child is Directory &&
              path.basename(child.path).toLowerCase() ==
                  folderName.toLowerCase()) {
            return child.path;
          }
        }
      } catch (e) {
        _log.e('Error listing standard directory $romFolderPath: $e');
        final directPath = path.join(romFolderPath, folderName);
        if (await Directory(directPath).exists()) return directPath;
      }
      return null;
    } catch (e) {
      _log.e(
        'Error resolving standard folder $romFolderPath for $folderName: $e',
      );
      return null;
    }
  }

  /// Recursively lists files within a standard filesystem path, filtering by
  /// extension.
  ///
  /// The walk itself runs on a background isolate. It is pure filesystem work
  /// — no plugin, no database — but every file costs two `await`s, and on the
  /// root isolate those completions queue behind the frame pipeline: each file
  /// then waits on a slice of a frame rather than on a syscall. Measured on a
  /// 9,140-ROM library over 32 systems, the startup scan took ~17s on the root
  /// isolate against ~0.3s for the identical walk with an idle event loop, and
  /// the startup shimmer stuttered in step with it the whole way — the scan
  /// and the animation were taking turns on one event loop.
  ///
  /// Android's SAF walk stays where it is: it reaches the DocumentsProvider
  /// over a platform channel, which is only bound on the root isolate.
  @visibleForTesting
  static Future<List<RomEntry>> scanStandardPath(
    String pathStr,
    Set<String> validExtensions,
    bool recursive, {
    bool ignoreHiddenFiles = true,
  }) async {
    final result = await Isolate.run(
      () => _walkStandardPath(
        pathStr,
        validExtensions,
        recursive,
        ignoreHiddenFiles: ignoreHiddenFiles,
      ),
    );
    if (result.error != null) {
      _log.e('Error scanning standard path $pathStr: ${result.error}');
    }
    return result.entries;
  }

  /// The body of [scanStandardPath], written to run on a bare isolate: it
  /// touches nothing the root isolate owns, so it must not log or reach a
  /// plugin. A failure comes back as [error] for the caller to log, along with
  /// whatever the walk had already collected — the same partial result the
  /// in-place `try` used to return.
  static Future<({List<RomEntry> entries, String? error})> _walkStandardPath(
    String pathStr,
    Set<String> validExtensions,
    bool recursive, {
    required bool ignoreHiddenFiles,
  }) async {
    final entries = <RomEntry>[];
    try {
      final entities = await Directory(
        pathStr,
      ).list(recursive: recursive, followLinks: false).toList();
      for (final entity in entities) {
        if (_shouldSkipStandardEntity(
          entity,
          ignoreHiddenFiles: ignoreHiddenFiles,
        )) {
          continue;
        }
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
    } catch (e) {
      return (entries: entries, error: '$e');
    }
    return (entries: entries, error: null);
  }

  static bool _isDotEntryName(String name) {
    final trimmed = name.trim();
    return trimmed.isNotEmpty && trimmed.startsWith('.');
  }

  /// The DocumentsProvider's view of a directory the fast walk called empty,
  /// with the entries the scan ignores removed.
  ///
  /// Hidden entries are dropped so a folder holding nothing but a `.nomedia`
  /// still reads as empty: it holds no ROMs either way, and treating it as a
  /// contradiction would send every such folder down the slow walk for nothing.
  /// Anything left is a file or directory the fast walk should have seen and
  /// did not, which makes its answer unusable.
  @visibleForTesting
  static List<Map<String, dynamic>> visibleSafChildren(
    List<Map<String, dynamic>> children, {
    bool ignoreHiddenFiles = true,
  }) {
    return children
        .where(
          (child) =>
              !_shouldSkipSafEntry(child, ignoreHiddenFiles: ignoreHiddenFiles),
        )
        .toList();
  }

  static bool _shouldSkipSafEntry(
    Map<String, dynamic> item, {
    required bool ignoreHiddenFiles,
  }) {
    if (!ignoreHiddenFiles) return false;
    final name = item['name']?.toString() ?? '';
    if (_isDotEntryName(name)) return true;
    if (item['isHidden'] == true) return true;
    return false;
  }

  /// Sync on purpose: this only inspects the name it was handed, and as an
  /// `async` function it cost the walk an extra event-loop turn per entry.
  static bool _shouldSkipStandardEntity(
    FileSystemEntity entity, {
    required bool ignoreHiddenFiles,
  }) {
    if (!ignoreHiddenFiles) return false;

    final name = path.basename(entity.path);
    if (_isDotEntryName(name)) return true;
    return false;
  }
}
