import 'package:shared_preferences/shared_preferences.dart';

/// Keeps the record of which games may still be open in an emulator (the
/// sync layer's open-game guard, as one encoded value) in preferences, so it
/// outlives NeoStation until a reboot.
class OpenGameRepository {
  OpenGameRepository._();

  static const String _pref = 'open_game_guard';

  static Future<String?> read() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_pref);
  }

  static Future<void> write(String value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_pref, value);
  }
}
