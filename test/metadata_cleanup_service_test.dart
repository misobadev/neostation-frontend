import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/services/metadata_cleanup_service.dart';

import 'database_test_helper.dart';

void main() {
  final dbHelper = DatabaseTestHelper();
  late dynamic db;
  late Directory tempMediaDir;

  setUp(() async {
    db = await dbHelper.setUp();
    tempMediaDir = await Directory.systemTemp.createTemp(
      'metadata_cleanup_test_',
    );

    await db.execute(
      "INSERT INTO app_systems (id, folder_name, real_name) VALUES ('psx', 'psx', 'PlayStation')",
    );
  });

  tearDown(() async {
    await dbHelper.tearDown();
    if (await tempMediaDir.exists()) {
      await tempMediaDir.delete(recursive: true);
    }
  });

  group('MetadataCleanupService', () {
    test('analyze returns empty when all metadata has matching ROMs', () async {
      await db.execute(
        "INSERT INTO user_roms (filename, rom_path, app_system_id) VALUES ('game.chd', '/roms/psx/game.chd', 'psx')",
      );
      await db.execute(
        "INSERT INTO user_screenscraper_metadata (app_system_id, filename, is_fully_scraped) VALUES ('psx', 'game.chd', 1)",
      );

      final result = await MetadataCleanupService.analyze();
      expect(result.hasOrphans, isFalse);
      expect(result.orphanedItems, isEmpty);
    });

    test('analyze detects NeoStation orphaned metadata', () async {
      await db.execute(
        "INSERT INTO user_screenscraper_metadata (app_system_id, filename, is_fully_scraped) VALUES ('psx', 'orphan.chd', 1)",
      );

      final result = await MetadataCleanupService.analyze();
      expect(result.hasOrphans, isTrue);
      expect(result.orphanedItems.length, 1);
      expect(result.orphanedItems.first.filename, 'orphan.chd');
      expect(result.orphanedItems.first.esdeImported, isFalse);
    });

    test('analyze detects ES-DE imported orphaned metadata', () async {
      await db.execute(
        "INSERT INTO user_screenscraper_metadata (app_system_id, filename, is_fully_scraped, esde_imported) VALUES ('psx', 'esde_orphan.chd', 0, 1)",
      );

      final result = await MetadataCleanupService.analyze();
      expect(result.hasOrphans, isTrue);
      expect(result.orphanedItems.length, 1);
      expect(result.orphanedItems.first.esdeImported, isTrue);
    });

    test(
      'clean deletes NeoStation rows and media but leaves ES-DE rows untouched',
      () async {
        // ROM with metadata stays in the library.
        await db.execute(
          "INSERT INTO user_roms (filename, rom_path, app_system_id) VALUES ('present.chd', '/roms/psx/present.chd', 'psx')",
        );
        await db.execute(
          "INSERT INTO user_screenscraper_metadata (app_system_id, filename, is_fully_scraped) VALUES ('psx', 'present.chd', 1)",
        );

        // NeoStation orphaned metadata with media files on disk.
        await db.execute(
          "INSERT INTO user_screenscraper_metadata (app_system_id, filename, is_fully_scraped) VALUES ('psx', 'neostation_orphan.chd', 1)",
        );
        final screenshotsDir = Directory(
          '${tempMediaDir.path}/psx/screenshots',
        );
        await screenshotsDir.create(recursive: true);
        final orphanScreenshot = File(
          '${screenshotsDir.path}/neostation_orphan.png',
        );
        await orphanScreenshot.writeAsString('screenshot');

        // ES-DE imported orphaned metadata must stay in the database and disk untouched.
        await db.execute(
          "INSERT INTO user_screenscraper_metadata (app_system_id, filename, is_fully_scraped, esde_imported) VALUES ('psx', 'esde_orphan.chd', 0, 1)",
        );
        final esdeScreenshot = File('${screenshotsDir.path}/esde_orphan.png');
        await esdeScreenshot.writeAsString('esde screenshot');

        final result = await MetadataCleanupService.clean(
          mediaDirectoryPath: '${tempMediaDir.path}/',
        );

        expect(result.orphanedItems.length, 2);
        expect(result.deletedItems.length, 1);
        expect(result.deletedItems.first.filename, 'neostation_orphan.chd');
        expect(result.skippedEsdeItems.length, 1);
        expect(result.skippedEsdeItems.first.filename, 'esde_orphan.chd');
        expect(result.deletedMediaFiles, 1);

        final remainingMetadata = await db.rawQuery(
          'SELECT filename FROM user_screenscraper_metadata ORDER BY filename',
        );
        expect(remainingMetadata.map((r) => r['filename']).toList(), [
          'esde_orphan.chd',
          'present.chd',
        ]);

        expect(await orphanScreenshot.exists(), isFalse);
        expect(await esdeScreenshot.exists(), isTrue);
      },
    );

    test('clean handles missing media directory gracefully', () async {
      await db.execute(
        "INSERT INTO user_screenscraper_metadata (app_system_id, filename, is_fully_scraped) VALUES ('psx', 'no_media_orphan.chd', 1)",
      );

      final result = await MetadataCleanupService.clean(
        mediaDirectoryPath: '${tempMediaDir.path}/nonexistent/',
      );

      expect(result.deletedItems.length, 1);
      expect(result.deletedMediaFiles, 0);

      final remaining = await db.rawQuery(
        "SELECT filename FROM user_screenscraper_metadata WHERE filename = 'no_media_orphan.chd'",
      );
      expect(remaining, isEmpty);
    });

    test('clean reports progress with the current item', () async {
      await db.execute(
        "INSERT INTO user_screenscraper_metadata (app_system_id, filename, is_fully_scraped) VALUES ('psx', 'orphan_a.chd', 1)",
      );
      await db.execute(
        "INSERT INTO user_screenscraper_metadata (app_system_id, filename, is_fully_scraped) VALUES ('psx', 'orphan_b.chd', 1)",
      );

      final reportedItems = <String>[];
      await MetadataCleanupService.clean(
        mediaDirectoryPath: '${tempMediaDir.path}/',
        onProgress: (progress, item) {
          reportedItems.add(item.filename);
        },
      );

      expect(reportedItems, ['orphan_a.chd', 'orphan_b.chd']);
    });

    test(
      'clean removes metadata for individual discs after multi-disc organization',
      () async {
        // After organizing multi-disc games, individual disc ROMs are gone and a
        // playlist remains. Metadata for the old disc filenames becomes orphaned.
        await db.execute(
          "INSERT INTO user_roms (filename, rom_path, app_system_id) VALUES ('Final Fantasy VIII.m3u', '/roms/psx/Final Fantasy VIII.m3u', 'psx')",
        );
        await db.execute(
          "INSERT INTO user_screenscraper_metadata (app_system_id, filename, is_fully_scraped) VALUES ('psx', 'Final Fantasy VIII.m3u', 1)",
        );
        await db.execute(
          "INSERT INTO user_screenscraper_metadata (app_system_id, filename, is_fully_scraped) VALUES ('psx', 'Final Fantasy VIII (Disc 1).chd', 1)",
        );
        await db.execute(
          "INSERT INTO user_screenscraper_metadata (app_system_id, filename, is_fully_scraped) VALUES ('psx', 'Final Fantasy VIII (Disc 2).chd', 1)",
        );

        final screenshotsDir = Directory(
          '${tempMediaDir.path}/psx/screenshots',
        );
        await screenshotsDir.create(recursive: true);
        final discOneScreenshot = File(
          '${screenshotsDir.path}/Final Fantasy VIII (Disc 1).png',
        );
        final discTwoScreenshot = File(
          '${screenshotsDir.path}/Final Fantasy VIII (Disc 2).png',
        );
        await discOneScreenshot.writeAsString('disc1');
        await discTwoScreenshot.writeAsString('disc2');

        final result = await MetadataCleanupService.clean(
          mediaDirectoryPath: '${tempMediaDir.path}/',
        );

        expect(result.orphanedItems.length, 2);
        expect(result.deletedItems.length, 2);
        expect(result.deletedMediaFiles, 2);

        final remaining = await db.rawQuery(
          'SELECT filename FROM user_screenscraper_metadata ORDER BY filename',
        );
        expect(remaining.map((r) => r['filename']).toList(), [
          'Final Fantasy VIII.m3u',
        ]);
        expect(await discOneScreenshot.exists(), isFalse);
        expect(await discTwoScreenshot.exists(), isFalse);
      },
    );

    test('a row that fails to delete is counted, the others are cleaned', () async {
      await db.execute(
        "INSERT INTO user_screenscraper_metadata (app_system_id, filename, is_fully_scraped) VALUES ('psx', 'good.chd', 1)",
      );
      await db.execute(
        "INSERT INTO user_screenscraper_metadata (app_system_id, filename, is_fully_scraped) VALUES ('psx', 'bad.chd', 1)",
      );
      await db.execute(
        'CREATE TRIGGER fail_one BEFORE DELETE ON user_screenscraper_metadata '
        "WHEN OLD.filename = 'bad.chd' "
        "BEGIN SELECT RAISE(ABORT, 'disk failure'); END",
      );

      final result = await MetadataCleanupService.clean(
        mediaDirectoryPath: '${tempMediaDir.path}/',
      );

      expect(result.deletedItems.map((i) => i.filename), ['good.chd']);
      expect(result.errors, hasLength(1));
      // The failed row stays, so the next run finds it again.
      final left = await MetadataCleanupService.analyze();
      expect(left.orphanedItems.map((i) => i.filename), ['bad.chd']);
    });
  });
}
