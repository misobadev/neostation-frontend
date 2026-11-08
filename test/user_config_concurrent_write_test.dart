import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/data/datasources/sqlite_config_service.dart';
import 'package:neostation/data/datasources/sqlite_service.dart';
import 'package:neostation/models/config_model.dart';
import 'package:neostation/repositories/config_repository.dart';

import 'database_test_helper.dart';

/// [SqliteService.saveUserConfig] used to read the whole `user_config` row,
/// patch it, and write every column back. Two writers whose read/write windows
/// overlapped therefore lost each other's changes: the second one to write put
/// back the values it had read before the first one landed.
///
/// Sequential saves behaved correctly even then, so these tests interleave the
/// writers on purpose — that is the only shape that tells the two
/// implementations apart.
void main() {
  final dbHelper = DatabaseTestHelper();

  setUp(() async => dbHelper.setUp());
  tearDown(() async => dbHelper.tearDown());

  group('concurrent user_config writes', () {
    test('two single-column writers both survive', () async {
      await SqliteService.saveUserConfig(themeName: 'system', sfxEnabled: 1);

      // Started together, deliberately not awaited in sequence.
      await Future.wait([
        SqliteService.saveUserConfig(themeName: 'dracula'),
        SqliteService.saveUserConfig(sfxEnabled: 0),
      ]);

      final stored = await SqliteService.getUserConfig();
      expect(stored?['theme_name'].toString(), 'dracula');
      expect(stored?['sfx_enabled'].toString(), '0');
    });

    test('a whole-config save does not swallow a concurrent theme change', () async {
      // The real-world shape: a settings toggle persists the whole model while
      // the user picks a theme. The toggle names no theme at all, so it must
      // not carry one back from its own read.
      await ConfigRepository.updateThemeName('system');

      final save = SqliteConfigService.saveConfig(
        const ConfigModel(appLanguage: 'fr'),
      );
      final theme = ConfigRepository.updateThemeName('nord');
      await Future.wait([save, theme]);

      expect(await ConfigRepository.getThemeName(), 'nord');
      final stored = await SqliteService.getUserConfig();
      expect(stored?['app_language'].toString(), 'fr');
    });

    test('columns with a single dedicated setter survive a concurrent save', () async {
      // active_theme (system art), systems_version and ra_user have exactly one
      // writer each and nothing that would restore them, so a lost update here
      // is permanent.
      await Future.wait([
        SqliteService.updateActiveTheme('neo-dark'),
        SqliteService.updateSystemsVersion('42'),
        SqliteService.updateRAUser('androosio'),
        SqliteConfigService.saveConfig(const ConfigModel(sfxEnabled: false)),
      ]);

      final stored = await SqliteService.getUserConfig();
      expect(stored?['active_theme'].toString(), 'neo-dark');
      expect(stored?['systems_version'].toString(), '42');
      expect(stored?['ra_user'].toString(), 'androosio');
      expect(stored?['sfx_enabled'].toString(), '0');
    });

    test('the first write creates the singleton row', () async {
      // Nothing has written user_config yet: the row has to be created before
      // the UPDATE can land on it.
      expect(await SqliteService.getUserConfig(), isNull);

      await SqliteService.saveUserConfig(appLanguage: 'ja');

      final stored = await SqliteService.getUserConfig();
      expect(stored?['id'].toString(), '1');
      expect(stored?['app_language'].toString(), 'ja');
    });

    test(
      'concurrent first writes do not reset each other to defaults',
      () async {
        expect(await SqliteService.getUserConfig(), isNull);

        await Future.wait([
          SqliteService.saveUserConfig(appLanguage: 'de'),
          SqliteService.saveUserConfig(themeName: 'nord'),
        ]);

        final rows = await SqliteService.instance.database.then(
          (db) => db.rawQuery('SELECT COUNT(*) AS n FROM user_config'),
        );
        expect(rows.first['n'].toString(), '1');

        final stored = await SqliteService.getUserConfig();
        expect(stored?['app_language'].toString(), 'de');
        expect(stored?['theme_name'].toString(), 'nord');
      },
    );
  });
}
