import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/data/datasources/sqlite_migrations.dart';
import 'package:neostation/models/game_model.dart';
import 'package:neostation/models/romm_asset.dart';
import 'package:neostation/models/romm_rom.dart';
import 'package:neostation/providers/neo_sync_provider.dart';
import 'package:neostation/providers/romm_provider.dart';
import 'package:neostation/repositories/romm_save_map_repository.dart';
import 'package:neostation/services/neosync/neo_sync_service.dart';
import 'package:neostation/services/romm_playtime_service.dart';
import 'package:neostation/services/romm_service.dart';
import 'package:neostation/sync/providers/romm_provider.dart';

import 'database_test_helper.dart';

class _FakeRommService extends RommService {
  /// Holds the recently-played listing until completed.
  Completer<List<RommRom>>? recent;

  @override
  bool get playtimeSyncAvailable => true;

  @override
  Future<List<RommRom>> getRecentlyPlayedRoms({int limit = 25}) =>
      recent?.future ?? Future.value(const []);

  @override
  Future<List<RommAsset>> listSaves({required int romId}) async => const [];

  @override
  Future<List<RommAsset>> listStates({required int romId}) async => const [];
}

class _FakeBrowse extends RommProvider {
  final RommService fakeService;
  _FakeBrowse(this.fakeService);

  @override
  bool get isConnected => true;

  @override
  RommService get service => fakeService;
}

GameModel _game(String romname) => GameModel(
  romname: romname,
  realname: romname,
  name: romname,
  year: '1991',
  developer: '',
  publisher: '',
  genre: '',
  players: '',
  rating: 0,
  romPath: '/roms/snes/$romname',
  systemFolderName: 'snes',
  cloudSyncEnabled: true,
);

/// [RomMSyncProvider.isSyncing] and [RommPlaytimeService.isRunning], which a
/// user-data move waits on (NEO-213): a save sync and the playtime work both
/// write the database, so anything they wrote after the move copied it would
/// be lost with the old folder.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final helper = DatabaseTestHelper();
  late _FakeRommService svc;
  late RomMSyncProvider provider;
  // Holds a game sync where it looks for the game's local saves.
  Completer<void>? locating;
  // Holds the upload sweep where it lists the library.
  Completer<void>? listing;
  var locateFails = false;

  setUp(() async {
    final db = await helper.setUp();
    await db.execute(SqliteMigrations.createAppRommRomMapTableSql);
    await db.execute(SqliteMigrations.createAppRommPlaySessionsTableSql);
    await db.execute(SqliteMigrations.createAppRommPlaytimeStateTableSql);
    await RommSaveMapRepository.putMapping(
      source: RommLinkSource.download,
      romname: 'Zelda',
      systemFolder: 'snes',
      rommRomId: 7,
    );
    svc = _FakeRommService();
    locating = null;
    listing = null;
    locateFails = false;
    provider = RomMSyncProvider(
      _FakeBrowse(svc),
      NeoSyncProvider(NeoSyncService()),
      autoSweep: false,
      listGames: () async {
        await listing?.future;
        return const [];
      },
      locateSaves: (game) async {
        await locating?.future;
        if (locateFails) throw StateError('save folder unreadable');
        return const [];
      },
    );
  });

  tearDown(helper.tearDown);

  test('idle: not syncing', () {
    expect(provider.isSyncing, isFalse);
  });

  test('a game sync counts until it finishes', () async {
    locating = Completer<void>();
    final sync = provider.syncGameSavesAfterClose(_game('Zelda'));
    await pumpEventQueue();
    expect(provider.isSyncing, isTrue);

    locating!.complete();
    await sync;
    expect(provider.isSyncing, isFalse);
  });

  test('a game sync that fails stops counting', () async {
    locating = Completer<void>();
    locateFails = true;
    final sync = provider.syncGameSavesBeforeLaunch(_game('Zelda'));
    await pumpEventQueue();
    expect(provider.isSyncing, isTrue);

    locating!.complete();
    await sync;
    expect(provider.isSyncing, isFalse);
  });

  test('the upload sweep counts until it finishes', () async {
    listing = Completer<void>();
    final sweep = provider.retryPendingUploads();
    await pumpEventQueue();
    expect(provider.isSyncing, isTrue);

    listing!.complete();
    await sweep;
    expect(provider.isSyncing, isFalse);
  });

  // Highlighting a game checks its status; that writes nothing, so a server
  // that stopped answering mustn't hold up a move meanwhile.
  test('a status-only check does not count', () async {
    locating = Completer<void>();
    final check = provider.detectGameSaveFiles(_game('Zelda'));
    await pumpEventQueue();
    expect(provider.isSyncing, isFalse);

    locating!.complete();
    await check;
  });

  test('a game sync finishing first leaves the pull counted', () async {
    locating = Completer<void>();
    svc.recent = Completer<List<RommRom>>();
    final sync = provider.syncGameSavesAfterClose(_game('Zelda'));
    final pull = provider.pullRecentPlaytime();
    await pumpEventQueue();

    locating!.complete();
    await sync;
    expect(provider.isSyncing, isTrue, reason: 'the pull still runs');

    svc.recent!.complete(const []);
    await pull;
    expect(provider.isSyncing, isFalse);
  });

  test('overlapping syncs count until the last one finishes', () async {
    locating = Completer<void>();
    svc.recent = Completer<List<RommRom>>();
    final sync = provider.syncGameSavesAfterClose(_game('Zelda'));
    final pull = provider.pullRecentPlaytime();
    await pumpEventQueue();

    svc.recent!.complete(const []);
    await pull;
    expect(provider.isSyncing, isTrue, reason: 'the game sync still runs');

    locating!.complete();
    await sync;
    expect(provider.isSyncing, isFalse);
  });

  test('queueing and flushing play sessions count while they run', () async {
    final flush = RommPlaytimeService.flushQueuedSessions(svc);
    expect(RommPlaytimeService.isRunning, isTrue);
    await flush;
    expect(RommPlaytimeService.isRunning, isFalse);

    final record = RommPlaytimeService.recordCompletedSession(
      romname: 'Zelda',
      systemFolder: 'snes',
      romPath: '/roms/snes/Zelda',
      startTime: DateTime.utc(2026, 11, 6, 12),
      endTime: DateTime.utc(2026, 11, 6, 13),
    );
    expect(RommPlaytimeService.isRunning, isTrue);
    await record;
    expect(RommPlaytimeService.isRunning, isFalse);
  });

  test('the playtime pull counts until it finishes', () async {
    svc.recent = Completer<List<RommRom>>();
    final pull = provider.pullRecentPlaytime();
    await pumpEventQueue();
    expect(provider.isSyncing, isTrue);

    svc.recent!.complete(const []);
    await pull;
    expect(provider.isSyncing, isFalse);
  });
}
