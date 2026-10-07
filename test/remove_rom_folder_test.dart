import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/data/datasources/sqlite_service.dart';
import 'package:neostation/providers/sqlite_config_provider.dart';
import 'package:neostation/repositories/config_repository.dart';
import 'package:neostation/services/global_notification_service.dart';

import 'database_test_helper.dart';

/// Removing a ROM folder saved the config with the remaining folders, and
/// `saveUserRomFolders` deliberately ignores an empty list so a blanket config
/// save can't wipe them. Removing the *last* folder therefore left it in the
/// folder table while its games were already deleted: Settings still listed it,
/// the library was empty, and the next launch scanned it back in.
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

  test('removing the only ROM folder removes it for good', () async {
    final root = await romRoot();
    final provider = SqliteConfigProvider();
    await provider.addRomFolder(root.path, scan: false);
    await storeRom('${root.path}/nes/Game.nes');

    await provider.removeRomFolder(root.path);

    expect(provider.config.romFolders, isEmpty);
    expect(await storedRomPaths(), isEmpty);
    expect(
      await ConfigRepository.getUserRomFolders(),
      isEmpty,
      reason: 'the next launch loads the folder list from this table',
    );
  });

  test('removing one of two folders keeps the other and its games', () async {
    final first = await romRoot();
    final second = await romRoot();
    final provider = SqliteConfigProvider();
    await provider.addRomFolder(first.path, scan: false);
    await provider.addRomFolder(second.path, scan: false);
    await storeRom('${first.path}/nes/A.nes');
    await storeRom('${second.path}/nes/B.nes');

    await provider.removeRomFolder(first.path);

    expect(provider.config.romFolders, [second.path]);
    expect(await ConfigRepository.getUserRomFolders(), [second.path]);
    expect(await storedRomPaths(), ['${second.path}/nes/B.nes']);
  });

  test('a config save with no folders still keeps them', () async {
    await SqliteService.addRomFolder('/roms');

    await SqliteService.saveUserRomFolders([]);

    expect(await ConfigRepository.getUserRomFolders(), ['/roms']);
  });

  test('the targeted removal deletes exactly the named folder', () async {
    await SqliteService.addRomFolder('/roms/a');
    await SqliteService.addRomFolder('/roms/b');

    await SqliteService.removeRomFolder('/roms/a');
    expect(await ConfigRepository.getUserRomFolders(), ['/roms/b']);

    await SqliteService.removeRomFolder('/roms/b');
    expect(await ConfigRepository.getUserRomFolders(), isEmpty);
  });
}
