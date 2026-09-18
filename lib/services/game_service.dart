import 'dart:io';
import 'dart:async';
import 'package:path/path.dart' as path;
import 'package:flutter/services.dart';
import 'package:flutter/material.dart';
import '../models/game_model.dart';
import '../models/system_model.dart';
import '../providers/file_provider.dart';
import 'music_player_service.dart';
import 'game/game_list_service.dart';
import 'game/favorites_service.dart';
import 'game/game_session_manager.dart';
import 'game/game_launch_service.dart';
export 'gamepad/gamepad_navigation_manager.dart'
    show GamepadNavigationManager, NavLayer;
export 'game/game_launch_service.dart' show GameLaunchResult;

/// Thin static facade over the game domain.
///
/// Presents a stable public API (list/detail loading, favorites/stats, launch
/// execution, and session lifecycle) while delegating to focused collaborators:
/// [GameListService], [FavoritesService], [GameSessionManager], and
/// [GameLaunchService]. Holds only the Android game-lifecycle listener wiring
/// and the [onScreenStateChanged] callback slot.
class GameService {
  /// Whether a game process is currently active.
  /// Delegates to [GameSessionManager].
  static bool get isGameLaunched => GameSessionManager.isGameLaunched;

  /// Whether a game is running OR a launch is in progress. Callers reacting to
  /// an app resume should use this (not [isGameLaunched]) before clearing
  /// secondary-display in-game state, to avoid a launch-window race.
  /// Delegates to [GameSessionManager].
  static bool get isGameLaunchInProgress =>
      GameSessionManager.isGameLaunchInProgress;

  /// Opens the launch-pending window. Call when a launch is initiated, before
  /// the emulator handoff.
  /// Delegates to [GameSessionManager].
  static void beginLaunchPending() => GameSessionManager.beginLaunchPending();

  /// Closes the launch-pending window (e.g. on launch failure).
  /// Delegates to [GameSessionManager].
  static void clearLaunchPending() => GameSessionManager.clearLaunchPending();

  /// Callback for raw device screen on/off, registered by a context-aware
  /// widget so context-only services (e.g. NotificationService) can be
  /// suspended while locked. `true` = screen on, `false` = screen off.
  static void Function(bool screenOn)? onScreenStateChanged;

  /// Whether the device screen is on, mirrored from the same native bridge.
  ///
  /// A callback slot only serves one listener; this notifier serves the rest.
  /// Screens that own media need it because NeoStation runs as a HOME launcher:
  /// the activity is never paused on lock, so a preview video keeps decoding —
  /// and, with video sound on, keeps playing audio — behind a dark screen until
  /// something tears it down.
  static final ValueNotifier<bool> deviceScreenOn = ValueNotifier<bool>(true);

  /// Initializes the platform-specific listener for Android game lifecycle events.
  static void initializeAndroidGameListener() {
    if (!Platform.isAndroid) return;

    const platform = MethodChannel('com.neogamelab.neostation/game');
    platform.setMethodCallHandler((call) async {
      if (call.method == 'onGameReturned') {
        final elapsedSeconds =
            int.tryParse(call.arguments['elapsedSeconds']?.toString() ?? '0') ??
            0;

        if (GameSessionManager.onGameReturnedCallback != null) {
          GameSessionManager.onGameReturnedCallback!(elapsedSeconds);
        }
      } else if (call.method == 'onDeviceScreenOff') {
        // As a HOME launcher we are not paused on lock, so this is the only
        // reliable signal to release background resources while locked.
        deviceScreenOn.value = false;
        GameSessionManager.onDeviceScreenChanged(false);
        MusicPlayerService().appPaused();
        onScreenStateChanged?.call(false);
      } else if (call.method == 'onDeviceScreenOn') {
        // Published unconditionally: listeners that must not act behind a
        // running game (the preview video) check that themselves, and leaving
        // the notifier stuck on false would strand them after the game exits.
        deviceScreenOn.value = true;
        GameSessionManager.onDeviceScreenChanged(true);
        // Skip restore while a game owns the foreground — the game-return
        // (lifecycle resumed) path re-opens everything. Restoring here would
        // reopen the audio engine (and restart music/websocket) behind the
        // running emulator.
        if (!GameSessionManager.isGameLaunched) {
          MusicPlayerService().appResumed();
          onScreenStateChanged?.call(true);
        }
      }
    });
  }

  /// Recovers playtime from a previously interrupted game session.
  ///
  /// Handles cases where the application was terminated by the OS (Android)
  /// while a game was running.
  /// Delegates to [GameSessionManager].
  static Future<void> checkPendingGameSession() =>
      GameSessionManager.checkPendingGameSession();

  static void setOnGameReturnedCallback(Function(int) callback) =>
      GameSessionManager.setOnGameReturnedCallback(callback);

  static void clearOnGameReturnedCallback() =>
      GameSessionManager.clearOnGameReturnedCallback();

  static void setOnProcessExitCallback(Function() callback) =>
      GameSessionManager.setOnProcessExitCallback(callback);

  static void clearOnProcessExitCallback() =>
      GameSessionManager.clearOnProcessExitCallback();

  /// Retrieves games for a system with metadata formatting applied.
  /// Delegates to [GameListService].
  static Future<List<GameModel>> loadGamesForSystem(SystemModel system) =>
      GameListService.loadGamesForSystem(system);

  /// Fetches detailed metadata for a specific game.
  /// Delegates to [GameListService].
  static Future<GameModel?> getGameDetails(
    SystemModel system,
    String romName,
  ) => GameListService.getGameDetails(system, romName);

  /// Groups a list of games by their genre metadata.
  /// Delegates to [GameListService].
  static Map<String, List<GameModel>> groupGamesByGenre(
    List<GameModel> games,
  ) => GameListService.groupGamesByGenre(games);

  /// Filters a list of games to return only those marked as favorites.
  /// Delegates to [GameListService].
  static List<GameModel> getFavoriteGames(List<GameModel> games) =>
      GameListService.getFavoriteGames(games);

  /// Filters and sorts a list of games to return the 10 most recently played.
  /// Delegates to [GameListService].
  static List<GameModel> getRecentlyPlayedGames(List<GameModel> games) =>
      GameListService.getRecentlyPlayedGames(games);

  /// Toggles the favorite status of a game in the persistent database.
  /// Delegates to [FavoritesService].
  static Future<void> toggleFavorite(GameModel game) =>
      FavoritesService.toggleFavorite(game);

  /// Records a new play instance for a game in the persistent database.
  /// Delegates to [FavoritesService].
  static Future<void> recordGamePlayed(GameModel game) =>
      FavoritesService.recordGamePlayed(game);

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

  /// Gracefully terminates the active game session and finalizes playtime tracking.
  /// Delegates to [GameSessionManager].
  static Future<void> endGameSession() => GameSessionManager.endGameSession();

  /// Handles application re-entry (foregrounding) to detect session termination.
  /// Delegates to [GameLaunchService].
  static Future<void> handleAppResumed() =>
      GameLaunchService.handleAppResumed();

  /// High-level emulator status check.
  /// Delegates to [GameLaunchService].
  static Future<bool> isEmulatorRunning([String? processName]) =>
      GameLaunchService.isEmulatorRunning(processName);

  static String? get launchedEmulatorExe =>
      GameSessionManager.launchedEmulatorExe;

  /// Verifies if a process is running on desktop platforms.
  /// Delegates to [GameLaunchService].
  static Future<bool> isProcessRunning(String processName) =>
      GameLaunchService.isProcessRunning(processName);

  /// Computes aggregate statistics for a list of games.
  /// Delegates to [FavoritesService].
  static Map<String, dynamic> getGameStats(List<GameModel> games) =>
      FavoritesService.getGameStats(games);

  /// Core logic for launching a game session across all supported platforms.
  ///
  /// Performs pre-launch validations (ROM existence, system config), resolves the
  /// optimal emulator/player, and initiates the execution process.
  /// Delegates to [GameLaunchService].
  static Future<GameLaunchResult> launchGame(
    BuildContext context,
    SystemModel system,
    GameModel game,
  ) => GameLaunchService.launchGame(context, system, game);
}
