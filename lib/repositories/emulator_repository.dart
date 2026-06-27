import '../models/core_emulator_model.dart';
import '../models/emulator_model.dart';
import '../data/datasources/sqlite_service.dart';

/// Repository for emulator configuration data access.
class EmulatorRepository {
  /// Returns the configured executable path for an emulator matched by
  /// [identifierLike] and [nameLike] (SQL LIKE patterns against
  /// app_emulators.unique_identifier and app_emulators.name).
  ///
  /// Returns the path string, or null if not configured.
  static Future<String?> getEmulatorPath(
    String identifierLike,
    String nameLike,
  ) async {
    final db = await SqliteService.getDatabase();
    final results = await db.rawQuery(
      '''
      SELECT uc.emulator_path
      FROM user_emulator_config uc
      JOIN app_emulators e ON e.unique_identifier = uc.emulator_unique_id
      WHERE e.unique_identifier LIKE ? OR e.name LIKE ?
      ORDER BY uc.is_user_default DESC
      LIMIT 1
      ''',
      [identifierLike, nameLike],
    );
    final path = results.isNotEmpty
        ? results.first['emulator_path']?.toString()
        : null;
    return (path != null && path.isNotEmpty) ? path : null;
  }

  // ── Per-system emulator queries ────────────────────────────────────────────

  static Future<List<CoreEmulatorModel>> getCoresBySystemId(String systemId) =>
      SqliteService.getCoresBySystemId(systemId);

  static Future<List<Map<String, dynamic>>> getStandaloneEmulatorsBySystemId(
    String systemId,
  ) => SqliteService.getStandaloneEmulatorsBySystemId(systemId);

  static Future<Map<String, EmulatorModel>> getUserDetectedEmulators() =>
      SqliteService.getUserDetectedEmulators();

  /// Returns all emulators (cores + standalone) for a system on the current OS.
  static Future<List<CoreEmulatorModel>> getEmulatorsForSystemCurrentOs(
    String systemId,
  ) => SqliteService.getEmulatorsForSystemCurrentOs(systemId);

  // ── Emulator configuration (write) ────────────────────────────────────────

  static Future<void> setDefaultCore(
    String systemId,
    String uniqueIdentifier,
    int osId,
  ) => SqliteService.setDefaultCore(systemId, uniqueIdentifier, osId);

  static Future<void> setDefaultStandaloneEmulator(
    String systemId,
    String emulatorUniqueId,
  ) => SqliteService.setDefaultStandaloneEmulator(systemId, emulatorUniqueId);

  static Future<void> setStandaloneEmulatorPath(
    String emulatorUniqueId,
    String path,
  ) => SqliteService.setStandaloneEmulatorPath(emulatorUniqueId, path);

  static Future<void> saveDetectedEmulatorPath({
    required String emulatorName,
    required String emulatorPath,
  }) => SqliteService.saveDetectedEmulatorPath(
    emulatorName: emulatorName,
    emulatorPath: emulatorPath,
  );

  // ── Default emulator resolution ───────────────────────────────────────────

  static Future<CoreEmulatorModel?> getDefaultEmulatorForSystem(
    String systemId,
  ) => SqliteService.getDefaultEmulatorForSystem(systemId);

  static Future<List<String>> getAndroidRetroArchPackages() =>
      SqliteService.getAndroidRetroArchPackages();

  static Future<void> fixRetroArchDefaultForAndroid(String preferredPackage) =>
      SqliteService.fixRetroArchDefaultForAndroid(preferredPackage);

  /// Resolves the detected RetroArch executable path for the current OS.
  static Future<String?> getRetroArchExecutablePath() async {
    final db = await SqliteService.getDatabase();
    final results = await db.rawQuery('''
      SELECT uc.emulator_path 
      FROM user_emulator_config uc
      LEFT JOIN app_emulators e ON e.unique_identifier = uc.emulator_unique_id
      WHERE (uc.emulator_unique_id LIKE '%ra' 
         OR uc.emulator_unique_id LIKE '%ra32'
         OR uc.emulator_unique_id LIKE '%ra64'
         OR uc.emulator_unique_id LIKE '%.ra.%'
         OR uc.emulator_unique_id LIKE '%.ra32.%'
         OR uc.emulator_unique_id LIKE '%.ra64.%')
         AND uc.emulator_unique_id NOT LIKE '%citra%'
         OR e.name LIKE '%RetroArch%'
      ORDER BY uc.is_user_default DESC
      LIMIT 1
    ''');

    if (results.isNotEmpty) {
      final path = results.first['emulator_path']?.toString();
      if (path != null && path.isNotEmpty) return path;
    }
    return null;
  }

  // ── Systems with standalone emulators ─────────────────────────────────────

  /// Returns systems that have at least one standalone emulator for the current OS,
  /// ordered by name.
  static Future<List<Map<String, dynamic>>>
  getSystemsWithStandaloneEmulators() async {
    final db = await SqliteService.getDatabase();
    final currentOs = SqliteService.getCurrentOs();

    final osResult = await db.query(
      'app_os',
      where: 'name = ?',
      whereArgs: [currentOs],
    );

    if (osResult.isEmpty) {
      throw Exception('OS context resolution failed: $currentOs');
    }

    final osId = int.tryParse(osResult.first['id']?.toString() ?? '0') ?? 0;

    final results = await db.rawQuery(
      '''
      SELECT DISTINCT
        s.id,
        s.real_name,
        s.folder_name,
        COUNT(DISTINCT e.id) as emulator_count
      FROM app_systems s
      INNER JOIN app_emulators e ON e.system_id = s.id
      WHERE e.os_id = ? AND e.is_standalone = 1
      GROUP BY s.id, s.real_name, s.folder_name
      ORDER BY s.real_name
      ''',
      [osId],
    );

    return results
        .map(
          (row) => {
            'id': row['id']?.toString() ?? '',
            'real_name': row['real_name']?.toString() ?? '',
            'folder_name': row['folder_name']?.toString() ?? '',
            'emulator_count':
                int.tryParse(row['emulator_count']?.toString() ?? '0') ?? 0,
          },
        )
        .toList();
  }
}
