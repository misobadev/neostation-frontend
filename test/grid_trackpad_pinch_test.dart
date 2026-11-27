import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/l10n/app_locale.dart';
import 'package:neostation/models/my_systems.dart';
import 'package:neostation/providers/collections_provider.dart';
import 'package:neostation/providers/neo_assets_provider.dart';
import 'package:neostation/providers/sqlite_config_provider.dart';
import 'package:neostation/screens/systems_screen/my_systems_section/my_systems_grid.dart';
import 'package:neostation/services/sfx_service.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'gamepad_test_clock.dart';
import 'support/plugin_channel_mocks.dart';

/// A trackpad pinch (macOS, Windows precision touchpads) arrives as a
/// pan-zoom gesture, not as two pointers. The systems grid, and with it the
/// collections, Discovery and Android apps grids that reuse it, resizes its
/// cards on it as it does on a two-finger touch pinch.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    SfxService().setEnabled(false);
    installDefaultPluginMocks();
    await FlutterLocalization.instance.ensureInitialized();
    FlutterLocalization.instance.init(
      mapLocales: [MapLocale('en', AppLocale.en)],
      initLanguageCode: 'en',
    );
  });
  setUp(resetGamepadClock);
  tearDown(restoreGamepadClock);

  SystemInfo system(String name) =>
      SystemInfo(title: name, shortName: name, folderName: name, numOfRoms: 3);

  Future<List<String>> pinch(WidgetTester tester, double scale) async {
    final changes = <String>[];
    await tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(size: Size(1920, 1080)),
        child: ScreenUtilInit(
          designSize: const Size(1920, 1080),
          builder: (context, _) => MultiProvider(
            providers: [
              ChangeNotifierProvider(create: (_) => SqliteConfigProvider()),
              ChangeNotifierProvider(create: (_) => NeoAssetsProvider()),
              ChangeNotifierProvider(create: (_) => CollectionsProvider()),
            ],
            child: MaterialApp(
              home: Scaffold(
                body: SystemCardGridView(
                  crossAxisCount: 6,
                  systems: [system('snes'), system('nes'), system('md')],
                  pinchSize: 'M',
                  onPinchSizeChanged: changes.add,
                  cardOverrideBuilder: (_, _, info, _, onTap) =>
                      ColoredBox(color: Colors.grey, child: Text(info.title!)),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    // Below the cards: with three of them they fill one row, and the rest
    // of the grid's space must take the gesture too.
    final grid = tester.getRect(find.byType(SystemCardGridView));
    final center = Offset(grid.center.dx, grid.bottom - 20);
    final trackpad = TestPointer(1, PointerDeviceKind.trackpad);
    await tester.sendEventToBinding(trackpad.panZoomStart(center));
    await tester.sendEventToBinding(
      trackpad.panZoomUpdate(center, scale: scale),
    );
    await tester.sendEventToBinding(trackpad.panZoomEnd());
    await tester.pump(const Duration(seconds: 2));
    return changes;
  }

  testWidgets('pinching out on a trackpad makes the cards bigger', (
    tester,
  ) async {
    expect(await pinch(tester, 1.3), ['L']);
  });

  testWidgets('pinching in on a trackpad makes the cards smaller', (
    tester,
  ) async {
    expect(await pinch(tester, 0.8), ['S']);
  });

  testWidgets('a slight trackpad pinch leaves the size alone', (tester) async {
    expect(await pinch(tester, 1.05), isEmpty);
  });
}
