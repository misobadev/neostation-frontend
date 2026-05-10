import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/repositories/config_repository.dart';

import 'database_test_helper.dart';

void main() {
  final dbHelper = DatabaseTestHelper();

  setUp(() async {
    await dbHelper.setUp();
  });

  tearDown(() async {
    await dbHelper.tearDown();
  });

  group('ConfigRepository', () {
    test('getUserConfig returns null when no config exists', () async {
      final config = await ConfigRepository.getUserConfig();
      expect(config, isNull);
    });

    test(
      'getGameViewMode returns default "list" when no config exists',
      () async {
        final mode = await ConfigRepository.getGameViewMode();
        expect(mode, 'list');
      },
    );

    test('updateGameViewMode persists the mode', () async {
      await ConfigRepository.updateGameViewMode('grid');
      final mode = await ConfigRepository.getGameViewMode();
      expect(mode, 'grid');
    });

    test(
      'getPaletteName returns default "system" when no config exists',
      () async {
        final theme = await ConfigRepository.getPaletteName();
        expect(theme, 'system');
      },
    );

    test('updatePaletteName persists the palette', () async {
      await ConfigRepository.updatePaletteName('dark');
      final theme = await ConfigRepository.getPaletteName();
      expect(theme, 'dark');
    });

    test('getActiveTheme returns empty string when no config exists', () async {
      final theme = await ConfigRepository.getActiveTheme();
      expect(theme, '');
    });

    test('updateActiveTheme persists the active theme', () async {
      await ConfigRepository.updateActiveTheme('neostation-assets');
      final theme = await ConfigRepository.getActiveTheme();
      expect(theme, 'neostation-assets');
    });

    test('saveUserConfig persists lastScan', () async {
      await ConfigRepository.saveUserConfig(lastScan: '2024-01-01');
      final config = await ConfigRepository.getUserConfig();
      expect(config, isNotNull);
      expect(config!['last_scan'], '2024-01-01');
    });
  });
}
