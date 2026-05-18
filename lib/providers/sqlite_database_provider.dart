import 'package:flutter/foundation.dart';
import 'package:neostation/services/logger_service.dart';
import '../models/database_game_model.dart';
import '../models/system_model.dart';
import '../data/datasources/sqlite_database_service.dart';
import '../services/config_service.dart';
import '../repositories/game_repository.dart';
import '../services/steam_scraper_service.dart';

/// Provider responsible for managing the in-memory state of the SQLite game database.
///
/// Synchronizes metadata for ROMs, favorites, and play statistics between the
/// physical SQLite file and the UI. Supports incremental loading, searching,
/// and global statistics computation.
class SqliteDatabaseProvider extends ChangeNotifier {
  static final _log = LoggerService.instance;

  /// Internal cache of games grouped by their system's folder name.
  Map<String, List<DatabaseGameModel>> _database = {};

  /// List of absolute paths currently monitored for ROM files.
  List<String> _romFolders = [];

  /// Metadata for all supported systems.
  List<SystemModel> _availableSystems = [];

  /// Whether a data retrieval or scanning task is in progress.
  bool _isLoading = false;

  /// Last error message encountered during database operations.
  String? _error;

  /// Timestamp of the last successful database synchronization.
  DateTime? _lastUpdate;

  /// Whether the provider has finished its initial data load.
  bool _initialized = false;

  // Getters
  Map<String, List<DatabaseGameModel>> get database => _database;
  bool get isLoading => _isLoading;
  String? get error => _error;
  DateTime? get lastUpdate => _lastUpdate;
  bool get initialized => _initialized;

  /// Initializes the provider by performing an initial full load of the database.
  Future<void> initialize({
    List<String>? romFolders,
    List<SystemModel>? availableSystems,
  }) async {
    if (_initialized) return;

    if (romFolders != null) _romFolders = romFolders;
    if (availableSystems != null) _availableSystems = availableSystems;

    try {
      _setLoading(true);
      await loadDatabase();
      _initialized = true;
    } catch (e) {
      _error = 'Error initializing database provider: $e';
      _log.e('$_error');
    } finally {
      _setLoading(false);
    }
  }

  /// Updates the current ROM folder configuration and available systems metadata.
  void updateConfig({
    List<String>? romFolders,
    List<SystemModel>? availableSystems,
  }) {
    if (romFolders != null) _romFolders = romFolders;
    if (availableSystems != null) _availableSystems = availableSystems;
    notifyListeners();
  }

  /// Performs a full reload of all systems and their games from the SQLite database.
  Future<void> loadDatabase() async {
    _setLoading(true);
    _error = null;

    try {
      _database = await GameRepository.loadDatabase();
      _lastUpdate = DateTime.now();
      _log.i('Database loaded: ${_database.length} systems with games');
      notifyListeners();
    } catch (e) {
      _error = 'Error loading database: $e';
      _log.e('$_error');
    } finally {
      _setLoading(false);
    }
  }

  /// Retrieves the list of games associated with a specific system from the in-memory cache.
  List<DatabaseGameModel> getGamesForSystem(String systemFolderName) {
    return _database[systemFolderName] ?? [];
  }

  /// Loads games for a specific system from SQLite and updates the internal cache.
  Future<List<DatabaseGameModel>> loadGamesForSystem(
    String systemFolderName,
  ) async {
    try {
      final games = await GameRepository.loadGamesForSystem(systemFolderName);
      _database[systemFolderName] = games;
      notifyListeners();
      return games;
    } catch (e) {
      _error = 'Error loading games for $systemFolderName: $e';
      _log.e('$_error');
      notifyListeners();
      return [];
    }
  }

  /// Scans a specific system for new or removed ROMs.
  ///
  /// Updates the local database and triggers specialized scrapers (e.g., Steam)
  /// if applicable.
  Future<ScanSummary> scanSystemRoms(SystemModel system) async {
    _setLoading(true);
    _error = null;

    try {
      final summary = await SqliteDatabaseService.scanSystemRoms(
        system,
        _romFolders,
      );

      await loadGamesForSystem(system.folderName);

      if (system.folderName == 'steam') {
        SteamScraperService.scrapeSteamGames(provider: this);
      }

      _lastUpdate = DateTime.now();
      notifyListeners();
      return summary;
    } catch (e) {
      _error = 'Error scanning ROMs for ${system.realName}: $e';
      _log.e('$_error');
      return ScanSummary(
        added: 0,
        removed: 0,
        total: 0,
        systemName: system.realName,
      );
    } finally {
      _setLoading(false);
    }
  }

  /// Toggles the favorite status of a game and persists the change to the database.
  Future<void> toggleFavorite(String systemFolderName, String filename) async {
    try {
      await GameRepository.toggleFavorite(systemFolderName, filename);

      final games = _database[systemFolderName];
      if (games != null) {
        final gameIndex = games.indexWhere((game) => game.filename == filename);
        if (gameIndex != -1) {
          final updatedGame = games[gameIndex].copyWith(
            isFavorite: !games[gameIndex].isFavorite,
          );
          games[gameIndex] = updatedGame;
          notifyListeners();
        }
      }
    } catch (e) {
      _error = 'Error toggling favorite for $filename: $e';
      _log.e('$_error');
      notifyListeners();
    }
  }

  /// Increments the play count and updates the "last played" timestamp for a game.
  Future<void> recordGamePlayed(
    String systemFolderName,
    String filename,
  ) async {
    try {
      await GameRepository.recordGamePlayed(systemFolderName, filename);

      final games = _database[systemFolderName];
      if (games != null) {
        final gameIndex = games.indexWhere((game) => game.filename == filename);
        if (gameIndex != -1) {
          final updatedGame = games[gameIndex].copyWith(
            lastPlayed: DateTime.now(),
            playTime: (games[gameIndex].playTime ?? 0) + 1,
          );
          games[gameIndex] = updatedGame;
          notifyListeners();
        }
      }
    } catch (e) {
      _log.e('Error recording game played: $e');
    }
  }

  /// Updates metadata for a specific game in the database and local cache.
  Future<void> updateGame(
    String systemFolderName,
    DatabaseGameModel updatedGame,
  ) async {
    try {
      await GameRepository.updateGame(systemFolderName, updatedGame);

      final games = _database[systemFolderName];
      if (games != null) {
        final gameIndex = games.indexWhere(
          (game) => game.filename == updatedGame.filename,
        );
        if (gameIndex != -1) {
          games[gameIndex] = updatedGame;
          notifyListeners();
        }
      }

      _availableSystems = await ConfigService.detectSystems(
        romFolders: _romFolders,
        availableSystems: _availableSystems,
      );
    } catch (e) {
      _error = 'Error updating game: $e';
      _log.e('$_error');
      notifyListeners();
    }
  }

  /// Calculates aggregate statistics from the SQLite database.
  Future<Map<String, dynamic>> getStats() async {
    try {
      return await GameRepository.getStats();
    } catch (e) {
      _error = 'Error getting stats: $e';
      _log.e('$_error');
      return {
        'totalSystems': 0,
        'totalRoms': 0,
        'favoriteRoms': 0,
        'playedRoms': 0,
      };
    }
  }

  /// Returns a consolidated list of all favorite games across all systems.
  List<DatabaseGameModel> getAllFavoriteGames() {
    final favoriteGames = <DatabaseGameModel>[];

    for (final games in _database.values) {
      favoriteGames.addAll(games.where((game) => game.isFavorite));
    }

    return favoriteGames;
  }

  /// Returns a list of recently played games across all systems, sorted by timestamp.
  List<DatabaseGameModel> getRecentlyPlayedGames([int limit = 10]) {
    final playedGames = <DatabaseGameModel>[];

    for (final games in _database.values) {
      playedGames.addAll(games.where((game) => game.lastPlayed != null));
    }

    playedGames.sort((a, b) => b.lastPlayed!.compareTo(a.lastPlayed!));

    return playedGames.take(limit).toList();
  }

  /// Returns a list of the most frequently played games across all systems.
  List<DatabaseGameModel> getMostPlayedGames([int limit = 10]) {
    final playedGames = <DatabaseGameModel>[];

    for (final games in _database.values) {
      playedGames.addAll(games.where((game) => (game.playTime ?? 0) > 0));
    }

    playedGames.sort((a, b) => (b.playTime ?? 0).compareTo(a.playTime ?? 0));

    return playedGames.take(limit).toList();
  }

  /// Performs a case-insensitive search for games by filename.
  ///
  /// Can be restricted to a specific [systemFolderName].
  List<DatabaseGameModel> searchGames(
    String query, [
    String? systemFolderName,
  ]) {
    final lowerQuery = query.toLowerCase();
    final allGames = <DatabaseGameModel>[];

    if (systemFolderName != null) {
      final games = _database[systemFolderName] ?? [];
      allGames.addAll(games);
    } else {
      for (final games in _database.values) {
        allGames.addAll(games);
      }
    }

    return allGames
        .where((game) => game.filename.toLowerCase().contains(lowerQuery))
        .toList();
  }

  /// Retrieves a mapping of system folder names to their respective ROM counts.
  Future<Map<String, int>> getRomCounts() async {
    try {
      return await GameRepository.getRomCounts();
    } catch (e) {
      _log.e('Error getting ROM counts: $e');
      return {};
    }
  }

  /// Forces a reload of the games list for a specific system.
  Future<void> refreshSystem(String systemFolderName) async {
    try {
      await loadGamesForSystem(systemFolderName);
    } catch (e) {
      _error = 'Error refreshing $systemFolderName: $e';
      _log.e('$_error');
      notifyListeners();
    }
  }

  /// Forces a full reload of the entire database state.
  Future<void> refresh() async {
    await loadDatabase();
  }

  /// Whether any games are currently loaded for the specified system.
  bool hasGamesForSystem(String systemFolderName) {
    final games = _database[systemFolderName];
    return games != null && games.isNotEmpty;
  }

  /// Returns the total number of games currently indexed in the database.
  int get totalGames {
    return _database.values
        .map((games) => games.length)
        .fold(0, (sum, count) => sum + count);
  }

  /// Returns the total number of games marked as favorites (excluding music).
  int get totalFavorites {
    return _database.entries
        .where((entry) => entry.key != 'music')
        .expand((entry) => entry.value)
        .where((game) => game.isFavorite)
        .length;
  }

  /// Returns the total number of games that have been played at least once.
  int get totalPlayedGames {
    return _database.values
        .expand((games) => games)
        .where((game) => game.lastPlayed != null)
        .length;
  }

  void _setLoading(bool loading) {
    _isLoading = loading;
    notifyListeners();
  }

  /// Resets the current error state.
  void clearError() {
    _error = null;
    notifyListeners();
  }
}
