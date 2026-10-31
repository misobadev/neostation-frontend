import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/models/game_model.dart';
import 'package:neostation/models/neo_sync_models.dart';
import 'package:neostation/models/sync_models.dart';
import 'package:neostation/providers/neo_sync_provider.dart';
import 'package:neostation/repositories/neosync_save_folder_repository.dart';
import 'package:neostation/repositories/sync_repository.dart';
import 'package:neostation/services/neosync/auth_service.dart';
import 'package:neostation/services/neosync/neo_sync_service.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import 'database_test_helper.dart';

// A game's pre-launch sync stops waiting after a few seconds and the game
// starts on its local save; a download that finishes later must not be
// written. NeoSync kept that deadline in one field for the whole provider, so
// while a slow pre-launch sync was still running every other game's download
// was dropped too, and shown as up to date. A stalled sync that finished late
// also cleared the deadline of the game launched after it, whose late
// download was then written over the save the emulator had open.

/// Lists [cloud], records uploads and downloads, and answers every download
/// with its bytes (`cloud <id>`); a download whose id has a [gates] entry is
/// held until that entry completes, and each download of an id with [queued]
/// gates is held on the next of them.
class _FakeNeoSync extends NeoSyncService {
  List<NeoSyncFile> cloud = [];
  final gates = <String, Completer<void>>{};
  final queued = <String, List<Completer<void>>>{};
  final uploads = <String>[];
  final downloads = <String>[];

  @override
  Future<Map<String, dynamic>> getAllFiles({NeoSyncFileFilter? filter}) async =>
      {'success': true, 'files': List<NeoSyncFile>.of(cloud)};

  @override
  Future<Map<String, dynamic>> downloadFile(String fileId) async {
    downloads.add(fileId);
    final queue = queued[fileId];
    final wait = queue != null && queue.isNotEmpty
        ? queue.removeAt(0)
        : gates[fileId];
    if (wait != null) await wait.future;
    return {'success': true, 'data': 'cloud $fileId'.codeUnits};
  }

  @override
  Future<Map<String, dynamic>> syncFile(
    File file,
    String gameName, {
    String? customFilename,
    String? systemId,
    String? emulatorId,
    String? gameHash,
    bool? isState,
    String? scope,
    String? type,
  }) async {
    uploads.add(p.basename(file.path));
    return {'success': true};
  }
}

class _SignedIn extends AuthService {
  @override
  bool get isLoggedIn => true;
}

GameModel _game(String rom, String system) => GameModel(
  romname: rom,
  realname: rom,
  name: rom,
  year: '',
  developer: '',
  publisher: '',
  genre: '',
  players: '',
  rating: 0,
  romPath: '/roms/$system/$rom',
  systemFolderName: system,
  cloudSyncEnabled: true,
);

/// A deadline that has already passed (`Duration.zero` can tie with now).
SyncDeadline _expired() => SyncDeadline(const Duration(milliseconds: -1));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  SharedPreferences.setMockInitialValues({});

  final dbHelper = DatabaseTestHelper();
  late Directory gcFolder;
  late Directory ps2Folder;
  late _FakeNeoSync service;
  late NeoSyncProvider provider;

  final gameA = _game('GameA.iso', 'gc');
  final gameB = _game('GameB.iso', 'gc');
  final gameC = _game('GameC.iso', 'gc');

  NeoSyncFile cloudSave(
    String name, {
    String system = 'gc',
    String emulator = 'dolphin',
    String checksum = '',
    DateTime? modified,
  }) => NeoSyncFile(
    id: name,
    fileName: name,
    filePath: name,
    type: 'custom',
    fileSize: 4,
    gameName: name,
    uploadedAt: DateTime(2026, 10, 1),
    fileModifiedAtTimestamp: modified?.millisecondsSinceEpoch,
    userId: 'player',
    checksum: checksum,
    systemName: system,
    emulator: emulator,
  );

  File gcSave(String name) => File(p.join(gcFolder.path, name));

  /// Waits until a download of [id] has reached the service (the listing runs
  /// in an isolate, so a few event-loop turns aren't enough).
  Future<void> downloadStarted(String id) async {
    for (var i = 0; i < 500; i++) {
      if (service.downloads.contains(id)) return;
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    fail('no download of $id started');
  }

  /// Waits until [id] has been asked for [times] times.
  Future<void> downloadsOf(String id, int times) async {
    for (var i = 0; i < 500; i++) {
      if (service.downloads.where((d) => d == id).length >= times) return;
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    fail('$id was not downloaded $times times');
  }

  Completer<void> hold(String id) => service.gates[id] = Completer<void>();

  setUp(() async {
    final db = await dbHelper.setUp();
    await db.execute(
      "INSERT INTO app_systems (id, real_name, folder_name, neosync_json) "
      "VALUES ('gc', 'GameCube', 'gc', '{\"sync\": true}'), "
      "('ps2', 'ps2', 'ps2', '{\"sync\": true}')",
    );
    await db.execute(
      "INSERT INTO user_detected_systems (app_system_id, actual_folder_name) "
      "VALUES ('gc', 'gc')",
    );
    gcFolder = await Directory.systemTemp.createTemp('neosync_deadline_gc_');
    ps2Folder = await Directory.systemTemp.createTemp('neosync_deadline_ps2_');
    await NeoSyncSaveFolderRepository.saveFolder(
      'gc',
      'dolphin',
      gcFolder.path,
    );
    await NeoSyncSaveFolderRepository.saveFolder(
      'ps2',
      'armsx2',
      ps2Folder.path,
    );
    service = _FakeNeoSync();
    provider = NeoSyncProvider(service)..setAuthService(_SignedIn());
  });

  tearDown(() async {
    for (final gate in [
      ...service.gates.values,
      ...service.queued.values.expand((queue) => queue),
    ]) {
      if (!gate.isCompleted) gate.complete();
    }
    await gcFolder.delete(recursive: true);
    await ps2Folder.delete(recursive: true);
    await dbHelper.tearDown();
  });

  test('another game synced while a launch is past its deadline still gets '
      'its save', () async {
    service.cloud = [cloudSave('GameA.sav'), cloudSave('GameB.sav')];
    final gateA = hold('GameA.sav');
    final launch = provider.syncGameSavesBeforeLaunch(
      gameA,
      deadline: _expired(),
    );
    await downloadStarted('GameA.sav');

    await provider
        .detectGameSaveFiles(gameB)
        .timeout(const Duration(seconds: 5));

    expect(service.downloads, contains('GameB.sav'));
    expect(gcSave('GameB.sav').existsSync(), isTrue);
    expect(gcSave('GameB.sav').readAsStringSync(), 'cloud GameB.sav');
    expect(
      provider.getGameSyncState('GameB.iso')?.status,
      GameSyncStatus.upToDate,
    );

    gateA.complete();
    await launch;
  });

  group('a pre-launch download that finishes after the deadline', () {
    Future<void> launchPastDeadline() async {
      final gate = hold('GameA.sav');
      final deadline = SyncDeadline(const Duration(milliseconds: 300));
      final launch = provider.syncGameSavesBeforeLaunch(
        gameA,
        deadline: deadline,
      );
      await downloadStarted('GameA.sav');
      while (!deadline.isExpired) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      gate.complete();
      await launch;
    }

    test('does not create the save, and shows the game as failed', () async {
      service.cloud = [cloudSave('GameA.sav')];

      await launchPastDeadline();

      expect(gcSave('GameA.sav').existsSync(), isFalse);
      expect(
        await SyncRepository.getSyncState(
          NeoSyncProvider.kSyncProviderId,
          gcSave('GameA.sav').path,
        ),
        isNull,
      );
      expect(
        provider.getGameSyncState('GameA.iso')?.status,
        GameSyncStatus.error,
      );
    });

    test('leaves the local save as it was, and shows the game as '
        'failed', () async {
      final local = gcSave('GameA.sav')..writeAsStringSync('local save');
      local.setLastModifiedSync(DateTime(2026, 1, 1));
      service.cloud = [cloudSave('GameA.sav', modified: DateTime(2026, 10, 1))];

      await launchPastDeadline();

      expect(local.readAsStringSync(), 'local save');
      expect(File('${local.path}.neosync.bak').existsSync(), isFalse);
      expect(
        await SyncRepository.getSyncState(
          NeoSyncProvider.kSyncProviderId,
          local.path,
        ),
        isNull,
      );
      expect(
        provider.getGameSyncState('GameA.iso')?.status,
        GameSyncStatus.error,
      );
    });
  });

  group('a launch past its deadline', () {
    test('keeps its deadline when an earlier launch of the same game '
        'finishes', () async {
      service.cloud = [cloudSave('GameA.sav')];
      final first = Completer<void>();
      final second = Completer<void>();
      service.queued['GameA.sav'] = [first, second];
      final launch = provider.syncGameSavesBeforeLaunch(
        gameA,
        deadline: SyncDeadline(const Duration(seconds: 30)),
      );
      await downloadStarted('GameA.sav');
      final relaunch = provider.syncGameSavesBeforeLaunch(
        gameA,
        deadline: _expired(),
      );
      await downloadsOf('GameA.sav', 2);

      first.complete();
      await launch;
      second.complete();
      await relaunch;

      expect(gcSave('GameA.sav').existsSync(), isFalse);
    });

    test('keeps its deadline when a stalled earlier launch finishes', () async {
      service.cloud = [cloudSave('GameA.sav'), cloudSave('GameB.sav')];
      final gateA = hold('GameA.sav');
      final gateB = hold('GameB.sav');
      final launchA = provider.syncGameSavesBeforeLaunch(
        gameA,
        deadline: SyncDeadline(const Duration(seconds: 30)),
      );
      await downloadStarted('GameA.sav');
      final launchB = provider.syncGameSavesBeforeLaunch(
        gameB,
        deadline: _expired(),
      );
      await downloadStarted('GameB.sav');

      gateA.complete();
      await launchA;
      gateB.complete();
      await launchB;

      expect(gcSave('GameB.sav').existsSync(), isFalse);
    });

    test('keeps its deadline when a sync without one runs alongside, as '
        'from the game settings', () async {
      service.cloud = [cloudSave('GameB.sav'), cloudSave('GameC.sav')];
      final gateB = hold('GameB.sav');
      final launchB = provider.syncGameSavesBeforeLaunch(
        gameB,
        deadline: _expired(),
      );
      await downloadStarted('GameB.sav');

      await provider
          .syncGameSavesBeforeLaunch(gameC)
          .timeout(const Duration(seconds: 5));
      gateB.complete();
      await launchB;

      expect(gcSave('GameC.sav').readAsStringSync(), 'cloud GameC.sav');
      expect(gcSave('GameB.sav').existsSync(), isFalse);
    });
  });

  test('a shared PS2 card abandoned at the deadline is checked again by the '
      'next PS2 game', () async {
    final card = File(p.join(ps2Folder.path, 'Mcd001.ps2'))
      ..writeAsBytesSync(const [1, 2, 3, 4]);
    service.cloud = [
      cloudSave(
        'Mcd001.ps2',
        system: 'ps2',
        emulator: 'armsx2',
        checksum: service.calculateFileHash(card.readAsBytesSync()),
      ),
      cloudSave('Mcd002.ps2', system: 'ps2', emulator: 'armsx2'),
    ];
    final other = File(p.join(ps2Folder.path, 'Mcd002.ps2'));

    await provider.syncGameSavesBeforeLaunch(
      _game('GameA.iso', 'ps2'),
      deadline: _expired(),
    );
    expect(service.downloads, ['Mcd002.ps2']);
    expect(other.existsSync(), isFalse);

    await provider.detectGameSaveFiles(_game('GameB.iso', 'ps2'));

    expect(service.downloads, ['Mcd002.ps2', 'Mcd002.ps2']);
    expect(other.readAsStringSync(), 'cloud Mcd002.ps2');
  });

  test('a download of the launched game started before its launch is not '
      'written once the launch is past its deadline', () async {
    // The games list syncs the highlighted game; the user then launches it
    // while that download is still running.
    service.cloud = [cloudSave('GameA.sav')];
    final gate = hold('GameA.sav');
    final highlight = provider.detectGameSaveFiles(gameA);
    await downloadStarted('GameA.sav');
    final launch = provider.syncGameSavesBeforeLaunch(
      gameA,
      deadline: _expired(),
    );
    await downloadsOf('GameA.sav', 2);

    gate.complete();
    await highlight;
    await launch;

    expect(gcSave('GameA.sav').existsSync(), isFalse);
  });

  test('a shared PS2 card fetched by another PS2 game is not written while a '
      'PS2 launch is past its deadline', () async {
    final card = File(p.join(ps2Folder.path, 'Mcd001.ps2'))
      ..writeAsBytesSync(const [1, 2, 3, 4]);
    service.cloud = [
      cloudSave(
        'Mcd001.ps2',
        system: 'ps2',
        emulator: 'armsx2',
        checksum: service.calculateFileHash(card.readAsBytesSync()),
        modified: DateTime(2026, 9, 1),
      ),
      cloudSave(
        'Mcd002.ps2',
        system: 'ps2',
        emulator: 'armsx2',
        modified: DateTime(2026, 10, 2),
      ),
      cloudSave(
        'Mcd003.ps2',
        system: 'ps2',
        emulator: 'armsx2',
        modified: DateTime(2026, 10, 1),
      ),
    ];
    File ps2Card(String name) => File(p.join(ps2Folder.path, name));
    final gate2 = hold('Mcd002.ps2');
    final gate3 = hold('Mcd003.ps2');

    // Game X (say, its sync after closing) fetches card 2; game Y's launch
    // then fetches card 3, and runs past its deadline.
    final sync = provider.detectGameSaveFiles(_game('GameX.iso', 'ps2'));
    await downloadStarted('Mcd002.ps2');
    final launch = provider.syncGameSavesBeforeLaunch(
      _game('GameY.iso', 'ps2'),
      deadline: _expired(),
    );
    await downloadStarted('Mcd003.ps2');

    gate2.complete();
    await sync;
    expect(ps2Card('Mcd002.ps2').existsSync(), isFalse);

    gate3.complete();
    await launch;
    expect(ps2Card('Mcd003.ps2').existsSync(), isFalse);

    // Once the launch's sync is over, the cards are fetched again.
    await provider.detectGameSaveFiles(_game('GameZ.iso', 'ps2'));

    expect(ps2Card('Mcd002.ps2').readAsStringSync(), 'cloud Mcd002.ps2');
    expect(ps2Card('Mcd003.ps2').readAsStringSync(), 'cloud Mcd003.ps2');
  });
}
