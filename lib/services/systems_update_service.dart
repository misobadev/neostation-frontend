import 'dart:convert';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path/path.dart' as path;
import 'config_service.dart';
import 'logger_service.dart';
import 'retroachievements_hash_service.dart';
import '../data/datasources/sqlite_service.dart';
import '../utils/bounded_concurrency.dart';

const _manifestUrl =
    'https://raw.githubusercontent.com/misobadev/neostation-frontend/main/assets/manifest.json';
const _baseRawUrl =
    'https://raw.githubusercontent.com/misobadev/neostation-frontend/main/assets/systems';
const _githubApiUrl =
    'https://api.github.com/repos/misobadev/neostation-frontend/contents/assets/systems';

final _log = LoggerService.instance;

/// Result returned when a systems update is detected and applied.
class SystemsUpdateResult {
  final String newVersion;
  final int filesUpdated;
  final int filesTotal;
  const SystemsUpdateResult({
    required this.newVersion,
    required this.filesUpdated,
    required this.filesTotal,
  });

  /// Whether every file in the set landed. A partial update applies the files
  /// it did get but deliberately leaves the stored version behind, so the next
  /// check retries — see `checkAndUpdate`.
  bool get isComplete => filesUpdated == filesTotal;
}

/// Info returned when a systems update is available but not yet downloaded.
class SystemsUpdateInfo {
  final String currentVersion;
  final String remoteVersion;
  const SystemsUpdateInfo({
    required this.currentVersion,
    required this.remoteVersion,
  });
}

/// Service that keeps the bundled system JSON configs up-to-date from the
/// main NeoStation frontend repository.
///
/// On startup, it compares the remote manifest version against the locally
/// stored version. If a newer version is available, it downloads all system
/// JSON files into the user data directory so LauncherService can use them.
/// When no internet is available the bundled assets are used as-is.
class SystemsUpdateService {
  /// Max system files fetched at once. The payload is tiny (~7 KB per file,
  /// ~865 KB for the full set) but each request costs a round trip, so the
  /// download is latency-bound and concurrency is what makes it fast.
  ///
  /// Measured against the live endpoint: serially the ~120 files cost ~196 ms
  /// each (~24 s total) on a wired connection, and well over a minute on
  /// handheld Wi-Fi. Pooled, the same set takes ~3 s cold and ~0.3 s warm.
  /// Raising the pool past 8 kept helping slightly (~176 ms warm at 16) but
  /// not enough to justify the extra sockets on a handheld's Wi-Fi stack, and
  /// 8 matches the pool NeoAssetsService already uses for theme assets.
  static const int _downloadConcurrency = 8;

  /// Per-file request timeout. Without one, a single stalled connection would
  /// hang the whole update with no way out.
  static const Duration _fileTimeout = Duration(seconds: 15);

  static Future<String> _getSystemsCachePath() async {
    final base = await ConfigService.getUserDataPath();
    final dir = Directory(path.join(base, 'systems'));
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir.path;
  }

  /// Returns the path to the local systems cache directory.
  static Future<String> getCacheDir() async => _getSystemsCachePath();

  /// Deletes all cached system JSON files so bundled assets take precedence.
  static Future<void> _clearSystemsCache() async {
    try {
      final cacheDir = Directory(await _getSystemsCachePath());
      if (!await cacheDir.exists()) return;
      await for (final entity in cacheDir.list()) {
        if (entity is File && entity.path.endsWith('.json')) {
          await entity.delete();
        }
      }
      RetroAchievementsHashService.clearPolicyCache();
      _log.i('SystemsUpdateService: cleared systems cache');
    } catch (e) {
      _log.w('SystemsUpdateService: failed to clear systems cache: $e');
    }
  }

  /// Returns the path to a cached system file, or null if not cached.
  static Future<String?> getCachedSystemPath(String jsonFileName) async {
    try {
      final cacheDir = await _getSystemsCachePath();
      final file = File(path.join(cacheDir, jsonFileName));
      if (await file.exists()) return file.path;
    } catch (_) {}
    return null;
  }

  /// Must be called on every app start. Ensures `systems_version` in SQLite
  /// always has a meaningful value so the About screen and any version
  /// checks have a baseline even without internet.
  ///
  /// Also detects Neostation app version changes: if the app was updated,
  /// resets `systems_version` so `checkAndUpdate` forces a re-download and
  /// `loadAndSyncSystems` re-applies all bundled/cached JSON definitions.
  static Future<void> initialize() async {
    // Step 1: always check bundled vs cached — independent of app version tracking.
    await _syncBundledVersion();

    // Step 2: track app version changes (best-effort).
    try {
      final packageInfo = await PackageInfo.fromPlatform();
      final currentAppVersion = packageInfo.version;
      final storedAppVersion = await SqliteService.getNeostationAppVersion();
      if (storedAppVersion != currentAppVersion) {
        _log.i(
          'SystemsUpdateService: app updated $storedAppVersion → $currentAppVersion',
        );
        await SqliteService.updateNeostationAppVersion(currentAppVersion);
      }
    } catch (e) {
      _log.w('SystemsUpdateService: failed to track app version: $e');
    }
  }

  /// Compares the bundled manifest version against the stored systems version.
  /// If bundled is newer, clears stale cache and advances the DB baseline so
  /// loadSystems() uses the newer bundled assets on next load.
  static Future<void> _syncBundledVersion() async {
    try {
      final bundledVersion = await _readBundledManifestVersion();
      final cachedVersion = await SqliteService.getSystemsVersion();

      _log.i(
        'SystemsUpdateService: bundled=$bundledVersion cached=$cachedVersion',
      );

      if (bundledVersion.isEmpty) return;

      if (cachedVersion.isEmpty) {
        await SqliteService.updateSystemsVersion(bundledVersion);
        _log.i(
          'SystemsUpdateService: initialized systems_version=$bundledVersion',
        );
        return;
      }

      if (!_meetsMinimumVersion(cachedVersion, bundledVersion)) {
        _log.i(
          'SystemsUpdateService: bundled v$bundledVersion > cached "$cachedVersion", clearing cache',
        );
        await _clearSystemsCache();
        await SqliteService.updateSystemsVersion(bundledVersion);
      }
    } catch (e) {
      _log.w('SystemsUpdateService: _syncBundledVersion error: $e');
    }
  }

  /// Whether the cached system definitions are from a *newer* generation than
  /// the ones bundled with this build.
  ///
  /// False on a tie, which is the steady state: after any systems update the
  /// cached version equals the version the next app release bundles, because
  /// the remote manifest is the bundled one. Callers use it to decide which
  /// copy of a field to believe when both exist.
  static Future<bool> cacheIsNewerThanBundle() async {
    try {
      final bundledVersion = await _readBundledManifestVersion();
      final cachedVersion = await SqliteService.getSystemsVersion();
      if (bundledVersion.isEmpty || cachedVersion.isEmpty) return false;
      if (cachedVersion == bundledVersion) return false;
      return _meetsMinimumVersion(cachedVersion, bundledVersion);
    } catch (e) {
      _log.w('SystemsUpdateService: cacheIsNewerThanBundle error: $e');
      return false;
    }
  }

  /// Reads the `latest_version` from the manifest bundled with this app build.
  static Future<String> _readBundledManifestVersion() async {
    try {
      final jsonString = await rootBundle.loadString('assets/manifest.json');
      final manifest = json.decode(jsonString) as Map<String, dynamic>;
      return manifest['latest_version']?.toString() ?? '';
    } catch (_) {
      return '';
    }
  }

  /// Checks the remote manifest and returns [SystemsUpdateInfo] if an update is
  /// available, without downloading anything.
  static Future<SystemsUpdateInfo?> checkForUpdate() async {
    try {
      final manifest = await _fetchManifest();
      if (manifest == null) return null;

      if (!await _appMeetsManifestMinimum(manifest)) return null;

      final remoteVersion = manifest['latest_version']?.toString() ?? '';
      if (remoteVersion.isEmpty) return null;

      final localVersion = await SqliteService.getSystemsVersion();
      if (_meetsMinimumVersion(localVersion, remoteVersion)) return null;

      return SystemsUpdateInfo(
        currentVersion: localVersion,
        remoteVersion: remoteVersion,
      );
    } catch (e) {
      _log.w('SystemsUpdateService: checkForUpdate error: $e');
      return null;
    }
  }

  /// Checks the remote manifest and downloads any updated system files.
  /// Returns a [SystemsUpdateResult] if files were updated, null otherwise.
  ///
  /// [onProgress] receives normalized progress (0.0–1.0) and a status string
  /// after each file is downloaded.
  ///
  /// [shouldCancel] is polled before each file; once it returns true the
  /// remaining downloads are skipped and null is returned. The stored version
  /// is left untouched so the next check retries the whole update.
  ///
  /// [knownUpdate] short-circuits the version check. Pass the result of an
  /// earlier [checkForUpdate] — as the update dialog does — to skip re-fetching
  /// the manifest and re-comparing versions that were just resolved.
  static Future<SystemsUpdateResult?> checkAndUpdate({
    SystemsUpdateInfo? knownUpdate,
    void Function(double progress, String status)? onProgress,
    bool Function()? shouldCancel,
  }) async {
    try {
      // 1. Resolve the target version, unless the caller already has it.
      final String remoteVersion;
      if (knownUpdate != null) {
        remoteVersion = knownUpdate.remoteVersion;
        _log.i(
          'SystemsUpdateService: new version $remoteVersion '
          '(local: ${knownUpdate.currentVersion})',
        );
      } else {
        // Fetching the manifest here doubles as the connectivity check —
        // failure means no internet, so bail silently.
        final manifest = await _fetchManifest();
        if (manifest == null) return null;

        if (!await _appMeetsManifestMinimum(manifest)) return null;

        final version = manifest['latest_version']?.toString() ?? '';
        if (version.isEmpty) return null;

        // 2. Compare with locally stored version.
        final localVersion = await SqliteService.getSystemsVersion();
        if (_meetsMinimumVersion(localVersion, version)) return null;

        remoteVersion = version;
        _log.i(
          'SystemsUpdateService: new version $remoteVersion (local: $localVersion)',
        );
      }

      // 3. Get the full list of system files from the GitHub repo directory,
      // falling back to the manifest's list when the API refuses us.
      var systemIds = await _fetchSystemListFromApi();
      if (systemIds.isEmpty) systemIds = await _fetchSystemListFromManifest();
      if (systemIds.isEmpty) {
        _log.w('SystemsUpdateService: no system list available, aborting');
        return null;
      }

      // 4. Download each file to the local cache.
      final cacheDir = await _getSystemsCachePath();
      final total = systemIds.length;
      var downloaded = 0;
      var completed = 0;

      // One client for the whole batch: the top-level `http.get` helper builds
      // and closes a Client per call, so it can never reuse a connection and
      // every file pays a fresh TCP + TLS handshake.
      final client = http.Client();
      try {
        await runBounded<String>(
          systemIds,
          _downloadConcurrency,
          (id) async {
            if (shouldCancel?.call() ?? false) return;
            final fileName = '$id.json';
            final url = '$_baseRawUrl/$fileName';
            final response = await client
                .get(Uri.parse(url))
                .timeout(_fileTimeout);
            if (response.statusCode == 200) {
              final file = File(path.join(cacheDir, fileName));
              await file.writeAsString(response.body, flush: true);
              downloaded++;
            } else {
              _log.w(
                'SystemsUpdateService: failed to download $fileName (${response.statusCode})',
              );
            }
          },
          onEach: () {
            completed++;
            onProgress?.call(
              completed / total,
              'Downloading systems ($completed/$total)...',
            );
          },
          label: 'SystemsUpdateService: download',
        );
      } finally {
        client.close();
      }

      // Leave systems_version alone on cancel: the cache now holds a mix of
      // old and new definitions, and only an unchanged version makes the next
      // check re-download the full set.
      if (shouldCancel?.call() ?? false) {
        _log.i(
          'SystemsUpdateService: cancelled after $downloaded/$total files',
        );
        return null;
      }

      if (downloaded == 0) return null;

      // 5. Persist the new version — but only once every file actually landed.
      //
      // Advancing it on a partial download strands the files that failed: the
      // stored version would claim the set is current, so no later check would
      // ever consider them out of date and they would stay stale forever.
      // Leaving it means the next check retries the whole set instead. The
      // shortfall is logged rather than swallowed, so a file that fails
      // systematically (a genuine 404 in the repo listing, say) shows up as a
      // repeating warning instead of silently re-downloading forever.
      if (downloaded < total) {
        _log.w(
          'SystemsUpdateService: only $downloaded/$total files downloaded — '
          'leaving systems_version at "${await SqliteService.getSystemsVersion()}" '
          'so the next check retries the full set',
        );
      } else {
        await SqliteService.updateSystemsVersion(remoteVersion);
        // The downloaded definitions may reassign a system's RA hashing policy.
        RetroAchievementsHashService.clearPolicyCache();
        _log.i(
          'SystemsUpdateService: updated $downloaded files to v$remoteVersion',
        );
      }

      return SystemsUpdateResult(
        newVersion: remoteVersion,
        filesUpdated: downloaded,
        filesTotal: total,
      );
    } catch (e, st) {
      _log.e(
        'SystemsUpdateService: unexpected error',
        error: e,
        stackTrace: st,
      );
      return null;
    }
  }

  /// Resolves which system IDs to download — always queries GitHub API directly.
  static Future<List<String>> _fetchSystemListFromApi() async {
    try {
      final response = await http
          .get(Uri.parse(_githubApiUrl))
          .timeout(const Duration(seconds: 10));
      if (response.statusCode != 200) {
        // Unauthenticated GitHub API calls are capped at 60/hour per IP, so a
        // 403 here is usually a rate limit, not a missing repo.
        _log.w(
          'SystemsUpdateService: GitHub API returned ${response.statusCode}',
        );
        return [];
      }
      final entries = json.decode(response.body) as List<dynamic>;
      return entries
          .where((e) => e['name']?.toString().endsWith('.json') == true)
          .map((e) => (e['name'] as String).replaceAll('.json', ''))
          .toList();
    } catch (e) {
      _log.w('SystemsUpdateService: GitHub API error: $e');
      return [];
    }
  }

  /// Reads the system IDs listed in the remote manifest. raw.githubusercontent
  /// isn't subject to the API rate limit, so this still works when
  /// [_fetchSystemListFromApi] is refused.
  static Future<List<String>> _fetchSystemListFromManifest() async {
    final manifest = await _fetchManifest();
    final systems = manifest?['systems'];
    if (systems is! List) return [];
    return systems.map((e) => e.toString()).toList();
  }

  /// Returns false (and logs) if the manifest declares a minimum app version
  /// that the current build doesn't satisfy. Missing field → always passes.
  static Future<bool> _appMeetsManifestMinimum(
    Map<String, dynamic> manifest,
  ) async {
    final minimum = manifest['neostation_minimum_version']?.toString() ?? '';
    if (minimum.isEmpty) return true;
    final packageInfo = await PackageInfo.fromPlatform();
    final appVersion = packageInfo.version;
    if (_meetsMinimumVersion(appVersion, minimum)) return true;
    _log.i(
      'SystemsUpdateService: remote requires app >= $minimum, current $appVersion — skipping update',
    );
    return false;
  }

  /// Compares two semver-style "major.minor.patch" strings numerically.
  /// Returns true if [appVersion] >= [minimum].
  static bool _meetsMinimumVersion(String appVersion, String minimum) {
    List<int> parse(String v) =>
        v.split('.').map((s) => int.tryParse(s) ?? 0).toList();
    final a = parse(appVersion);
    final m = parse(minimum);
    final len = a.length > m.length ? a.length : m.length;
    for (var i = 0; i < len; i++) {
      final av = i < a.length ? a[i] : 0;
      final mv = i < m.length ? m[i] : 0;
      if (av != mv) return av > mv;
    }
    return true;
  }

  static Future<Map<String, dynamic>?> _fetchManifest() async {
    try {
      final bustUrl =
          '$_manifestUrl?t=${DateTime.now().millisecondsSinceEpoch}';
      final response = await http
          .get(
            Uri.parse(bustUrl),
            headers: {'Cache-Control': 'no-cache', 'Pragma': 'no-cache'},
          )
          .timeout(const Duration(seconds: 10));
      if (response.statusCode != 200) return null;
      return json.decode(response.body) as Map<String, dynamic>;
    } catch (_) {
      return null; // No internet or timeout — silent fallback to bundled assets.
    }
  }
}
