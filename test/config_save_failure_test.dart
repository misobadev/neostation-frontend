import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/data/datasources/sqlite_config_service.dart';
import 'package:neostation/data/datasources/sqlite_service.dart';
import 'package:neostation/providers/sqlite_config_provider.dart';
import 'package:sqlite3/sqlite3.dart';

import 'database_test_helper.dart';

/// Every settings change was applied to the in-memory config before it was
/// saved, and stayed there when the save failed (a database locked by another
/// process, storage that went away). The app then showed a value the database
/// never got, and the next successful save of any other setting, which writes
/// the whole config, stored it after all. A failed save now puts the setting
/// back.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final helper = DatabaseTestHelper();
  late DatabaseAdapter db;

  setUp(() async {
    db = await helper.setUp();
  });

  tearDown(() async {
    await helper.tearDown();
  });

  // Makes every config save fail, as a locked or missing database would.
  Future<void> failSaves() => db.execute(
    'CREATE TRIGGER fail_config_save BEFORE UPDATE ON user_config '
    "BEGIN SELECT RAISE(ABORT, 'disk failure'); END",
  );
  Future<void> allowSaves() =>
      db.execute('DROP TRIGGER IF EXISTS fail_config_save');

  test('a failed save puts the setting back', () async {
    final provider = SqliteConfigProvider();
    await failSaves();

    await expectLater(
      provider.updateHideRecentCard(true),
      throwsA(isA<SqliteException>()),
    );

    expect(provider.config.hideRecentCard, isFalse);
  });

  test('the next save does not store the failed setting', () async {
    final provider = SqliteConfigProvider();
    await failSaves();
    await expectLater(
      provider.updateHideRecentCard(true),
      throwsA(isA<SqliteException>()),
    );
    await allowSaves();

    await provider.updateShowGameInfo(true);

    final stored = await SqliteConfigService.loadConfig();
    expect(stored.showGameInfo, isTrue);
    expect(stored.hideRecentCard, isFalse);
  });

  test('a change made while a failed save was under way is kept', () async {
    final provider = SqliteConfigProvider();
    // Only the first change's config (recent card hidden, game info off)
    // fails; the second change saves both settings.
    await db.execute(
      'CREATE TRIGGER fail_config_save BEFORE UPDATE ON user_config '
      'WHEN NEW.hide_recent_card = 1 AND NEW.show_game_info = 0 '
      "BEGIN SELECT RAISE(ABORT, 'disk failure'); END",
    );

    final first = provider.updateHideRecentCard(true);
    final second = provider.updateShowGameInfo(true);
    await expectLater(first, throwsA(isA<SqliteException>()));
    await second;

    expect(provider.config.hideRecentCard, isTrue);
    expect(provider.config.showGameInfo, isTrue);
    final stored = await SqliteConfigService.loadConfig();
    expect(stored.hideRecentCard, isTrue);
    expect(stored.showGameInfo, isTrue);
  });

  test('a save that fails partway stores nothing', () async {
    final provider = SqliteConfigProvider();
    await provider.updateRomFolders(['/roms']);
    // The settings row saves, then the ROM folders fail.
    await db.execute(
      'CREATE TRIGGER fail_folder_save BEFORE DELETE ON user_rom_folders '
      "BEGIN SELECT RAISE(ABORT, 'disk failure'); END",
    );

    await expectLater(
      provider.updateHideRecentCard(true),
      throwsA(isA<SqliteException>()),
    );

    final stored = await SqliteConfigService.loadConfig();
    expect(provider.config.hideRecentCard, isFalse);
    expect(stored.hideRecentCard, isFalse);
  });

  test(
    'a queued list size save that fails keeps a change saved since',
    () async {
      final provider = SqliteConfigProvider();
      // Lets two saves through, then fails every later one.
      await db.execute('CREATE TABLE saves_done (n INTEGER)');
      await db.execute(
        'CREATE TRIGGER count_saves AFTER UPDATE ON user_config '
        'BEGIN INSERT INTO saves_done VALUES (1); END',
      );
      await db.execute(
        'CREATE TRIGGER fail_later_saves BEFORE UPDATE ON user_config '
        'WHEN (SELECT COUNT(*) FROM saves_done) >= 2 '
        "BEGIN SELECT RAISE(ABORT, 'disk failure'); END",
      );
      // Hold the transaction lock, as a running scan does, so the saves queue.
      final hold = Completer<void>();
      final holder = db.transaction((_) => hold.future);
      await pumpEventQueue();

      final medium = provider.updateGameListSize('M');
      await pumpEventQueue();
      final large = provider.updateGameListSize('L');
      final hidden = provider.updateHideRecentCard(true);
      await pumpEventQueue();
      hold.complete();
      await holder;
      await medium;
      await hidden;
      await expectLater(large, throwsA(isA<SqliteException>()));

      // The recent card change was saved (with the large size) after the large
      // size's own save was queued; putting the large size back would undo it.
      final stored = await SqliteConfigService.loadConfig();
      expect(stored.hideRecentCard, isTrue);
      expect(provider.config.hideRecentCard, stored.hideRecentCard);
      expect(provider.config.gameListSize, stored.gameListSize);
    },
  );

  test('listeners hear about the setting going back', () async {
    final provider = SqliteConfigProvider();
    final seen = <String>[];
    provider.addListener(() => seen.add(provider.config.gameListSize));
    await failSaves();

    // The list size is shown before it is saved, so the list resizes on the
    // same input; a failed save has to resize it back.
    await expectLater(
      provider.updateGameListSize('L'),
      throwsA(isA<SqliteException>()),
    );

    expect(provider.config.gameListSize, 'S');
    expect(seen, ['L', 'S']);
  });

  test('a failed sort order change keeps the current order', () async {
    final provider = SqliteConfigProvider();
    final before = provider.config.systemSortBy;
    await failSaves();

    await expectLater(
      provider.updateSystemSortBy(before == 'year' ? 'alphabetical' : 'year'),
      throwsA(isA<SqliteException>()),
    );

    expect(provider.config.systemSortBy, before);
  });

  test('a failed video sound change puts it back', () async {
    final provider = SqliteConfigProvider();
    final before = provider.config.videoSound;
    await failSaves();

    // Saved without waiting, so the toggle stays instant.
    await provider.updateVideoSound(!before);
    await pumpEventQueue();

    expect(provider.config.videoSound, before);
  });

  test('a ROM folder that could not be saved is not added', () async {
    final root = await Directory.systemTemp.createTemp('neostation_roms_');
    addTearDown(() => root.delete(recursive: true));
    final provider = SqliteConfigProvider();
    await failSaves();

    await expectLater(
      provider.addRomFolder(root.path, scan: false),
      throwsA(isA<SqliteException>()),
    );

    expect(provider.config.romFolders, isEmpty);
    expect(provider.config.setupCompleted, isFalse);
  });

  test('setup that could not be saved is not completed', () async {
    final provider = SqliteConfigProvider();
    await failSaves();

    await expectLater(
      provider.completeSetup(),
      throwsA(isA<SqliteException>()),
    );

    expect(provider.config.setupCompleted, isFalse);
  });

  test('every settings change goes through the revert', () {
    // A new mutator that saves directly would bring the bug back for its
    // setting. removeRomFolder saves through SqliteConfigService.removeRomFolder
    // instead (with the folder's games, in one transaction) and puts the folder
    // back itself when that fails: it applies the change first on purpose, so a
    // scan started meanwhile skips the folder.
    final sources = [
      'lib/providers/sqlite_config_provider/mutators.dart',
      'lib/providers/sqlite_config_provider/secondary_display.dart',
      'lib/providers/sqlite_config_provider/scanning.dart',
    ];
    for (final path in sources) {
      final source = File(path).readAsStringSync();
      final direct = 'SqliteConfigService.saveConfig('.allMatches(source);
      expect(direct.length, 0, reason: path);
    }
  });
}
