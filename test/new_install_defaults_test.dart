import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/data/datasources/sqlite_config_service.dart';
import 'package:neostation/data/datasources/sqlite_service.dart';
import 'package:neostation/models/config_model.dart';

import 'database_test_helper.dart';

/// The defaults a brand-new install starts with. Existing installs keep their
/// stored values: each of these columns reached them through a migration with
/// its old DEFAULT, which the per-setting migration tests pin.
void main() {
  final dbHelper = DatabaseTestHelper();

  setUp(() async => dbHelper.setUp());
  tearDown(() async => dbHelper.tearDown());

  void expectNewInstallDefaults(ConfigModel config) {
    expect(config.sfxVolume, 0.5, reason: 'UI sounds start at Medium (50%)');
    expect(config.showAchievementsBadge, isTrue);
    expect(config.nowPlayingDimLevel, 25, reason: '25% darkness');
    expect(config.nowPlayingDimDelay, 5, reason: 'after 5 seconds');
    expect(config.androidAppsAsTab, isTrue);
  }

  test('the model defaults', () {
    expectNewInstallDefaults(const ConfigModel());
  });

  test('the first config row a fresh database creates', () async {
    await SqliteService.initializeUserData(await SqliteService.getDatabase());

    expectNewInstallDefaults(await SqliteConfigService.loadConfig());
  });
}
