import 'dart:convert';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path/path.dart' as path;
import 'config_service.dart';
import 'logger_service.dart';
import '../data/datasources/sqlite_service.dart';

const _manifestUrl =
    'https://raw.githubusercontent.com/miguelsotobaez/neostation-systems/main/manifest.json';
const _baseRawUrl =
    'https://raw.githubusercontent.com/miguelsotobaez/neostation-systems/main/systems';
const _githubApiUrl =
    'https://api.github.com/repos/miguelsotobaez/neostation-systems/contents/systems';

final _log = LoggerService.instance;

/// Result returned when a systems update is detected and applied.
class SystemsUpdateResult {
  final String newVersion;
  final int filesUpdated;
  const SystemsUpdateResult({
    required this.newVersion,
    required this.filesUpdated,
  });
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
/// neostation-systems GitHub repository.
///
/// On startup, it compares the remote manifest version against the locally
/// stored version. If a newer version is available, it downloads all system
/// JSON files into the user data directory so LauncherService can use them.
/// When no internet is available the bundled assets are used as-is.
class SystemsUpdateService {
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
  static Future<SystemsUpdateResult?> checkAndUpdate({
    void Function(double progress, String status)? onProgress,
  }) async {
    try {
      // 1. Fetch manifest — failure here means no internet, bail silently.
      final manifest = await _fetchManifest();
      if (manifest == null) return null;

      if (!await _appMeetsManifestMinimum(manifest)) return null;

      final remoteVersion = manifest['latest_version']?.toString() ?? '';
      if (remoteVersion.isEmpty) return null;

      // 2. Compare with locally stored version.
      final localVersion = await SqliteService.getSystemsVersion();
      if (_meetsMinimumVersion(localVersion, remoteVersion)) return null;

      _log.i(
        'SystemsUpdateService: new version $remoteVersion (local: $localVersion)',
      );

      // 3. Get the full list of system files from the GitHub repo directory.
      final systemIds = await _fetchSystemListFromApi();
      if (systemIds.isEmpty) return null;

      // 4. Download each file to the local cache.
      final cacheDir = await _getSystemsCachePath();
      var downloaded = 0;
      final total = systemIds.length;

      for (int i = 0; i < total; i++) {
        final id = systemIds[i];
        final fileName = '$id.json';
        final url = '$_baseRawUrl/$fileName';
        try {
          final response = await http.get(Uri.parse(url));
          if (response.statusCode == 200) {
            final file = File(path.join(cacheDir, fileName));
            await file.writeAsString(response.body, flush: true);
            downloaded++;
          } else {
            _log.w(
              'SystemsUpdateService: failed to download $fileName (${response.statusCode})',
            );
          }
        } catch (e) {
          _log.w('SystemsUpdateService: error downloading $fileName: $e');
        }
        onProgress?.call(
          (i + 1) / total,
          'Downloading systems (${i + 1}/$total)...',
        );
      }

      if (downloaded == 0) return null;

      // 5. Persist new version.
      await SqliteService.updateSystemsVersion(remoteVersion);
      _log.i(
        'SystemsUpdateService: updated $downloaded files to v$remoteVersion',
      );
      return SystemsUpdateResult(
        newVersion: remoteVersion,
        filesUpdated: downloaded,
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
      if (response.statusCode != 200) return [];
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
