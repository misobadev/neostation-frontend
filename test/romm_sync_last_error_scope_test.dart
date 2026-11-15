import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:neostation/models/romm_platform.dart';
import 'package:neostation/providers/neo_sync_provider.dart';
import 'package:neostation/providers/romm_provider.dart';
import 'package:neostation/services/neosync/neo_sync_service.dart';
import 'package:neostation/services/romm_service.dart';
import 'package:neostation/sync/i_sync_provider.dart';
import 'package:neostation/sync/providers/romm_provider.dart';

// The game list's NeoSync mark turns red whenever the active sync provider
// reports an error. RomM's sync provider used to pass on the browse
// provider's last error, so a collections load or a search that failed in
// the RomM tab marked the highlighted game as failing to sync, while RomM
// itself was still connected and the game's saves were fine.

/// Connected without `connect()`, which would write the account to the
/// database.
class _ConnectedBrowse extends RommProvider {
  @override
  RommConnectionStatus get status => RommConnectionStatus.connected;

  @override
  bool get isConnected => true;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final snes = RommPlatform(id: 12, name: 'SNES', slug: 'snes');

  /// A RomM that answers signing in with [signIn] and everything else with
  /// 500.
  void serveBrowseBroken({int signIn = 200}) {
    RommService.debugUseHttpClient(
      MockClient((request) async {
        switch (request.url.path) {
          case '/api/users/me':
            return http.Response(
              jsonEncode({'id': 1, 'username': 'player'}),
              signIn,
              headers: const {'content-type': 'application/json'},
            );
        }
        return http.Response('boom', 500);
      }),
    );
  }

  RomMSyncProvider syncOver(RommProvider browse) {
    final sync = RomMSyncProvider(
      browse,
      NeoSyncProvider(NeoSyncService()),
      locateSaves: (_) async => const [],
      resolveTargets: (_, name) async => const [],
      listGames: () async => const [],
      autoSweep: false,
    );
    addTearDown(sync.dispose);
    return sync;
  }

  RommProvider connected() {
    final browse = _ConnectedBrowse();
    browse.service.configure(
      serverUrl: 'https://romm.local',
      apiKey: 'test-key',
    );
    addTearDown(browse.dispose);
    return browse;
  }

  tearDown(() => RommService.debugUseHttpClient(null));

  test('a failed collections load is not a sync error', () async {
    serveBrowseBroken();
    final browse = connected();
    final sync = syncOver(browse);

    await browse.loadCollections();

    expect(browse.lastError, isNotNull, reason: 'the load should fail');
    expect(sync.lastError, isNull);
  });

  test('a failed search is not a sync error', () async {
    serveBrowseBroken();
    final browse = connected();
    final sync = syncOver(browse);

    await browse.selectPlatform(snes, search: 'mario');

    expect(browse.lastError, isNotNull, reason: 'the search should fail');
    expect(sync.lastError, isNull);
  });

  test('a rejected connection is still reported', () async {
    serveBrowseBroken(signIn: 401);
    final browse = RommProvider();
    addTearDown(browse.dispose);
    final sync = syncOver(browse);

    await browse.connect(serverUrl: 'https://romm.local', apiKey: 'bad-key');

    expect(sync.status, SyncProviderStatus.error);
    expect(sync.lastError, isNotNull);
  });
}
