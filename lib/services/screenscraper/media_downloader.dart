import 'dart:io';

import 'package:path/path.dart' as path;
import 'package:neostation/services/logger_service.dart';
import 'package:neostation/utils/atomic_file_writer.dart';
import 'region_config.dart';
import 'rom_hasher.dart';
import 'media_resolver.dart';
import 'screenscraper_client.dart';
import 'screenscraper_exceptions.dart';

/// Media asset downloader for ScreenScraper.
///
/// Downloads a game's media assets (boxart, screenshots, etc.) in bounded
/// concurrent batches, selecting the best regional/language variant, mapping
/// media types to folders, and skipping assets already on disk. Delegates
/// transport to [ScreenscraperClient], resolution to [ScreenscraperMediaResolver]
/// / [ScreenscraperRegionConfig], and ROM naming to [ScreenscraperRomHasher].
/// Extracted from [ScreenScraperService].
/// Stateless — holds only the shared logger.
class ScreenscraperMediaDownloader {
  ScreenscraperMediaDownloader._();

  static final _log = LoggerService.instance;

  static final RegExp _safeExtension = RegExp(r'^[A-Za-z0-9]{1,8}$');

  /// Downloads and caches a media file.
  static Future<bool> _downloadMediaFileSmart(
    String url,
    String relativePath,
    String userDataDir, {
    bool forceOverwrite = false,
    int? maxDailyRequests,
  }) async {
    try {
      final fullPath = path.join(userDataDir, relativePath);
      final file = File(fullPath);
      if (await file.exists() && !forceOverwrite) {
        return true;
      }

      final response = await ScreenscraperClient.httpGetWithRetry(
        Uri.parse(url),
        timeout: const Duration(seconds: 60),
        maxRetries: 2,
        maxDailyRequests: maxDailyRequests,
      );
      if (response.statusCode == 200) {
        // A file left half-written would count as downloaded from then on.
        await writeFileAtomically(file, response.bodyBytes);
        return true;
      } else {
        _log.e('Error downloading media (${response.statusCode}): $url');
        return false;
      }
    } on ScreenscraperQuotaExceededException {
      // Every later request would be refused too; the caller says why.
      rethrow;
    } catch (e) {
      _log.e('Error downloading media: $e');
      return false;
    }
  }

  /// Downloads multiple media assets for a game, managing concurrency.
  ///
  /// Throws [ScreenscraperQuotaExceededException] when ScreenScraper refuses a
  /// download because the day's quota is used up: the batch under way
  /// finishes, and no later batch is requested.
  static Future<Map<String, dynamic>> downloadGameMedia(
    String systemFolder,
    String romName,
    List<dynamic> medias,
    int maxThreads, {
    String? appSystemId,
    String? preferredLanguage,
    bool Function()? shouldCancel,
    Function(double progress)? onProgress,
    List<String>? allowedMediaTypes,
    bool forceOverwrite = false,
    int? maxDailyRequests,
  }) async {
    if (medias.isEmpty) {
      return {'success': true, 'cancelled': false};
    }

    final userDataDir = await ScreenscraperMediaResolver.getMediaDirectory();
    final regionPriority = await ScreenscraperRegionConfig.getRegionPriority();
    final mediaTypes =
        allowedMediaTypes ?? ['fanart', 'ss', 'video', 'wheel', 'box2D'];

    final downloadTasks = <Map<String, dynamic>>[];
    for (final mediaType in mediaTypes) {
      final bestMedia = ScreenscraperMediaResolver.selectBestMedia(
        medias,
        mediaType,
        preferredLanguage: preferredLanguage,
        regionPriority: regionPriority,
      );
      if (bestMedia != null) {
        final folderName = ScreenscraperMediaResolver.mapMediaTypeToFolder(
          mediaType,
        );
        final romBaseName = await ScreenscraperRomHasher.getCleanRomName(
          romName,
          appSystemId,
        );
        // The extension comes from the API response; accept only a plain
        // extension so it can't carry a path out of the media folder.
        final format = bestMedia['format']?.toString() ?? 'png';
        if (!_safeExtension.hasMatch(format)) {
          _log.w('Skipping $mediaType for $romName: unexpected format');
          continue;
        }
        final fileName = '$romBaseName.$format';
        final relativePath = '$systemFolder/$folderName/$fileName';

        downloadTasks.add({
          'url': bestMedia['url'].toString(),
          'relativePath': relativePath,
        });
      }
    }

    if (downloadTasks.isEmpty) {
      return {'success': true, 'cancelled': false};
    }

    final batches = <List<Map<String, dynamic>>>[];
    for (var i = 0; i < downloadTasks.length; i += maxThreads) {
      final end = (i + maxThreads < downloadTasks.length)
          ? i + maxThreads
          : downloadTasks.length;
      batches.add(downloadTasks.sublist(i, end));
    }

    int succeeded = 0;
    bool wasCancelled = false;

    int completedTasks = 0;
    for (final batch in batches) {
      if (shouldCancel != null && shouldCancel()) {
        wasCancelled = true;
        break;
      }

      final results = await Future.wait(
        batch.map(
          (task) => _downloadMediaFileSmart(
            task['url'],
            task['relativePath'],
            userDataDir,
            forceOverwrite: forceOverwrite,
            maxDailyRequests: maxDailyRequests,
          ),
        ),
      );
      succeeded += results.where((ok) => ok).length;

      completedTasks += batch.length;
      if (onProgress != null) onProgress(completedTasks / downloadTasks.length);

      if (batches.length > 1) {
        await Future.delayed(const Duration(milliseconds: 100));
      }
    }

    return {
      'success': succeeded == downloadTasks.length && !wasCancelled,
      'cancelled': wasCancelled,
    };
  }
}
