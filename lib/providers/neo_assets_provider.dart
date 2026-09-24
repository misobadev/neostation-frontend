import 'package:flutter/foundation.dart';
import '../services/neo_assets_service.dart';
import '../repositories/config_repository.dart';
import '../services/logger_service.dart';

final _log = LoggerService.instance;

/// Provider responsible for managing system art packs (backgrounds) from the
/// NeoAssets catalog.
///
/// Handles pack discovery, downloading of a pack's files, and persistence of
/// the active pack selection. Uses [NeoAssetsService] for network and cache I/O.
class NeoAssetsProvider extends ChangeNotifier {
  /// List of available packs fetched from the NeoAssets catalog.
  List<NeoAssetsTheme> _themes = [];

  /// Folder name of the currently selected pack.
  String _activeThemeFolder = '';

  /// Whether a network request to fetch packs is in progress.
  bool _loading = false;

  /// Whether a background download of pack assets is active.
  bool _downloading = false;

  /// Normalized download progress (0.0 to 1.0).
  double _downloadProgress = 0.0;

  /// Files downloaded so far in the active download.
  int _downloadDone = 0;

  /// Total files in the active download.
  int _downloadTotal = 0;

  /// Internal flag to ensure initialization logic runs only once.
  bool _initialized = false;

  List<NeoAssetsTheme> get themes => _themes;
  String get activeThemeFolder => _activeThemeFolder;
  bool get loading => _loading;
  bool get downloading => _downloading;
  double get downloadProgress => _downloadProgress;
  int get downloadDone => _downloadDone;
  int get downloadTotal => _downloadTotal;
  bool get hasActiveTheme => _activeThemeFolder.isNotEmpty;

  /// Whether [folder] is the applied pack, matched case-insensitively so a
  /// folder-casing difference (e.g. a legacy `NeoStation` vs the catalog's
  /// `neostation`) still reads as the same pack.
  bool isThemeActive(String folder) =>
      _activeThemeFolder.isNotEmpty &&
      _activeThemeFolder.toLowerCase() == folder.toLowerCase();

  /// Returns the currently active [NeoAssetsTheme] metadata.
  NeoAssetsTheme? get activeTheme => _themes.isEmpty
      ? null
      : _themes.where((t) => t.folder == _activeThemeFolder).firstOrNull;

  /// Initializes the pack cache directory and loads the active pack from the
  /// database.
  Future<void> init() async {
    if (_initialized) return;
    _initialized = true;
    await NeoAssetsService.ensureCacheDirInitialized();
    _activeThemeFolder = await ConfigRepository.getActiveTheme();
    notifyListeners();
    await loadThemes();
  }

  /// Re-runs [init] against the *current* user-data location.
  ///
  /// The setup wizard's first step can move the user data after this provider
  /// has already initialised, which leaves the cache directory and the active
  /// pack resolved against the folder the app started in. Calling this once the
  /// database has been reopened at the new path re-derives both.
  Future<void> reinitialize() async {
    _initialized = false;
    await init();
  }

  /// Fetches the list of available packs from the NeoAssets catalog.
  Future<void> loadThemes({bool forceRefresh = false}) async {
    _loading = true;
    notifyListeners();
    try {
      _themes = await NeoAssetsService.fetchThemes(forceRefresh: forceRefresh);
    } catch (e) {
      _log.e('Error loading system art packs: $e');
    } finally {
      _loading = false;
      notifyListeners();
    }
  }

  /// Re-fetches the catalog and updates the list without the loading spinner.
  ///
  /// Used after applying a pack: the server counted the download but its
  /// response carries the previous count, so the list is re-read to show the
  /// new one. A failed refresh keeps the current list.
  Future<void> refreshThemes() async {
    try {
      _themes = await NeoAssetsService.fetchThemes(forceRefresh: true);
      notifyListeners();
    } catch (e) {
      _log.w('Error refreshing system art packs: $e');
    }
  }

  /// Sets a new active pack and persists the choice to the local database.
  Future<void> setActiveTheme(String themeFolder) async {
    if (_activeThemeFolder == themeFolder) return;
    _activeThemeFolder = themeFolder;
    await ConfigRepository.updateActiveTheme(themeFolder);
    notifyListeners();
  }

  /// Deselects the current pack and resets the active selection.
  Future<void> clearTheme() async {
    _activeThemeFolder = '';
    await ConfigRepository.updateActiveTheme('');
    notifyListeners();
  }

  /// Downloads the specified pack and applies it.
  ///
  /// Fetches the pack's file list from the catalog and downloads every file,
  /// reporting progress. Returns whether the pack was actually applied, so a
  /// caller that reports success (the setup wizard) doesn't claim a pack the
  /// user has no art for. An unreachable pack, or one whose files all failed to
  /// download, is never recorded as active.
  ///
  /// [systemFolderNames] is kept for API compatibility and ignored: the pack
  /// itself declares exactly which system files it ships.
  Future<bool> downloadAndApplyTheme(
    String themeFolder,
    List<String> systemFolderNames, {
    bool forceRedownload = false,
  }) async {
    try {
      final pack = await NeoAssetsService.fetchPack(themeFolder);
      if (pack == null || pack.files.isEmpty) {
        _log.w(
          'Not applying pack "$themeFolder": metadata unreachable or the pack '
          'ships no files',
        );
        return false;
      }

      _downloading = true;
      _downloadProgress = 0.0;
      _downloadDone = 0;
      _downloadTotal = pack.files.length;
      notifyListeners();

      // A forced redownload wipes the cache before refetching, so only honour
      // it once the pack metadata has actually come back: deleting art we then
      // cannot re-fetch (offline, CDN down) would leave the user with none.
      if (forceRedownload) {
        await NeoAssetsService.clearThemeCache(themeFolder);
      }

      final cached = await NeoAssetsService.downloadPack(
        themeFolder,
        pack.files,
        onProgress: (done, total) {
          _downloadDone = done;
          _downloadTotal = total;
          _downloadProgress = total == 0 ? 1.0 : done / total;
          notifyListeners();
        },
      );

      if (cached <= 0) {
        _log.w('Not applying pack "$themeFolder": no files were downloaded');
        return false;
      }

      await NeoAssetsService.writeLocalPackMetadata(
        themeFolder,
        pack.toMetadataJson(),
      );

      // Persist first: if the database write fails, do not claim the pack is
      // active (the catch below returns false and leaves the old selection).
      await ConfigRepository.updateActiveTheme(themeFolder);
      _activeThemeFolder = themeFolder;

      // Re-read the catalog so the pack's download count reflects the download
      // the server just counted (its own response carries the old value).
      await refreshThemes();
      return true;
    } catch (e) {
      _log.e('Error downloading pack "$themeFolder": $e');
      return false;
    } finally {
      _downloading = false;
      _downloadProgress = 0.0;
      _downloadDone = 0;
      _downloadTotal = 0;
      notifyListeners();
    }
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

  /// Logos are no longer loaded from remote packs.
  /// Returns null to fall through to bundled local assets.
  Future<String?> getLogoForSystem(String systemFolderName) async {
    return null;
  }

  /// Synchronous variant — always returns null.
  String? getLogoForSystemSync(String systemFolderName) {
    return null;
  }
}
