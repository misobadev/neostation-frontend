import 'package:flutter/foundation.dart';
import '../services/neo_assets_service.dart';
import '../repositories/config_repository.dart';
import '../services/logger_service.dart';

final _log = LoggerService.instance;

/// Provider responsible for managing remote and local theme assets (logos, backgrounds).
///
/// Handles theme discovery, batch downloading of assets, and persistence of the
/// active theme selection. Uses [NeoAssetsService] for network and cache I/O.
class NeoAssetsProvider extends ChangeNotifier {
  /// List of available themes fetched from the remote repository.
  List<NeoAssetsTheme> _themes = [];

  /// Folder name of the currently selected theme.
  String _activeThemeFolder = '';

  /// Whether a network request to fetch themes is in progress.
  bool _loading = false;

  /// Whether a background download of theme assets is active.
  bool _downloading = false;

  /// Normalized download progress (0.0 to 1.0).
  double _downloadProgress = 0.0;

  /// Internal flag to ensure initialization logic runs only once.
  bool _initialized = false;

  List<NeoAssetsTheme> get themes => _themes;
  String get activeThemeFolder => _activeThemeFolder;
  bool get loading => _loading;
  bool get downloading => _downloading;
  double get downloadProgress => _downloadProgress;
  bool get hasActiveTheme => _activeThemeFolder.isNotEmpty;

  /// Returns the currently active [NeoAssetsTheme] metadata.
  NeoAssetsTheme? get activeTheme => _themes.isEmpty
      ? null
      : _themes.where((t) => t.folder == _activeThemeFolder).firstOrNull;

  /// Initializes the theme cache directory and loads the active theme from the database.
  Future<void> init() async {
    if (_initialized) return;
    _initialized = true;
    await NeoAssetsService.ensureCacheDirInitialized();
    _activeThemeFolder = await ConfigRepository.getActiveTheme();
    notifyListeners();
    await loadThemes();
  }

  /// Fetches the list of available themes from the remote server.
  Future<void> loadThemes() async {
    _loading = true;
    notifyListeners();
    try {
      _themes = await NeoAssetsService.fetchThemes();
    } catch (e) {
      _log.e('Error loading themes: $e');
    } finally {
      _loading = false;
      notifyListeners();
    }
  }

  /// Sets a new active theme and persists the choice to the local database.
  Future<void> setActiveTheme(String themeFolder) async {
    if (_activeThemeFolder == themeFolder) return;
    _activeThemeFolder = themeFolder;
    await ConfigRepository.updateActiveTheme(themeFolder);
    notifyListeners();
  }

  /// Deselects the current theme and resets the active selection.
  Future<void> clearTheme() async {
    _activeThemeFolder = '';
    await ConfigRepository.updateActiveTheme('');
    notifyListeners();
  }

  /// Downloads all required assets for the specified theme and applies it.
  ///
  /// Calculates a download plan to identify missing or outdated assets and
  /// performs a batch download with real-time progress updates.
  Future<void> downloadAndApplyTheme(
    String themeFolder,
    List<String> systemFolderNames,
  ) async {
    try {
      final plan = await NeoAssetsService.buildThemeDownloadPlan(
        themeFolder,
        systemFolderNames,
      );

      if (plan.totalAssetsToDownload > 0) {
        _downloading = true;
        _downloadProgress = 0.0;
        notifyListeners();

        if (plan.forceRedownload) {
          await NeoAssetsService.downloadAllThemeAssets(
            themeFolder,
            systemFolderNames,
            forceRedownload: true,
            onProgress: (done, t) {
              _downloadProgress = t == 0 ? 1.0 : done / t;
              notifyListeners();
            },
          );
        } else {
          await NeoAssetsService.downloadMissingThemeAssets(
            themeFolder,
            systemFolderNames,
            missingTotal: plan.totalAssetsToDownload,
            onProgress: (done, t) {
              _downloadProgress = t == 0 ? 1.0 : done / t;
              notifyListeners();
            },
          );
        }
      }

      if (plan.remoteMetadata != null) {
        await NeoAssetsService.writeLocalThemeMetadata(
          themeFolder,
          plan.remoteMetadata!,
        );
      }

      _activeThemeFolder = themeFolder;
      await ConfigRepository.updateActiveTheme(themeFolder);
    } catch (e) {
      _log.e('Error downloading theme: $e');
    } finally {
      _downloading = false;
      _downloadProgress = 0.0;
      notifyListeners();
    }
  }

  /// Resolves the absolute path to a system background within the active theme.
  Future<String?> getBackgroundForSystem(String systemFolderName) async {
    if (!hasActiveTheme) return null;
    return NeoAssetsService.getCachedBackground(
      _activeThemeFolder,
      systemFolderName,
    );
  }

  /// Synchronous variant for resolving background paths.
  /// Checks the cache for both .webp and .gif formats.
  String? getBackgroundForSystemSync(String systemFolderName) {
    if (!hasActiveTheme) return null;
    return NeoAssetsService.resolveBackgroundPathSync(
      _activeThemeFolder,
      systemFolderName,
    );
  }

  /// Resolves the absolute path to a system logo within the active theme.
  Future<String?> getLogoForSystem(String systemFolderName) async {
    if (!hasActiveTheme) return null;
    return NeoAssetsService.getCachedLogo(_activeThemeFolder, systemFolderName);
  }

  /// Synchronous variant for resolving logo paths.
  String? getLogoForSystemSync(String systemFolderName) {
    if (!hasActiveTheme) return null;
    return NeoAssetsService.logoCachePathSync(
      _activeThemeFolder,
      systemFolderName,
    );
  }
}
