import 'dart:async';
import 'dart:collection';

import '../models/game_model.dart';
import '../providers/file_provider.dart';
import 'media_isolate_service.dart';

/// Represents a cached entry containing file presence and metadata for a media asset.
class MediaCacheEntry {
  /// Whether the media file exists on disk.
  final bool exists;

  /// The size of the file in bytes, if it exists.
  final int? fileSize;

  /// Timestamp when this entry was created or last refreshed.
  final DateTime timestamp;

  /// Error message if the file check failed.
  final String? error;

  MediaCacheEntry({
    required this.exists,
    this.fileSize,
    required this.timestamp,
    this.error,
  });

  /// Checks if the entry has exceeded its validity period (30 seconds).
  bool get isExpired {
    return DateTime.now().difference(timestamp) > const Duration(seconds: 30);
  }
}

/// Aggregated media availability information for a specific game.
class GameMediaInfo {
  final bool hasVideo;
  final bool hasScreenshot;
  final String? videoPath;
  final String? screenshotPath;
  final Map<String, String> errors;

  GameMediaInfo({
    required this.hasVideo,
    required this.hasScreenshot,
    this.videoPath,
    this.screenshotPath,
    this.errors = const {},
  });

  /// Whether the game has any associated media assets.
  bool get hasAnyMedia => hasVideo || hasScreenshot;

  /// Returns the path of the highest quality media available (Video > Screenshot).
  String? get bestMediaPath {
    if (hasVideo && videoPath != null) return videoPath;
    if (hasScreenshot && screenshotPath != null) return screenshotPath;
    return null;
  }
}

/// Service that manages an LRU cache for game media assets, utilizing isolates
/// for non-blocking file system checks.
///
/// Prevents main-thread stuttering by offloading expensive I/O operations to
/// background workers while maintaining a performant lookup cache.
class MediaCacheService {
  static MediaCacheService? _instance;
  static MediaCacheService get instance => _instance ??= MediaCacheService._();

  MediaCacheService._();

  final Map<String, MediaCacheEntry> _cache = {};
  final Map<String, Completer<GameMediaInfo>> _loadingGames = {};

  final LinkedHashMap<String, DateTime> _accessOrder = LinkedHashMap();
  static const int _maxCacheSize = 1000;
  static const Duration _cacheExpiration = Duration(minutes: 5);

  /// Initializes the service and its underlying isolate worker.
  Future<void> initialize() async {
    await MediaIsolateService.instance.initialize();
  }

  /// Retrieves media availability for a game, utilizing the cache or querying the file system.
  ///
  /// Automatically de-duplicates concurrent requests for the same game to avoid
  /// redundant I/O operations.
  Future<GameMediaInfo> getGameMediaInfo(
    GameModel game,
    String systemFolderName,
    FileProvider fileProvider,
  ) async {
    final cacheKey = '${systemFolderName}_${game.romname}';

    if (_loadingGames.containsKey(cacheKey)) {
      return await _loadingGames[cacheKey]!.future;
    }

    final completer = Completer<GameMediaInfo>();
    _loadingGames[cacheKey] = completer;

    try {
      final result = await _loadGameMediaInternal(
        game,
        systemFolderName,
        fileProvider,
      );
      completer.complete(result);
      return result;
    } catch (e) {
      final errorResult = GameMediaInfo(
        hasVideo: false,
        hasScreenshot: false,
        errors: {'general': e.toString()},
      );
      completer.complete(errorResult);
      return errorResult;
    } finally {
      _loadingGames.remove(cacheKey);
    }
  }

  /// Internal logic for resolving media paths and performing non-cached checks via isolates.
  Future<GameMediaInfo> _loadGameMediaInternal(
    GameModel game,
    String systemFolderName,
    FileProvider fileProvider,
  ) async {
    final videoPath = game.getVideoPath(systemFolderName, fileProvider);
    final screenshotPath = game.getScreenshotPath(
      systemFolderName,
      fileProvider,
    );

    final files = <String, MediaType>{};

    if (videoPath.isNotEmpty) {
      files[videoPath] = MediaType.video;
    }
    if (screenshotPath.isNotEmpty) {
      files[screenshotPath] = MediaType.screenshot;
    }

    final cachedResults = <String, MediaCacheEntry>{};
    final filesToCheck = <String, MediaType>{};

    for (final entry in files.entries) {
      final cached = _getCachedResult(entry.key);
      if (cached != null && !cached.isExpired) {
        cachedResults[entry.key] = cached;
        _updateAccessOrder(entry.key);
      } else {
        filesToCheck[entry.key] = entry.value;
      }
    }

    Map<String, MediaResponse> isolateResults = {};
    if (filesToCheck.isNotEmpty) {
      isolateResults = await MediaIsolateService.instance.checkMultipleFiles(
        filesToCheck,
      );

      for (final entry in isolateResults.entries) {
        final cacheEntry = MediaCacheEntry(
          exists: entry.value.exists,
          fileSize: entry.value.fileSize,
          timestamp: DateTime.now(),
          error: entry.value.error,
        );
        _updateCache(entry.key, cacheEntry);
      }
    }

    final errors = <String, String>{};

    bool hasVideo = false;
    bool hasScreenshot = false;

    if (videoPath.isNotEmpty) {
      final cached = cachedResults[videoPath];
      final isolateResult = isolateResults[videoPath];

      if (cached != null) {
        hasVideo = cached.exists;
        if (cached.error != null) {
          errors['video'] = cached.error!;
        }
      } else if (isolateResult != null) {
        hasVideo = isolateResult.exists;
        if (isolateResult.error != null) {
          errors['video'] = isolateResult.error!;
        }
      }
    }

    if (screenshotPath.isNotEmpty) {
      final cached = cachedResults[screenshotPath];
      final isolateResult = isolateResults[screenshotPath];

      if (cached != null) {
        hasScreenshot = cached.exists;
        if (cached.error != null) {
          errors['screenshot'] = cached.error!;
        }
      } else if (isolateResult != null) {
        hasScreenshot = isolateResult.exists;
        if (isolateResult.error != null) {
          errors['screenshot'] = isolateResult.error!;
        }
      }
    }

    return GameMediaInfo(
      hasVideo: hasVideo,
      hasScreenshot: hasScreenshot,
      videoPath: hasVideo ? videoPath : null,
      screenshotPath: hasScreenshot ? screenshotPath : null,
      errors: errors,
    );
  }

  /// Pre-fetches media information for a list of games in batches.
  Future<Map<String, GameMediaInfo>> preloadGamesMedia(
    List<GameModel> games,
    String systemFolderName,
    FileProvider fileProvider, {
    int batchSize = 5,
  }) async {
    final results = <String, GameMediaInfo>{};

    for (int i = 0; i < games.length; i += batchSize) {
      final batch = games.skip(i).take(batchSize).toList();
      final futures = batch.map(
        (game) => getGameMediaInfo(
          game,
          systemFolderName,
          fileProvider,
        ).then((info) => MapEntry('${systemFolderName}_${game.romname}', info)),
      );

      final batchResults = await Future.wait(futures);
      for (final entry in batchResults) {
        results[entry.key] = entry.value;
      }

      if (i + batchSize < games.length) {
        await Future.delayed(const Duration(milliseconds: 10));
      }
    }

    return results;
  }

  MediaCacheEntry? _getCachedResult(String filePath) {
    return _cache[filePath];
  }

  void _updateCache(String filePath, MediaCacheEntry entry) {
    _cache[filePath] = entry;
    _updateAccessOrder(filePath);
    _cleanupCache();
  }

  void _updateAccessOrder(String filePath) {
    _accessOrder.remove(filePath);
    _accessOrder[filePath] = DateTime.now();
  }

  /// Removes expired entries and enforces the maximum cache size using an LRU strategy.
  void _cleanupCache() {
    final now = DateTime.now();
    final expiredKeys = <String>[];

    for (final entry in _cache.entries) {
      if (now.difference(entry.value.timestamp) > _cacheExpiration) {
        expiredKeys.add(entry.key);
      }
    }

    for (final key in expiredKeys) {
      _cache.remove(key);
      _accessOrder.remove(key);
    }

    while (_cache.length > _maxCacheSize) {
      final oldestKey = _accessOrder.keys.first;
      _cache.remove(oldestKey);
      _accessOrder.remove(oldestKey);
    }
  }

  /// Clears all cached media information.
  void clearCache() {
    _cache.clear();
    _accessOrder.clear();
  }

  /// Returns diagnostic statistics about the current cache state.
  Map<String, dynamic> getCacheStats() {
    return {
      'cacheSize': _cache.length,
      'maxCacheSize': _maxCacheSize,
      'loadingGames': _loadingGames.length,
      'cacheHitRatio': _calculateCacheHitRatio(),
    };
  }

  double _calculateCacheHitRatio() {
    return _cache.length / _maxCacheSize.toDouble();
  }

  /// Disposes of the service, clearing the cache and shutting down the isolate worker.
  Future<void> dispose() async {
    _cache.clear();
    _accessOrder.clear();
    _loadingGames.clear();
    await MediaIsolateService.instance.dispose();
  }
}
