import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/data/datasources/sqlite_migrations.dart';
import 'package:neostation/data/datasources/sqlite_service.dart';
import 'package:neostation/models/romm_rom.dart';
import 'package:neostation/models/system_model.dart';
import 'package:neostation/providers/file_provider.dart';
import 'package:neostation/providers/romm_provider.dart';
import 'package:neostation/repositories/romm_save_map_repository.dart';
import 'package:neostation/repositories/scraper_repository.dart';
import 'package:path/path.dart' as p;

import 'database_test_helper.dart';

/// The link paths for ROMs that were already on disk before RomM was
/// connected: finding the local copy
/// by the shared filename rule, writing its mapping row exactly once, and
/// gating the browser's metadata import on the game having none.
///
/// [RommProvider.resolveSystem] is the only server-facing step in the probe,
/// so a subclass pins it to a fixed system and the rest runs against a real
/// temp directory and an in-memory database — the same filesystem the
/// "downloaded" badge probes, which is what makes the two agree.

const _snes = SystemModel(
  id: 'snes',
  folderName: 'snes',
  realName: 'Super Nintendo',
  iconImage: '',
  color: '#000000',
  folders: ['snes', 'sfc'],
);

class _PinnedSystem extends RommProvider {
  final SystemModel? system;
  _PinnedSystem(this.system);

  @override
  Future<SystemModel?> resolveSystem(RommRom rom) async => system;
}

RommRom _rom(int id, String fsName, {bool multiFile = false}) => RommRom(
  id: id,
  name: 'Game $id',
  platformId: 1,
  platformSlug: 'snes',
  fsName: fsName,
  fsNameNoExt: p.basenameWithoutExtension(fsName),
  fsExtension: p.extension(fsName).replaceFirst('.', ''),
  fsSizeBytes: 0,
  hasMultipleFiles: multiFile,
);

void main() {
  final helper = DatabaseTestHelper();
  late DatabaseAdapter db;
  late Directory root;
  late List<String> romFolders;

  setUp(() async {
    db = await helper.setUp();
    await db.execute(SqliteMigrations.createAppRommRomMapTableSql);
    root = await Directory.systemTemp.createTemp('romm_link_');
    romFolders = [root.path];
  });

  tearDown(() async {
    await helper.tearDown();
    await root.delete(recursive: true);
  });

  Future<File> put(String folder, String name) async {
    final f = File(p.join(root.path, folder, name));
    await f.create(recursive: true);
    return f;
  }

  group('findLocalCopy', () {
    test('returns the directory and on-disk name of a matching file', () async {
      await put('snes', 'Chrono Trigger (USA).sfc');
      final provider = _PinnedSystem(_snes);

      final copy = await provider.findLocalCopy(
        _rom(7, 'Chrono Trigger (USA).sfc'),
        romFolders,
      );

      expect(copy, isNotNull);
      expect(copy!.system.folderName, 'snes');
      expect(copy.directory, p.join(root.path, 'snes'));
      expect(copy.filename, 'Chrono Trigger (USA).sfc');
      expect(copy.romname, 'Chrono Trigger (USA)');
    });

    test('agrees with isDownloaded', () async {
      await put('snes', 'a.sfc');
      final provider = _PinnedSystem(_snes);
      final present = _rom(1, 'a.sfc');
      final absent = _rom(2, 'b.sfc');

      expect(await provider.isDownloaded(present, romFolders), isTrue);
      expect(await provider.findLocalCopy(present, romFolders), isNotNull);
      expect(await provider.isDownloaded(absent, romFolders), isFalse);
      expect(await provider.findLocalCopy(absent, romFolders), isNull);
    });

    test('finds a copy under a folder alias', () async {
      await put('sfc', 'a.sfc');
      final provider = _PinnedSystem(_snes);

      final copy = await provider.findLocalCopy(_rom(1, 'a.sfc'), romFolders);

      expect(copy?.directory, p.join(root.path, 'sfc'));
      expect(
        copy?.system.folderName,
        'snes',
        reason: 'the mapping is keyed by the canonical folder, not the alias',
      );
    });

    test('finds a multi-disc game by its playlist', () async {
      await put('snes', 'Game (USA).m3u');
      final provider = _PinnedSystem(_snes);

      final copy = await provider.findLocalCopy(
        _rom(1, 'Game (USA)', multiFile: true),
        romFolders,
      );

      expect(copy?.filename, 'Game (USA).m3u');
    });

    test('a copy the badge probe found is not probed for again', () async {
      // The disk is the witness: once isDownloadedCached has looked, deleting
      // the file must not change what findLocalCopy hands the link path —
      // a second probe would notice, a memoised copy does not.
      final file = await put('snes', 'a.sfc');
      final provider = _PinnedSystem(_snes);
      final rom = _rom(1, 'a.sfc');

      expect(await provider.isDownloadedCached(rom, romFolders), isTrue);
      await file.delete();

      final copy = await provider.findLocalCopy(rom, romFolders);
      expect(copy, isNotNull, reason: 'served from the memo, not the disk');
      expect(copy!.filename, 'a.sfc');
      expect(await provider.isDownloadedCached(rom, romFolders), isTrue);

      provider.invalidateDownloadedCache();
      expect(
        await provider.findLocalCopy(rom, romFolders),
        isNull,
        reason: 'invalidation drops the copy along with the flag',
      );
      expect(await provider.isDownloadedCached(rom, romFolders), isFalse);
    });

    test('a miss is not memoised as a copy', () async {
      final provider = _PinnedSystem(_snes);
      final rom = _rom(1, 'a.sfc');

      expect(await provider.isDownloadedCached(rom, romFolders), isFalse);
      await put('snes', 'a.sfc');

      expect(
        await provider.findLocalCopy(rom, romFolders),
        isNotNull,
        reason: 'only hits are memoised; a miss probes again',
      );
    });

    test('is null when the platform resolves to no local system', () async {
      await put('snes', 'a.sfc');
      final provider = _PinnedSystem(null);

      expect(
        await provider.findLocalCopy(_rom(1, 'a.sfc'), romFolders),
        isNull,
      );
    });
  });

  group('linkLocalCopy', () {
    test(
      'writes one row keyed by the on-disk name, then never again',
      () async {
        await put('snes', 'a.sfc');
        final provider = _PinnedSystem(_snes);
        final rom = _rom(42, 'a.sfc');
        final copy = (await provider.findLocalCopy(rom, romFolders))!;

        expect(
          await provider.linkLocalCopy(rom, copy),
          RommMappingWriteResult.written,
        );
        expect(await RommSaveMapRepository.getRommRomId('a.sfc', 'snes'), 42);
        expect(
          await RommSaveMapRepository.getRommRomId('a', 'snes'),
          42,
          reason:
              'resolvable from the extension-stripped GameModel.romname too',
        );

        expect(
          await provider.linkLocalCopy(rom, copy),
          RommMappingWriteResult.kept,
          reason: 'a second confirm is "already downloaded", not a rewrite',
        );
      },
    );

    test('never overwrites a row that points elsewhere', () async {
      await put('snes', 'a.sfc');
      await RommSaveMapRepository.putMapping(
        source: RommLinkSource.download,
        romname: 'a.sfc',
        systemFolder: 'snes',
        rommRomId: 1,
      );
      final provider = _PinnedSystem(_snes);
      final rom = _rom(2, 'a.sfc');
      final copy = (await provider.findLocalCopy(rom, romFolders))!;

      expect(
        await provider.linkLocalCopy(rom, copy),
        RommMappingWriteResult.kept,
      );
      expect(await RommSaveMapRepository.getRommRomId('a.sfc', 'snes'), 1);
    });
  });

  group('importMetadataIfMissing', () {
    // Renamed: there are two gates now, not one. The row write and the artwork
    // import overwrite different things — `saveGameMetadata` is a whole-row
    // writer that replaces a curated row, and `_saveRommMedia` overwrites the
    // asset and deletes its other extensions — so a single "has a metadata
    // row" gate ran both or neither. A game scraped by ScreenScraper but
    // carrying no metadata row used to lose its art to an A press.
    test('leaves curated metadata alone when a row already exists', () async {
      await put('snes', 'a.sfc');
      await ScraperRepository.saveGameMetadata({
        'filename': 'a.sfc',
        'real_name': 'Curated by hand',
      }, 'snes');
      final provider = _PinnedSystem(_snes);
      final rom = _rom(1, 'a.sfc');
      final copy = (await provider.findLocalCopy(rom, romFolders))!;

      // The call may still run the media half — this fixture has no artwork on
      // disk — so the return value is not what is under test here. What must
      // hold is that the row is untouched.
      await provider.importMetadataIfMissing(rom, copy, FileProvider());

      final row = await ScraperRepository.getGameMetadata('snes', 'a.sfc');
      expect(
        row?['real_name'],
        'Curated by hand',
        reason: 'the metadata gate is the row, and the row exists',
      );
    });
  });
}
