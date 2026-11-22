import '../repositories/game_repository.dart';
import 'android_game_icon_service.dart';

/// Decides which installed apps are filed under "Android Games".
///
/// Nothing is classified automatically: an app is a game only once the user
/// marks it.
class AndroidGamesService {
  /// Marks [packageName] as a game ([isGame] true) or sends it back to the
  /// Android tab. Caches the icon the games views show as art.
  static Future<void> setIsGame(String packageName, bool isGame) async {
    await GameRepository.setAndroidGame(packageName, isGame);
    if (isGame) await AndroidGameIconService.ensureIcon(packageName);
  }

  /// Caches the icon of every marked game that has none yet, such as after a
  /// reinstall or a cleared media folder.
  static Future<void> cacheMissingIcons() async {
    for (final packageName in await GameRepository.getAndroidGamePackages()) {
      await AndroidGameIconService.ensureIcon(packageName);
    }
  }
}
