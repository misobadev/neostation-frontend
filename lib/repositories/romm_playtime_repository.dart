import '../data/datasources/sqlite_service.dart';

import 'package:neostation/services/logger_service.dart';

/// Repository for RomM playtime sync state: the [app_romm_play_sessions]
/// outbox of finished sessions waiting to be pushed, and the
/// [app_romm_playtime_state] per-ROM reconciliation ledger.
///
/// Per the architecture rules, this is the only layer that touches
/// [SqliteService] for this data.
class RommPlaytimeRepository {
  static final _log = LoggerService.instance;

  /// Sessions kept in the outbox before the oldest are dropped. A device that
  /// plays RomM games while permanently offline would otherwise queue forever;
  /// the cap bounds that at a few weeks of heavy play.
  static const int maxQueuedSessions = 500;

  // ── Outbox ─────────────────────────────────────────────────────────────────

  /// Queues a finished session for upload. Silently ignores a session whose
  /// `(rom_id, start_time)` is already queued — the same key RomM dedupes on.
  static Future<void> enqueueSession({
    required int rommRomId,
    required String romPath,
    required DateTime startTime,
    required DateTime endTime,
    required int durationMs,
  }) async {
    try {
      final db = await SqliteService.getDatabase();
      await db.rawInsert(
        '''
        INSERT OR IGNORE INTO app_romm_play_sessions
          (romm_rom_id, rom_path, start_time, end_time, duration_ms, created_at)
        VALUES (?, ?, ?, ?, ?, ?)
        ''',
        [
          rommRomId,
          romPath,
          startTime.toUtc().toIso8601String(),
          endTime.toUtc().toIso8601String(),
          durationMs,
          DateTime.now().toIso8601String(),
        ],
      );
      await _pruneQueue(db);
    } catch (e) {
      _log.e('Error queueing RomM play session (rom $rommRomId): $e');
    }
  }

  /// Oldest-first batch of queued sessions, capped at [limit] (RomM's ingest
  /// endpoint rejects batches above 100).
  static Future<List<Map<String, Object?>>> pendingSessions({
    int limit = 100,
  }) async {
    try {
      final db = await SqliteService.getDatabase();
      return await db.query(
        'app_romm_play_sessions',
        orderBy: 'id ASC',
        limit: limit,
      );
    } catch (e) {
      _log.e('Error reading queued RomM play sessions: $e');
      return const [];
    }
  }

  /// Number of sessions still waiting to be pushed.
  static Future<int> pendingCount() async {
    try {
      final db = await SqliteService.getDatabase();
      final rows = await db.rawQuery(
        'SELECT COUNT(*) AS c FROM app_romm_play_sessions',
      );
      if (rows.isEmpty) return 0;
      return int.tryParse(rows.first['c']?.toString() ?? '0') ?? 0;
    } catch (e) {
      _log.e('Error counting queued RomM play sessions: $e');
      return 0;
    }
  }

  /// Removes queued sessions by row id (called once the server holds them).
  static Future<void> deleteSessions(List<int> ids) async {
    if (ids.isEmpty) return;
    try {
      final db = await SqliteService.getDatabase();
      final placeholders = List.filled(ids.length, '?').join(',');
      await db.rawDelete(
        'DELETE FROM app_romm_play_sessions WHERE id IN ($placeholders)',
        ids,
      );
    } catch (e) {
      _log.e('Error deleting queued RomM play sessions: $e');
    }
  }

  static Future<void> _pruneQueue(DatabaseAdapter db) async {
    await db.rawDelete(
      '''
      DELETE FROM app_romm_play_sessions
      WHERE id NOT IN (
        SELECT id FROM app_romm_play_sessions ORDER BY id DESC LIMIT ?
      )
      ''',
      [maxQueuedSessions],
    );
  }

  // ── Ledger ─────────────────────────────────────────────────────────────────

  /// Reconciliation state for [rommRomId]. Keys: `pushed_ms`,
  /// `remote_applied_ms`, `last_pulled_at` (ISO string or null). Returns zeroed
  /// state for a ROM that has never synced playtime.
  static Future<RommPlaytimeLedger> getLedger(int rommRomId) async {
    try {
      final db = await SqliteService.getDatabase();
      final rows = await db.query(
        'app_romm_playtime_state',
        where: 'romm_rom_id = ?',
        whereArgs: [rommRomId],
        limit: 1,
      );
      if (rows.isEmpty) return RommPlaytimeLedger.empty(rommRomId);
      final row = rows.first;
      final lastPulledRaw = row['last_pulled_at']?.toString();
      return RommPlaytimeLedger(
        rommRomId: rommRomId,
        pushedMs: int.tryParse(row['pushed_ms']?.toString() ?? '0') ?? 0,
        remoteAppliedMs:
            int.tryParse(row['remote_applied_ms']?.toString() ?? '0') ?? 0,
        lastPulledAt: (lastPulledRaw == null || lastPulledRaw.isEmpty)
            ? null
            : DateTime.tryParse(lastPulledRaw),
      );
    } catch (e) {
      _log.e('Error reading RomM playtime ledger (rom $rommRomId): $e');
      return RommPlaytimeLedger.empty(rommRomId);
    }
  }

  /// Adds [ms] to the time this device has successfully pushed for [rommRomId].
  static Future<void> addPushedMs(int rommRomId, int ms) async {
    if (ms <= 0) return;
    try {
      final db = await SqliteService.getDatabase();
      await _ensureLedgerRow(db, rommRomId);
      await db.rawUpdate(
        '''
        UPDATE app_romm_playtime_state
        SET pushed_ms = pushed_ms + ?, updated_at = ?
        WHERE romm_rom_id = ?
        ''',
        [ms, DateTime.now().toIso8601String(), rommRomId],
      );
    } catch (e) {
      _log.e('Error updating RomM pushed playtime (rom $rommRomId): $e');
    }
  }

  /// Records how much other-device time is now folded into the local total,
  /// and stamps the pull so [RommPlaytimeLedger.lastPulledAt] can throttle the
  /// next one.
  static Future<void> setRemoteApplied(
    int rommRomId,
    int remoteAppliedMs, {
    DateTime? pulledAt,
  }) async {
    try {
      final db = await SqliteService.getDatabase();
      await _ensureLedgerRow(db, rommRomId);
      final now = (pulledAt ?? DateTime.now()).toIso8601String();
      await db.rawUpdate(
        '''
        UPDATE app_romm_playtime_state
        SET remote_applied_ms = ?, last_pulled_at = ?, updated_at = ?
        WHERE romm_rom_id = ?
        ''',
        [remoteAppliedMs, now, now, rommRomId],
      );
    } catch (e) {
      _log.e('Error updating RomM applied playtime (rom $rommRomId): $e');
    }
  }

  static Future<void> _ensureLedgerRow(
    DatabaseAdapter db,
    int rommRomId,
  ) async {
    await db.rawInsert(
      'INSERT OR IGNORE INTO app_romm_playtime_state (romm_rom_id) VALUES (?)',
      [rommRomId],
    );
  }
}

/// Per-ROM playtime reconciliation state, backing `app_romm_playtime_state`.
class RommPlaytimeLedger {
  final int rommRomId;

  /// Session time this device has pushed to RomM.
  final int pushedMs;

  /// Other-device time already added to `user_roms.play_time`.
  final int remoteAppliedMs;

  final DateTime? lastPulledAt;

  const RommPlaytimeLedger({
    required this.rommRomId,
    required this.pushedMs,
    required this.remoteAppliedMs,
    this.lastPulledAt,
  });

  factory RommPlaytimeLedger.empty(int rommRomId) =>
      RommPlaytimeLedger(rommRomId: rommRomId, pushedMs: 0, remoteAppliedMs: 0);
}
