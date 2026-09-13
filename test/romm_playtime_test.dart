import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/data/datasources/sqlite_migrations.dart';
import 'package:neostation/models/romm_play_session.dart';
import 'package:neostation/repositories/game_repository.dart';
import 'package:neostation/repositories/romm_playtime_repository.dart';
import 'package:neostation/repositories/romm_save_map_repository.dart';
import 'package:neostation/services/romm_playtime_service.dart';

import 'database_test_helper.dart';

/// Covers RomM playtime sync: the wire shape of a play session, the outbox and
/// ledger that make pushes and pulls idempotent, and the reconciliation
/// arithmetic that keeps a device from counting its own play twice.
void main() {
  group('RommPlaySession.toIngestJson', () {
    test('sends whole-second UTC timestamps', () {
      final json = RommPlaySession(
        romId: 7,
        startTime: DateTime.utc(2026, 7, 28, 10, 0, 0, 500, 250),
        endTime: DateTime.utc(2026, 7, 28, 10, 30, 0),
        durationMs: 1800000,
      ).toIngestJson();

      // RomM truncates sub-second precision before its (rom_id, start_time)
      // duplicate check — sending it would make a re-push look like new play.
      expect(json['start_time'], '2026-07-28T10:00:00.000Z');
      expect(json['end_time'], '2026-07-28T10:30:00.000Z');
      expect(json['rom_id'], 7);
      expect(json['duration_ms'], 1800000);
    });

    test('converts a local start time to UTC', () {
      final local = DateTime.utc(2026, 7, 28, 12, 0, 0).toLocal();
      final json = RommPlaySession(
        romId: 1,
        startTime: local,
        endTime: local.add(const Duration(minutes: 10)),
        durationMs: 600000,
      ).toIngestJson();

      expect(json['start_time'], '2026-07-28T12:00:00.000Z');
      expect(json['end_time'], '2026-07-28T12:10:00.000Z');
    });
  });

  group('RommPlaySession.fromJson', () {
    test('parses a server session', () {
      final s = RommPlaySession.fromJson({
        'id': 42,
        'rom_id': 7,
        'device_id': null,
        'start_time': '2026-07-28T10:00:00Z',
        'end_time': '2026-07-28T10:30:00Z',
        'duration_ms': 1800000,
      });

      expect(s.id, 42);
      expect(s.romId, 7);
      expect(s.durationMs, 1800000);
      expect(s.endTime.toUtc(), DateTime.utc(2026, 7, 28, 10, 30));
    });

    test('reads a naive server timestamp as UTC, not local', () {
      // RomM serializes these UTC columns without a zone designator; parsing
      // them as local time would shift every pulled session by the device's
      // offset and write a wrong last_played.
      final s = RommPlaySession.fromJson({
        'id': 1,
        'rom_id': 7,
        'start_time': '2026-07-28T20:00:00',
        'end_time': '2026-07-28T20:30:00',
        'duration_ms': 1800000,
      });

      expect(s.endTime.isUtc, isTrue);
      expect(s.endTime, DateTime.utc(2026, 7, 28, 20, 30));
    });

    test('honours an explicit offset when the server sends one', () {
      final s = RommPlaySession.fromJson({
        'id': 1,
        'rom_id': 7,
        'start_time': '2026-07-28T22:00:00+02:00',
        'end_time': '2026-07-28T22:30:00+02:00',
        'duration_ms': 1800000,
      });

      expect(s.endTime.toUtc(), DateTime.utc(2026, 7, 28, 20, 30));
    });

    test('falls back to the interval when duration_ms is absent', () {
      final s = RommPlaySession.fromJson({
        'id': 1,
        'rom_id': 7,
        'start_time': '2026-07-28T10:00:00Z',
        'end_time': '2026-07-28T10:05:00Z',
      });

      expect(s.durationMs, 300000);
    });
  });

  group('RommPlaySessionIngestResult', () {
    test('counts duplicates as accepted, errors as rejected', () {
      final r = RommPlaySessionIngestResult.fromJson({
        'results': [
          {'index': 0, 'status': 'created', 'id': 1},
          {'index': 1, 'status': 'duplicate'},
          {'index': 2, 'status': 'error', 'detail': 'end_time in the future'},
        ],
        'created_count': 1,
        'skipped_count': 1,
      });

      // A duplicate is a session we pushed before but whose response we lost;
      // excluding it would later read as another device's play and inflate the
      // local total.
      expect(r.acceptedIndexes, {0, 1});
      expect(r.rejectedIndexes, {2});
      expect(r.createdCount, 1);
      expect(r.skippedCount, 1);
    });
  });

  group('RommPlaytimeService.remoteSecondsToApply', () {
    int apply({
      required int total,
      required int pushed,
      required int applied,
    }) => RommPlaytimeService.remoteSecondsToApply(
      remoteTotalMs: total,
      pushedMs: pushed,
      appliedMs: applied,
    );

    test('ignores time this device pushed itself', () {
      // Everything on the server came from here → nothing new to add.
      expect(apply(total: 600000, pushed: 600000, applied: 0), 0);
    });

    test('adds only the time played elsewhere', () {
      expect(apply(total: 900000, pushed: 600000, applied: 0), 300);
    });

    test('is idempotent across repeated pulls', () {
      expect(apply(total: 900000, pushed: 600000, applied: 300000), 0);
    });

    test('adds only the increment since the last pull', () {
      expect(apply(total: 1200000, pushed: 600000, applied: 300000), 300);
    });

    test('never claws back time when server sessions are deleted', () {
      expect(apply(total: 300000, pushed: 600000, applied: 300000), 0);
    });

    test('truncates to whole seconds, leaving the remainder for next time', () {
      expect(apply(total: 1500, pushed: 0, applied: 0), 1);
      // 500ms remainder stays unapplied; a later pull that pushes the delta
      // over the next second picks it up.
      expect(apply(total: 2400, pushed: 0, applied: 1000), 1);
    });

    test('counts the full remote total on a device with no local history', () {
      // Fresh install: play_time is 0, so every server session is new here.
      expect(apply(total: 3600000, pushed: 0, applied: 0), 3600);
    });
  });

  group('outbox + ledger', () {
    final dbHelper = DatabaseTestHelper();
    late dynamic db;

    setUp(() async {
      db = await dbHelper.setUp();
      await db.execute(SqliteMigrations.createAppRommRomMapTableSql);
      await db.execute(SqliteMigrations.createAppRommPlaySessionsTableSql);
      await db.execute(SqliteMigrations.createAppRommPlaytimeStateTableSql);
    });

    tearDown(() async {
      await dbHelper.tearDown();
    });

    Future<void> insertGame(String romPath, {int playTime = 0}) => db.rawInsert(
      'INSERT INTO user_roms (filename, rom_path, app_system_id, play_time) '
      'VALUES (?, ?, ?, ?)',
      ['game.sfc', romPath, 'snes', playTime],
    );

    test('queues a session and hands it back oldest-first', () async {
      final start = DateTime.utc(2026, 7, 28, 10);
      await RommPlaytimeRepository.enqueueSession(
        rommRomId: 7,
        romPath: '/roms/snes/game.sfc',
        startTime: start,
        endTime: start.add(const Duration(minutes: 30)),
        durationMs: 1800000,
      );
      await RommPlaytimeRepository.enqueueSession(
        rommRomId: 7,
        romPath: '/roms/snes/game.sfc',
        startTime: start.add(const Duration(hours: 2)),
        endTime: start.add(const Duration(hours: 2, minutes: 5)),
        durationMs: 300000,
      );

      final pending = await RommPlaytimeRepository.pendingSessions();
      expect(pending.length, 2);
      expect(pending.first['duration_ms'], 1800000);
      expect(await RommPlaytimeRepository.pendingCount(), 2);
    });

    test('re-queueing the same session is a no-op', () async {
      final start = DateTime.utc(2026, 7, 28, 10);
      for (var i = 0; i < 2; i++) {
        await RommPlaytimeRepository.enqueueSession(
          rommRomId: 7,
          romPath: '/roms/snes/game.sfc',
          startTime: start,
          endTime: start.add(const Duration(minutes: 30)),
          durationMs: 1800000,
        );
      }
      expect(await RommPlaytimeRepository.pendingCount(), 1);
    });

    test('deleteSessions dequeues only the given rows', () async {
      final start = DateTime.utc(2026, 7, 28, 10);
      await RommPlaytimeRepository.enqueueSession(
        rommRomId: 7,
        romPath: '/roms/snes/game.sfc',
        startTime: start,
        endTime: start.add(const Duration(minutes: 1)),
        durationMs: 60000,
      );
      await RommPlaytimeRepository.enqueueSession(
        rommRomId: 8,
        romPath: '/roms/snes/other.sfc',
        startTime: start,
        endTime: start.add(const Duration(minutes: 1)),
        durationMs: 60000,
      );

      final pending = await RommPlaytimeRepository.pendingSessions();
      await RommPlaytimeRepository.deleteSessions([
        int.parse(pending.first['id'].toString()),
      ]);

      final left = await RommPlaytimeRepository.pendingSessions();
      expect(left.length, 1);
      expect(left.first['romm_rom_id'], 8);
    });

    test('ledger starts empty and accumulates pushed time', () async {
      expect((await RommPlaytimeRepository.getLedger(7)).pushedMs, 0);

      await RommPlaytimeRepository.addPushedMs(7, 600000);
      await RommPlaytimeRepository.addPushedMs(7, 300000);

      final ledger = await RommPlaytimeRepository.getLedger(7);
      expect(ledger.pushedMs, 900000);
      expect(ledger.remoteAppliedMs, 0);
      expect(ledger.lastPulledAt, isNull);
    });

    test('setRemoteApplied records the pull watermark and stamp', () async {
      await RommPlaytimeRepository.setRemoteApplied(7, 300000);

      final ledger = await RommPlaytimeRepository.getLedger(7);
      expect(ledger.remoteAppliedMs, 300000);
      expect(ledger.lastPulledAt, isNotNull);
    });

    test('records a finished session for a RomM-linked game', () async {
      await RommSaveMapRepository.putMapping(
        source: RommLinkSource.download,
        romname: 'game.sfc',
        systemFolder: 'snes',
        rommRomId: 7,
      );

      final start = DateTime.now().subtract(const Duration(minutes: 30));
      final queued = await RommPlaytimeService.recordCompletedSession(
        romname: 'game.sfc',
        systemFolder: 'snes',
        romPath: '/roms/snes/game.sfc',
        startTime: start,
        endTime: start.add(const Duration(minutes: 30)),
      );

      expect(queued, isTrue);
      final pending = await RommPlaytimeRepository.pendingSessions();
      expect(pending.single['romm_rom_id'], 7);
      expect(pending.single['duration_ms'], 1800000);
    });

    test('skips a game that did not come from RomM', () async {
      final start = DateTime.now().subtract(const Duration(minutes: 30));
      final queued = await RommPlaytimeService.recordCompletedSession(
        romname: 'local.sfc',
        systemFolder: 'snes',
        romPath: '/roms/snes/local.sfc',
        startTime: start,
        endTime: start.add(const Duration(minutes: 30)),
      );

      expect(queued, isFalse);
      expect(await RommPlaytimeRepository.pendingCount(), 0);
    });

    test('skips a session too short to be real play', () async {
      await RommSaveMapRepository.putMapping(
        source: RommLinkSource.download,
        romname: 'game.sfc',
        systemFolder: 'snes',
        rommRomId: 7,
      );

      final start = DateTime.now();
      final queued = await RommPlaytimeService.recordCompletedSession(
        romname: 'game.sfc',
        systemFolder: 'snes',
        romPath: '/roms/snes/game.sfc',
        startTime: start,
        endTime: start.add(const Duration(seconds: 2)),
      );

      // A launch that bounced straight back is not playtime.
      expect(queued, isFalse);
      expect(await RommPlaytimeRepository.pendingCount(), 0);
    });

    test('applyRemotePlayTime adds seconds and advances last_played', () async {
      await insertGame('/roms/snes/game.sfc', playTime: 600);

      await GameRepository.applyRemotePlayTime(
        '/roms/snes/game.sfc',
        300,
        remoteLastPlayed: DateTime(2026, 7, 28, 12),
      );

      final rows = await db.query(
        'user_roms',
        where: 'rom_path = ?',
        whereArgs: ['/roms/snes/game.sfc'],
      );
      expect(rows.first['play_time'], 900);
      expect(
        DateTime.parse(rows.first['last_played'].toString()),
        DateTime(2026, 7, 28, 12),
      );
    });

    test('applyRemotePlayTime never moves last_played backwards', () async {
      await insertGame('/roms/snes/game.sfc');
      await db.rawUpdate(
        'UPDATE user_roms SET last_played = ? WHERE rom_path = ?',
        [DateTime(2026, 7, 28, 18).toIso8601String(), '/roms/snes/game.sfc'],
      );

      await GameRepository.applyRemotePlayTime(
        '/roms/snes/game.sfc',
        60,
        // An older session pulled from another device must not rewrite a more
        // recent local one as older.
        remoteLastPlayed: DateTime(2026, 7, 28, 9),
      );

      final rows = await db.query(
        'user_roms',
        where: 'rom_path = ?',
        whereArgs: ['/roms/snes/game.sfc'],
      );
      expect(rows.first['play_time'], 60);
      expect(
        DateTime.parse(rows.first['last_played'].toString()),
        DateTime(2026, 7, 28, 18),
      );
    });
  });
}
