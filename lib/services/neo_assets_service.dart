import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as path;
import 'config_service.dart';
import 'logger_service.dart';
import '../utils/app_config.dart';
import '../utils/bounded_concurrency.dart';

final _log = LoggerService.instance;

/// Outcome of a single remote asset fetch.
enum AssetFetchStatus {
  /// The file is on disk (freshly downloaded or already cached).
  cached,

  /// The server answered 404: the asset genuinely is not published.
  notFound,

  /// The asset could not be reached (timeout, socket error, 429, 5xx). Says
  /// nothing about whether it exists, so it must never be cached as absent.
  failed,
}

/// The status of an asset fetch plus the local path when it succeeded.
class AssetFetchResult {
  final AssetFetchStatus status;
  final String? path;

  const AssetFetchResult(this.status, [this.path]);

  /// Whether the asset is now available on disk.
  bool get isCached => status == AssetFetchStatus.cached;

  /// Whether the server positively reported the asset as absent.
  bool get isNotFound => status == AssetFetchStatus.notFound;
}

/// A system art pack as listed by the NeoAssets catalog (`GET /api/v1/packs`).
class NeoAssetsTheme {
  /// Display name of the pack.
  final String name;

  /// The unique folder identifier for the pack.
  final String folder;

  /// Who made the pack.
  final String author;

  /// Short description shown in the list.
  final String description;

  /// Donation/support URL (usually Ko-fi, sometimes another profile).
  final String donationUrl;

  /// The pack version string.
  final String version;

  /// The direct CDN URL to the pack's preview image.
  final String previewUrl;

  /// The first four background image URLs (CDN), used by the list mosaic.
  final List<String> backgrounds;

  /// How many times the pack has been downloaded.
  final int downloads;

  /// How many systems the pack ships art for.
  final int systemsCovered;

  /// Whether the pack art was generated using AI.
  final bool isAi;

  const NeoAssetsTheme({
    required this.name,
    required this.folder,
    required this.author,
    required this.description,
    required this.donationUrl,
    required this.version,
    required this.previewUrl,
    required this.backgrounds,
    required this.downloads,
    required this.systemsCovered,
    required this.isAi,
  });

  factory NeoAssetsTheme.fromJson(Map<String, dynamic> json) {
    return NeoAssetsTheme(
      name: json['name']?.toString() ?? '',
      folder: json['folder']?.toString() ?? '',
      author: json['author']?.toString() ?? '',
      description: json['description']?.toString() ?? '',
      donationUrl: json['donation_url']?.toString().trim() ?? '',
      version: json['version']?.toString() ?? '',
      previewUrl: normalizePreviewUrl(json['preview']?.toString() ?? ''),
      backgrounds: (json['backgrounds'] as List? ?? [])
          .map((e) => normalizePreviewUrl(e.toString()))
          .where((url) => url.isNotEmpty)
          .toList(),
      downloads: _parseInt(json['downloads']),
      systemsCovered: _parseInt(json['systems_covered']),
      isAi: _parseAi(json['ai']),
    );
  }

  NeoAssetsTheme copyWith({
    String? name,
    String? folder,
    String? author,
    String? description,
    String? donationUrl,
    String? version,
    String? previewUrl,
    List<String>? backgrounds,
    int? downloads,
    int? systemsCovered,
    bool? isAi,
  }) {
    return NeoAssetsTheme(
      name: name ?? this.name,
      folder: folder ?? this.folder,
      author: author ?? this.author,
      description: description ?? this.description,
      donationUrl: donationUrl ?? this.donationUrl,
      version: version ?? this.version,
      previewUrl: previewUrl ?? this.previewUrl,
      backgrounds: backgrounds ?? this.backgrounds,
      downloads: downloads ?? this.downloads,
      systemsCovered: systemsCovered ?? this.systemsCovered,
      isAi: isAi ?? this.isAi,
    );
  }

  /// The images shown in the list mosaic: the preview plus the first three
  /// backgrounds, de-duplicated and capped at four.
  List<String> get mosaicImages {
    final images = <String>[];
    if (previewUrl.isNotEmpty) images.add(previewUrl);
    for (final background in backgrounds) {
      if (images.length >= 4) break;
      if (!images.contains(background)) images.add(background);
    }
    return images.take(4).toList();
  }

  static int _parseInt(dynamic value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    return int.tryParse(value?.toString() ?? '') ?? 0;
  }

  /// Parses various dynamic types into a boolean flag for AI attribution.
  static bool _parseAi(dynamic value) {
    if (value is bool) return value;
    if (value is num) return value != 0;
    if (value is String) {
      final normalized = value.trim().toLowerCase();
      return normalized == 'true' || normalized == '1' || normalized == 'yes';
    }
    return false;
  }

  /// Resolves a raw pack image path into an absolute CDN URL.
  ///
  /// The catalog returns relative object keys (`packs/<folder>/backgrounds/x.webp`)
  /// while the download endpoint returns absolute URLs; both are accepted.
  static String normalizePreviewUrl(String value) {
    final raw = value.trim();
    if (raw.isEmpty) return '';

    final uri = Uri.tryParse(raw);
    if (uri != null && uri.hasScheme) return raw;

    final normalized = raw.startsWith('/') ? raw.substring(1) : raw;
    return '${AppConfig.neoAssetsCdnBaseUrl}/$normalized';
  }
}

/// One file inside a system art pack, as returned by
/// `GET /api/v1/packs/{folder}/download`.
class NeoAssetsPackFile {
  /// `background`, `preview`, ... (currently every file is a background).
  final String kind;

  /// The system folder name the file belongs to (matches NeoStation's
  /// `folder_name`, e.g. `neogeo`, `gb`, `snes`).
  final String systemId;

  /// The on-disk file name, e.g. `neogeo.webp`.
  final String fileName;

  /// Absolute CDN URL to download the file from.
  final String url;

  /// File size in bytes.
  final int size;

  /// MIME type, e.g. `image/webp`.
  final String mime;

  const NeoAssetsPackFile({
    required this.kind,
    required this.systemId,
    required this.fileName,
    required this.url,
    required this.size,
    required this.mime,
  });

  factory NeoAssetsPackFile.fromJson(Map<String, dynamic> json) {
    return NeoAssetsPackFile(
      kind: json['kind']?.toString() ?? 'background',
      systemId: json['system_id']?.toString() ?? '',
      fileName: json['file_name']?.toString() ?? '',
      url: NeoAssetsTheme.normalizePreviewUrl(json['url']?.toString() ?? ''),
      size: json['size'] is num ? (json['size'] as num).toInt() : 0,
      mime: json['mime']?.toString() ?? '',
    );
  }

  /// Whether this file is a system background.
  bool get isBackground => kind == 'background';
}

/// A fully-resolved system art pack (metadata + files) ready to download.
class NeoAssetsPack {
  final String folder;
  final String name;
  final String author;
  final String description;
  final String donationUrl;
  final String version;
  final bool isAi;
  final int downloads;
  final int systemsCovered;
  final List<NeoAssetsPackFile> files;

  const NeoAssetsPack({
    required this.folder,
    required this.name,
    required this.author,
    required this.description,
    required this.donationUrl,
    required this.version,
    required this.isAi,
    required this.downloads,
    required this.systemsCovered,
    required this.files,
  });

  factory NeoAssetsPack.fromJson(Map<String, dynamic> json) {
    return NeoAssetsPack(
      folder: json['folder']?.toString() ?? '',
      name: json['name']?.toString() ?? '',
      author: json['author']?.toString() ?? '',
      description: json['description']?.toString() ?? '',
      donationUrl: json['donation_url']?.toString().trim() ?? '',
      version: json['version']?.toString() ?? '',
      isAi: NeoAssetsTheme._parseAi(json['ai']),
      downloads: NeoAssetsTheme._parseInt(json['downloads']),
      systemsCovered: NeoAssetsTheme._parseInt(json['systems_covered']),
      files: (json['files'] as List? ?? [])
          .whereType<Map>()
          .map((e) => NeoAssetsPackFile.fromJson(e.cast<String, dynamic>()))
          .where((f) => f.fileName.isNotEmpty && f.url.isNotEmpty)
          .toList(),
    );
  }

  /// The metadata persisted next to the downloaded files for offline reuse.
  Map<String, dynamic> toMetadataJson() {
    return {
      'folder': folder,
      'name': name,
      'author': author,
      'description': description,
      'donation_url': donationUrl,
      'version': version,
      'ai': isAi,
      'downloads': downloads,
      'systems_covered': systemsCovered,
    };
  }
}

/// Service responsible for fetching, downloading, and caching system art packs
/// from the public NeoAssets catalog (https://api.neoassets.dev).
class NeoAssetsService {
  static List<NeoAssetsTheme>? _cachedThemes;
  static String? _cachedThemeDir;

  /// HTTP client for every remote fetch. Swappable so tests can drive the
  /// 404-versus-transient-failure split without a network.
  static http.Client _client = http.Client();

  /// How long a single request may take before it is retried.
  static const Duration _requestTimeout = Duration(seconds: 20);

  /// Attempts per asset before giving up.
  static const int _maxFetchAttempts = 3;

  /// Base backoff between attempts, multiplied by the attempt number.
  static const Duration _retryBackoff = Duration(milliseconds: 500);

  /// Max file downloads in flight at once.
  static const int _downloadConcurrency = 8;

  /// The public catalog listing endpoint.
  static String get packsUrl => '${AppConfig.neoAssetsApiBaseUrl}/api/v1/packs';

  /// The public download endpoint for one pack (counts a download).
  static String packDownloadUrl(String folder) =>
      '${AppConfig.neoAssetsApiBaseUrl}/api/v1/packs/'
      '${Uri.encodeComponent(folder)}/download';

  /// Forgets the resolved theme-cache directory so the next call re-derives it
  /// from the current user-data path.
  ///
  /// [_cacheDir] memoises the path on first use, which is at app start — before
  /// the setup wizard's first step can move the user-data location. Without
  /// this, a wizard that relocates the user data downloads the art pack into
  /// the *old* folder while the database records the pack at the new one.
  static void resetCacheDir() {
    _cachedThemeDir = null;
  }

  /// Points the service at a stub client and a scratch cache directory.
  @visibleForTesting
  static void debugConfigure({http.Client? client, String? cacheDir}) {
    _client = client ?? http.Client();
    _cachedThemeDir = cacheDir;
    _cachedThemes = null;
  }

  /// Restores the real client and drops any test cache directory.
  @visibleForTesting
  static void debugReset() {
    _client = http.Client();
    _cachedThemeDir = null;
    _cachedThemes = null;
  }

  /// Fetches the catalog of available packs.
  ///
  /// Tries the remote catalog first (caching it to disk on success), then falls
  /// back to the last cached catalog when the network is unavailable. The
  /// result is floored with locally-downloaded packs so an already-applied pack
  /// stays visible and selectable even offline.
  ///
  /// [forceRefresh] bypasses the in-memory cache. It is used after applying a
  /// pack, because the server increments the pack's download count on the
  /// download request while its response still carries the previous value, so
  /// the only way to show the new count is to re-read the catalog.
  static Future<List<NeoAssetsTheme>> fetchThemes({
    bool forceRefresh = false,
  }) async {
    if (!forceRefresh && _cachedThemes != null) return _cachedThemes!;

    final remote = await _fetchRemoteThemes();
    if (remote != null) {
      final merged = await _mergeWithLocalThemes(remote);
      merged.sort(_byDownloadsThenName);
      _cachedThemes = merged;
      return merged;
    }

    // A refresh that could not reach the network keeps the last known list
    // rather than dropping it for the on-disk copy.
    if (forceRefresh && _cachedThemes != null) return _cachedThemes!;

    final fallback = await _mergeWithLocalThemes(await _readCachedManifest());
    if (fallback.isNotEmpty) {
      fallback.sort(_byDownloadsThenName);
      _log.i('Themes: offline fallback served ${fallback.length} pack(s)');
      _cachedThemes = fallback;
      return fallback;
    }
    return _cachedThemes ?? [];
  }

  /// Most-downloaded packs first, then alphabetical by name. Locally-downloaded
  /// packs that carry no download count sink to the bottom.
  static int _byDownloadsThenName(NeoAssetsTheme a, NeoAssetsTheme b) {
    final byDownloads = b.downloads.compareTo(a.downloads);
    if (byDownloads != 0) return byDownloads;
    return a.name.toLowerCase().compareTo(b.name.toLowerCase());
  }

  /// Fetches the remote pack catalog, persisting it to disk for offline reuse.
  /// Returns null on any failure so callers can fall back to the on-disk copy.
  static Future<List<NeoAssetsTheme>?> _fetchRemoteThemes() async {
    try {
      final response = await _client
          .get(Uri.parse(packsUrl))
          .timeout(_requestTimeout);
      if (response.statusCode != 200) {
        _log.w('Failed to fetch NeoAssets packs: ${response.statusCode}');
        return null;
      }
      final json = jsonDecode(response.body);
      if (json is! Map<String, dynamic>) return null;
      final themes = (json['themes'] as List? ?? [])
          .whereType<Map>()
          .map((e) => NeoAssetsTheme.fromJson(e.cast<String, dynamic>()))
          .where((t) => t.folder.isNotEmpty)
          .toList();
      // Persist with a source marker so a catalog left by the removed GitHub
      // theme system is never mistaken for this one.
      await _writeCachedManifest(
        jsonEncode({
          'source': _manifestSource,
          'themes': json['themes'],
          'total': json['total'],
        }),
      );
      return themes;
    } catch (e) {
      _log.e('Error fetching NeoAssets packs: $e');
      return null;
    }
  }

  /// Marker written into the cached catalog by this service.
  static const String _manifestSource = 'neoassets';

  /// On-disk path of the cached catalog.
  static Future<String> _manifestCachePath() async {
    return path.join(await _cacheDir(), 'manifest.json');
  }

  /// Persists the catalog JSON body to the cache directory.
  static Future<void> _writeCachedManifest(String body) async {
    try {
      final file = File(await _manifestCachePath());
      await file.parent.create(recursive: true);
      await file.writeAsString(body);
    } catch (e) {
      _log.w('Error caching manifest: $e');
    }
  }

  /// Reads the last successfully-fetched catalog from disk. Empty if none.
  ///
  /// A catalog written by the removed GitHub theme system has no `source`
  /// marker and is ignored outright.
  static Future<List<NeoAssetsTheme>> _readCachedManifest() async {
    try {
      final file = File(await _manifestCachePath());
      if (!await file.exists()) return [];
      final json = jsonDecode(await file.readAsString());
      if (json is! Map<String, dynamic>) return [];
      if (json['source'] != _manifestSource) return [];
      return (json['themes'] as List? ?? [])
          .whereType<Map>()
          .map((e) => NeoAssetsTheme.fromJson(e.cast<String, dynamic>()))
          .where((t) => t.folder.isNotEmpty)
          .toList();
    } catch (e) {
      _log.w('Error reading cached manifest: $e');
      return [];
    }
  }

  /// Builds pack entries from locally-downloaded folders (each carries a
  /// `pack.json`). Guarantees an applied pack appears even if it is absent from
  /// the cached catalog. Preview URLs are empty (previews are not cached), so
  /// tiles render a placeholder — the point is selectability.
  ///
  /// Only packs downloaded by this service are listed: the legacy `theme.json`
  /// folders left by the removed GitHub system are ignored.
  static Future<List<NeoAssetsTheme>> _localThemes() async {
    try {
      final dir = Directory(await _cacheDir());
      if (!await dir.exists()) return [];
      final result = <NeoAssetsTheme>[];
      await for (final entry in dir.list()) {
        if (entry is! Directory) continue;
        final folder = path.basename(entry.path);
        final metaFile = File(path.join(entry.path, 'pack.json'));
        if (!await metaFile.exists()) continue;
        try {
          final json = jsonDecode(await metaFile.readAsString());
          if (json is! Map<String, dynamic>) continue;
          final name = json['name']?.toString();
          result.add(
            NeoAssetsTheme(
              name: (name == null || name.isEmpty) ? folder : name,
              folder: folder,
              author: json['author']?.toString() ?? '',
              description: json['description']?.toString() ?? '',
              donationUrl: json['donation_url']?.toString().trim() ?? '',
              version: json['version']?.toString() ?? '',
              previewUrl: '',
              backgrounds: const [],
              downloads: NeoAssetsTheme._parseInt(json['downloads']),
              systemsCovered: NeoAssetsTheme._parseInt(json['systems_covered']),
              isAi: NeoAssetsTheme._parseAi(json['ai']),
            ),
          );
        } catch (_) {
          // Skip an unreadable metadata file rather than dropping the list.
        }
      }
      return result;
    } catch (e) {
      _log.w('Error enumerating local packs: $e');
      return [];
    }
  }

  /// Appends any locally-downloaded pack not already present in [base],
  /// matched case-insensitively by folder so a folder-casing difference can
  /// never produce a duplicate entry. The remote entry wins.
  static Future<List<NeoAssetsTheme>> _mergeWithLocalThemes(
    List<NeoAssetsTheme> base,
  ) async {
    final local = await _localThemes();
    if (local.isEmpty) return base;
    final seen = base.map((t) => t.folder.toLowerCase()).toSet();
    final merged = [...base];
    for (final t in local) {
      if (seen.add(t.folder.toLowerCase())) merged.add(t);
    }
    return merged;
  }

  /// Clears the in-memory pack list cache.
  static void clearCache() {
    _cachedThemes = null;
  }

  /// Downloads the full file list of a pack, including its metadata.
  ///
  /// Returns null when the pack is unreachable, so callers never apply a pack
  /// they have no art for.
  static Future<NeoAssetsPack?> fetchPack(String folder) async {
    try {
      final response = await _client
          .get(Uri.parse(packDownloadUrl(folder)))
          .timeout(_requestTimeout);
      if (response.statusCode != 200) {
        _log.w(
          'Failed to fetch NeoAssets pack "$folder": ${response.statusCode}',
        );
        return null;
      }
      final json = jsonDecode(response.body);
      if (json is! Map<String, dynamic>) return null;
      return NeoAssetsPack.fromJson(json);
    } catch (e) {
      _log.e('Error fetching NeoAssets pack "$folder": $e');
      return null;
    }
  }

  /// Downloads every file of [files] into the pack's cache folder.
  ///
  /// Backgrounds land under `<cache>/<folder>/backgrounds/<file_name>` so the
  /// existing background resolvers keep working; other kinds land at the pack
  /// root. Returns how many files were cached, so the caller can decide whether
  /// the pack is usable.
  static Future<int> downloadPack(
    String folder,
    List<NeoAssetsPackFile> files, {
    void Function(int done, int total)? onProgress,
  }) async {
    final total = files.length;
    int done = 0;
    int cached = 0;
    await runBounded<NeoAssetsPackFile>(
      files,
      _downloadConcurrency,
      (file) async {
        final localPath = await _fileCachePath(folder, file);
        final result = await fetchAndCacheAsset(file.url, localPath);
        if (result.isCached) cached++;
      },
      onEach: () => onProgress?.call(++done, total),
      label: 'NeoAssets pack download',
    );
    return cached;
  }

  /// The local cache path a pack file is written to.
  static Future<String> _fileCachePath(
    String folder,
    NeoAssetsPackFile file,
  ) async {
    final dir = await _cacheDir();
    if (file.isBackground) {
      return path.join(dir, folder, 'backgrounds', file.fileName);
    }
    return path.join(dir, folder, file.fileName);
  }

  /// Downloads a remote asset to the local filesystem.
  ///
  /// Distinguishes a definitive HTTP 404 ([AssetFetchStatus.notFound]) from an
  /// asset that could not be reached right now ([AssetFetchStatus.failed]:
  /// timeout, socket error, 429, 5xx). Bytes land in a sibling `.part` file
  /// that is renamed into place only once the body is fully written, so an
  /// interrupted write can never leave a truncated image that later reads as
  /// "already cached".
  static Future<AssetFetchResult> fetchAndCacheAsset(
    String url,
    String localPath,
  ) async {
    final file = File(localPath);
    try {
      if (await file.exists()) {
        return AssetFetchResult(AssetFetchStatus.cached, localPath);
      }
    } catch (e) {
      _log.w('Error checking cached asset $localPath: $e');
    }

    for (var attempt = 1; attempt <= _maxFetchAttempts; attempt++) {
      try {
        final response = await _client
            .get(Uri.parse(url))
            .timeout(_requestTimeout);

        if (response.statusCode == 200) {
          await file.parent.create(recursive: true);
          final part = File('$localPath.part');
          await part.writeAsBytes(response.bodyBytes, flush: true);
          await part.rename(localPath);
          return AssetFetchResult(AssetFetchStatus.cached, localPath);
        }

        if (response.statusCode == 404) {
          return const AssetFetchResult(AssetFetchStatus.notFound);
        }

        _log.w(
          'Asset fetch failed ($url): HTTP ${response.statusCode} '
          '(attempt $attempt/$_maxFetchAttempts)',
        );
      } catch (e) {
        _log.w(
          'Asset fetch errored ($url): $e (attempt $attempt/$_maxFetchAttempts)',
        );
      }

      if (attempt < _maxFetchAttempts) {
        await Future.delayed(_retryBackoff * attempt);
      }
    }

    return const AssetFetchResult(AssetFetchStatus.failed);
  }

  /// Returns the local directory used for pack asset caching.
  static Future<String> _cacheDir() async {
    if (_cachedThemeDir != null) return _cachedThemeDir!;
    final base = await ConfigService.getUserDataPath();
    _cachedThemeDir = path.join(base, 'themes');
    return _cachedThemeDir!;
  }

  /// Ensures the pack cache directory path is calculated and available.
  static Future<void> ensureCacheDirInitialized() async {
    await _cacheDir();
  }

  /// Synchronous variant of background path resolution, requires previous initialization.
  static String? backgroundCachePathSync(
    String themeFolder,
    String systemFolderName, {
    String ext = 'webp',
  }) {
    final dir = _cachedThemeDir;
    if (dir == null) return null;
    return path.join(dir, themeFolder, 'backgrounds', '$systemFolderName.$ext');
  }

  /// Resolves the cached background path checking both .webp and .gif formats.
  /// Returns the path to the existing file, preferring .webp over .gif.
  /// If neither exists, returns the .webp path as default.
  static String? resolveBackgroundPathSync(
    String themeFolder,
    String systemFolderName,
  ) {
    final dir = _cachedThemeDir;
    if (dir == null) return null;

    final webpPath = path.join(
      dir,
      themeFolder,
      'backgrounds',
      '$systemFolderName.webp',
    );
    if (File(webpPath).existsSync()) return webpPath;

    final gifPath = path.join(
      dir,
      themeFolder,
      'backgrounds',
      '$systemFolderName.gif',
    );
    if (File(gifPath).existsSync()) return gifPath;

    return webpPath;
  }

  /// Returns the local cache path for a specific background.
  static Future<String> backgroundCachePath(
    String themeFolder,
    String systemFolderName, {
    String ext = 'webp',
  }) async {
    final dir = await _cacheDir();
    return path.join(dir, themeFolder, 'backgrounds', '$systemFolderName.$ext');
  }

  /// Returns the local cache path for a pack's metadata file.
  static Future<String> packMetadataCachePath(String themeFolder) async {
    final dir = await _cacheDir();
    return path.join(dir, themeFolder, 'pack.json');
  }

  /// Persists the pack metadata to the local cache so it survives offline.
  static Future<void> writeLocalPackMetadata(
    String themeFolder,
    Map<String, dynamic> metadata,
  ) async {
    try {
      final metadataPath = await packMetadataCachePath(themeFolder);
      final file = File(metadataPath);
      await file.parent.create(recursive: true);
      await file.writeAsString(jsonEncode(metadata));
    } catch (e) {
      _log.w('Error writing local pack metadata for "$themeFolder": $e');
    }
  }

  /// Deletes all cached assets for a specific pack folder.
  static Future<void> clearThemeCache(String themeFolder) async {
    try {
      final dir = await _cacheDir();
      final themeDir = Directory(path.join(dir, themeFolder));
      if (await themeDir.exists()) {
        await themeDir.delete(recursive: true);
      }
    } catch (e) {
      _log.e('Error clearing theme cache: $e');
    }
  }
}
