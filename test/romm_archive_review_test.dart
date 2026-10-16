import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:neostation/models/romm_rom.dart';
import 'package:neostation/models/system_model.dart';
import 'package:neostation/data/datasources/sqlite_migrations.dart';
import 'package:neostation/services/romm_service.dart';
import 'package:neostation/repositories/romm_save_map_repository.dart';
import 'database_test_helper.dart';
import 'package:neostation/providers/romm_provider.dart';
import 'package:neostation/services/romm_archive_service.dart';
import 'package:path/path.dart' as p;

class _DiscProvider extends RommProvider {
  final String folder;
  _DiscProvider([this.folder = 'psx']);
  @override
  Future<SystemModel?> resolveSystem(RommRom rom) async => SystemModel(
    id: folder,
    folderName: folder,
    realName: 'PlayStation',
    iconImage: '',
    color: '#000000',
    folders: [folder],
  );
}

void main() {
  late Directory dir;
  setUp(
    () async => dir = await Directory.systemTemp.createTemp('romm_review_'),
  );
  tearDown(() async => dir.delete(recursive: true));

  String zip(Map<String, List<int>> files, {String name = 'Game.zip'}) {
    final archive = Archive();
    for (final entry in files.entries) {
      archive.addFile(ArchiveFile(entry.key, entry.value.length, entry.value));
    }
    final path = p.join(dir.path, name);
    File(path).writeAsBytesSync(ZipEncoder().encode(archive));
    return path;
  }

  for (final extension in ['dosz', 'easyrpg', 'vpk', 'love', 'apk']) {
    test('ZIP-based $extension retains its supported ROM filename', () async {
      final path = zip({
        'data': [1],
      }, name: 'Game.$extension');
      expect(
        await RommArchiveService.ensureArchiveExtension(
          path,
          extensions: {'.$extension'.toUpperCase()},
        ),
        path,
      );
      expect(File(path).existsSync(), isTrue);
    });
  }

  test(
    'multi-file payload is detected even with a supported filename',
    () async {
      final path = zip({
        'Game.iso': [1],
      }, name: 'Game.dosz');
      expect(
        await RommArchiveService.ensureArchiveExtension(
          path,
          extensions: {'dosz'},
          isMultiFile: true,
        ),
        '$path.zip',
      );
    },
  );

  test(
    'legacy root playlist is replaced without a new bundle folder',
    () async {
      File(
        p.join(dir.path, 'Old.m3u'),
      ).writeAsStringSync('Disc 1.chd\nDisc 2.chd\n');
      File(p.join(dir.path, 'Disc 1.chd')).writeAsBytesSync([9]);
      final path = zip({
        'Disc 1.chd': [1],
        'Disc 2.chd': [2],
      });
      expect(
        await RommArchiveService.prepareGameDownload(
          path,
          dir.path,
          'Game',
          {'m3u', 'chd'},
          isMultiFile: true,
          reuseExistingDirectory: true,
          playlistName: 'Old.m3u',
        ),
        'Old.m3u',
      );
      expect(Directory(p.join(dir.path, 'Game')).existsSync(), isFalse);
      expect(File(p.join(dir.path, 'Game.m3u')).existsSync(), isFalse);
      expect(File(p.join(dir.path, 'Disc 1.chd')).readAsBytesSync(), [1]);
    },
  );

  test(
    're-download into a bundle does not nest the game folder twice',
    () async {
      final gameDir = await Directory(p.join(dir.path, 'Game')).create();
      final path = zip({
        'Game/Disc 1.chd': [1],
        'Game/Disc 2.chd': [2],
      });
      expect(
        await RommArchiveService.prepareGameDownload(
          path,
          gameDir.path,
          'Game',
          {'m3u', 'chd'},
          reuseExistingDirectory: true,
        ),
        'Game.m3u',
      );
      expect(File(p.join(gameDir.path, 'Disc 1.chd')).existsSync(), isTrue);
      expect(Directory(p.join(gameDir.path, 'Game')).existsSync(), isFalse);
    },
  );

  for (final descriptor in ['ccd', 'cue', 'mds', 'toc']) {
    test('$descriptor companions are not extra playlist discs', () async {
      final dataExt = descriptor == 'mds' ? 'mdf' : 'img';
      final text = descriptor == 'cue'
          ? 'FILE "Disc.$dataExt" BINARY'
          : descriptor == 'toc'
          ? 'DATAFILE "Disc.$dataExt"'
          : 'descriptor';
      final path = zip({
        'Disc.$descriptor': text.codeUnits,
        'Disc.$dataExt': [1],
        if (descriptor == 'ccd') 'Disc.sub': [2],
        'Other.iso': [3],
      });
      expect(
        await RommArchiveService.prepareDownload(path, dir.path, {
          'm3u',
          descriptor,
          dataExt,
          'sub',
          'iso',
        }),
        'Game.m3u',
      );
      expect(File(p.join(dir.path, 'Game.m3u')).readAsLinesSync(), [
        'Disc.$descriptor',
        'Other.iso',
      ]);
      expect(File(p.join(dir.path, 'Disc.$dataExt')).existsSync(), isTrue);
    });
  }

  test('gdi track files are not extra playlist discs', () async {
    final path = zip({
      'Game.gdi':
          '3\n1 0 4 2352 track01.bin 0\n2 600 0 2352 "track 02.raw" 0\n3 45000 4 2352 track03.bin 0\n'
              .codeUnits,
      'track01.bin': [1],
      'track 02.raw': [2],
      'track03.bin': [3],
    });
    expect(
      await RommArchiveService.prepareDownload(path, dir.path, {
        'm3u',
        'gdi',
        'bin',
      }),
      'Game.m3u',
    );
    expect(File(p.join(dir.path, 'Game.m3u')).readAsLinesSync(), ['Game.gdi']);
  });

  test('a bundle launches its base game, not an update or DLC', () async {
    final path = zip({
      'Game/DLC/x.nsp': [1],
      'Game/Game [v0].nsp': [2],
      'Game/Updates/u.nsp': [3],
      'Game/Game [v65536].nsp': [4],
    });
    expect(
      await RommArchiveService.prepareGameDownload(path, dir.path, 'Game', {
        'nsp',
        'xci',
      }),
      'Game [v0].nsp',
    );
    expect(File(p.join(dir.path, 'Game', 'DLC', 'x.nsp')).existsSync(), isTrue);
  });

  test('a bundled playlist with wrapper-prefixed lines is rewritten', () async {
    final path = zip({
      'Game/Game.m3u': 'Game/Disc 1.chd\r\nGame/Disc 2.chd\r\n'.codeUnits,
      'Game/Disc 1.chd': [1],
      'Game/Disc 2.chd': [2],
    });
    expect(
      await RommArchiveService.prepareGameDownload(path, dir.path, 'Game', {
        'm3u',
        'chd',
      }),
      'Game.m3u',
    );
    expect(File(p.join(dir.path, 'Game', 'Game.m3u')).readAsLinesSync(), [
      'Disc 1.chd',
      'Disc 2.chd',
    ]);
  });

  test(
    'a bundled playlist naming missing files is regenerated from the discs',
    () async {
      final path = zip({
        'Game.m3u': 'Missing.chd\n'.codeUnits,
        'Disc 2.chd': [2],
        'Disc 1.chd': [1],
      });
      expect(
        await RommArchiveService.prepareGameDownload(path, dir.path, 'Game', {
          'm3u',
          'chd',
        }),
        'Game.m3u',
      );
      expect(File(p.join(dir.path, 'Game', 'Game.m3u')).readAsLinesSync(), [
        'Disc 1.chd',
        'Disc 2.chd',
      ]);
    },
  );

  test(
    'a symlinked system folder still installs (EmuDeck gc -> gamecube)',
    () async {
      final real = await Directory(p.join(dir.path, 'gamecube')).create();
      final link = await Link(p.join(dir.path, 'gc')).create(real.path);
      // A lone ROM installs straight into the linked system folder.
      final path = zip({
        'Game/Game.iso': [1],
      });
      expect(
        await RommArchiveService.prepareGameDownload(path, link.path, 'Game', {
          'iso',
        }),
        'Game.iso',
      );
      expect(File(p.join(real.path, 'Game.iso')).existsSync(), isTrue);
    },
    skip: Platform.isWindows ? 'Symlinks need elevation on Windows' : false,
  );

  test(
    'duplicate ZIP entries are rejected before any file is written',
    () async {
      // Case-only duplicates collide on case-insensitive filesystems.
      final folded = zip({
        'Game.iso': [1],
        'game.ISO': [2],
      });
      expect(
        await RommArchiveService.prepareDownload(folded, dir.path, {'iso'}),
        isNull,
      );
      // An exact duplicate: `archive` dedupes names, so patch them in place.
      // Same bytes, so only the duplicate check (not a CRC) can reject it.
      final exact = zip({
        'Game.iso': [1],
        'Gbme.iso': [1],
      }, name: 'Exact.zip');
      final bytes = File(exact).readAsBytesSync();
      final from = 'Gbme.iso'.codeUnits;
      for (var i = 0; i + from.length <= bytes.length; i++) {
        if (List.generate(from.length, (k) => bytes[i + k]).join(',') ==
            from.join(',')) {
          bytes[i + 1] = 'a'.codeUnitAt(0);
        }
      }
      File(exact).writeAsBytesSync(bytes);
      expect(
        await RommArchiveService.prepareDownload(exact, dir.path, {'iso'}),
        isNull,
      );
      expect(File(p.join(dir.path, 'Game.iso')).existsSync(), isFalse);
    },
  );

  test('unsafe ZIP cannot replace an existing good ROM', () async {
    final existing = File(p.join(dir.path, 'Game.iso'))..writeAsBytesSync([9]);
    final path = zip({
      'Game.iso': [1],
      '../escape.iso': [2],
    });
    expect(
      await RommArchiveService.prepareDownload(path, dir.path, {'iso'}),
      isNull,
    );
    expect(existing.readAsBytesSync(), [9]);
    expect(Directory(dir.path).listSync().whereType<Directory>(), isEmpty);
  });

  test('corrupt ZIP is verified before replacing existing files', () async {
    final existing = File(p.join(dir.path, 'Game.iso'))..writeAsBytesSync([9]);
    final path = zip({
      'Game.iso': [1, 2, 3],
    });
    final bytes = File(path).readAsBytesSync();
    for (var i = 0; i < bytes.length - 20; i++) {
      if (bytes[i] == 0x50 &&
          bytes[i + 1] == 0x4b &&
          bytes[i + 2] == 0x01 &&
          bytes[i + 3] == 0x02) {
        bytes[i + 16] ^= 0xff; // Corrupt the central-directory CRC.
        break;
      }
    }
    File(path).writeAsBytesSync(bytes);
    expect(
      await RommArchiveService.prepareDownload(path, dir.path, {'iso'}),
      isNull,
    );
    expect(existing.readAsBytesSync(), [9]);
    expect(Directory(dir.path).listSync().whereType<Directory>(), isEmpty);
  });

  test(
    'install failure restores replaced files and removes partial outputs',
    () async {
      final existing = File(p.join(dir.path, 'Game.iso'))
        ..writeAsBytesSync([9]);
      File(p.join(dir.path, 'blocked')).writeAsBytesSync([8]);
      final path = zip({
        'Game.iso': [1],
        'new.iso': [2],
        'blocked/data.bin': [3],
      });
      expect(
        await RommArchiveService.prepareDownload(path, dir.path, {'iso'}),
        isNull,
      );
      expect(existing.readAsBytesSync(), [9]);
      expect(File(p.join(dir.path, 'new.iso')).existsSync(), isFalse);
      expect(File(path).existsSync(), isTrue);
      expect(Directory(dir.path).listSync().whereType<Directory>(), isEmpty);
    },
  );

  test(
    'ScummVM descriptor-less ZIP keeps the previous fallback behavior',
    () async {
      final path = zip({
        'LOOM.000': [1],
      });
      expect(
        await RommArchiveService.prepareGameDownload(path, dir.path, 'Game', {
          'scummvm',
        }, scummVm: true),
        'Game.zip',
      );
      expect(File(path).existsSync(), isTrue);
      expect(File(p.join(dir.path, 'LOOM.000')).existsSync(), isFalse);
    },
  );
  group('provider download lifecycle', () {
    final helper = DatabaseTestHelper();
    late _DiscProvider provider;
    final rom = RommRom.fromJson({
      'id': 42,
      'fs_name': 'Game',
      'has_multiple_files': true,
      'platform_slug': 'psx',
    });
    setUp(() async {
      final db = await helper.setUp();
      await db.execute(SqliteMigrations.createAppRommRomMapTableSql);
      for (final ext in ['m3u', 'chd']) {
        await db.execute('INSERT INTO app_system_extensions VALUES (?, ?)', [
          'psx',
          ext,
        ]);
      }
      provider = _DiscProvider();
      provider.service.configure(
        serverUrl: 'https://romm.test',
        apiKey: 'test',
      );
    });
    tearDown(() async {
      provider.dispose();
      RommService.debugUseHttpClient(null);
      await helper.tearDown();
    });

    void serve(Map<String, List<int>> files) {
      final path = zip(files);
      final bytes = File(path).readAsBytesSync();
      File(path).deleteSync();
      RommService.debugUseHttpClient(
        MockClient((_) async => http.Response.bytes(bytes, 200)),
      );
    }

    test(
      'failed retries keep one archive copy and preserve the old library',
      () async {
        final systemDir = await Directory(p.join(dir.path, 'psx')).create();
        final existing = File(p.join(systemDir.path, 'Game.m3u'))
          ..writeAsStringSync('Old.chd\n');
        File(p.join(systemDir.path, 'Old.chd')).writeAsBytesSync([9]);
        serve({
          'Old.chd': [1],
          '../escape.chd': [2],
        });
        for (var attempt = 0; attempt < 2; attempt++) {
          final result = await provider.downloadRom(
            rom,
            romFolders: [dir.path],
          );
          expect(result.status, RommDownloadStatus.failed);
          expect(result.error, RommDownloadError.extraction);
          expect(existing.readAsStringSync(), 'Old.chd\n');
          expect(File(p.join(systemDir.path, 'Old.chd')).readAsBytesSync(), [
            9,
          ]);
          // The download is kept beside the library rather than thrown away,
          // retries do not pile up copies, and no staging folder is left.
          expect(
            systemDir.listSync().map((entry) => p.basename(entry.path)).toSet(),
            {'Game.m3u', 'Old.chd', 'Game.zip'},
          );
        }
      },
    );

    test(
      'a stale raw root download is replaced by the bundle folder',
      () async {
        final systemDir = await Directory(p.join(dir.path, 'psx')).create();
        // Left by older builds: the folder ZIP saved without an extension,
        // and a crashed download's staging folder.
        File(p.join(systemDir.path, 'Game')).writeAsBytesSync([9]);
        File(p.join(systemDir.path, '.romm_download_7', 'part'))
          ..createSync(recursive: true)
          ..writeAsBytesSync([8]);
        serve({
          'Game/Disc 1.chd': [1],
          'Game/Disc 2.chd': [2],
        });
        final result = await provider.downloadRom(rom, romFolders: [dir.path]);
        expect(result.status, RommDownloadStatus.completed);
        expect(
          systemDir.listSync().map((entry) => p.basename(entry.path)).toSet(),
          {'Game'},
        );
        final gameDir = Directory(p.join(systemDir.path, 'Game'));
        expect(
          gameDir.listSync().map((entry) => p.basename(entry.path)).toSet(),
          {'Game.m3u', 'Disc 1.chd', 'Disc 2.chd'},
        );
      },
    );

    test('a failed install puts a stale raw download back', () async {
      final systemDir = await Directory(p.join(dir.path, 'psx')).create();
      File(p.join(systemDir.path, 'Game')).writeAsBytesSync([9]);
      serve({
        'Disc 1.chd': [1],
        '../escape.chd': [2],
      });
      final result = await provider.downloadRom(rom, romFolders: [dir.path]);
      expect(result.status, RommDownloadStatus.failed);
      expect(File(p.join(systemDir.path, 'Game')).readAsBytesSync(), [9]);
      expect(
        systemDir.listSync().map((entry) => p.basename(entry.path)).toSet(),
        {'Game', 'Game.zip'},
      );
    });

    test(
      'a recorded download is found in its bundle but not in staging',
      () async {
        await RommSaveMapRepository.putMapping(
          romname: 'Custom.m3u',
          systemFolder: 'psx',
          rommRomId: 42,
          source: RommLinkSource.download,
          fsName: 'Game',
        );
        final staged = File(
          p.join(dir.path, 'psx', 'Game', '.romm_download_1', 'Custom.m3u'),
        )..createSync(recursive: true);
        expect(await provider.isDownloaded(rom, [dir.path]), isFalse);
        staged.deleteSync();
        File(
          p.join(dir.path, 'psx', 'Game', 'Discs', 'Custom.m3u'),
        ).createSync(recursive: true);
        expect(await provider.isDownloaded(rom, [dir.path]), isTrue);
      },
    );

    test(
      'legacy root re-download replaces its mapped playlist in place',
      () async {
        final systemDir = await Directory(p.join(dir.path, 'psx')).create();
        File(
          p.join(systemDir.path, 'Custom.m3u'),
        ).writeAsStringSync('Disc 1.chd\nDisc 2.chd\n');
        File(p.join(systemDir.path, 'Disc 1.chd')).writeAsBytesSync([9]);
        await RommSaveMapRepository.putMapping(
          romname: 'Custom.m3u',
          systemFolder: 'psx',
          rommRomId: 42,
          source: RommLinkSource.download,
          fsName: 'Game',
        );
        serve({
          'Disc 1.chd': [1],
          'Disc 2.chd': [2],
        });
        final result = await provider.downloadRom(rom, romFolders: [dir.path]);
        expect(result.status, RommDownloadStatus.completed);
        expect(
          systemDir.listSync().map((entry) => p.basename(entry.path)).toSet(),
          {'Custom.m3u', 'Disc 1.chd', 'Disc 2.chd'},
        );
        expect(File(p.join(systemDir.path, 'Disc 1.chd')).readAsBytesSync(), [
          1,
        ]);
      },
    );

    test(
      'ScummVM re-download reuses its target folder without nesting it',
      () async {
        provider.dispose();
        provider = _DiscProvider('scummvm');
        provider.service.configure(
          serverUrl: 'https://romm.test',
          apiKey: 'test',
        );
        final target = await Directory(
          p.join(dir.path, 'scummvm', 'loom'),
        ).create(recursive: true);
        File(p.join(target.path, 'Game.scummvm')).writeAsStringSync('loom');
        await RommSaveMapRepository.putMapping(
          romname: 'Game.scummvm',
          systemFolder: 'scummvm',
          rommRomId: 42,
          source: RommLinkSource.download,
          fsName: 'Game',
        );
        serve({
          'wrapper/Game.scummvm': 'loom'.codeUnits,
          'wrapper/LOOM.000': [1],
        });
        final result = await provider.downloadRom(rom, romFolders: [dir.path]);
        expect(result.status, RommDownloadStatus.completed);
        expect(
          target.listSync().map((entry) => p.basename(entry.path)).toSet(),
          {'Game.scummvm', 'LOOM.000'},
        );
        expect(Directory(p.join(target.path, 'loom')).existsSync(), isFalse);
      },
    );

    test(
      'badge probe returns the actual predictable bundle directory',
      () async {
        final bundle = await Directory(
          p.join(dir.path, 'psx', 'Game'),
        ).create(recursive: true);
        File(p.join(bundle.path, 'Custom.m3u')).writeAsStringSync('Disc.chd\n');
        await RommSaveMapRepository.putMapping(
          romname: 'Custom.m3u',
          systemFolder: 'psx',
          rommRomId: 42,
          source: RommLinkSource.download,
          fsName: 'Game',
        );
        final copy = await provider.findLocalCopy(rom, [dir.path]);
        expect(copy?.directory, bundle.path);
        expect(copy?.filename, 'Custom.m3u');
      },
    );
  });
}
