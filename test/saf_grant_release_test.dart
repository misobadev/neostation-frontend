import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/data/datasources/sqlite_service.dart';
import 'package:neostation/providers/sqlite_config_provider.dart';
import 'package:neostation/services/global_notification_service.dart';
import 'package:neostation/services/saf_grant_service.dart';
import 'package:neostation/services/user_data_location_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'database_test_helper.dart';

/// Removing an Android ROM folder never released the storage grant Android
/// gave for it (the release had no caller, and no native side either), so
/// every folder ever removed kept a grant towards Android's cap. A removed
/// folder's grant is now released, unless something still stored uses that
/// same folder.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const tree =
      'content://com.android.externalstorage.documents/tree/primary%3AROMs';
  const subTree =
      'content://com.android.externalstorage.documents/tree/primary%3AROMs%2Fnds';

  group('the folder a grant covers', () {
    test('ignores how the folder is spelt', () {
      final key = safTreeKey(tree);
      expect(key, isNotNull);
      expect(
        safTreeKey(
          'content://com.android.externalstorage.documents/tree/primary:ROMs',
        ),
        key,
      );
      expect(safTreeKey('$tree/'), key);
      expect(
        safTreeKey(
          'content://com.android.externalstorage.documents/tree/primary%3aROMs',
        ),
        key,
      );
    });

    test('tells a folder from the folders inside it', () {
      expect(safTreeKey(subTree), isNot(safTreeKey(tree)));
    });

    test('tells volumes and providers apart', () {
      expect(
        safTreeKey(
          'content://com.android.externalstorage.documents/tree/1234-5678%3AROMs',
        ),
        isNot(safTreeKey(tree)),
      );
      expect(
        safTreeKey('content://com.example.documents/tree/primary%3AROMs'),
        isNot(safTreeKey(tree)),
      );
    });

    test('is none for a plain path or a single document', () {
      expect(safTreeKey('/home/user/roms'), isNull);
      expect(safTreeKey('/tree/primary%3AROMs'), isNull);
      expect(safTreeKey('file:///tree/primary%3AROMs'), isNull);
      expect(safTreeKey('https://example.com/tree/primary%3AROMs'), isNull);
      expect(safTreeKey('content:///tree/primary%3AROMs'), isNull);
      // An escape that isn't valid UTF-8 can't be decoded.
      expect(
        safTreeKey(
          'content://com.android.externalstorage.documents/tree/primary%3A%C3',
        ),
        isNull,
      );
      expect(safTreeKey(r'C:\roms'), isNull);
      expect(
        safTreeKey(
          'content://com.android.externalstorage.documents/document/primary%3AROMs',
        ),
        isNull,
      );
    });
  });

  group('removing a ROM folder', () {
    final helper = DatabaseTestHelper();
    late DatabaseAdapter db;
    late List<String> released;

    setUp(() async {
      db = await helper.setUp();
      GlobalNotificationService().dismiss();
      released = [];
      SafGrantService.debugUseReleaser((uri) async {
        released.add(uri);
        return true;
      });
    });

    tearDown(() async {
      SafGrantService.debugUseReleaser(null);
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

    Future<SqliteConfigProvider> withFolders(List<String> folders) async {
      final provider = SqliteConfigProvider();
      for (final folder in folders) {
        await provider.addRomFolder(folder, scan: false);
      }
      return provider;
    }

    test('releases its grant', () async {
      final provider = await withFolders([tree]);
      await db.rawInsert(
        'INSERT INTO user_roms (app_system_id, filename, rom_path) '
        'VALUES (?, ?, ?)',
        ['nes', 'Game.nes', '$tree/document/primary%3AROMs%2Fnes%2FGame.nes'],
      );

      await provider.removeRomFolder(tree);

      expect(released, [tree]);
    });

    test('keeps a folder inside it working: its grant is its own', () async {
      final provider = await withFolders([tree, subTree]);

      await provider.removeRomFolder(tree);

      expect(released, [tree]);
      expect(provider.config.romFolders, [subTree]);
    });

    test(
      'releases a folder inside another without touching the other',
      () async {
        final provider = await withFolders([tree, subTree]);

        await provider.removeRomFolder(subTree);

        expect(released, [subTree]);
      },
    );

    test(
      'keeps the grant while another ROM folder is the same folder',
      () async {
        const sameFolder =
            'content://com.android.externalstorage.documents/tree/primary:ROMs';
        final provider = await withFolders([tree, sameFolder]);

        await provider.removeRomFolder(tree);

        expect(released, isEmpty);
      },
    );

    test('keeps the grant while the ES-DE folder is in it', () async {
      final provider = await withFolders([tree]);
      await provider.updateEsdeFolderPath('/storage/emulated/0/ROMs/ES-DE');

      await provider.removeRomFolder(tree);

      expect(released, isEmpty);
    });

    test('keeps the grant while the ES-DE folder is that folder', () async {
      final provider = await withFolders([tree]);
      await provider.updateEsdeFolderPath('/storage/emulated/0/ROMs/');

      await provider.removeRomFolder(tree);

      expect(released, isEmpty);
    });

    test('keeps the grant while the user data is in it', () async {
      SharedPreferences.setMockInitialValues({
        UserDataLocationService.customPathKey:
            '/storage/emulated/0/ROMs/user-data',
      });
      final provider = await withFolders([tree]);

      await provider.removeRomFolder(tree);

      expect(released, isEmpty);
    });

    test('keeps the grant while a NeoSync save folder is in it', () async {
      final provider = await withFolders([tree]);
      await db.rawInsert(
        'INSERT INTO user_custom_save_folders '
        '(system_folder_name, emulator_slug, folder_path) VALUES (?, ?, ?)',
        ['ps2', 'aethersx2', '/storage/emulated/0/ROMs/saves/ps2'],
      );

      await provider.removeRomFolder(tree);

      expect(released, isEmpty);
    });

    test('a folder next to it with a longer name does not keep it', () async {
      final provider = await withFolders([tree]);
      await provider.updateEsdeFolderPath('/storage/emulated/0/ROMs-ES-DE');

      await provider.removeRomFolder(tree);

      expect(released, [tree]);
    });

    test('releases nothing for a plain folder', () async {
      final root = await romRoot();
      final provider = await withFolders([root.path]);

      await provider.removeRomFolder(root.path);

      expect(released, isEmpty);
    });

    test('keeps the grant when it cannot tell what uses the folder', () async {
      final provider = await withFolders([tree]);
      await db.execute('DROP TABLE user_custom_save_folders');

      await provider.removeRomFolder(tree);

      expect(released, isEmpty);
      expect(provider.config.romFolders, isEmpty);
    });

    test('a folder whose address cannot be read is removed as usual', () async {
      const malformed =
          'content://com.android.externalstorage.documents/tree/primary%3A%C3';
      final provider = await withFolders([malformed]);

      await provider.removeRomFolder(malformed);

      expect(released, isEmpty);
      expect(provider.config.romFolders, isEmpty);
    });

    test('a failed release still removes the folder', () async {
      SafGrantService.debugUseReleaser((uri) async {
        released.add(uri);
        throw Exception('release failed');
      });
      final provider = await withFolders([tree]);

      await provider.removeRomFolder(tree);

      expect(released, [tree]);
      expect(provider.config.romFolders, isEmpty);
    });

    test('a removal that could not be stored keeps the grant', () async {
      final provider = await withFolders([tree]);
      await db.execute(
        'CREATE TRIGGER fail_folder_delete BEFORE DELETE ON user_rom_folders '
        "BEGIN SELECT RAISE(ABORT, 'disk full'); END",
      );

      await expectLater(provider.removeRomFolder(tree), throwsA(anything));

      expect(released, isEmpty);
      expect(provider.config.romFolders, [tree]);
    });
  });
}
