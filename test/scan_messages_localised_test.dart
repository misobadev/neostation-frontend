import 'dart:io';

import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/data/datasources/sqlite_service.dart';
import 'package:neostation/l10n/app_locale.dart';
import 'package:neostation/providers/sqlite_config_provider.dart';
import 'package:neostation/services/global_notification_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'database_test_helper.dart';

/// The scan's own messages were English whatever the app language, with
/// English plurals ("ROM folder$plural"): unreachable ROM folders, no ROM
/// folder configured, a folder from a temporary portal path, a folder that
/// couldn't be added, Android storage access, and a scan that failed. They
/// reach the bell, the setup wizard's scan step and the systems screen's setup
/// prompt.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final helper = DatabaseTestHelper();
  late DatabaseAdapter db;
  final de = AppLocale.de;

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await FlutterLocalization.instance.ensureInitialized();
    FlutterLocalization.instance.init(
      mapLocales: [
        const MapLocale('en', AppLocale.en),
        const MapLocale('de', AppLocale.de),
      ],
      initLanguageCode: 'en',
    );
  });

  setUp(() async {
    db = await helper.setUp();
    GlobalNotificationService().dismiss();
    FlutterLocalization.instance.translate('de', save: false);
  });

  tearDown(() async {
    FlutterLocalization.instance.translate('en', save: false);
    await helper.tearDown();
    GlobalNotificationService().dismiss();
  });

  Future<void> storeRom() => db.rawInsert(
    'INSERT INTO user_roms (app_system_id, filename, rom_path) '
    'VALUES (?, ?, ?)',
    ['nes', 'Game.nes', '/roms/nes/Game.nes'],
  );

  GlobalNotificationData? bell(String id) {
    for (final n in GlobalNotificationService().notifier.value) {
      if (n.id == id) return n;
    }
    return null;
  }

  String text(String key) => de[key] as String;

  group('unreachable ROM folders', () {
    test('one folder: singular title and message, drive advice', () async {
      await storeRom();
      final provider = SqliteConfigProvider();
      await provider.addRomFolder('/nonexistent/uat-roms', scan: false);

      await provider.scanSystems();

      final expected = text(AppLocale.romFolderUnreachable)
          .replaceFirst('{advice}', text(AppLocale.romFolderAdviceReconnect))
          .replaceFirst('{folders}', '/nonexistent/uat-roms');
      expect(provider.error, expected);
      expect(
        bell('rom-folders-unreachable')?.title,
        text(AppLocale.romFolderUnreachableTitle),
      );
      expect(bell('rom-folders-unreachable')?.message, expected);
    });

    test('two folders: plural forms, both listed', () async {
      // In English, where the one and many titles differ (in German they
      // don't).
      FlutterLocalization.instance.translate('en', save: false);
      String text(String key) => AppLocale.en[key] as String;
      await storeRom();
      final provider = SqliteConfigProvider();
      await provider.addRomFolder('/nonexistent/a', scan: false);
      await provider.addRomFolder('/nonexistent/b', scan: false);

      await provider.scanSystems();

      expect(
        provider.error,
        text(AppLocale.romFoldersUnreachable)
            .replaceFirst('{advice}', text(AppLocale.romFolderAdviceReconnect))
            .replaceFirst('{folders}', '/nonexistent/a, /nonexistent/b'),
      );
      expect(
        bell('rom-folders-unreachable')?.title,
        text(AppLocale.romFoldersUnreachableTitle),
      );
    });

    test('a portal path gets the portal advice', () async {
      await storeRom();
      final provider = SqliteConfigProvider();
      await provider.updateRomFolders(['/run/user/1000/doc/abc/roms']);

      await provider.scanSystems();

      expect(provider.error, contains(text(AppLocale.romFolderAdvicePortal)));
    });

    test('a path holding a placeholder is not expanded', () async {
      await storeRom();
      final provider = SqliteConfigProvider();
      await provider.addRomFolder('/nonexistent/{advice}', scan: false);

      await provider.scanSystems();

      expect(provider.error, contains('/nonexistent/{advice}'));
    });
  });

  test('no ROM folder configured', () async {
    await storeRom();
    final provider = SqliteConfigProvider();

    await provider.scanSystems();

    expect(provider.error, text(AppLocale.noRomFolderConfigured));
    expect(
      bell('rom-folders-missing')?.title,
      text(AppLocale.noRomFolderTitle),
    );
  });

  test('a folder from a temporary portal path', () async {
    final provider = SqliteConfigProvider();

    await provider.addRomFolder('/run/user/1000/doc/xyz/roms');

    expect(provider.error, text(AppLocale.wizardRomFolderTemporary));
    expect(
      bell('rom-folder-transient')?.title,
      text(AppLocale.romFolderNotAddedTitle),
    );
  });

  test('a folder that could not be added', () async {
    final root = await Directory.systemTemp.createTemp('neostation_scan_');
    addTearDown(() => root.delete(recursive: true));
    final provider = SqliteConfigProvider();
    await db.execute(
      'CREATE TRIGGER fail_config_save BEFORE UPDATE ON user_config '
      "BEGIN SELECT RAISE(ABORT, 'disk failure'); END",
    );

    await expectLater(
      provider.addRomFolder(root.path, scan: false),
      throwsA(isA<Exception>()),
    );

    final prefix = text(AppLocale.romFolderAddFailed).split('{error}').first;
    expect(provider.error, startsWith(prefix));
    expect(provider.error, contains('disk failure'));
    // The setup wizard shows only the first line.
    expect(provider.error, isNot(contains('\n')));
  });

  test('a scan that fails says so, on one line', () async {
    // With no ROM folder configured, the scan first checks for stored ROMs;
    // without the table that check throws.
    await db.execute('DROP TABLE user_roms');
    final provider = SqliteConfigProvider();

    await provider.scanSystems();

    final prefix = text(
      AppLocale.errorScanningRomsDetail,
    ).split('{error}').first;
    expect(provider.error, startsWith(prefix));
    expect(provider.error, isNot(contains('\n')));
  });

  group('source', () {
    final source = File(
      'lib/providers/sqlite_config_provider/scanning.dart',
    ).readAsStringSync();

    test('no English message is built in the scan', () {
      final literals = RegExp(
        r'''(_error\s*=\s*|title:\s*|message:\s*)\n?\s*['"][A-Z]''',
      ).allMatches(source).map((m) => source.substring(m.start, m.end + 40));
      // Two remain in code nothing calls (a rescan that catches its own
      // errors, and clearConfig).
      expect(
        literals.where(
          (l) =>
              !l.contains('Error rescanning') &&
              !l.contains('Error clearing config'),
        ),
        isEmpty,
      );
      expect(source, isNot(contains(r'folder$plural')));
    });

    test('Android storage and folder access use the app language', () {
      expect(source, contains('AppLocale.romStorageAccessRequired'));
      expect(source, contains('AppLocale.romFolderAccessDenied'));
      // The one/many form follows the number of folders.
      expect(
        source,
        matches(
          RegExp(
            r'one\s*\?\s*AppLocale\.romFolderSafMissingTitle\s*'
            r':\s*AppLocale\.romFoldersSafMissingTitle',
          ),
        ),
      );
      expect(
        source,
        matches(
          RegExp(
            r'one\s*\?\s*AppLocale\.romFolderSafMissing\s*'
            r':\s*AppLocale\.romFoldersSafMissing\b',
          ),
        ),
      );
      expect(source, contains("replaceFirst('{count}', '\${missing.length}')"));
    });

    test('a failed scan says so in the app language', () {
      expect(
        RegExp(
          r'_error = _text\(\s*AppLocale\.errorScanningRomsDetail,',
        ).allMatches(source).length,
        2,
      );
    });
  });

  group('every language', () {
    const maps = {
      'de': AppLocale.de,
      'en': AppLocale.en,
      'es': AppLocale.es,
      'fr': AppLocale.fr,
      'id': AppLocale.id,
      'it': AppLocale.it,
      'ja': AppLocale.ja,
      'ko': AppLocale.ko,
      'pt': AppLocale.pt,
      'ru': AppLocale.ru,
      'zh': AppLocale.zh,
      'zh_Hant': AppLocale.zhHant,
    };
    const keys = [
      AppLocale.romFolderNotAddedTitle,
      AppLocale.romFolderAddFailed,
      AppLocale.romFolderSafMissingTitle,
      AppLocale.romFoldersSafMissingTitle,
      AppLocale.romFolderSafMissing,
      AppLocale.romFoldersSafMissing,
      AppLocale.romStorageAccessRequired,
      AppLocale.romFolderAccessDenied,
      AppLocale.romFolderUnreachableTitle,
      AppLocale.romFoldersUnreachableTitle,
      AppLocale.romFolderUnreachable,
      AppLocale.romFoldersUnreachable,
      AppLocale.romFolderAdvicePortal,
      AppLocale.romFolderAdviceReconnect,
      AppLocale.noRomFolderTitle,
      AppLocale.noRomFolderConfigured,
      AppLocale.errorScanningRomsDetail,
    ];
    // The ones that send the user to Settings > Directories.
    const pointToDirectories = [
      AppLocale.romFolderSafMissing,
      AppLocale.romFoldersSafMissing,
      AppLocale.romFolderAdvicePortal,
      AppLocale.romFolderAdviceReconnect,
      AppLocale.noRomFolderConfigured,
    ];

    for (final MapEntry(key: code, value: map) in maps.entries) {
      test('$code has the scan messages', () {
        for (final key in keys) {
          final value = map[key];
          expect(value, isA<String>(), reason: '$code $key');
          // The wizard shows the first line of these only.
          expect(value as String, isNot(contains('\n')), reason: '$code $key');
          if (code != 'en') {
            expect(value, isNot(AppLocale.en[key]), reason: '$code $key');
          }
        }
        for (final key in pointToDirectories) {
          expect(
            map[key],
            contains(
              '${map[AppLocale.settings]} > ${map[AppLocale.directories]}',
            ),
            reason: '$code $key names its own Settings > Directories',
          );
        }
      });
    }
  });
}
