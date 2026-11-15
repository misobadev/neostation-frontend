import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/models/game_model.dart';
import 'package:neostation/providers/neo_sync_provider.dart';
import 'package:neostation/repositories/neosync_save_folder_repository.dart';
import 'package:neostation/services/neosync/neo_sync_service.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import 'database_test_helper.dart';

// A game's NeoSync sync, before launch and after closing, lists the save
// folders to find its local saves. One subfolder it couldn't read failed the
// whole listing, so the game looked like it had no local saves, and the sync
// downloaded every cloud save for it over the local ones.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  SharedPreferences.setMockInitialValues({});

  final dbHelper = DatabaseTestHelper();
  late Directory folder;

  final game = GameModel(
    romname: 'Zelda.iso',
    realname: 'Zelda',
    name: 'Zelda',
    year: '2002',
    developer: '',
    publisher: '',
    genre: '',
    players: '',
    rating: 0,
    romPath: '/roms/gc/Zelda.iso',
    systemFolderName: 'gc',
    cloudSyncEnabled: true,
  );

  setUp(() async {
    final db = await dbHelper.setUp();
    await db.execute(
      "INSERT INTO app_systems (id, real_name, folder_name, neosync_json) "
      "VALUES ('gc', 'GameCube', 'gc', '{\"sync\": true}')",
    );
    await db.execute(
      "INSERT INTO user_detected_systems (app_system_id, actual_folder_name) "
      "VALUES ('gc', 'gc')",
    );
    folder = await Directory.systemTemp.createTemp('neosync_game_saves_');
    await NeoSyncSaveFolderRepository.saveFolder('gc', 'dolphin', folder.path);
  });

  tearDown(() async {
    if (!Platform.isWindows) {
      await Process.run('chmod', ['-R', 'u+rwx', folder.path]);
    }
    await folder.delete(recursive: true);
    await dbHelper.tearDown();
  });

  void write(String relative) {
    final file = File(p.join(folder.path, relative));
    file.parent.createSync(recursive: true);
    file.writeAsBytesSync(const [1, 2, 3, 4]);
  }

  test('a game\'s local save is found next to an unreadable folder', () async {
    write('Zelda.sav');
    write(p.join('other', 'Mario.sav'));
    final bad = Directory(p.join(folder.path, 'other'));
    await Process.run('chmod', ['000', bad.path]);
    try {
      bad.listSync();
      markTestSkipped('running with permission to read any folder');
      return;
    } on FileSystemException {
      // Unreadable, as intended.
    }

    final provider = NeoSyncProvider(NeoSyncService());
    final saves = await provider.locateGameSaveFiles(game);

    expect(saves.map((s) => s.fileName), ['Zelda.sav']);
  }, skip: Platform.isWindows);
}
