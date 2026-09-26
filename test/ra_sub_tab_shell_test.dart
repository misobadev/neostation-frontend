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
import 'package:neostation/screens/retro_achievements_screen/ra_dedicated_pages.dart';
import 'package:neostation/services/gamepad/gamepad_navigation_manager.dart';
import 'package:neostation/services/sfx_service.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

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
    RetroAchievementsProvider provider,
  ) async {
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
          designSize: const Size(1280, 720),
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

  testWidgets('signed in shows a compact dashboard without nested tabs', (
    tester,
  ) async {
    await pumpShell(tester, _DashboardProvider());

    expect(find.byType(RADashboardHub), findsOneWidget);
    expect(find.text(AppLocale.en[AppLocale.raAotw]!), findsOneWidget);
    expect(find.text(AppLocale.en[AppLocale.raSubtabUnlocks]!), findsOneWidget);
    expect(find.text(AppLocale.en[AppLocale.raSubtabGames]!), findsOneWidget);
    expect(find.text(AppLocale.en[AppLocale.raAwards]!), findsOneWidget);
  });

  testWidgets('dashboard keeps profile standing visible above destinations', (
    tester,
  ) async {
    await pumpShell(tester, _DashboardProvider());

    expect(find.text('Rank #12 · Top 1.2%'), findsOneWidget);
    expect(find.text('100 pts'), findsOneWidget);
  });

  testWidgets('dashboard destinations open dedicated routes', (tester) async {
    await pumpShell(tester, _DashboardProvider());

    await tester.tap(find.text(AppLocale.en[AppLocale.raSubtabGames]!).first);
    await tester.pumpAndSettle();
    expect(find.byType(RaGamesPage), findsOneWidget);
    expect(GamepadNavigationManager.stackDepth, greaterThan(1));

    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.byType(RaGamesPage), findsNothing);
    expect(find.byType(RADashboardHub), findsOneWidget);
    expect(GamepadNavigationManager.stackDepth, 1);
  });

  testWidgets('events and awards have separate full-screen destinations', (
    tester,
  ) async {
    await pumpShell(tester, _DashboardProvider());

    await tester.tap(find.text(AppLocale.en[AppLocale.raAotw]!).first);
    await tester.pumpAndSettle();
    expect(find.byType(RaCollectionPage), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();

    await tester.tap(find.text(AppLocale.en[AppLocale.raAwards]!).first);
    await tester.pumpAndSettle();
    expect(find.byType(RaCollectionPage), findsOneWidget);
  });

  testWidgets('recent unlocks has a dedicated full-screen destination', (
    tester,
  ) async {
    await pumpShell(tester, _DashboardProvider());

    await tester.tap(find.text(AppLocale.en[AppLocale.raSubtabUnlocks]!).first);
    await tester.pumpAndSettle();
    expect(find.byType(RaUnlocksPage), findsOneWidget);
  });
}
