import 'package:neostation/data/datasources/sqlite_service.dart';
import 'package:neostation/providers/file_provider.dart';
import 'package:neostation/repositories/game_repository.dart';
import 'package:neostation/services/logger_service.dart';

/// Represents a single orphaned metadata row found in the database.
class OrphanedMetadataItem {
  final String appSystemId;
  final String filename;
  final String systemFolderName;
  final bool isFullyScraped;
  final bool esdeImported;

  const OrphanedMetadataItem({
    required this.appSystemId,
    required this.filename,
    required this.systemFolderName,
    required this.isFullyScraped,
    required this.esdeImported,
  });

  bool get isNeoStation => !esdeImported;
}

/// Result of analyzing or cleaning orphaned game metadata.
class MetadataCleanupResult {
  /// All orphaned metadata rows found during analysis.
  final List<OrphanedMetadataItem> orphanedItems;

  /// Items that were actually deleted (NeoStation-owned rows only).
  final List<OrphanedMetadataItem> deletedItems;

  /// ES-DE imported rows that were left untouched.
  final List<OrphanedMetadataItem> skippedEsdeItems;

  /// Number of media files removed from NeoStation's `media/` directory.
  final int deletedMediaFiles;

  /// Human-readable errors encountered while deleting files: one per row that
  /// couldn't be deleted (media failures are logged, not counted), so the
  /// screen reports `errors.length` as the rows left behind.
  final List<String> errors;

  const MetadataCleanupResult({
    this.orphanedItems = const [],
    this.deletedItems = const [],
    this.skippedEsdeItems = const [],
    this.deletedMediaFiles = 0,
    this.errors = const [],
  });

  bool get hasOrphans => orphanedItems.isNotEmpty;
  bool get hasDeletions => deletedItems.isNotEmpty || deletedMediaFiles > 0;
}

/// Service that detects and removes game metadata that no longer has an
/// associated ROM entry.
///
/// Only NeoStation-generated metadata is physically cleaned: its database row
/// and any files living inside NeoStation's own `media/` folder are removed.
/// Metadata imported from ES-DE is intentionally left untouched, because the
/// underlying images and videos live in ES-DE's `downloaded_media/` directory
/// and may still be referenced by ES-DE itself.
class MetadataCleanupService {
  static final _log = LoggerService.instance;

  /// Finds every row in `user_screenscraper_metadata` whose
  /// `(app_system_id, filename)` pair no longer exists in `user_roms`.
  static Future<MetadataCleanupResult> analyze() async {
    final db = await SqliteService.getDatabase();
    final rows = await db.rawQuery('''
      SELECT
        usm.app_system_id AS app_system_id,
        usm.filename AS filename,
        s.folder_name AS system_folder_name,
        COALESCE(usm.is_fully_scraped, 0) AS is_fully_scraped,
        COALESCE(usm.esde_imported, 0) AS esde_imported
      FROM user_screenscraper_metadata usm
      JOIN app_systems s ON usm.app_system_id = s.id
      LEFT JOIN user_roms ur
        ON ur.app_system_id = usm.app_system_id
        AND ur.filename = usm.filename
      WHERE ur.filename IS NULL
      ORDER BY usm.app_system_id, usm.filename
    ''');

    final items = rows.map(_rowToItem).toList();
    return MetadataCleanupResult(orphanedItems: items);
  }

  /// Removes NeoStation-owned orphaned metadata and its physical media files.
  /// ES-DE imported rows are reported in [skippedEsdeItems] but never deleted.
  static Future<MetadataCleanupResult> clean({
    FileProvider? fileProvider,
    String? mediaDirectoryPath,
    void Function(double progress, OrphanedMetadataItem currentItem)?
    onProgress,
  }) async {
    try {
      final analysis = await analyze();
      final orphanedItems = analysis.orphanedItems;

      if (orphanedItems.isEmpty) {
        return analysis;
      }

      final db = await SqliteService.getDatabase();
      final deletedItems = <OrphanedMetadataItem>[];
      final skippedEsdeItems = <OrphanedMetadataItem>[];
      final errors = <String>[];
      int deletedMediaFiles = 0;

      final resolvedMediaDir =
          mediaDirectoryPath ?? fileProvider?.getMediaDirectoryPath();

      for (var index = 0; index < orphanedItems.length; index++) {
        final item = orphanedItems[index];

        try {
          if (item.esdeImported) {
            skippedEsdeItems.add(item);
            _log.i(
              'Metadata cleanup: skipping ES-DE imported row '
              '${item.systemFolderName}/${item.filename}',
            );
            continue;
          }

          // Delete the orphaned database row first so the DB stays consistent
          // even if file deletion fails.
          await db.delete(
            'user_screenscraper_metadata',
            where: 'app_system_id = ? AND filename = ?',
            whereArgs: [item.appSystemId, item.filename],
          );

          deletedItems.add(item);

          if (resolvedMediaDir != null) {
            final romBaseName = FileProvider.stripRomExtension(item.filename);
            final mediaDeleted =
                await GameRepository.deleteNeoStationScrapedMedia(
                  systemFolderName: item.systemFolderName,
                  filename: item.filename,
                  romBaseName: romBaseName,
                  mediaDirectoryPath: resolvedMediaDir,
                );
            deletedMediaFiles += mediaDeleted;
          }
        } catch (e, stackTrace) {
          final message =
              'Failed to clean metadata for ${item.systemFolderName}/${item.filename}: $e';
          _log.e(message, stackTrace: stackTrace);
          errors.add(message);
        } finally {
          if (onProgress != null && orphanedItems.isNotEmpty) {
            try {
              onProgress((index + 1) / orphanedItems.length, item);
            } catch (e, stackTrace) {
              _log.e(
                'Metadata cleanup onProgress callback failed: $e',
                stackTrace: stackTrace,
              );
            }
          }
        }
      }

      return MetadataCleanupResult(
        orphanedItems: orphanedItems,
        deletedItems: deletedItems,
        skippedEsdeItems: skippedEsdeItems,
        deletedMediaFiles: deletedMediaFiles,
        errors: errors,
      );
    } catch (e, stackTrace) {
      _log.e('Metadata cleanup failed: $e', stackTrace: stackTrace);
      rethrow;
    }
  }

  static OrphanedMetadataItem _rowToItem(Map<String, Object?> row) {
    return OrphanedMetadataItem(
      appSystemId: row['app_system_id']?.toString() ?? '',
      filename: row['filename']?.toString() ?? '',
      systemFolderName: row['system_folder_name']?.toString() ?? '',
      isFullyScraped:
          (int.tryParse(row['is_fully_scraped']?.toString() ?? '0') ?? 0) == 1,
      esdeImported:
          (int.tryParse(row['esde_imported']?.toString() ?? '0') ?? 0) == 1,
    );
  }
}
