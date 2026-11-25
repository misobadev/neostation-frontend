import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/repositories/game_repository.dart';

import 'database_test_helper.dart';

/// A pinned shortcut is an `android` row flagged as a game whose `rom_path` is
/// a shortcut id rather than a package name. It has to list under Android Games
/// only, survive the Android rescan, and stay removable without touching the
/// installed app rows beside it.
void main() {
  const shortcutPath = 'shortcut-0123456789abcdef';
  const chromePath = 'com.android.chrome';

  final dbHelper = DatabaseTestHelper();
  late dynamic db;

  String intentJson([String game = '1']) => jsonEncode({
    'package': 'com.droiddeck.launcher',
    'shortcut': 'game:$game',
    'component': 'com.droiddeck.launcher/.FrontEndActivity',
    'data': 'droiddeck://game/$game',
  });

  setUp(() async {
    db = await dbHelper.setUp();
    await db.execute(
      "INSERT INTO app_systems (id, real_name, folder_name) VALUES ('android', 'Android', 'android')",
    );
    await db.execute(
      "INSERT INTO app_systems (id, real_name, folder_name, short_name) VALUES ('android_games', 'Android Games', 'android_games', 'Android Games')",
    );
    await db.execute(
      "INSERT INTO user_roms (filename, rom_path, app_system_id, title_name) "
      "VALUES ('$chromePath', '$chromePath', 'android', 'Chrome')",
    );
    await GameRepository.setAndroidGame(chromePath, true);
  });

  tearDown(() async => dbHelper.tearDown());

  test(
    'files the shortcut under Android Games and not the Android tab',
    () async {
      await GameRepository.saveAndroidShortcut(
        romPath: shortcutPath,
        label: 'Half-Life 2',
        intentJson: intentJson(),
      );

      expect(
        (await GameRepository.getGamesBySystem('android_games'))
            .map((game) => game.romPath),
        contains(shortcutPath),
      );
      expect(
        (await GameRepository.getGamesBySystem('android'))
            .map((game) => game.romPath),
        isNot(contains(shortcutPath)),
      );
    },
  );

  test('stores the intent so the launch path can replay it', () async {
    await GameRepository.saveAndroidShortcut(
      romPath: shortcutPath,
      label: 'Half-Life 2',
      intentJson: intentJson(),
    );

    expect(
      await GameRepository.getShortcutIntent(shortcutPath),
      contains('droiddeck://game/1'),
    );
  });

  test('an installed app row carries no shortcut intent', () async {
    expect(await GameRepository.getShortcutIntent(chromePath), isNull);
  });

  test('keeps shortcuts out of the package list the rescan diffs', () async {
    await GameRepository.saveAndroidShortcut(
      romPath: shortcutPath,
      label: 'Half-Life 2',
      intentJson: intentJson(),
    );

    // The Android rescan compares installed packages against this list, so a
    // shortcut leaking into it would be treated as an uninstalled app.
    expect(await GameRepository.getAndroidGamePackages(), [chromePath]);
  });

  test('re-pinning refreshes the label and keeps the user state', () async {
    await GameRepository.saveAndroidShortcut(
      romPath: shortcutPath,
      label: 'Half-Life 2',
      intentJson: intentJson(),
    );
    await GameRepository.toggleRomFavoriteByPath(shortcutPath);

    await GameRepository.saveAndroidShortcut(
      romPath: shortcutPath,
      label: 'Half-Life 2 (renamed)',
      intentJson: intentJson(),
    );

    final game = await GameRepository.getSingleGame(
      'android_games',
      shortcutPath,
    );
    expect(game!.realName, 'Half-Life 2 (renamed)');
    final favourite = await db.query(
      'user_roms',
      columns: ['is_favorite'],
      where: 'rom_path = ?',
      whereArgs: [shortcutPath],
    );
    expect(favourite.first['is_favorite'], 1);
    expect((await GameRepository.getGamesBySystem('android_games')).length, 2);
  });

  test('removing a shortcut leaves the app rows alone', () async {
    await GameRepository.saveAndroidShortcut(
      romPath: shortcutPath,
      label: 'Half-Life 2',
      intentJson: intentJson(),
    );

    await GameRepository.deleteAndroidShortcut(shortcutPath);

    expect(await GameRepository.getShortcutIntent(shortcutPath), isNull);
    expect(await GameRepository.getShortcutIntent(chromePath), isNull);
    expect(
      (await GameRepository.getGamesBySystem('android_games'))
          .map((game) => game.romPath),
      [chromePath],
    );
  });

  test('deleting an app row does not delete a shortcut', () async {
    await GameRepository.saveAndroidShortcut(
      romPath: shortcutPath,
      label: 'Half-Life 2',
      intentJson: intentJson(),
    );

    await GameRepository.deleteAndroidShortcut(chromePath);

    expect(await GameRepository.getShortcutIntent(shortcutPath), isNotNull);
    expect(await GameRepository.getShortcutIntent(chromePath), isNull);
  });
}
