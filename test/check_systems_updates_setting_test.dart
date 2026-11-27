import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/data/datasources/sqlite_service.dart';
import 'package:neostation/l10n/app_locale.dart';
import 'package:neostation/providers/sqlite_config_provider.dart';
import 'package:neostation/screens/settings_screen/new_settings_options/general_settings_content.dart';
import 'package:neostation/screens/settings_screen/new_settings_options/widgets/setting_row.dart';
import 'package:neostation/services/global_notification_service.dart';
import 'package:neostation/services/systems_update_service.dart';
import 'package:neostation/utils/systems_update_flow.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'database_test_helper.dart';

/// Settings > General has a "Check for Systems Updates" row directly under
/// the auto-update toggle. General settings counts its rows by hand in three
/// places (the item count, the select chain and the build), so a row added to
/// one and not the others is unreachable by D-pad, or shifts every row below
/// it onto its neighbour's action.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final dbHelper = DatabaseTestHelper();
  late int checks;

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await FlutterLocalization.instance.ensureInitialized();
    FlutterLocalization.instance.init(
      mapLocales: [const MapLocale('en', AppLocale.en)],
      initLanguageCode: 'en',
    );
  });

  setUp(() async {
    await dbHelper.setUp();
    await SqliteService.updateSystemsVersion('0.4.2');
    checks = 0;
    SystemsUpdateFlow.debugReset();
    SystemsUpdateFlow.check = () async {
      checks++;
      return const SystemsUpToDate('0.4.2');
    };
    GlobalNotificationService().dismiss();
    // The panel syncs desktop fullscreen on open, through plugins that are not
    // there under test; answer them with nothing.
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    for (final channel in const ['fullscreen_window', 'window_manager']) {
      messenger.setMockMethodCallHandler(
        MethodChannel(channel),
        (call) async => null,
      );
    }
  });

  tearDown(() async {
    SystemsUpdateFlow.debugReset();
    GlobalNotificationService().dismiss();
    await dbHelper.tearDown();
  });

  String en(String key) => AppLocale.en[key] as String;

  Future<GeneralSettingsContentState> pumpGeneral(
    WidgetTester tester, {
    int selectedContentIndex = 0,
  }) async {
    final key = GlobalKey<GeneralSettingsContentState>();
    await tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(size: Size(1920, 1080)),
        child: ScreenUtilInit(
          designSize: const Size(1920, 1080),
          builder: (context, child) =>
              ChangeNotifierProvider<SqliteConfigProvider>(
                create: (_) => SqliteConfigProvider(),
                child: MaterialApp(
                  localizationsDelegates:
                      FlutterLocalization.instance.localizationsDelegates,
                  supportedLocales:
                      FlutterLocalization.instance.supportedLocales,
                  home: Scaffold(
                    body: GeneralSettingsContent(
                      key: key,
                      isContentFocused: true,
                      selectedContentIndex: selectedContentIndex,
                      onFullscreenToggle: (_) {},
                    ),
                  ),
                ),
              ),
        ),
      ),
    );
    // The version loads from the real test database; let it settle.
    await tester.runAsync(SystemsUpdateService.currentVersion);
    await tester.pump();
    await tester.pump();
    return key.currentState!;
  }

  Finder rowTitled(String key) =>
      find.ancestor(of: find.text(en(key)), matching: find.byType(SettingRow));

  /// The row's index as the select chain and the D-pad see it: its position
  /// among the rows, which are built in order.
  int indexOf(WidgetTester tester, String key) {
    final rows = tester.widgetList<SettingRow>(find.byType(SettingRow));
    return rows.toList().indexWhere((r) => r.title == en(key));
  }

  testWidgets('sits directly under the auto-update toggle', (tester) async {
    await pumpGeneral(tester);

    final toggle = indexOf(tester, AppLocale.autoUpdateSystems);
    final check = indexOf(tester, AppLocale.checkSystemsUpdates);

    expect(toggle, isNonNegative);
    expect(check, toggle + 1);
    expect(
      tester.getTopLeft(rowTitled(AppLocale.checkSystemsUpdates)).dy,
      greaterThan(tester.getTopLeft(rowTitled(AppLocale.autoUpdateSystems)).dy),
    );
  });

  testWidgets('shows the installed systems version', (tester) async {
    await pumpGeneral(tester);

    expect(find.text('Current version: 0.4.2'), findsOneWidget);
  });

  testWidgets('every row is counted, so the last one is reachable', (
    tester,
  ) async {
    final general = await pumpGeneral(tester);

    expect(
      general.getItemCount(),
      tester.widgetList(find.byType(SettingRow)).length,
    );
  });

  testWidgets('the D-pad focus lands on it at its index', (tester) async {
    await pumpGeneral(tester);
    final index = indexOf(tester, AppLocale.checkSystemsUpdates);

    await pumpGeneral(tester, selectedContentIndex: index);

    final row = tester.widget<SettingRow>(
      rowTitled(AppLocale.checkSystemsUpdates),
    );
    expect(row.focused, isTrue);
  });

  testWidgets('A on the row runs the check', (tester) async {
    final general = await pumpGeneral(tester);
    final index = indexOf(tester, AppLocale.checkSystemsUpdates);

    general.selectItem(index);
    await tester.pump();
    await tester.pump();

    expect(checks, 1);
    expect(
      GlobalNotificationService().notifier.value.single.message,
      'Systems are up to date (v0.4.2)',
    );
  });

  testWidgets('a tap on the row runs the check', (tester) async {
    await pumpGeneral(tester);

    await tester.ensureVisible(rowTitled(AppLocale.checkSystemsUpdates));
    await tester.tap(find.text(en(AppLocale.checkSystemsUpdates)));
    await tester.pump();
    await tester.pump();

    expect(checks, 1);
  });

  testWidgets('the rows below it keep their own actions', (tester) async {
    final general = await pumpGeneral(tester);
    final provider = Provider.of<SqliteConfigProvider>(
      tester.element(find.byType(GeneralSettingsContent)),
      listen: false,
    );
    final sfxIndex = indexOf(tester, AppLocale.sfxSounds);
    final autoIndex = indexOf(tester, AppLocale.autoUpdateSystems);
    final sfxBefore = provider.config.sfxEnabled;
    final autoBefore = provider.config.autoUpdateSystems;

    general.selectItem(sfxIndex);
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump();
    general.selectItem(autoIndex);
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump();

    expect(provider.config.sfxEnabled, !sfxBefore);
    expect(provider.config.autoUpdateSystems, !autoBefore);
    expect(checks, 0);
  });

  testWidgets('says it is checking while the check runs', (tester) async {
    final pending = Completer<SystemsUpdateCheck>();
    SystemsUpdateFlow.check = () {
      checks++;
      return pending.future;
    };
    final general = await pumpGeneral(tester);

    general.selectItem(indexOf(tester, AppLocale.checkSystemsUpdates));
    await tester.pump();

    expect(find.text(en(AppLocale.systemsUpdateChecking)), findsOneWidget);
    expect(find.text('Current version: 0.4.2'), findsNothing);

    // A second press while it runs does not start another check.
    general.selectItem(indexOf(tester, AppLocale.checkSystemsUpdates));
    await tester.pump();
    expect(checks, 1);

    pending.complete(const SystemsUpToDate('0.4.2'));
    await tester.pump();
    await tester.pump();
    expect(find.text('Current version: 0.4.2'), findsOneWidget);
  });
}
