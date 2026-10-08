import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/data/datasources/sqlite_config_service.dart';
import 'package:neostation/models/config_model.dart';
import 'database_test_helper.dart';

void main() {
  final helper = DatabaseTestHelper();
  setUp(helper.setUp);
  tearDown(helper.tearDown);

  test(
    'article sort preference defaults off and persists both states',
    () async {
      expect(
        (await SqliteConfigService.loadConfig()).ignoreArticlesInGameSort,
        false,
      );
      await SqliteConfigService.saveConfig(
        const ConfigModel(ignoreArticlesInGameSort: true),
      );
      expect(
        (await SqliteConfigService.loadConfig()).ignoreArticlesInGameSort,
        true,
      );
      await SqliteConfigService.saveConfig(
        const ConfigModel(ignoreArticlesInGameSort: false),
      );
      expect(
        (await SqliteConfigService.loadConfig()).ignoreArticlesInGameSort,
        false,
      );
    },
  );
}
