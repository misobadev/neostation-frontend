import 'dart:async';
import 'dart:convert';
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
      File(p.join(dir.path, 'Old.m3u'))
          .writeAsStringSync('Disc 1.chd\nDisc 2.chd\n');
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
          // The provider passes the recorded playlist and the discs it lists.
          replaceable: {
            for (final name in ['Old.m3u', 'Disc 1.chd', 'Disc 2.chd'])
              p.join(dir.path, name),
          },
        ),
        'Old.m3u',
      );
      expect(Directory(p.join(dir.path, 'Game')).existsSync(), isFalse);
      expect(File(p.join(dir.path, 'Game.m3u')).existsSync(), isFalse);
      expect(File(p.join(dir.path, 'Disc 1.chd')).readAsBytesSync(), [1]);
    },
  );

  test(
    "an install into the system folder never replaces another game's file",
    () async {
      // A server-chosen name that collides with a file this ROM never
      // recorded: the other game's file must survive. The archive itself is
      // sound, so it is kept for extracting by hand.
      final other = File(p.join(dir.path, 'Disc 1.chd'))..writeAsBytesSync([9]);
      final path = zip({
        'Disc 1.chd': [1],
        'Disc 2.chd': [2],
      });
      await expectLater(
        RommArchiveService.prepareGameDownload(
          path,
          dir.path,
          'Game',
          {'m3u', 'chd'},
          isMultiFile: true,
          reuseExistingDirectory: true,
          playlistName: 'Old.m3u',
        ),
        throwsA(isA<RommArchiveRefusedException>()),
      );
      expect(other.readAsBytesSync(), [9]);
      expect(File(p.join(dir.path, 'Disc 2.chd')).existsSync(), isFalse);
      expect(File(path).existsSync(), isTrue);
    },
  );

  Matcher refused(RommArchiveRefusal reason) => throwsA(
    isA<RommArchiveRefusedException>().having(
      (e) => e.reason,
      'reason',
      reason,
    ),
  );

  test('an archive with too many entries is refused but kept', () async {
    addTearDown(() => RommArchiveService.debugMaxEntries = null);
    RommArchiveService.debugMaxEntries = 100;
    final path = zip({for (var i = 0; i <= 100; i++) 'f$i.iso': []});
    await expectLater(
      RommArchiveService.prepareDownload(path, dir.path, {'iso'}),
      refused(RommArchiveRefusal.unsupported),
    );
    expect(File(path).existsSync(), isTrue);
    expect(File(p.join(dir.path, 'f0.iso')).existsSync(), isFalse);
  });

  test('an archive larger than the free space is refused but kept', () async {
    addTearDown(() => RommArchiveService.debugFreeBytes = null);
    RommArchiveService.debugFreeBytes = 1;
    final path = zip({
      'Game/Disc 1.chd': [1, 2],
    });
    await expectLater(
      RommArchiveService.prepareDownload(path, dir.path, {'m3u', 'chd'}),
      refused(RommArchiveRefusal.notEnoughSpace),
    );
    expect(File(path).existsSync(), isTrue);
    expect(Directory(p.join(dir.path, 'Game')).existsSync(), isFalse);
  });

  test('an entry posing as the install record is unsafe', () async {
    final path = zip({
      'Game/Disc 1.chd': [1],
      'Game/${RommArchiveService.manifestName}': 'Other.sav\n'.codeUnits,
    });
    expect(
      await RommArchiveService.prepareGameDownload(path, dir.path, 'Game', {
        'm3u',
        'chd',
      }),
      isNull,
    );
    expect(File(path).existsSync(), isFalse);
  });

  for (final name in [
    '.romm_installed\u0000.bin',
    '.romm_installed.',
    '.ROMM_INSTALLED ',
    '.romm_installed:stream',
    '.romm_download_9/part',
  ]) {
    test('an entry named ${jsonEncode(name)} is unsafe', () async {
      final path = zip({
        'Game/Disc 1.chd': [1],
        'Game/$name': '# romm-rom-id: 42\nCard.mcr\n'.codeUnits,
      });
      expect(
        await RommArchiveService.prepareGameDownload(path, dir.path, 'Game', {
          'm3u',
          'chd',
        }, romId: 42),
        isNull,
      );
      expect(File(path).existsSync(), isFalse);
      expect(Directory(p.join(dir.path, 'Game')).existsSync(), isFalse);
    });
  }

  test('a same-named folder with no record is not replaced', () async {
    // The user's own folder, or one from before install records: only the
    // copy the provider found for this ROM (replaceRoot) would make it ours.
    final disc = File(p.join(dir.path, 'Game', 'Disc 1.chd'))
      ..createSync(recursive: true)
      ..writeAsBytesSync([8]);
    final path = zip({
      'Game/Disc 1.chd': [1],
      'Game/Disc 2.chd': [2],
    });
    await expectLater(
      RommArchiveService.prepareGameDownload(path, dir.path, 'Game', {
        'm3u',
        'chd',
      }, romId: 42),
      refused(RommArchiveRefusal.conflict),
    );
    expect(disc.readAsBytesSync(), [8]);
    expect(File(path).existsSync(), isTrue);
  });

  test('an install records the ROM that made the folder', () async {
    final path = zip({
      'Game/Disc 1.chd': [1],
      'Game/Disc 2.chd': [2],
    });
    expect(
      await RommArchiveService.prepareGameDownload(path, dir.path, 'Game', {
        'm3u',
        'chd',
      }, romId: 42),
      'Game.m3u',
    );
    final record = await RommArchiveService.readInstallRecord(
      p.join(dir.path, 'Game'),
    );
    expect(record.romId, 42);
    expect(record.paths, {'disc 1.chd', 'disc 2.chd', 'game.m3u'});
  });

  test('an oversized playlist is not read into memory', () async {
    final path = zip({
      'Game/Game.m3u': List.filled(
        RommArchiveService.maxDescriptorBytes + 1,
        65,
      ),
      'Game/Disc 1.chd': [1],
    });
    await expectLater(
      RommArchiveService.prepareGameDownload(path, dir.path, 'Game', {
        'm3u',
        'chd',
      }),
      refused(RommArchiveRefusal.unsupported),
    );
    expect(File(path).existsSync(), isTrue);
  });

  group('install steps', () {
    tearDown(() => RommArchiveService.debugInstallHook = null);

    test(
      'a backup that cannot be restored is parked beside its place',
      () async {
        final gameDir = await Directory(p.join(dir.path, 'Game')).create();
        File(p.join(gameDir.path, 'Disc 1.chd')).writeAsBytesSync([8]);
        File(p.join(gameDir.path, 'Disc 2.chd')).writeAsBytesSync([9]);
        final path = zip({
          'Game/Disc 1.chd': [1],
          'Game/Disc 2.chd': [2],
        });
        // The install runs in another isolate, so the hook keeps its own
        // state and the test reads the outcome off the disk.
        RommArchiveService.debugInstallHook = (step, target) async {
          if (step != 'rename' || !target.endsWith('Disc 2.chd')) return;
          // Disc 1 is installed by now. Put a folder where it was, so neither
          // the rollback's delete nor its restore can work.
          final victim = p.join(p.dirname(target), 'Disc 1.chd');
          if (!File(victim).existsSync()) return;
          File(victim).deleteSync();
          File(p.join(victim, 'blocker')).createSync(recursive: true);
          throw StateError('disk went away');
        };
        expect(
          await RommArchiveService.prepareGameDownload(path, dir.path, 'Game', {
            'm3u',
            'chd',
          }, replaceRoot: gameDir.path),
          isNull,
        );
        expect(
          File(p.join(gameDir.path, 'Disc 1.chd.romm-backup'))
              .readAsBytesSync(),
          [8],
        );
        expect(File(p.join(gameDir.path, 'Disc 2.chd')).readAsBytesSync(), [9]);
        expect(File(path).existsSync(), isTrue);
      },
    );

    test("a locked archive doesn't undo a finished install", () async {
      final path = zip({
        'Game/Disc 1.chd': [1],
        'Game/Disc 2.chd': [2],
      });
      RommArchiveService.debugInstallHook = (step, _) async {
        if (step == 'deleteArchive') {
          throw const FileSystemException('locked by antivirus');
        }
      };
      expect(
        await RommArchiveService.prepareGameDownload(path, dir.path, 'Game', {
          'm3u',
          'chd',
        }),
        'Game.m3u',
      );
      expect(File(p.join(dir.path, 'Game', 'Disc 2.chd')).readAsBytesSync(), [
        2,
      ]);
      expect(File(path).existsSync(), isTrue);
    });
  });

  test('a game folder that is a link is not installed into', () async {
    final elsewhere = await Directory(p.join(dir.path, 'elsewhere')).create();
    final systemDir = await Directory(p.join(dir.path, 'psx')).create();
    Link(p.join(systemDir.path, 'Game')).createSync(elsewhere.path);
    final path = zip({
      'Game/Disc 1.chd': [1],
      'Game/Disc 2.chd': [2],
    });
    await expectLater(
      RommArchiveService.prepareGameDownload(path, systemDir.path, 'Game', {
        'm3u',
        'chd',
      }),
      refused(RommArchiveRefusal.conflict),
    );
    expect(elsewhere.listSync(), isEmpty);
    expect(File(path).existsSync(), isTrue);
  });

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
      'Game.gdi': '3\n1 0 4 2352 track01.bin 0\n2 600 0 2352 "track 02.raw" 0\n3 45000 4 2352 track03.bin 0\n'
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
        await RommArchiveService.prepareDownload(
          path,
          dir.path,
          {'iso'},
          replaceable: {existing.path},
        ),
        isNull,
      );
      expect(existing.readAsBytesSync(), [9]);
      expect(File(p.join(dir.path, 'new.iso')).existsSync(), isFalse);
      expect(File(path).existsSync(), isTrue);
      expect(Directory(dir.path).listSync().whereType<Directory>(), isEmpty);
    },
  );

  test(
    'ScummVM descriptor-less ZIP fails, since ScummVM never scans a zip',
    () async {
      final path = zip({
        'LOOM.000': [1],
      });
      expect(
        await RommArchiveService.prepareGameDownload(path, dir.path, 'Game', {
          'scummvm',
        }, scummVm: true),
        isNull,
      );
      // Damaged or incomplete, not unsafe: the caller keeps it.
      expect(File(path).existsSync(), isTrue);
      expect(File(p.join(dir.path, 'LOOM.000')).existsSync(), isFalse);
    },
  );

  for (final ext in ['scummvm', 'dpt']) {
    test('a single .$ext ScummVM file is still kept as it is', () async {
      final path = p.join(dir.path, 'dl', 'Game.$ext');
      File(path)
        ..createSync(recursive: true)
        ..writeAsStringSync('not an id!');
      expect(
        await RommArchiveService.prepareScummVmDownload(path, dir.path),
        'Game.$ext',
      );
      expect(File(p.join(dir.path, 'Game.$ext')).existsSync(), isTrue);
    });
  }
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
      for (final (system, ext) in [
        ('psx', 'm3u'),
        ('psx', 'chd'),
        ('scummvm', 'scummvm'),
      ]) {
        await db.execute('INSERT INTO app_system_extensions VALUES (?, ?)', [
          system,
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
          // An archive refused as unsafe is deleted rather than kept for
          // extracting by hand, and no staging folder is left.
          expect(
            systemDir.listSync().map((entry) => p.basename(entry.path)).toSet(),
            {'Game.m3u', 'Old.chd'},
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
        // Older builds recorded the raw file as this ROM's download.
        await RommSaveMapRepository.putMapping(
          romname: 'Game',
          systemFolder: 'psx',
          rommRomId: 42,
          source: RommLinkSource.download,
          fsName: 'Game',
        );
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
          {
            'Game.m3u',
            'Disc 1.chd',
            'Disc 2.chd',
            RommArchiveService.manifestName,
          },
        );
      },
    );

    test('a failed install puts a stale raw download back', () async {
      final systemDir = await Directory(p.join(dir.path, 'psx')).create();
      File(p.join(systemDir.path, 'Game')).writeAsBytesSync([9]);
      await RommSaveMapRepository.putMapping(
        romname: 'Game',
        systemFolder: 'psx',
        rommRomId: 42,
        source: RommLinkSource.download,
        fsName: 'Game',
      );
      // A damaged archive (bad central-directory CRCs) fails the install
      // after the stale file was moved aside.
      RommService.debugUseHttpClient(
        MockClient((_) async {
          final path = zip({
            'Game/Disc 1.chd': [1],
            'Game/Disc 2.chd': [2, 3],
          }, name: 'corrupt.zip');
          final data = File(path).readAsBytesSync();
          File(path).deleteSync();
          for (var i = 0; i < data.length - 20; i++) {
            if (data[i] == 0x50 &&
                data[i + 1] == 0x4b &&
                data[i + 2] == 0x01 &&
                data[i + 3] == 0x02) {
              data[i + 16] ^= 0xff;
            }
          }
          return http.Response.bytes(data, 200);
        }),
      );
      final result = await provider.downloadRom(rom, romFolders: [dir.path]);
      expect(result.status, RommDownloadStatus.failed);
      expect(File(p.join(systemDir.path, 'Game')).readAsBytesSync(), [9]);
      expect(
        systemDir.listSync().map((entry) => p.basename(entry.path)).toSet(),
        {'Game', 'Game.zip'},
        reason: 'a damaged (not unsafe) archive is kept beside the library',
      );
    });

    test("a root file the save map doesn't record is never replaced", () async {
      // Same name as the ROM, but not this ROM's download (a user's own file,
      // a save): the bundle can't take its place, and the file survives.
      final systemDir = await Directory(p.join(dir.path, 'psx')).create();
      final own = File(p.join(systemDir.path, 'Game'))..writeAsBytesSync([9]);
      serve({
        'Game/Disc 1.chd': [1],
        'Game/Disc 2.chd': [2],
      });
      final result = await provider.downloadRom(rom, romFolders: [dir.path]);
      expect(result.status, RommDownloadStatus.failed);
      expect(own.readAsBytesSync(), [9]);
    });

    test(
      'a failed archive kept in the library is not badged as downloaded',
      () async {
        final systemDir = await Directory(p.join(dir.path, 'psx')).create();
        File(p.join(systemDir.path, 'Game.zip')).writeAsBytesSync([1]);
        final zipped = RommRom.fromJson({
          'id': 43,
          'fs_name': 'Game.zip',
          'platform_slug': 'psx',
        });
        expect(await provider.isDownloaded(zipped, [dir.path]), isFalse);
        expect(await provider.findLocalCopy(zipped, [dir.path]), isNull);
      },
    );

    test(
      'a second press shares the running download and its outcome',
      () async {
        final gate = Completer<void>();
        final path = zip({
          'Game/Disc 1.chd': [1],
          'Game/Disc 2.chd': [2],
        });
        final bytes = File(path).readAsBytesSync();
        File(path).deleteSync();
        var requests = 0;
        RommService.debugUseHttpClient(
          MockClient((_) async {
            requests++;
            await gate.future;
            return http.Response.bytes(bytes, 200);
          }),
        );
        final first = provider.downloadRom(rom, romFolders: [dir.path]);
        final second = provider.downloadRom(rom, romFolders: [dir.path]);
        gate.complete();
        final results = await Future.wait([first, second]);
        expect(results[0].status, RommDownloadStatus.completed);
        expect(results[1].status, RommDownloadStatus.completed);
        expect(requests, 1);
      },
    );

    test('a download that cannot set up its folder still finishes', () async {
      final systemDir = await Directory(p.join(dir.path, 'psx')).create();
      // A file where the download folder goes makes creating it throw.
      File(p.join(systemDir.path, '.romm_download_42')).writeAsBytesSync([1]);
      serve({
        'Game/Disc 1.chd': [1],
      });
      final result = await provider.downloadRom(rom, romFolders: [dir.path]);
      expect(result.status, RommDownloadStatus.failed);
      expect(provider.downloadFor(42)?.status, RommDownloadStatus.failed);
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
        File(p.join(dir.path, 'psx', 'Game', 'Discs', 'Custom.m3u'))
            .createSync(recursive: true);
        expect(await provider.isDownloaded(rom, [dir.path]), isTrue);
      },
    );

    test(
      'legacy root re-download replaces its mapped playlist in place',
      () async {
        final systemDir = await Directory(p.join(dir.path, 'psx')).create();
        File(p.join(systemDir.path, 'Custom.m3u'))
            .writeAsStringSync('Disc 1.chd\nDisc 2.chd\n');
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
        final target = await Directory(p.join(dir.path, 'scummvm', 'loom'))
            .create(recursive: true);
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
          {'Game.scummvm', 'LOOM.000', RommArchiveService.manifestName},
        );
        expect(Directory(p.join(target.path, 'loom')).existsSync(), isFalse);
      },
    );

    test(
      'badge probe returns the actual predictable bundle directory',
      () async {
        final bundle = await Directory(p.join(dir.path, 'psx', 'Game'))
            .create(recursive: true);
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

    test('a deleted game downloads again over the discs it left', () async {
      // Deleting a game removes its playlist; the discs and the user's own
      // memory card stay in its folder. Older download rows name files that
      // are gone.
      final gameDir = await Directory(p.join(dir.path, 'psx', 'Game'))
          .create(recursive: true);
      File(p.join(gameDir.path, 'Disc 1.chd')).writeAsBytesSync([8]);
      File(p.join(gameDir.path, 'Disc 2.chd')).writeAsBytesSync([9]);
      final card = File(p.join(gameDir.path, 'Card.mcr'))
        ..writeAsBytesSync([7]);
      // What the earlier install of this ROM recorded there.
      File(p.join(gameDir.path, RommArchiveService.manifestName))
          .writeAsStringSync(
            '# romm-rom-id: 42\nDisc 1.chd\nDisc 2.chd\nGame.m3u\n',
          );
      for (final name in ['Game.zip', 'Game.m3u']) {
        await RommSaveMapRepository.putMapping(
          romname: name,
          systemFolder: 'psx',
          rommRomId: 42,
          source: RommLinkSource.download,
          fsName: 'Game',
        );
      }
      expect(await provider.isDownloaded(rom, [dir.path]), isFalse);
      serve({
        'Game/Disc 1.chd': [1],
        'Game/Disc 2.chd': [2],
      });
      final result = await provider.downloadRom(rom, romFolders: [dir.path]);
      expect(result.status, RommDownloadStatus.completed);
      expect(File(p.join(gameDir.path, 'Disc 1.chd')).readAsBytesSync(), [1]);
      expect(card.readAsBytesSync(), [7]);
      expect(await RommSaveMapRepository.localNamesForRom(42), [
        (romname: 'Game.m3u', systemFolder: 'psx'),
      ]);
      final fresh = _DiscProvider();
      addTearDown(fresh.dispose);
      expect(await fresh.isDownloaded(rom, [dir.path]), isTrue);
    });

    test('a file the earlier install wrote is replaced again', () async {
      // Not in a format the system launches, so only the install record
      // says it is this game's.
      serve({
        'Game/Disc 1.chd': [1],
        'Game/Game.cfg': [1],
      });
      expect(
        (await provider.downloadRom(rom, romFolders: [dir.path])).status,
        RommDownloadStatus.completed,
      );
      final gameDir = p.join(dir.path, 'psx', 'Game');
      File(p.join(gameDir, 'Game.m3u')).deleteSync();
      serve({
        'Game/Disc 1.chd': [2],
        'Game/Game.cfg': [2],
      });
      expect(
        (await provider.downloadRom(rom, romFolders: [dir.path])).status,
        RommDownloadStatus.completed,
      );
      expect(File(p.join(gameDir, 'Game.cfg')).readAsBytesSync(), [2]);
    });

    test("a user's file in the game folder stops the install", () async {
      final gameDir = await Directory(p.join(dir.path, 'psx', 'Game'))
          .create(recursive: true);
      final notes = File(p.join(gameDir.path, 'notes.txt'))
        ..writeAsBytesSync([7]);
      serve({
        'Game/Disc 1.chd': [1],
        'Game/notes.txt': [1],
      });
      final result = await provider.downloadRom(rom, romFolders: [dir.path]);
      expect(result.status, RommDownloadStatus.failed);
      expect(result.error, RommDownloadError.extraction);
      expect(notes.readAsBytesSync(), [7]);
      // Sound, so kept: moving the file and extracting by hand still works.
      expect(File(p.join(dir.path, 'psx', 'Game.zip')).existsSync(), isTrue);
    });

    test('not enough space keeps the download and says so', () async {
      addTearDown(() => RommArchiveService.debugFreeBytes = null);
      RommArchiveService.debugFreeBytes = 0;
      serve({
        'Game/Disc 1.chd': [1],
      });
      final result = await provider.downloadRom(rom, romFolders: [dir.path]);
      expect(result.status, RommDownloadStatus.failed);
      expect(result.error, RommDownloadError.notEnoughSpace);
      expect(
        Directory(p.join(dir.path, 'psx'))
            .listSync()
            .map((entry) => p.basename(entry.path))
            .toSet(),
        {'Game.zip'},
      );
    });

    test("a playlist line that isn't a sibling disc is not replaced", () async {
      final systemDir = await Directory(p.join(dir.path, 'psx')).create();
      File(p.join(systemDir.path, 'Custom.m3u'))
          .writeAsStringSync('Disc 1.chd\nCard.mcr\n');
      final card = File(p.join(systemDir.path, 'Card.mcr'))
        ..writeAsBytesSync([7]);
      await RommSaveMapRepository.putMapping(
        romname: 'Custom.m3u',
        systemFolder: 'psx',
        rommRomId: 42,
        source: RommLinkSource.download,
        fsName: 'Game',
      );
      serve({
        'Disc 1.chd': [1],
        'Card.mcr': [1],
      });
      final result = await provider.downloadRom(rom, romFolders: [dir.path]);
      expect(result.status, RommDownloadStatus.failed);
      expect(card.readAsBytesSync(), [7]);
    });

    test("another ROM's folder of the same name is not replaced", () async {
      // A different RomM entry (say the .7z of the same game) installed
      // here first. Its files are its own, even in a launchable format.
      final gameDir = await Directory(p.join(dir.path, 'psx', 'Game'))
          .create(recursive: true);
      final disc = File(p.join(gameDir.path, 'Disc 1.chd'))
        ..writeAsBytesSync([8]);
      File(p.join(gameDir.path, RommArchiveService.manifestName))
          .writeAsStringSync('# romm-rom-id: 7\nDisc 1.chd\nGame.m3u\n');
      serve({
        'Game/Disc 1.chd': [1],
        'Game/Disc 2.chd': [2],
      });
      final result = await provider.downloadRom(rom, romFolders: [dir.path]);
      expect(result.status, RommDownloadStatus.failed);
      expect(disc.readAsBytesSync(), [8]);
      expect(File(p.join(dir.path, 'psx', 'Game.zip')).existsSync(), isTrue);
      expect(
        (await RommArchiveService.readInstallRecord(gameDir.path)).romId,
        7,
        reason: "the other ROM's record is left alone",
      );
    });

    test('a nested bundle copy is served from the cache', () async {
      File(p.join(dir.path, 'psx', 'Game', 'Discs', 'Custom.m3u'))
          .createSync(recursive: true);
      await RommSaveMapRepository.putMapping(
        romname: 'Custom.m3u',
        systemFolder: 'psx',
        rommRomId: 42,
        source: RommLinkSource.download,
        fsName: 'Game',
      );
      final first = await provider.findLocalCopy(rom, [dir.path]);
      expect(first, isNotNull);
      // Without the row a fresh probe can't find the file, so only the
      // cache can answer.
      await RommSaveMapRepository.removeMapping('Custom.m3u', 'psx');
      expect(await provider.findLocalCopy(rom, [dir.path]), same(first));
    });
  });
}
