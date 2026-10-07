import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/data/datasources/sqlite_service.dart';
import 'package:neostation/repositories/game_repository.dart';

import 'database_test_helper.dart';

/// Removing a ROM folder deletes the games stored under it. The folder was
/// matched with `LIKE '<folder>/%'`, so `_` and `%` in the path acted as
/// wildcards and the match ignored case: removing one folder also deleted the
/// games of folders that only looked alike.
void main() {
  final helper = DatabaseTestHelper();
  late DatabaseAdapter db;

  setUp(() async {
    db = await helper.setUp();
  });

  tearDown(() async {
    await helper.tearDown();
  });

  Future<void> storeRoms(List<String> paths) async {
    for (final p in paths) {
      await db.rawInsert(
        'INSERT INTO user_roms (app_system_id, filename, rom_path) '
        'VALUES (?, ?, ?)',
        ['nes', p.split(RegExp(r'[/\\]')).last, p],
      );
    }
  }

  Future<List<String>> remaining() async => (await db.rawQuery(
    'SELECT rom_path FROM user_roms ORDER BY rom_path',
  )).map((r) => r['rom_path'] as String).toList();

  test('an underscore in the folder name is not a wildcard', () async {
    await storeRoms(['/roms/my_games/nes/A.nes', '/roms/myXgames/nes/B.nes']);

    await GameRepository.deleteRomsByFolderPath('/roms/my_games');

    expect(await remaining(), ['/roms/myXgames/nes/B.nes']);
  });

  test('a folder differing only in case is left alone', () async {
    await storeRoms(['/roms/my_games/nes/A.nes', '/ROMS/MY_GAMES/nes/B.nes']);

    await GameRepository.deleteRomsByFolderPath('/roms/my_games');

    expect(await remaining(), ['/ROMS/MY_GAMES/nes/B.nes']);
  });

  test('the % escapes of an Android tree URI are not wildcards', () async {
    const tree =
        'content://com.android.externalstorage.documents/tree/primary%3Aemu';
    const other =
        'content://com.android.externalstorage.documents/tree/primaryX3Aemu';
    await storeRoms([
      '$tree/document/primary%3Aemu%2Fnes%2FA.nes',
      '$other/document/primaryX3Aemu%2Fnes%2FB.nes',
    ]);

    await GameRepository.deleteRomsByFolderPath(tree);

    expect(await remaining(), ['$other/document/primaryX3Aemu%2Fnes%2FB.nes']);
  });

  test('a folder name with an emoji still removes its own games', () async {
    await storeRoms(['/roms/Games 🎮/nes/A.nes', '/roms/Games 🎮x/nes/B.nes']);

    final deleted = await GameRepository.deleteRomsByFolderPath(
      '/roms/Games 🎮',
    );

    expect(deleted, 1);
    expect(await remaining(), ['/roms/Games 🎮x/nes/B.nes']);
  });

  test('removes its own games with either separator', () async {
    await storeRoms([
      '/roms/snes/game.smc',
      '/roms/snes/sub/other.smc',
      r'C:\roms\snes\win.smc',
      '/roms/snes2/keep.smc',
    ]);

    expect(await GameRepository.deleteRomsByFolderPath('/roms/snes/'), 2);
    expect(await GameRepository.deleteRomsByFolderPath(r'C:\roms\snes'), 1);
    expect(await remaining(), ['/roms/snes2/keep.smc']);
  });

  // A ROM folder at the filesystem root strips down to nothing; it used to
  // match no game at all, so removing it left every game behind with no folder.
  test('a root folder removes the games under it', () async {
    const saf =
        'content://com.android.externalstorage.documents/tree/primary%3Aemu/'
        'document/primary%3Aemu%2Fnes%2FC.nes';
    await storeRoms(['/roms/nes/A.nes', '/home/me/B.nes', saf]);

    expect(await GameRepository.deleteRomsByFolderPath('/'), 2);
    expect(await remaining(), [saf]);
  });

  test('an empty folder path removes nothing', () async {
    await storeRoms(['/roms/nes/A.nes']);

    expect(await GameRepository.deleteRomsByFolderPath(''), 0);
    expect(await remaining(), ['/roms/nes/A.nes']);
  });

  test('a folder name with an emoji is found to hold games', () async {
    await storeRoms(['/roms/Games 🎮/nes/A.nes']);

    expect(await GameRepository.hasRomsUnderFolder('/roms/Games 🎮'), isTrue);
    expect(await GameRepository.hasRomsUnderFolder('/roms/Games'), isFalse);
  });
}
