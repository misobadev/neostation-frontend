import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:neostation/data/datasources/sqlite_migrations.dart';
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

/// Sending a `slot` on every save we create (#368 stage 2).
///
/// A NULL slot is archival to a slot-aware client — `lodordev/lodor` pairs on
/// `(rom_id, slot)` and never sees a save without one — so an unslotted upload
/// is invisible to it. Slotting costs a server-side rename: RomM datetime-tags
/// a slotted upload, which is why the round-trip below is the test that
/// matters. We create a name we cannot then read back naively.
///
/// The fake mirrors RomM 5.2.0 as verified over HTTP against a live 5.2.0
/// server: `POST` with a slot stores the slot and tags the filename, `PUT`
/// sends no slot and leaves both the slot and the name alone.
class _FakeRommService extends RommService {
  final Map<int, List<RommAsset>> savesByRom = {};
  final Map<int, List<RommAsset>> statesByRom = {};
  final Map<String, List<int>> contentByPath = {};

  /// Slot recorded per created asset name, in creation order.
  final List<({String name, String? slot})> creates = [];
  final List<int> updates = [];

  int _nextAssetId = 1;
  int _stampSeq = 0;

  DateTime _stamp() =>
      DateTime.now().toUtc().add(Duration(seconds: ++_stampSeq));

  /// RomM's server-side rename for a slotted save, matching its
  /// `DATETIME_TAG_PATTERN`. Applied at creation only.
  String _tagged(String fileName) {
    final ext = p.extension(fileName);
    final base = fileName.substring(0, fileName.length - ext.length);
    final seq = _stampSeq.toString().padLeft(2, '0');
    return '$base [2026-08-21_19-00-$seq]$ext';
  }

  RommAsset seedSave(
    int romId,
    String fileName,
    List<int> bytes, {
    required DateTime updatedAt,
    String? slot,
  }) {
    final path = 'assets/$romId/${_nextAssetId}_$fileName';
    final asset = RommAsset(
      id: _nextAssetId++,
      fileName: fileName,
      fileSizeBytes: bytes.length,
      isState: false,
      updatedAt: updatedAt,
      slot: slot,
      contentHash: md5.convert(bytes).toString(),
      downloadPath: path,
    );
    contentByPath[path] = List.of(bytes);
    (savesByRom[romId] ??= []).add(asset);
    return asset;
  }

  @override
  bool get playtimeSyncAvailable => false;

  @override
  Future<List<RommAsset>> listSaves({required int romId}) async =>
      List.of(savesByRom[romId] ?? const []);

  @override
  Future<List<RommAsset>> listStates({required int romId}) async =>
      List.of(statesByRom[romId] ?? const []);

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
    creates.add((name: name, slot: slot));
    final stored = (slot != null && slot.isNotEmpty) ? _tagged(name) : name;
    return seedSave(
      romId,
      stored,
      await file.readAsBytes(),
      updatedAt: _stamp(),
      slot: slot,
    );
  }

  @override
  Future<RommAsset> uploadState(
    int romId,
    File file, {
    String? emulator,
    String? slot,
    String? deviceId,
    bool overwrite = true,
  }) async {
    final name = p.basename(file.path);
    creates.add((name: name, slot: slot));
    final path = 'assets/$romId/${_nextAssetId}_$name';
    final bytes = await file.readAsBytes();
    final asset = RommAsset(
      id: _nextAssetId++,
      fileName: name,
      fileSizeBytes: bytes.length,
      isState: true,
      updatedAt: _stamp(),
      downloadPath: path,
    );
    contentByPath[path] = List.of(bytes);
    (statesByRom[romId] ??= []).add(asset);
    return asset;
  }

  @override
  Future<RommAsset> updateSave(int assetId, File file) =>
      _update(savesByRom, assetId, file, isState: false);

  @override
  Future<RommAsset> updateState(int assetId, File file) =>
      _update(statesByRom, assetId, file, isState: true);

  /// `PUT` carries no slot and no emulator: the row keeps the slot and the name
  /// it already has, and only the bytes/hash/stamp move.
  Future<RommAsset> _update(
    Map<int, List<RommAsset>> byRom,
    int assetId,
    File file, {
    required bool isState,
  }) async {
    for (final entry in byRom.entries) {
      final i = entry.value.indexWhere((a) => a.id == assetId);
      if (i < 0) continue;
      final old = entry.value[i];
      final bytes = await file.readAsBytes();
      updates.add(assetId);
      contentByPath[old.downloadPath!] = List.of(bytes);
      final updated = RommAsset(
        id: old.id,
        fileName: old.fileName,
        fileSizeBytes: bytes.length,
        isState: old.isState,
        updatedAt: _stamp(),
        slot: old.slot,
        contentHash: isState ? null : md5.convert(bytes).toString(),
        downloadPath: old.downloadPath,
      );
      entry.value[i] = updated;
      return updated;
    }
    throw StateError('no asset with id $assetId');
  }

  @override
  Future<Uint8List> downloadAssetByPath(String downloadPath) async =>
      Uint8List.fromList(contentByPath[downloadPath]!);

  @override
  Future<Uint8List> downloadSaveContent(int assetId) async =>
      throw UnimplementedError('tests always provide download_path');
}

class _FakeBrowse extends RommProvider {
  final RommService fakeService;
  _FakeBrowse(this.fakeService);

  @override
  bool get isConnected => true;

  @override
  RommService get service => fakeService;
}

class _TempSavePaths {
  _TempSavePaths(this.root);

  final String root;

  Future<List<LocalSaveFile>> locate(GameModel game) async {
    final out = <LocalSaveFile>[];
    for (final kind in const ['saves', 'states']) {
      final dir = Directory(p.join(root, kind));
      if (!dir.existsSync()) continue;
      for (final f in dir.listSync().whereType<File>()) {
        final stat = f.statSync();
        out.add(
          LocalSaveFile(
            filePath: f.path,
            fileName: p.basename(f.path),
            fileSize: stat.size,
            lastModified: stat.modified,
            gameName: game.name,
            isSynced: false,
            relativePath: '$kind/${p.basename(f.path)}',
          ),
        );
      }
    }
    return out;
  }

  Future<List<String>> resolveTargets(
    GameModel game,
    String relativeName,
  ) async => [p.join(root, relativeName)];
}

GameModel _game(String romname) => GameModel(
  romname: romname,
  realname: romname,
  name: p.basenameWithoutExtension(romname),
  year: '1996',
  developer: '',
  publisher: '',
  genre: '',
  players: '',
  rating: 0,
  romPath: '/roms/nes/$romname',
  systemFolderName: 'nes',
  cloudSyncEnabled: true,
);

void main() {
  final helper = DatabaseTestHelper();
  late Directory tempDir;
  late _FakeRommService svc;
  late RomMSyncProvider provider;

  final game = _game('Game.nes');

  File localSave() => File(p.join(tempDir.path, 'saves', 'Game.srm'));
  File localState() => File(p.join(tempDir.path, 'states', 'Game.state.auto'));

  /// Pushes a file's mtime well past [_mtimeToleranceMs], so a rewrite inside
  /// the same test second still reads as a change.
  Future<void> touch(File f) =>
      f.setLastModified(DateTime.now().add(const Duration(minutes: 5)));

  setUp(() async {
    final db = await helper.setUp();
    await db.execute(SqliteMigrations.createAppRommRomMapTableSql);
    await db.execute(SqliteMigrations.createAppNeoSyncStateTableSql);
    tempDir = await Directory.systemTemp.createTemp('romm_slot_test');
    await Directory(p.join(tempDir.path, 'saves')).create(recursive: true);
    await Directory(p.join(tempDir.path, 'states')).create(recursive: true);

    await RommSaveMapRepository.putMapping(
      source: RommLinkSource.download,
      romname: 'Game.nes',
      systemFolder: 'nes',
      rommRomId: 1,
    );

    svc = _FakeRommService();
    provider = RomMSyncProvider(
      _FakeBrowse(svc),
      NeoSyncProvider(NeoSyncService()),
      locateSaves: _TempSavePaths(tempDir.path).locate,
      resolveTargets: _TempSavePaths(tempDir.path).resolveTargets,
      autoSweep: false,
    );
  });

  tearDown(() async {
    await helper.tearDown();
    await tempDir.delete(recursive: true);
  });

  group('slot on upload', () {
    test('a newly created save is slotted', () async {
      await localSave().writeAsString('PROGRESS');

      await provider.syncGameSavesAfterClose(game);

      expect(svc.creates, hasLength(1));
      expect(
        svc.creates.single.slot,
        'autosave',
        reason: 'the slot a (rom_id, slot) client pairs on',
      );
      expect(svc.savesByRom[1]!.single.slot, 'autosave');
    });

    test(
      'a newly created state is not slotted: /api/states has no slot',
      () async {
        await localState().writeAsString('SNAPSHOT');

        await provider.syncGameSavesAfterClose(game);

        expect(svc.creates, hasLength(1));
        expect(svc.creates.single.slot, isNull);
      },
    );

    test('the tagged name RomM assigns still pairs to the local save, so a '
        'second pass neither re-creates nor duplicates it', () async {
      await localSave().writeAsString('PROGRESS');
      await provider.syncGameSavesAfterClose(game);

      // The server now holds a name we never wrote.
      final created = svc.savesByRom[1]!.single;
      expect(
        created.fileName,
        matches(r'^Game \[\d{4}-\d{2}-\d{2}_\d{2}-\d{2}-\d{2}\]\.srm$'),
        reason: 'RomM renamed it on the way in',
      );

      await localSave().writeAsString('MORE PROGRESS');
      await touch(localSave());
      await provider.syncGameSavesAfterClose(game);

      expect(
        svc.creates,
        hasLength(1),
        reason: 'the tagged asset was matched, not treated as absent',
      );
      expect(svc.updates, [created.id], reason: 'updated in place');
      expect(svc.savesByRom[1], hasLength(1), reason: 'no duplicate lineage');
      expect(
        File(p.join(tempDir.path, 'saves', created.fileName)).existsSync(),
        isFalse,
        reason: 'the tag must never reach the local filesystem',
      );
    });

    test(
      'an existing unslotted save stays unslotted: PUT carries no slot',
      () async {
        svc.seedSave(
          1,
          'Game.srm',
          'OLD'.codeUnits,
          updatedAt: DateTime.utc(2026, 1, 1),
        );
        await localSave().writeAsString('NEW');

        await provider.syncGameSavesAfterClose(game);

        expect(svc.creates, isEmpty, reason: 'matched, so updated not created');
        expect(
          svc.savesByRom[1]!.single.slot,
          isNull,
          reason: 'slotting reaches new saves, never the existing library',
        );
      },
    );
  });
}
