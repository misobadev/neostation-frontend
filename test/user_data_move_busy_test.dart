import 'dart:async';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/models/romm_rom.dart';
import 'package:neostation/providers/neo_sync_provider.dart';
import 'package:neostation/providers/romm_provider.dart';
import 'package:neostation/providers/scraping_provider.dart';
import 'package:neostation/providers/sqlite_config_provider.dart';
import 'package:neostation/services/esde_import_service.dart';
import 'package:neostation/services/library_file_tool_lock.dart';
import 'package:neostation/services/neosync/neo_sync_service.dart';
import 'package:neostation/services/romm_playtime_service.dart';
import 'package:neostation/services/romm_service.dart';
import 'package:neostation/sync/providers/romm_provider.dart';
import 'package:neostation/sync/sync_manager.dart';
import 'package:neostation/utils/user_data_move_busy.dart';
import 'package:provider/provider.dart';

class _HeldRommService extends RommService {
  final recent = Completer<List<RommRom>>();

  @override
  bool get playtimeSyncAvailable => true;

  @override
  Future<List<RommRom>> getRecentlyPlayedRoms({int limit = 25}) =>
      recent.future;
}

class _NoPlaytime extends RommService {
  @override
  bool get playtimeSyncAvailable => false;
}

class _ConnectedBrowse extends RommProvider {
  final RommService fakeService;
  _ConnectedBrowse(this.fakeService);

  @override
  bool get isConnected => true;

  @override
  RommService get service => fakeService;
}

/// NEO-213: a move copies the database once, so anything a scan, scrape, sync,
/// import or tool writes after that copy is lost with the old folder.
void main() {
  tearDown(LibraryFileToolLock.debugReset);

  Future<BuildContext> pumpProviders(WidgetTester tester) async {
    late BuildContext context;
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider(create: (_) => SqliteConfigProvider()),
          ChangeNotifierProvider(create: (_) => ScrapingProvider()),
          ChangeNotifierProvider(create: (_) => RommProvider()),
          ChangeNotifierProvider(
            create: (_) => NeoSyncProvider(NeoSyncService()),
          ),
        ],
        child: Builder(
          builder: (c) {
            context = c;
            return const SizedBox();
          },
        ),
      ),
    );
    return context;
  }

  testWidgets('nothing running: the move can go ahead', (tester) async {
    final context = await pumpProviders(tester);
    expect(userDataMoveBusy(context), isFalse);
  });

  testWidgets('a library tool running: the move waits', (tester) async {
    final context = await pumpProviders(tester);
    expect(LibraryFileToolLock.tryAcquire('orphan_cleanup'), isTrue);

    expect(userDataMoveBusy(context), isTrue);

    LibraryFileToolLock.release('orphan_cleanup');
    expect(userDataMoveBusy(context), isFalse);
  });

  // Registered whether or not RomM is the save provider.
  testWidgets('a RomM save sync running: the move waits', (tester) async {
    final context = await pumpProviders(tester);
    final svc = _HeldRommService();
    final romm = RomMSyncProvider(
      _ConnectedBrowse(svc),
      NeoSyncProvider(NeoSyncService()),
      autoSweep: false,
    );
    SyncManager.instance.register(romm);
    addTearDown(() => SyncManager.instance.unregister(romm.providerId));

    final pull = romm.pullRecentPlaytime();
    expect(userDataMoveBusy(context), isTrue);

    svc.recent.complete(const []);
    await tester.runAsync(() => pull);
    expect(userDataMoveBusy(context), isFalse);
  });

  testWidgets('play sessions being flushed: the move waits', (tester) async {
    final context = await pumpProviders(tester);
    // No playtime support on the server: the flush returns at once, but it
    // still counts until it does.
    final flush = RommPlaytimeService.flushQueuedSessions(_NoPlaytime());
    expect(userDataMoveBusy(context), isTrue);

    await flush;
    expect(userDataMoveBusy(context), isFalse);
  });

  test('an ES-DE import counts as running until it returns', () async {
    final empty = Directory.systemTemp.createTempSync('neostation_esde_');
    addTearDown(() => empty.deleteSync(recursive: true));

    // No gamelists/ folder: the import returns without touching the database.
    final run = EsdeImportService.import(empty.path);
    expect(EsdeImportService.isRunning, isTrue);
    await run;
    expect(EsdeImportService.isRunning, isFalse);
  });
}
