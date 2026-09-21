import 'package:flutter/material.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/l10n/app_locale.dart';
import 'package:neostation/models/game_model.dart';
import 'package:neostation/models/system_model.dart';
import 'package:neostation/providers/file_provider.dart';
import 'package:neostation/providers/sqlite_config_provider.dart';
import 'package:neostation/screens/game_screen/game_details_card/tabs/game_details_game_info_tab.dart';
import 'package:neostation/services/sfx_service.dart';
import 'package:neostation/themes/chrome_surface.dart';
import 'package:neostation/themes/corner_radii.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// An unscraped game's info panel shows an "Incomplete Metadata" notice above
/// the game's name and ROM filename. On a short landscape phone the room
/// between the header and that identity footer is less than the notice needs,
/// and the notice (a centred column) used to spill out over the footer, so the
/// explanation was drawn straight across the name and filename.
final _system = SystemModel(
  id: 'atari7800',
  folderName: 'atari7800',
  realName: 'Atari 7800',
  iconImage: '',
  color: '#ff006a',
);

final _game = GameModel(
  romname: 'Mario Bros. (1988) (Atari).a78',
  realname: 'Mario Bros.',
  name: 'Mario Bros.',
  year: '',
  developer: '',
  publisher: '',
  genre: '',
  players: '',
  rating: 0,
  romPath: '/roms/atari7800/Mario Bros. (1988) (Atari).a78',
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
    SfxService().setEnabled(false);
  });

  Future<void> mountPanel(
    WidgetTester tester, {
    required Size screen,
    required double cardHeight,
  }) async {
    tester.view.physicalSize = screen;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      ChangeNotifierProvider<SqliteConfigProvider>(
        create: (_) => SqliteConfigProvider(),
        child: ScreenUtilInit(
          designSize: const Size(640, 480),
          builder: (context, child) => MaterialApp(
            localizationsDelegates:
                FlutterLocalization.instance.localizationsDelegates,
            supportedLocales: FlutterLocalization.instance.supportedLocales,
            theme: ThemeData(
              extensions: [ChromeSurface.standard(), CornerRadii.m()],
            ),
            home: Scaffold(
              body: Align(
                alignment: Alignment.topLeft,
                child: SizedBox(
                  width: screen.width * 0.65,
                  height: cardHeight,
                  child: Stack(
                    children: [
                      GameDetailsGameInfoTab(
                        system: _system,
                        game: _game,
                        fileProvider: FileProvider(),
                        description: '',
                        isScrapingGame: false,
                        onScrapeGame: () {},
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 300));
  }

  Rect notice(WidgetTester tester) => tester
      .getRect(find.text(AppLocale.en[AppLocale.incompleteMetadata]! as String))
      .expandToInclude(
        tester.getRect(
          find.text(AppLocale.en[AppLocale.scrapeToDownload]! as String),
        ),
      );

  for (final (label, screen, cardHeight) in [
    ('a landscape phone', const Size(890, 400), 300.0),
    ('a handheld', const Size(1920, 1080), 1000.0),
  ]) {
    testWidgets('the notice stays clear of the name and filename on $label', (
      tester,
    ) async {
      await mountPanel(tester, screen: screen, cardHeight: cardHeight);

      final name = tester.getRect(find.text('Mario Bros.'));
      final file = tester.getRect(find.text(_game.romname));
      final shown = notice(tester);

      expect(tester.takeException(), isNull);
      expect(shown.bottom, lessThanOrEqualTo(name.top));
      expect(shown.overlaps(file), isFalse);
    });
  }
}
