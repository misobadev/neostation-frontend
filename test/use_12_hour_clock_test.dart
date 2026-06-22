import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/models/config_model.dart';
import 'package:neostation/data/datasources/sqlite_service.dart';

import 'database_test_helper.dart';

void main() {
  group('ConfigModel.use12HourClock serialization', () {
    test('defaults to false (24-hour)', () {
      expect(const ConfigModel().use12HourClock, isFalse);
    });

    test('copyWith updates the flag', () {
      const base = ConfigModel();
      expect(base.copyWith(use12HourClock: true).use12HourClock, isTrue);
      // Omitting the field preserves the previous value.
      final enabled = base.copyWith(use12HourClock: true);
      expect(enabled.copyWith().use12HourClock, isTrue);
    });

    test('round-trips through toJson/fromJson', () {
      const enabled = ConfigModel(use12HourClock: true);
      final restored = ConfigModel.fromJson(enabled.toJson());
      expect(restored.use12HourClock, isTrue);
    });

    test('fromJson parses bool, legacy int, and snake_case keys', () {
      expect(
        ConfigModel.fromJson({'use12HourClock': true}).use12HourClock,
        isTrue,
      );
      expect(
        ConfigModel.fromJson({'use_12_hour_clock': 1}).use12HourClock,
        isTrue,
      );
      expect(
        ConfigModel.fromJson({'use_12_hour_clock': 0}).use12HourClock,
        isFalse,
      );
      // Absent key falls back to the 24-hour default.
      expect(ConfigModel.fromJson({}).use12HourClock, isFalse);
    });
  });

  group('use_12_hour_clock persistence (SQLite)', () {
    final dbHelper = DatabaseTestHelper();

    setUp(() async => dbHelper.setUp());
    tearDown(() async => dbHelper.tearDown());

    test('defaults to 0 when never set', () async {
      await SqliteService.saveUserConfig(appLanguage: 'en');
      final config = await SqliteService.getUserConfig();
      final value =
          int.tryParse(config?['use_12_hour_clock']?.toString() ?? '0') ?? 0;
      expect(value, 0);
    });

    test('persists an enabled value across save/load', () async {
      await SqliteService.saveUserConfig(use12HourClock: 1);
      final config = await SqliteService.getUserConfig();
      expect(config?['use_12_hour_clock'].toString(), '1');
    });

    test('can be toggled back off', () async {
      await SqliteService.saveUserConfig(use12HourClock: 1);
      await SqliteService.saveUserConfig(use12HourClock: 0);
      final config = await SqliteService.getUserConfig();
      expect(config?['use_12_hour_clock'].toString(), '0');
    });
  });
}
