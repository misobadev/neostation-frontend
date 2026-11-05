import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/models/game_model.dart';
import 'package:neostation/models/neo_sync_models.dart';
import 'package:neostation/models/sync_models.dart';
import 'package:neostation/providers/neo_sync_provider.dart';
import 'package:neostation/repositories/neosync_save_folder_repository.dart';
import 'package:neostation/services/neosync/auth_service.dart';
import 'package:neostation/services/neosync/neo_sync_service.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import 'database_test_helper.dart';

// PS2 and Dreamcast games share their memory cards, so a game's NeoSync sync
// checks the system's cards once per session rather than for every game. The
// cards were marked as checked while they were being found, before the sync
// looked at them, so a PS2 card was never uploaded or downloaded and the game
// still showed as up to date. Dreamcast escaped only because its check used a
// system name ('dreamcast') that never reaches it.

/// Lists [cloud], records uploads and downloads, and answers uploads with
/// [upload]: 'ok', 'fail' (a server error) or 'full' (the account is full);
/// [gate] holds uploads and downloads back until it completes.
class _FakeNeoSync extends NeoSyncService {
  List<NeoSyncFile> cloud = [];
  String upload = 'ok';
  Completer<void>? gate;
  final uploads = <String>[];
  final downloads = <String>[];

  @override
  Future<Map<String, dynamic>> getAllFiles({NeoSyncFileFilter? filter}) async =>
      {'success': true, 'files': List<NeoSyncFile>.of(cloud)};

  @override
  Future<Map<String, dynamic>> downloadFile(String fileId) async {
    downloads.add(fileId);
    final wait = gate;
    if (wait != null) await wait.future;
    return {'success': false, 'message': 'offline'};
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
    SyncDeadline? Function()? deadline,
  }) async {
    uploads.add(p.basename(file.path));
    final wait = gate;
    if (wait != null) await wait.future;
    if (upload == 'fail') return {'success': false, 'message': 'Server error'};
    if (upload == 'full') {
      return {'success': false, 'message': 'Storage quota exceeded'};
    }
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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  SharedPreferences.setMockInitialValues({});

  final dbHelper = DatabaseTestHelper();
  late Directory folder;
  late _FakeNeoSync service;
  late NeoSyncProvider provider;

  /// Waits until the first sync is held in its transfer (the listing runs in
  /// an isolate, so a few event-loop turns aren't enough).
  Future<void> transferStarted() async {
    for (var i = 0; i < 200; i++) {
      if (service.uploads.isNotEmpty || service.downloads.isNotEmpty) return;
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    fail('no transfer started');
  }

  tearDown(() async {
    await folder.delete(recursive: true);
    await dbHelper.tearDown();
  });

  for (final (system, emulator, card) in [
    ('ps2', 'armsx2', 'Mcd001.ps2'),
    ('dc', 'flycast', 'vmu_save_A1.bin'),
  ]) {
    group('$system memory cards', () {
      late File cardFile;

      setUp(() async {
        final db = await dbHelper.setUp();
        await db.execute(
          "INSERT INTO app_systems (id, real_name, folder_name, neosync_json) "
          "VALUES ('$system', '$system', '$system', '{\"sync\": true}')",
        );
        folder = await Directory.systemTemp.createTemp('neosync_cards_');
        await NeoSyncSaveFolderRepository.saveFolder(
          system,
          emulator,
          folder.path,
        );
        cardFile = File(p.join(folder.path, card))
          ..writeAsBytesSync(const [1, 2, 3, 4]);
        service = _FakeNeoSync();
        provider = NeoSyncProvider(service)..setAuthService(_SignedIn());
      });

      test('a card missing from the cloud is uploaded', () async {
        await provider.detectGameSaveFiles(_game('GameA.iso', system));

        expect(service.uploads, [card]);
        expect(
          provider.getGameSyncState('GameA.iso')?.status,
          GameSyncStatus.upToDate,
        );
      });

      NeoSyncFile cloudCard(String name, {String checksum = ''}) => NeoSyncFile(
        id: name,
        fileName: name,
        filePath: name,
        type: 'custom',
        fileSize: 4,
        gameName: '$system Shared',
        uploadedAt: DateTime(2026, 10, 1),
        userId: 'player',
        checksum: checksum,
        systemName: system,
        emulator: emulator,
      );

      test('a card that failed to upload shows the game as failed', () async {
        service.upload = 'fail';

        await provider.detectGameSaveFiles(_game('GameA.iso', system));

        expect(service.uploads, [card]);
        expect(
          provider.getGameSyncState('GameA.iso')?.status,
          GameSyncStatus.error,
        );
      });

      test('the next game of the system does not check the card '
          'again', () async {
        await provider.detectGameSaveFiles(_game('GameA.iso', system));
        await provider.detectGameSaveFiles(_game('GameB.iso', system));

        expect(service.uploads, [card]);
      });

      test('a card that failed to upload is tried again for the next '
          'game', () async {
        service.upload = 'fail';
        await provider.detectGameSaveFiles(_game('GameA.iso', system));

        service.upload = 'ok';
        await provider.detectGameSaveFiles(_game('GameB.iso', system));

        expect(service.uploads, [card, card]);
      });

      test('a card the full account refused is not sent again for the next '
          'game', () async {
        service.upload = 'full';
        await provider.detectGameSaveFiles(_game('GameA.iso', system));
        await provider.detectGameSaveFiles(_game('GameB.iso', system));

        expect(service.uploads, [card]);
      });

      test('two syncs at once send the card once', () async {
        service.gate = Completer<void>();
        final first = provider.detectGameSaveFiles(_game('GameA.iso', system));
        await transferStarted();
        // Finishes without touching the card; waiting on the held transfer
        // instead would time out.
        await provider
            .detectGameSaveFiles(_game('GameB.iso', system))
            .timeout(const Duration(seconds: 5));
        service.gate!.complete();
        await first;

        expect(service.uploads, [card]);
      });

      test('a card already in the cloud is left alone, also at a '
          'launch', () async {
        service.cloud = [
          cloudCard(
            card,
            checksum: service.calculateFileHash(cardFile.readAsBytesSync()),
          ),
        ];

        await provider.detectGameSaveFiles(_game('GameA.iso', system));
        await provider.syncGameSavesBeforeLaunch(_game('GameA.iso', system));

        expect(service.uploads, isEmpty);
        expect(service.downloads, isEmpty);
        expect(
          provider.getGameSyncState('GameA.iso')?.status,
          GameSyncStatus.upToDate,
        );
      });

      test('a card only in the cloud is requested', () async {
        final other = card.replaceFirst('1', '2');
        service.cloud = [cloudCard(other)];

        await provider.detectGameSaveFiles(_game('GameA.iso', system));

        expect(service.downloads, [other]);
      });

      test('two syncs at once fetch a card only in the cloud once', () async {
        final other = card.replaceFirst('1', '2');
        service
          ..cloud = [
            cloudCard(
              card,
              checksum: service.calculateFileHash(cardFile.readAsBytesSync()),
            ),
            cloudCard(other),
          ]
          ..gate = Completer<void>();
        final first = provider.detectGameSaveFiles(_game('GameA.iso', system));
        await transferStarted();
        // Finishes without touching the card; waiting on the held transfer
        // instead would time out.
        await provider
            .detectGameSaveFiles(_game('GameB.iso', system))
            .timeout(const Duration(seconds: 5));
        service.gate!.complete();
        await first;

        expect(service.downloads, [other]);
      });

      test('a game launched while its card is still being sent does not '
          'send it again', () async {
        service.gate = Completer<void>();
        final selected = provider.detectGameSaveFiles(
          _game('GameA.iso', system),
        );
        await transferStarted();
        await provider
            .syncGameSavesBeforeLaunch(_game('GameA.iso', system))
            .timeout(const Duration(seconds: 5));
        service.gate!.complete();
        await selected;

        expect(service.uploads, [card]);
      });

      test('a game about to launch checks the card again', () async {
        await provider.detectGameSaveFiles(_game('GameA.iso', system));

        await provider.syncGameSavesBeforeLaunch(_game('GameB.iso', system));

        expect(service.uploads, [card, card]);
      });

      test('a game that has just closed checks the card again', () async {
        // So a card changed during play reaches the cloud.
        await provider.detectGameSaveFiles(_game('GameA.iso', system));
        cardFile.writeAsBytesSync(const [5, 6, 7, 8]);

        await provider.syncGameSavesAfterClose(_game('GameA.iso', system));

        expect(service.uploads, [card, card]);
      });
    });
  }
}
