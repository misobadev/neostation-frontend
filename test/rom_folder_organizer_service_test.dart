import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/data/datasources/sqlite_service.dart';
import 'package:neostation/services/rom_folder_organizer_service.dart';

import 'database_test_helper.dart';

void main() {
  final dbHelper = DatabaseTestHelper();

  setUp(() async {
    await dbHelper.setUp();
  });

  tearDown(() async {
    await dbHelper.tearDown();
  });

  group('RomFolderOrganizerService', () {
    test('moves Disc files and existing m3u into a game folder', () async {
      final root = await Directory.systemTemp.createTemp(
        'neostation_organize_',
      );
      addTearDown(() async {
        if (await root.exists()) {
          await root.delete(recursive: true);
        }
      });

      final psxDir = Directory('${root.path}/psx')..createSync(recursive: true);

      final disc1 = File('${psxDir.path}/Final Fantasy VIII (Disc 1).chd')
        ..writeAsStringSync('disc1');
      final disc2 = File('${psxDir.path}/Final Fantasy VIII (Disc 2).chd')
        ..writeAsStringSync('disc2');
      final playlist = File('${psxDir.path}/Final Fantasy VIII.m3u')
        ..writeAsStringSync('old-entry.chd\n');

      expect(await disc1.exists(), isTrue);
      expect(await disc2.exists(), isTrue);
      expect(await playlist.exists(), isTrue);

      final db = await SqliteService.getDatabase();
      await db.execute(
        "INSERT INTO user_roms (filename, rom_path, app_system_id) VALUES ('Final Fantasy VIII (Disc 1).chd', '${disc1.path}', 'psx')",
      );
      await db.execute(
        "INSERT INTO user_screenscraper_metadata (filename, app_system_id, real_name, is_fully_scraped) VALUES ('Final Fantasy VIII (Disc 1).chd', 'psx', 'Final Fantasy VIII', 1)",
      );

      final result = await RomFolderOrganizerService.organizeRomFolders(
        [root.path],
        supportedRomExtensions: {'chd', 'm3u'},
      );

      expect(result.groupsOrganized, 1);
      expect(result.foldersCreated, 1);
      expect(result.playlistsCreated, 0);

      final targetDir = Directory('${psxDir.path}/Final Fantasy VIII');
      final movedDisc1 = File(
        '${targetDir.path}/Final Fantasy VIII (Disc 1).chd',
      );
      final movedDisc2 = File(
        '${targetDir.path}/Final Fantasy VIII (Disc 2).chd',
      );
      final movedPlaylist = File('${targetDir.path}/Final Fantasy VIII.m3u');

      expect(await targetDir.exists(), isTrue);
      expect(await movedDisc1.exists(), isTrue);
      expect(await movedDisc2.exists(), isTrue);
      expect(await movedPlaylist.exists(), isTrue);

      final lines = await movedPlaylist.readAsLines();
      expect(lines, [
        'Final Fantasy VIII (Disc 1).chd',
        'Final Fantasy VIII (Disc 2).chd',
      ]);

      final metadata = await db.rawQuery(
        "SELECT filename, real_name FROM user_screenscraper_metadata WHERE app_system_id = 'psx'",
      );
      expect(metadata.single['filename'], 'Final Fantasy VIII.m3u');
      expect(metadata.single['real_name'], 'Final Fantasy VIII');
    });

    test(
      'creates m3u when missing and matches Disk/CD naming patterns',
      () async {
        final root = await Directory.systemTemp.createTemp(
          'neostation_organize_',
        );
        addTearDown(() async {
          if (await root.exists()) {
            await root.delete(recursive: true);
          }
        });

        final saturnDir = Directory('${root.path}/saturn')
          ..createSync(recursive: true);
        File('${saturnDir.path}/Panzer Dragoon Saga - Disk 1.cue')
            .writeAsStringSync('disk1');
        File('${saturnDir.path}/Panzer Dragoon Saga - CD 2.cue')
            .writeAsStringSync('disk2');

        final result = await RomFolderOrganizerService.organizeRomFolders(
          [root.path],
          supportedRomExtensions: {'cue', 'm3u'},
        );

        expect(result.groupsOrganized, 1);
        expect(result.playlistsCreated, 1);

        final targetDir = Directory('${saturnDir.path}/Panzer Dragoon Saga');
        final playlist = File('${targetDir.path}/Panzer Dragoon Saga.m3u');

        expect(await targetDir.exists(), isTrue);
        expect(await playlist.exists(), isTrue);

        final lines = await playlist.readAsLines();
        expect(lines, [
          'Panzer Dragoon Saga - Disk 1.cue',
          'Panzer Dragoon Saga - CD 2.cue',
        ]);
      },
    );

    test(
      'ignores Skraper media files with disc markers in their names',
      () async {
        final root = await Directory.systemTemp.createTemp(
          'neostation_organize_',
        );
        addTearDown(() async {
          if (await root.exists()) await root.delete(recursive: true);
        });

        final psxDir = Directory('${root.path}/psx')
          ..createSync(recursive: true);
        final mediaDir = Directory('${psxDir.path}/media')
          ..createSync(recursive: true);
        File('${psxDir.path}/Game Disc 1.chd').writeAsStringSync('1');
        File('${psxDir.path}/Game Disc 2.chd').writeAsStringSync('2');
        File('${mediaDir.path}/Game Disc 1.png').writeAsStringSync('image1');
        File('${mediaDir.path}/Game Disc 2.png').writeAsStringSync('image2');

        final result = await RomFolderOrganizerService.organizeRomFolders(
          [root.path],
          supportedRomExtensions: {'chd', 'm3u'},
        );

        expect(result.groupsOrganized, 1);
        expect(await File('${mediaDir.path}/Game Disc 1.png').exists(), isTrue);
        expect(await File('${mediaDir.path}/Game Disc 2.png').exists(), isTrue);
        expect(await File('${mediaDir.path}/Game/Game.m3u').exists(), isFalse);
      },
    );

    test('organizes multi-disc files found in nested subfolders', () async {
      final root = await Directory.systemTemp.createTemp(
        'neostation_organize_',
      );
      addTearDown(() async {
        if (await root.exists()) await root.delete(recursive: true);
      });

      final nestedDir = Directory('${root.path}/psx/collections/rpg')
        ..createSync(recursive: true);
      File('${nestedDir.path}/Suikoden II Disc 1.chd').writeAsStringSync('1');
      File('${nestedDir.path}/Suikoden II Disc 2.chd').writeAsStringSync('2');

      final result = await RomFolderOrganizerService.organizeRomFolders(
        [root.path],
        supportedRomExtensions: {'chd', 'm3u'},
      );

      expect(result.groupsOrganized, 1);
      expect(
        await File('${nestedDir.path}/Suikoden II/Suikoden II.m3u').exists(),
        isTrue,
      );
    });

    test(
      'only scans folders for multi-disc-capable systems when provided',
      () async {
        final root = await Directory.systemTemp.createTemp(
          'neostation_organize_',
        );
        addTearDown(() async {
          if (await root.exists()) await root.delete(recursive: true);
        });

        final psxDir = Directory('${root.path}/psx')..createSync();
        final nesDir = Directory('${root.path}/nes')..createSync();
        for (final directory in [psxDir, nesDir]) {
          File('${directory.path}/Example Disc 1.chd').writeAsStringSync('1');
          File('${directory.path}/Example Disc 2.chd').writeAsStringSync('2');
        }

        final progress = <String>[];
        final result = await RomFolderOrganizerService.organizeRomFolders(
          [root.path],
          supportedRomExtensions: {'chd', 'm3u'},
          supportedSystemFolders: {'psx'},
          onProgress: (completed, total) => progress.add('$completed/$total'),
        );

        expect(result.groupsOrganized, 1);
        expect(progress, ['1/1']);
        expect(
          await File('${psxDir.path}/Example/Example.m3u').exists(),
          isTrue,
        );
        expect(
          await File('${nesDir.path}/Example Disc 1.chd').exists(),
          isTrue,
        );
        expect(
          await File('${nesDir.path}/Example Disc 2.chd').exists(),
          isTrue,
        );
      },
    );

    test('skips m3u folders and everything inside them', () async {
      final root = await Directory.systemTemp.createTemp(
        'neostation_organize_',
      );
      addTearDown(() async {
        if (await root.exists()) await root.delete(recursive: true);
      });

      final playlistDir = Directory('${root.path}/already-organized.m3u/discs')
        ..createSync(recursive: true);
      File('${playlistDir.path}/Game Disc 1.chd').writeAsStringSync('1');
      File('${playlistDir.path}/Game Disc 2.chd').writeAsStringSync('2');

      final result = await RomFolderOrganizerService.organizeRomFolders(
        [root.path],
        supportedRomExtensions: {'chd', 'm3u'},
      );

      expect(result.groupsOrganized, 0);
      expect(result.foldersCreated, 0);
      expect(
        await File('${playlistDir.path}/Game Disc 1.chd').exists(),
        isTrue,
      );
      expect(
        await File('${playlistDir.path}/Game Disc 2.chd').exists(),
        isTrue,
      );
    });
  });
}
