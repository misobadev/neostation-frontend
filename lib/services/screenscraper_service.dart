import 'dart:convert';
import 'dart:io';
import 'dart:async';
import 'dart:isolate';
import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as path;
import 'package:http/io_client.dart';
import 'package:neostation/services/logger_service.dart';
import '../repositories/scraper_repository.dart';
import '../repositories/system_repository.dart';
import 'config_service.dart';
import 'game_service.dart';
import '../utils/gamepad_nav.dart';
import '../utils/optimized_md5_utils.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import '../providers/scraping_provider.dart';
import '../l10n/app_locale.dart';

/// Simple semaphore to control concurrency for HTTP requests and background tasks.
class _Semaphore {
  final int maxCount;
  int _currentCount = 0;
  final List<Completer<void>> _waitQueue = [];

  _Semaphore(this.maxCount);

  /// Acquires a slot in the semaphore, waiting if the [maxCount] is reached.
  Future<void> acquire() async {
    if (_currentCount < maxCount) {
      _currentCount++;
      return;
    }

    final completer = Completer<void>();
    _waitQueue.add(completer);
    await completer.future;
  }

  /// Releases a slot in the semaphore and notifies the next waiting task.
  void release() {
    if (_waitQueue.isNotEmpty) {
      final completer = _waitQueue.removeAt(0);
      completer.complete();
    } else {
      _currentCount--;
    }
  }
}

/// Service responsible for scraping game metadata and media from the
/// ScreenScraper.fr API.
///
/// Features:
/// - Multi-threaded scraping with configurable concurrency.
/// - Support for MD5-based identification.
/// - Local caching of metadata and media (images, videos, wheels).
/// - Automatic system mapping between NeoStation and ScreenScraper IDs.
/// - Daily request quota management and credentials verification.
class ScreenScraperService {
  static const String _baseUrl = 'https://api.screenscraper.fr/api2';
  static final _log = LoggerService.instance;

  static const Map<String, int> _regionPriority = {
    'wor': 100,
    'us': 80,
    'eu': 60,
    'fr': 40,
    'sp': 40,
    'it': 40,
    'de': 40,
    'jp': 20,
    'kr': 10,
    'cn': 10,
  };

  // Developer credentials — provided at build time via --dart-define.
  static const String _devId = String.fromEnvironment('SCREENSCRAPER_DEV_ID');
  static const String _devPassword = String.fromEnvironment(
    'SCREENSCRAPER_DEV_PASSWORD',
  );

  static String? _appVersion;

  /// Retrieves the application version and platform to identify requests to the API.
  static Future<String> _getSoftname() async {
    if (_appVersion != null) return _appVersion!;

    try {
      final packageInfo = await PackageInfo.fromPlatform();
      final name = packageInfo.appName.isNotEmpty
          ? packageInfo.appName
          : 'neostation';
      final version = packageInfo.version;

      String platform = '';
      if (Platform.isAndroid) {
        platform = 'android';
      } else if (Platform.isIOS) {
        platform = 'ios';
      } else if (Platform.isWindows) {
        platform = 'windows';
      } else if (Platform.isLinux) {
        platform = 'linux';
      } else if (Platform.isMacOS) {
        platform = 'macos';
      }
      _appVersion = '$name-$version-$platform';
      return _appVersion!;
    } catch (e) {
      _appVersion = 'neostation';
      return _appVersion!;
    }
  }

  /// Persistent HTTP client with SSL certificate validation bypass for legacy compatibility.
  static final http.Client _httpClient = () {
    final client = HttpClient()
      ..badCertificateCallback =
          ((X509Certificate cert, String host, int port) => true);
    return IOClient(client);
  }();

  static _Semaphore _requestSemaphore = _Semaphore(5);

  static int _dailyRequestsCount = 0;
  static DateTime? _lastRequestDate;

  static String? _cachedMediaDirectory;
  static Map<String, dynamic>? _cachedCredentials;
  static bool _isMetadataScrapingRunning = false;

  /// Updates the request semaphore concurrency limit.
  static void _updateRequestSemaphore(int maxThreads) {
    if (_requestSemaphore.maxCount != maxThreads) {
      _requestSemaphore = _Semaphore(maxThreads);
    }
  }

  /// Resets or initializes the daily request counter based on the current date.
  static void _initializeDailyCounter(int currentRequests) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);

    if (_lastRequestDate == null ||
        !_lastRequestDate!.isAtSameMomentAs(today)) {
      _dailyRequestsCount = currentRequests;
      _lastRequestDate = today;
    }
  }

  /// Performs an HTTP GET request with exponential backoff and timeout management.
  static Future<http.Response> _httpGetWithRetry(
    Uri url, {
    Map<String, String>? headers,
    int maxRetries = 2,
    Duration timeout = const Duration(seconds: 40),
    int? maxDailyRequests,
  }) async {
    if (maxDailyRequests != null && maxDailyRequests > 0) {
      if (!await _canMakeRequest(_dailyRequestsCount, maxDailyRequests)) {
        throw Exception(
          'Daily request limit reached: $_dailyRequestsCount/$maxDailyRequests',
        );
      }
    }

    int attempt = 0;
    while (attempt < maxRetries) {
      try {
        await _requestSemaphore.acquire();

        final response = await _httpClient
            .get(url, headers: headers)
            .timeout(timeout);

        _requestSemaphore.release();

        if (response.statusCode == 200 || response.statusCode == 403) {
          _dailyRequestsCount++;
          return response;
        } else if (response.statusCode >= 500) {
          if (attempt < maxRetries - 1) {
            final delay = Duration(milliseconds: 500 * (attempt + 1));
            _log.w(
              'Server error ${response.statusCode}, retrying in ${delay.inMilliseconds}ms...',
            );
            await Future.delayed(delay);
            attempt++;
            continue;
          }
        }

        return response;
      } on TimeoutException {
        _requestSemaphore.release();
        if (attempt < maxRetries - 1) {
          final delay = Duration(milliseconds: 500 * (attempt + 1));
          await Future.delayed(delay);
          attempt++;
          continue;
        }
        rethrow;
      } catch (e) {
        _requestSemaphore.release();
        if (attempt < maxRetries - 1) {
          final delay = Duration(milliseconds: 500 * (attempt + 1));
          _log.e(
            'Request failed, retrying in ${delay.inMilliseconds}ms... (${e.toString()})',
          );
          await Future.delayed(delay);
          attempt++;
          continue;
        }
        rethrow;
      }
    }

    throw Exception('HTTP request failed after $maxRetries attempts');
  }

  /// Computes the file MD5 hash in a background isolate to keep the UI responsive.
  static Future<String> _calculateMd5InIsolate(String filePath) async {
    return await Isolate.run(() async {
      return await OptimizedMd5Utils.calculateFileMd5(filePath);
    });
  }

  /// Validates if a new request can be made based on user's daily quota limits.
  static Future<bool> _canMakeRequest(
    int currentRequests,
    int maxDailyRequests,
  ) async {
    if (maxDailyRequests <= 0) return true;

    final bufferLimit = (maxDailyRequests * 0.9).round();

    if (currentRequests >= bufferLimit) {
      _log.e(
        'Daily limit reached: $currentRequests/$maxDailyRequests (buffer: $bufferLimit)',
      );
      return false;
    }

    return true;
  }

  /// Retrieves the directory path for downloaded media assets.
  static Future<String> _getMediaDirectory() async {
    if (_cachedMediaDirectory != null) {
      return _cachedMediaDirectory!;
    }

    final mediaPath = await ConfigService.getMediaPath();
    final mediaDir = Directory(mediaPath);
    if (!await mediaDir.exists()) {
      await mediaDir.create(recursive: true);
    }
    _cachedMediaDirectory = mediaDir.path;

    return _cachedMediaDirectory!;
  }

  /// Sanitizes a ROM filename by removing system-specific extensions.
  static Future<String> _getCleanRomName(
    String romName,
    String? appSystemId,
  ) async {
    if (appSystemId != null) {
      try {
        final extensions = await SystemRepository.getExtensionsForSystem(
          appSystemId,
        );
        for (final ext in extensions) {
          final dotExt = '.$ext';
          if (romName.toLowerCase().endsWith(dotExt.toLowerCase())) {
            return romName.substring(0, romName.length - dotExt.length);
          }
        }
      } catch (e) {
        _log.w('Error getting extensions for app system $appSystemId: $e');
      }
    }

    final lastDot = romName.lastIndexOf('.');
    if (lastDot != -1) {
      final ext = romName.substring(lastDot + 1);
      if (!ext.contains(' ') && ext.length <= 10) {
        return romName.substring(0, lastDot);
      }
    }

    return romName;
  }

  /// Authenticates user credentials against the ScreenScraper API.
  static Future<Map<String, dynamic>?> verifyCredentials(
    String username,
    String password,
  ) async {
    try {
      final softname = await _getSoftname();
      final url = Uri.parse('$_baseUrl/ssuserInfos.php').replace(
        queryParameters: {
          'devid': _devId,
          'devpassword': _devPassword,
          'softname': softname,
          'output': 'json',
          'ssid': username,
          'sspassword': password,
        },
      );

      final response = await _httpGetWithRetry(
        url,
        headers: {'User-Agent': 'NeoStation/1.0', 'Accept': 'application/json'},
      );

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        if (data['header']['success'] == 'true') {
          return data;
        } else {
          _log.e('Invalid credentials: ${data['header']['error']}');
          return null;
        }
      } else if (response.statusCode == 403) {
        _log.e('Error 403: Invalid credentials');
        return null;
      } else {
        _log.e('HTTP Error ${response.statusCode}: ${response.body}');
        return null;
      }
    } catch (e) {
      _log.e('Error verifying credentials: $e');
      return null;
    }
  }

  /// Persists encrypted ScreenScraper credentials and user tier information
  /// to the local database.
  static Future<bool> saveCredentials(
    String username,
    String password, [
    Map<String, dynamic>? userInfo,
    String? preferredLanguage,
  ]) async {
    try {
      return await ScraperRepository.saveCredentials(
        username,
        password,
        userInfo,
        preferredLanguage,
      );
    } catch (e) {
      _log.e('Error saving credentials: $e');
      return false;
    }
  }

  /// Refreshes local user statistics and account tier from the API.
  static Future<bool> refreshCredentials() async {
    try {
      final credentials = await getSavedCredentials();
      if (credentials == null) return false;

      final username = credentials['username']!;
      final password = credentials['password']!;

      final userInfo = await verifyCredentials(username, password);
      if (userInfo != null) {
        return await saveCredentials(
          username,
          password,
          userInfo['response']['ssuser'] as Map<String, dynamic>?,
          credentials['preferred_language'],
        );
      }
      return false;
    } catch (e) {
      _log.e('Error refreshing credentials: $e');
      return false;
    }
  }

  /// Retrieves the saved ScreenScraper credentials from the database.
  static Future<Map<String, String>?> getSavedCredentials() async {
    try {
      return await ScraperRepository.getSavedCredentials();
    } catch (e) {
      _log.e('Error getting saved credentials: $e');
      return null;
    }
  }

  /// Deletes saved credentials from the local database.
  static Future<bool> clearCredentials() async {
    try {
      return await ScraperRepository.clearCredentials();
    } catch (e) {
      _log.e('Error deleting credentials: $e');
      return false;
    }
  }

  /// Checks if credentials have been saved locally.
  static Future<bool> hasSavedCredentials() async {
    final credentials = await getSavedCredentials();
    return credentials != null;
  }

  /// Retrieves the current scraper configuration (modes and media types to fetch).
  static Future<Map<String, dynamic>> getScraperConfig() async {
    try {
      return await ScraperRepository.getScraperConfig();
    } catch (e) {
      _log.e('Error getting scraper configuration: $e');
      return {
        'scrape_mode': 'new_only',
        'scrape_metadata': true,
        'scrape_images': true,
        'scrape_videos': true,
      };
    }
  }

  /// Updates the scraper configuration.
  static Future<bool> saveScraperConfig(Map<String, dynamic> config) async {
    try {
      return await ScraperRepository.saveScraperConfig(config);
    } catch (e) {
      _log.e('Error saving scraper configuration: $e');
      return false;
    }
  }

  /// Retrieves the internal system mappings for enabled ScreenScraper integration.
  static Future<List<Map<String, dynamic>>> getSystemMappings() async {
    try {
      return await ScraperRepository.getSystemMappings();
    } catch (e) {
      _log.e('Error getting system mappings: $e');
      return [];
    }
  }

  /// Fetches the global list of supported systems from ScreenScraper.
  static Future<List<Map<String, dynamic>>?> getSystemsList() async {
    try {
      final credentials = await getSavedCredentials();
      if (credentials == null) {
        _log.e('There is no saved credentials to get systems list');
        return null;
      }

      final softname = await _getSoftname();
      final url = Uri.parse('$_baseUrl/systemesListe.php').replace(
        queryParameters: {
          'devid': _devId,
          'devpassword': _devPassword,
          'softname': softname,
          'output': 'json',
          'ssid': credentials['username'],
          'sspassword': credentials['password'],
        },
      );

      final response = await _httpGetWithRetry(
        url,
        headers: {'User-Agent': 'NeoStation/1.0', 'Accept': 'application/json'},
      );

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        if (data['header']['success'] == 'true') {
          final systems = data['response']['systemes'] as List;
          return systems.cast<Map<String, dynamic>>();
        } else {
          _log.e('Error getting systems list: ${data['header']['error']}');
          return null;
        }
      } else {
        _log.e('HTTP Error ${response.statusCode}: ${response.body}');
        return null;
      }
    } catch (e) {
      _log.e('Error getting systems list: $e');
      return null;
    }
  }

  /// Synchronizes local system IDs with ScreenScraper IDs by matching folder names.
  static Future<bool> syncSystemIds() async {
    try {
      final unmappedCount = await ScraperRepository.getUnmappedSystemsCount();
      if (unmappedCount == 0) {
        await ScraperRepository.initializeScraperSystemConfig();
        return true;
      }

      final detectedSystems =
          await ScraperRepository.getDetectedSystemsWithScraperIds();

      if (detectedSystems.isEmpty) {
        _log.w('There is no detected systems to sync');
        return true;
      }

      final systemsList = await getSystemsList();
      if (systemsList == null) {
        return false;
      }

      final screenscraperMap = <String, int>{};
      for (final system in systemsList) {
        final noms = system['noms'] as Map<String, dynamic>;
        final nomRecalbox = noms['nom_recalbox']?.toString();
        if (nomRecalbox != null) {
          final names = nomRecalbox.split(',');
          for (final name in names) {
            final trimmedName = name.trim();
            if (trimmedName.isNotEmpty) {
              screenscraperMap[trimmedName] =
                  int.tryParse(system['id']?.toString() ?? '0') ?? 0;
            }
          }
        }
      }

      for (final system in detectedSystems) {
        final appSystemId = system['id'].toString();
        final folderName = system['folder_name']?.toString();
        final realName = system['real_name']?.toString();

        if (folderName == null || realName == null) continue;

        if (system['screenscraper_id'] != null) continue;

        final foundScreenscraperId = screenscraperMap[folderName];

        if (foundScreenscraperId != null) {
          await ScraperRepository.updateSystemScraperId(
            appSystemId,
            foundScreenscraperId,
          );
        }
      }

      await ScraperRepository.initializeScraperSystemConfig();
      return true;
    } catch (e) {
      _log.e('Error syncing system IDs: $e');
      return false;
    }
  }

  /// Fetches game information from the API using name or hash.
  ///
  /// Returns a map containing both `gameInfo` and updated `userInfo` (quota).
  static Future<Map<String, dynamic>?> fetchGameInfo(
    String systemId,
    String romName, {
    String? appSystemId,
    String? md5,
    int? maxDailyRequests,
    String? gameName,
  }) async {
    try {
      final credentials = _cachedCredentials ?? await getSavedCredentials();
      if (credentials == null) {
        _log.e('There is no saved credentials to get game information');
        return null;
      }

      _cachedCredentials ??= credentials;
      final softname = await _getSoftname();

      String? targetAppSystemId = appSystemId;
      if (targetAppSystemId == null) {
        try {
          targetAppSystemId = await ScraperRepository.getAppSystemIdByScraperId(
            systemId,
          );
        } catch (_) {}
      }

      final cleanRomName = await _getCleanRomName(
        gameName ?? romName,
        targetAppSystemId,
      );

      final queryParameters = {
        'devid': _devId,
        'devpassword': _devPassword,
        'softname': softname,
        'output': 'json',
        'ssid': credentials['username'],
        'sspassword': credentials['password'],
        'systemeid': systemId,
        'romtype': 'rom',
        'romnom': cleanRomName,
      };

      final preferredLanguage = credentials['preferred_language'];
      if (preferredLanguage != null && preferredLanguage.isNotEmpty) {
        queryParameters['langue'] = preferredLanguage;
      }

      if (md5 != null && md5.isNotEmpty) {
        queryParameters['md5'] = md5;
      }

      final url = Uri.parse(
        '$_baseUrl/jeuInfos.php',
      ).replace(queryParameters: queryParameters);

      final response = await _httpGetWithRetry(
        url,
        headers: {'User-Agent': 'NeoStation/1.0', 'Accept': 'application/json'},
        maxDailyRequests: maxDailyRequests,
      );

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        if (data['header']['success'] == 'true') {
          return {
            'gameInfo': data['response']['jeu'],
            'userInfo': data['response']['ssuser'],
          };
        } else {
          _log.e('Error getting game information: ${data['header']['error']}');
          return null;
        }
      } else {
        _log.e('HTTP Error ${response.statusCode}: ${response.body}');
        return null;
      }
    } catch (e) {
      _log.e('Error getting game information: $e');
      return null;
    }
  }

  /// Maps a raw API response to the NeoStation metadata schema.
  ///
  /// Handles language localization priority and region-based selection
  /// using the global priority map (World > US > EU > FR/SP/IT/DE > JP > KR/CN).
  static Future<Map<String, dynamic>> _mapGameInfoToMetadata(
    String filename,
    String romPath,
    Map<String, dynamic> gameInfo, {
    String? preferredLanguage,
  }) async {
    final metadata = <String, dynamic>{};
    metadata['filename'] = filename;

    final noms = gameInfo['noms'] as List<dynamic>? ?? [];
    String? realName;
    int bestNamePriority = -1;
    for (final nom in noms) {
      final region = nom['region']?.toString();
      final text = nom['text']?.toString();
      if (text != null && text.isNotEmpty) {
        final priority = _regionPriority[region] ?? 0;
        if (priority > bestNamePriority) {
          bestNamePriority = priority;
          realName = text;
        }
      }
    }
    metadata['real_name'] = realName ?? filename;

    final synopses = gameInfo['synopsis'] as List<dynamic>? ?? [];
    String? preferredDescription;

    if (preferredLanguage != null) {
      for (final synopsis in synopses) {
        final langue = synopsis['langue']?.toString();
        final text = synopsis['text']?.toString();
        if (text != null && langue == preferredLanguage) {
          preferredDescription = text;
          break;
        }
      }
    }

    if (preferredDescription == null) {
      const languagePriority = ['en', 'es', 'fr', 'de', 'it', 'pt'];
      for (final lang in languagePriority) {
        for (final synopsis in synopses) {
          final langue = synopsis['langue']?.toString();
          final text = synopsis['text']?.toString();
          if (text != null && langue == lang) {
            preferredDescription = text;
            break;
          }
        }
        if (preferredDescription != null) break;
      }
    }

    for (final synopsis in synopses) {
      final langue = synopsis['langue']?.toString();
      final text = synopsis['text']?.toString();
      if (text != null) {
        switch (langue) {
          case 'en':
            metadata['description_en'] = text;
            break;
          case 'es':
            metadata['description_es'] = text;
            break;
          case 'fr':
            metadata['description_fr'] = text;
            break;
          case 'de':
            metadata['description_de'] = text;
            break;
          case 'it':
            metadata['description_it'] = text;
            break;
          case 'pt':
            metadata['description_pt'] = text;
            break;
        }
      }
    }

    final note = gameInfo['note'];
    if (note != null && note['text'] != null) {
      final rating = double.tryParse(note['text'].toString());
      if (rating != null) metadata['rating'] = rating;
    }

    final dates = gameInfo['dates'] as List<dynamic>? ?? [];
    DateTime? releaseDate;
    int bestDatePriority = -1;
    for (final date in dates) {
      final region = date['region']?.toString();
      final dateText = date['text']?.toString();
      if (dateText != null) {
        try {
          final parsedDate = DateTime.parse(dateText);
          final priority = _regionPriority[region] ?? 0;
          if (priority > bestDatePriority) {
            bestDatePriority = priority;
            releaseDate = parsedDate;
          }
        } catch (_) {}
      }
    }
    if (releaseDate != null) {
      metadata['release_date'] = releaseDate.toIso8601String();
    }

    metadata['developer'] = gameInfo['developpeur']?['text']?.toString();
    metadata['publisher'] = gameInfo['editeur']?['text']?.toString();

    final genres = gameInfo['genres'] as List<dynamic>? ?? [];
    if (genres.isNotEmpty) {
      final genre = genres[0];
      final genreNoms = genre['noms'] as List<dynamic>? ?? [];
      String? genreText;

      if (preferredLanguage != null) {
        for (final nom in genreNoms) {
          final langue = nom['langue']?.toString();
          final text = nom['text']?.toString();
          if (text != null && langue == preferredLanguage) {
            genreText = text;
            break;
          }
        }
      }

      if (genreText == null) {
        for (final nom in genreNoms) {
          final langue = nom['langue']?.toString();
          final text = nom['text']?.toString();
          if (text != null && langue == 'en') {
            genreText = text;
            break;
          }
        }
      }

      metadata['genre'] =
          genreText ?? (genreNoms.isNotEmpty ? genreNoms[0]['text'] : null);
    }

    metadata['players'] = gameInfo['joueurs']?['text']?.toString();

    return metadata;
  }

  /// Saves the metadata to the local user_screenscraper_metadata table.
  static Future<bool> _saveGameMetadata(
    Map<String, dynamic> metadata,
    String appSystemId, {
    bool isFullyScraped = false,
  }) async {
    try {
      return await ScraperRepository.saveGameMetadata(
        metadata,
        appSystemId,
        isFullyScraped: isFullyScraped,
      );
    } catch (e) {
      _log.e('Error saving metadata for ${metadata['filename']}: $e');
      return false;
    }
  }

  /// Maps API media type names to NeoStation folder names.
  static String _mapMediaTypeToFolder(String mediaType) {
    switch (mediaType) {
      case 'fanart':
        return 'fanarts';
      case 'ss':
        return 'screenshots';
      case 'video':
        return 'videos';
      case 'wheel':
        return 'wheels';
      case 'box2D':
        return 'box2d';
      default:
        return mediaType;
    }
  }

  /// Selects the best media asset from a list based on region and language priority.
  ///
  /// Priority: World > US > EU > Others > Asia.
  static Map<String, dynamic>? _selectBestMedia(
    List<dynamic> medias,
    String mediaType, {
    String? preferredLanguage,
  }) {
    if (medias.isEmpty) return null;

    final typesToSearch = mediaType == 'wheel'
        ? ['wheel-hd', 'wheel']
        : (mediaType == 'ss'
            ? ['ss-hd', 'ss']
            : (mediaType == 'box2D' ? ['box-2D'] : [mediaType]));

    const defaultLanguageHierarchy = ['en', 'es', 'fr', 'de', 'it', 'pt', 'jp'];

    Map<String, dynamic>? bestMedia;
    int bestPriority = -1;

    final candidates = medias
        .where((m) => typesToSearch.contains(m['type']))
        .toList();

    for (final media in candidates) {
      final region = media['region']?.toString() ?? '';
      final regionValue = _regionPriority[region] ?? 5;

      int languageBonus = 0;
      final mediaLang = media['langue']?.toString() ?? '';

      if (preferredLanguage != null && preferredLanguage.isNotEmpty) {
        if (mediaLang == preferredLanguage) languageBonus = 200;
      } else {
        final langIndex = defaultLanguageHierarchy.indexOf(mediaLang);
        if (langIndex != -1) {
          languageBonus = (defaultLanguageHierarchy.length - langIndex) * 10;
        }
      }

      final bool isHD = (media['type']?.toString() ?? '').endsWith('-hd');
      final int totalPriority = regionValue + languageBonus + (isHD ? 1 : 0);

      if (totalPriority > bestPriority) {
        bestPriority = totalPriority;
        bestMedia = media as Map<String, dynamic>;
      }
    }

    return bestMedia;
  }

  /// Verifies if a specific media asset exists in the local cache.
  static Future<bool> _checkFileExists(
    String relativePath,
    String userDataDir,
  ) async {
    try {
      final fullPath = path.join(userDataDir, relativePath);
      return await File(fullPath).exists();
    } catch (e) {
      return false;
    }
  }

  /// Downloads and caches a media file.
  static Future<bool> _downloadMediaFileSmart(
    String url,
    String relativePath,
    String userDataDir, {
    bool forceOverwrite = false,
  }) async {
    try {
      final fullPath = path.join(userDataDir, relativePath);
      final file = File(fullPath);
      if (await file.exists() && !forceOverwrite) {
        return true;
      }

      final response = await _httpClient.get(Uri.parse(url));
      if (response.statusCode == 200) {
        await file.create(recursive: true);
        await file.writeAsBytes(response.bodyBytes);
        return true;
      } else {
        _log.e('Error downloading media (${response.statusCode}): $url');
        return false;
      }
    } catch (e) {
      _log.e('Error downloading media: $e');
      return false;
    }
  }

  /// Downloads multiple media assets for a game, managing concurrency.
  static Future<Map<String, dynamic>> _downloadGameMedia(
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
  }) async {
    if (medias.isEmpty) {
      return {
        'success': true,
        'downloadedTypes': <String>[],
        'cancelled': false,
      };
    }

    final userDataDir = await _getMediaDirectory();
    final mediaTypes = allowedMediaTypes ?? ['fanart', 'ss', 'video', 'wheel', 'box2D'];

    final downloadTasks = <Map<String, dynamic>>[];
    for (final mediaType in mediaTypes) {
      final bestMedia = _selectBestMedia(
        medias,
        mediaType,
        preferredLanguage: preferredLanguage,
      );
      if (bestMedia != null) {
        final folderName = _mapMediaTypeToFolder(mediaType);
        final romBaseName = await _getCleanRomName(romName, appSystemId);
        final fileName =
            '$romBaseName.${bestMedia['format']?.toString() ?? 'png'}';
        final relativePath = '$systemFolder/$folderName/$fileName';

        downloadTasks.add({
          'url': bestMedia['url'].toString(),
          'relativePath': relativePath,
          'mediaType': mediaType,
        });
      }
    }

    if (downloadTasks.isEmpty) {
      return {
        'success': true,
        'downloadedTypes': <String>[],
        'cancelled': false,
      };
    }

    final batches = <List<Map<String, dynamic>>>[];
    for (var i = 0; i < downloadTasks.length; i += maxThreads) {
      final end = (i + maxThreads < downloadTasks.length)
          ? i + maxThreads
          : downloadTasks.length;
      batches.add(downloadTasks.sublist(i, end));
    }

    final downloadedTypes = <String>[];
    final existingTypes = <String>[];
    bool wasCancelled = false;

    int completedTasks = 0;
    for (final batch in batches) {
      if (shouldCancel != null && shouldCancel()) {
        wasCancelled = true;
        break;
      }

      final futures = batch.map((task) async {
        final success = await _downloadMediaFileSmart(
          task['url'],
          task['relativePath'],
          userDataDir,
          forceOverwrite: forceOverwrite,
        );
        return {
          'mediaType': task['mediaType'],
          'success': success,
          'wasExisting':
              !forceOverwrite &&
              success &&
              await _checkFileExists(task['relativePath'], userDataDir),
        };
      });

      final results = await Future.wait(futures);

      for (final result in results) {
        if (result['success'] == true) {
          if (result['wasExisting'] as bool) {
            existingTypes.add(result['mediaType'] as String);
          } else {
            downloadedTypes.add(result['mediaType'] as String);
          }
        }
      }

      completedTasks += batch.length;
      if (onProgress != null) onProgress(completedTasks / downloadTasks.length);

      if (batches.length > 1) {
        await Future.delayed(const Duration(milliseconds: 100));
      }
    }

    final totalAvailable = downloadedTypes.length + existingTypes.length;
    return {
      'success': totalAvailable == downloadTasks.length && !wasCancelled,
      'downloadedTypes': downloadedTypes,
      'existingTypes': existingTypes,
      'cancelled': wasCancelled,
    };
  }

  /// Scrapes a single game by its filename and updates its local state.
  static Future<Map<String, dynamic>> scrapeSingleGame({
    required String appSystemId,
    required String romName,
    required String systemFolder,
    required String romPath,
    String? gameName,
    Function(String status, double progress)? onProgress,
    bool forceOverwrite = false,
  }) async {
    try {
      onProgress?.call(AppLocale.checkingCredentials, 0.05);

      if (!await hasSavedCredentials()) {
        return {'success': false, 'message': AppLocale.scrapeNoCredentials};
      }

      int? screenScraperSystemId =
          await ScraperRepository.getScreenScraperIdByAppSystemId(appSystemId);

      if (screenScraperSystemId == null) {
        await syncSystemIds();
        screenScraperSystemId =
            await ScraperRepository.getScreenScraperIdByAppSystemId(
              appSystemId,
            );
      }

      if (screenScraperSystemId == null) {
        return {'success': false, 'message': AppLocale.scrapeSystemNotMapped};
      }

      onProgress?.call(AppLocale.fetchingMetadata, 0.1);

      Map<String, dynamic>? gameInfoResult;
      int attempts = 0;
      while (attempts < 3) {
        if (attempts > 0) await Future.delayed(const Duration(seconds: 2));
        gameInfoResult = await fetchGameInfo(
          screenScraperSystemId.toString(),
          romName,
          appSystemId: appSystemId,
          maxDailyRequests: 0,
          gameName: (systemFolder == 'android') ? gameName : null,
        );
        if (gameInfoResult != null && gameInfoResult['gameInfo'] != null) break;
        attempts++;
      }

      if (gameInfoResult == null || gameInfoResult['gameInfo'] == null) {
        return {'success': false, 'message': AppLocale.scrapeGameNotFound};
      }

      final gameInfo = gameInfoResult['gameInfo'] as Map<String, dynamic>;
      final credentials = await getSavedCredentials();
      final preferredLanguage = credentials?['preferred_language'] ?? 'en';
      final scraperConfig = await getScraperConfig();

      if (scraperConfig['scrape_metadata'] as bool? ?? true) {
        final metadata = await _mapGameInfoToMetadata(
          romName,
          romPath,
          gameInfo,
          preferredLanguage: preferredLanguage,
        );
        await _saveGameMetadata(metadata, appSystemId, isFullyScraped: true);
      }

      onProgress?.call(AppLocale.downloadingImages, 0.2);

      final allowedMediaTypes = <String>[];
      if (scraperConfig['scrape_images'] as bool? ?? true) {
        allowedMediaTypes.addAll(['fanart', 'ss', 'wheel', 'box2D']);
      }
      if (scraperConfig['scrape_videos'] as bool? ?? true) {
        allowedMediaTypes.add('video');
      }

      if (allowedMediaTypes.isEmpty) {
        return {'success': true, 'message': AppLocale.scrapeSuccessful};
      }

      final medias = gameInfo['medias'] as List<dynamic>? ?? [];
      final downloadResult = await _downloadGameMedia(
        systemFolder,
        romName,
        medias,
        1,
        appSystemId: appSystemId,
        preferredLanguage: preferredLanguage,
        allowedMediaTypes: allowedMediaTypes,
        forceOverwrite: forceOverwrite,
        onProgress: (p) =>
            onProgress?.call(AppLocale.downloadingImages, 0.2 + (p * 0.8)),
      );

      return {
        'success': downloadResult['success'] == true,
        'message': downloadResult['success'] == true
            ? AppLocale.scrapeSuccessful
            : AppLocale.scrapeMediaDownloadsFailed,
      };
    } catch (e) {
      _log.e('Error scraping single game: $e');
      return {'success': false, 'message': AppLocale.scrapeUnexpectedError};
    }
  }

  /// Initiates a background scraping process for all detected ROMs.
  ///
  /// Coordinates system synchronization, batch processing, and thread-safe
  /// quota monitoring. Notifies the provided [ScrapingProvider] about progress.
  static Future<bool> startMetadataScraping(
    BuildContext context,
    ScrapingProvider scrapingProvider, {
    bool Function()? shouldCancel,
  }) async {
    try {
      if (_isMetadataScrapingRunning) return false;
      _isMetadataScrapingRunning = true;

      final startTime = DateTime.now();
      final credentials = await getSavedCredentials();
      if (credentials == null) return false;

      _initializeDailyCounter(0);
      final maxThreads = int.tryParse(credentials['maxthreads'] ?? '4') ?? 4;
      _updateRequestSemaphore(maxThreads);

      final preferredLanguage = credentials['preferred_language'] ?? 'en';
      final scraperConfig = await getScraperConfig();
      final scrapeMode = scraperConfig['scrape_mode'].toString();

      final systemMappings = await getSystemMappings();
      if (systemMappings.isEmpty) return false;

      final systemsWithRoms = <Map<String, dynamic>>[];
      int totalGamesToProcess = 0;

      for (final systemMapping in systemMappings) {
        final appSystemId = systemMapping['app_system_id'].toString();
        final count = await ScraperRepository.getRomCountForScraping(
          appSystemId,
          scrapeMode,
        );
        if (count > 0) {
          systemsWithRoms.add(systemMapping);
          totalGamesToProcess += count;
        }
      }

      if (systemsWithRoms.isEmpty) {
        scrapingProvider.stopScraping();
        return true;
      }

      scrapingProvider.updateProgress(
        totalGames: totalGamesToProcess,
        processedGames: 0,
        successfulGames: 0,
        failedGames: 0,
      );

      final allRomsToProcess = <Map<String, dynamic>>[];
      for (final systemMapping in systemsWithRoms) {
        final appSystemId = systemMapping['app_system_id'].toString();
        final romsQueryResult = await ScraperRepository.getRomsForScraping(
          appSystemId,
          scrapeMode,
        );

        for (final rom in romsQueryResult) {
          final copy = Map<String, dynamic>.from(rom);
          copy['system_id'] = appSystemId;
          copy['screenscraper_system_id'] =
              systemMapping['screenscraper_system_id'];
          copy['system_name'] = systemMapping['real_name'];
          copy['system_folder'] = systemMapping['primary_folder_name'];
          allRomsToProcess.add(copy);
        }
      }

      int totalProcessedGames = 0;
      int totalSuccessfulGames = 0;
      int totalFailedGames = 0;

      final batches = <List<Map<String, dynamic>>>[];
      for (var i = 0; i < allRomsToProcess.length; i += maxThreads) {
        batches.add(
          allRomsToProcess.sublist(
            i,
            (i + maxThreads < allRomsToProcess.length)
                ? i + maxThreads
                : allRomsToProcess.length,
          ),
        );
      }

      for (final batch in batches) {
        scrapingProvider.clearCompletedThreads();
        if (shouldCancel != null && shouldCancel()) {
          scrapingProvider.stopScraping();
          return false;
        }

        final batchFutures = <Future<Map<String, dynamic>>>[];
        for (var threadIndex = 0; threadIndex < batch.length; threadIndex++) {
          final threadId = threadIndex + 1;
          batchFutures.add(
            _processRomInThread(
              rom: batch[threadIndex],
              threadId: threadId,
              systemName: batch[threadIndex]['system_name'],
              systemFolder: batch[threadIndex]['system_folder'],
              screenscraperSystemId:
                  int.tryParse(
                    batch[threadIndex]['screenscraper_system_id']?.toString() ??
                        '0',
                  ) ??
                  0,
              appSystemId: batch[threadIndex]['system_id'],
              maxThreads: maxThreads,
              maxDailyRequests: 100000,
              preferredLanguage: preferredLanguage,
              scrapingProvider: scrapingProvider,
              shouldCancel: shouldCancel,
              scraperConfig: scraperConfig,
            ),
          );
        }

        final results = await Future.wait(batchFutures);
        for (var i = 0; i < results.length; i++) {
          totalProcessedGames++;
          if (results[i]['success'] == true) {
            totalSuccessfulGames++;
          } else if (results[i]['cancelled'] == true) {
            return false;
          } else {
            totalFailedGames++;
          }

          scrapingProvider.markThreadCompleted(i + 1);
          scrapingProvider.updateProgress(
            totalGames: totalGamesToProcess,
            processedGames: totalProcessedGames,
            successfulGames: totalSuccessfulGames,
            failedGames: totalFailedGames,
          );
        }
        if (batches.length > 1) {
          await Future.delayed(const Duration(milliseconds: 200));
        }
      }

      if (context.mounted) {
        _showScrapingSummaryDialog(
          context,
          totalGames: totalGamesToProcess,
          successfulGames: totalSuccessfulGames,
          failedGames: totalFailedGames,
          elapsedTime: '${DateTime.now().difference(startTime).inSeconds}s',
          totalRequests: 0,
        );
      }

      scrapingProvider.stopScraping();
      return true;
    } catch (e) {
      _log.e('Error during scraping process: $e');
      scrapingProvider.stopScraping();
      return false;
    } finally {
      _cachedCredentials = null;
      _isMetadataScrapingRunning = false;
    }
  }

  /// Internal worker thread processing for a single ROM during a batch operation.
  static Future<Map<String, dynamic>> _processRomInThread({
    required Map<String, dynamic> rom,
    required int threadId,
    required String systemName,
    required String systemFolder,
    required int screenscraperSystemId,
    required String appSystemId,
    required int maxThreads,
    required int maxDailyRequests,
    required String? preferredLanguage,
    required ScrapingProvider scrapingProvider,
    required bool Function()? shouldCancel,
    required Map<String, dynamic> scraperConfig,
  }) async {
    try {
      final filename = rom['filename'].toString();
      final romPath = rom['rom_path'].toString();
      final titleName = rom['title_name']?.toString();

      scrapingProvider.updateThreadProgress(
        threadId: threadId,
        gameName: filename,
        systemName: systemName,
        isActive: true,
        status: ThreadStatus.active,
        currentStep: ThreadProcessingStep.fetchingMetadata,
        progress: 0.0,
      );

      if (shouldCancel != null && shouldCancel()) {
        return {'success': false, 'cancelled': true, 'requests': 0};
      }

      final gameResult = await fetchGameInfo(
        screenscraperSystemId.toString(),
        filename,
        appSystemId: appSystemId,
        maxDailyRequests: maxDailyRequests,
        gameName: (systemFolder == 'android') ? titleName : null,
      );
      var gameInfo = gameResult?['gameInfo'];
      int requestsMade = 1;

      if (gameResult?['userInfo'] != null) {
        final ui = gameResult!['userInfo'];
        scrapingProvider.updateProgress(
          totalRequests:
              int.tryParse(ui['requeststoday']?.toString() ?? '0') ?? 0,
          maxDailyRequests:
              int.tryParse(ui['maxrequestsperday']?.toString() ?? '0') ?? 0,
        );
      }

      scrapingProvider.updateThreadProgress(
        threadId: threadId,
        gameName: filename,
        systemName: systemName,
        isActive: true,
        status: ThreadStatus.active,
        currentStep: ThreadProcessingStep.scanningImages,
        progress: 0.33,
      );

      if (gameInfo == null &&
          systemFolder != 'android' &&
          File(romPath).existsSync()) {
        final hash = await _calculateMd5InIsolate(romPath);
        final resWithHash = await fetchGameInfo(
          screenscraperSystemId.toString(),
          filename,
          appSystemId: appSystemId,
          md5: hash,
          maxDailyRequests: maxDailyRequests,
        );
        gameInfo = resWithHash?['gameInfo'];
        requestsMade++;
      }

      if (gameInfo != null) {
        if (scraperConfig['scrape_metadata'] as bool? ?? true) {
          final metadata = await _mapGameInfoToMetadata(
            filename,
            romPath,
            gameInfo,
            preferredLanguage: preferredLanguage,
          );
          await _saveGameMetadata(metadata, appSystemId, isFullyScraped: false);
        }

        final allowedTypes = <String>[];
        if (scraperConfig['scrape_images'] as bool? ?? true) {
          allowedTypes.addAll(['fanart', 'ss', 'wheel', 'box2D']);
        }
        if (scraperConfig['scrape_videos'] as bool? ?? true) {
          allowedTypes.add('video');
        }

        if (allowedTypes.isNotEmpty) {
          scrapingProvider.updateThreadProgress(
            threadId: threadId,
            gameName: filename,
            systemName: systemName,
            isActive: true,
            status: ThreadStatus.active,
            currentStep: ThreadProcessingStep.downloadingImages,
            progress: 0.66,
          );
          final res = await _downloadGameMedia(
            systemFolder,
            filename,
            gameInfo['medias'] ?? [],
            maxThreads,
            appSystemId: appSystemId,
            preferredLanguage: preferredLanguage,
            shouldCancel: shouldCancel,
            allowedMediaTypes: allowedTypes,
          );
          if (res['cancelled'] == true) {
            return {
              'success': false,
              'cancelled': true,
              'requests': requestsMade,
            };
          }
          if (res['success'] == true) {
            await ScraperRepository.markGameFullyScraped(filename);
          }
        }

        scrapingProvider.updateThreadProgress(
          threadId: threadId,
          gameName: filename,
          systemName: systemName,
          isActive: false,
          status: ThreadStatus.completed,
          currentStep: ThreadProcessingStep.completed,
          progress: 1.0,
        );
        return {'success': true, 'cancelled': false, 'requests': requestsMade};
      }
      return {'success': false, 'cancelled': false, 'requests': requestsMade};
    } catch (e) {
      return {'success': false, 'cancelled': false, 'requests': 0};
    }
  }

  /// Checks the local availability of required media assets for a given game.
  static Future<Map<String, dynamic>> checkGameMediaStatus(
    String appSystemId,
    String romName,
  ) async {
    try {
      final systemFolder = await ScraperRepository.getSystemFolderNameById(
        appSystemId,
      );
      if (systemFolder == null) {
        return {'hasAllMedia': false, 'error': 'System not found'};
      }
      final userDataDir = await _getMediaDirectory();
      const expectedTypes = ['fanarts', 'screenshots', 'videos', 'box2d'];
      final romBaseName = await _getCleanRomName(romName, appSystemId);
      final missing = <String>[];
      final existing = <String>[];

      for (final type in expectedTypes) {
        bool found = false;
        for (final ext in ['.png', '.jpg', '.jpeg', '.mp4', '.webm']) {
          if (await File(
            path.join(
              userDataDir,
              'media',
              systemFolder,
              type,
              '$romBaseName$ext',
            ),
          ).exists()) {
            existing.add(type);
            found = true;
            break;
          }
        }
        if (!found) missing.add(type);
      }

      return {
        'hasAllMedia': missing.isEmpty,
        'existingMedia': existing,
        'missingMedia': missing,
      };
    } catch (e) {
      return {'hasAllMedia': false, 'error': e.toString()};
    }
  }

  /// Displays the final results of a scraping session in a localized dialog.
  static void _showScrapingSummaryDialog(
    BuildContext context, {
    required int totalGames,
    required int successfulGames,
    required int failedGames,
    required String elapsedTime,
    required int totalRequests,
  }) async {
    await showDialog(
      context: context,
      barrierDismissible: true,
      builder: (BuildContext context) => _ScrapingSummaryDialogContent(
        totalGames: totalGames,
        successfulGames: successfulGames,
        failedGames: failedGames,
        elapsedTime: elapsedTime,
      ),
    );
  }
}

/// Specialized dialog content providing gamepad-friendly navigation for
/// scraping session summaries.
class _ScrapingSummaryDialogContent extends StatefulWidget {
  final int totalGames;
  final int successfulGames;
  final int failedGames;
  final String elapsedTime;

  const _ScrapingSummaryDialogContent({
    required this.totalGames,
    required this.successfulGames,
    required this.failedGames,
    required this.elapsedTime,
  });

  @override
  State<_ScrapingSummaryDialogContent> createState() =>
      _ScrapingSummaryDialogContentState();
}

class _ScrapingSummaryDialogContentState
    extends State<_ScrapingSummaryDialogContent> {
  late GamepadNavigation _gamepadNav;

  @override
  void initState() {
    super.initState();
    _gamepadNav = GamepadNavigation(
      onSelectItem: () => Navigator.of(context).pop(),
      onBack: () => Navigator.of(context).pop(),
    );
    _gamepadNav.initialize();
    GamepadNavigationManager.pushLayer(
      'scraping_summary_dialog',
      onActivate: () => _gamepadNav.activate(),
      onDeactivate: () => _gamepadNav.deactivate(),
    );
  }

  @override
  void dispose() {
    GamepadNavigationManager.popLayer('scraping_summary_dialog');
    _gamepadNav.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final rate = widget.totalGames > 0
        ? ((widget.successfulGames / widget.totalGames) * 100).toStringAsFixed(
            1,
          )
        : '0.0';
    return Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: EdgeInsets.symmetric(horizontal: 10.w, vertical: 6.h),
      child: Container(
        constraints: BoxConstraints(maxWidth: 240.w),
        decoration: BoxDecoration(
          color: Theme.of(context).scaffoldBackgroundColor,
          borderRadius: BorderRadius.circular(12.r),
          border: Border.all(
            color: Theme.of(context).colorScheme.outline.withValues(alpha: 0.3),
            width: 1.r,
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.6),
              blurRadius: 10.r,
              spreadRadius: 1.r,
            ),
          ],
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(12.r),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: double.infinity,
                padding: EdgeInsets.symmetric(vertical: 8.h),
                decoration: BoxDecoration(
                  color: Theme.of(
                    context,
                  ).scaffoldBackgroundColor.withValues(alpha: 0.2),
                  border: Border(
                    bottom: BorderSide(
                      color: Theme.of(
                        context,
                      ).colorScheme.outline.withValues(alpha: 0.1),
                      width: 1.r,
                    ),
                  ),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(
                      Symbols.check_circle_rounded,
                      size: 16.r,
                      color: Colors.green,
                    ),
                    SizedBox(width: 6.w),
                    Text(
                      'Scraping Finished',
                      style: TextStyle(
                        fontSize: 13.r,
                        fontWeight: FontWeight.bold,
                        color: Theme.of(context).colorScheme.onSurface,
                      ),
                    ),
                  ],
                ),
              ),
              Padding(
                padding: EdgeInsets.symmetric(horizontal: 12.w, vertical: 10.h),
                child: Column(
                  children: [
                    _buildCompactStatRow('Games', widget.totalGames.toString()),
                    SizedBox(height: 4.h),
                    _buildCompactStatRow(
                      'Success',
                      '${widget.successfulGames} ($rate%)',
                      valueColor: Colors.green,
                    ),
                    SizedBox(height: 4.h),
                    _buildCompactStatRow(
                      'Failed',
                      widget.failedGames.toString(),
                      valueColor: widget.failedGames > 0
                          ? Colors.orange
                          : Theme.of(context).colorScheme.onSurface,
                    ),
                    SizedBox(height: 4.h),
                    _buildCompactStatRow(
                      'Duration',
                      widget.elapsedTime,
                      valueColor: Theme.of(context).colorScheme.primary,
                    ),
                  ],
                ),
              ),
              Padding(
                padding: EdgeInsets.only(left: 12.r, right: 12.r, bottom: 10.r),
                child: SizedBox(
                  width: double.infinity,
                  height: 32.h,
                  child: ElevatedButton(
                    onPressed: () => Navigator.of(context).pop(),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Theme.of(context).colorScheme.primary,
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8.r),
                      ),
                    ),
                    child: Text(
                      'OK',
                      style: TextStyle(
                        fontSize: 12.r,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildCompactStatRow(String label, String value, {Color? valueColor}) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(
          label,
          style: TextStyle(
            fontSize: 11.r,
            color: Theme.of(context).colorScheme.onSurface,
          ),
        ),
        Text(
          value,
          style: TextStyle(
            fontSize: 11.r,
            fontWeight: FontWeight.bold,
            color: valueColor ?? Theme.of(context).colorScheme.onSurface,
          ),
        ),
      ],
    );
  }
}
