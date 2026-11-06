import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as path;
import '../repositories/system_repository.dart';
import '../repositories/scraper_repository.dart';
import 'package:neostation/services/config_service.dart';
import 'package:neostation/providers/sqlite_database_provider.dart';
import 'package:neostation/services/logger_service.dart';
import 'package:neostation/utils/atomic_file_writer.dart';

/// Service responsible for fetching metadata and media from the Steam Store API.
///
/// Integrates with the application's persistence layer to enrich Steam game entries
/// with descriptions, ratings, and localized media (fanarts, logos, screenshots).
class SteamScraperService {
  /// Base URL for the Steam Storefront API app details endpoint.
  static const String _steamApiUrl =
      'https://store.steampowered.com/api/appdetails';

  static final _log = LoggerService.instance;

  static http.Client? _httpClientOverride;

  /// Routes the Steam Store and image requests through [client] (a
  /// `MockClient`, typically); pass null to restore the default.
  @visibleForTesting
  static void debugUseHttpClient(http.Client? client) {
    _httpClientOverride = client;
  }

  /// How long a Store request may take, and an image download (the whole
  /// body, so longer). Without a limit a stalled request would keep its run,
  /// and so every later run, waiting.
  @visibleForTesting
  static Duration requestTimeout = const Duration(seconds: 20);
  @visibleForTesting
  static Duration imageTimeout = const Duration(seconds: 60);

  static Future<http.Response> _get(Uri url, Duration timeout) =>
      (_httpClientOverride?.get(url) ?? http.get(url)).timeout(timeout);

  /// The run in progress, if any; see [scrapeSteamGames].
  static Future<void>? _inFlight;

  /// Whether a run was asked for while one was in progress.
  static bool _rerun = false;

  /// The provider to refresh, kept from whichever caller passed one: launch
  /// passes it, a ROM scan can't, and a scan's run still refreshes the list.
  static SqliteDatabaseProvider? _provider;

  @visibleForTesting
  static void debugForgetProvider() => _provider = null;

  /// A batch scrape is running (see [scrapeSteamGames]).
  static bool get isRunning => _inFlight != null;

  /// Performs a batch scraping operation for all registered Steam games.
  ///
  /// Targets entries that have a valid Steam App ID but are missing localized
  /// metadata or physical media assets on disk.
  ///
  /// Launch and every ROM scan that reaches the Steam system call this without
  /// waiting, so calls overlap. One run goes at a time: a call made during a
  /// run gets one more run after it, which picks up games the scan added since
  /// the first run read its list, and returns when that run is done.
  static Future<void> scrapeSteamGames({SqliteDatabaseProvider? provider}) {
    if (provider != null) _provider = provider;
    final running = _inFlight;
    if (running != null) {
      _rerun = true;
      return running;
    }
    return _inFlight = _runUntilIdle().whenComplete(() => _inFlight = null);
  }

  static Future<void> _runUntilIdle() async {
    do {
      _rerun = false;
      await _scrapeOnce(provider: _provider);
    } while (_rerun);
  }

  static Future<void> _scrapeOnce({SqliteDatabaseProvider? provider}) async {
    try {
      // 1. Resolve the logical Steam system to obtain its internal ID.
      final steamSystem = await SystemRepository.getSystemByFolderName('steam');
      if (steamSystem?.id == null) return;

      // 2. Identify candidates for metadata enrichment.
      // We fetch games that possess a 'title_id' (Steam App ID) and verify their completion status.
      final allGames = await ScraperRepository.getSteamGamesWithScrapeStatus(
        steamSystem!.id!,
      );

      // 3. Resolve user language preferences for API localization.
      final lang = await _getPreferredLanguage();

      // 4. Sequential processing of game metadata.
      int scrapeCount = 0;
      for (final game in allGames) {
        final filename = game['filename'].toString();
        final romPath = game['rom_path'].toString();
        final appId = game['title_id'].toString();

        // The user picked this game's match through ScreenScraper; its metadata
        // and media are theirs, not ours to replace.
        if (game['ss_manual_game_id'] != null) continue;

        // Metadata is only written for a game that has none yet: an existing
        // row came from this scraper, ScreenScraper, an ES-DE import or the
        // user's own edits, and none of those is ours to replace. Otherwise
        // only missing art is fetched.
        final writeMetadata = game['metadata_filename'] == null;
        final missingMedia = await _missingMediaFolders('steam', filename);

        if (writeMetadata || missingMedia.isNotEmpty) {
          scrapeCount++;
          await _scrapeSingleGame(
            steamSystem.id!,
            filename,
            romPath,
            appId,
            lang,
            writeMetadata: writeMetadata,
            missingMedia: missingMedia,
          );

          // Trigger a reactive UI update if a state provider is attached.
          if (provider != null) {
            await provider.refreshSystem('steam');
          }
        }
      }

      if (scrapeCount > 0) {
        _log.i('SteamScraper: Processed $scrapeCount game entries.');
      } else {
        _log.i('SteamScraper: Local metadata and media library is up to date.');
      }
    } catch (e) {
      _log.e('SteamScraper: Critical failure during batch operation', error: e);
    }
  }

  /// Synchronizes metadata for a specific Steam application ID.
  ///
  /// Writes the metadata only when [writeMetadata] is set, and downloads only
  /// the media folders in [missingMedia].
  static Future<void> _scrapeSingleGame(
    String systemId,
    String filename,
    String romPath,
    String appId,
    String lang, {
    required bool writeMetadata,
    required Set<String> missingMedia,
  }) async {
    try {
      final url = Uri.parse('$_steamApiUrl?appids=$appId&l=$lang');
      final response = await _get(url, requestTimeout);

      if (response.statusCode != 200) {
        _log.e(
          'SteamScraper: API upstream error (Status: ${response.statusCode})',
        );
        return;
      }

      final data = json.decode(response.body);
      if (data[appId] == null || data[appId]['success'] != true) {
        _log.w('SteamScraper: No valid data payload for AppID $appId');
        return;
      }

      final gameData = data[appId]['data'];

      if (writeMetadata) {
        // Map Steam API response to application metadata schema.
        final metadata = <String, dynamic>{
          'app_system_id': systemId,
          'filename': filename,
          'real_name': gameData['name'] ?? filename,
          'developer': (gameData['developers'] as List?)?.first?.toString(),
          'publisher': (gameData['publishers'] as List?)?.first?.toString(),
          'rating':
              (gameData['metacritic']?['score'] as num? ?? 0) /
              5.0, // Normalize metacritic 0-100 to 0-20 (UI maps to 0-10 star scale).
          'release_date': gameData['release_date']?['date']?.toString(),
          'genre': (gameData['genres'] as List?)?.first?['description']
              ?.toString(),
          'is_fully_scraped': 1,
          'updated_at': DateTime.now().toIso8601String(),
        };

        // Localized description logic: persist in requested language with English fallback.
        final description = gameData['short_description']?.toString() ?? '';
        metadata['description_$lang'] = description;
        if (lang != 'en') {
          metadata['description_en'] = description;
        }

        // Upsert into the persistent storage.
        await ScraperRepository.upsertSteamMetadata(metadata);
      }

      // Trigger asynchronous media download.
      await _downloadMedia(gameData, 'steam', filename, appId, missingMedia);
    } catch (e) {
      _log.e('SteamScraper: Error processing AppID $appId', error: e);
    }
  }

  /// Orchestrates the download of media assets based on Steam API URLs.
  ///
  /// Only the folders in [missingMedia] are downloaded, so art another scraper
  /// saved in a different format is left as it is.
  static Future<void> _downloadMedia(
    Map<String, dynamic> gameData,
    String systemFolder,
    String filename,
    String appId,
    Set<String> missingMedia,
  ) async {
    final mediaDir = await ConfigService.getMediaPath();

    // Standardize filename by stripping extension for media filesystem matching.
    final String romBaseName = filename.contains('.')
        ? filename.substring(0, filename.lastIndexOf('.'))
        : filename;

    // Steam API Mapping to NeoStation Media Convention:
    // - Static URL based on AppID -> fanarts/ (Background art)
    // - Static URL based on AppID -> box2d/ (Box art)
    // - Static URL based on AppID -> wheels/ (Transparent Logo)
    // - screenshots[0] -> screenshots/ (In-game thumbnail)

    final fanartUrl =
        'https://shared.fastly.steamstatic.com/store_item_assets/steam/apps/$appId/library_hero.jpg';
    final box2dUrl =
        'https://shared.fastly.steamstatic.com/store_item_assets/steam/apps/$appId/library_600x900.jpg';
    final wheelUrl =
        'https://shared.fastly.steamstatic.com/store_item_assets/steam/apps/$appId/logo.png';
    final ssUrl = (gameData['screenshots'] as List?)?.first?['path_thumbnail']
        ?.toString();

    if (missingMedia.contains('fanarts')) {
      await _downloadFile(
        fanartUrl,
        path.join(mediaDir, systemFolder, 'fanarts', '$romBaseName.jpg'),
      );
    }

    if (missingMedia.contains('box2d')) {
      await _downloadFile(
        box2dUrl,
        path.join(mediaDir, systemFolder, 'box2d', '$romBaseName.jpg'),
      );
    }

    if (missingMedia.contains('wheels')) {
      await _downloadFile(
        wheelUrl,
        path.join(mediaDir, systemFolder, 'wheels', '$romBaseName.png'),
      );
    }

    if (!missingMedia.contains('screenshots')) return;
    if (ssUrl != null) {
      await _downloadFile(
        ssUrl,
        path.join(mediaDir, systemFolder, 'screenshots', '$romBaseName.jpg'),
      );
    } else {
      _log.w('SteamScraper: Screenshot URL missing for $romBaseName');
    }
  }

  /// Downloads a remote file to the local filesystem if it doesn't already exist.
  static Future<void> _downloadFile(String url, String savePath) async {
    try {
      final file = File(savePath);

      // Avoid redundant network requests if asset is already localized.
      if (await file.exists()) return;

      await file.parent.create(recursive: true);
      final response = await _get(Uri.parse(url), imageTimeout);

      if (response.statusCode == 200) {
        // A file left half-written would count as downloaded from then on.
        await writeFileAtomically(file, response.bodyBytes);
      }
    } catch (e) {
      _log.e('SteamScraper: Network failure downloading $url', error: e);
    }
  }

  /// The media folders the Steam scraper fills.
  static const _mediaFolders = ['fanarts', 'box2d', 'wheels', 'screenshots'];

  /// The image formats the library shows (`GameModel`), in any of which art
  /// counts as present, whichever scraper saved it.
  static const _mediaExtensions = ['png', 'jpg', 'webp'];

  /// The media folders that have no art for [filename] in any format.
  static Future<Set<String>> _missingMediaFolders(
    String systemFolder,
    String filename,
  ) async {
    final mediaDir = await ConfigService.getMediaPath();

    final String romBaseName = filename.contains('.')
        ? filename.substring(0, filename.lastIndexOf('.'))
        : filename;

    final missing = <String>{};
    for (final folder in _mediaFolders) {
      var found = false;
      for (final ext in _mediaExtensions) {
        final imagePath = path.join(
          mediaDir,
          systemFolder,
          folder,
          '$romBaseName.$ext',
        );
        if (await File(imagePath).exists()) {
          found = true;
          break;
        }
      }
      if (!found) {
        _log.d('SteamScraper: Missing required $folder asset for $romBaseName');
        missing.add(folder);
      }
    }
    return missing;
  }

  /// Retrieves the preferred language for scraper operations from local configuration.
  static Future<String> _getPreferredLanguage() async {
    return ScraperRepository.getPreferredLanguage();
  }
}
