import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/models/system_model.dart';
import 'package:neostation/repositories/game_repository.dart';
import 'package:neostation/services/game/game_list_service.dart';

import 'database_test_helper.dart';

/// Hiding an app from the Android apps grid uses the same per-game flag as
/// hiding a game: the app leaves the grid and is listed in the Android
/// system's Hidden tab, which is where it is restored.
void main() {
  final dbHelper = DatabaseTestHelper();
  late dynamic db;

  final android = SystemModel(
    id: 'android',
    folderName: 'android',
    realName: 'Android',
    iconImage: 'assets/images/icons/heart-bulk.png',
    color: '#3ddc84',
  );

  setUp(() async {
    db = await dbHelper.setUp();
    await db.execute(
      "INSERT INTO app_systems (id, real_name, folder_name) VALUES ('android', 'Android', 'android')",
    );
    for (final (package, name) in [
      ('com.android.calendar', 'Calendar'),
      ('com.retroarch.aarch64', 'RetroArch'),
      ('org.ppsspp.ppsspp', 'PPSSPP'),
    ]) {
      await db.execute(
        'INSERT INTO user_roms (filename, rom_path, app_system_id, title_name) '
        "VALUES ('$package', '$package', 'android', '$name')",
      );
    }
  });

  tearDown(() async {
    await dbHelper.tearDown();
  });

  Future<List<String>> visiblePackages() async =>
      (await GameListService.loadGamesForSystem(
        android,
      )).map((app) => app.romname).toList();

  test('a hidden app leaves the apps grid and is listed as hidden', () async {
    await GameRepository.setGameHidden('android', 'com.android.calendar', true);

    expect(
      await visiblePackages(),
      unorderedEquals(['com.retroarch.aarch64', 'org.ppsspp.ppsspp']),
    );

    final hidden = await GameRepository.getHiddenGames(systemId: 'android');
    expect(hidden.map((app) => app.filename), ['com.android.calendar']);
    expect(hidden.single.realName, 'Calendar');
  });

  test('unhiding an app puts it back in the grid', () async {
    await GameRepository.setGameHidden('android', 'com.android.calendar', true);
    await GameRepository.setGameHidden(
      'android',
      'com.android.calendar',
      false,
    );

    expect(await visiblePackages(), contains('com.android.calendar'));
    expect(await GameRepository.getHiddenGames(systemId: 'android'), isEmpty);
  });
}
