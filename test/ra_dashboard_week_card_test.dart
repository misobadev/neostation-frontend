import 'package:flutter/material.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:neostation/l10n/app_locale.dart';
import 'package:neostation/models/database_game_model.dart';
import 'package:neostation/models/retro_achievements_dashboard_models.dart';
import 'package:neostation/models/retro_achievements_gotw.dart';
import 'package:neostation/models/retro_achievements_user.dart';
import 'package:neostation/models/retro_achievements_user_awards.dart';
import 'package:neostation/providers/retro_achievements_provider.dart';
import 'package:neostation/providers/romm_provider.dart';
import 'package:neostation/screens/retro_achievements_screen/ra_dashboard.dart';

class _DashboardProvider extends RetroAchievementsProvider {
  _DashboardProvider(
    this._owned, {
    this.personalProgress = const AotwPersonalProgress.unknown(),
    this.showAotw = true,
    this.casual = false,
    this.awards,
  });

  final OwnedWeekGameResolution? _owned;
  final AotwPersonalProgress personalProgress;
  final bool showAotw;
  final bool casual;
  final RetroAchievementsUserAwards? awards;

  @override
  RetroAchievementsUser? get user => RetroAchievementsUser(
    user: 'Player',
    ulid: '',
    userPic: '',
    memberSince: '',
    richPresenceMsg: '',
    lastGameId: 0,
    contribCount: 0,
    contribYield: 0,
    totalPoints: casual ? 0 : 1,
    totalCasualPoints: casual ? 1 : 0,
    totalTruePoints: 0,
    permissions: 0,
    untracked: 0,
    id: 1,
    userWallActive: false,
    motto: '',
  );

  @override
  RetroAchievementsUserAwards? get userAwards => awards;

  @override
  RetroAchievementsGOTW? get gotw => showAotw
      ? RetroAchievementsGOTW(
          achievement: Achievement(
            id: 1,
            title: 'Finish the level',
            description: 'Reach the goal.',
            points: 5,
            trueRatio: 12,
            type: '',
            author: '',
            badgeName: '',
            badgeUrl: '',
            dateCreated: '',
            dateModified: '',
          ),
          console: Console(id: 1, title: 'NES'),
          game: Game(id: 42, title: 'Local game'),
          startAt: '2026-09-01T00:00:00Z',
          totalPlayers: 10,
          unlocks: const [],
          unlocksCount: 4,
          unlocksHardcoreCount: 3,
        )
      : null;

  @override
  OwnedWeekGameResolution? get ownedWeekGame => _owned;

  @override
  AotwPersonalProgress get aotwPersonalProgress => personalProgress;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await FlutterLocalization.instance.ensureInitialized();
    FlutterLocalization.instance.init(
      mapLocales: [MapLocale('en', AppLocale.en)],
      initLanguageCode: 'en',
    );
  });

  testWidgets('selected owned weekly card opens its local game', (
    tester,
  ) async {
    final owned = OwnedWeekGameResolution(
      raGameId: 42,
      game: DatabaseGameModel(
        filename: 'local.nes',
        romPath: '/roms/local.nes',
      ),
    );
    OwnedWeekGameResolution? opened;

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<RetroAchievementsProvider>.value(
            value: _DashboardProvider(owned),
          ),
          ChangeNotifierProvider(create: (_) => RommProvider()),
        ],
        child: ScreenUtilInit(
          designSize: const Size(1280, 720),
          builder: (context, _) => MaterialApp(
            localizationsDelegates:
                FlutterLocalization.instance.localizationsDelegates,
            supportedLocales: FlutterLocalization.instance.supportedLocales,
            home: Scaffold(
              body: RADashboardHub(
                logoutSelected: false,
                weekCardSelected: true,
                onDisconnectRequested: () {},
                onOwnedWeekGameSelected: (game) => opened = game,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    final selectedCard = find.byWidgetPredicate(
      (widget) => widget is Semantics && widget.properties.selected == true,
    );
    expect(selectedCard, findsOneWidget);

    await tester.tap(
      find.descendant(of: selectedCard, matching: find.byType(InkWell)),
    );
    expect(opened, same(owned));
  });

  testWidgets('shows documented AOTW metrics and personal status', (
    tester,
  ) async {
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<RetroAchievementsProvider>.value(
            value: _DashboardProvider(
              null,
              personalProgress: AotwPersonalProgress(
                state: AotwUserState.earnedHardcoreThisWeek,
                earnedAt: DateTime.utc(2026, 9, 2),
              ),
            ),
          ),
          ChangeNotifierProvider(create: (_) => RommProvider()),
        ],
        child: ScreenUtilInit(
          designSize: const Size(1280, 720),
          builder: (context, _) => MaterialApp(
            localizationsDelegates:
                FlutterLocalization.instance.localizationsDelegates,
            supportedLocales: FlutterLocalization.instance.supportedLocales,
            home: Scaffold(
              body: RADashboardHub(
                logoutSelected: false,
                weekCardSelected: false,
                onDisconnectRequested: () {},
                onOwnedWeekGameSelected: (_) {},
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('Earned this week · Hardcore'), findsOneWidget);
    expect(find.text('12 True Ratio'), findsOneWidget);
    expect(find.text('4 of 10 players · 40%'), findsOneWidget);
    expect(find.text('Week started 2026-09-01'), findsOneWidget);
    expect(find.text('Not in your library'), findsOneWidget);
  });

  testWidgets('renders an empty event as a neutral state', (tester) async {
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<RetroAchievementsProvider>.value(
            value: _DashboardProvider(null, showAotw: false),
          ),
          ChangeNotifierProvider(create: (_) => RommProvider()),
        ],
        child: ScreenUtilInit(
          designSize: const Size(1280, 720),
          builder: (context, _) => MaterialApp(
            localizationsDelegates:
                FlutterLocalization.instance.localizationsDelegates,
            supportedLocales: FlutterLocalization.instance.supportedLocales,
            home: Scaffold(
              body: RADashboardHub(
                logoutSelected: false,
                weekCardSelected: false,
                onDisconnectRequested: () {},
                onOwnedWeekGameSelected: (_) {},
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('No current Achievement of the Week'), findsOneWidget);
  });

  testWidgets('shows the mode-appropriate games beaten pill', (tester) async {
    final awards = RetroAchievementsUserAwards(
      totalAwardsCount: 0,
      hiddenAwardsCount: 0,
      masteryAwardsCount: 0,
      completionAwardsCount: 0,
      beatenHardcoreAwardsCount: 7,
      beatenCasualAwardsCount: 11,
      eventAwardsCount: 0,
      siteAwardsCount: 0,
      visibleUserAwards: [],
    );

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<RetroAchievementsProvider>.value(
            value: _DashboardProvider(null, awards: awards),
          ),
          ChangeNotifierProvider(create: (_) => RommProvider()),
        ],
        child: ScreenUtilInit(
          designSize: const Size(1280, 720),
          builder: (context, _) => MaterialApp(
            localizationsDelegates:
                FlutterLocalization.instance.localizationsDelegates,
            supportedLocales: FlutterLocalization.instance.supportedLocales,
            home: Scaffold(
              body: RADashboardHub(
                logoutSelected: false,
                weekCardSelected: false,
                onDisconnectRequested: () {},
                onOwnedWeekGameSelected: (_) {},
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('7 games beaten'), findsOneWidget);

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<RetroAchievementsProvider>.value(
            value: _DashboardProvider(null, casual: true, awards: awards),
          ),
          ChangeNotifierProvider(create: (_) => RommProvider()),
        ],
        child: ScreenUtilInit(
          designSize: const Size(1280, 720),
          builder: (context, _) => MaterialApp(
            localizationsDelegates:
                FlutterLocalization.instance.localizationsDelegates,
            supportedLocales: FlutterLocalization.instance.supportedLocales,
            home: Scaffold(
              body: RADashboardHub(
                logoutSelected: false,
                weekCardSelected: false,
                onDisconnectRequested: () {},
                onOwnedWeekGameSelected: (_) {},
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('11 games beaten'), findsOneWidget);
  });
}
