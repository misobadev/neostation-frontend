import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/data/datasources/sqlite_migrations.dart';
import 'package:neostation/data/datasources/sqlite_service.dart';
import 'package:neostation/models/romm_play_session.dart';
import 'package:neostation/models/romm_rom.dart';
import 'package:neostation/providers/neo_sync_provider.dart';
import 'package:neostation/providers/romm_provider.dart';
import 'package:neostation/repositories/romm_playtime_repository.dart';
import 'package:neostation/repositories/romm_save_map_repository.dart';
import 'package:neostation/services/neosync/neo_sync_service.dart';
import 'package:neostation/services/romm_service.dart';
import 'package:neostation/sync/providers/romm_provider.dart';

import 'database_test_helper.dart';

/// The connect-time playtime pull ([RomMSyncProvider.pullRecentPlaytime]).
///
/// Sessions were already pushed on connect regardless of the save-sync toggle,
/// but the matching *pull* only ran inside a RomM-active save sync — so a user
/// who keeps NeoSync as their save provider uploaded their play and never got
/// anyone else's back. These tests pin the two properties that make closing
/// that gap safe to do automatically:
///
/// 1. **It is bounded by what the server says was played.** The candidate list
///    is one request; a library of linked games that nobody has played costs
///    exactly that and no session lookups.
/// 2. **It is not gated on the active save provider,** because playtime is a
///    statistic — but it also never touches a save, so that is not a licence
///    the save-sync rules care about.

class _FakeRommService extends RommService {
  /// ROMs the server reports as played, newest first.
  List<RommRom> recentlyPlayed = [];

  /// Sessions per rom id, as the server would return them.
  final Map<int, List<RommPlaySession>> sessionsByRom = {};

  /// rom ids whose sessions were fetched — the pull's network footprint.
  final List<int> sessionCalls = [];
  int recentCalls = 0;

  /// Server failures to simulate.
  bool failListing = false;
  final Set<int> failSessionsFor = {};

  @override
  bool get playtimeSyncAvailable => true;

  @override
  Future<List<RommRom>> getRecentlyPlayedRoms({int limit = 25}) async {
    recentCalls++;
    if (failListing) throw Exception('500 from the server');
    return recentlyPlayed.take(limit).toList();
  }

  @override
  Future<List<RommPlaySession>> getPlaySessions({required int romId}) async {
    sessionCalls.add(romId);
    if (failSessionsFor.contains(romId)) throw Exception('503');
    return sessionsByRom[romId] ?? const [];
  }
}

class _FakeBrowse extends RommProvider {
  final RommService fakeService;
  bool connected = true;
  _FakeBrowse(this.fakeService);

  @override
  bool get isConnected => connected;

  @override
  RommService get service => fakeService;
}

RommRom _rom(int id, String name) => RommRom(
  id: id,
  name: name,
  platformId: 1,
  platformSlug: 'snes',
  fsName: '$name.zip',
  fsNameNoExt: name,
  fsExtension: 'zip',
);

RommPlaySession _session(int romId, int minutes) {
  final end = DateTime.utc(2026, 8, 9, 12);
  return RommPlaySession(
    romId: romId,
    startTime: end.subtract(Duration(minutes: minutes)),
    endTime: end,
    durationMs: minutes * 60 * 1000,
  );
}

void main() {
  final helper = DatabaseTestHelper();
  late DatabaseAdapter db;
  late _FakeRommService svc;
  late _FakeBrowse browse;
  late RomMSyncProvider provider;

  /// A game in the local library, optionally linked to a RomM rom id.
  Future<void> localGame(
    String romname, {
    int? romId,
    String storedName = '',
    String folder = 'snes',
  }) async {
    await db.execute(
      "INSERT OR IGNORE INTO app_systems (id, folder_name) VALUES ('sys_$folder', '$folder')",
    );
    await db.execute(
      'INSERT INTO user_roms (filename, rom_path, app_system_id, play_time) '
      "VALUES ('$romname', '/roms/$folder/$romname', 'sys_$folder', 0)",
    );
    if (romId != null) {
      await RommSaveMapRepository.putMapping(
        source: RommLinkSource.download,
        // The mapping is written with the on-disk filename; the library row
        // carries it stripped. Defaulting to "<romname>.zip" keeps every test
        // on the mismatching spelling, which is the case that used to miss.
        romname: storedName.isEmpty ? '$romname.zip' : storedName,
        systemFolder: folder,
        rommRomId: romId,
      );
    }
  }

  Future<int> localPlayTime(String romname, {String folder = 'snes'}) async {
    final rows = await db.query(
      'user_roms',
      columns: ['play_time'],
      where: 'rom_path = ?',
      whereArgs: ['/roms/$folder/$romname'],
    );
    return int.parse(rows.first['play_time'].toString());
  }

  setUp(() async {
    db = await helper.setUp();
    await db.execute(SqliteMigrations.createAppRommRomMapTableSql);
    await db.execute(SqliteMigrations.createAppRommPlaySessionsTableSql);
    await db.execute(SqliteMigrations.createAppRommPlaytimeStateTableSql);

    svc = _FakeRommService();
    browse = _FakeBrowse(svc);
    provider = RomMSyncProvider(
      browse,
      NeoSyncProvider(NeoSyncService()),
      // The pull rides the same 30s connect timer as the sweep; these tests
      // drive it directly rather than waiting one out.
      autoSweep: false,
    );
  });

  tearDown(helper.tearDown);

  group('what the pull folds in', () {
    test('playtime from another device lands on the local row', () async {
      await localGame('Zelda', romId: 7);
      svc.recentlyPlayed = [_rom(7, 'Zelda')];
      svc.sessionsByRom[7] = [_session(7, 30)];

      await provider.pullRecentPlaytime();

      expect(await localPlayTime('Zelda'), 30 * 60);
    });

    test('our own pushed sessions are not counted twice', () async {
      await localGame('Zelda', romId: 7);
      // 30 minutes on the server, all of it pushed from this device — so
      // `user_roms.play_time` already counts it and the pull must add nothing.
      await RommPlaytimeRepository.addPushedMs(7, 30 * 60 * 1000);
      svc.recentlyPlayed = [_rom(7, 'Zelda')];
      svc.sessionsByRom[7] = [_session(7, 30)];

      await provider.pullRecentPlaytime();

      expect(await localPlayTime('Zelda'), 0);
    });

    test('a second pull adds nothing new (idempotent)', () async {
      await localGame('Zelda', romId: 7);
      svc.recentlyPlayed = [_rom(7, 'Zelda')];
      svc.sessionsByRom[7] = [_session(7, 30)];

      await provider.pullRecentPlaytime();
      // The 5-minute throttle would mask a double-count here, so clear it and
      // make the second pull do the full round trip.
      await RommPlaytimeRepository.setRemoteApplied(
        7,
        (await RommPlaytimeRepository.getLedger(7)).remoteAppliedMs,
      );
      await provider.pullRecentPlaytime();

      expect(await localPlayTime('Zelda'), 30 * 60);
    });
  });

  group('what it costs', () {
    test('never-played ROMs are never asked about', () async {
      // Three linked games in the library, none of them played anywhere: the
      // server leaves them out of the candidate list, so the pull spends one
      // request in total. This is the property that makes it affordable to run
      // on every connect after a bulk sync of hundreds of ROMs.
      await localGame('Zelda', romId: 7);
      await localGame('Mario', romId: 8);
      await localGame('Metroid', romId: 9);
      svc.recentlyPlayed = [];

      await provider.pullRecentPlaytime();

      expect(svc.recentCalls, 1);
      expect(svc.sessionCalls, isEmpty);
    });

    test('a played ROM that is not linked here is skipped', () async {
      // Played on another device, never downloaded here: there is no local row
      // to fold it into, and asking for its sessions would be a wasted request.
      svc.recentlyPlayed = [_rom(7, 'Zelda'), _rom(8, 'Mario')];
      await localGame('Zelda', romId: 7);
      svc.sessionsByRom[7] = [_session(7, 10)];
      svc.sessionsByRom[8] = [_session(8, 99)];

      await provider.pullRecentPlaytime();

      expect(svc.sessionCalls, [7]);
      expect(await localPlayTime('Zelda'), 10 * 60);
    });

    test('the throttle stops a reconnect from re-fetching sessions', () async {
      await localGame('Zelda', romId: 7);
      svc.recentlyPlayed = [_rom(7, 'Zelda')];
      svc.sessionsByRom[7] = [_session(7, 30)];

      await provider.pullRecentPlaytime();
      await provider.pullRecentPlaytime();

      // Two candidate listings, but only one session lookup: reconnecting
      // inside the throttle window costs a single request.
      expect(svc.recentCalls, 2);
      expect(svc.sessionCalls, [7]);
    });
  });

  group('when it does nothing', () {
    test('a disconnected provider makes no request at all', () async {
      await localGame('Zelda', romId: 7);
      svc.recentlyPlayed = [_rom(7, 'Zelda')];
      browse.connected = false;

      await provider.pullRecentPlaytime();

      expect(svc.recentCalls, 0);
    });

    test('a listing failure is swallowed, not thrown', () async {
      await localGame('Zelda', romId: 7);
      svc.recentlyPlayed = [_rom(7, 'Zelda')];
      svc.sessionsByRom[7] = [_session(7, 30)];
      svc.failListing = true;

      // A pull that throws would take the upload sweep down with it: both run
      // from the same connect timer, and the sweep is the one carrying save
      // data.
      await expectLater(provider.pullRecentPlaytime(), completes);
      expect(svc.sessionCalls, isEmpty);
      expect(await localPlayTime('Zelda'), 0);
    });

    test('one ROM failing does not stop the rest', () async {
      await localGame('Zelda', romId: 7);
      await localGame('Mario', romId: 8);
      svc.recentlyPlayed = [_rom(7, 'Zelda'), _rom(8, 'Mario')];
      svc.sessionsByRom[8] = [_session(8, 12)];
      svc.failSessionsFor.add(7);

      await expectLater(provider.pullRecentPlaytime(), completes);

      expect(await localPlayTime('Mario'), 12 * 60);
    });
  });

  group('linking the server id back to a local row', () {
    test('matches when the mapping kept the file extension', () async {
      // The mapping is written as "Zelda.zip" while `user_roms.filename` is
      // "Zelda". An exact-match-only lookup misses every game launched
      // normally, and an unresolved id reads as "not a RomM game".
      await localGame('Zelda', romId: 7, storedName: 'Zelda.zip');
      svc.recentlyPlayed = [_rom(7, 'Zelda')];
      svc.sessionsByRom[7] = [_session(7, 15)];

      await provider.pullRecentPlaytime();

      expect(await localPlayTime('Zelda'), 15 * 60);
    });

    test('matches when the mapping kept no extension', () async {
      await localGame('Zelda', romId: 7, storedName: 'Zelda');
      svc.recentlyPlayed = [_rom(7, 'Zelda')];
      svc.sessionsByRom[7] = [_session(7, 15)];

      await provider.pullRecentPlaytime();

      expect(await localPlayTime('Zelda'), 15 * 60);
    });

    test('a title with its own dot is not cut short', () async {
      // "Mr. Do.zip" stripped once is "Mr. Do"; stripping the library row's
      // name too would make it "Mr", matching nothing.
      await localGame('Mr. Do', romId: 7, storedName: 'Mr. Do.zip');
      svc.recentlyPlayed = [_rom(7, 'Mr. Do')];
      svc.sessionsByRom[7] = [_session(7, 20)];

      await provider.pullRecentPlaytime();

      expect(await localPlayTime('Mr. Do'), 20 * 60);
    });

    test('the same name in another system is not confused for it', () async {
      // Two systems, one filename: the mapping is per (name, folder), so the
      // wrong row must not absorb the playtime.
      await localGame('Zelda', romId: 7, folder: 'snes');
      await localGame('Zelda', romId: null, folder: 'nes');
      svc.recentlyPlayed = [_rom(7, 'Zelda')];
      svc.sessionsByRom[7] = [_session(7, 25)];

      await provider.pullRecentPlaytime();

      expect(await localPlayTime('Zelda', folder: 'snes'), 25 * 60);
      expect(await localPlayTime('Zelda', folder: 'nes'), 0);
    });
  });
}
