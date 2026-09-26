import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/l10n/app_locale.dart';
import 'package:neostation/models/retro_achievements_game_info.dart';
import 'package:neostation/models/retro_achievements_leaderboard.dart';
import 'package:neostation/providers/retro_achievements_provider.dart';
import 'package:neostation/screens/retro_achievements_screen/ra_game_achievements_page.dart';
import 'package:neostation/services/sfx_service.dart';
import 'package:neostation/themes/chrome_surface.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _PageProvider extends RetroAchievementsProvider {
  _PageProvider(this.info);

  final GameInfoAndUserProgress info;
  int gameLeaderboardCalls = 0;

  @override
  bool get isConnected => true;

  @override
  String get username => 'Player';

  @override
  Future<GameInfoAndUserProgress?> getGameInfoAndUserProgress(
    int gameId, {
    bool forceRefresh = false,
    String? md5Hash,
  }) async => info;

  @override
  Future<RaGameLeaderboardsPage?> getGameLeaderboards(
    int gameId, {
    int count = 100,
    int offset = 0,
  }) async {
    gameLeaderboardCalls++;
    return const RaGameLeaderboardsPage.empty();
  }

  @override
  Future<RaLeaderboardEntriesPage?> getLeaderboardEntries(
    int leaderboardId, {
    int count = 100,
    int offset = 0,
  }) async => const RaLeaderboardEntriesPage.empty();

  @override
  Future<RaUserGameLeaderboardsPage?> getUserGameLeaderboards(
    int gameId, {
    int count = 200,
    int offset = 0,
  }) async => const RaUserGameLeaderboardsPage.empty();
}

GameInfoAndUserProgress _info() => GameInfoAndUserProgress.fromJson({
  'ID': 42,
  'Title': 'Example Quest',
  'ConsoleName': 'NES',
  'ImageBoxArt': '',
  'NumAchievements': 3,
  'NumAwardedToUser': 2,
  'NumAwardedToUserHardcore': 1,
  'NumDistinctPlayersCasual': 100,
  'NumDistinctPlayersHardcore': 80,
  'GuideURL': 'https://example.test/guide',
  'Achievements': {
    '1': {
      'ID': 1,
      'Title': 'First',
      'Description': 'First description',
      'Points': 5,
      'BadgeName': '',
      'NumAwarded': 50,
      'NumAwardedHardcore': 40,
      'DisplayOrder': 2,
      'type': 'missable',
      'DateEarned': '2026-09-20 10:00:00',
    },
    '2': {
      'ID': 2,
      'Title': 'Second',
      'Description': 'Second description',
      'Points': 10,
      'BadgeName': '',
      'NumAwarded': 20,
      'NumAwardedHardcore': 10,
      'DisplayOrder': 1,
      'Type': 'progression',
      'DateEarnedHardcore': '2026-09-19 10:00:00',
    },
    '3': {
      'ID': 3,
      'Title': 'Third',
      'Description': 'Third description',
      'Points': 15,
      'BadgeName': '',
      'NumAwarded': 0,
      'NumAwardedHardcore': 0,
      'DisplayOrder': 3,
    },
  },
});

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    SfxService().setEnabled(false);
    await FlutterLocalization.instance.ensureInitialized();
    FlutterLocalization.instance.init(
      mapLocales: [MapLocale('en', AppLocale.en)],
      initLanguageCode: 'en',
    );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('xyz.luan/gamepads'),
          (call) async => <dynamic>[],
        );
  });

  testWidgets(
    'shows filter counts, overlap, rarity, guide, and lazy leaderboards',
    (tester) async {
      final provider = _PageProvider(_info());
      addTearDown(provider.dispose);

      await tester.pumpWidget(
        ChangeNotifierProvider<RetroAchievementsProvider>.value(
          value: provider,
          child: ScreenUtilInit(
            designSize: const Size(1280, 720),
            builder: (context, _) => MaterialApp(
              theme: ThemeData(extensions: [ChromeSurface.standard()]),
              localizationsDelegates:
                  FlutterLocalization.instance.localizationsDelegates,
              supportedLocales: FlutterLocalization.instance.supportedLocales,
              home: const RaGameAchievementsPage(gameId: 42),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();

      expect(find.text('3 / 3 Achievements'), findsOneWidget);
      expect(find.byTooltip('Guide'), findsOneWidget);
      expect(find.textContaining('Hardcore: 2026-09-19'), findsNothing);
      expect(find.byType(AlertDialog), findsNothing);
      expect(provider.gameLeaderboardCalls, 0);

      await tester.tap(find.text('First'));
      await tester.pump();
      expect(find.text('First'), findsOneWidget);
      expect(find.text('Third'), findsNothing);
      expect(find.textContaining('Casual: 2026-09-20'), findsOneWidget);
      expect(find.text('First description'), findsOneWidget);

      await tester.tap(find.text('Back'));
      await tester.pump();
      expect(find.text('Third'), findsOneWidget);

      await tester.tap(find.text('Leaderboards'));
      await tester.pump();
      await tester.pump();
      expect(provider.gameLeaderboardCalls, 1);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    },
  );
}
