import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:neostation/l10n/app_locale.dart';
import 'package:neostation/services/sfx_service.dart';
import 'package:neostation/utils/app_shortcuts.dart';
import 'package:neostation/widgets/context_menu/game_context_menu.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// On desktop the keyboard drives GamepadNavigation, and Flutter's focus system
/// sees the same keys. The arrow keys must not also move Flutter's focus, or
/// Enter activates the focused widget as well as the navigation's selection —
/// one press then runs a menu row twice and pops the screen beneath the menu.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    // SoLoud has no native library in the test host.
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

  tearDown(() => debugDefaultTargetPlatformOverride = null);

  group('appShortcuts', () {
    for (final platform in [
      TargetPlatform.linux,
      TargetPlatform.windows,
      TargetPlatform.macOS,
    ]) {
      test('on ${platform.name} the arrow keys do not move focus', () {
        debugDefaultTargetPlatformOverride = platform;
        final shortcuts = appShortcuts()!;

        for (final key in [
          LogicalKeyboardKey.arrowUp,
          LogicalKeyboardKey.arrowDown,
          LogicalKeyboardKey.arrowLeft,
          LogicalKeyboardKey.arrowRight,
        ]) {
          expect(shortcuts[SingleActivator(key)], isNull, reason: '$key');
        }
        expect(shortcuts.values.whereType<DirectionalFocusIntent>(), isEmpty);
      });

      test('on ${platform.name} everything else is Flutter\'s default', () {
        debugDefaultTargetPlatformOverride = platform;
        final shortcuts = appShortcuts()!;
        final defaults = WidgetsApp.defaultShortcuts;

        for (final entry in defaults.entries) {
          if (entry.value is DirectionalFocusIntent) continue;
          expect(shortcuts[entry.key], entry.value, reason: '${entry.key}');
        }
        expect(shortcuts.length, lessThan(defaults.length));
      });
    }

    test('Android keeps Flutter\'s defaults', () {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      expect(appShortcuts(), isNull);
    });
  });

  testWidgets('a menu row chosen with the arrow keys and Enter runs once and '
      'leaves the screen beneath it open', (tester) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(1920, 1080);
    addTearDown(tester.view.reset);

    final navigatorKey = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      ScreenUtilInit(
        designSize: const Size(1920, 1080),
        builder: (context, _) => MaterialApp(
          navigatorKey: navigatorKey,
          shortcuts: appShortcuts(),
          localizationsDelegates:
              FlutterLocalization.instance.localizationsDelegates,
          supportedLocales: FlutterLocalization.instance.supportedLocales,
          home: const Scaffold(body: Text('home')),
        ),
      ),
    );
    await tester.pumpAndSettle();
    // The games list the menu opens over.
    navigatorKey.currentState!.push(
      MaterialPageRoute<void>(
        builder: (_) => const Scaffold(body: Text('games list')),
      ),
    );
    await tester.pumpAndSettle();

    var scraped = 0;
    // ignore: unawaited_futures
    showGameContextMenu(
      context: navigatorKey.currentContext!,
      targets: [
        GameContextMenuTarget(
          id: 'favorites',
          label: 'Favorite',
          icon: Symbols.favorite_rounded,
          isMember: false,
          setMember: (_) async => true,
        ),
      ],
      onSettings: () {},
      onScrape: () => scraped++,
    );
    await tester.pumpAndSettle();

    // GamepadNavigation drops keys for 150 real ms after a layer activates and
    // throttles them 128 real ms apart; fake time moves neither.
    Future<void> realPause() async {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 200)),
      );
      await tester.pumpAndSettle();
    }

    await realPause();
    // Settings is where the cursor starts; Down moves to Scrape.
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await realPause();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await realPause();

    expect(scraped, 1);
    expect(find.text('games list'), findsOneWidget);
  }, variant: TargetPlatformVariant.only(TargetPlatform.linux));
}
