import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/data/datasources/sqlite_migrations.dart';
import 'package:neostation/data/datasources/sqlite_service.dart';
import 'package:neostation/models/game_model.dart';
import 'package:neostation/models/neo_sync_models.dart';
import 'package:neostation/models/romm_asset.dart';
import 'package:neostation/providers/neo_sync_provider.dart';
import 'package:neostation/providers/romm_provider.dart';
import 'package:neostation/repositories/romm_save_map_repository.dart';
import 'package:neostation/services/neosync/neo_sync_service.dart';
import 'package:neostation/services/romm_service.dart';
import 'package:neostation/sync/providers/romm_provider.dart';

import 'database_test_helper.dart';

/// [RomMSyncProvider.invalidateGameSyncState] — the hook the link paths call
/// after writing an `app_romm_rom_map` row for a game that was already on the
/// device.
///
/// Before the link, the provider has cached [GameSyncStatus.disabled] for the
/// game (no rom id → "sync doesn't apply" → grey cloud). Nothing recomputes
/// that entry on its own, so without the invalidation the badge would stay
/// grey until a restart even though the row now exists.

/// A server with no saves at all: enough for the status computation to reach
/// a verdict other than "disabled" once a rom id resolves.
class _FakeRommService extends RommService {
  final List<int> listCalls = [];

  @override
  bool get playtimeSyncAvailable => false;

  @override
  Future<List<RommAsset>> listSaves({required int romId}) async {
    listCalls.add(romId);
    return const [];
  }

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
  romPath: '/roms/snes/$romname.sfc',
  systemFolderName: 'snes',
  cloudSyncEnabled: true,
);

void main() {
  final helper = DatabaseTestHelper();
  late DatabaseAdapter db;
  late _FakeRommService svc;
  late RomMSyncProvider provider;
  late int notifications;

  setUp(() async {
    db = await helper.setUp();
    await db.execute(SqliteMigrations.createAppRommRomMapTableSql);
    svc = _FakeRommService();
    notifications = 0;
    provider = RomMSyncProvider(
      _FakeBrowse(svc),
      NeoSyncProvider(NeoSyncService()),
      locateSaves: (_) async => const [],
      resolveTargets: (_, name) async => const [],
      listGames: () async => const [],
      autoSweep: false,
    )..addListener(() => notifications++);
  });

  tearDown(() async {
    await helper.tearDown();
  });

  test('a disabled state is recomputed after invalidation', () async {
    final game = _game('Chrono Trigger');

    // Unlinked: the status computation caches "disabled" and never asks the
    // server, exactly the grey-cloud state a pre-existing ROM sits in.
    await provider.detectGameSaveFiles(game);
    expect(
      provider.getGameSyncState(game.romname)?.status,
      GameSyncStatus.disabled,
    );
    expect(svc.listCalls, isEmpty);

    // The link path writes the row...
    expect(
      await RommSaveMapRepository.putMappingIfAbsent(
        romname: 'Chrono Trigger.sfc',
        systemFolder: 'snes',
        rommRomId: 7,
      ),
      RommMappingWriteResult.written,
    );
    // ...and, on its own, that changes nothing the badge can see.
    expect(
      provider.getGameSyncState(game.romname)?.status,
      GameSyncStatus.disabled,
    );

    notifications = 0;
    provider.invalidateGameSyncState(game.romname);

    expect(
      provider.getGameSyncState(game.romname),
      isNull,
      reason: 'the cached entry is dropped, not merely flagged',
    );
    expect(notifications, 1, reason: 'listeners learn the state is gone');

    await provider.detectGameSaveFiles(game);
    final state = provider.getGameSyncState(game.romname);
    expect(state, isNotNull);
    expect(state!.status, isNot(GameSyncStatus.disabled));
    expect(svc.listCalls, [
      7,
    ], reason: 'the recomputation resolved the new link');
  });

  test('invalidating a game with no cached state is a silent no-op', () {
    provider.invalidateGameSyncState('Never Seen');

    expect(provider.getGameSyncState('Never Seen'), isNull);
    expect(notifications, 0);
  });

  test('only the named game is forgotten', () async {
    final a = _game('Alpha');
    final b = _game('Beta');
    await provider.detectGameSaveFiles(a);
    await provider.detectGameSaveFiles(b);

    provider.invalidateGameSyncState(a.romname);

    expect(provider.getGameSyncState(a.romname), isNull);
    expect(provider.getGameSyncState(b.romname), isNotNull);
  });
}
