import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/data/datasources/sqlite_config_service.dart';
import 'package:neostation/models/config_model.dart';
import 'database_test_helper.dart';

void main() {
  final helper = DatabaseTestHelper();
  setUp(helper.setUp);
  tearDown(helper.tearDown);

  test('video previews default off and persist both states', () async {
    expect((await SqliteConfigService.loadConfig()).videoPreviews, false);
    await SqliteConfigService.saveConfig(
      const ConfigModel(videoPreviews: true),
    );
    expect((await SqliteConfigService.loadConfig()).videoPreviews, true);
    await SqliteConfigService.saveConfig(
      const ConfigModel(videoPreviews: false),
    );
    expect((await SqliteConfigService.loadConfig()).videoPreviews, false);
  });

  test('a config without the key reads as off', () {
    expect(ConfigModel.fromJson(const {}).videoPreviews, false);
    expect(
      ConfigModel.fromJson(const {'video_previews': 1}).videoPreviews,
      true,
    );
  });
}
