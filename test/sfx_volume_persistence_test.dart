import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/data/datasources/sqlite_service.dart';
import 'package:neostation/models/config_model.dart';

import 'database_test_helper.dart';

void main() {
  group('ConfigModel.sfxVolume serialization', () {
    test('a new install starts at the Medium stop (50%)', () {
      expect(const ConfigModel().sfxVolume, 0.5);
    });

    test('round-trips and clamps persisted values', () {
      expect(
        ConfigModel.fromJson(
          const ConfigModel(sfxVolume: 0.5).toJson(),
        ).sfxVolume,
        0.5,
      );
      expect(ConfigModel.fromJson({'sfx_volume': 4}).sfxVolume, 0.75);
      expect(ConfigModel.fromJson({'sfx_volume': -1}).sfxVolume, 0.0);
    });
  });

  group('sfx_volume persistence (SQLite)', () {
    final dbHelper = DatabaseTestHelper();

    setUp(() async => dbHelper.setUp());
    tearDown(() async => dbHelper.tearDown());

    test('persists a selected volume across save/load', () async {
      await SqliteService.saveUserConfig(sfxVolume: 0.45);

      final config = await SqliteService.getUserConfig();
      expect(config?['sfx_volume'], 0.45);
    });
  });
}
