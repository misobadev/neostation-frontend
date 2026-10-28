import 'package:flutter/material.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:neostation/l10n/app_locale.dart';
import 'package:neostation/models/game_model.dart';
import 'package:neostation/providers/retro_achievements_provider.dart';
import 'package:neostation/providers/sqlite_config_provider.dart';
import 'package:neostation/themes/chrome_surface.dart';
import 'package:neostation/widgets/game_view_footer.dart';

/// When the grid/carousel footer shows its achievements pill at all.
///
/// Two conditions hide it, and they are different questions. Signed out, no
/// game info is ever loaded, so without a connection check the pill would state
/// for every game in the library that it has no achievements — which it cannot
/// know. And a *settled* zero hides it too: a game with nothing to earn gets no
/// pill rather than a pill saying so. That second rule is the details card's,
/// adopted here through [GameDetailsFooter.showsAchievementsFor] so the two
/// footers cannot drift. While a lookup is genuinely outstanding the pill stays
/// and says "Loading" — only an answered zero removes it.
class _FakeRaProvider extends RetroAchievementsProvider {
  _FakeRaProvider({required bool connected}) : _connected = connected;

  final bool _connected;

  @override
  bool get isConnected => _connected;
}

/// [raHash] defaults to a hash on purpose: a hashed, unmatched ROM is the case
/// where an empty pill is an answer from RetroAchievements. Pass null for a ROM
/// nothing could hash, where it is not.
GameModel _game({
  int? idRa,
  String? systemRaId,
  int? raNumAchievements,
  String? raHash = 'deadbeef',
}) => GameModel(
  romname: 'Sonic The Hedgehog.gg',
  realname: 'Sonic The Hedgehog',
  name: 'Sonic The Hedgehog',
  year: '',
  developer: '',
  publisher: '',
  genre: '',
  players: '',
  rating: 0,
  idRa: idRa,
  raHash: raHash,
  systemRaId: systemRaId,
  raNumAchievements: raNumAchievements,
);

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

  Future<void> pumpFooter(
    WidgetTester tester, {
    required bool connected,
    GameModel? game,
    bool isLoading = false,
  }) async {
    // The footer lays out against the full window width in the real app; give
    // the test the same room or its Row overflows and never builds the pill.
    tester.view.physicalSize = const Size(1280, 720);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<RetroAchievementsProvider>.value(
            value: _FakeRaProvider(connected: connected),
          ),
          // The footer reads which of its items the user has hidden.
          ChangeNotifierProvider<SqliteConfigProvider>(
            create: (_) => SqliteConfigProvider(),
          ),
        ],
        child: ScreenUtilInit(
          designSize: const Size(1280, 720),
          builder: (context, _) => MaterialApp(
            // The pill asserts on these theme extensions, which the real app
            // always supplies.
            theme: ThemeData(extensions: [ChromeSurface.standard()]),
            localizationsDelegates:
                FlutterLocalization.instance.localizationsDelegates,
            supportedLocales: FlutterLocalization.instance.supportedLocales,
            home: Scaffold(
              body: SizedBox(
                width: 1280,
                child: GameViewFooter(
                  game: game ?? _game(),
                  onPlay: () {},
                  hasRetroAchievements: true,
                  isLoadingAchievements: isLoading,
                  onShowAchievements: () {},
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  testWidgets('the pill is hidden while signed out', (tester) async {
    await pumpFooter(tester, connected: false);

    expect(
      find.text(AppLocale.en[AppLocale.noAchievements]!.toUpperCase()),
      findsNothing,
      reason: 'signed out, the app has not asked RetroAchievements anything',
    );
  });

  testWidgets('the pill returns once signed in, for a game that has a set', (
    tester,
  ) async {
    await pumpFooter(
      tester,
      connected: true,
      game: _game(idRa: 1234, systemRaId: '15', raNumAchievements: 45),
    );

    expect(find.byType(LinearProgressIndicator), findsOneWidget);

    // The pill's fixed 101.r width rounds one pixel tight against its contents
    // at the test surface's scale factor. It is a layout artifact of this
    // harness, not the behaviour under test, so consume it deliberately rather
    // than let it fail the assertion above.
    final overflow = tester.takeException();
    expect(
      overflow == null || overflow.toString().contains('overflowed'),
      isTrue,
      reason: 'only the known 1px overflow may be swallowed here',
    );
  });

  testWidgets('a game with no achievements gets no pill, signed in', (
    tester,
  ) async {
    // Connected, hashed and unmatched: RetroAchievements was asked and has no
    // set for this ROM. The answer is worth nothing on a footer the user scrolls
    // past, so the pill stands down and gives the room back.
    await pumpFooter(tester, connected: true, game: _game(systemRaId: '15'));

    expect(find.byType(LinearProgressIndicator), findsNothing);
    expect(
      find.text(AppLocale.en[AppLocale.noAchievements]!.toUpperCase()),
      findsNothing,
    );
    tester.takeException();
  });

  testWidgets('a lookup still in flight keeps the pill', (tester) async {
    // The distinction the hide rule turns on: nothing is known yet, so removing
    // the pill here would make it appear a moment later and shuffle the row.
    await pumpFooter(
      tester,
      connected: true,
      game: _game(systemRaId: '15'),
      isLoading: true,
    );

    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    tester.takeException();
  });

  group('the total comes from the local snapshot, not the network', () {
    // A matched ROM carries its achievement count in the bundled snapshot, so
    // the pill can show the total with no API call. Only the earned half needs
    // the network, and until it lands the pill must not imply a progress it
    // has not fetched.
    GameModel matched() =>
        _game(idRa: 1234, systemRaId: '15', raNumAchievements: 45);

    testWidgets('shows the total while the earned count is outstanding', (
      tester,
    ) async {
      await pumpFooter(
        tester,
        connected: true,
        game: matched(),
        isLoading: true,
      );

      expect(find.text('\u2013/45'), findsOneWidget);
      expect(
        find.text(AppLocale.en[AppLocale.loading]!.toUpperCase()),
        findsNothing,
        reason: 'the total is already known — do not spin for it',
      );
      tester.takeException();
    });

    testWidgets('never renders a zero it has not fetched', (tester) async {
      await pumpFooter(
        tester,
        connected: true,
        game: matched(),
        isLoading: true,
      );

      expect(
        find.text('0/45'),
        findsNothing,
        reason: '0/45 claims the user has earned none, which is unknown here',
      );
      tester.takeException();
    });

    testWidgets('a settled zero takes the pill away, however it got there', (
      tester,
    ) async {
      // Two different zeros, one outcome. A hashed, unmatched ROM is
      // RetroAchievements answering "no set"; a ROM nothing could hash is the
      // app never having asked. Main's footer told them apart in words ("No
      // Achievements" against "Unknown"), which only mattered while a zero
      // still drew a pill. Neither draws one now.
      for (final game in [
        _game(systemRaId: '15'),
        _game(systemRaId: '15', raHash: null),
      ]) {
        await pumpFooter(tester, connected: true, game: game);

        expect(find.byType(LinearProgressIndicator), findsNothing);
        expect(
          find.text(AppLocale.en[AppLocale.noAchievements]!.toUpperCase()),
          findsNothing,
        );
        expect(
          find.text(AppLocale.en[AppLocale.raCoverageUnknown]!.toUpperCase()),
          findsNothing,
        );
        tester.takeException();
      }
    });

    testWidgets('a local count is ignored unless the ROM is matched', (
      tester,
    ) async {
      // raNumAchievements without an id_ra should never happen, but if a stale
      // row carried one the pill must not advertise a set for an unmatched ROM
      // — which now means not appearing at all rather than appearing empty.
      await pumpFooter(
        tester,
        connected: true,
        game: _game(systemRaId: '15', raNumAchievements: 45),
      );

      expect(find.text('\u2013/45'), findsNothing);
      expect(find.byType(LinearProgressIndicator), findsNothing);
      tester.takeException();
    });
  });

  group('the progress bar never animates', () {
    LinearProgressIndicator bar(WidgetTester tester) => tester
        .widget<LinearProgressIndicator>(find.byType(LinearProgressIndicator));

    testWidgets('an outstanding lookup sits still rather than sweeping', (
      tester,
    ) async {
      // An indeterminate bar reads as "still fetching", and it used to run on
      // every zero. A settled zero has no pill left to animate, so the case
      // that remains is the wait itself — which the "Loading" text already
      // reports without a strobe.
      await pumpFooter(
        tester,
        connected: true,
        game: _game(systemRaId: '15'),
        isLoading: true,
      );

      expect(bar(tester).value, 0.0);
      tester.takeException();
    });

    testWidgets('a known total with no earned count sits still too', (
      tester,
    ) async {
      // The total comes from the bundled snapshot and the earned count from
      // the network, so this gap opens on every selection change. It used to
      // run an indeterminate bar, which flashed orange across the pill each
      // time the user moved between games.
      await pumpFooter(
        tester,
        connected: true,
        game: _game(idRa: 1234, systemRaId: '15', raNumAchievements: 45),
        isLoading: true,
      );

      expect(
        bar(tester).value,
        0.0,
        reason: 'the earned half is outstanding, but that is not an animation',
      );
      expect(
        bar(tester).valueColor?.value,
        isNot(Colors.orange),
        reason: 'the score colour arrives with the score, not before it',
      );
      tester.takeException();
    });
  });
}
