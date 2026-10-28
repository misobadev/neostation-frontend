import 'package:flutter/material.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:neostation/constants/game_view_items.dart';
import 'package:neostation/l10n/app_locale.dart';
import 'package:neostation/models/config_model.dart';
import 'package:neostation/models/game_model.dart';
import 'package:neostation/providers/retro_achievements_provider.dart';
import 'package:neostation/providers/sqlite_config_provider.dart';
import 'package:neostation/themes/chrome_surface.dart';
import 'package:neostation/widgets/game_view_footer.dart';

/// The grid and carousel footer hides what its own view's options switched
/// off — and only that view's: hiding Play in the grid leaves the carousel's.
class _Config extends SqliteConfigProvider {
  _Config(this.hidden);

  final Set<String> hidden;

  @override
  ConfigModel get config => super.config.copyWith(gameViewHiddenItems: hidden);
}

class _RaProvider extends RetroAchievementsProvider {
  @override
  bool get isConnected => false;
}

GameModel _game() => GameModel(
  romname: 'Sonic The Hedgehog (USA).gg',
  realname: 'Sonic The Hedgehog',
  name: 'Sonic The Hedgehog',
  year: '',
  developer: '',
  publisher: '',
  genre: '',
  players: '',
  rating: 16,
  playTime: 3671,
  showRomFileNameSubtitle: true,
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
    required String view,
    Set<String> hidden = const {},
  }) async {
    tester.view.physicalSize = const Size(1280, 720);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<RetroAchievementsProvider>(
            create: (_) => _RaProvider(),
          ),
          ChangeNotifierProvider<SqliteConfigProvider>(
            create: (_) => _Config(hidden),
          ),
        ],
        child: ScreenUtilInit(
          designSize: const Size(1280, 720),
          builder: (context, _) => MaterialApp(
            theme: ThemeData(extensions: [ChromeSurface.standard()]),
            localizationsDelegates:
                FlutterLocalization.instance.localizationsDelegates,
            supportedLocales: FlutterLocalization.instance.supportedLocales,
            home: Scaffold(
              body: SizedBox(
                width: 1280,
                child: GameViewFooter(game: _game(), onPlay: () {}, view: view),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  final itemFinders = <String, Finder Function()>{
    GameViewItem.fileName: () => find.text('Sonic The Hedgehog (USA).gg'),
    GameViewItem.playTime: () => find.byIcon(Symbols.schedule_rounded),
    GameViewItem.rating: () => find.byIcon(Symbols.star_rounded),
    GameViewItem.play: () =>
        find.text(AppLocale.en[AppLocale.playButton]! as String),
  };

  for (final view in [GameViewItem.grid, GameViewItem.carousel]) {
    for (final item in itemFinders.keys) {
      testWidgets('$view: hiding $item takes away only $item', (tester) async {
        await pumpFooter(tester, view: view, hidden: {'$view.$item'});
        expect(itemFinders[item]!(), findsNothing);
        for (final other in itemFinders.keys.where((o) => o != item)) {
          expect(itemFinders[other]!(), findsWidgets, reason: other);
        }
        expect(tester.takeException(), isNull);
      });
    }
  }

  testWidgets('another view\'s choices do not apply', (tester) async {
    await pumpFooter(
      tester,
      view: GameViewItem.carousel,
      hidden: {'grid.play', 'list.rating'},
    );
    for (final finder in itemFinders.values) {
      expect(finder(), findsWidgets);
    }
  });
}
