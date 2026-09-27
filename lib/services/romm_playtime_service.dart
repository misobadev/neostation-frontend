import 'package:neostation/models/romm_play_session.dart';
import 'package:neostation/repositories/game_repository.dart';
import 'package:neostation/repositories/romm_playtime_repository.dart';
import 'package:neostation/repositories/romm_save_map_repository.dart';
import 'package:neostation/services/logger_service.dart';
import 'package:neostation/services/romm_service.dart';

/// Two-way playtime sync with RomM.
///
/// **Push** — a finished session is queued locally the moment the game exits
/// ([recordCompletedSession]) and uploaded on the next sync
/// ([flushQueuedSessions]), so play is never lost to a server that happened to
/// be unreachable. RomM has no aggregate playtime field: uploading the session
/// *is* how playtime reaches the server, and it moves `last_played` forward
/// there as a side effect.
///
/// **Pull** — [pullPlaytime] sums the ROM's sessions on the server, subtracts
/// what this device pushed, and folds the remainder (time played on another
/// device or in RomM's web player) into `user_roms.play_time`.
///
/// Playtime that accumulated locally *before* a game was linked to RomM is not
/// backfilled — there are no session boundaries to report for it, and inventing
/// them would put fabricated timestamps in the user's history.
class RommPlaytimeService {
  static final _log = LoggerService.instance;

  /// Sessions shorter than this are dropped rather than reported: they're
  /// almost always a failed launch bouncing straight back to the UI. Matches
  /// the threshold the crash-recovery path already applies locally.
  static const int minSessionSeconds = 5;

  /// How stale a ROM's pulled playtime may get before another pull is worth a
  /// round-trip. The pull runs off save-sync, which fires on every highlighted
  /// game while browsing, so an unthrottled pull would be a GET per selection.
  static const Duration pullInterval = Duration(minutes: 5);

  // ── Push ───────────────────────────────────────────────────────────────────

  /// Queues a finished play session for upload, if the game is RomM-linked.
  ///
  /// Returns true when a session was queued. Purely local (no network), so it
  /// is safe to call from the game-exit path regardless of connectivity or of
  /// which sync provider is active.
  static Future<bool> recordCompletedSession({
    required String romname,
    required String systemFolder,
    required String romPath,
    required DateTime startTime,
    required DateTime endTime,
    Duration? played,
  }) async {
    // [played] excludes time the device spent asleep inside the window, so it
    // can be shorter than endTime - startTime.
    final durationMs = (played ?? endTime.difference(startTime)).inMilliseconds;
    if (durationMs < minSessionSeconds * 1000) return false;
    if (romname.isEmpty || systemFolder.isEmpty || romPath.isEmpty) {
      return false;
    }

    final romId = await RommSaveMapRepository.getRommRomId(
      romname,
      systemFolder,
    );
    if (romId == null) return false; // not downloaded from RomM

    await RommPlaytimeRepository.enqueueSession(
      rommRomId: romId,
      romPath: romPath,
      startTime: startTime,
      endTime: endTime,
      durationMs: durationMs,
    );
    return true;
  }

  /// Uploads every queued session, in batches of [RommService.maxPlaySessionBatch].
  ///
  /// Returns the number of sessions the server now holds as a result. A network
  /// failure leaves the remaining queue intact for the next sync; only sessions
  /// the server accepted — or explicitly rejected as unfixable — are dequeued.
  static Future<int> flushQueuedSessions(RommService service) async {
    if (!service.playtimeSyncAvailable) return 0;

    var pushed = 0;
    while (true) {
      final rows = await RommPlaytimeRepository.pendingSessions(
        limit: RommService.maxPlaySessionBatch,
      );
      if (rows.isEmpty) break;

      final sessions = <RommPlaySession>[];
      final romIds = <int>[];
      final rowIds = <int>[];
      final durations = <int>[];
      for (final row in rows) {
        final romId = int.tryParse(row['romm_rom_id']?.toString() ?? '');
        final rowId = int.tryParse(row['id']?.toString() ?? '');
        final start = DateTime.tryParse(row['start_time']?.toString() ?? '');
        final end = DateTime.tryParse(row['end_time']?.toString() ?? '');
        final durationMs =
            int.tryParse(row['duration_ms']?.toString() ?? '') ?? 0;
        if (romId == null || rowId == null || start == null || end == null) {
          // Unparseable row — drop it rather than blocking the queue forever.
          if (rowId != null) {
            await RommPlaytimeRepository.deleteSessions([rowId]);
          }
          continue;
        }
        sessions.add(
          RommPlaySession(
            romId: romId,
            startTime: start,
            endTime: end,
            durationMs: durationMs,
          ),
        );
        romIds.add(romId);
        rowIds.add(rowId);
        durations.add(durationMs);
      }
      if (sessions.isEmpty) continue;

      final RommPlaySessionIngestResult result;
      try {
        result = await service.ingestPlaySessions(sessions);
      } catch (e) {
        _log.w('RomM play-session upload failed (kept queued): $e');
        return pushed;
      }

      // Time the server now holds counts against this device's contribution,
      // so a later pull can tell our own play apart from another device's.
      final acceptedMsByRom = <int, int>{};
      final settledRowIds = <int>[];
      for (var i = 0; i < sessions.length; i++) {
        if (result.acceptedIndexes.contains(i)) {
          acceptedMsByRom[romIds[i]] =
              (acceptedMsByRom[romIds[i]] ?? 0) + durations[i];
          settledRowIds.add(rowIds[i]);
          pushed++;
        } else if (result.rejectedIndexes.contains(i)) {
          _log.w(
            'RomM rejected play session for rom ${romIds[i]} — discarding',
          );
          settledRowIds.add(rowIds[i]);
        }
      }
      for (final entry in acceptedMsByRom.entries) {
        await RommPlaytimeRepository.addPushedMs(entry.key, entry.value);
      }
      await RommPlaytimeRepository.deleteSessions(settledRowIds);

      // Nothing settled → the server answered but kept none of the batch;
      // stop rather than re-sending the same rows forever.
      if (settledRowIds.isEmpty) break;
      if (rows.length < RommService.maxPlaySessionBatch) break;
    }

    if (pushed > 0) _log.i('RomM playtime: pushed $pushed session(s)');
    return pushed;
  }

  // ── Pull ───────────────────────────────────────────────────────────────────

  /// Folds playtime recorded elsewhere for [romId] into the local total for
  /// [romPath]. Returns true when the local row was touched.
  ///
  /// Throttled to one round-trip per [pullInterval] per ROM unless [force].
  static Future<bool> pullPlaytime(
    RommService service, {
    required int romId,
    required String romPath,
    bool force = false,
  }) async {
    if (!service.playtimeSyncAvailable || romPath.isEmpty) return false;

    final ledger = await RommPlaytimeRepository.getLedger(romId);
    final lastPulled = ledger.lastPulledAt;
    if (!force &&
        lastPulled != null &&
        DateTime.now().difference(lastPulled) < pullInterval) {
      return false;
    }

    final List<RommPlaySession> sessions;
    try {
      sessions = await service.getPlaySessions(romId: romId);
    } catch (e) {
      _log.w('RomM play-session fetch failed for rom $romId: $e');
      return false;
    }

    var remoteTotalMs = 0;
    DateTime? lastEnd;
    for (final s in sessions) {
      remoteTotalMs += s.durationMs;
      if (lastEnd == null || s.endTime.isAfter(lastEnd)) lastEnd = s.endTime;
    }

    final seconds = remoteSecondsToApply(
      remoteTotalMs: remoteTotalMs,
      pushedMs: ledger.pushedMs,
      appliedMs: ledger.remoteAppliedMs,
    );

    if (seconds > 0 || lastEnd != null) {
      await GameRepository.applyRemotePlayTime(
        romPath,
        seconds,
        remoteLastPlayed: lastEnd,
      );
    }
    await RommPlaytimeRepository.setRemoteApplied(
      romId,
      ledger.remoteAppliedMs + seconds * 1000,
    );

    if (seconds > 0) {
      _log.i('RomM playtime: +${seconds}s from other devices (rom $romId)');
    }
    return seconds > 0 || lastEnd != null;
  }

  /// Whole seconds of *other-device* playtime not yet counted locally.
  ///
  /// The server total includes the sessions this device pushed ([pushedMs]),
  /// which `user_roms.play_time` already counts — subtracting them is what
  /// keeps a pull from double-counting our own play. [appliedMs] then removes
  /// what earlier pulls already added, making repeated pulls idempotent.
  ///
  /// Never negative: sessions deleted on the server shrink the remote total,
  /// and playtime already earned locally must not be clawed back. The
  /// sub-second remainder is deliberately left in the ledger so a run of short
  /// remote sessions eventually adds up instead of being truncated away each
  /// time.
  static int remoteSecondsToApply({
    required int remoteTotalMs,
    required int pushedMs,
    required int appliedMs,
  }) {
    final otherMs = remoteTotalMs - pushedMs;
    final deltaMs = otherMs - appliedMs;
    if (deltaMs <= 0) return 0;
    return deltaMs ~/ 1000;
  }
}
