import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/constants/system_folder_names.dart';
import 'package:neostation/models/game_model.dart';
import 'package:neostation/models/system_model.dart';
import 'package:neostation/services/game_service.dart';

import 'database_test_helper.dart';

void main() {
  final dbHelper = DatabaseTestHelper();
  late dynamic db;

  setUp(() async {
    db = await dbHelper.setUp();
    await db.execute(
      "INSERT INTO app_systems (id, real_name, folder_name) VALUES ('android', 'Android', 'android')",
    );
  });

  tearDown(() async {
    await dbHelper.tearDown();
  });

  group('GameService.toggleFavorite', () {
    test('toggles favorite by romPath', () async {
      await db.execute(
        "INSERT INTO user_roms (filename, rom_path, app_system_id, is_favorite) VALUES ('com.example.app', 'com.example.app', 'android', 0)",
      );

      final app = GameModel(
        romname: 'com.example.app',
        realname: 'Example App',
        name: 'Example App',
        year: '',
        rating: 0,
        genre: '',
        developer: '',
        publisher: '',
        players: '',
        systemId: 'android',
        systemFolderName: 'android',
        systemRealName: 'Android',
        romPath: 'com.example.app',
      );

      await GameService.toggleFavorite(app);

      final result = await db.rawQuery(
        "SELECT is_favorite FROM user_roms WHERE rom_path = 'com.example.app'",
      );
      expect(result.single['is_favorite'], 1);

      await GameService.toggleFavorite(app);

      final result2 = await db.rawQuery(
        "SELECT is_favorite FROM user_roms WHERE rom_path = 'com.example.app'",
      );
      expect(result2.single['is_favorite'], 0);
    });

    test('is a no-op when romPath is null', () async {
      final app = GameModel(
        romname: 'missing-path-app',
        realname: 'Missing Path App',
        name: 'Missing Path App',
        year: '',
        rating: 0,
        genre: '',
        developer: '',
        publisher: '',
        players: '',
        systemId: 'android',
        systemFolderName: 'android',
        systemRealName: 'Android',
      );

      await GameService.toggleFavorite(app);

      final result = await db.rawQuery(
        "SELECT COUNT(*) as c FROM user_roms WHERE filename = 'missing-path-app'",
      );
      expect(result.single['c'], 0);
    });
  });

  group('GameService.loadGamesForSystem (favorites)', () {
    test('loads only favorite ROM-library games for favorites virtual system', () async {
      await db.execute(
        "INSERT INTO app_systems (id, real_name, folder_name) VALUES ('snes', 'Super Nintendo', 'snes')",
      );
      await db.execute(
        "INSERT INTO app_systems (id, real_name, folder_name) VALUES ('music', 'Music', 'music')",
      );
      await db.execute(
        "INSERT INTO app_systems (id, real_name, folder_name) VALUES ('all', 'All', 'all')",
      );
      await db.execute(
        "INSERT INTO user_system_settings (app_system_id) VALUES ('snes')",
      );

      await db.execute(
        "INSERT INTO user_roms (filename, rom_path, app_system_id, is_favorite) VALUES ('fav-a.smc', '/roms/snes/fav-a.smc', 'snes', 1)",
      );
      await db.execute(
        "INSERT INTO user_roms (filename, rom_path, app_system_id, is_favorite) VALUES ('fav-b.smc', '/roms/snes/fav-b.smc', 'snes', 1)",
      );
      await db.execute(
        "INSERT INTO user_roms (filename, rom_path, app_system_id, is_favorite) VALUES ('not-fav.smc', '/roms/snes/not-fav.smc', 'snes', 0)",
      );
      await db.execute(
        "INSERT INTO user_roms (filename, rom_path, app_system_id, is_favorite) VALUES ('fav-music.mp3', '/roms/music/fav-music.mp3', 'music', 1)",
      );
      await db.execute(
        "INSERT INTO user_roms (filename, rom_path, app_system_id, is_favorite) VALUES ('fav-android.apk', 'com.example.app', 'android', 1)",
      );

      final favoritesSystem = SystemModel(
        id: SystemFolderNames.favorites,
        folderName: SystemFolderNames.favorites,
        realName: 'Favorites',
        iconImage: 'assets/images/icons/heart-bulk.png',
        color: '#ff006a',
        isVirtual: true,
      );

      final games = await GameService.loadGamesForSystem(favoritesSystem);
      final names = games.map((g) => g.romname).toSet();

      expect(names, contains('fav-a.smc'));
      expect(names, contains('fav-b.smc'));
      expect(names, isNot(contains('not-fav.smc')));
      expect(names, isNot(contains('fav-music.mp3')));
      expect(names, isNot(contains('fav-android.apk')));
    });
  });
}
