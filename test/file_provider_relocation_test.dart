import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/providers/file_provider.dart';
import 'package:neostation/services/config_service.dart';
import 'package:neostation/services/screenscraper/media_resolver.dart';
import 'package:neostation/services/user_data_location_service.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import 'database_test_helper.dart';

/// Scraped art didn't show after the setup wizard moved the user data.
///
/// [FileProvider] resolves the media folder once, at app start, and every art
/// lookup in the UI goes through it. The wizard moves the user data without a
/// restart, while the scraper already writes to the new folder, so the art
/// landed where the UI never looked until the next launch. Art written through
/// the provider in that session (RomM covers, a replaced image) went to the
/// old folder and was lost after the restart.
///
/// Separately, a failed system-extension lookup at start-up (the database
/// briefly locked on a fresh install) threw away every path, and nothing tried
/// again, so no art showed for the whole session.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final dbHelper = DatabaseTestHelper();
  late dynamic db;
  late Directory tmp;
  late Directory first;
  late Directory second;

  setUp(() async {
    db = await dbHelper.setUp();
    tmp = await Directory.systemTemp.createTemp('neostation_file_provider_');
    first = Directory(p.join(tmp.path, 'first'))..createSync(recursive: true);
    second = Directory(p.join(tmp.path, 'second'))..createSync(recursive: true);
    SharedPreferences.setMockInitialValues({});
    ConfigService.resetStorageAvailability();
    ScreenscraperMediaResolver.resetMediaDirectory();
  });

  tearDown(() async {
    ScreenscraperMediaResolver.resetMediaDirectory();
    await dbHelper.tearDown();
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  group('after a user-data move', () {
    // A database whose systems are synced: start-up has nothing left to load,
    // so only a re-resolve looks again.
    setUp(() async {
      await db.execute(
        "INSERT INTO app_systems (id, real_name, folder_name) "
        "VALUES ('snes', 'SNES', 'snes')",
      );
      await db.execute(
        "INSERT INTO app_system_extensions VALUES ('snes', 'sfc')",
      );
    });

    test('art lookups follow the new folder', () async {
      await UserDataLocationService.setCustomPath(first.path);
      final provider = FileProvider();
      await provider.initialize();
      expect(provider.getMediaDirectoryPath(), p.join(first.path, 'media'));

      await UserDataLocationService.setCustomPath(second.path);
      await provider.reinitialize();

      expect(provider.getMediaDirectoryPath(), p.join(second.path, 'media'));
      expect(
        provider.getMediaPath('snes', 'box2d', 'Game.sfc', 'png'),
        p.join(second.path, 'media', 'snes', 'box2d', 'Game.png'),
      );
    });

    test('art is looked up where the scraper writes it', () async {
      await UserDataLocationService.setCustomPath(first.path);
      final provider = FileProvider();
      await provider.initialize();

      await UserDataLocationService.setCustomPath(second.path);
      await provider.reinitialize();

      expect(
        provider.getMediaDirectoryPath(),
        await ScreenscraperMediaResolver.getMediaDirectory(),
      );
    });

    test('listeners hear about the move', () async {
      await UserDataLocationService.setCustomPath(first.path);
      final provider = FileProvider();
      await provider.initialize();
      var notified = 0;
      provider.addListener(() => notified++);

      await UserDataLocationService.setCustomPath(second.path);
      await provider.reinitialize();

      expect(notified, greaterThan(0));
      expect(provider.isInitialized, isTrue);
    });
  });

  test('a re-resolve that fails keeps the folders that worked', () async {
    await UserDataLocationService.setCustomPath(first.path);
    final provider = FileProvider();
    await provider.initialize();

    // A media folder that can't be created: its path is a file.
    final blocked = File(p.join(tmp.path, 'blocked'))..writeAsStringSync('x');
    await UserDataLocationService.setCustomPath(blocked.path);
    await provider.reinitialize();

    expect(provider.isInitialized, isTrue);
    expect(provider.getMediaDirectoryPath(), p.join(first.path, 'media'));
  });

  test('a fresh database without extensions yet is read again', () async {
    // Its systems are synced after this provider starts, and the start-up
    // retry is what picks their extensions up.
    await UserDataLocationService.setCustomPath(first.path);
    final provider = FileProvider();
    await provider.initialize();

    await db.execute(
      "INSERT INTO app_systems (id, real_name, folder_name) "
      "VALUES ('scummvm', 'ScummVM', 'scummvm')",
    );
    await db.execute(
      "INSERT INTO app_system_extensions VALUES ('scummvm', 'scummvm')",
    );
    await provider.initialize();

    expect(
      provider.getMediaPath('scummvm', 'box2d', 'Monkey Island.scummvm', 'png'),
      p.join(first.path, 'media', 'scummvm', 'box2d', 'Monkey Island.png'),
    );
  });

  group('a failed system-extension lookup at start-up', () {
    test('keeps the art folder', () async {
      await UserDataLocationService.setCustomPath(first.path);
      await db.execute('DROP TABLE app_system_extensions');

      final provider = FileProvider();
      await provider.initialize();

      expect(provider.isInitialized, isTrue);
      expect(provider.getMediaDirectoryPath(), p.join(first.path, 'media'));
    });

    test('is tried again by the next initialize', () async {
      await UserDataLocationService.setCustomPath(first.path);
      await db.execute('DROP TABLE app_system_extensions');
      final provider = FileProvider();
      await provider.initialize();
      // Without the system's list, a long extension isn't recognised as one.
      expect(
        provider.getMediaPath(
          'scummvm',
          'box2d',
          'Monkey Island.scummvm',
          'png',
        ),
        endsWith('Monkey Island.scummvm.png'),
      );

      await db.execute(
        'CREATE TABLE app_system_extensions (system_id TEXT, extension TEXT)',
      );
      await db.execute(
        "INSERT INTO app_systems (id, real_name, folder_name) "
        "VALUES ('scummvm', 'ScummVM', 'scummvm')",
      );
      await db.execute(
        "INSERT INTO app_system_extensions VALUES ('scummvm', 'scummvm')",
      );
      await provider.initialize();

      expect(
        provider.getMediaPath(
          'scummvm',
          'box2d',
          'Monkey Island.scummvm',
          'png',
        ),
        p.join(first.path, 'media', 'scummvm', 'box2d', 'Monkey Island.png'),
      );
    });

    test('a complete start-up is not repeated', () async {
      await UserDataLocationService.setCustomPath(first.path);
      await db.execute(
        "INSERT INTO app_systems (id, real_name, folder_name) "
        "VALUES ('snes', 'SNES', 'snes')",
      );
      await db.execute(
        "INSERT INTO app_system_extensions VALUES ('snes', 'sfc')",
      );
      final provider = FileProvider();
      await provider.initialize();
      var notified = 0;
      provider.addListener(() => notified++);

      await provider.initialize();

      expect(notified, 0);
    });
  });
}
