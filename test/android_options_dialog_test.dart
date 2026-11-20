import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/l10n/app_locale.dart';
import 'package:neostation/models/game_model.dart';
import 'package:neostation/models/system_model.dart';
import 'package:neostation/providers/sqlite_config_provider.dart';
import 'package:neostation/screens/game_screen/android_apps/android_options_dialog.dart';
import 'package:neostation/services/sfx_service.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'database_test_helper.dart';
import 'gamepad_test_clock.dart';
import 'support/plugin_channel_mocks.dart';

/// The Android board's Start panel is where apps are hidden and restored:
/// the app under the grid's cursor can be hidden, and every hidden app is
/// listed with a way back.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final dbHelper = DatabaseTestHelper();
  late dynamic db;

  const androidSystem = SystemModel(
    id: 'android',
    realName: 'Android',
    folderName: 'android',
    iconImage: '',
    color: '#000000',
  );

  // A dotted package name, as every real one is: hiding must key on the whole
  // package, not on a name with its "extension" stripped.
  const chrome = GameModel(
    romname: 'com.android',
    realname: 'Chrome',
    name: 'Chrome',
    descriptions: {},
    year: '',
    developer: '',
    publisher: '',
    genre: '',
    players: '',
    rating: 0,
    romPath: 'com.android.chrome',
  );

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

  setUp(() async {
    resetGamepadClock();
    db = await dbHelper.setUp();
    await db.execute(
      "INSERT INTO app_systems (id, real_name, folder_name) "
      "VALUES ('android', 'Android', 'android')",
    );
  });

  tearDown(() async {
    restoreGamepadClock();
    await dbHelper.tearDown();
  });

  Future<void> addApp(String package, String label, {bool hidden = false}) =>
      db.execute(
        'INSERT INTO user_roms (rom_path, filename, app_system_id, title_name, '
        'is_hidden) VALUES (?, ?, ?, ?, ?)',
        [package, package, 'android', label, hidden ? 1 : 0],
      );

  Future<Map<String, int>> hiddenFlags() async {
    final rows = await db.rawQuery(
      "SELECT rom_path, is_hidden FROM user_roms WHERE app_system_id = 'android'",
    );
    return {
      for (final row in rows)
        row['rom_path'] as String: (row['is_hidden'] as int?) ?? 0,
    };
  }

  /// Opens the panel the way the grid does, from a button on the page.
  Future<int Function()> openPanel(
    WidgetTester tester, {
    GameModel? focusedApp = chrome,
  }) async {
    var changes = 0;
    await tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(size: Size(1920, 1080)),
        child: ScreenUtilInit(
          designSize: const Size(1920, 1080),
          builder: (context, _) => ChangeNotifierProvider<SqliteConfigProvider>(
            create: (_) => SqliteConfigProvider(),
            child: MaterialApp(
              localizationsDelegates:
                  FlutterLocalization.instance.localizationsDelegates,
              supportedLocales: FlutterLocalization.instance.supportedLocales,
              home: Builder(
                builder: (context) => Scaffold(
                  body: TextButton(
                    onPressed: () => showAndroidOptionsDialog(
                      context,
                      system: androidSystem,
                      focusedApp: focusedApp,
                      onAppsChanged: () async => changes++,
                    ),
                    child: const Text('open'),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    // Past the navigator's activation grace.
    advanceGamepadClock(const Duration(milliseconds: 250));
    await tester.pump();
    return () => changes;
  }

  Future<void> press(WidgetTester tester, LogicalKeyboardKey key) async {
    await tester.sendKeyEvent(key);
    await tester.pump();
    advanceGamepadClock(const Duration(milliseconds: 200));
    await tester.pumpAndSettle();
  }

  testWidgets('lists the hidden apps by name, with Unhide All for two', (
    tester,
  ) async {
    await addApp('com.android.chrome', 'Chrome');
    await addApp('org.zeta', 'Zeta', hidden: true);
    await addApp('org.alpha', 'Alpha', hidden: true);

    await openPanel(tester);

    expect(find.text('Hide App'), findsOneWidget);
    expect(find.text('HIDDEN APPS'), findsOneWidget);
    expect(find.text('Unhide All'), findsOneWidget);
    // Sorted by name, whatever order the rows were stored in.
    final alpha = tester.getTopLeft(find.text('Alpha')).dy;
    final zeta = tester.getTopLeft(find.text('Zeta')).dy;
    expect(alpha, lessThan(zeta));
  });

  testWidgets('hides the focused app from the pad and closes', (tester) async {
    await addApp('com.android.chrome', 'Chrome');
    await addApp('com.android', 'Not Chrome');

    final changes = await openPanel(tester);
    await press(tester, LogicalKeyboardKey.arrowDown);
    await press(tester, LogicalKeyboardKey.enter);

    expect(await hiddenFlags(), {'com.android.chrome': 1, 'com.android': 0});
    expect(changes(), 1);
    expect(find.text('Hide App'), findsNothing);
  });

  testWidgets('tapping a hidden app restores it and drops Unhide All', (
    tester,
  ) async {
    await addApp('org.alpha', 'Alpha', hidden: true);
    await addApp('org.zeta', 'Zeta', hidden: true);

    final changes = await openPanel(tester);
    await tester.tap(find.text('Alpha'));
    await tester.pumpAndSettle();

    expect(await hiddenFlags(), {'org.alpha': 0, 'org.zeta': 1});
    expect(changes(), 1);
    expect(find.text('Alpha'), findsNothing);
    expect(find.text('Zeta'), findsOneWidget);
    expect(find.text('Unhide All'), findsNothing);
  });

  testWidgets('Unhide All restores every hidden app', (tester) async {
    await addApp('com.android.chrome', 'Chrome');
    await addApp('org.alpha', 'Alpha', hidden: true);
    await addApp('org.zeta', 'Zeta', hidden: true);

    await openPanel(tester);
    // Card size, Hide App, Alpha, Zeta, Unhide All.
    for (var i = 0; i < 4; i++) {
      await press(tester, LogicalKeyboardKey.arrowDown);
    }
    await press(tester, LogicalKeyboardKey.enter);

    expect((await hiddenFlags()).values, everyElement(0));
    expect(find.text('HIDDEN APPS'), findsNothing);
  });

  testWidgets('offers no Hide row when the grid is empty', (tester) async {
    await openPanel(tester, focusedApp: null);

    expect(find.text('Hide App'), findsNothing);
    expect(find.text('HIDDEN APPS'), findsNothing);
  });
}
