import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/data/datasources/sqlite_service.dart';
import 'package:neostation/l10n/app_locale.dart';
import 'package:neostation/providers/sqlite_config_provider.dart';
import 'package:neostation/repositories/config_repository.dart';
import 'package:neostation/services/global_notification_service.dart';
import 'package:sqlite3/sqlite3.dart';

import 'database_test_helper.dart';

/// Adding a ROM folder whose save failed (a database locked by another
/// process, storage that went away) set the provider's error and returned as
/// if it had worked. Settings > Directories never reads that error, so the
/// folder just didn't appear and nothing said why. Picking a folder that was
/// already in the list was silent too.
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

  Future<void> failSaves() => db.execute(
    'CREATE TRIGGER fail_config_save BEFORE UPDATE ON user_config '
    "BEGIN SELECT RAISE(ABORT, 'disk failure'); END",
  );

  group('a ROM folder that could not be saved', () {
    test('throws, stores nothing and says why', () async {
      final root = await romRoot();
      final provider = SqliteConfigProvider();
      await failSaves();

      await expectLater(
        provider.addRomFolder(root.path, scan: false),
        throwsA(isA<SqliteException>()),
      );

      expect(provider.config.romFolders, isEmpty);
      expect(await ConfigRepository.getUserRomFolders(), isEmpty);
      // The setup wizard and the setup prompt still read the reason here.
      final prefix = (AppLocale.en[AppLocale.romFolderAddFailed] as String)
          .split('{error}')
          .first;
      expect(provider.error, startsWith(prefix));
      expect(provider.isLoading, isFalse);
    });

    test('a folder that was saved is not reported as failed', () async {
      final root = await romRoot();
      final provider = SqliteConfigProvider();

      await provider.addRomFolder(root.path, scan: false);

      expect(provider.config.romFolders, [root.path]);
      expect(await ConfigRepository.getUserRomFolders(), [root.path]);
      expect(provider.error, isNull);
      expect(provider.isLoading, isFalse);
    });
  });

  group('source', () {
    final scanning = File(
      'lib/providers/sqlite_config_provider/scanning.dart',
    ).readAsStringSync();
    final directories = File(
      'lib/screens/settings_screen/new_settings_options/'
      'directories_settings_content.dart',
    ).readAsStringSync();
    final wizard = File('lib/widgets/setup_wizard.dart').readAsStringSync();

    String body(String source, String signature) {
      final start = source.indexOf(signature);
      expect(start, isNot(-1), reason: '$signature not found');
      return source.substring(start, source.indexOf('\n  }\n', start));
    }

    test('only a failed save is reported, not the scan after it', () {
      final add = body(scanning, 'Future<void> addRomFolder(');
      // The rethrow belongs to the save alone: once the folder is stored, a
      // scan problem is the scan's to report.
      final save = RegExp(
        r'try \{\s*await _saveOrRevert\(previous\);\s*\} catch \(e\) \{'
        r'(.*?)rethrow;\s*\}',
        dotAll: true,
      ).firstMatch(add);
      expect(save, isNotNull, reason: 'the save has its own catch');
      expect(save!.group(1), contains('AppLocale.romFolderAddFailed'));
      expect(
        add.indexOf('await scanSystems();'),
        greaterThan(add.indexOf('rethrow;')),
      );
    });

    group('Settings > Directories', () {
      late final pick = body(directories, 'Future<void> _selectRomFolder()');

      test('says when the folder could not be saved', () {
        final handler =
            RegExp(
              r'\} catch \(e\) \{(.*?)await _loadCurrentPaths\(\);',
              dotAll: true,
            ).firstMatch(
              pick.substring(
                pick.indexOf('await configProvider.addRomFolder('),
              ),
            );
        expect(handler, isNotNull, reason: 'no catch around the add');
        expect(handler!.group(1), contains('AppLocale.romFolderAddFailed'));
        expect(handler.group(1), contains('NotificationType.error'));
        // The list is reloaded either way.
        expect(
          pick.lastIndexOf('await _loadCurrentPaths();'),
          greaterThan(pick.indexOf('AppLocale.romFolderAddFailed')),
        );
      });

      test('says when the folder is already in the list', () {
        final check = pick.indexOf(
          'configProvider.config.romFolders.contains(selected)',
        );
        expect(check, isNot(-1));
        expect(check, lessThan(pick.indexOf('addRomFolder(')));
        expect(pick, contains('AppLocale.romFolderAlreadyAdded'));
      });

      test('ignores a second press while an add runs', () {
        expect(pick, contains('if (_addingRomFolder) return;'));
        expect(
          RegExp(r'\} finally \{\s*_addingRomFolder = false;').hasMatch(pick),
          isTrue,
        );
      });
    });

    test('the setup wizard still reports a failed save itself', () {
      final select = body(wizard, 'Future<void> _selectFolder(');
      expect(
        RegExp(
          r'try \{\s*await configProvider\.addRomFolder\(result, scan: false\);'
          r'\s*\} catch \(_\) \{',
        ).hasMatch(select),
        isTrue,
        reason: 'a throw would skip the wizard\'s own message',
      );
    });
  });

  test('the already-added message is in every language', () {
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
      final value = map[AppLocale.romFolderAlreadyAdded];
      expect(value, isA<String>());
      if (!identical(map, AppLocale.en)) {
        expect(value, isNot(AppLocale.en[AppLocale.romFolderAlreadyAdded]));
      }
    }
  });
}
