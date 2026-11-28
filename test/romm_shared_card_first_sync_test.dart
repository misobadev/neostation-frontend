import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:neostation/data/datasources/sqlite_migrations.dart';
import 'package:neostation/l10n/app_locale.dart';
import 'package:neostation/models/game_model.dart';
import 'package:neostation/models/neo_sync_models.dart';
import 'package:neostation/models/romm_asset.dart';
import 'package:neostation/models/sync_models.dart';
import 'package:neostation/providers/neo_sync_provider.dart';
import 'package:neostation/providers/romm_provider.dart';
import 'package:neostation/repositories/romm_save_map_repository.dart';
import 'package:neostation/repositories/sync_repository.dart';
import 'package:neostation/services/global_notification_service.dart';
import 'package:neostation/services/neosync/neo_sync_service.dart';
import 'package:neostation/services/romm_service.dart';
import 'package:neostation/sync/providers/romm_provider.dart';
import 'package:neostation/utils/kept_save_copy.dart';

import 'database_test_helper.dart';

/// NEO-270: a memory card every game of its system shares (a PS2 `.ps2` card,
/// a Dreamcast `vmu_save*.bin`) keeps one RomM sync record on this device, but
/// RomM stores a copy of it under every game.
///
/// * The first time this device syncs the card, the server's card wins: it is
///   taken in the pre-launch sync and this device's card is kept as a dated
///   copy, with the bell. A blank card an emulator has just made on a new
///   device used to be uploaded over the real one after the game closed.
///   Other passes leave such a card alone. The server's card is the newest
///   copy of that name under any game, so a game with no copy of its own
///   doesn't upload over the copies the other games hold.
/// * Whenever a pull replaces a shared card with different bytes, this
///   device's card is kept first: the server's copy under one game may have
///   come from a card this device never had (another game's copy), which
///   nothing here can tell from an ordinary pull. The bell shows only when the
///   card had changed here, as for any save.

class _FakeRommService extends RommService {
  final Map<int, List<RommAsset>> savesByRom = {};
  final Map<String, List<int>> contentByPath = {};
  final List<String> uploads = []; // "romId/fileName"
  int listAllCalls = 0;
  int failUploads = 0;
  int downloads = 0;
  int listCalls = 0;
  bool listFails = false;
  bool listAllFails = false;
  int _nextAssetId = 1;
  int _stampSeq = 0;

  static String hashOf(List<int> bytes) => md5.convert(bytes).toString();

  DateTime _stamp() =>
      DateTime.now().toUtc().add(Duration(minutes: 10, seconds: ++_stampSeq));

  RommAsset seedSave(
    int romId,
    String fileName,
    List<int> bytes, {
    required DateTime updatedAt,
  }) {
    final path = 'assets/$romId/${_nextAssetId}_$fileName';
    final asset = RommAsset(
      id: _nextAssetId++,
      romId: romId,
      fileName: fileName,
      fileSizeBytes: bytes.length,
      isState: false,
      updatedAt: updatedAt,
      contentHash: hashOf(bytes),
      downloadPath: path,
    );
    contentByPath[path] = List.of(bytes);
    (savesByRom[romId] ??= [])
      ..removeWhere((a) => a.fileName == fileName)
      ..add(asset);
    return asset;
  }

  String serverBytes(int romId, String fileName) => String.fromCharCodes(
    contentByPath[savesByRom[romId]!
        .singleWhere((a) => a.fileName == fileName)
        .downloadPath!]!,
  );

  @override
  bool get playtimeSyncAvailable => false;

  @override
  Future<List<RommAsset>> listSaves({required int romId}) async {
    listCalls++;
    if (listFails) throw const HttpException('listing failed');
    return List.of(savesByRom[romId] ?? const []);
  }

  @override
  Future<List<RommAsset>> listAllSaves() async {
    listAllCalls++;
    if (listAllFails) throw const HttpException('listing failed');
    return [for (final saves in savesByRom.values) ...saves];
  }

  @override
  Future<List<RommAsset>> listStates({required int romId}) async => const [];

  @override
  Future<RommAsset> uploadSave(
    int romId,
    File file, {
    String? emulator,
    String? slot,
    String? deviceId,
    bool overwrite = true,
  }) async {
    final name = p.basename(file.path);
    if (failUploads > 0) {
      failUploads--;
      throw const HttpException('upload failed');
    }
    uploads.add('$romId/$name');
    return seedSave(romId, name, await file.readAsBytes(), updatedAt: _stamp());
  }

  @override
  Future<RommAsset> updateSave(int assetId, File file) async {
    for (final entry in savesByRom.entries) {
      final i = entry.value.indexWhere((a) => a.id == assetId);
      if (i < 0) continue;
      final old = entry.value[i];
      final bytes = await file.readAsBytes();
      uploads.add('${entry.key}/${old.fileName}');
      contentByPath[old.downloadPath!] = List.of(bytes);
      final updated = RommAsset(
        id: old.id,
        romId: old.romId,
        fileName: old.fileName,
        fileSizeBytes: bytes.length,
        isState: false,
        updatedAt: _stamp(),
        contentHash: hashOf(bytes),
        downloadPath: old.downloadPath,
      );
      entry.value[i] = updated;
      return updated;
    }
    throw StateError('no asset with id $assetId');
  }

  @override
  Future<Uint8List> downloadAssetByPath(String downloadPath) async {
    downloads++;
    return Uint8List.fromList(contentByPath[downloadPath]!);
  }
}

class _FakeBrowse extends RommProvider {
  final RommService fakeService;
  _FakeBrowse(this.fakeService);

  @override
  bool get isConnected => true;

  @override
  RommService get service => fakeService;
}

/// Every game's saves are the one card at [cardPath], statted live.
class _CardPaths {
  _CardPaths(this.cardPath);

  String cardPath;

  /// Where a download is placed; the card itself unless a test says otherwise.
  String? placedAt;

  /// Other saves every game has, beside the card.
  final List<String> others = [];

  Future<List<LocalSaveFile>> locate(GameModel game) async => [
    for (final path in [cardPath, ...others])
      if (File(path).existsSync())
        LocalSaveFile(
          filePath: path,
          fileName: p.basename(path),
          fileSize: File(path).statSync().size,
          lastModified: File(path).statSync().modified,
          gameName: game.name,
          isSynced: false,
          relativePath: 'saves/${p.basename(path)}',
        ),
  ];

  Future<List<String>> resolveTargets(
    GameModel game,
    String relativeName,
  ) async => [placedAt ?? cardPath];
}

/// Open for its first [openFor] looks, passed after that.
class _ScriptedDeadline extends SyncDeadline {
  _ScriptedDeadline(this.openFor) : super(const Duration(hours: 1));

  final int openFor;
  int looks = 0;

  @override
  bool get isExpired => ++looks > openFor;
}

GameModel _game(String romname, String system) => GameModel(
  romname: romname,
  realname: romname,
  name: romname,
  year: '2001',
  developer: '',
  publisher: '',
  genre: '',
  players: '',
  rating: 0,
  romPath: '/roms/$system/$romname',
  systemFolderName: system,
  cloudSyncEnabled: true,
);

void main() {
  final helper = DatabaseTestHelper();
  late Directory tempDir;
  late File card;
  late _FakeRommService svc;
  late _CardPaths paths;
  late RomMSyncProvider provider;

  final gameX = _game('GameX', 'ps2');
  final gameZ = _game('GameZ', 'ps2');

  final now = DateTime.now().toUtc();
  final hourAgo = now.subtract(const Duration(hours: 1));
  final inFiveMinutes = now.add(const Duration(minutes: 5));

  SyncDeadline launch() => SyncDeadline(const Duration(minutes: 1));

  Future<void> writeCard(String bytes, {DateTime? at}) async {
    await card.writeAsString(bytes);
    if (at != null) await card.setLastModified(at);
  }

  List<String> filesBesideCard() =>
      card.parent
          .listSync()
          .whereType<File>()
          .map((f) => f.path)
          .where((path) => path != card.path)
          .toList()
        ..sort();

  List<String> keptLocalCopies() => filesBesideCard().where((path) {
    final name = parseKeptCopyPath(path);
    return name != null &&
        name.savePath == card.path &&
        name.source == KeptCopySource.rommBeforeDownload;
  }).toList();

  GlobalNotificationData? bell() {
    for (final n in GlobalNotificationService().notifier.value) {
      if (n.id == 'neosync-kept-cloud-copy-${card.path}') return n;
    }
    return null;
  }

  Future<Map<String, dynamic>?> record([String? path]) =>
      SyncRepository.getSyncState(
        RomMSyncProvider.kProviderId,
        path ?? card.path,
      );

  Future<void> sweep() async {
    final result = await provider.retryPendingUploads();
    expect(result.success, isTrue, reason: result.message);
  }

  setUp(() async {
    final db = await helper.setUp();
    await db.execute(SqliteMigrations.createAppRommRomMapTableSql);
    await db.execute(SqliteMigrations.createAppNeoSyncStateTableSql);
    tempDir = await Directory.systemTemp.createTemp('romm_first_card_test');
    await Directory(p.join(tempDir.path, 'saves')).create();
    card = File(p.join(tempDir.path, 'saves', 'Mcd001.ps2'));

    for (final (romname, system, romId) in [
      ('GameX', 'ps2', 1),
      ('GameZ', 'ps2', 2),
      ('GameD', 'dc', 3),
      ('GameN', 'nes', 4),
    ]) {
      await RommSaveMapRepository.putMapping(
        source: RommLinkSource.download,
        romname: romname,
        systemFolder: system,
        rommRomId: romId,
      );
    }

    svc = _FakeRommService();
    paths = _CardPaths(card.path);
    provider = RomMSyncProvider(
      _FakeBrowse(svc),
      NeoSyncProvider(NeoSyncService()),
      // RetroArch's system folder is never this machine's.
      systemCardHome: (_) async => null,
      systemCardTarget: (_, _) async => null,
      locateSaves: paths.locate,
      resolveTargets: paths.resolveTargets,
      listGames: () async => [gameX, gameZ],
      autoSweep: false,
    );
    GlobalNotificationService().dismiss();
  });

  tearDown(() async {
    GlobalNotificationService().dismiss();
    await helper.tearDown();
    if (tempDir.existsSync()) await tempDir.delete(recursive: true);
  });

  group('first sync of a shared card, the server has one', () {
    test('pre-launch takes the server\'s card over a newer local one and '
        'keeps this device\'s as a dated copy, with the bell', () async {
      svc.seedSave(1, 'Mcd001.ps2', 'REAL CARD'.codeUnits, updatedAt: hourAgo);
      await writeCard('BLANK CARD');

      await provider.syncGameSavesBeforeLaunch(gameX, deadline: launch());

      expect(await card.readAsString(), 'REAL CARD');
      final copies = keptLocalCopies();
      expect(copies, hasLength(1));
      expect(await File(copies.single).readAsString(), 'BLANK CARD');
      expect(
        bell()?.message,
        AppLocale.neoSyncFirstCardSyncTookCloud.getStringForCurrentLocale(),
      );
      expect(
        (await record())?['file_hash'],
        _FakeRommService.hashOf('REAL CARD'.codeUnits),
      );
      expect(svc.uploads, isEmpty);
    });

    test('pre-launch takes it over an older local one too', () async {
      await writeCard('OLD CARD', at: hourAgo);
      svc.seedSave(1, 'Mcd001.ps2', 'REAL CARD'.codeUnits, updatedAt: now);

      await provider.syncGameSavesBeforeLaunch(gameX, deadline: launch());

      expect(await card.readAsString(), 'REAL CARD');
      expect(keptLocalCopies(), hasLength(1));
      expect(
        bell()?.message,
        AppLocale.neoSyncFirstCardSyncTookCloud.getStringForCurrentLocale(),
      );
    });

    test(
      'a pre-launch sync with no launch (the Manage tab) leaves it alone',
      () async {
        svc.seedSave(
          1,
          'Mcd001.ps2',
          'REAL CARD'.codeUnits,
          updatedAt: hourAgo,
        );
        await writeCard('BLANK CARD', at: hourAgo);

        await provider.syncGameSavesBeforeLaunch(gameX);

        expect(await card.readAsString(), 'BLANK CARD');
        expect(filesBesideCard(), isEmpty);
        expect(await record(), isNull);
        expect(svc.uploads, isEmpty);
      },
    );

    test(
      'post-close uploads nothing, keeps no copy and records nothing',
      () async {
        svc.seedSave(
          1,
          'Mcd001.ps2',
          'REAL CARD'.codeUnits,
          updatedAt: hourAgo,
        );
        await writeCard('BLANK CARD');

        final result = await provider.syncGameSavesAfterClose(gameX);

        expect(result.success, isTrue);
        expect(svc.uploads, isEmpty);
        expect(svc.serverBytes(1, 'Mcd001.ps2'), 'REAL CARD');
        expect(await card.readAsString(), 'BLANK CARD');
        expect(filesBesideCard(), isEmpty);
        expect(await record(), isNull);
        expect(
          provider.getGameSyncState('GameX')?.status,
          GameSyncStatus.cloudOnly,
          reason: 'the card waits for the next launch, it is not up to date',
        );
      },
    );

    test('the upload sweep uploads nothing', () async {
      svc.seedSave(1, 'Mcd001.ps2', 'REAL CARD'.codeUnits, updatedAt: hourAgo);
      await writeCard('BLANK CARD');

      await sweep();

      expect(svc.uploads, isEmpty);
      expect(svc.serverBytes(1, 'Mcd001.ps2'), 'REAL CARD');
      expect(await card.readAsString(), 'BLANK CARD');
    });

    test(
      'highlighting the game writes nothing and shows the card as waiting',
      () async {
        svc.seedSave(
          1,
          'Mcd001.ps2',
          'REAL CARD'.codeUnits,
          updatedAt: hourAgo,
        );
        await writeCard('BLANK CARD');

        await provider.detectGameSaveFiles(gameX);

        expect(await card.readAsString(), 'BLANK CARD');
        expect(filesBesideCard(), isEmpty);
        expect(await record(), isNull);
        expect(
          provider.getGameSyncState('GameX')?.status,
          GameSyncStatus.cloudOnly,
        );
      },
    );

    test('the same card is recorded, and a later change uploads', () async {
      svc.seedSave(1, 'Mcd001.ps2', 'SAME CARD'.codeUnits, updatedAt: hourAgo);
      await writeCard('SAME CARD');

      await provider.syncGameSavesAfterClose(gameX);

      expect(svc.uploads, isEmpty);
      expect(
        (await record())?['file_hash'],
        _FakeRommService.hashOf('SAME CARD'.codeUnits),
      );

      await writeCard('PLAYED', at: now.add(const Duration(minutes: 1)));
      await provider.syncGameSavesAfterClose(gameX);

      expect(svc.uploads, ['1/Mcd001.ps2']);
      expect(svc.serverBytes(1, 'Mcd001.ps2'), 'PLAYED');
    });

    test('highlights reuse a listing of every save for a minute', () async {
      svc.seedSave(1, 'Mcd001.ps2', 'REAL CARD'.codeUnits, updatedAt: hourAgo);
      await writeCard('BLANK CARD');

      await provider.detectGameSaveFiles(gameX);
      await provider.detectGameSaveFiles(gameZ);
      expect(svc.listAllCalls, 1);

      // A launch always asks afresh.
      await provider.syncGameSavesBeforeLaunch(gameX, deadline: launch());
      expect(svc.listAllCalls, 2);
    });

    test('signing out forgets the listing', () async {
      svc.seedSave(1, 'Mcd001.ps2', 'REAL CARD'.codeUnits, updatedAt: hourAgo);
      await writeCard('BLANK CARD');
      await provider.detectGameSaveFiles(gameX);

      await provider.logout();
      await provider.detectGameSaveFiles(gameX);

      expect(svc.listAllCalls, 2);
    });

    test('highlighting a game with the same card records nothing', () async {
      svc.seedSave(1, 'Mcd001.ps2', 'SAME CARD'.codeUnits, updatedAt: hourAgo);
      await writeCard('SAME CARD');

      await provider.detectGameSaveFiles(gameX);

      expect(await record(), isNull);
    });

    test('the launch deadline passing mid-take leaves the card as it was, '
        'removes the copy and records nothing', () async {
      svc.seedSave(1, 'Mcd001.ps2', 'REAL CARD'.codeUnits, updatedAt: hourAgo);
      await writeCard('BLANK CARD');

      // Open at the look after the fetch, passed at the one before the write.
      await provider.syncGameSavesBeforeLaunch(
        gameX,
        deadline: _ScriptedDeadline(1),
      );

      expect(await card.readAsString(), 'BLANK CARD');
      expect(filesBesideCard(), isEmpty);
      expect(await record(), isNull);
      expect(bell(), isNull);
      expect(
        provider.getGameSyncState('GameX')?.status,
        GameSyncStatus.cloudOnly,
        reason: 'still the next launch\'s to take',
      );
    });

    test('a card that is a link is left as it is: not taken, not uploaded, '
        'no error', () async {
      final real = File(p.join(tempDir.path, 'elsewhere', 'Mcd001.ps2'));
      await real.create(recursive: true);
      await real.writeAsString('LINKED CARD');
      await Link(card.path).create(real.path);
      svc.seedSave(1, 'Mcd001.ps2', 'REAL CARD'.codeUnits, updatedAt: hourAgo);

      final launched = await provider.syncGameSavesBeforeLaunch(
        gameX,
        deadline: launch(),
      );
      await provider.syncGameSavesAfterClose(gameX);

      expect(launched.success, isTrue);
      expect(await real.readAsString(), 'LINKED CARD');
      expect(filesBesideCard(), isEmpty);
      expect(svc.uploads, isEmpty);
      expect(
        provider.getGameSyncState('GameX')?.status,
        GameSyncStatus.cloudOnly,
      );
    }, skip: Platform.isWindows ? 'links need privileges on Windows' : false);

    test('a Dreamcast VMU is taken the same way', () async {
      card = File(p.join(tempDir.path, 'saves', 'vmu_save_A1.bin'));
      paths.cardPath = card.path;
      svc.seedSave(
        3,
        'vmu_save_A1.bin',
        'REAL VMU'.codeUnits,
        updatedAt: hourAgo,
      );
      await writeCard('BLANK VMU');

      await provider.syncGameSavesAfterClose(_game('GameD', 'dc'));
      expect(svc.uploads, isEmpty);

      await provider.syncGameSavesBeforeLaunch(
        _game('GameD', 'dc'),
        deadline: launch(),
      );
      expect(await card.readAsString(), 'REAL VMU');
      expect(keptLocalCopies(), hasLength(1));
    });

    test('a record under the normalised path is not a first sync', () async {
      // A download placed by folder records the normalised path; the listing
      // may give the same file with a `.` segment in it.
      paths.cardPath = p.join(tempDir.path, '.', 'saves', 'Mcd001.ps2');
      final synced = svc.seedSave(
        1,
        'Mcd001.ps2',
        'SYNCED'.codeUnits,
        updatedAt: hourAgo,
      );
      await writeCard('SYNCED', at: hourAgo);
      await SyncRepository.saveSyncState(
        RomMSyncProvider.kProviderId,
        card.path,
        hourAgo.millisecondsSinceEpoch,
        synced.updatedAtMs,
        6,
        fileHash: _FakeRommService.hashOf('SYNCED'.codeUnits),
      );
      await writeCard('PLAYED', at: now);

      await provider.syncGameSavesAfterClose(gameX);

      expect(svc.uploads, ['1/Mcd001.ps2']);
      expect(svc.serverBytes(1, 'Mcd001.ps2'), 'PLAYED');
    });
  });

  group('first sync of a shared card, where it goes', () {
    test('the take writes onto the card that was listed, not where a new '
        'download would be placed', () async {
      paths.placedAt = p.join(tempDir.path, 'saves', 'PS2', 'Mcd001.ps2');
      svc.seedSave(1, 'Mcd001.ps2', 'REAL CARD'.codeUnits, updatedAt: hourAgo);
      await writeCard('BLANK CARD');

      await provider.syncGameSavesBeforeLaunch(gameX, deadline: launch());

      expect(await card.readAsString(), 'REAL CARD');
      expect(File(paths.placedAt!).existsSync(), isFalse);
    });

    test('the upload sweep doesn\'t list a game whose only save is a card '
        'never synced from here', () async {
      svc.seedSave(1, 'Mcd001.ps2', 'REAL CARD'.codeUnits, updatedAt: hourAgo);
      await writeCard('BLANK CARD');

      await sweep();

      expect(svc.listCalls, 0);
      expect(svc.listAllCalls, 0);
    });
  });

  group('the upload sweep, for a game with another save waiting', () {
    late File other;

    setUp(() async {
      other = File(p.join(tempDir.path, 'saves', 'GameX.sav'));
      paths.others.add(other.path);
      await other.writeAsString('OTHER', flush: true);
      await other.setLastModified(hourAgo);
    });

    Future<void> otherSavePlayed() async {
      // Recorded once, then changed: the sweep's to send.
      await SyncRepository.saveSyncState(
        RomMSyncProvider.kProviderId,
        other.path,
        hourAgo.millisecondsSinceEpoch,
        0,
        5,
      );
      await other.writeAsString('OTHER PLAYED');
    }

    test('sends that save, and not a differing card never synced', () async {
      svc.seedSave(1, 'Mcd001.ps2', 'REAL CARD'.codeUnits, updatedAt: hourAgo);
      await writeCard('BLANK CARD');
      await otherSavePlayed();

      await sweep();

      expect(svc.uploads, ['1/GameX.sav']);
      expect(svc.serverBytes(1, 'Mcd001.ps2'), 'REAL CARD');
    });

    test('nor a card never synced that no game has', () async {
      await writeCard('FIRST CARD');
      await otherSavePlayed();

      await sweep();

      expect(svc.uploads, ['1/GameX.sav']);
    });
  });

  group('a post-close sync that couldn\'t list every save', () {
    test(
      'reports the card as not uploaded, and the sweep retries it',
      () async {
        await writeCard('FIRST CARD');
        svc.listAllFails = true;

        await provider.syncGameSavesAfterClose(gameX);
        expect(svc.uploads, isEmpty);
        expect(provider.uploadFailures.value.games, isNotEmpty);

        svc.listAllFails = false;
        await sweep();

        expect(svc.uploads, ['1/Mcd001.ps2']);
        expect(provider.uploadFailures.value.games, isEmpty);
      },
    );

    test(
      'nor this game\'s saves: the card is reported as not uploaded',
      () async {
        await writeCard('FIRST CARD');
        svc.listFails = true;

        await provider.syncGameSavesAfterClose(gameX);

        expect(svc.uploads, isEmpty);
        expect(provider.uploadFailures.value.games, isNotEmpty);
      },
    );

    test('a retry that finds the server\'s card leaves it for the launch and '
        'stops reporting it', () async {
      await writeCard('BLANK CARD');
      svc.listAllFails = true;
      await provider.syncGameSavesAfterClose(gameX);
      expect(provider.uploadFailures.value.games, isNotEmpty);

      svc.listAllFails = false;
      svc.seedSave(2, 'Mcd001.ps2', 'REAL CARD'.codeUnits, updatedAt: now);
      await sweep();

      expect(svc.uploads, isEmpty);
      expect(provider.uploadFailures.value.games, isEmpty);
    });
  });

  group('a first upload that failed', () {
    test('is retried by the upload sweep', () async {
      await writeCard('FIRST CARD');
      svc.failUploads = 1;

      await provider.syncGameSavesAfterClose(gameX);
      expect(svc.uploads, isEmpty);
      expect(provider.uploadFailures.value.games, isNotEmpty);

      await sweep();

      expect(svc.uploads, ['1/Mcd001.ps2']);
      expect(provider.uploadFailures.value.games, isEmpty);
    });

    test('is retried by a sweep that names the game without its extension '
        '(NEO-285: one game, whatever form its name takes)', () async {
      await writeCard('FIRST CARD');
      svc.failUploads = 1;
      await RommSaveMapRepository.putMapping(
        source: RommLinkSource.download,
        romname: 'GameX.iso',
        systemFolder: 'ps2',
        rommRomId: 1,
      );

      // Closed from a game list: the file name.
      await provider.syncGameSavesAfterClose(_game('GameX.iso', 'ps2'));
      expect(svc.uploads, isEmpty);
      expect(provider.uploadFailures.value.games, isNotEmpty);

      // The sweep's library rows name it without the extension.
      await sweep();

      expect(svc.uploads, ['1/Mcd001.ps2']);
      expect(provider.uploadFailures.value.games, isEmpty);
    });
  });

  group('a launch on a device with no card yet', () {
    test('places the server\'s card from another game', () async {
      svc.seedSave(1, 'Mcd001.ps2', 'REAL CARD'.codeUnits, updatedAt: hourAgo);

      await provider.syncGameSavesBeforeLaunch(gameZ, deadline: launch());

      expect(await card.readAsString(), 'REAL CARD');
      expect(svc.uploads, isEmpty);
      expect(await record(), isNotNull);
      expect(
        provider.getGameSyncState('GameZ')?.status,
        GameSyncStatus.upToDate,
      );
    });

    test('places the newest copy, not this game\'s older one', () async {
      svc.seedSave(2, 'Mcd001.ps2', 'OLDER COPY'.codeUnits, updatedAt: hourAgo);
      svc.seedSave(1, 'Mcd001.ps2', 'NEWER COPY'.codeUnits, updatedAt: now);

      await provider.syncGameSavesBeforeLaunch(gameZ, deadline: launch());

      expect(await card.readAsString(), 'NEWER COPY');
      expect(
        svc.downloads,
        1,
        reason: 'this game\'s older copy isn\'t fetched',
      );
      expect(filesBesideCard(), isEmpty);
    });

    test('places only the system\'s shared cards', () async {
      svc.seedSave(1, 'GameX.ps2', 'PER-GAME CARD'.codeUnits, updatedAt: now);
      svc.seedSave(3, 'vmu_save_A1.bin', 'VMU'.codeUnits, updatedAt: now);

      await provider.syncGameSavesBeforeLaunch(gameZ, deadline: launch());

      expect(await card.exists(), isFalse);
      expect(filesBesideCard(), isEmpty);
    });

    test('a highlight or a sync with no launch places nothing', () async {
      svc.seedSave(1, 'Mcd001.ps2', 'REAL CARD'.codeUnits, updatedAt: hourAgo);

      await provider.detectGameSaveFiles(gameZ);
      await provider.syncGameSavesBeforeLaunch(gameZ);

      expect(await card.exists(), isFalse);
      expect(svc.listAllCalls, 0);
    });
  });

  group('a card recorded under both its paths', () {
    test('the later record is the one that counts', () async {
      paths.cardPath = p.join(tempDir.path, '.', 'saves', 'Mcd001.ps2');
      final server = svc.seedSave(
        1,
        'Mcd001.ps2',
        'SERVER'.codeUnits,
        updatedAt: hourAgo,
      );
      await writeCard('MINE', at: hourAgo);
      final dayAgo = now.subtract(const Duration(days: 1));
      // An old record under the path as listed, and a later one under the
      // normalised path, which says the card hasn't changed since.
      await SyncRepository.saveSyncState(
        RomMSyncProvider.kProviderId,
        paths.cardPath,
        dayAgo.millisecondsSinceEpoch,
        dayAgo.millisecondsSinceEpoch,
        4,
      );
      await SyncRepository.saveSyncState(
        RomMSyncProvider.kProviderId,
        card.path,
        hourAgo.millisecondsSinceEpoch,
        server.updatedAtMs,
        4,
        fileHash: _FakeRommService.hashOf('MINE'.codeUnits),
      );

      await provider.syncGameSavesAfterClose(gameX);

      expect(svc.uploads, isEmpty);
      expect(filesBesideCard(), isEmpty);
    });
  });

  group('first sync of a shared card, across games', () {
    test('a game with no copy of its own uploads nothing when another game '
        'has one, and its launch takes that one', () async {
      svc.seedSave(1, 'Mcd001.ps2', 'REAL CARD'.codeUnits, updatedAt: hourAgo);
      await writeCard('BLANK CARD');

      await provider.syncGameSavesAfterClose(gameZ);
      expect(svc.uploads, isEmpty);
      expect(svc.savesByRom[2], isNull);

      await provider.syncGameSavesBeforeLaunch(gameZ, deadline: launch());
      expect(await card.readAsString(), 'REAL CARD');
      expect(keptLocalCopies(), hasLength(1));
    });

    test('the newest copy under any game is the server\'s card', () async {
      svc.seedSave(1, 'Mcd001.ps2', 'OLDER COPY'.codeUnits, updatedAt: hourAgo);
      svc.seedSave(2, 'Mcd001.ps2', 'NEWER COPY'.codeUnits, updatedAt: now);
      await writeCard('BLANK CARD');

      await provider.syncGameSavesBeforeLaunch(gameX, deadline: launch());

      expect(await card.readAsString(), 'NEWER COPY');
    });

    test('when every save can\'t be listed, this game\'s copy (perhaps an '
        'old one) is not taken, and the sync shows an error', () async {
      svc.seedSave(1, 'Mcd001.ps2', 'OLD COPY'.codeUnits, updatedAt: hourAgo);
      svc.listAllFails = true;
      await writeCard('BLANK CARD');

      await provider.syncGameSavesBeforeLaunch(gameX, deadline: launch());

      expect(await card.readAsString(), 'BLANK CARD');
      expect(filesBesideCard(), isEmpty);
      expect(await record(), isNull);
      expect(provider.getGameSyncState('GameX')?.status, GameSyncStatus.error);
    });

    test('with no copy here and every save unlisted, post-close uploads '
        'nothing', () async {
      svc.seedSave(1, 'Mcd001.ps2', 'REAL CARD'.codeUnits, updatedAt: hourAgo);
      svc.listAllFails = true;
      await writeCard('BLANK CARD');

      await provider.syncGameSavesAfterClose(gameZ);

      expect(svc.uploads, isEmpty);
      expect(await record(), isNull);
    });

    test(
      'every save is listed only for a card synced for the first time',
      () async {
        svc.seedSave(
          1,
          'Mcd001.ps2',
          'SAME CARD'.codeUnits,
          updatedAt: hourAgo,
        );
        await writeCard('SAME CARD');
        await provider.syncGameSavesAfterClose(gameX);
        final calls = svc.listAllCalls;

        await provider.syncGameSavesBeforeLaunch(gameX, deadline: launch());
        await provider.syncGameSavesAfterClose(gameX);

        expect(svc.listAllCalls, calls);
      },
    );
  });

  group('first sync of a shared card, no server copy anywhere', () {
    test('post-close uploads it', () async {
      await writeCard('FIRST CARD');

      await provider.syncGameSavesAfterClose(gameX);

      expect(svc.uploads, ['1/Mcd001.ps2']);
      expect(await record(), isNotNull);
    });

    test('pre-launch and the sweep don\'t', () async {
      await writeCard('FIRST CARD');

      await provider.syncGameSavesBeforeLaunch(gameX, deadline: launch());
      await sweep();

      expect(svc.uploads, isEmpty);
      expect(await card.readAsString(), 'FIRST CARD');
    });

    test('highlighting shows it as waiting to go up even when the game has '
        'another save on the server', () async {
      svc.seedSave(
        1,
        'Mcd002.ps2',
        'SECOND CARD'.codeUnits,
        updatedAt: hourAgo,
      );
      await writeCard('FIRST CARD');

      await provider.detectGameSaveFiles(gameX);

      expect(
        provider.getGameSyncState('GameX')?.status,
        GameSyncStatus.localOnly,
      );
    });

    test('highlighting shows it as waiting to go up', () async {
      await writeCard('FIRST CARD');

      await provider.detectGameSaveFiles(gameX);

      expect(
        provider.getGameSyncState('GameX')?.status,
        GameSyncStatus.localOnly,
      );
    });
  });

  group('a pull over a synced shared card', () {
    Future<void> syncedCard(String bytes) async {
      await writeCard(bytes, at: hourAgo);
      await provider.syncGameSavesAfterClose(gameX);
      expect(svc.uploads, ['1/Mcd001.ps2']);
    }

    test('keeps this device\'s card even when it is unchanged since its last '
        'sync, without the bell', () async {
      // Another game's card replaced this game's copy on the server (or the
      // other device played): nothing here can tell which.
      await syncedCard('THIS DEVICE');
      svc.seedSave(
        1,
        'Mcd001.ps2',
        'OTHER CARD'.codeUnits,
        updatedAt: inFiveMinutes.add(const Duration(hours: 1)),
      );

      await provider.syncGameSavesBeforeLaunch(gameX, deadline: launch());

      expect(await card.readAsString(), 'OTHER CARD');
      final copies = keptLocalCopies();
      expect(copies, [rommLocalSlotPath(card.path)]);
      expect(await File(copies.single).readAsString(), 'THIS DEVICE');
      expect(bell(), isNull);
    });

    test('routine pulls overwrite one slot and never push out the copy a '
        'first sync kept', () async {
      svc.seedSave(1, 'Mcd001.ps2', 'REAL CARD'.codeUnits, updatedAt: hourAgo);
      await writeCard('ORIGINAL CARD');
      await provider.syncGameSavesBeforeLaunch(gameX, deadline: launch());
      final firstSyncCopy = keptLocalCopies().single;

      for (var i = 1; i <= 4; i++) {
        svc.seedSave(
          1,
          'Mcd001.ps2',
          'OTHER DEVICE $i'.codeUnits,
          updatedAt: now.add(Duration(hours: i)),
        );
        await provider.syncGameSavesBeforeLaunch(gameX, deadline: launch());
        expect(await card.readAsString(), 'OTHER DEVICE $i');
      }

      expect(await File(firstSyncCopy).readAsString(), 'ORIGINAL CARD');
      expect(
        await File(rommLocalSlotPath(card.path)).readAsString(),
        'OTHER DEVICE 3',
      );
      expect(keptLocalCopies(), hasLength(2));
    });

    test(
      'a pull abandoned at the deadline leaves the slot as it was',
      () async {
        await syncedCard('THIS DEVICE');
        svc.seedSave(
          1,
          'Mcd001.ps2',
          'FIRST PULL'.codeUnits,
          updatedAt: inFiveMinutes.add(const Duration(hours: 1)),
        );
        await provider.syncGameSavesBeforeLaunch(gameX, deadline: launch());
        final slot = File(rommLocalSlotPath(card.path));
        expect(await slot.readAsString(), 'THIS DEVICE');
        svc.seedSave(
          1,
          'Mcd001.ps2',
          'SECOND PULL'.codeUnits,
          updatedAt: inFiveMinutes.add(const Duration(hours: 2)),
        );

        await provider.syncGameSavesBeforeLaunch(
          gameX,
          deadline: _ScriptedDeadline(1),
        );

        expect(await card.readAsString(), 'FIRST PULL');
        expect(await slot.readAsString(), 'THIS DEVICE');
        expect(filesBesideCard(), [slot.path]);
      },
    );

    test('with the bell when it changed here too', () async {
      await syncedCard('THIS DEVICE');
      await writeCard('PLAYED OFFLINE', at: now);
      svc.seedSave(
        1,
        'Mcd001.ps2',
        'OTHER CARD'.codeUnits,
        updatedAt: inFiveMinutes.add(const Duration(hours: 1)),
      );

      await provider.syncGameSavesBeforeLaunch(gameX, deadline: launch());

      expect(await card.readAsString(), 'OTHER CARD');
      expect(keptLocalCopies(), hasLength(1));
      expect(
        bell()?.message,
        AppLocale.neoSyncNewerCloudCopy.getStringForCurrentLocale(),
      );
    });

    test('a card that is a link and unchanged here is written through, with '
        'no copy', () async {
      final real = File(p.join(tempDir.path, 'elsewhere', 'Mcd001.ps2'));
      await real.create(recursive: true);
      await real.writeAsString('THIS DEVICE');
      await real.setLastModified(hourAgo);
      await Link(card.path).create(real.path);
      await provider.syncGameSavesAfterClose(gameX);
      expect(svc.uploads, ['1/Mcd001.ps2']);
      svc.seedSave(
        1,
        'Mcd001.ps2',
        'OTHER CARD'.codeUnits,
        updatedAt: inFiveMinutes.add(const Duration(hours: 1)),
      );

      final result = await provider.syncGameSavesBeforeLaunch(
        gameX,
        deadline: launch(),
      );

      expect(result.success, isTrue);
      expect(await real.readAsString(), 'OTHER CARD');
      expect(keptLocalCopies(), isEmpty);
    }, skip: Platform.isWindows ? 'links need privileges on Windows' : false);

    test('keeps nothing when the server holds the same bytes', () async {
      await syncedCard('THIS DEVICE');
      final asset = svc.savesByRom[1]!.single;
      svc.contentByPath[asset.downloadPath!] = 'THIS DEVICE'.codeUnits;
      svc.savesByRom[1] = [
        RommAsset(
          id: asset.id,
          romId: 1,
          fileName: asset.fileName,
          fileSizeBytes: asset.fileSizeBytes,
          isState: false,
          updatedAt: inFiveMinutes.add(const Duration(hours: 1)),
          // No content hash: the bytes are compared after the fetch.
          downloadPath: asset.downloadPath,
        ),
      ];

      await provider.syncGameSavesBeforeLaunch(gameX, deadline: launch());

      expect(keptLocalCopies(), isEmpty);
    });
  });

  group('other saves are unchanged', () {
    test('a never-synced save on a system without shared cards still '
        'uploads after the game closes', () async {
      card = File(p.join(tempDir.path, 'saves', 'GameN.srm'));
      paths.cardPath = card.path;
      svc.seedSave(4, 'GameN.srm', 'SERVER'.codeUnits, updatedAt: hourAgo);
      await writeCard('LOCAL');

      await provider.syncGameSavesAfterClose(_game('GameN', 'nes'));

      expect(svc.uploads, ['4/GameN.srm']);
      expect(svc.listAllCalls, 0);
    });

    test(
      'a pull over an unchanged save on such a system keeps no copy',
      () async {
        card = File(p.join(tempDir.path, 'saves', 'GameN.srm'));
        paths.cardPath = card.path;
        final gameN = _game('GameN', 'nes');
        await writeCard('LOCAL', at: hourAgo);
        await provider.syncGameSavesAfterClose(gameN);
        svc.seedSave(
          4,
          'GameN.srm',
          'NEWER'.codeUnits,
          updatedAt: inFiveMinutes.add(const Duration(hours: 1)),
        );

        await provider.syncGameSavesBeforeLaunch(gameN, deadline: launch());

        expect(await card.readAsString(), 'NEWER');
        expect(keptLocalCopies(), isEmpty);
      },
    );
  });
}
