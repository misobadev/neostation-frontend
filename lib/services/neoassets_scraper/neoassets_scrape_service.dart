import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as path;

import '../../constants/system_folder_names.dart';
import '../../l10n/app_locale.dart';
import '../../models/neoassets_scrape_models.dart';
import '../../models/rom_fingerprint.dart';
import '../../providers/scraping_provider.dart';
import '../../repositories/neoassets_account_repository.dart';
import '../../repositories/game_library_repository.dart';
import '../../repositories/neoassets_settings_repository.dart';
import '../../utils/atomic_file_writer.dart';
import '../../utils/regional_name.dart';
import '../logger_service.dart';
import '../rom_fingerprint_resolver.dart';
import '../rom_fingerprint_service.dart';
import '../scraping/scraped_media_paths.dart';
import 'neoassets_scrape_client.dart';
import 'neoassets_system_map.dart';

/// What a NeoAssets session did, for the summary shown when it ends.
class NeoAssetsSessionResult {
  final int total;
  final int succeeded;
  final int failed;
  final bool cancelled;
  final Duration elapsed;

  /// Set when the session stopped early because NeoAssets refused to go on
  /// (quota used up, key revoked).
  final NeoAssetsScrapeException? stoppedBy;

  const NeoAssetsSessionResult({
    required this.total,
    required this.succeeded,
    required this.failed,
    required this.cancelled,
    required this.elapsed,
    this.stoppedBy,
  });
}

/// Outcome of scraping one ROM.
enum _RomOutcome { scraped, notFound, mediaFailed }

/// The NeoAssets metadata provider: signs the user in with their personal
/// API key, and scrapes the library into the same metadata table and media
/// folders the game lists read, so switching provider keeps everything
/// already scraped.
///
/// Matching is hash first (a cached fingerprint or a zip's stored crc32 come
/// for free), then by file name, which the server cleans of extension and
/// region/revision tags itself; a ROM the name misses gets a full read only
/// then.
class NeoAssetsScrapeService {
  NeoAssetsScrapeService._();

  static final _log = LoggerService.instance;

  static final http.Client _http = http.Client();
  static bool _sessionRunning = false;

  /// Description columns the metadata table has (one per NeoStation UI
  /// language; Traditional Chinese reads `zh`).
  static const List<String> descriptionLanguages = [
    'en',
    'es',
    'fr',
    'de',
    'it',
    'pt',
    'ja',
    'ko',
    'ru',
    'zh',
    'id',
  ];

  /// NeoStation media type → NeoAssets media kinds, best first.
  static const Map<String, List<String>> _mediaKinds = {
    'box2D': ['cover', 'boxfront'],
    'ss': ['screenshot'],
    'wheel': ['logo'],
    'fanart': ['fanart'],
    'video': ['video'],
  };

  static const List<String> _imageExtensions = ['png', 'jpg', 'jpeg', 'webp'];
  static const List<String> _videoExtensions = ['mp4', 'webm'];

  /// Most workers a session runs at once: NeoAssets' top rank (and admins)
  /// get 20 threads.
  static const int maxWorkers = 20;

  // ==========================================
  // ACCOUNT
  // ==========================================

  static bool get isAvailable => NeoAssetsScrapeClient.isConfigured;

  /// Signed in with a personal key, or scraping as a guest.
  static Future<bool> isSignedIn() => NeoAssetsAccountRepository.hasSession();

  static Future<bool> isGuest() => NeoAssetsAccountRepository.isGuest();

  /// Scrapes with the app's own credentials and no personal key: one thread
  /// and the guest quota, which NeoAssets counts per network address. Throws
  /// [NeoAssetsScrapeException] when NeoAssets refuses.
  static Future<NeoAssetsAccount> signInAsGuest() async {
    final account = await NeoAssetsScrapeClient.fetchAccount(null);
    await NeoAssetsAccountRepository.saveGuest(account);
    return account;
  }

  /// The key requests send: the personal key, or null for a guest. Throws
  /// when there is no session, or the stored key cannot be read.
  static Future<String?> _sessionKey() async {
    final key = await NeoAssetsAccountRepository.getApiKey();
    if (key != null || await isGuest()) return key;
    throw const NeoAssetsScrapeException(NeoAssetsScrapeFailure.invalidKey);
  }

  /// Checks [apiKey] with NeoAssets and stores it when it belongs to a user.
  /// Throws [NeoAssetsScrapeException] when it is refused.
  static Future<NeoAssetsAccount> signIn(String apiKey) async {
    final key = apiKey.trim();
    final account = await NeoAssetsScrapeClient.fetchAccount(key);
    if (!account.isUser) {
      throw const NeoAssetsScrapeException(NeoAssetsScrapeFailure.invalidKey);
    }
    final saved = await NeoAssetsAccountRepository.saveApiKey(key, account);
    if (!saved) {
      throw const NeoAssetsScrapeException(NeoAssetsScrapeFailure.unknown);
    }
    return account;
  }

  static Future<void> signOut() => NeoAssetsAccountRepository.clear();

  /// The last account snapshot, without asking NeoAssets.
  static Future<NeoAssetsAccount?> cachedAccount() =>
      NeoAssetsAccountRepository.getAccount();

  /// Workers a session runs for [account].
  static int workersFor(NeoAssetsAccount? account) =>
      (account?.threads ?? 1).clamp(1, maxWorkers);

  /// The stored account snapshot, refreshed from NeoAssets when reachable.
  static Future<NeoAssetsAccount?> refreshAccount() async {
    if (!await isSignedIn()) return null;
    try {
      final account = await NeoAssetsScrapeClient.fetchAccount(
        await _sessionKey(),
      );
      await NeoAssetsAccountRepository.saveAccount(account);
      return account;
    } on NeoAssetsScrapeException catch (e) {
      _log.w('Could not refresh the NeoAssets account: $e');
      return NeoAssetsAccountRepository.getAccount();
    }
  }

  // ==========================================
  // SYSTEMS
  // ==========================================

  /// Detected systems NeoAssets has a catalog for, ordered by name.
  static Future<List<Map<String, dynamic>>> getSystems() async {
    final systems = await GameLibraryRepository.getDetectedSystems();
    return systems
        .where((s) => NeoAssetsSystemMap.supports(s['id'].toString()))
        .toList();
  }

  /// Enabled state per system; a system with no saved choice is enabled.
  static Future<Map<String, bool>> getEnabledSystems(
    List<Map<String, dynamic>> systems,
  ) async {
    final saved = await NeoAssetsSettingsRepository.getSystems();
    return {
      for (final s in systems)
        s['id'].toString(): saved[s['id'].toString()] ?? true,
    };
  }

  // ==========================================
  // SESSION
  // ==========================================

  /// Scrapes every enabled system's ROMs that [scrape mode] still has to do.
  ///
  /// Runs as many workers as the account has threads, reporting each one to
  /// [progress]. Returns null when a session is already running.
  static Future<NeoAssetsSessionResult?> runSession(
    ScrapingProvider progress, {
    required bool Function() shouldCancel,
  }) async {
    if (_sessionRunning) return null;
    _sessionRunning = true;
    final started = DateTime.now();
    var succeeded = 0;
    var failed = 0;
    var total = 0;
    NeoAssetsScrapeException? stoppedBy;

    try {
      final apiKey = await _sessionKey();
      final account = await refreshAccount();
      final workers = workersFor(account);

      final scrapeMode = await NeoAssetsSettingsRepository.getScrapeMode();
      final mediaTypes = await NeoAssetsSettingsRepository.getMediaTypes();
      final language = await GameLibraryRepository.getAppLanguage();

      // With streaming off, a game scraped while it was on still has only its
      // link: its video is fetched from there, with no lookup.
      final fetchStreamedVideos =
          mediaTypes.contains('video') &&
          !await NeoAssetsSettingsRepository.getStreamVideo();

      final systems = await getSystems();
      final enabled = await getEnabledSystems(systems);
      final queue = <_RomJob>[];
      for (final system in systems) {
        final id = system['id'].toString();
        if (enabled[id] != true) continue;
        final selector = NeoAssetsSystemMap.selectorFor(id)!;
        final roms = await GameLibraryRepository.getRomsForScraping(
          id,
          scrapeMode,
          mediaWanted: mediaTypes.isNotEmpty,
        );
        for (final rom in roms) {
          queue.add(
            _RomJob(
              appSystemId: id,
              systemName: system['name'].toString(),
              systemFolder: system['folder_name'].toString(),
              selector: selector,
              filename: rom['filename'].toString(),
              romPath: rom['rom_path']?.toString() ?? '',
            ),
          );
        }
        if (fetchStreamedVideos) {
          final queued = {for (final rom in roms) rom['filename'].toString()};
          final systemFolder = system['folder_name'].toString();
          for (final link in await streamedVideosToFetch(id, systemFolder)) {
            if (queued.contains(link.filename)) continue;
            queue.add(
              _RomJob(
                appSystemId: id,
                systemName: system['name'].toString(),
                systemFolder: systemFolder,
                selector: selector,
                filename: link.filename,
                romPath: '',
                videoUrl: link.url,
              ),
            );
          }
        }
      }

      total = queue.length;
      progress.updateProgress(
        totalGames: total,
        processedGames: 0,
        successfulGames: 0,
        failedGames: 0,
        // 0 tells the panel there is no daily cap to count against.
        maxDailyRequests: account == null || account.hasNoDailyLimit
            ? 0
            : account.dailyLimit,
        totalRequests: account?.used,
      );
      if (queue.isEmpty) {
        return NeoAssetsSessionResult(
          total: 0,
          succeeded: 0,
          failed: 0,
          cancelled: false,
          elapsed: DateTime.now().difference(started),
        );
      }

      var next = 0;
      var processed = 0;
      var requests = account?.used ?? 0;

      Future<void> worker(int threadId) async {
        while (true) {
          if (shouldCancel() || stoppedBy != null) return;
          if (next >= queue.length) return;
          final job = queue[next++];
          progress.updateThreadProgress(
            threadId: threadId,
            gameName: job.filename,
            systemName: job.systemName,
            isActive: true,
            status: ThreadStatus.active,
            currentStep: ThreadProcessingStep.fetchingMetadata,
            progress: 0,
          );
          try {
            final outcome = job.videoUrl != null
                ? await _fetchStreamedVideo(job)
                : await _scrapeRom(
                    job,
                    apiKey: apiKey,
                    newOnly: scrapeMode == 'new_only',
                    mediaTypes: mediaTypes,
                    language: language,
                    onRequest: () => requests++,
                    onStep: (step, value) => progress.updateThreadProgress(
                      threadId: threadId,
                      currentStep: step,
                      progress: value,
                    ),
                  );
            if (outcome == _RomOutcome.scraped) {
              succeeded++;
            } else {
              failed++;
            }
          } on NeoAssetsScrapeException catch (e) {
            if (e.stopsSession) {
              stoppedBy ??= e;
              return;
            }
            failed++;
          } catch (e) {
            _log.w('NeoAssets scrape of ${job.filename} failed: $e');
            failed++;
          }
          processed++;
          progress.markThreadIdle(threadId);
          progress.updateProgress(
            totalGames: total,
            processedGames: processed,
            successfulGames: succeeded,
            failedGames: failed,
            totalRequests: requests,
          );
        }
      }

      await Future.wait([
        for (var i = 1; i <= workers.clamp(1, queue.length); i++) worker(i),
      ]);

      // Fresh quota for the account card.
      await refreshAccount();

      return NeoAssetsSessionResult(
        total: total,
        succeeded: succeeded,
        failed: failed,
        cancelled: shouldCancel(),
        elapsed: DateTime.now().difference(started),
        stoppedBy: stoppedBy,
      );
    } on NeoAssetsScrapeException catch (e) {
      return NeoAssetsSessionResult(
        total: total,
        succeeded: succeeded,
        failed: failed,
        cancelled: false,
        elapsed: DateTime.now().difference(started),
        stoppedBy: e,
      );
    } finally {
      _sessionRunning = false;
    }
  }

  // ==========================================
  // SINGLE GAME
  // ==========================================

  /// Scrapes one game from its details or the game list, with the same
  /// result shape as the other providers' single-game scrape.
  static Future<Map<String, dynamic>> scrapeSingleGame({
    required String appSystemId,
    required String romName,
    required String systemFolder,
    required String romPath,
    Function(String status, double progress)? onProgress,
    bool forceOverwrite = false,
  }) async {
    final rowSystemId = SystemFolderNames.rowSystemFolder(appSystemId);
    try {
      onProgress?.call(AppLocale.checkingCredentials, 0.05);
      if (!await isSignedIn()) {
        return {'success': false, 'message': AppLocale.neoAssetsNoCredentials};
      }
      final apiKey = await _sessionKey();
      final selector = NeoAssetsSystemMap.selectorFor(rowSystemId);
      if (selector == null) {
        return {
          'success': false,
          'message': AppLocale.neoAssetsSystemNotMapped,
        };
      }
      final outcome = await _scrapeRom(
        _RomJob(
          appSystemId: rowSystemId,
          systemName: '',
          systemFolder: systemFolder,
          selector: selector,
          filename: romName,
          romPath: romPath,
        ),
        apiKey: apiKey,
        newOnly: !forceOverwrite,
        mediaTypes: await NeoAssetsSettingsRepository.getMediaTypes(),
        language: await GameLibraryRepository.getAppLanguage(),
        onStep: (step, value) => onProgress?.call(
          step == ThreadProcessingStep.fetchingMetadata
              ? AppLocale.fetchingMetadata
              : AppLocale.downloadingImages,
          value,
        ),
      );
      return switch (outcome) {
        _RomOutcome.scraped => {
          'success': true,
          'message': AppLocale.scrapeSuccessful,
        },
        _RomOutcome.notFound => {
          'success': false,
          'message': AppLocale.neoAssetsGameNotFound,
        },
        _RomOutcome.mediaFailed => {
          'success': false,
          'message': AppLocale.scrapeMediaDownloadsFailed,
        },
      };
    } on NeoAssetsScrapeException catch (e) {
      return {
        'success': false,
        'message': e.failure == NeoAssetsScrapeFailure.quotaExceeded
            ? AppLocale.neoAssetsQuotaExceeded
            : AppLocale.scrapeUnexpectedError,
      };
    } catch (e) {
      _log.e('NeoAssets single-game scrape failed: $e');
      return {'success': false, 'message': AppLocale.scrapeUnexpectedError};
    }
  }

  // ==========================================
  // ONE ROM
  // ==========================================

  static Future<_RomOutcome> _scrapeRom(
    _RomJob job, {
    required String? apiKey,
    required bool newOnly,
    required List<String> mediaTypes,
    required String language,
    void Function()? onRequest,
    void Function(ThreadProcessingStep step, double progress)? onStep,
  }) async {
    final isApp = SystemFolderNames.isAndroidApps(job.systemFolder);
    RomFingerprint? fingerprint = isApp || job.romPath.isEmpty
        ? null
        : await RomFingerprintResolver.resolve(
            job.romPath,
            job.systemFolder,
            effort: FingerprintEffort.cheapOnly,
          );

    onStep?.call(ThreadProcessingStep.fetchingMetadata, 0.1);
    onRequest?.call();
    var game = await NeoAssetsScrapeClient.lookupGame(
      selector: job.selector,
      apiKey: apiKey,
      name: job.filename,
      crc: fingerprint?.crc32,
      md5: fingerprint?.md5,
    );

    // The name rode along on that request and the server falls back to it
    // when no hash matches, so only a ROM that had no hash yet is worth a
    // full read and a second request.
    if (game == null &&
        fingerprint == null &&
        !isApp &&
        job.romPath.isNotEmpty) {
      fingerprint = await RomFingerprintResolver.resolve(
        job.romPath,
        job.systemFolder,
        effort: FingerprintEffort.full,
      );
      if (fingerprint != null) {
        onRequest?.call();
        game = await NeoAssetsScrapeClient.lookupGame(
          selector: job.selector,
          apiKey: apiKey,
          crc: fingerprint.crc32,
          md5: fingerprint.md5,
        );
      }
    }
    if (game == null) return _RomOutcome.notFound;

    onStep?.call(ThreadProcessingStep.scanningImages, 0.35);
    final metadata = metadataFor(job.filename, game, language: language);
    final regions = RegionalName.regionsFor(language);
    // Streaming keeps the video's link and leaves the file on NeoAssets.
    final streamVideo =
        mediaTypes.contains('video') &&
        await NeoAssetsSettingsRepository.getStreamVideo();
    if (mediaTypes.contains('video')) {
      final url = game.firstMedia('video', regions: regions)?.url;
      metadata['video_url'] = isStreamableUrl(url) ? url : null;
    }
    if (newOnly) {
      await GameLibraryRepository.fillGameMetadataGaps(
        metadata,
        job.appSystemId,
      );
    } else {
      await GameLibraryRepository.saveGameMetadata(
        metadata,
        job.appSystemId,
        isFullyScraped: false,
      );
    }

    if (mediaTypes.isEmpty) {
      await GameLibraryRepository.markGameFullyScraped(
        job.appSystemId,
        job.filename,
        metadataOnly: true,
      );
      return _RomOutcome.scraped;
    }

    onStep?.call(ThreadProcessingStep.downloadingImages, 0.5);
    final mediaOk = await _downloadMedia(
      job,
      game,
      streamVideo
          ? [
              for (final t in mediaTypes)
                if (t != 'video') t,
            ]
          : mediaTypes,
      regions,
      overwrite: !newOnly,
      onProgress: (p) =>
          onStep?.call(ThreadProcessingStep.downloadingImages, 0.5 + p * 0.5),
    );
    if (!mediaOk) return _RomOutcome.mediaFailed;
    await GameLibraryRepository.markGameFullyScraped(
      job.appSystemId,
      job.filename,
    );
    return _RomOutcome.scraped;
  }

  /// Whether [url] is a web address a video can stream from: anything else
  /// (a local path, another scheme) is never handed to the player.
  static bool isStreamableUrl(String? url) {
    if (url == null || url.isEmpty) return false;
    final uri = Uri.tryParse(url);
    return uri != null &&
        (uri.scheme == 'https' || uri.scheme == 'http') &&
        uri.host.isNotEmpty;
  }

  /// Maps a NeoAssets game to the game library's metadata columns.
  ///
  /// The title is the one of [language]'s release, and every regional title
  /// is kept so a later change of app language can retitle the game.
  static Map<String, dynamic> metadataFor(
    String filename,
    NeoAssetsGame game, {
    String language = 'en',
  }) {
    final title =
        RegionalName.pick(game.regionalNames, language) ??
        (game.name.isNotEmpty ? game.name : filename);
    final metadata = <String, dynamic>{
      'filename': filename,
      'real_name': title,
      'regional_names': game.regionalNames.isEmpty
          ? null
          : RegionalName.encode(game.regionalNames),
      'developer': game.developer,
      'publisher': game.publisher,
      'genre': game.genre,
    };
    for (final lang in descriptionLanguages) {
      final text = game.descriptions[lang];
      if (text != null) metadata['description_$lang'] = text;
    }
    // The library stores ratings on a 0..20 scale; NeoAssets rates 0..10.
    if (game.rating > 0) metadata['rating'] = (game.rating * 2).toDouble();
    final year = game.releaseYear;
    if (year != null && year > 0) {
      final month = (game.releaseMonth ?? 1).clamp(1, 12);
      metadata['release_date'] = DateTime(year, month).toIso8601String();
    }
    return metadata;
  }

  static Future<bool> _downloadMedia(
    _RomJob job,
    NeoAssetsGame game,
    List<String> mediaTypes,
    List<String> regions, {
    required bool overwrite,
    void Function(double progress)? onProgress,
  }) async {
    final mediaDir = await ScrapedMediaPaths.getMediaDirectory();
    final baseName = await ScrapedMediaPaths.artBaseName(
      job.filename,
      job.appSystemId,
    );
    final tasks = <({NeoAssetsMedia media, String folder})>[];
    for (final type in mediaTypes) {
      NeoAssetsMedia? media;
      for (final kind in _mediaKinds[type] ?? const <String>[]) {
        media = game.firstMedia(kind, regions: regions);
        if (media != null) break;
      }
      if (media == null) continue;
      tasks.add((media: media, folder: ScrapedMediaPaths.folderFor(type)));
    }
    if (tasks.isEmpty) return true;

    var done = 0;
    final results = await Future.wait(
      tasks.map((task) async {
        final ok = await _downloadOne(
          task.media,
          path.join(mediaDir, job.systemFolder, task.folder),
          baseName,
          overwrite: overwrite,
        );
        done++;
        onProgress?.call(done / tasks.length);
        return ok;
      }),
    );
    return results.every((ok) => ok);
  }

  /// The games on [appSystemId] whose video NeoAssets streams and that have
  /// no video file yet, for a session with streaming switched off.
  @visibleForTesting
  static Future<List<({String filename, String url})>> streamedVideosToFetch(
    String appSystemId,
    String systemFolder,
  ) async {
    final links = await GameLibraryRepository.getVideoLinks(appSystemId);
    if (links.isEmpty) return const [];
    final folder = path.join(
      await ScrapedMediaPaths.getMediaDirectory(),
      systemFolder,
      ScrapedMediaPaths.folderFor('video'),
    );
    final missing = <({String filename, String url})>[];
    for (final link in links) {
      if (!isStreamableUrl(link.url)) continue;
      final baseName = await ScrapedMediaPaths.artBaseName(
        link.filename,
        appSystemId,
      );
      var onDisk = false;
      for (final ext in _videoExtensions) {
        if (await File(path.join(folder, '$baseName.$ext')).exists()) {
          onDisk = true;
          break;
        }
      }
      if (!onDisk) missing.add(link);
    }
    return missing;
  }

  /// Downloads a streamed game's video from its saved link. No lookup, so it
  /// costs nothing against the account's rate or quota.
  static Future<_RomOutcome> _fetchStreamedVideo(_RomJob job) async {
    // The saved link carries no type; its extension must be a video's.
    final media = NeoAssetsMedia(kind: 'video', url: job.videoUrl!, mime: '');
    if (!_videoExtensions.contains(media.extension)) {
      return _RomOutcome.mediaFailed;
    }
    final ok = await _downloadOne(
      media,
      path.join(
        await ScrapedMediaPaths.getMediaDirectory(),
        job.systemFolder,
        ScrapedMediaPaths.folderFor('video'),
      ),
      await ScrapedMediaPaths.artBaseName(job.filename, job.appSystemId),
      overwrite: false,
    );
    return ok ? _RomOutcome.scraped : _RomOutcome.mediaFailed;
  }

  static final RegExp _safeExtension = RegExp(r'^[a-z0-9]{1,8}$');

  static Future<bool> _downloadOne(
    NeoAssetsMedia media,
    String folder,
    String baseName, {
    required bool overwrite,
  }) async {
    final ext = media.extension;
    if (!_safeExtension.hasMatch(ext)) return false;
    final siblings = media.kind == 'video'
        ? _videoExtensions
        : _imageExtensions;
    final existing = [
      for (final e in siblings) File(path.join(folder, '$baseName.$e')),
    ];
    if (!overwrite) {
      for (final file in existing) {
        if (await file.exists()) return true;
      }
    }
    try {
      final response = await _http
          .get(Uri.parse(media.url))
          .timeout(const Duration(seconds: 60));
      if (response.statusCode != 200 || response.bodyBytes.isEmpty) {
        _log.w('NeoAssets media ${response.statusCode}: ${media.url}');
        return false;
      }
      final target = File(path.join(folder, '$baseName.$ext'));
      await target.parent.create(recursive: true);
      await writeFileAtomically(target, response.bodyBytes);
      // Art is looked up png first, so a previous scrape's file in another
      // format would keep hiding the new one.
      for (final file in existing) {
        if (file.path != target.path && await file.exists()) {
          await file.delete();
        }
      }
      return true;
    } catch (e) {
      _log.w('NeoAssets media download failed: $e');
      return false;
    }
  }
}

class _RomJob {
  final String appSystemId;
  final String systemName;
  final String systemFolder;
  final NeoAssetsSystemSelector selector;
  final String filename;
  final String romPath;

  /// Set for a game whose video is only fetched from its saved link.
  final String? videoUrl;

  const _RomJob({
    required this.appSystemId,
    required this.systemName,
    required this.systemFolder,
    required this.selector,
    required this.filename,
    required this.romPath,
    this.videoUrl,
  });
}
