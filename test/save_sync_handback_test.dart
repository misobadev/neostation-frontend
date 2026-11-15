import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/models/game_model.dart';
import 'package:neostation/models/neo_sync_models.dart';
import 'package:neostation/sync/i_sync_provider.dart';
import 'package:neostation/sync/providers/neo_sync_adapter.dart';
import 'package:neostation/sync/providers/romm_provider.dart';
import 'package:neostation/sync/sync_manager.dart';

/// Guards the rule that signing out of a provider must not leave it holding
/// save sync.
///
/// Both RomM disconnect paths (the library header's logout button and the
/// connect panel's Disconnect row) call [SyncManager.releaseIfActive]. Without
/// it, "romm" stays active against a server the user just forgot, every save
/// hook errors out, NeoSync sits idle, and nothing on screen connects the dead
/// sync to the disconnect that caused it. There was no coverage of this before;
/// the same gap is why `RomMSyncProvider.logout()` was written without a
/// handback and nobody noticed.
void main() {
  late _FakeProvider neoSync;
  late _FakeProvider romm;
  late List<String> persisted;

  setUp(() {
    neoSync = _FakeProvider(NeoSyncAdapter.kProviderId, 'NeoSync');
    romm = _FakeProvider(RomMSyncProvider.kProviderId, 'RomM');
    persisted = [];
    SyncManager.instance.register(neoSync);
    SyncManager.instance.register(romm);
  });

  tearDown(() {
    // The manager is a singleton, so an un-torn-down registration leaks into
    // every later test in the run.
    SyncManager.instance.unregister(RomMSyncProvider.kProviderId);
    SyncManager.instance.unregister(NeoSyncAdapter.kProviderId);
  });

  Future<void> persist(String id) async => persisted.add(id);

  test('disconnecting the active provider hands save sync back to NeoSync', () async {
    await SyncManager.instance.setActive(
      RomMSyncProvider.kProviderId,
      persist: persist,
    );
    persisted.clear();

    final moved = await SyncManager.instance.releaseIfActive(
      RomMSyncProvider.kProviderId,
      persist: persist,
    );

    expect(moved, isTrue);
    expect(SyncManager.instance.activeProviderId, NeoSyncAdapter.kProviderId);
    // Persisted, not just held in memory: the choice has to survive a restart,
    // or the next launch resurrects the disconnected provider.
    expect(persisted, [NeoSyncAdapter.kProviderId]);
  });

  test(
    'disconnecting a provider that does not own save sync changes nothing',
    () async {
      await SyncManager.instance.setActive(
        NeoSyncAdapter.kProviderId,
        persist: persist,
      );
      persisted.clear();

      final moved = await SyncManager.instance.releaseIfActive(
        RomMSyncProvider.kProviderId,
        persist: persist,
      );

      expect(moved, isFalse);
      expect(SyncManager.instance.activeProviderId, NeoSyncAdapter.kProviderId);
      // A NeoSync user who merely disconnects a RomM server must not have their
      // setting rewritten underneath them.
      expect(persisted, isEmpty);
    },
  );

  test(
    'handing back notifies listeners so the UI can drop its owner line',
    () async {
      await SyncManager.instance.setActive(
        RomMSyncProvider.kProviderId,
        persist: persist,
      );
      var notifications = 0;
      void listener() => notifications++;
      SyncManager.instance.addListener(listener);
      addTearDown(() => SyncManager.instance.removeListener(listener));

      await SyncManager.instance.releaseIfActive(
        RomMSyncProvider.kProviderId,
        persist: persist,
      );

      expect(notifications, greaterThan(0));
    },
  );
}

/// Minimal [ISyncProvider] stand-in: these tests only exercise registration and
/// active-id bookkeeping, so every transfer method is left unimplemented.
class _FakeProvider implements ISyncProvider {
  _FakeProvider(this.providerId, this._name);

  @override
  final String providerId;

  final String _name;

  @override
  SyncProviderMeta get meta => SyncProviderMeta(
    id: providerId,
    name: _name,
    description: '',
    author: '',
  );

  @override
  SyncProviderStatus get status => SyncProviderStatus.connected;

  @override
  bool get isAuthenticated => true;

  @override
  String? get lastError => null;

  @override
  Future<void> initialize() async {}

  @override
  void dispose() {}

  @override
  Future<SyncResult> login() async => SyncResult.ok();

  @override
  Future<void> logout() async {}

  @override
  Future<SyncResult> uploadSave(
    String gameId,
    File file, {
    String? customFileName,
  }) async => SyncResult.ok();

  @override
  Future<SyncResult> downloadSave(String gameId, String fileId) async =>
      SyncResult.ok();

  @override
  Future<List<SyncFile>> listSaves({String? gameId}) async => const [];

  @override
  Future<SyncResult> fullSync() async => SyncResult.ok();

  @override
  Future<SyncResult> detectGameSaveFiles(GameModel game) async =>
      SyncResult.ok();

  @override
  GameSyncState? getGameSyncState(String gameId) => null;

  @override
  Future<SyncResult> syncGameSavesBeforeLaunch(
    GameModel game, {
    SyncDeadline? deadline,
  }) async => SyncResult.ok();

  @override
  Future<SyncResult> syncGameSavesAfterClose(GameModel game) async =>
      SyncResult.ok();

  @override
  Future<void> updateGameCloudSyncEnabled(String gameId, bool enabled) async {}

  @override
  Future<SyncQuota?> getQuota() async => null;

  @override
  Future<SyncResult> deleteRemote(String fileId) async => SyncResult.ok();
}
