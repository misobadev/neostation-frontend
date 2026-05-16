import 'dart:io';
import 'dart:async';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:neostation/l10n/app_locale.dart';
import 'package:path/path.dart' as path;
import 'package:flutter/services.dart';
import 'package:flutter/material.dart';
import 'package:neostation/services/logger_service.dart';
import '../models/game_model.dart';
import '../models/database_game_model.dart';
import '../models/system_model.dart';
import '../models/emulator_model.dart';
import '../providers/file_provider.dart';
import '../repositories/game_repository.dart';
import '../repositories/system_repository.dart';
import '../repositories/emulator_repository.dart';
import '../constants/system_folder_names.dart';
import 'config_service.dart';
import 'game_session_persistence.dart';
import 'android_service.dart';
import 'launcher_service.dart';

/// Represents the result of a game launch attempt.
class GameLaunchResult {
  /// Whether the launch was successful.
  final bool success;

  /// Human-readable error message.
  final String? errorMessage;

  /// Technical details or raw error information for debugging.
  final String? errorDetails;

  GameLaunchResult.success()
    : success = true,
      errorMessage = null,
      errorDetails = null;

  GameLaunchResult.failure(this.errorMessage, [this.errorDetails])
    : success = false;
}

/// Represents a single layer in the navigation stack for gamepad focus management.
class NavLayer {
  final String id;
  final void Function() onActivate;
  final void Function() onDeactivate;

  NavLayer({
    required this.id,
    required this.onActivate,
    required this.onDeactivate,
  });
}

/// Global manager for gamepad/keyboard navigation focus across the application.
///
/// Maintains a focus stack to ensure that only the topmost UI layer receives
/// input events, preventing "ghost" navigation in background screens.
class GamepadNavigationManager {
  static final _log = LoggerService.instance;
  static final List<NavLayer> _stack = [];

  /// Pushes a new navigation layer to the top of the stack and activates it.
  ///
  /// Automatically deactivates the previously active layer.
  static void pushLayer(
    String id, {
    required void Function() onActivate,
    required void Function() onDeactivate,
  }) {
    _log.i('[GamepadNavigationManager] Pushing layer: $id');

    if (_stack.isNotEmpty) {
      _log.d(
        '[GamepadNavigationManager] Deactivating previous layer: ${_stack.last.id}',
      );
      try {
        _stack.last.onDeactivate();
      } catch (e) {
        _log.e('Error deactivating layer ${_stack.last.id}: $e');
      }
    }

    final newLayer = NavLayer(
      id: id,
      onActivate: onActivate,
      onDeactivate: onDeactivate,
    );
    _stack.add(newLayer);

    try {
      onActivate();
    } catch (e) {
      _log.e('Error activating layer $id: $e');
    }
  }

  /// Removes a navigation layer by its identifier and reactivates the new top layer.
  static void popLayer(String id) {
    if (_stack.isEmpty) return;

    _log.i('[GamepadNavigationManager] Popping layer: $id');

    final index = _stack.indexWhere((layer) => layer.id == id);
    if (index == -1) {
      _log.w('[GamepadNavigationManager] Layer $id not found in stack');
      return;
    }

    final isTop = index == _stack.length - 1;
    final layer = _stack.removeAt(index);

    if (isTop) {
      try {
        layer.onDeactivate();
      } catch (e) {
        _log.e('Error deactivating layer $id during pop: $e');
      }

      if (_stack.isNotEmpty) {
        _log.i(
          '[GamepadNavigationManager] Reactivating previous layer: ${_stack.last.id}',
        );
        try {
          _stack.last.onActivate();
        } catch (e) {
          _log.e('Error reactivating layer ${_stack.last.id}: $e');
        }
      }
    }
  }

  /// Deactivates all layers in the stack.
  ///
  /// Typically called when launching a game to prevent UI interaction during gameplay.
  static void deactivateAll() {
    if (_stack.isNotEmpty) {
      _log.i('[GamepadNavigationManager] Deactivating all layers');
      try {
        _stack.last.onDeactivate();
      } catch (e) {
        _log.e('Error deactivating top layer: $e');
      }
    }
  }

  /// Reactivates the topmost layer in the stack.
  static void reactivate() {
    if (_stack.isNotEmpty) {
      _log.i(
        '[GamepadNavigationManager] Reactivating top layer: ${_stack.last.id}',
      );
      try {
        _stack.last.onActivate();
      } catch (e) {
        _log.e('Error reactivating top layer: $e');
      }
    }
  }
}

/// Service responsible for game metadata management, process launching, and session tracking.
///
/// Handles platform-specific execution logic for RetroArch cores, standalone emulators,
/// and native Android applications. Manages playtime persistence and cross-platform
/// process monitoring.
class GameService {
  /// Whether a game process is currently active.
  static bool _isGameLaunched = false;
  static bool get isGameLaunched => _isGameLaunched;

  /// Timestamp when the current game session was initiated.
  static DateTime? _gameLaunchTime;

  /// Filename of the standalone emulator executable currently running.
  static String? _launchedEmulatorExe;

  /// Metadata for the system associated with the current game.
  static SystemModel? _currentGameSystem;

  /// Metadata for the currently active game.
  static GameModel? _currentGame;

  /// Callback triggered when a game session terminates on Android.
  static Function(int)? _onGameReturnedCallback;

  /// Callback triggered when the game process exits on desktop platforms.
  static Function()? _onProcessExitCallback;

  /// Periodic timer for persisting playtime statistics to the database.
  static Timer? _playtimeTimer;

  /// Timestamp of the last successful playtime persistence operation.
  static DateTime? _lastPlaytimeSave;

  static final _log = LoggerService.instance;

  static final RegExp _parenthesesRegex = RegExp(r'\([^)]*\)');
  static final RegExp _bracketsRegex = RegExp(r'\[[^\]]*\]');
  static final RegExp _whitespaceRegex = RegExp(r'\s+');

  /// Initializes the platform-specific listener for Android game lifecycle events.
  static void initializeAndroidGameListener() {
    if (!Platform.isAndroid) return;

    const platform = MethodChannel('com.neogamelab.neostation/game');
    platform.setMethodCallHandler((call) async {
      if (call.method == 'onGameReturned') {
        final elapsedSeconds =
            int.tryParse(call.arguments['elapsedSeconds']?.toString() ?? '0') ??
            0;

        if (_onGameReturnedCallback != null) {
          _onGameReturnedCallback!(elapsedSeconds);
        }
      }
    });
  }

  /// Recovers playtime from a previously interrupted game session.
  ///
  /// Handles cases where the application was terminated by the OS (Android)
  /// while a game was running.
  static Future<void> checkPendingGameSession() async {
    try {
      final session = await GameSessionPersistence.getActiveGameSession();

      if (session == null) {
        return;
      }

      final systemFolderName = session['systemFolderName'].toString();
      final filename = session['filename'].toString();
      final startTimestamp =
          int.tryParse(session['startTimestamp']?.toString() ?? '0') ?? 0;

      final currentTimestamp = DateTime.now().millisecondsSinceEpoch;
      final elapsedSeconds = ((currentTimestamp - startTimestamp) / 1000)
          .round();

      // Only process sessions that lasted at least 5 seconds to filter out launch failures
      if (elapsedSeconds >= 5) {
        final system = await SystemRepository.getSystemByFolderName(
          systemFolderName,
        );
        if (system == null) return;
        final game = await GameRepository.getSingleGame(system.id!, filename);

        if (game != null && game.romPath.isNotEmpty) {
          await GameRepository.updatePlayTime(game.romPath, elapsedSeconds);
        }
      }

      await GameSessionPersistence.clearGameSession();
    } catch (e) {
      _log.e('Error checking pending game session: $e');
    }
  }

  static void setOnGameReturnedCallback(Function(int) callback) {
    _onGameReturnedCallback = callback;
  }

  static void clearOnGameReturnedCallback() {
    _onGameReturnedCallback = null;
  }

  static void setOnProcessExitCallback(Function() callback) {
    _onProcessExitCallback = callback;
  }

  static void clearOnProcessExitCallback() {
    _onProcessExitCallback = null;
  }

  static bool _hasScreenscraperRealName(DatabaseGameModel dbGame) {
    final t = dbGame.screenscraperRealName?.trim();
    return t != null && t.isNotEmpty;
  }

  /// Sanitizes a filename for display in the UI based on user preferences.
  ///
  /// Optionally strips extensions, regional tags (parentheses), and technical
  /// tags (brackets).
  static String _formatListNameFromFilename(
    String filename,
    Set<String> validExtensionsSet, {
    required bool hideExtension,
    required bool hideParentheses,
    required bool hideBrackets,
  }) {
    String name = filename;
    if (hideExtension) {
      final extWithDot = path.extension(name).toLowerCase();
      if (extWithDot.isNotEmpty) {
        final ext = extWithDot.substring(1);
        if (validExtensionsSet.contains(ext)) {
          name = name.substring(0, name.length - extWithDot.length);
        }
      }
    }
    if (hideParentheses) {
      name = name.replaceAll(_parenthesesRegex, '');
    }
    if (hideBrackets) {
      name = name.replaceAll(_bracketsRegex, '');
    }
    name = name.replaceAll(_whitespaceRegex, ' ').trim();
    if (!hideExtension) {
      name = name.replaceAll(RegExp(r'\s+(?=\.[^.]+$)'), '');
    }
    return name;
  }

  static String _formatListNameFromScrapedTitle(String rawTitle) {
    String name = rawTitle.trim();
    name = name.replaceAll(_whitespaceRegex, ' ').trim();
    name = name.replaceAll(RegExp(r'\s+(?=\.[^.]+$)'), '');
    return name;
  }

  /// Resolves the optimal display name for a game considering scraped metadata
  /// and user-defined naming conventions.
  static ({String name, bool showRomFileNameSubtitle}) _resolveListDisplayName({
    required DatabaseGameModel dbGame,
    required bool preferFileName,
    required bool hideExtension,
    required bool hideParentheses,
    required bool hideBrackets,
    required Set<String> validExtensionsSet,
  }) {
    final filename = dbGame.filename;
    final scraped = _hasScreenscraperRealName(dbGame);
    final coalesced = dbGame.realName ?? dbGame.titleName ?? filename;

    if (preferFileName) {
      return (
        name: _formatListNameFromFilename(
          filename,
          validExtensionsSet,
          hideExtension: hideExtension,
          hideParentheses: hideParentheses,
          hideBrackets: hideBrackets,
        ),
        showRomFileNameSubtitle: false,
      );
    }
    if (scraped) {
      return (
        name: _formatListNameFromScrapedTitle(coalesced),
        showRomFileNameSubtitle: true,
      );
    }
    if (coalesced != filename) {
      return (name: coalesced, showRomFileNameSubtitle: false);
    }
    return (
      name: _formatListNameFromFilename(
        filename,
        validExtensionsSet,
        hideExtension: hideExtension,
        hideParentheses: hideParentheses,
        hideBrackets: hideBrackets,
      ),
      showRomFileNameSubtitle: false,
    );
  }

  /// Retrieves a list of games for a specific system, applying metadata formatting.
  ///
  /// If the 'all' system is requested, it aggregates games across all supported
  /// emulation systems (excluding Android and Music).
  static Future<List<GameModel>> loadGamesForSystem(SystemModel system) async {
    try {
      if (system.folderName == SystemFolderNames.favorites) {
        return _loadFavoriteGames();
      }

      if (system.folderName == 'all') {
        final databaseGames = (await GameRepository.getAllGames())
            .where(
              (dbGame) =>
                  dbGame.systemFolderName != 'android' &&
                  dbGame.systemFolderName != 'music',
            )
            .toList();

        final systemIds = databaseGames
            .map((g) => g.appSystemId)
            .whereType<String>()
            .toSet();

        final settingsBySystem = <String, Map<String, dynamic>>{};
        final extensionsBySystem = <String, Set<String>>{};
        for (final sid in systemIds) {
          settingsBySystem[sid] = await SystemRepository.getSystemSettings(sid);
          final exts = await SystemRepository.getExtensionsForSystem(sid);
          extensionsBySystem[sid] = exts.map((e) => e.toLowerCase()).toSet();
        }

        return databaseGames.map((dbGame) {
          final sid = dbGame.appSystemId ?? '';
          final settings = settingsBySystem[sid] ?? {};
          final preferFileName = (settings['prefer_file_name'] ?? 0) == 1;
          final hideExtension = (settings['hide_extension'] ?? 1) == 1;
          final hideParentheses = (settings['hide_parentheses'] ?? 1) == 1;
          final hideBrackets = (settings['hide_brackets'] ?? 1) == 1;
          final extSet = extensionsBySystem[sid] ?? {};

          final resolved = _resolveListDisplayName(
            dbGame: dbGame,
            preferFileName: preferFileName,
            hideExtension: hideExtension,
            hideParentheses: hideParentheses,
            hideBrackets: hideBrackets,
            validExtensionsSet: extSet,
          );

          return GameModel(
            romname: dbGame.filename,
            realname: dbGame.realName ?? dbGame.filename,
            name: resolved.name,
            showRomFileNameSubtitle: resolved.showRomFileNameSubtitle,
            descriptions: dbGame.descriptions,
            year: dbGame.year ?? '',
            developer: dbGame.developer ?? '',
            publisher: dbGame.publisher ?? '',
            genre: dbGame.genre ?? '',
            players: dbGame.players ?? '',
            rating: dbGame.rating ?? 0.0,
            isFavorite: dbGame.isFavorite,
            lastPlayed: dbGame.lastPlayed,
            playTime: dbGame.playTime,
            romPath: dbGame.romPath,
            emulatorName: dbGame.emulatorName,
            coreName: dbGame.coreName,
            raHash: dbGame.raHash,
            systemFolderName: dbGame.systemFolderName,
            systemRealName: dbGame.systemRealName,
            cloudSyncEnabled: dbGame.cloudSyncEnabled,
            titleId: dbGame.titleId,
            titleName: dbGame.titleName,
          );
        }).toList();
      }

      if (system.id == null) {
        return [];
      }

      final databaseGames = await GameRepository.getGamesBySystem(system.id!);
      final validExtensions = await SystemRepository.getExtensionsForSystem(
        system.id!,
      );

      final settings = await SystemRepository.getSystemSettings(system.id!);
      final preferFileName = (settings['prefer_file_name'] ?? 0) == 1;
      final hideExtension = (settings['hide_extension'] ?? 1) == 1;
      final hideParentheses = (settings['hide_parentheses'] ?? 1) == 1;
      final hideBrackets = (settings['hide_brackets'] ?? 1) == 1;

      final validExtensionsSet = validExtensions
          .map((e) => e.toLowerCase())
          .toSet();

      final games = databaseGames.map((dbGame) {
        final resolved = _resolveListDisplayName(
          dbGame: dbGame,
          preferFileName: preferFileName,
          hideExtension: hideExtension,
          hideParentheses: hideParentheses,
          hideBrackets: hideBrackets,
          validExtensionsSet: validExtensionsSet,
        );

        return GameModel(
          romname: dbGame.filename,
          realname: dbGame.realName ?? dbGame.filename,
          name: resolved.name,
          showRomFileNameSubtitle: resolved.showRomFileNameSubtitle,
          descriptions: dbGame.descriptions,
          year: dbGame.year ?? '',
          developer: dbGame.developer ?? '',
          publisher: dbGame.publisher ?? '',
          genre: dbGame.genre ?? '',
          players: dbGame.players ?? '',
          rating: dbGame.rating ?? 0.0,
          isFavorite: dbGame.isFavorite,
          lastPlayed: dbGame.lastPlayed,
          playTime: dbGame.playTime,
          romPath: dbGame.romPath,
          emulatorName: dbGame.emulatorName,
          coreName: dbGame.coreName,
          raHash: dbGame.raHash,
          systemFolderName: system.folderName,
          cloudSyncEnabled: dbGame.cloudSyncEnabled,
          titleId: dbGame.titleId,
          titleName: dbGame.titleName,
        );
      }).toList();

      return games;
    } catch (e) {
      _log.e('Error loading games for ${system.realName}: $e');
      return [];
    }
  }

  static Future<List<GameModel>> _loadFavoriteGames() async {
    final databaseGames = await GameRepository.getFavoriteGames();

    final systemIds = databaseGames
        .map((g) => g.appSystemId)
        .whereType<String>()
        .toSet();

    final settingsBySystem = <String, Map<String, dynamic>>{};
    final extensionsBySystem = <String, Set<String>>{};
    for (final sid in systemIds) {
      settingsBySystem[sid] = await SystemRepository.getSystemSettings(sid);
      final exts = await SystemRepository.getExtensionsForSystem(sid);
      extensionsBySystem[sid] = exts.map((e) => e.toLowerCase()).toSet();
    }

    return databaseGames.map((dbGame) {
      final sid = dbGame.appSystemId ?? '';
      final settings = settingsBySystem[sid] ?? {};
      final preferFileName = (settings['prefer_file_name'] ?? 0) == 1;
      final hideExtension = (settings['hide_extension'] ?? 1) == 1;
      final hideParentheses = (settings['hide_parentheses'] ?? 1) == 1;
      final hideBrackets = (settings['hide_brackets'] ?? 1) == 1;
      final extSet = extensionsBySystem[sid] ?? {};

      final resolved = _resolveListDisplayName(
        dbGame: dbGame,
        preferFileName: preferFileName,
        hideExtension: hideExtension,
        hideParentheses: hideParentheses,
        hideBrackets: hideBrackets,
        validExtensionsSet: extSet,
      );

      return GameModel(
        romname: dbGame.filename,
        realname: dbGame.realName ?? dbGame.filename,
        name: resolved.name,
        showRomFileNameSubtitle: resolved.showRomFileNameSubtitle,
        descriptions: dbGame.descriptions,
        year: dbGame.year ?? '',
        developer: dbGame.developer ?? '',
        publisher: dbGame.publisher ?? '',
        genre: dbGame.genre ?? '',
        players: dbGame.players ?? '',
        rating: dbGame.rating ?? 0.0,
        isFavorite: dbGame.isFavorite,
        lastPlayed: dbGame.lastPlayed,
        playTime: dbGame.playTime,
        romPath: dbGame.romPath,
        emulatorName: dbGame.emulatorName,
        coreName: dbGame.coreName,
        raHash: dbGame.raHash,
        systemFolderName: dbGame.systemFolderName,
        systemRealName: dbGame.systemRealName,
        cloudSyncEnabled: dbGame.cloudSyncEnabled,
        titleId: dbGame.titleId,
        titleName: dbGame.titleName,
      );
    }).toList();
  }

  /// Fetches detailed metadata for a specific game instance.
  static Future<GameModel?> getGameDetails(
    SystemModel system,
    String romName,
  ) async {
    try {
      if (system.id == null) return null;

      final dbGame = await GameRepository.getSingleGame(system.id!, romName);
      if (dbGame == null) return null;

      final settings = await SystemRepository.getSystemSettings(system.id!);
      final preferFileName = (settings['prefer_file_name'] ?? 0) == 1;
      final hideExtension = (settings['hide_extension'] ?? 1) == 1;
      final hideParentheses = (settings['hide_parentheses'] ?? 1) == 1;
      final hideBrackets = (settings['hide_brackets'] ?? 1) == 1;
      final validExtensions = await SystemRepository.getExtensionsForSystem(
        system.id!,
      );
      final validExtensionsSet = validExtensions
          .map((e) => e.toLowerCase())
          .toSet();

      final resolved = _resolveListDisplayName(
        dbGame: dbGame,
        preferFileName: preferFileName,
        hideExtension: hideExtension,
        hideParentheses: hideParentheses,
        hideBrackets: hideBrackets,
        validExtensionsSet: validExtensionsSet,
      );

      return GameModel(
        romname: dbGame.filename,
        realname: dbGame.realName ?? dbGame.filename,
        name: resolved.name,
        showRomFileNameSubtitle: resolved.showRomFileNameSubtitle,
        descriptions: dbGame.descriptions,
        year: dbGame.year ?? '',
        developer: dbGame.developer ?? '',
        publisher: dbGame.publisher ?? '',
        genre: dbGame.genre ?? '',
        players: dbGame.players ?? '',
        rating: dbGame.rating ?? 0.0,
        isFavorite: dbGame.isFavorite,
        lastPlayed: dbGame.lastPlayed,
        playTime: dbGame.playTime,
        romPath: dbGame.romPath,
        emulatorName: dbGame.emulatorName,
        coreName: dbGame.coreName,
        raHash: dbGame.raHash,
        systemFolderName: system.folderName,
        cloudSyncEnabled: dbGame.cloudSyncEnabled,
        titleId: dbGame.titleId,
        titleName: dbGame.titleName,
      );
    } catch (e) {
      _log.e('Error loading game details for $romName: $e');
      return null;
    }
  }

  /// Groups a list of games by their genre metadata.
  static Map<String, List<GameModel>> groupGamesByGenre(List<GameModel> games) {
    Map<String, List<GameModel>> grouped = {};

    for (var game in games) {
      final genre = game.genre.isEmpty ? 'Unknown' : game.genre;
      if (!grouped.containsKey(genre)) {
        grouped[genre] = [];
      }
      grouped[genre]!.add(game);
    }

    return grouped;
  }

  /// Filters a list of games to return only those marked as favorites.
  static List<GameModel> getFavoriteGames(List<GameModel> games) {
    return games.where((game) => game.isFavorite ?? false).toList();
  }

  /// Filters and sorts a list of games to return the 10 most recently played instances.
  static List<GameModel> getRecentlyPlayedGames(List<GameModel> games) {
    final playedGames = games.where((game) => game.lastPlayed != null).toList();
    playedGames.sort((a, b) => b.lastPlayed!.compareTo(a.lastPlayed!));
    return playedGames.take(10).toList();
  }

  /// Toggles the favorite status of a game in the persistent database.
  static Future<void> toggleFavorite(GameModel game) async {
    if (game.romPath == null) return;
    await GameRepository.toggleRomFavoriteByPath(game.romPath!);
  }

  /// Records a new play instance for a game in the persistent database.
  static Future<void> recordGamePlayed(GameModel game) async {
    if (game.romPath == null) return;
    await GameRepository.recordRomPlayedByPath(game.romPath!);
  }

  /// Verifies if a valid screenshots folder exists for the specified system.
  static bool hasScreenshotsFolder(String systemFolderName) {
    final fileProvider = FileProvider();
    if (fileProvider.isInitialized) {
      final screenshotsPath = path.join(
        fileProvider.mediaPath ?? 'media',
        'screenshots',
        systemFolderName,
      );
      return Directory(screenshotsPath).existsSync();
    }
    final screenshotsPath = path.join('media', 'screenshots', systemFolderName);
    return Directory(screenshotsPath).existsSync();
  }

  /// Registers the initiation of a game session and initializes tracking state.
  static void _registerGameLaunch(
    SystemModel system,
    GameModel game, [
    String? emulatorExeName,
  ]) {
    _isGameLaunched = true;
    _gameLaunchTime = DateTime.now();
    _lastPlaytimeSave = _gameLaunchTime;
    _launchedEmulatorExe = emulatorExeName;
    _currentGameSystem = system;
    _currentGame = game;

    if (Platform.isAndroid) {
      GameSessionPersistence.saveGameSession(
        systemFolderName: system.folderName,
        filename: game.romname,
        startTimestamp: _gameLaunchTime!.millisecondsSinceEpoch,
      );
    }

    _startPlaytimeTimer();
  }

  /// Starts the periodic timer for incremental playtime persistence.
  static void _startPlaytimeTimer() {
    _playtimeTimer?.cancel();

    _playtimeTimer = Timer.periodic(const Duration(seconds: 10), (timer) {
      if (_isGameLaunched &&
          _gameLaunchTime != null &&
          _lastPlaytimeSave != null &&
          _currentGameSystem != null &&
          _currentGame != null) {
        final now = DateTime.now();
        final elapsedSinceLastSave = now
            .difference(_lastPlaytimeSave!)
            .inSeconds;

        if (elapsedSinceLastSave > 0) {
          _savePlayTime(
            _currentGameSystem!,
            _currentGame!,
            elapsedSinceLastSave,
          );
          _lastPlaytimeSave = now;
        }
      }
    });
  }

  static void _stopPlaytimeTimer() {
    _playtimeTimer?.cancel();
    _playtimeTimer = null;
  }

  /// Checks if the default emulator (RetroArch) is currently running on the host system.
  static Future<bool> _isDefaultEmulatorRunning() async {
    if (Platform.isWindows) return await _isProcessRunning('retroarch.exe');
    if (Platform.isLinux || Platform.isMacOS) {
      return await _isProcessRunningUnix('retroarch');
    }
    return false;
  }

  /// Checks for a running process on Windows using the tasklist command.
  static Future<bool> _isProcessRunning(String processName) async {
    if (!Platform.isWindows) return false;

    try {
      final result = await Process.run('tasklist', [
        '/FI',
        'IMAGENAME eq $processName',
        '/NH',
      ]);
      return result.stdout.toString().toLowerCase().contains(
        processName.toLowerCase(),
      );
    } catch (e) {
      _log.e('Error checking if $processName is running: $e');
      return false;
    }
  }

  /// Checks for a running process on Unix-like systems using the pgrep command.
  static Future<bool> _isProcessRunningUnix(String processName) async {
    if (!Platform.isLinux && !Platform.isMacOS) return false;

    try {
      final result = await Process.run('pgrep', ['-i', '-f', processName]);
      return result.exitCode == 0;
    } catch (e) {
      _log.e('Error checking if $processName is running (unix): $e');
      return false;
    }
  }

  /// Gracefully terminates the active game session and finalizes playtime tracking.
  static Future<void> endGameSession() async {
    if (!_isGameLaunched) return;

    if (_gameLaunchTime != null &&
        _lastPlaytimeSave != null &&
        _currentGameSystem != null &&
        _currentGame != null) {
      final now = DateTime.now();
      final elapsedSinceLastSave = now.difference(_lastPlaytimeSave!).inSeconds;
      if (elapsedSinceLastSave > 0) {
        await _savePlayTime(
          _currentGameSystem!,
          _currentGame!,
          elapsedSinceLastSave,
        );
      }
    }

    _stopPlaytimeTimer();

    if (Platform.isAndroid) {
      const platform = MethodChannel('com.neogamelab.neostation/game');
      await platform.invokeMethod('setGamepadBlock', {'block': false});
      GameSessionPersistence.clearGameSession();
    } else if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
      if (_onProcessExitCallback != null) {
        _onProcessExitCallback!();
      }
    }

    _isGameLaunched = false;
    _gameLaunchTime = null;
    _lastPlaytimeSave = null;
    _launchedEmulatorExe = null;
    _currentGameSystem = null;
    _currentGame = null;
  }

  /// Handles application re-entry (foregrounding) to detect session termination.
  static Future<void> handleAppResumed() async {
    if (_isGameLaunched) {
      if (Platform.isLinux) return;

      final isDesktop =
          Platform.isWindows || Platform.isLinux || Platform.isMacOS;
      final gracePeriod = isDesktop ? 10 : 2;
      final timeSinceLaunch = DateTime.now().difference(_gameLaunchTime!);

      if (timeSinceLaunch.inSeconds > gracePeriod) {
        bool emulatorStillRunning = false;

        if (_launchedEmulatorExe != null) {
          emulatorStillRunning = await _isProcessRunning(_launchedEmulatorExe!);
        } else {
          emulatorStillRunning = await _isDefaultEmulatorRunning();
        }

        if (!emulatorStillRunning) {
          _log.i(
            'GameService: Emulator process not detected after grace period. Ending session.',
          );
          await endGameSession();
        }
      }
    } else {
      GamepadNavigationManager.reactivate();
    }
  }

  /// High-level emulator status check.
  static Future<bool> isEmulatorRunning([String? processName]) async {
    if (processName != null) return await isProcessRunning(processName);
    return await _isDefaultEmulatorRunning();
  }

  static String? get launchedEmulatorExe => _launchedEmulatorExe;

  /// Verifies if a process is running on desktop platforms.
  static Future<bool> isProcessRunning(String processName) async {
    if (Platform.isWindows) return await _isProcessRunning(processName);
    if (Platform.isLinux || Platform.isMacOS) {
      final unixName = processName.replaceAll(
        RegExp(r'\.exe$', caseSensitive: false),
        '',
      );
      return await _isProcessRunningUnix(unixName);
    }
    return false;
  }

  static Future<void> _savePlayTime(
    SystemModel system,
    GameModel game,
    int elapsedSeconds,
  ) async {
    try {
      await GameRepository.updatePlayTime(game.romPath!, elapsedSeconds);
    } catch (e) {
      _log.e('Error saving game time: $e');
    }
  }

  /// Computes aggregate statistics for a list of games.
  static Map<String, dynamic> getGameStats(List<GameModel> games) {
    if (games.isEmpty) {
      return {
        'total': 0,
        'genres': 0,
        'developers': 0,
        'favorites': 0,
        'played': 0,
        'averageRating': 0.0,
      };
    }

    final genres = games.map((g) => g.genre).where((g) => g.isNotEmpty).toSet();
    final developers = games
        .map((g) => g.developer)
        .where((d) => d.isNotEmpty)
        .toSet();
    final favorites = games.where((g) => g.isFavorite == true).length;
    final played = games.where((g) => g.lastPlayed != null).length;

    final ratingsWithValue = games.map((g) => g.rating).where((r) => r > 0);
    double averageRating = 0.0;
    if (ratingsWithValue.isNotEmpty) {
      averageRating =
          ratingsWithValue.reduce((a, b) => a + b) / ratingsWithValue.length;
    }

    return {
      'total': games.length,
      'genres': genres.length,
      'developers': developers.length,
      'favorites': favorites,
      'played': played,
      'averageRating': averageRating,
    };
  }

  /// Core logic for launching a game session across all supported platforms.
  ///
  /// Performs pre-launch validations (ROM existence, system config), resolves the
  /// optimal emulator/player, and initiates the execution process.
  static Future<GameLaunchResult> launchGame(
    BuildContext context,
    SystemModel system,
    GameModel game,
  ) async {
    try {
      if (Platform.isAndroid && (system.folderName == 'android')) {
        if (game.romPath == null) {
          return GameLaunchResult.failure(
            AppLocale.packageNameMissing.getString(context),
          );
        }

        _registerGameLaunch(system, game, 'android_app');
        await recordGamePlayed(game);

        final success = await AndroidService.launchPackage(game.romPath!);
        if (!context.mounted) return GameLaunchResult.failure('', '');
        if (success) {
          return GameLaunchResult.success();
        } else {
          return GameLaunchResult.failure(
            AppLocale.failedToLaunchAndroidApp.getString(context),
            game.romPath,
          );
        }
      }

      bool romExists = false;
      if (game.romPath != null) {
        if (Platform.isAndroid && game.romPath!.startsWith('content://')) {
          romExists = true;
        } else {
          romExists = await File(game.romPath!).exists();
        }
      }
      if (!context.mounted) return GameLaunchResult.failure('', '');

      if (!romExists) {
        return GameLaunchResult.failure(
          AppLocale.romFileNotFound.getString(context),
          game.romPath ?? AppLocale.noData.getString(context),
        );
      }

      final configFileName = '${system.folderName}.json';
      final bool configLoaded = await LauncherService.instance.loadSystemConfig(
        configFileName,
      );

      if (configLoaded) {
        String? preferredPlayerId = game.emulatorName;

        if (preferredPlayerId == null) {
          final defaultEmu =
              await EmulatorRepository.getDefaultEmulatorForSystem(system.id!);
          if (defaultEmu != null) {
            preferredPlayerId = defaultEmu.uniqueId;
          }
        }

        final launchCmd = LauncherService.instance.getLaunchCommand(
          system,
          game,
          preferredPlayerId,
        );

        if (launchCmd.isNotEmpty) {
          if (Platform.isAndroid &&
              launchCmd.containsKey('package') &&
              launchCmd.containsKey('activity')) {
            try {
              GamepadNavigationManager.reactivate();

              const platform = MethodChannel('com.neogamelab.neostation/game');
              await platform.invokeMethod('setGamepadBlock', {'block': true});

              var packageName = launchCmd['package'];
              final activityName = launchCmd['activity'];
              final action = launchCmd['action'];
              final category = launchCmd['category'];
              final data = launchCmd['data'];
              final type = launchCmd['type'];

              if (packageName.toString().startsWith('com.retroarch')) {
                try {
                  final defaultEmu =
                      await EmulatorRepository.getDefaultEmulatorForSystem(
                        system.id!,
                      );
                  if (defaultEmu != null &&
                      defaultEmu.androidPackageName != null &&
                      defaultEmu.androidPackageName!.isNotEmpty) {
                    final userPackage = defaultEmu.androidPackageName!;
                    if (userPackage != packageName) {
                      packageName = userPackage;
                    }
                  }
                } catch (e) {
                  _log.e('Error overriding RetroArch package: $e');
                }
              }

              List<Map<String, dynamic>> extrasList = [];

              if (launchCmd.containsKey('extras') &&
                  launchCmd['extras'] is List) {
                for (final item in launchCmd['extras'] as List) {
                  if (item is Map) {
                    extrasList.add(Map<String, dynamic>.from(item));
                  }
                }
              } else {
                final argsStr = launchCmd['args']?.toString() ?? '';
                if (argsStr.isNotEmpty) {
                  final extrasMap = _parseArgsToExtras(argsStr);
                  extrasMap.forEach((k, v) {
                    String type = 'string';
                    if (v is int) type = 'int';
                    if (v is bool) type = 'bool';
                    extrasList.add({'key': k, 'value': v, 'type': type});
                  });
                }
              }

              if (packageName.toString() != 'com.retroarch' &&
                  packageName.toString().startsWith('com.retroarch')) {
                for (var extra in extrasList) {
                  if (extra['key'] == 'CONFIGFILE') {
                    final String currentPath = extra['value'].toString();
                    if (currentPath.contains('/com.retroarch/')) {
                      final newPath = currentPath.replaceAll(
                        '/com.retroarch/',
                        '/$packageName/',
                      );
                      extra['value'] = newPath;
                    }
                  }
                }
              }

              final result = await platform
                  .invokeMethod('launchGenericIntent', {
                    'package': packageName,
                    'activity': activityName,
                    'action': action,
                    'category': category,
                    'data': data,
                    'type': type,
                    'extras': extrasList,
                    'activity_flags': launchCmd['activity_flags'] != null
                        ? List<String>.from(launchCmd['activity_flags'] as List)
                        : <String>[],
                  });

              if (result == true) {
                _registerGameLaunch(system, game);
                await recordGamePlayed(game);
                return GameLaunchResult.success();
              } else {
                GamepadNavigationManager.reactivate();
                await platform.invokeMethod('setGamepadBlock', {
                  'block': false,
                });
                if (!context.mounted) return GameLaunchResult.failure('', '');
                return GameLaunchResult.failure(
                  AppLocale.launchFailed.getString(context),
                  AppLocale.error.getString(context),
                );
              }
            } catch (e) {
              _log.e('JSON Launch Error: $e');
              GamepadNavigationManager.reactivate();
              const platform = MethodChannel('com.neogamelab.neostation/game');
              await platform.invokeMethod('setGamepadBlock', {'block': false});
            }
          }

          if ((Platform.isWindows || Platform.isLinux || Platform.isMacOS) &&
              launchCmd.containsKey('executable')) {
            if (!context.mounted) return GameLaunchResult.failure('', '');
            return await _launchGameDesktopFromConfig(
              context,
              launchCmd,
              system,
              game,
            );
          }
        }
      }

      final standaloneEmulator = await _getStandaloneEmulatorForSystem(system);
      if (!context.mounted) return GameLaunchResult.failure('', '');

      if (standaloneEmulator != null) {
        if (Platform.isAndroid) {
          return await _launchStandaloneAndroid(
            context,
            system,
            game,
            standaloneEmulator,
          );
        } else if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
          return await _launchStandaloneDesktop(
            context,
            system,
            game,
            standaloneEmulator,
          );
        } else {
          return GameLaunchResult.failure(
            AppLocale.platformNotSupported.getString(context),
            Platform.operatingSystem,
          );
        }
      }

      final coreName = await _getCoreForSystem(system);
      if (!context.mounted) return GameLaunchResult.failure('', '');

      if (coreName == null) {
        return GameLaunchResult.failure(
          AppLocale.coreNotConfigured.getString(context),
          'No core found for system ${system.folderName}',
        );
      }

      if (Platform.isAndroid) {
        return await _launchGameAndroid(context, system, game, coreName);
      } else if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
        return await _launchGameDesktop(context, system, game, coreName);
      } else {
        _log.e('Platform not supported: ${Platform.operatingSystem}');
        return GameLaunchResult.failure(
          AppLocale.platformNotSupported.getString(context),
          Platform.operatingSystem,
        );
      }
    } catch (e) {
      _log.e('Error launching the game: $e');
      GamepadNavigationManager.reactivate();
      if (Platform.isAndroid) {
        const platform = MethodChannel('com.neogamelab.neostation/game');
        await platform.invokeMethod('setGamepadBlock', {'block': false});
      }
      if (!context.mounted) return GameLaunchResult.failure('', '');
      return GameLaunchResult.failure(
        AppLocale.anErrorOccurred.getString(context),
        e.toString(),
      );
    }
  }

  /// Internal logic for launching RetroArch cores on Android.
  static Future<GameLaunchResult> _launchGameAndroid(
    BuildContext context,
    SystemModel system,
    GameModel game,
    String coreName,
  ) async {
    try {
      final packages = await EmulatorRepository.getAndroidRetroArchPackages();

      if (packages.isNotEmpty) {
        try {
          final defaultEmu =
              await EmulatorRepository.getDefaultEmulatorForSystem(system.id!);
          if (defaultEmu != null &&
              defaultEmu.androidPackageName != null &&
              defaultEmu.androidPackageName!.isNotEmpty) {
            final specificPackage = defaultEmu.androidPackageName!;
            _log.i(
              'Android: User selected specific RetroArch package: $specificPackage',
            );
            packages.insert(0, specificPackage);
          }
        } catch (e) {
          _log.e('Error getting default emulator package: $e');
        }
      }

      const platform = MethodChannel('com.neogamelab.neostation/game');
      GamepadNavigationManager.reactivate();
      await platform.invokeMethod('setGamepadBlock', {'block': true});

      String packageName = 'com.retroarch.aarch64';
      if (packages.isNotEmpty) {
        packageName = packages.first;
      }

      final activityName =
          'com.retroarch.browser.retroactivity.RetroActivityFuture';

      final result = await platform.invokeMethod('launchGenericIntent', {
        'package': packageName,
        'activity': activityName,
        'action': 'android.intent.action.MAIN',
        'category': 'android.intent.category.LAUNCHER',
        'extras': [
          {
            'key': 'ROM',
            'value': (game.romPath?.startsWith('content://') == true)
                ? 'neostation-realpath:${game.romPath}'
                : game.romPath ?? '',
            'type': 'string',
          },
          {'key': 'LIBRETRO', 'value': coreName, 'type': 'string'},
        ],
      });

      if (result == true) {
        await recordGamePlayed(game);
        _registerGameLaunch(system, game);
        return GameLaunchResult.success();
      } else {
        GamepadNavigationManager.reactivate();
        const platform = MethodChannel('com.neogamelab.neostation/game');
        await platform.invokeMethod('setGamepadBlock', {'block': false});
        if (!context.mounted) return GameLaunchResult.failure('', '');
        return GameLaunchResult.failure(
          AppLocale.launchFailed.getString(context),
          'RetroArch returned false',
        );
      }
    } catch (e) {
      GamepadNavigationManager.reactivate();
      const platform = MethodChannel('com.neogamelab.neostation/game');
      await platform.invokeMethod('setGamepadBlock', {'block': false});
      if (!context.mounted) return GameLaunchResult.failure('', '');

      if (e is PlatformException) {
        if (e.code == "CORE_NOT_FOUND") {
          return GameLaunchResult.failure(
            AppLocale.coreNotInstalled
                .getString(context)
                .replaceFirst('{name}', coreName),
            'Please install the core from RetroArch\'s Online Updater',
          );
        } else {
          return GameLaunchResult.failure(
            e.message ?? AppLocale.error.getString(context),
            e.details?.toString(),
          );
        }
      } else {
        _log.e('Error en MethodChannel: $e');
        return GameLaunchResult.failure(
          AppLocale.launchFailed.getString(context),
          e.toString(),
        );
      }
    }
  }

  /// Internal logic for launching RetroArch cores on Desktop.
  static Future<GameLaunchResult> _launchGameDesktop(
    BuildContext context,
    SystemModel system,
    GameModel game,
    String coreName,
  ) async {
    try {
      final detectedEmulators =
          await EmulatorRepository.getUserDetectedEmulators();
      final retroArch = detectedEmulators['RetroArch'];
      if (!context.mounted) return GameLaunchResult.failure('', '');
      if (retroArch == null) {
        return GameLaunchResult.failure(
          AppLocale.retroArchNotFound.getString(context),
          'RetroArch is not detected on your system. Please install RetroArch.',
        );
      }

      bool raExists = false;
      if (Platform.isMacOS && retroArch.path.endsWith('.app')) {
        raExists = await Directory(retroArch.path).exists();
      } else {
        raExists = await File(retroArch.path).exists();
      }
      if (!context.mounted) return GameLaunchResult.failure('', '');

      if (!raExists) {
        _log.e(
          'RetroArch does not exist at the specified path: ${retroArch.path}',
        );
        return GameLaunchResult.failure(
          AppLocale.retroArchExecutableNotFound.getString(context),
          'Path: ${retroArch.path}',
        );
      }

      final coresPath = await _getRetroArchCoresDirectory(retroArch);
      final coresDirectory = Directory(coresPath);
      if (!await coresDirectory.exists()) {
        if (!context.mounted) return GameLaunchResult.failure('', '');
        _log.e('The cores directory does not exist: $coresPath');
        return GameLaunchResult.failure(
          AppLocale.coresDirectoryNotFound.getString(context),
          'Path: $coresPath',
        );
      }

      final coreFullPath = await _getCoreFullPath(coreName);
      if (!context.mounted) return GameLaunchResult.failure('', '');
      if (coreFullPath == null) {
        return GameLaunchResult.failure(
          AppLocale.coreNotFound.getString(context),
          'Could not locate core: $coreName',
        );
      }

      final coreFile = File(coreFullPath);
      if (!await coreFile.exists()) {
        if (!context.mounted) return GameLaunchResult.failure('', '');
        return GameLaunchResult.failure(
          AppLocale.coreFileNotFound.getString(context),
          'Path: $coreFullPath',
        );
      }

      Process process;

      if (Platform.isMacOS) {
        String executable = retroArch.path;
        if (executable.endsWith('.app')) {
          executable = path.join(executable, 'Contents', 'MacOS', 'RetroArch');
        }

        final args = ['-L', coreFullPath, game.romPath!];
        final env = Map<String, String>.from(Platform.environment);
        env['HOME'] = ConfigService.getRealHomePath();

        process = await Process.start(executable, args, environment: env);
      } else {
        String executable = retroArch.path;
        final args = ['-f', '-L', coreFullPath, game.romPath!];

        process = await Process.start(executable, args);
      }

      process.stdout.listen((_) {});
      process.stderr.listen((_) {});

      GamepadNavigationManager.deactivateAll();

      process.exitCode
          .then((exitCode) async {
            _log.i('RetroArch exited with code: $exitCode');
            await Future.delayed(Duration(seconds: 2));
            bool stillRunning = await _isDefaultEmulatorRunning();

            if (!stillRunning &&
                (Platform.isWindows || Platform.isLinux || Platform.isMacOS)) {
              endGameSession();
            }
          })
          .catchError((error) {
            _log.e('Error monitoring RetroArch: $error');
            if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
              endGameSession();
            }
          });

      await recordGamePlayed(game);
      _registerGameLaunch(system, game);

      return GameLaunchResult.success();
    } catch (e) {
      _log.e('Error launching game on ${Platform.operatingSystem}: $e');
      GamepadNavigationManager.reactivate();
      if (!context.mounted) return GameLaunchResult.failure('', '');
      return GameLaunchResult.failure(
        AppLocale.failedToLaunchRetroArch.getString(context),
        e.toString(),
      );
    }
  }

  /// Internal logic for launching games using a custom JSON configuration profile.
  static Future<GameLaunchResult> _launchGameDesktopFromConfig(
    BuildContext context,
    Map<String, dynamic> launchCmd,
    SystemModel system,
    GameModel game,
  ) async {
    try {
      String executable = launchCmd['executable'].toString();

      if ((Platform.isWindows || Platform.isLinux) &&
          !await File(executable).exists()) {
        final detected = await EmulatorRepository.getUserDetectedEmulators();

        if (executable.toLowerCase().contains('retroarch')) {
          final ra = detected['RetroArch'];
          if (ra != null) {
            executable = ra.path;
          }
        } else {
          String? resolvedPath;
          final uniqueId = launchCmd['unique_id']?.toString();
          if (uniqueId != null) {
            for (final emu in detected.values) {
              if (emu.uniqueId == uniqueId &&
                  emu.detected &&
                  emu.path.isNotEmpty) {
                resolvedPath = emu.path;
                break;
              }
            }
          }

          if (resolvedPath == null) {
            final playerName = launchCmd['player_name']?.toString();
            if (playerName != null) {
              final emu = detected[playerName];
              if (emu != null && emu.detected && emu.path.isNotEmpty) {
                resolvedPath = emu.path;
              }
            }
          }

          if (resolvedPath != null) {
            executable = resolvedPath;
          }
        }
      } else if (Platform.isMacOS &&
          executable.toLowerCase().contains('retroarch')) {
        final detected = await EmulatorRepository.getUserDetectedEmulators();
        final ra = detected['RetroArch'];
        if (ra != null) {
          executable = ra.path;
          if (executable.endsWith('.app')) {
            executable = path.join(
              executable,
              'Contents',
              'MacOS',
              'RetroArch',
            );
          }
        }
      }

      if ((Platform.isWindows || Platform.isLinux || Platform.isMacOS) &&
          !await File(executable).exists()) {
        if (!context.mounted) return GameLaunchResult.failure('', '');
        _log.e('Final check failed: $executable not found');
        return GameLaunchResult.failure(
          AppLocale.executableNotFound.getString(context),
          'Could not find the emulator or game executable at:\n$executable\n\nPlease check your System Settings or Emulator Configuration.',
        );
      }

      final argsStr = launchCmd['args']?.toString() ?? '';
      final args = LauncherService.splitArgs(argsStr);

      final env = Map<String, String>.from(Platform.environment);
      if (Platform.isMacOS) {
        env['HOME'] = ConfigService.getRealHomePath();
      }

      final process = await Process.start(executable, args, environment: env);

      process.stdout.listen((_) {});
      process.stderr.listen((_) {});

      GamepadNavigationManager.deactivateAll();

      process.exitCode
          .then((exitCode) async {
            _log.i('Process exited with code: $exitCode');
            await Future.delayed(Duration(seconds: 2));
            bool stillRunning = false;
            if (_launchedEmulatorExe != null) {
              stillRunning = await _isProcessRunning(_launchedEmulatorExe!);
            }

            if (!stillRunning &&
                (Platform.isWindows || Platform.isLinux || Platform.isMacOS)) {
              endGameSession();
            }
          })
          .catchError((err) {
            if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
              endGameSession();
            }
          });

      await recordGamePlayed(game);

      String? launchedExeName;
      if (!executable.toLowerCase().contains('retroarch')) {
        launchedExeName = path.basename(executable);
      }

      _registerGameLaunch(system, game, launchedExeName);

      return GameLaunchResult.success();
    } catch (e) {
      _log.e('Error launching via config: $e');
      GamepadNavigationManager.reactivate();
      if (!context.mounted) return GameLaunchResult.failure('', '');
      return GameLaunchResult.failure(
        AppLocale.launchFailed.getString(context),
        e.toString(),
      );
    }
  }

  /// Resolves the identifier for the core assigned to the given system.
  static Future<String?> _getCoreForSystem(SystemModel system) async {
    final emulator = await EmulatorRepository.getDefaultEmulatorForSystem(
      system.id!,
    );

    if (emulator != null) {
      final coreFilename = emulator['core_filename'].toString();

      if (Platform.isAndroid) {
        return coreFilename;
      } else {
        String coreName = coreFilename;
        if (coreName.endsWith('.dll')) {
          coreName = coreName.substring(0, coreName.length - 4);
        } else if (coreName.endsWith('.so')) {
          coreName = coreName.substring(0, coreName.length - 3);
        }

        return coreName;
      }
    }

    _log.e('No default emulator found for system ${system.folderName}');
    return null;
  }

  /// Retrieves the user-assigned standalone emulator for a system if applicable.
  static Future<Map<String, dynamic>?> _getStandaloneEmulatorForSystem(
    SystemModel system,
  ) async {
    if (system.id == null) return null;

    try {
      final standalones =
          await EmulatorRepository.getStandaloneEmulatorsBySystemId(system.id!);

      if (standalones.isEmpty) {
        return null;
      }

      Map<String, dynamic>? userDefault;
      for (final standalone in standalones) {
        if (standalone['is_user_default'] == 1) {
          userDefault = standalone;
          break;
        }
      }

      if (userDefault == null) {
        return null;
      }

      if (!Platform.isAndroid) {
        final path = userDefault['emulator_path']?.toString();
        if (path == null || path.isEmpty) {
          return null;
        }

        final file = File(path);
        if (!await file.exists()) {
          return null;
        }
      }

      return userDefault;
    } catch (e) {
      _log.e('Error getting standalone emulator: $e');
      return null;
    }
  }

  /// Internal logic for launching standalone emulators on Android.
  static Future<GameLaunchResult> _launchStandaloneAndroid(
    BuildContext context,
    SystemModel system,
    GameModel game,
    Map<String, dynamic> emulator,
  ) async {
    try {
      final packageName = emulator['android_package_name']?.toString();
      final activityName = emulator['android_activity_name']?.toString();

      if (packageName == null || activityName == null) {
        _log.e('Missing Android package/activity for standalone emulator');
        return GameLaunchResult.failure(
          AppLocale.emulatorNotConfigured.getString(context),
          'Missing Android package or activity name for ${emulator['name']}',
        );
      }

      const platform = MethodChannel('com.neogamelab.neostation/game');
      GamepadNavigationManager.reactivate();
      await platform.invokeMethod('setGamepadBlock', {'block': true});

      final result = await platform.invokeMethod('launchStandaloneEmulator', {
        'packageName': packageName,
        'activityName': activityName,
        'romPath': game.romPath!,
      });

      if (result == true) {
        await recordGamePlayed(game);
        _registerGameLaunch(system, game);
        return GameLaunchResult.success();
      } else {
        _log.e('Failed to launch standalone emulator on Android');
        GamepadNavigationManager.reactivate();
        await platform.invokeMethod('setGamepadBlock', {'block': false});
        if (!context.mounted) return GameLaunchResult.failure('', '');
        return GameLaunchResult.failure(
          AppLocale.failedToLaunchStandalone
              .getString(context)
              .replaceFirst('{name}', emulator['name']),
          'The emulator may not be installed or the app is not responding',
        );
      }
    } catch (e) {
      _log.e('Error launching standalone emulator on Android: $e');
      GamepadNavigationManager.reactivate();
      const platform = MethodChannel('com.neogamelab.neostation/game');
      await platform.invokeMethod('setGamepadBlock', {'block': false});
      if (!context.mounted) return GameLaunchResult.failure('', '');

      if (e is PlatformException) {
        return GameLaunchResult.failure(
          e.message ?? 'Platform error',
          'Code: ${e.code}\nDetails: ${e.details}',
        );
      }
      return GameLaunchResult.failure(
        AppLocale.launchFailed.getString(context),
        e.toString(),
      );
    }
  }

  /// Internal logic for launching standalone emulators on Desktop.
  static Future<GameLaunchResult> _launchStandaloneDesktop(
    BuildContext context,
    SystemModel system,
    GameModel game,
    Map<String, dynamic> emulator,
  ) async {
    try {
      final emulatorPath = emulator['emulator_path']?.toString();
      final launchArgs =
          emulator['launch_arguments']?.toString() ?? '"{rom_path}"';

      if (emulatorPath == null || emulatorPath.isEmpty) {
        _log.e('Emulator path not configured');
        return GameLaunchResult.failure(
          AppLocale.emulatorNotConfigured.getString(context),
          'Path not set for ${emulator['name']}',
        );
      }

      final emulatorFile = File(emulatorPath);
      if (!await emulatorFile.exists()) {
        if (!context.mounted) return GameLaunchResult.failure('', '');
        _log.e('Emulator not found: $emulatorPath');
        return GameLaunchResult.failure(
          AppLocale.executableNotFound.getString(context),
          'Path: $emulatorPath',
        );
      }

      final romPath = game.romPath!;
      final args = launchArgs
          .replaceAll('{rom_path}', romPath)
          .replaceAll('{emulator_path}', emulatorPath);

      final argList = _parseCommandArguments(args);
      final process = await Process.start(emulatorPath, argList);

      process.stdout.listen((_) {});
      process.stderr.listen((_) {});

      GamepadNavigationManager.deactivateAll();

      process.exitCode
          .then((exitCode) async {
            _log.i('Standalone emulator exited with code: $exitCode');
            await Future.delayed(Duration(seconds: 2));
            bool stillRunning = false;
            if (_launchedEmulatorExe != null) {
              stillRunning = await _isProcessRunning(_launchedEmulatorExe!);
            }

            if (!stillRunning &&
                (Platform.isWindows || Platform.isLinux || Platform.isMacOS)) {
              endGameSession();
            }
          })
          .catchError((error) {
            _log.e('Error monitoring standalone emulator: $error');
            if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
              endGameSession();
            }
          });

      final exeName = path.basename(emulatorPath);
      _registerGameLaunch(system, game, exeName);
      await recordGamePlayed(game);

      return GameLaunchResult.success();
    } catch (e) {
      _log.e('Error launching standalone emulator: $e');
      GamepadNavigationManager.reactivate();
      if (!context.mounted) return GameLaunchResult.failure('', '');
      return GameLaunchResult.failure(
        AppLocale.failedToLaunchStandalone
            .getString(context)
            .replaceFirst('{name}', emulator['name']),
        e.toString(),
      );
    }
  }

  /// Parses a command-line argument string into an Android Intent extras map.
  static Map<String, dynamic> _parseArgsToExtras(String argsStr) {
    if (argsStr.isEmpty) return {};

    final extras = <String, dynamic>{};
    final args = _parseCommandArguments(argsStr);

    for (int i = 0; i < args.length; i++) {
      final arg = args[i];
      if (arg == '-e' || arg == '--es') {
        if (i + 2 < args.length) {
          extras[args[i + 1]] = args[i + 2];
          i += 2;
        }
      } else if (arg == '--ez') {
        if (i + 2 < args.length) {
          extras[args[i + 1]] = args[i + 2] == 'true' || args[i + 2] == '1';
          i += 2;
        }
      } else if (arg == '--ei') {
        if (i + 2 < args.length) {
          extras[args[i + 1]] = int.tryParse(args[i + 2]) ?? 0;
          i += 2;
        }
      } else if (arg == '--esa') {
        if (i + 2 < args.length) {
          extras[args[i + 1]] = args[i + 2]
              .split(',')
              .map((e) => e.trim())
              .toList();
          i += 2;
        }
      }
    }
    return extras;
  }

  /// Tokenizes a command string into discrete arguments, respecting double quotes.
  static List<String> _parseCommandArguments(String args) {
    final List<String> result = [];
    final buffer = StringBuffer();
    bool inQuotes = false;

    for (int i = 0; i < args.length; i++) {
      final char = args[i];

      if (char == '"') {
        inQuotes = !inQuotes;
      } else if (char == ' ' && !inQuotes) {
        if (buffer.isNotEmpty) {
          result.add(buffer.toString());
          buffer.clear();
        }
      } else {
        buffer.write(char);
      }
    }

    if (buffer.isNotEmpty) {
      result.add(buffer.toString());
    }

    return result;
  }

  /// Resolves the absolute path for a specific RetroArch core library.
  static Future<String?> _getCoreFullPath(String coreName) async {
    try {
      final detectedEmulators =
          await EmulatorRepository.getUserDetectedEmulators();
      final retroArch = detectedEmulators['RetroArch'];
      if (retroArch == null) return null;

      final coresDir = await _getRetroArchCoresDirectory(retroArch);

      String fullCoreName;
      if (Platform.isWindows) {
        if (coreName.endsWith('.dll')) {
          fullCoreName = coreName;
        } else if (coreName.endsWith('_libretro')) {
          fullCoreName = '$coreName.dll';
        } else {
          fullCoreName = '${coreName}_libretro.dll';
        }
      } else if (Platform.isMacOS) {
        if (coreName.endsWith('.dylib')) {
          fullCoreName = coreName;
        } else if (coreName.endsWith('_libretro')) {
          fullCoreName = '$coreName.dylib';
        } else {
          fullCoreName = '${coreName}_libretro.dylib';
        }
      } else if (Platform.isAndroid) {
        if (coreName.endsWith('.so')) {
          fullCoreName = coreName;
        } else {
          if (coreName.contains('_android')) {
            fullCoreName = '$coreName.so';
          } else if (coreName.endsWith('_libretro')) {
            fullCoreName = '${coreName}_android.so';
          } else {
            fullCoreName = '${coreName}_libretro_android.so';
          }
        }
      } else {
        if (coreName.endsWith('.so')) {
          fullCoreName = coreName;
        } else if (coreName.endsWith('_libretro')) {
          fullCoreName = '$coreName.so';
        } else {
          fullCoreName = '${coreName}_libretro.so';
        }
      }

      final corePath = path.join(coresDir, fullCoreName);

      if (await File(corePath).exists()) {
        return corePath;
      } else {
        return null;
      }
    } catch (e) {
      _log.e('Error getting core path: $e');
      return null;
    }
  }

  /// Resolves the optimal directory for RetroArch cores based on the platform and installation type.
  ///
  /// Supports Flatpak, AppImage, and standard installation discovery on Linux.
  static Future<String> _getRetroArchCoresDirectory(
    EmulatorModel retroArch,
  ) async {
    final retroArchDir = path.dirname(retroArch.path);

    if (Platform.isLinux) {
      final homeDir = Platform.environment['HOME'] ?? '';

      if (retroArch.path.contains('flatpak')) {
        return path.join(
          homeDir,
          '.var/app/org.libretro.RetroArch/config/retroarch/cores',
        );
      }

      final configCores = path.join(homeDir, '.config/retroarch/cores');
      if (await Directory(configCores).exists()) {
        return configCores;
      }

      return path.join(retroArchDir, 'cores');
    } else if (Platform.isMacOS) {
      final homeDir = ConfigService.getRealHomePath();
      return path.join(homeDir, 'Library/Application Support/RetroArch/cores');
    } else {
      return path.join(retroArchDir, 'cores');
    }
  }
}
