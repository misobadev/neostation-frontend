import '../data/datasources/sqlite_service.dart';

/// Repository for user configuration data access.
class ConfigRepository {
  /// Returns the list of ROM folder paths configured by the user.
  static Future<List<String>> getUserRomFolders() =>
      SqliteService.getUserRomFolders();

  /// Removes one ROM folder from the configured list.
  static Future<void> removeRomFolder(String folderPath) =>
      SqliteService.removeRomFolder(folderPath);

  /// Returns the full user_config row, or null if not yet created.
  static Future<Map<String, dynamic>?> getUserConfig() =>
      SqliteService.getUserConfig();

  static Future<void> updateCustomSfx(String json) =>
      SqliteService.saveUserConfig(customSfx: json);

  // ── Theme settings ──────────────────────────────────────────────────────

  static Future<String> getThemeName() => SqliteService.getThemeName();

  static Future<void> updateThemeName(String name) =>
      SqliteService.updateThemeName(name);

  // ── Active asset theme ────────────────────────────────────────────────────

  static Future<String> getActiveTheme() => SqliteService.getActiveTheme();

  static Future<void> updateActiveTheme(String folder) =>
      SqliteService.updateActiveTheme(folder);

  // ── General user config (write) ───────────────────────────────────────────

  static Future<void> saveUserConfig({String? lastScan}) =>
      SqliteService.saveUserConfig(lastScan: lastScan);
}
