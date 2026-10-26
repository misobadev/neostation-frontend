import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/l10n/app_locale.dart';
import 'package:neostation/screens/secondary_screen/widgets/status_readout.dart';
import 'package:neostation/services/secondary_apps_service.dart';
import 'package:neostation/themes/app_themes.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Covers the secondary display's corner clock + battery readout.
///
/// The bottom screen runs in its own Flutter engine, spawned by `sub_screen`
/// rather than by the activity that registers the app's plugins — so the one
/// thing this widget must never do is fail loudly when `battery_plus` isn't
/// reachable. These pin that fallback (clock alone, no wrong number) alongside
/// the two clock formats and the low-battery colouring.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('dev.fluttercommunity.plus/battery');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  var levelReads = 0;

  // The clock reads its AM/PM words from the app language.
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await FlutterLocalization.instance.ensureInitialized();
    FlutterLocalization.instance.init(
      mapLocales: [const MapLocale('en', AppLocale.en)],
      initLanguageCode: 'en',
    );
  });

  setUp(() {
    levelReads = 0;
    SecondaryAppsService.deviceScreenOn.value = true;
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
    SecondaryAppsService.deviceScreenOn.value = true;
  });

  /// Answers `getBatteryLevel` with [level], or throws the way an unregistered
  /// plugin does when [level] is null.
  void mockBattery(int? level) {
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method != 'getBatteryLevel') return null;
      levelReads++;
      if (level == null) {
        throw MissingPluginException(
          'No implementation found for getBatteryLevel',
        );
      }
      return level;
    });
  }

  Future<void> pumpReadout(
    WidgetTester tester, {
    required bool use12HourClock,
    String? themeName = 'dark',
  }) async {
    await tester.pumpWidget(
      ScreenUtilInit(
        designSize: const Size(640, 480),
        builder: (context, _) => MaterialApp(
          localizationsDelegates:
              FlutterLocalization.instance.localizationsDelegates,
          supportedLocales: FlutterLocalization.instance.supportedLocales,
          locale: const Locale('en'),
          home: Scaffold(
            body: StatusReadout(
              scheme: const ColorScheme.dark(),
              themeName: themeName,
              use12HourClock: use12HourClock,
            ),
          ),
        ),
      ),
    );
    // The level is read asynchronously in initState; settle so the first
    // answer (or failure) has landed before asserting.
    await tester.pumpAndSettle();
  }

  testWidgets('shows the battery percentage the platform reports', (
    tester,
  ) async {
    mockBattery(87);

    await pumpReadout(tester, use12HourClock: false);

    expect(find.text('87%'), findsOneWidget);
  });

  testWidgets('drops the battery block when the plugin is unreachable', (
    tester,
  ) async {
    // What the secondary engine does if `battery_plus` never registered there:
    // the clock still has to render, and no percentage may be invented.
    mockBattery(null);

    await pumpReadout(tester, use12HourClock: false);

    expect(find.textContaining('%'), findsNothing);
    expect(find.byType(Text), findsOneWidget);
  });

  testWidgets('renders the clock in the format the user picked', (
    tester,
  ) async {
    mockBattery(50);

    await pumpReadout(tester, use12HourClock: true);
    final twelveHour = tester.widgetList<Text>(find.byType(Text)).first.data!;
    expect(twelveHour, anyOf(contains('AM'), contains('PM')));

    await pumpReadout(tester, use12HourClock: false);
    final twentyFourHour = tester
        .widgetList<Text>(find.byType(Text))
        .first
        .data!;
    expect(twentyFourHour, isNot(anyOf(contains('AM'), contains('PM'))));
  });

  testWidgets('colours the battery by charge level, like the primary header', (
    tester,
  ) async {
    // The same theme colours the header reads, resolved by name because this
    // engine has no ThemeProvider: a user glancing down should not have to
    // learn a second colour language for the same number.
    final colors = AppThemes.getCustomColorsByName('dark');

    Future<Color> colorAtLevel(int level) async {
      mockBattery(level);
      // Tear the old readout down first: the level is read in initState, so a
      // re-pump of the same widget would keep showing the previous charge.
      await tester.pumpWidget(const SizedBox.shrink());
      await pumpReadout(tester, use12HourClock: false);
      final text = tester.widget<Text>(find.text('$level%'));
      return text.style!.color!;
    }

    expect(await colorAtLevel(80), colors.batteryFull);
    expect(await colorAtLevel(21), colors.batteryFull);
    expect(await colorAtLevel(20), colors.batteryMedium);
    expect(await colorAtLevel(6), colors.batteryMedium);
    expect(await colorAtLevel(5), colors.batteryLow);
    expect(await colorAtLevel(1), colors.batteryLow);
  });

  testWidgets('stops ticking behind a closed lid and catches up on wake', (
    tester,
  ) async {
    mockBattery(64);

    await pumpReadout(tester, use12HourClock: false);
    expect(levelReads, 1);

    // Lid shut: the panel stays mounted, but nothing should wake the CPU for a
    // screen nobody can see.
    SecondaryAppsService.deviceScreenOn.value = false;
    await tester.pump(const Duration(minutes: 3));
    expect(levelReads, 1);

    // Lid open: refresh immediately rather than showing the time it closed at
    // until the next minute boundary, then resume ticking.
    SecondaryAppsService.deviceScreenOn.value = true;
    await tester.pump();
    expect(levelReads, 2);

    await tester.pump(const Duration(minutes: 2));
    expect(levelReads, greaterThan(2));
  });
}
