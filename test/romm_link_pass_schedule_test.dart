import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/models/romm_link_row.dart';
import 'package:neostation/models/romm_platform.dart';
import 'package:neostation/models/romm_rom.dart';
import 'package:neostation/models/romm_rom_page.dart';
import 'package:neostation/models/system_model.dart';
import 'package:neostation/models/sync_models.dart';
import 'package:neostation/providers/neo_sync_provider.dart';
import 'package:neostation/providers/romm_provider.dart';
import 'package:neostation/repositories/romm_save_map_repository.dart';
import 'package:neostation/services/logger_service.dart';
import 'package:neostation/services/neosync/neo_sync_service.dart';
import 'package:neostation/services/romm/romm_library_linker.dart';
import 'package:neostation/services/romm_service.dart';
import 'package:neostation/sync/providers/romm_provider.dart';
import 'package:neostation/sync/sync_manager.dart';

import 'database_test_helper.dart';

/// How [RomMSyncProvider] schedules the connect-time link pass: after a
/// disconnected → connected transition it runs before the pending-upload
/// sweep, under that sweep's guards, never overlapping itself, and
/// invalidates the linked games' cached state once per run rather than once
/// per game.
///
/// The linker itself is a recording fake — its algorithm has its own tests —
/// so the linker is faked here, but the real platform loader classifies against app_systems, so a test database is seeded.

class _FakeRommService extends RommService {
  /// What [getPlatforms] answers — after [platformsGate] completes, when one
  /// is set, so a test can hold a platform load open.
  List<RommPlatform> platforms = const [];
  Completer<void>? platformsGate;

  @override
  bool get playtimeSyncAvailable => false;

  @override
  Future<List<RommPlatform>> getPlatforms() async {
    final gate = platformsGate;
    if (gate != null) await gate.future;
    return platforms;
  }
}

class _FakeBrowse extends RommProvider {
  final RommService fakeService;
  bool connected = false;
  int cacheInvalidations = 0;

  /// Reports "loading" with nothing in flight and an empty list, the state
  /// left behind when a forced reload starts under the pass.
  bool stuckLoading = false;

  _FakeBrowse(this.fakeService);

  @override
  bool get isConnected => connected;

  @override
  RommService get service => fakeService;

  @override
  bool get isLoadingPlatforms => stuckLoading || super.isLoadingPlatforms;

  @override
  Future<void> loadPlatforms({bool force = false}) {
    if (stuckLoading) return Future.value();
    return super.loadPlatforms(force: force);
  }

  @override
  void invalidateDownloadedCache() => cacheInvalidations++;

  void goOnline() {
    connected = true;
    notifyListeners();
  }
}

/// Records each run, optionally holding it open until [release] is called.
class _FakeLinker extends RommLibraryLinker {
  final List<String> events;
  RommLinkPassSummary result = const RommLinkPassSummary();
  Completer<void>? _gate;
  int runs = 0;

  _FakeLinker(this.events)
    : super(
        listPlatforms: () async => const [],
        resolveSystem: (_) async => null,
        fetchPage: ({required platformId, required limit, required offset}) =>
            throw UnimplementedError(),
        listGames: () async => const [],
        loadRomIdIndex: () async => const RommRomIdIndex({}),
        putMappingsIfAbsent: (_) async => (inserted: 0, failed: false),
      );

  void hold() => _gate = Completer<void>();
  void release() => _gate?.complete();

  @override
  Future<RommLinkPassSummary> run() async {
    runs++;
    events.add('link');
    final gate = _gate;
    if (gate != null) await gate.future;
    return result;
  }
}

/// The provider with the sweep replaced by a recorder, so the order of the
/// connect-time work can be asserted without any saves on disk.
class _RecordingProvider extends RomMSyncProvider {
  final List<String> events;

  _RecordingProvider(
    super.browse,
    super.neoSync, {
    required this.events,
    required super.linker,
    super.autoSweep,
  }) : super(sweepStartupDelay: Duration.zero);

  bool disposed = false;

  @override
  void dispose() {
    if (disposed) return;
    disposed = true;
    super.dispose();
  }

  @override
  Future<SyncResult> retryPendingUploads() async {
    events.add('sweep');
    return SyncResult.ok();
  }
}

const _snes = SystemModel(
  folderName: 'snes',
  realName: 'SNES',
  iconImage: '',
  color: '#000000',
  folders: ['snes'],
);

void main() {
  // The real platform load classifies platforms against the systems table,
  // so the tests that let it run need a database — an empty one will do.
  final helper = DatabaseTestHelper();
  late _FakeBrowse browse;
  late List<String> events;
  late _FakeLinker linker;
  late _RecordingProvider provider;

  /// A real linker over in-memory fakes whose platform list comes from the
  /// provider's own lister — the seam under test. One unlinked local game,
  /// one server ROM named the same, so a run that sees the platform links it.
  RommLibraryLinker realLinker() => RommLibraryLinker(
    listPlatforms: () => provider.listPlatformsForLinkPass(),
    resolveSystem: (_) async => _snes,
    fetchPage: ({required platformId, required limit, required offset}) async =>
        RommRomPage(
          items: [
            RommRom(
              id: 10,
              name: 'Game',
              platformId: platformId,
              platformSlug: 'snes',
              fsName: 'Game.sfc',
              fsNameNoExt: 'Game',
              fsExtension: 'sfc',
            ),
          ],
          total: 1,
        ),
    listGames: () async => [
      rommLinkRow(filename: 'Game.sfc', systemFolder: 'snes'),
    ],
    loadRomIdIndex: () async => const RommRomIdIndex({}),
    putMappingsIfAbsent: (entries) async =>
        (inserted: entries.length, failed: false),
  );

  setUp(() async {
    await helper.setUp();
    browse = _FakeBrowse(_FakeRommService());
    events = [];
    linker = _FakeLinker(events);
    LoggerService.instance.startCapture();
  });

  tearDown(() async {
    LoggerService.instance.takeCapture();
    SyncManager.instance.unregister(RomMSyncProvider.kProviderId);
    provider.dispose();
    await helper.tearDown();
  });

  /// Builds the provider and makes RomM the active save provider, so the
  /// sweep half of the connect-time work is not gated off.
  Future<void> build({
    bool autoSweep = true,
    RommLibraryLinker? withLinker,
  }) async {
    provider = _RecordingProvider(
      browse,
      NeoSyncProvider(NeoSyncService()),
      events: events,
      linker: withLinker ?? linker,
      autoSweep: autoSweep,
    );
    SyncManager.instance.register(provider);
    await SyncManager.instance.setActive(
      RomMSyncProvider.kProviderId,
      persist: (_) async {},
    );
  }

  group('on connect', () {
    test('the pass runs, then the sweep', () async {
      await build();
      browse.goOnline();
      await pumpEventQueue();

      expect(events, ['link', 'sweep']);
    });

    test('a bulk ROM sync in progress skips the pass', () async {
      await build();
      final firstPage = Completer<RommRomPage>();
      final sync = browse.bulkSync.run(
        sourceLabel: 'SNES',
        fetchPage: ({required limit, required offset}) => firstPage.future,
        isDownloaded: (_) async => false,
        download: (_) async => throw UnimplementedError(),
      );
      expect(browse.bulkSync.isRunning, isTrue);

      browse.goOnline();
      await pumpEventQueue();

      expect(linker.runs, 0);
      expect(events, isEmpty);
      // The sweep's own guard fires first and names the reason; the pass is
      // never reached, so nothing else needs to say it again.
      final skipped = LoggerService.instance.takeCapture().where(
        (l) => l.contains('a bulk ROM sync is running'),
      );
      expect(skipped, hasLength(1), reason: 'one log line says why');

      firstPage.complete(const RommRomPage(items: []));
      await sync;
    });

    test('a disconnect before the delay elapses skips everything', () async {
      await build();
      browse.goOnline();
      browse.connected = false;
      await pumpEventQueue();

      expect(linker.runs, 0);
      expect(events, isEmpty);
    });

    test('a connected provider at construction runs the pass too', () async {
      browse.connected = true;
      await build();
      await pumpEventQueue();

      expect(events, ['link', 'sweep']);
    });
  });

  group('linkLibrary', () {
    test('the linked games are invalidated once, not per game', () async {
      await build(autoSweep: false);
      browse.connected = true;
      linker.result = const RommLinkPassSummary(
        rowsAdded: 3,
        linkedRomnames: ['A', 'B', 'C'],
      );
      var notifications = 0;
      provider.addListener(() => notifications++);

      final summary = await provider.linkLibrary();

      expect(summary?.rowsAdded, 3);
      expect(browse.cacheInvalidations, 1);
      expect(notifications, 0, reason: 'nothing was cached for these games');
    });

    test('a pass that linked nothing invalidates nothing', () async {
      await build(autoSweep: false);
      browse.connected = true;

      await provider.linkLibrary();

      expect(browse.cacheInvalidations, 0);
    });

    test('a second call while one is in flight is skipped', () async {
      await build(autoSweep: false);
      browse.connected = true;
      linker.hold();

      final first = provider.linkLibrary();
      final second = await provider.linkLibrary();

      expect(second, isNull);
      expect(linker.runs, 1);
      linker.release();
      expect(await first, isNotNull);
      expect(
        LoggerService.instance.takeCapture(),
        contains('i|RomM link pass skipped: a pass is already running'),
      );
    });

    test('a bulk ROM sync in progress is refused with a reason', () async {
      await build(autoSweep: false);
      browse.connected = true;
      final firstPage = Completer<RommRomPage>();
      final sync = browse.bulkSync.run(
        sourceLabel: 'SNES',
        fetchPage: ({required limit, required offset}) => firstPage.future,
        isDownloaded: (_) async => false,
        download: (_) async => throw UnimplementedError(),
      );

      expect(await provider.linkLibrary(), isNull);
      expect(linker.runs, 0);

      firstPage.complete(const RommRomPage(items: []));
      await sync;
    });

    test('disconnected: skipped', () async {
      await build(autoSweep: false);

      expect(await provider.linkLibrary(), isNull);
      expect(linker.runs, 0);
    });

    test('a platform load in flight is awaited, not raced', () async {
      final svc = browse.fakeService as _FakeRommService;
      svc.platforms = [
        const RommPlatform(id: 1, name: 'SNES', slug: 'snes', romCount: 1),
      ];
      svc.platformsGate = Completer<void>();
      await build(autoSweep: false, withLinker: realLinker());
      browse.connected = true;

      // The browse screen's load, still waiting on the server.
      final load = browse.loadPlatforms();
      expect(browse.isLoadingPlatforms, isTrue);

      final pass = provider.linkLibrary();
      await pumpEventQueue();
      expect(
        LoggerService.instance.takeCapture(),
        contains(
          'i|RomM link pass waiting: the platform list is still loading',
        ),
      );

      svc.platformsGate!.complete();
      await load;
      final summary = await pass;

      expect(summary, isNotNull);
      expect(summary!.platformsProcessed, 1);
      expect(summary.rowsAdded, 1, reason: 'the pass saw the loaded list');
    });

    test(
      'a list still loading after the wait fails the pass by name',
      () async {
        await build(autoSweep: false, withLinker: realLinker());
        browse.connected = true;
        browse.stuckLoading = true;

        expect(await provider.linkLibrary(), isNull);

        expect(
          LoggerService.instance.takeCapture(),
          contains(
            'w|RomM link pass failed: platform enumeration failed: '
            'Bad state: the platform list is still loading',
          ),
        );
      },
    );

    test('a dispose mid-pass is not followed by a sweep', () async {
      await build();
      linker.hold();
      browse.goOnline();
      await pumpEventQueue();
      expect(events, ['link']);

      provider.dispose();
      linker.release();
      await pumpEventQueue();

      expect(events, ['link'], reason: 'the sweep never started');
    });
  });
}
