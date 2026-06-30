import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as path;
import 'config_service.dart';
import 'logger_service.dart';

const _baseRaw =
    'https://raw.githubusercontent.com/misobadev/neostation-assets/main';
const _manifestUrl = '$_baseRaw/manifest.json';

final _log = LoggerService.instance;

/// Represents a plan for downloading or updating theme assets.
class ThemeDownloadPlan {
  /// Whether a full redownload is required due to a version mismatch.
  final bool forceRedownload;

  /// The total number of individual asset files that need to be fetched.
  final int totalAssetsToDownload;

  /// The version string of the theme currently stored locally.
  final String? localVersion;

  /// The version string of the theme available on the remote repository.
  final String? remoteVersion;

  /// Full metadata retrieved from the remote theme configuration.
  final Map<String, dynamic>? remoteMetadata;

  const ThemeDownloadPlan({
    required this.forceRedownload,
    required this.totalAssetsToDownload,
    required this.localVersion,
    required this.remoteVersion,
    required this.remoteMetadata,
  });
}

/// Model representing a theme available in the NeoStation assets repository.
class NeoAssetsTheme {
  /// Display name of the theme.
  final String name;

  /// The unique folder identifier for the theme.
  final String folder;

  /// The direct URL to the theme's preview image.
  final String previewUrl;

  /// The raw source path or URL for the preview image.
  final String previewSource;

  /// Whether the theme assets were generated using AI.
  final bool isAi;

  const NeoAssetsTheme({
    required this.name,
    required this.folder,
    required this.previewUrl,
    required this.previewSource,
    required this.isAi,
  });

  factory NeoAssetsTheme.fromJson(Map<String, dynamic> json) {
    final previewSource = json['preview']?.toString().trim() ?? '';
    return NeoAssetsTheme(
      name: json['name']?.toString() ?? '',
      folder: json['folder']?.toString() ?? '',
      previewUrl: _resolvePreviewUrl(previewSource),
      previewSource: previewSource,
      isAi: _parseAi(json['ai']),
    );
  }

  NeoAssetsTheme copyWith({
    String? name,
    String? folder,
    String? previewUrl,
    String? previewSource,
    bool? isAi,
  }) {
    return NeoAssetsTheme(
      name: name ?? this.name,
      folder: folder ?? this.folder,
      previewUrl: previewUrl ?? this.previewUrl,
      previewSource: previewSource ?? this.previewSource,
      isAi: isAi ?? this.isAi,
    );
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

  /// Resolves raw preview strings into usable image URLs, including GitHub blob
  /// translation and WebP conversion heuristics.
  static String _resolvePreviewUrl(dynamic rawPreview) {
    final preview = rawPreview?.toString().trim() ?? '';
    if (preview.isEmpty) return '';

    final uri = Uri.tryParse(preview);
    if (uri != null && uri.hasScheme) {
      if (uri.host == 'github.com' && uri.pathSegments.length >= 5) {
        final segments = uri.pathSegments;
        if (segments[2] == 'blob') {
          final owner = segments[0];
          final repo = segments[1];
          final branch = segments[3];
          final filePath = segments.sublist(4).join('/');
          return _forceWebpPreviewUrl(
            'https://raw.githubusercontent.com/$owner/$repo/$branch/$filePath',
          );
        }
      }
      return _forceWebpPreviewUrl(preview);
    }

    final normalizedPath = preview.startsWith('/')
        ? preview.substring(1)
        : preview;
    return _forceWebpPreviewUrl('$_baseRaw/$normalizedPath');
  }

  /// Appends or replaces the image extension with .webp if it's a standard format.
  static String _forceWebpPreviewUrl(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null || !uri.hasScheme) return url;

    final path = uri.path;
    final lowerPath = path.toLowerCase();
    if (!lowerPath.endsWith('.jpg') &&
        !lowerPath.endsWith('.jpeg') &&
        !lowerPath.endsWith('.png')) {
      return url;
    }

    final newPath = path.replaceFirst(
      RegExp(r'\.(jpg|jpeg|png)$', caseSensitive: false),
      '.webp',
    );
    return uri.replace(path: newPath).toString();
  }
}

/// Service responsible for fetching, downloading, and caching remote assets
/// (themes, logos, backgrounds) from the NeoStation assets repository.
class NeoAssetsService {
  static List<NeoAssetsTheme>? _cachedThemes;
  static String? _cachedThemeDir;

  /// Fetches the global manifest of available themes from the remote repository.
  static Future<List<NeoAssetsTheme>> fetchThemes() async {
    if (_cachedThemes != null) return _cachedThemes!;

    try {
      final response = await http.get(Uri.parse(_manifestUrl));
      if (response.statusCode != 200) {
        _log.w(
          'Failed to fetch neostation-assets manifest: ${response.statusCode}',
        );
        return [];
      }
      final json = jsonDecode(response.body) as Map<String, dynamic>;
      final baseList = (json['themes'] as List? ?? [])
          .cast<Map<String, dynamic>>()
          .map(NeoAssetsTheme.fromJson)
          .toList();
      final list = await Future.wait(
        baseList.map((theme) async {
          final metadata = await _fetchThemeMetadata(theme.folder);
          if (metadata == null) return theme;
          final metadataAi = NeoAssetsTheme._parseAi(metadata['ai']);
          if (metadataAi == theme.isAi) return theme;
          return theme.copyWith(isAi: metadataAi);
        }),
      );
      _cachedThemes = list;
      return list;
    } catch (e) {
      _log.e('Error fetching themes: $e');
      return [];
    }
  }

  /// Clears the in-memory theme list cache.
  static void clearCache() {
    _cachedThemes = null;
  }

  /// Returns the remote URL for a specific system background within a theme.
  static String getBackgroundUrl(
    String themeFolder,
    String systemFolderName, {
    String ext = 'webp',
  }) {
    return '$_baseRaw/themes/$themeFolder/backgrounds/$systemFolderName.$ext';
  }

  /// Returns the remote URL for a specific system logo within a theme.
  static String getLogoUrl(
    String themeFolder,
    String systemFolderName, {
    String ext = 'webp',
  }) {
    return '$_baseRaw/themes/$themeFolder/logos/$systemFolderName.$ext';
  }

  /// Returns the remote URL for a theme's metadata JSON file.
  static String getThemeMetadataUrl(String themeFolder) {
    return '$_baseRaw/themes/$themeFolder/theme.json';
  }

  /// Downloads a remote asset to the local filesystem and returns the absolute path.
  static Future<String?> downloadAndCacheAsset(
    String url,
    String localPath,
  ) async {
    try {
      final file = File(localPath);
      if (await file.exists()) return localPath;

      await file.parent.create(recursive: true);
      final response = await http.get(Uri.parse(url));
      if (response.statusCode != 200) return null;

      await file.writeAsBytes(response.bodyBytes);
      return localPath;
    } catch (e) {
      _log.e('Error caching asset $url: $e');
      return null;
    }
  }

  /// Returns the local directory used for theme asset caching.
  static Future<String> _cacheDir() async {
    if (_cachedThemeDir != null) return _cachedThemeDir!;
    final base = await ConfigService.getUserDataPath();
    _cachedThemeDir = path.join(base, 'themes');
    return _cachedThemeDir!;
  }

  /// Ensures the theme cache directory path is calculated and available.
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

  /// Synchronous variant of logo path resolution, requires previous initialization.
  static String? logoCachePathSync(
    String themeFolder,
    String systemFolderName, {
    String ext = 'webp',
  }) {
    final dir = _cachedThemeDir;
    if (dir == null) return null;
    return path.join(dir, themeFolder, 'logos', '$systemFolderName.$ext');
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

  /// Returns the local cache path for a specific logo.
  static Future<String> logoCachePath(
    String themeFolder,
    String systemFolderName, {
    String ext = 'webp',
  }) async {
    final dir = await _cacheDir();
    return path.join(dir, themeFolder, 'logos', '$systemFolderName.$ext');
  }

  /// Returns the local cache path for a theme's metadata file.
  static Future<String> themeMetadataCachePath(String themeFolder) async {
    final dir = await _cacheDir();
    return path.join(dir, themeFolder, 'theme.json');
  }

  /// Fetches the metadata JSON for a specific theme from the remote repository.
  static Future<Map<String, dynamic>?> _fetchThemeMetadata(
    String themeFolder,
  ) async {
    try {
      final response = await http.get(
        Uri.parse(getThemeMetadataUrl(themeFolder)),
      );
      if (response.statusCode != 200) {
        _log.w(
          'Failed to fetch theme metadata for "$themeFolder": ${response.statusCode}',
        );
        return null;
      }
      final json = jsonDecode(response.body);
      if (json is! Map<String, dynamic>) return null;
      return json;
    } catch (e) {
      _log.w('Error fetching theme metadata for "$themeFolder": $e');
      return null;
    }
  }

  /// Reads the version string from the locally cached theme metadata.
  static Future<String?> readLocalThemeVersion(String themeFolder) async {
    try {
      final metadataPath = await themeMetadataCachePath(themeFolder);
      final file = File(metadataPath);
      if (!await file.exists()) return null;
      final json = jsonDecode(await file.readAsString());
      if (json is! Map<String, dynamic>) return null;
      return json['version']?.toString();
    } catch (e) {
      _log.w('Error reading local theme metadata for "$themeFolder": $e');
      return null;
    }
  }

  /// Persists the theme metadata to the local cache.
  static Future<void> writeLocalThemeMetadata(
    String themeFolder,
    Map<String, dynamic> metadata,
  ) async {
    try {
      final metadataPath = await themeMetadataCachePath(themeFolder);
      final file = File(metadataPath);
      await file.parent.create(recursive: true);
      await file.writeAsString(jsonEncode(metadata));
    } catch (e) {
      _log.w('Error writing local theme metadata for "$themeFolder": $e');
    }
  }

  /// Counts the number of theme assets missing from the local cache for a list
  /// of systems.
  static Future<int> countMissingThemeAssets(
    String themeFolder,
    List<String> systemFolderNames,
  ) async {
    int missing = 0;
    for (final system in systemFolderNames) {
      final bgWebp = await backgroundCachePath(themeFolder, system);
      final bgGif = await backgroundCachePath(themeFolder, system, ext: 'gif');
      if (!await File(bgWebp).exists() && !await File(bgGif).exists()) {
        missing++;
      }

      final logoPath = await logoCachePath(themeFolder, system);
      if (!await File(logoPath).exists()) missing++;
    }
    return missing;
  }

  /// Compares local and remote versions to build a prioritized download plan.
  static Future<ThemeDownloadPlan> buildThemeDownloadPlan(
    String themeFolder,
    List<String> systemFolderNames,
  ) async {
    final remoteMetadata = await _fetchThemeMetadata(themeFolder);
    final localVersion = await readLocalThemeVersion(themeFolder);
    final remoteVersion = remoteMetadata?['version']?.toString();

    final forceRedownload =
        localVersion != null &&
        remoteVersion != null &&
        localVersion.isNotEmpty &&
        remoteVersion.isNotEmpty &&
        localVersion != remoteVersion;

    final totalAssetsToDownload = forceRedownload
        ? systemFolderNames.length * 2
        : await countMissingThemeAssets(themeFolder, systemFolderNames);

    return ThemeDownloadPlan(
      forceRedownload: forceRedownload,
      totalAssetsToDownload: totalAssetsToDownload,
      localVersion: localVersion,
      remoteVersion: remoteVersion,
      remoteMetadata: remoteMetadata,
    );
  }

  /// Retrieves a cached background image, downloading it if necessary.
  /// Tries .webp first, then falls back to .gif.
  static Future<String?> getCachedBackground(
    String themeFolder,
    String systemFolderName,
  ) async {
    final webpPath = await backgroundCachePath(themeFolder, systemFolderName);
    final webpUrl = getBackgroundUrl(themeFolder, systemFolderName);
    var result = await downloadAndCacheAsset(webpUrl, webpPath);
    if (result != null) return result;

    final gifPath = await backgroundCachePath(
      themeFolder,
      systemFolderName,
      ext: 'gif',
    );
    final gifUrl = getBackgroundUrl(themeFolder, systemFolderName, ext: 'gif');
    result = await downloadAndCacheAsset(gifUrl, gifPath);
    if (result != null) return result;

    return null;
  }

  /// Retrieves a cached system logo image, downloading it if necessary.
  static Future<String?> getCachedLogo(
    String themeFolder,
    String systemFolderName,
  ) async {
    final localPath = await logoCachePath(themeFolder, systemFolderName);
    final url = getLogoUrl(themeFolder, systemFolderName);
    return downloadAndCacheAsset(url, localPath);
  }

  /// Downloads all background and logo assets for a theme, optionally
  /// forcing a refresh.
  static Future<void> downloadAllThemeAssets(
    String themeFolder,
    List<String> systemFolderNames, {
    bool forceRedownload = false,
    void Function(int done, int total)? onProgress,
  }) async {
    if (forceRedownload) {
      await clearThemeCache(themeFolder);
    }

    final total = systemFolderNames.length * 2;
    int done = 0;
    for (final system in systemFolderNames) {
      await getCachedBackground(themeFolder, system);
      done++;
      onProgress?.call(done, total);
      await getCachedLogo(themeFolder, system);
      done++;
      onProgress?.call(done, total);
    }
  }

  /// Downloads only the missing background and logo assets for a theme.
  static Future<void> downloadMissingThemeAssets(
    String themeFolder,
    List<String> systemFolderNames, {
    required int missingTotal,
    void Function(int done, int total)? onProgress,
  }) async {
    if (missingTotal <= 0) return;

    int done = 0;
    for (final system in systemFolderNames) {
      final bgWebp = await backgroundCachePath(themeFolder, system);
      final bgGif = await backgroundCachePath(themeFolder, system, ext: 'gif');
      if (!await File(bgWebp).exists() && !await File(bgGif).exists()) {
        final bgUrl = getBackgroundUrl(themeFolder, system);
        var result = await downloadAndCacheAsset(bgUrl, bgWebp);
        if (result == null) {
          final gifUrl = getBackgroundUrl(themeFolder, system, ext: 'gif');
          await downloadAndCacheAsset(gifUrl, bgGif);
        }
        done++;
        onProgress?.call(done, missingTotal);
      }

      final logoPath = await logoCachePath(themeFolder, system);
      if (!await File(logoPath).exists()) {
        final logoUrl = getLogoUrl(themeFolder, system);
        await downloadAndCacheAsset(logoUrl, logoPath);
        done++;
        onProgress?.call(done, missingTotal);
      }
    }
  }

  /// Deletes all cached assets for a specific theme folder.
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
