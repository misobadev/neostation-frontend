import 'package:flutter/material.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:neostation/l10n/app_locale.dart';
import 'package:neostation/models/retro_achievements_leaderboard.dart';
import 'package:neostation/screens/game_screen/game_details_card/tabs/game_details_leaderboards_tab.dart';
import 'package:neostation/services/sfx_service.dart';
import 'package:neostation/themes/chrome_surface.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    // SoLoud's native library is unavailable to the Flutter test host.
    SfxService().setEnabled(false);
    await FlutterLocalization.instance.ensureInitialized();
    FlutterLocalization.instance.init(
      mapLocales: [MapLocale('en', AppLocale.en)],
      initLanguageCode: 'en',
    );
  });

  Future<void> pumpPanel(
    WidgetTester tester, {
    required bool connected,
    GlobalKey<GameDetailsLeaderboardsTabState>? key,
    RaLoadGameLeaderboards? loadGameLeaderboards,
    RaLoadLeaderboardEntries? loadLeaderboardEntries,
    RaLoadUserGameLeaderboards? loadUserGameLeaderboards,
  }) async {
    tester.view.physicalSize = const Size(1280, 720);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      ScreenUtilInit(
        designSize: const Size(1280, 720),
        builder: (context, _) => MaterialApp(
          theme: ThemeData(extensions: [ChromeSurface.standard()]),
          localizationsDelegates:
              FlutterLocalization.instance.localizationsDelegates,
          supportedLocales: FlutterLocalization.instance.supportedLocales,
          home: Scaffold(
            body: Stack(
              children: [
                GameDetailsLeaderboardsTab(
                  key: key,
                  gameId: 14402,
                  isConnected: connected,
                  loadGameLeaderboards:
                      loadGameLeaderboards ??
                      (_) async => const RaGameLeaderboardsPage(
                        count: 0,
                        total: 0,
                        results: [],
                      ),
                  loadLeaderboardEntries:
                      loadLeaderboardEntries ??
                      (_, {required count, required offset}) async =>
                          const RaLeaderboardEntriesPage(
                            count: 0,
                            total: 0,
                            results: [],
                          ),
                  loadUserGameLeaderboards:
                      loadUserGameLeaderboards ??
                      (_) async => const RaUserGameLeaderboardsPage(
                        count: 0,
                        total: 0,
                        results: [],
                      ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  RaGameLeaderboard leaderboard() => const RaGameLeaderboard(
    id: 104370,
    rankAsc: false,
    title: 'South Island Conqueror',
    description: 'Finish with the highest score',
    format: 'VALUE',
    author: 'Scott',
    authorUlid: 'author-ulid',
    topEntry: RaLeaderboardTopEntry(
      user: 'vani11a',
      ulid: 'top-ulid',
      score: 390490,
      formattedScore: '390,490',
    ),
  );

  testWidgets('signed-out users see the localized sign-in prompt', (
    tester,
  ) async {
    await pumpPanel(tester, connected: false);

    expect(
      find.text(AppLocale.en[AppLocale.raLeaderboardSignIn]!),
      findsOneWidget,
    );
  });

  testWidgets('opens entries and highlights the signed-in user', (
    tester,
  ) async {
    final key = GlobalKey<GameDetailsLeaderboardsTabState>();
    await pumpPanel(
      tester,
      connected: true,
      key: key,
      loadGameLeaderboards: (_) async =>
          RaGameLeaderboardsPage(count: 1, total: 1, results: [leaderboard()]),
      loadUserGameLeaderboards: (_) async => const RaUserGameLeaderboardsPage(
        count: 1,
        total: 1,
        results: [
          RaUserGameLeaderboardEntry(
            id: 104370,
            rankAsc: false,
            title: 'South Island Conqueror',
            description: 'Finish with the highest score',
            format: 'VALUE',
            userEntry: RaLeaderboardEntry(
              rank: 9,
              user: 'me',
              ulid: 'my-ulid',
              score: 120,
              formattedScore: '120',
              dateSubmitted: null,
            ),
          ),
        ],
      ),
      loadLeaderboardEntries: (_, {required count, required offset}) async =>
          const RaLeaderboardEntriesPage(
            count: 1,
            total: 1,
            results: [
              RaLeaderboardEntry(
                rank: 1,
                user: 'vani11a',
                ulid: 'top-ulid',
                score: 390490,
                formattedScore: '390,490',
                dateSubmitted: null,
              ),
            ],
          ),
    );
    await tester.pumpAndSettle();

    expect(find.text('South Island Conqueror'), findsOneWidget);
    expect(find.textContaining('390,490'), findsOneWidget);

    expect(key.currentState!.enterPanel(), isTrue);
    expect(key.currentState!.activateFocused(), isTrue);
    await tester.pumpAndSettle();

    expect(find.text('me'), findsOneWidget);
    expect(
      find.text(AppLocale.en[AppLocale.raLeaderboardYourEntry]!),
      findsOneWidget,
    );
    expect(key.currentState!.exitPanel(), isTrue);
    await tester.pump();
    expect(
      find.text(AppLocale.en[AppLocale.raSubtabLeaderboards]!),
      findsOneWidget,
    );
  });
}
