import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:neostation/data/datasources/sqlite_config_service.dart';
import 'package:neostation/models/config_model.dart';
import 'package:neostation/models/secondary_display_state.dart';
import 'package:neostation/screens/secondary_screen/widgets/app_dock.dart';

import 'database_test_helper.dart';

/// Zero slots shows only the all-apps button. The count is clamped wherever it
/// is read, so a saved zero has to load back as zero, not one.
void main() {
  final dbHelper = DatabaseTestHelper();

  setUp(() async => dbHelper.setUp());
  tearDown(() async => dbHelper.tearDown());

  group('dock slot count setting', () {
    test('a fresh config still shows three slots', () {
      expect(const ConfigModel().dockSlotCount, 3);
    });

    test('zero slots survives a save and reload', () async {
      await SqliteConfigService.saveConfig(const ConfigModel(dockSlotCount: 0));

      final loaded = await SqliteConfigService.loadConfig();

      expect(loaded.dockSlotCount, 0);
    });

    test('zero slots round-trips through JSON in both key forms', () {
      expect(ConfigModel.fromJson({'dockSlotCount': 0}).dockSlotCount, 0);
      expect(ConfigModel.fromJson({'dock_slot_count': 0}).dockSlotCount, 0);
    });

    test('a negative count still clamps to zero', () {
      expect(ConfigModel.fromJson({'dockSlotCount': -1}).dockSlotCount, 0);
    });
  });

  group('AppDock', () {
    Future<void> pumpDock(WidgetTester tester, int slotCount) {
      return tester.pumpWidget(
        ScreenUtilInit(
          designSize: const Size(1920, 1080),
          builder: (context, _) => MaterialApp(
            home: Scaffold(
              body: AppDock(
                value: SecondaryDisplayStateData(
                  systemName: 'WELCOME',
                  dockSlotCount: slotCount,
                ),
                onLaunchApp: (_) {},
                onPickSlot: (_) {},
                onClearSlot: (_) {},
                onOpenAccessibilitySettings: () {},
              ),
            ),
          ),
        ),
      );
    }

    testWidgets('shows one empty slot per visible count', (tester) async {
      await pumpDock(tester, 3);

      expect(find.byIcon(Symbols.add_rounded), findsNWidgets(3));
    });

    testWidgets('shows no slots when the count is zero', (tester) async {
      await pumpDock(tester, 0);

      expect(find.byIcon(Symbols.add_rounded), findsNothing);
    });
  });
}
