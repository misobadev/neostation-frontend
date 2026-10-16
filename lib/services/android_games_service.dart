import '../repositories/game_repository.dart';
import 'android_game_icon_service.dart';

/// Decides which installed apps are filed under "Android Games".
class AndroidGamesService {
  /// Marks [packageName] as a game ([isGame] true) or not, overriding the
  /// category the app declares. Caches the icon the games views show as art.
  static Future<void> setIsGame(String packageName, bool isGame) async {
    await GameRepository.setAndroidGameOverride(packageName, isGame);
    if (isGame) await AndroidGameIconService.ensureIcon(packageName);
  }
}
