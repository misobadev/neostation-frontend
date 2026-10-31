import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/data/datasources/sqlite_config_service.dart';
import 'package:neostation/data/datasources/sqlite_service.dart';
import 'package:neostation/models/config_model.dart';

import 'database_test_helper.dart';

/// Glass border used to allow 0–4. It is now a 0–2 setting, so both JSON and
/// existing database rows have to read a larger stored value as the new
/// maximum rather than showing a setting the UI can no longer represent.
void main() {
  final dbHelper = DatabaseTestHelper();

  setUp(() async => dbHelper.setUp());
  tearDown(() async => dbHelper.tearDown());

  group('glass border width limit', () {
    test('clamps values above 2 in both JSON key forms', () {
      expect(
        ConfigModel.fromJson(const {
          'neoglassBorderWidth': 4,
        }).neoglassBorderWidth,
        2,
      );
      expect(
        ConfigModel.fromJson(const {
          'neoglass_border_width': 4,
        }).neoglassBorderWidth,
        2,
      );
      expect(
        ConfigModel.fromJson(const {
          'neoglassBorderWidth': 1,
        }).neoglassBorderWidth,
        1,
      );
    });

    test('an existing database row above 2 loads as 2', () async {
      await SqliteService.saveUserConfig(neoglassBorderWidth: 4);

      final loaded = await SqliteConfigService.loadConfig();

      expect(loaded.neoglassBorderWidth, 2);
    });

    test('the model default is the new maximum', () {
      expect(const ConfigModel().neoglassBorderWidth, 2);
    });
  });
}
