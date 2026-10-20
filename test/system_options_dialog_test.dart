import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:neostation/constants/system_folder_names.dart';
import 'package:neostation/l10n/app_locale.dart';
import 'package:neostation/models/config_model.dart';
import 'package:neostation/models/my_systems.dart';
import 'package:neostation/providers/sqlite_config_provider.dart';
import 'package:neostation/screens/systems_screen/my_systems_section/widgets/system_options_dialog.dart';
import 'package:neostation/services/sfx_service.dart';
import 'package:neostation/services/gamepad/gamepad_navigation_manager.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The systems Options dialog is the single entry point for the selected
/// system's actions and the library display/sorting settings. These tests pin
/// the three-column split and the action the dialog reports back.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    SfxService().setEnabled(false);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('xyz.luan/gamepads'),
          (call) async => <dynamic>[],
        );
    await FlutterLocalization.instance.ensureInitialized();
    FlutterLocalization.instance.init(
      mapLocales: [MapLocale('en', AppLocale.en)],
      initLanguageCode: 'en',
    );
  });

  SystemInfo system({
    String folderName = 'snes',
    String title = 'Super Nintendo',
  }) => SystemInfo(
    title: title,
    shortName: 'SNES',
    folderName: folderName,
    numOfRoms: 3,
  );

  Widget host({
    SystemInfo? target,
    SqliteConfigProvider? config,
    ValueChanged<SystemOptionsAction?>? onResult,
  }) {
    final systemInfo = target ?? system();
    return ScreenUtilInit(
      designSize: const Size(1920, 1080),
      builder: (context, _) => ChangeNotifierProvider<SqliteConfigProvider>(
        create: (_) => config ?? _GridConfig(),
        child: MaterialApp(
          localizationsDelegates:
              FlutterLocalization.instance.localizationsDelegates,
          supportedLocales: FlutterLocalization.instance.supportedLocales,
          home: Scaffold(
            body: Builder(
              builder: (context) => ElevatedButton(
                onPressed: () async {
                  final result = await showSystemOptionsDialog(
                    context: context,
                    system: systemInfo,
                  );
                  onResult?.call(result);
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> openDialog(WidgetTester tester) async {
    await tester.pump();
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  testWidgets('splits the selected system from the library settings', (
    tester,
  ) async {
    await tester.pumpWidget(host());
    await openDialog(tester);

    final context = tester.element(find.byType(SystemOptionsDialog));

    expect(
      find.textContaining(
        AppLocale.systemOptionsSelectedSystem.getString(context).toUpperCase(),
      ),
      findsOneWidget,
    );
    expect(
      find.text(AppLocale.systemSettings.getString(context)),
      findsOneWidget,
    );
    expect(
      find.text(AppLocale.systemOptionsGameSearch.getString(context)),
      findsOneWidget,
    );
    expect(
      find.text(
        AppLocale.systemOptionsSystemView.getString(context).toUpperCase(),
      ),
      findsOneWidget,
    );
    expect(
      find.text(AppLocale.systemOptionsSystemLayout.getString(context)),
      findsOneWidget,
    );
    expect(
      find.text(AppLocale.systemOptionsSystemSorting.getString(context)),
      findsOneWidget,
    );

    await tester.tap(
      find.text(AppLocale.systemOptionsSystemLayout.getString(context)),
    );
    await tester.pumpAndSettle();

    expect(
      find.text(AppLocale.viewModeGroup.getString(context)),
      findsOneWidget,
    );
    expect(
      find.text(AppLocale.cardSizeGroup.getString(context)),
      findsOneWidget,
    );
    for (final size in const ['S', 'M', 'L', 'XL']) {
      expect(find.text(size), findsOneWidget);
    }
    expect(find.text(AppLocale.sortByGroup.getString(context)), findsNothing);

    await tester.tap(find.byIcon(Symbols.arrow_back_rounded));
    await tester.pumpAndSettle();

    await tester.tap(
      find.text(AppLocale.systemOptionsSystemSorting.getString(context)),
    );
    await tester.pumpAndSettle();

    expect(find.text(AppLocale.sortByGroup.getString(context)), findsOneWidget);
    expect(find.text(AppLocale.orderGroup.getString(context)), findsOneWidget);
    expect(find.text(AppLocale.cardSizeGroup.getString(context)), findsNothing);
  });

  testWidgets('hides card size when the library is in carousel mode', (
    tester,
  ) async {
    await tester.pumpWidget(host(config: _CarouselConfig()));
    await openDialog(tester);

    final context = tester.element(find.byType(SystemOptionsDialog));

    await tester.tap(
      find.text(AppLocale.systemOptionsSystemLayout.getString(context)),
    );
    await tester.pumpAndSettle();

    expect(find.text(AppLocale.cardSizeGroup.getString(context)), findsNothing);
    expect(
      find.text(AppLocale.viewModeGroup.getString(context)),
      findsOneWidget,
    );
  });

  testWidgets('the Search card has no system actions', (tester) async {
    await tester.pumpWidget(
      host(
        target: system(
          folderName: SystemFolderNames.search,
          title: 'Search card',
        ),
      ),
    );
    await openDialog(tester);

    final context = tester.element(find.byType(SystemOptionsDialog));

    expect(
      find.text(AppLocale.systemOptionsNoSystem.getString(context)),
      findsOneWidget,
    );
    expect(
      find.text(AppLocale.systemSettings.getString(context)),
      findsNothing,
    );
    expect(
      find.text(AppLocale.systemOptionsGameSearch.getString(context)),
      findsNothing,
    );
  });

  testWidgets('remounting the system view keeps input in Options', (
    tester,
  ) async {
    await tester.pumpWidget(host());
    await openDialog(tester);
    var systemsActive = false;
    GamepadNavigationManager.pushLayer(
      'replacement_systems_view',
      onActivate: () => systemsActive = true,
      onDeactivate: () => systemsActive = false,
    );
    try {
      expect(systemsActive, isFalse);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      expect(systemsActive, isTrue);
    } finally {
      GamepadNavigationManager.popLayer('replacement_systems_view');
    }
  });

  testWidgets('System Settings reports the action back to the host', (
    tester,
  ) async {
    SystemOptionsAction? result;
    await tester.pumpWidget(host(onResult: (value) => result = value));
    await openDialog(tester);

    final context = tester.element(find.byType(SystemOptionsDialog));
    await tester.tap(find.text(AppLocale.systemSettings.getString(context)));
    await tester.pumpAndSettle();

    expect(result, SystemOptionsAction.gameSettings);
  });
}

/// Grid mode, so the dialog offers the card-size rows.
class _GridConfig extends SqliteConfigProvider {
  @override
  ConfigModel get config => super.config.copyWith(systemViewMode: 'grid');
}

/// Carousel mode, where card size does not apply.
class _CarouselConfig extends _GridConfig {
  @override
  ConfigModel get config => super.config.copyWith(systemViewMode: 'carousel');
}
