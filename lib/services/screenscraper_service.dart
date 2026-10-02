import 'dart:convert';
import 'dart:io';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as path;
import 'package:neostation/services/logger_service.dart';
import '../models/rom_fingerprint.dart';
import '../repositories/scraper_repository.dart';
import 'retroachievements_hash_service.dart';
import 'rom_fingerprint_service.dart';
import 'screenscraper/region_config.dart';
import 'screenscraper/rom_hasher.dart';
import 'screenscraper/media_resolver.dart';
import 'screenscraper/screenscraper_client.dart';
import 'screenscraper/media_downloader.dart';
import 'screenscraper/screenscraper_exceptions.dart';
import '../providers/scraping_provider.dart';
import '../l10n/app_locale.dart';
import '../widgets/scraping_summary_dialog.dart';

/// Why ScreenScraper refused a login attempt.
///
/// Kept distinct from the raw HTTP status so the UI can explain the failure:
/// an overloaded API or a blacklisted app version is not a wrong password, and
/// telling the user to re-check their credentials sends them the wrong way.
enum ScreenScraperAuthFailure {
  invalidCredentials,
  apiClosed,
  appOutdated,
  quotaExceeded,
  networkError,
  unknown,
}

/// Outcome of [ScreenScraperService.verifyCredentials].
class ScreenScraperAuthResult {
  final Map<String, dynamic>? data;
  final ScreenScraperAuthFailure? failure;

  const ScreenScraperAuthResult.success(this.data) : failure = null;

  const ScreenScraperAuthResult.failure(this.failure) : data = null;

  bool get isSuccess => data != null;
}

/// Service responsible for scraping game metadata and media from the
/// ScreenScraper.fr API.
///
/// Features:
/// - Multi-threaded scraping with configurable concurrency.
/// - Hash-first identification (crc32/md5/size), falling back to the filename.
/// - Local caching of metadata and media (images, videos, wheels).
/// - Automatic system mapping between NeoStation and ScreenScraper IDs.
/// - Daily request quota management and credentials verification.
class ScreenScraperService {
  static const String _baseUrl = 'https://api.screenscraper.fr/api2';
  static final _log = LoggerService.instance;

  // Developer credentials — provided at build time via --dart-define
  // or at runtime via environment variables.
  static String get _devId {
    const compileTime = String.fromEnvironment('SCREENSCRAPER_DEV_ID');
    if (compileTime.isNotEmpty) return compileTime;
    return Platform.environment['SCREENSCRAPER_DEV_ID'] ?? '';
  }

  static String get _devPassword {
    const compileTime = String.fromEnvironment('SCREENSCRAPER_DEV_PASSWORD');
    if (compileTime.isNotEmpty) return compileTime;
    return Platform.environment['SCREENSCRAPER_DEV_PASSWORD'] ?? '';
  }

  static Map<String, dynamic>? _cachedCredentials;
  static bool _isMetadataScrapingRunning = false;

  /// Authenticates user credentials against the ScreenScraper API.
  ///
  /// [username] must be the ScreenScraper account username, not the email the
  /// website also accepts: `ssid` only matches the username, so an email is
  /// answered with the same 403 as a wrong password.
  static Future<ScreenScraperAuthResult> verifyCredentials(
    String username,
    String password,
  ) async {
    try {
      final softname = await ScreenscraperClient.getSoftname();
      final url = buildApiUrl('ssuserInfos.php', {
        'devid': _devId,
        'devpassword': _devPassword,
        'softname': softname,
        'output': 'json',
        'ssid': username,
        'sspassword': password,
      });

      final response = await ScreenscraperClient.httpGetWithRetry(
        url,
        headers: {'User-Agent': 'NeoStation/1.0', 'Accept': 'application/json'},
      );

      if (response.statusCode == 200) {
        final data = json.decode(response.body) as Map<String, dynamic>;
        if (data['header']['success'] == 'true') {
          return ScreenScraperAuthResult.success(data);
        }
        _log.e(
          'ScreenScraper rejected the login: ${_summarizeBody(response.body)}',
        );
        return const ScreenScraperAuthResult.failure(
          ScreenScraperAuthFailure.invalidCredentials,
        );
      }

      return _failureFromResponse(
        response.statusCode,
        response.body,
        endpoint: 'ssuserInfos.php',
      );
    } catch (e) {
      _log.e('Error verifying credentials: $e');
      return const ScreenScraperAuthResult.failure(
        ScreenScraperAuthFailure.networkError,
      );
    }
  }

  /// Builds an API URL with every query value percent-encoded.
  ///
  /// [Uri.replace] encodes spaces as `+`, but ScreenScraper documents and
  /// expects `%20` (see its own request examples), and a server-side decoder
  /// that reads `+` literally would corrupt a password containing a space.
  /// Encoding each component keeps special characters in usernames and
  /// passwords intact.
  @visibleForTesting
  static Uri buildApiUrl(String endpoint, Map<String, String> params) {
    final query = params.entries
        .map(
          (e) =>
              '${Uri.encodeComponent(e.key)}=${Uri.encodeComponent(e.value)}',
        )
        .join('&');
    return Uri.parse('$_baseUrl/$endpoint?$query');
  }

  /// Maps a ScreenScraper HTTP status to a failure the UI can act on.
  @visibleForTesting
  static ScreenScraperAuthFailure failureForStatus(int statusCode) {
    switch (statusCode) {
      case 403:
        return ScreenScraperAuthFailure.invalidCredentials;
      case 401:
      case 423:
        // 401: API closed to non-members / overloaded (CPU > 60%).
        // 423: API closed entirely.
        return ScreenScraperAuthFailure.apiClosed;
      case 426:
        return ScreenScraperAuthFailure.appOutdated;
      case 429:
      case 430:
      case 431:
        return ScreenScraperAuthFailure.quotaExceeded;
      default:
        return ScreenScraperAuthFailure.unknown;
    }
  }

  /// Maps a ScreenScraper HTTP error to a failure the UI can act on.
  ///
  /// ScreenScraper sends the real reason in the body even on a 403, but it uses
  /// the same "check the user credentials" wording whether the user or the
  /// developer credentials are wrong, so the endpoint is what attributes the
  /// refusal: only `ssuserInfos.php` checks the account password. The body is
  /// logged so a bug report carries the provider's exact words; the central
  /// logger redacts any credential that appears in it.
  static ScreenScraperAuthResult _failureFromResponse(
    int statusCode,
    String body, {
    required String endpoint,
  }) {
    final detail = _summarizeBody(body);
    _log.e(
      'ScreenScraper $endpoint failed: HTTP $statusCode'
      '${detail.isEmpty ? '' : ' - $detail'}',
    );
    return ScreenScraperAuthResult.failure(failureForStatus(statusCode));
  }

  /// Collapses a response body to a single log-safe line.
  static String _summarizeBody(String body) {
    return body.replaceAll(RegExp(r'\s+'), ' ').trim();
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

      final result = await verifyCredentials(username, password);
      if (result.isSuccess) {
        return await saveCredentials(
          username,
          password,
          result.data!['response']['ssuser'] as Map<String, dynamic>?,
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

      final softname = await ScreenscraperClient.getSoftname();
      final url = buildApiUrl('systemesListe.php', {
        'devid': _devId,
        'devpassword': _devPassword,
        'softname': softname,
        'output': 'json',
        'ssid': credentials['username']!,
        'sspassword': credentials['password']!,
      });

      final response = await ScreenscraperClient.httpGetWithRetry(
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

  /// Returns the cached dump identity for [romPath], computing and caching it
  /// on first use.
  ///
  /// [effort] decides whether a ROM that is not already fingerprinted is worth
  /// reading. Under [FingerprintEffort.cheapOnly] only a cached value or a
  /// zip's stored crc32 comes back, and a null result means "not worth it yet",
  /// not "cannot be done" — so nothing is parked.
  ///
  /// Never throws: a ROM that genuinely cannot be fingerprinted is parked with
  /// its reason and the scrape carries on by name, which is what it did before
  /// hashing existed.
  static Future<RomFingerprint?> _resolveFingerprint(
    String romPath,
    String? systemFolder, {
    required FingerprintEffort effort,
  }) async {
    try {
      final cached = await ScraperRepository.getRomFingerprint(romPath);
      if (cached != null) return cached;

      // A ROM parked for a reason that cannot fix itself (disc, oversize, a
      // corrupt archive) stays parked — re-attempting it every scrape is
      // exactly what the marker exists to stop, and for extract_failed each
      // retry is a full extraction. Transient reasons (missing, error) are
      // allowed through: a re-scrape is the natural retry point, and a fresh
      // fingerprint clears the marker.
      final parked = await ScraperRepository.getRomFingerprintSkipReason(
        romPath,
      );
      if (parked != null &&
          RomFingerprintService.permanentSkipReasons.contains(parked)) {
        return null;
      }

      // Arcade sets are identified by their archive, and which systems those
      // are is declared per system in assets/systems/<sys>.json. Resolved here
      // (cached per system) rather than inside the fingerprinter, which stays
      // free of database reads.
      final policy = await RetroAchievementsHashService.policyForSystem(
        systemFolder,
      );

      // The cheap path reads a few hundred bytes, so an isolate hop would cost
      // more than the work. Only the full read is worth handing off.
      final attempt = effort == FingerprintEffort.cheapOnly
          ? await RomFingerprintService.fingerprint(
              romPath,
              systemFolder,
              keepsArchivesPacked: policy.keepsArchivesPacked,
              effort: FingerprintEffort.cheapOnly,
            )
          : await RomFingerprintService.computeInBackground(
              romPath,
              systemFolder,
              keepsArchivesPacked: policy.keepsArchivesPacked,
            );

      final fingerprint = attempt.fingerprint;
      if (fingerprint == null) {
        // Deferring is not a failure — parking the ROM here would hide it from
        // the full pass that runs a moment later.
        if (attempt.skipReason != RomFingerprintService.deferredCostly) {
          await ScraperRepository.markRomFingerprintSkipped(
            romPath,
            attempt.skipReason ?? RomFingerprintService.skipError,
          );
        }
        return null;
      }

      await ScraperRepository.updateRomFingerprint(romPath, fingerprint);
      return fingerprint;
    } catch (e) {
      _log.w('Could not fingerprint $romPath, scraping by name: $e');
      return null;
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
    String? crc,
    int? romSize,
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
      final softname = await ScreenscraperClient.getSoftname();

      String? targetAppSystemId = appSystemId;
      if (targetAppSystemId == null) {
        try {
          targetAppSystemId = await ScraperRepository.getAppSystemIdByScraperId(
            systemId,
          );
        } catch (_) {}
      }

      final cleanRomName = await ScreenscraperRomHasher.getCleanRomName(
        gameName ?? romName,
        targetAppSystemId,
      );

      final queryParameters = <String, String>{
        'devid': _devId,
        'devpassword': _devPassword,
        'softname': softname,
        'output': 'json',
        'ssid': credentials['username']!,
        'sspassword': credentials['password']!,
        'systemeid': systemId,
        'romtype': 'rom',
        'romnom': cleanRomName,
      };

      final preferredLanguage = credentials['preferred_language'];
      if (preferredLanguage != null && preferredLanguage.isNotEmpty) {
        queryParameters['langue'] = preferredLanguage;
      }

      // Any one of these resolves a lookup on its own and outranks romnom, so
      // an exact dump match does not depend on the filename being tidy. crc has
      // the widest coverage — ScreenScraper's DB is seeded from No-Intro and
      // Redump DATs. Comparison is case-insensitive on their side.
      if (crc != null && crc.isNotEmpty) {
        queryParameters['crc'] = crc;
      }
      if (md5 != null && md5.isNotEmpty) {
        queryParameters['md5'] = md5;
      }
      if (romSize != null && romSize > 0) {
        queryParameters['romtaille'] = romSize.toString();
      }

      final url = buildApiUrl('jeuInfos.php', queryParameters);

      final response = await ScreenscraperClient.httpGetWithRetry(
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
      } else if (response.statusCode == 404) {
        // ScreenScraper answers an unmatched ROM with 404 ("Rom/Iso/Dossier
        // non trouvee"), which is an ordinary outcome of a scrape sweep rather
        // than a fault. Logged at error it buried everything else: 478 of the
        // 575 error lines in one user's log were this one line repeating.
        _log.d('ScreenScraper has no entry for "$romName"');
        return null;
      } else {
        _log.e('HTTP Error ${response.statusCode}: ${response.body}');
        return null;
      }
    } on ScreenscraperQuotaExceededException {
      rethrow;
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
    final regionPriority = await ScreenscraperRegionConfig.getRegionPriority();
    final metadata = <String, dynamic>{};
    metadata['filename'] = filename;

    final noms = gameInfo['noms'] as List<dynamic>? ?? [];
    String? realName;
    int bestNamePriority = -1;
    for (final nom in noms) {
      final region = nom['region']?.toString();
      final text = nom['text']?.toString();
      if (text != null && text.isNotEmpty) {
        final priority = regionPriority[region] ?? 0;
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
          final priority = regionPriority[region] ?? 0;
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

      final allowedMediaTypes = await ScraperRepository.getEnabledMediaTypes();

      if (allowedMediaTypes.isEmpty) {
        return {'success': true, 'message': AppLocale.scrapeSuccessful};
      }

      final medias = gameInfo['medias'] as List<dynamic>? ?? [];
      final downloadResult =
          await ScreenscraperMediaDownloader.downloadGameMedia(
            systemFolder,
            romName,
            medias,
            1,
            appSystemId: appSystemId,
            preferredLanguage: preferredLanguage,
            allowedMediaTypes: allowedMediaTypes,
            forceOverwrite: forceOverwrite,
            maxDailyRequests: null,
            onProgress: (p) =>
                onProgress?.call(AppLocale.downloadingImages, 0.2 + (p * 0.8)),
          );

      return {
        'success': downloadResult['success'] == true,
        'message': downloadResult['success'] == true
            ? AppLocale.scrapeSuccessful
            : AppLocale.scrapeMediaDownloadsFailed,
      };
    } on ScreenscraperQuotaExceededException {
      return {'success': false, 'message': AppLocale.scrapeQuotaExceeded};
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

      ScreenscraperClient.initializeDailyCounter(0);
      final maxThreads = int.tryParse(credentials['maxthreads'] ?? '4') ?? 4;
      ScreenscraperClient.updateRequestSemaphore(maxThreads);

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
    } on ScreenscraperQuotaExceededException {
      _log.e('Daily scraping quota exceeded; stopping scraping session.');
      scrapingProvider.stopScraping();
      rethrow;
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

      // Use a hash when one is free — already cached, or a zipped ROM whose
      // crc32 the archive already stores. An exact dump match beats the
      // filename outright, surviving regional tags, revision markers and untidy
      // naming, and on a zipped library it costs a few hundred bytes.
      //
      // What it deliberately does NOT do is read every ROM up front. An
      // uncompressed 16 MB cartridge costs ~200ms to hash, and on a library
      // whose filenames are tidy that buys nothing the name would not have
      // found. Those are hashed further down, only once the name has missed.
      //
      // Android app entries have no ROM file to fingerprint.
      var fingerprint = systemFolder == 'android'
          ? null
          : await _resolveFingerprint(
              romPath,
              systemFolder,
              effort: FingerprintEffort.cheapOnly,
            );

      var gameResult = await fetchGameInfo(
        screenscraperSystemId.toString(),
        filename,
        appSystemId: appSystemId,
        md5: fingerprint?.md5,
        crc: fingerprint?.crc32,
        romSize: fingerprint?.sizeBytes,
        maxDailyRequests: maxDailyRequests,
        gameName: (systemFolder == 'android') ? titleName : null,
      );
      var gameInfo = gameResult?['gameInfo'];
      int requestsMade = 1;

      // A miss with a fingerprint on board is final: romnom rode along on that
      // request, and ScreenScraper falls back to the name server-side when the
      // hash is unknown to it (probed live: a junk crc next to a valid romnom
      // still matches). A name-only retry could never succeed where that
      // request failed, so none is sent.
      if (gameInfo == null &&
          systemFolder != 'android' &&
          fingerprint == null) {
        // The name missed and no cheap hash was available, so this is the ROM
        // that earns a full read: hashing is the only thing left to try, and
        // the result is cached so no later scrape repeats it.
        fingerprint = await _resolveFingerprint(
          romPath,
          systemFolder,
          effort: FingerprintEffort.full,
        );
        if (fingerprint != null) {
          gameResult = await fetchGameInfo(
            screenscraperSystemId.toString(),
            filename,
            appSystemId: appSystemId,
            md5: fingerprint.md5,
            crc: fingerprint.crc32,
            romSize: fingerprint.sizeBytes,
            maxDailyRequests: maxDailyRequests,
          );
          gameInfo = gameResult?['gameInfo'];
          requestsMade++;
        }
      }

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

        final allowedTypes = await ScraperRepository.getEnabledMediaTypes();

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
          final res = await ScreenscraperMediaDownloader.downloadGameMedia(
            systemFolder,
            filename,
            gameInfo['medias'] ?? [],
            maxThreads,
            appSystemId: appSystemId,
            preferredLanguage: preferredLanguage,
            shouldCancel: shouldCancel,
            allowedMediaTypes: allowedTypes,
            maxDailyRequests: maxDailyRequests,
            forceOverwrite: scraperConfig['scrape_mode'].toString() == 'all',
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
    } on ScreenscraperQuotaExceededException {
      rethrow;
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
      final userDataDir = await ScreenscraperMediaResolver.getMediaDirectory();
      const expectedTypes = [
        'fanarts',
        'screenshots',
        'wheels',
        'box2d',
        'videos',
      ];
      final romBaseName = await ScreenscraperRomHasher.getCleanRomName(
        romName,
        appSystemId,
      );
      final missing = <String>[];
      final existing = <String>[];

      for (final type in expectedTypes) {
        bool found = false;
        for (final ext in ['.png', '.jpg', '.jpeg', '.mp4', '.webm']) {
          if (await File(
            path.join(userDataDir, systemFolder, type, '$romBaseName$ext'),
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
      builder: (BuildContext context) => ScrapingSummaryDialog(
        totalGames: totalGames,
        successfulGames: successfulGames,
        failedGames: failedGames,
        elapsedTime: elapsedTime,
      ),
    );
  }
}
