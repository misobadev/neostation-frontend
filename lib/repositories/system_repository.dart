import 'dart:io';
import '../models/system_model.dart';
import '../data/datasources/sqlite_service.dart';

/// Repository for handling system data (app_systems - read-only)
class SystemRepository {
  /// Whether a system is meant to be shown on the current platform.
  ///
  /// Native ports are desktop-only, while the Android app system is the
  /// inverse. Keeping the rule here prevents a configured folder from leaking
  /// the card onto a platform that cannot launch its games.
  static bool isSystemAvailableOnPlatform(String folderName, {bool? android}) {
    final isAndroid = android ?? Platform.isAndroid;
    if (folderName == 'ports' && isAndroid) return false;
    if (folderName == 'android' && !isAndroid) return false;
    return true;
  }

  /// Get all available systems from the database
  static Future<List<SystemModel>> getAllSystems() async {
    // If the DB is empty, force sync during app startup if necessary
    var systems = await SqliteService.getAllSystems();
    if (systems.isEmpty) {
      await SqliteService.loadAndSyncSystems();
      systems = await SqliteService.getAllSystems();
    }
    return systems
        .where((system) => system.folderName != 'ports' || !Platform.isAndroid)
        .toList();
  }

  /// Get a system by its folder_name
  static Future<SystemModel?> getSystemByFolderName(String folderName) async {
    try {
      return await SqliteService.getSystemByFolderName(folderName);
    } catch (e) {
      return null;
    }
  }

  /// Get a system by its ID
  static Future<SystemModel?> getSystemById(String id) async {
    final systems = await getAllSystems();
    try {
      return systems.firstWhere((s) => s.id == id);
    } catch (e) {
      return null;
    }
  }

  /// Search systems by name (real_name or folder_name)
  static Future<List<SystemModel>> searchSystems(String query) async {
    final systems = await getAllSystems();
    final lowerQuery = query.toLowerCase();

    return systems
        .where(
          (s) =>
              s.realName.toLowerCase().contains(lowerQuery) ||
              s.folderName.toLowerCase().contains(lowerQuery),
        )
        .toList();
  }

  /// Get detected systems with rom count
  static Future<List<SystemModel>> getDetectedSystems() async {
    final allSystems = await getAllSystems();
    final detected = await SqliteService.getUserDetectedSystems();

    // Filter detected systems to only include those present in the JSON configuration
    // AND platform-specific systems (like Android) only on their respective platforms.
    return detected.where((d) {
      final isPresent = allSystems.any((s) => s.folderName == d.folderName);
      if (!isPresent) return false;

      if (!isSystemAvailableOnPlatform(d.folderName)) {
        return false;
      }

      return true;
    }).toList();
  }

  /// Check if a system is detected
  static Future<bool> isSystemDetected(String folderName) async {
    final detectedSystems = await getDetectedSystems();
    return detectedSystems.any((s) => s.folderName == folderName);
  }

  /// Get total detected systems count
  static Future<int> getDetectedSystemCount() async {
    final detectedSystems = await getDetectedSystems();
    return detectedSystems.length;
  }

  // ── System display/scan settings (write) ──────────────────────────────────

  static Future<void> setRecursiveScan(String systemId, bool value) =>
      SqliteService.setSystemRecursiveScan(systemId, value);

  static Future<void> setPreferFileName(String systemId, bool value) =>
      SqliteService.setSystemPreferFileName(systemId, value);

  static Future<void> setSubfolderView(String systemId, bool value) =>
      SqliteService.setSystemSubfolderView(systemId, value);

  /// Applies "Show Subfolders" to every system at once (the global toggle in
  /// Settings > General).
  static Future<void> setSubfolderViewForAll(bool value) =>
      SqliteService.setSubfolderViewForAllSystems(value);

  /// How many systems carry a "Show Subfolders" setting of their own — one that
  /// differs from [globalValue], the last global choice — and would therefore
  /// be overwritten by the next global stamp.
  static Future<int> countSubfolderViewOverrides(bool globalValue) =>
      SqliteService.countSubfolderViewOverrides(globalValue);

  static Future<void> setHideExtension(String systemId, bool value) =>
      SqliteService.setSystemHideExtension(systemId, value);

  static Future<void> setHideParentheses(String systemId, bool value) =>
      SqliteService.setSystemHideParentheses(systemId, value);

  static Future<void> setHideBrackets(String systemId, bool value) =>
      SqliteService.setSystemHideBrackets(systemId, value);

  static Future<void> setCustomImages(
    String systemId, {
    String? backgroundPath,
    String? logoPath,
  }) => SqliteService.setSystemCustomImages(
    systemId,
    backgroundPath: backgroundPath,
    logoPath: logoPath,
  );

  // ── System detection (write) ────────────────────────────────────────────

  static Future<void> addDetectedSystem(
    String systemId,
    String actualFolderName,
  ) => SqliteService.addDetectedSystem(systemId, actualFolderName);

  static Future<void> removeDetectedSystem(String systemId) =>
      SqliteService.removeDetectedSystem(systemId);

  static Future<void> updateDetectedSystems(List<String> folderNames) =>
      SqliteService.updateDetectedSystems(folderNames);

  // ── System visibility ─────────────────────────────────────────────────────

  static Future<Set<String>> getHiddenSystems() =>
      SqliteService.getHiddenSystems();

  static Future<void> setSystemHidden(String folderName, bool isHidden) =>
      SqliteService.setSystemHidden(folderName, isHidden);

  // ── ROM counts ────────────────────────────────────────────────────────────

  static Future<int> getRomCountForSystem(String systemId) =>
      SqliteService.getRomCountForSystem(systemId);

  // ── System settings ───────────────────────────────────────────────────────

  static Future<Map<String, dynamic>> getSystemSettings(String systemId) =>
      SqliteService.getSystemSettings(systemId);

  static Future<Set<String>> getExtensionsForSystem(String systemId) =>
      SqliteService.getExtensionsForSystem(systemId);

  // ── System extensions ─────────────────────────────────────────────────────

  static Future<Set<String>> getAllValidExtensions() =>
      SqliteService.getAllValidExtensions();

  static Future<Map<String, Set<String>>> getSystemExtensionsMap() =>
      SqliteService.getSystemExtensionsMap();

  // ── System statistics ──────────────────────────────────────────────────────

  /// Get System Stats
  static Future<Map<String, int>> getSystemStats() async {
    final allSystems = await getAllSystems();
    final detectedSystems = await getDetectedSystems();

    int totalRoms = 0;

    for (final system in detectedSystems) {
      totalRoms += system.romCount;
    }

    return {
      'totalAvailable': allSystems.length,
      'totalDetected': detectedSystems.length,
      'totalRoms': totalRoms,
    };
  }
}
