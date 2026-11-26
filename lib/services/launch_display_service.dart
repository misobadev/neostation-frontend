import 'dart:io';

import 'package:sub_screen/sub_screen.dart';

import '../data/datasources/sqlite_service.dart';
import '../models/game_model.dart';
import '../models/system_model.dart';
import 'logger_service.dart';

/// Which screen of a dual-screen handheld (AYN Thor, a Retroid Pocket with the
/// dual-screen add-on) a game opens on.
enum LaunchDisplay {
  /// The default display: the top screen on the AYN Thor.
  primary('primary'),

  /// The first other display: the bottom screen on the AYN Thor.
  secondary('secondary');

  const LaunchDisplay(this.value);

  /// Stored in `user_launch_display.display` and sent to the native launcher
  /// as `launch_display`.
  final String value;

  static LaunchDisplay? fromValue(String? value) {
    for (final display in LaunchDisplay.values) {
      if (display.value == value) return display;
    }
    return null;
  }
}

/// Per-system and per-game launch screen.
///
/// A game's own setting wins over its system's; with neither, nothing is sent
/// and Android opens the emulator where it always has (the screen NeoStation
/// is on, the default display). Only meaningful on Android with a second
/// display, which is also the only place the settings rows are shown.
class LaunchDisplayService {
  static final _log = LoggerService.instance;

  static const _systemScope = 'system';
  static const _gameScope = 'game';

  /// Whether the device currently has a display besides the default one.
  static Future<bool> hasSecondaryDisplay() async {
    if (!Platform.isAndroid) return false;
    try {
      final displays = await SubScreenPlugin.getDisplays();
      return displays.any((d) => !d.isDefault);
    } catch (e) {
      _log.w('Could not list displays: $e');
      return false;
    }
  }

  static Future<LaunchDisplay?> getForSystem(String systemFolderName) async =>
      LaunchDisplay.fromValue(
        await SqliteService.getLaunchDisplay(_systemScope, systemFolderName),
      );

  /// Sets the screen for every game of the system; null restores the default.
  static Future<void> setForSystem(
    String systemFolderName,
    LaunchDisplay? display,
  ) => SqliteService.setLaunchDisplay(
    _systemScope,
    systemFolderName,
    display?.value,
  );

  static Future<LaunchDisplay?> getForGame(String romPath) async =>
      LaunchDisplay.fromValue(
        await SqliteService.getLaunchDisplay(_gameScope, romPath),
      );

  /// Sets the screen for one game; null makes it follow its system again.
  static Future<void> setForGame(String romPath, LaunchDisplay? display) =>
      SqliteService.setLaunchDisplay(_gameScope, romPath, display?.value);

  /// The `launch_display` value for launching [game] of [system], or null to
  /// leave the choice to Android.
  ///
  /// In aggregate views ('all', favorites, collections) [system] is the
  /// aggregate, so the game's own system folder is preferred when known.
  /// Never throws: a lookup failure must not stop the game from launching.
  static Future<String?> resolveForLaunch(
    SystemModel system,
    GameModel game,
  ) async {
    if (!Platform.isAndroid) return null;
    try {
      final romPath = game.romPath;
      if (romPath != null && romPath.isNotEmpty) {
        final own = await getForGame(romPath);
        if (own != null) return own.value;
      }
      final systemFolder = game.systemFolderName ?? system.folderName;
      return (await getForSystem(systemFolder))?.value;
    } catch (e) {
      _log.w('Could not resolve the launch screen: $e');
      return null;
    }
  }
}
