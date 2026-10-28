import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/data/datasources/sqlite_config_service.dart';
import 'package:neostation/models/config_model.dart';
import 'database_test_helper.dart';

void main() {
  final helper = DatabaseTestHelper();
  setUp(helper.setUp);
  tearDown(helper.tearDown);

  test(
    'preview delay defaults to two seconds and persists every state',
    () async {
      expect((await SqliteConfigService.loadConfig()).videoPreviewDelay, 2);
      for (final seconds in [-1, 0, 1, 2, 3, 4, 5]) {
        await SqliteConfigService.saveConfig(
          ConfigModel(videoPreviewDelay: seconds),
        );
        expect(
          (await SqliteConfigService.loadConfig()).videoPreviewDelay,
          seconds,
        );
      }
    },
  );

  test('JSON defaults to two seconds and understands the old flag', () {
    expect(ConfigModel.fromJson(const {}).videoPreviewDelay, 2);
    expect(
      ConfigModel.fromJson(const {'video_preview_delay': 0}).videoPreviewDelay,
      0,
    );
    expect(
      ConfigModel.fromJson(const {'video_previews': 0}).videoPreviewDelay,
      -1,
    );
    expect(
      ConfigModel.fromJson(const {'video_previews': 1}).videoPreviewDelay,
      2,
    );
  });
}
