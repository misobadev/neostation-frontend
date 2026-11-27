import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/l10n/app_locale.dart';
import 'package:neostation/models/retro_achievements_dashboard_models.dart';
import 'package:neostation/models/retro_achievements_game_info.dart';
import 'package:neostation/models/retro_achievements_summary.dart';
import 'package:neostation/models/retro_achievements_user.dart';
import 'package:neostation/providers/file_provider.dart';
import 'package:neostation/providers/retro_achievements_provider.dart';
import 'package:neostation/providers/romm_provider.dart';
import 'package:neostation/providers/sqlite_config_provider.dart';
import 'package:neostation/screens/retro_achievements_screen/ra_content.dart';
import 'package:neostation/screens/retro_achievements_screen/ra_dashboard.dart';
import 'package:neostation/screens/retro_achievements_screen/ra_collection_tab.dart';
import 'package:neostation/screens/retro_achievements_screen/ra_games_tab.dart';
import 'package:neostation/screens/retro_achievements_screen/ra_unlocks_tab.dart';
import 'package:neostation/services/gamepad/gamepad_navigation_manager.dart';
import 'package:neostation/services/sfx_service.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'gamepad_test_clock.dart';

class _DashboardProvider extends RetroAchievementsProvider {
  _DashboardProvider({this.connected = true});

  final bool connected;
  final _summary = RetroAchievementsUserSummary.fromJson({
    'Rank': 12,
    'TotalRanked': 1000,
  });

  @override
  bool get isConnected => connected;

  @override
  bool get summaryLoaded => true;

  @override
  RetroAchievementsUserSummary? get userSummary => _summary;

  @override
  RetroAchievementsUser? get user => connected
      ? RetroAchievementsUser(
          user: 'Player',
          ulid: 'player',
          userPic: '',
          memberSince: '',
          richPresenceMsg: '',
          lastGameId: 0,
          contribCount: 0,
          contribYield: 0,
          totalPoints: 100,
          totalCasualPoints: 0,
          totalTruePoints: 100,
          permissions: 0,
          untracked: 0,
          id: 1,
          userWallActive: false,
          motto: '',
        )
      : null;

  @override
  List<RetroAchievementRecentUnlockItem> get recentUnlocks => [
    RetroAchievementRecentUnlockItem(
      date: '2026-09-01 00:00:00',
      hardcoreMode: true,
      achievementId: 1,
      title: 'First unlock',
      description: '',
      badgeName: '',
      badgeUrl: '',
      points: 5,
      trueRatio: 5,
      type: null,
      author: '',
      authorUlid: '',
      gameTitle: 'Game',
      gameIcon: '',
      gameId: 1,
      consoleName: 'NES',
      gameUrl: '',
    ),
  ];

  @override
  List<RetroAchievementRecentlyPlayedGameItem> get recentlyPlayedGames => [];

  @override
  Future<bool> fetchGOTW() async => true;

  @override
  Future<bool> fetchRecentUnlocks() async => true;

  @override
  Future<bool> fetchRecentlyPlayedGames() async => true;

  @override
  Future<bool> fetchUserAwards() async => true;

  @override
  Future<bool> fetchCompletionProgress() async => true;

  @override
  Future<Map<String, dynamic>> getEventCatalogue(int year) async => {
    'year': year,
    'weeks': <Map<String, dynamic>>[],
  };

  @override
  Future<GameInfoAndUserProgress?> getAnnualEventProgress(int year) async =>
      null;

  @override
  Future<List<RetroAchievementCompletionProgressItem>>
  getAwardProgress() async => [];

  @override
  List<RetroAchievementRecentUnlockItem> get unlocksListItems => recentUnlocks;

  @override
  bool get unlocksListLoaded => true;

  @override
  bool get unlocksListIsStale => false;

  @override
  Future<bool> loadUnlocksPage({bool reset = false}) async => true;

  @override
  List<RaGamesListItem> get gamesListItems => [];

  @override
  bool get gamesListLoaded => true;

  @override
  bool get gamesListIsStale => false;

  @override
  Future<bool> loadGamesPage({bool reset = false}) async => true;
}

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

  Future<void> pumpShell(
    WidgetTester tester,
    RetroAchievementsProvider provider, {
    Size designSize = const Size(1280, 720),
  }) async {
    tester.view.physicalSize = const Size(1280, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    });
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<RetroAchievementsProvider>.value(
            value: provider,
          ),
          ChangeNotifierProvider(create: (_) => SqliteConfigProvider()),
          ChangeNotifierProvider(create: (_) => FileProvider()),
          ChangeNotifierProvider(create: (_) => RommProvider()),
        ],
        child: ScreenUtilInit(
          designSize: designSize,
          builder: (context, _) => MaterialApp(
            localizationsDelegates:
                FlutterLocalization.instance.localizationsDelegates,
            supportedLocales: FlutterLocalization.instance.supportedLocales,
            home: const Scaffold(body: RAContent()),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  testWidgets('signed out shows the login flow without dashboard actions', (
    tester,
  ) async {
    await pumpShell(tester, _DashboardProvider(connected: false));

    expect(find.byType(RADashboardHub), findsNothing);
    expect(find.byType(TextFormField), findsNWidgets(2));
  });

  testWidgets('signed in shows the section menu beside the overview', (
    tester,
  ) async {
    await pumpShell(tester, _DashboardProvider());

    expect(find.byType(RADashboardHub), findsOneWidget);
    expect(find.text(AppLocale.en[AppLocale.raOverview]!), findsOneWidget);
    expect(find.text('Achievement of the Week'), findsOneWidget);
    expect(find.text(AppLocale.en[AppLocale.raSubtabUnlocks]!), findsOneWidget);
    expect(find.text(AppLocale.en[AppLocale.raSubtabGames]!), findsOneWidget);
    expect(find.text(AppLocale.en[AppLocale.raAwards]!), findsOneWidget);
    expect(find.text(AppLocale.en[AppLocale.logout]!), findsOneWidget);
  });

  testWidgets('the sidebar keeps the profile standing visible', (tester) async {
    await pumpShell(tester, _DashboardProvider());

    expect(find.text('Rank #12 · Top 1.2%'), findsOneWidget);
    expect(find.textContaining('100 pts'), findsOneWidget);
  });

  testWidgets('menu rows show their section in the panel, not a new page', (
    tester,
  ) async {
    await pumpShell(tester, _DashboardProvider());

    await tester.tap(find.text(AppLocale.en[AppLocale.raSubtabGames]!));
    await tester.pumpAndSettle();
    expect(find.byType(RaGamesTab), findsOneWidget);
    expect(find.byType(RADashboardHub), findsOneWidget);
    expect(GamepadNavigationManager.stackDepth, 1);

    await tester.tap(find.text(AppLocale.en[AppLocale.raSubtabUnlocks]!));
    await tester.pumpAndSettle();
    expect(find.byType(RaUnlocksTab), findsOneWidget);
    // A section once shown stays mounted.
    expect(find.byType(RaGamesTab, skipOffstage: false), findsOneWidget);

    await tester.tap(find.text(AppLocale.en[AppLocale.raAwards]!));
    await tester.pumpAndSettle();
    expect(find.byType(RaCollectionTab), findsOneWidget);
  });

  testWidgets('down walks the menu and right enters the panel', (tester) async {
    resetGamepadClock();
    addTearDown(restoreGamepadClock);
    await pumpShell(tester, _DashboardProvider());
    Future<void> press(LogicalKeyboardKey key) async {
      advanceGamepadClock(const Duration(milliseconds: 600));
      await tester.pump();
      await tester.sendKeyEvent(key);
      await tester.pumpAndSettle();
    }

    Color? menuBackground(String label) {
      final row = find.widgetWithText(AnimatedContainer, label);
      final decoration = tester.widget<AnimatedContainer>(row).decoration;
      return (decoration as BoxDecoration).color;
    }

    await press(LogicalKeyboardKey.arrowDown);
    expect(
      tester.widget<RADashboardHub>(find.byType(RADashboardHub)).section,
      RaDashboardSection.aotw,
    );

    await press(LogicalKeyboardKey.arrowDown);
    final hub = tester.widget<RADashboardHub>(find.byType(RADashboardHub));
    expect(hub.section, RaDashboardSection.unlocks);
    expect(hub.menuFocused, isTrue);

    await press(LogicalKeyboardKey.arrowDown);
    await press(LogicalKeyboardKey.arrowDown);
    final awards = AppLocale.en[AppLocale.raAwards]!;
    final logout = AppLocale.en[AppLocale.logout]!;
    final awardsPanel = find.text(AppLocale.en[AppLocale.noAwardsYet]!);
    final highlight = Theme.of(
      tester.element(find.byType(RADashboardHub)),
    ).colorScheme.onSurface;
    expect(menuBackground(awards), highlight);

    await press(LogicalKeyboardKey.arrowDown);
    expect(menuBackground(logout), highlight);
    expect(menuBackground(awards), Colors.transparent);
    expect(awardsPanel.hitTestable(), findsOneWidget);

    await press(LogicalKeyboardKey.arrowUp);
    expect(menuBackground(awards), highlight);
    expect(menuBackground(logout), Colors.transparent);

    await press(LogicalKeyboardKey.arrowRight);
    expect(
      tester.widget<RADashboardHub>(find.byType(RADashboardHub)).menuFocused,
      isFalse,
    );
  });

  testWidgets('collections keep their text scale inside the panel', (
    tester,
  ) async {
    await pumpShell(
      tester,
      _DashboardProvider(),
      designSize: const Size(640, 480),
    );
    await tester.tap(find.text(AppLocale.en[AppLocale.raAwards]!));
    await tester.pumpAndSettle();
    final empty = find.text(AppLocale.en[AppLocale.noAwardsYet]!);
    final context = tester.element(empty);
    expect(DefaultTextStyle.of(context).style.fontSize, 11.r);
  });
}
