import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/data/datasources/sqlite_service.dart';
import 'package:neostation/l10n/app_locale.dart';
import 'package:neostation/providers/sqlite_config_provider.dart';
import 'package:neostation/repositories/config_repository.dart';
import 'package:neostation/services/global_notification_service.dart';
import 'package:sqlite3/sqlite3.dart';

import 'database_test_helper.dart';

/// Removing a ROM folder deleted its games, then the folder, then saved the
/// config, each on its own, and swallowed any error: Settings > Directories said
/// "ROM folder removed" whatever happened. A failure partway left half a
/// removal behind (games gone, folder kept), and one after the folder row was
/// deleted put the folder back into memory only, so the next save of any
/// setting wrote it back to the table and the next scan brought its games back.
/// The removal is now one transaction, a failure stores none of it and is
/// reported, and the folder stays where it was.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final helper = DatabaseTestHelper();
  late DatabaseAdapter db;

  setUp(() async {
    db = await helper.setUp();
    GlobalNotificationService().dismiss();
  });

  tearDown(() async {
    await helper.tearDown();
    GlobalNotificationService().dismiss();
  });

  Future<Directory> romRoot() async {
    final dir = await Directory.systemTemp.createTemp('neostation_rom_root_');
    addTearDown(() async {
      if (await dir.exists()) await dir.delete(recursive: true);
    });
    return dir;
  }

  Future<void> storeRom(String path) => db.rawInsert(
    'INSERT INTO user_roms (app_system_id, filename, rom_path) '
    'VALUES (?, ?, ?)',
    ['nes', path.split('/').last, path],
  );

  Future<List<String>> storedRomPaths() async => (await db.rawQuery(
    'SELECT rom_path FROM user_roms ORDER BY rom_path',
  )).map((r) => r['rom_path'] as String).toList();

  // Makes one kind of write fail, as a locked or missing database would.
  Future<void> failOn(String event) => db.execute(
    'CREATE TRIGGER fail_write BEFORE $event '
    "BEGIN SELECT RAISE(ABORT, 'disk failure'); END",
  );
  Future<void> allowWrites() => db.execute('DROP TRIGGER IF EXISTS fail_write');

  // Three folders, each with a game; the middle one is the one removed.
  Future<(SqliteConfigProvider, List<String>)> threeFolders() async {
    final roots = [await romRoot(), await romRoot(), await romRoot()];
    final provider = SqliteConfigProvider();
    for (final root in roots) {
      await provider.addRomFolder(root.path, scan: false);
      await storeRom('${root.path}/nes/Game.nes');
    }
    return (provider, [for (final root in roots) root.path]);
  }

  for (final (step, event) in [
    ('deleting its games', 'DELETE ON user_roms'),
    ('deleting the folder', 'DELETE ON user_rom_folders'),
    ('saving the config', 'UPDATE ON user_config'),
  ]) {
    group('when $step fails', () {
      test('the removal fails and stores nothing', () async {
        final (provider, folders) = await threeFolders();
        final games = await storedRomPaths();
        await failOn(event);

        await expectLater(
          provider.removeRomFolder(folders[1]),
          throwsA(isA<SqliteException>()),
        );

        expect(await ConfigRepository.getUserRomFolders(), folders);
        expect(await storedRomPaths(), games, reason: 'games kept');
        // Back where it was, not appended.
        expect(provider.config.romFolders, folders);
        expect(provider.isLoading, isFalse);
      });

      test('the next save does not drop or bring back anything', () async {
        final (provider, folders) = await threeFolders();
        final games = await storedRomPaths();
        await failOn(event);
        await provider.removeRomFolder(folders[1]).catchError((_) {});
        await allowWrites();

        await provider.updateHideRecentCard(true);

        expect(await ConfigRepository.getUserRomFolders(), folders);
        expect(await storedRomPaths(), games);
      });
    });
  }

  test('a failed save of the last folder keeps it and its games', () async {
    final root = await romRoot();
    final provider = SqliteConfigProvider();
    await provider.addRomFolder(root.path, scan: false);
    await storeRom('${root.path}/nes/Game.nes');
    await failOn('UPDATE ON user_config');

    await expectLater(
      provider.removeRomFolder(root.path),
      throwsA(isA<SqliteException>()),
    );

    expect(await ConfigRepository.getUserRomFolders(), [root.path]);
    expect(await storedRomPaths(), ['${root.path}/nes/Game.nes']);
    expect(provider.config.romFolders, [root.path]);
  });

  test('a failed refresh after the removal still counts as removed', () async {
    // Removing the last folder clears the detected systems afterwards; the
    // folder and its games are gone by then, so a failure there is no reason
    // to report the removal as failed or to put the folder back.
    final root = await romRoot();
    final provider = SqliteConfigProvider();
    await provider.addRomFolder(root.path, scan: false);
    await storeRom('${root.path}/nes/Game.nes');
    await db.rawInsert(
      'INSERT INTO user_detected_systems (app_system_id, actual_folder_name) '
      'VALUES (?, ?)',
      ['nes', 'nes'],
    );
    await failOn('DELETE ON user_detected_systems');

    await provider.removeRomFolder(root.path);

    expect(await ConfigRepository.getUserRomFolders(), isEmpty);
    expect(await storedRomPaths(), isEmpty);
    expect(provider.config.romFolders, isEmpty);
  });

  group('Settings > Directories', () {
    final source = File(
      'lib/screens/settings_screen/new_settings_options/'
      'directories_settings_content.dart',
    ).readAsStringSync();
    String removal() {
      final start = source.indexOf('Future<void> _removeRomFolder(');
      expect(start, isNot(-1));
      return source.substring(start, source.indexOf('\n  }\n', start));
    }

    test('says the removal failed instead of that it worked', () {
      final handler = RegExp(
        r'\} catch \(e\) \{(.*?)\n      \}',
        dotAll: true,
      ).firstMatch(removal());
      expect(handler, isNotNull, reason: 'no catch around the removal');
      final block = handler!.group(1)!;
      expect(block, contains('AppLocale.romFolderRemoveFailed'));
      expect(block, contains('NotificationType.error'));
      expect(block, isNot(contains('romFolderRemoved')));
      // The success message comes after the removal, inside the try.
      final body = removal();
      expect(
        body.indexOf('await configProvider.removeRomFolder(path);'),
        lessThan(body.indexOf('AppLocale.romFolderRemoved')),
      );
      expect(
        body.indexOf('AppLocale.romFolderRemoved'),
        lessThan(body.indexOf('} catch (e) {')),
      );
    });

    test('reloads the list after a failed removal too', () {
      final body = removal();
      expect(
        body.lastIndexOf('await _loadCurrentPaths();'),
        greaterThan(body.indexOf('} catch (e) {')),
      );
    });

    test('ignores a second press while a removal runs', () {
      final body = removal();
      expect(body, contains('if (_removingRomFolder) return;'));
      expect(
        RegExp(r'\} finally \{\s*_removingRomFolder = false;').hasMatch(body),
        isTrue,
      );
    });

    test('the failure message is in every language', () {
      for (final map in [
        AppLocale.de,
        AppLocale.en,
        AppLocale.es,
        AppLocale.fr,
        AppLocale.id,
        AppLocale.it,
        AppLocale.ja,
        AppLocale.ko,
        AppLocale.pt,
        AppLocale.ru,
        AppLocale.zh,
        AppLocale.zhHant,
      ]) {
        final value = map[AppLocale.romFolderRemoveFailed];
        expect(value, isA<String>());
        expect(value as String, contains('{error}'));
        if (!identical(map, AppLocale.en)) {
          expect(value, isNot(AppLocale.en[AppLocale.romFolderRemoveFailed]));
        }
      }
    });
  });
}
