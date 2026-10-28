import 'package:flutter/material.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:neostation/constants/game_view_items.dart';
import 'package:neostation/l10n/app_locale.dart';
import 'package:neostation/models/game_model.dart';
import 'package:neostation/models/system_model.dart';
import 'package:neostation/providers/retro_achievements_provider.dart';
import 'package:neostation/services/sfx_service.dart';
import 'package:neostation/screens/game_screen/game_details_card/widgets/game_details_footer.dart';
import 'package:neostation/themes/chrome_surface.dart';

/// Every item on the list view's details footer, and the play-time clock and
/// file name above it, can be switched off from the list view's options. Hiding one takes only that item away, the row keeps its
/// height, and whatever is left still lays out without overflowing — down to
/// a footer with nothing on it at all.
class _RaProvider extends RetroAchievementsProvider {
  _RaProvider(this._connected);

  final bool _connected;

  @override
  bool get isConnected => _connected;
}

SystemModel _system() => const SystemModel(
  folderName: 'psx',
  realName: 'Sony PlayStation',
  iconImage: '',
  color: '#FFFFFF',
);

GameModel _game({
  double rating = 18.0,
  int? playTime = 3671,
  bool isFavorite = false,
  bool showRomFileNameSubtitle = true,
}) => GameModel(
  romname: 'A Game (USA).chd',
  realname: 'A Game',
  name: 'A Game',
  year: '1999',
  developer: '',
  publisher: 'Sony',
  genre: 'RPG',
  players: '1',
  rating: rating,
  playTime: playTime,
  isFavorite: isFavorite,
  showRomFileNameSubtitle: showRomFileNameSubtitle,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    // No audio engine in a widget test, and every control on this row plays a
    // sound on tap.
    SfxService().setEnabled(false);
    await FlutterLocalization.instance.ensureInitialized();
    FlutterLocalization.instance.init(
      mapLocales: [MapLocale('en', AppLocale.en)],
      initLanguageCode: 'en',
    );
  });

  late List<String> pressed;

  setUp(() => pressed = <String>[]);

  Future<void> pumpFooter(
    WidgetTester tester, {
    GameModel? game,
    bool showsPill = false,
    bool canRandom = true,
    double width = 640,
    Set<String> hidden = const {},
  }) async {
    tester.view.physicalSize = const Size(1280, 720);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      ChangeNotifierProvider<RetroAchievementsProvider>.value(
        value: _RaProvider(showsPill),
        child: ScreenUtilInit(
          designSize: const Size(1280, 720),
          builder: (context, _) => MaterialApp(
            theme: ThemeData(
              brightness: Brightness.dark,
              extensions: [ChromeSurface.standard()],
            ),
            localizationsDelegates:
                FlutterLocalization.instance.localizationsDelegates,
            supportedLocales: FlutterLocalization.instance.supportedLocales,
            home: Scaffold(
              body: Align(
                alignment: Alignment.topLeft,
                child: SizedBox(
                  width: width,
                  height: 360,
                  child: Stack(
                    children: [
                      GameDetailsFooter(
                        system: _system(),
                        game: game ?? _game(),
                        isMusicSystem: false,
                        hasScreenScraper: false,
                        isSecondaryScreenActive: false,
                        onShowAchievements: () {},
                        onShowGameInfo: () => pressed.add('gameInfo'),
                        hasRetroAchievements: showsPill,
                        // Loading is the cheapest state that makes the pill
                        // render without a fixture of achievement data.
                        isLoadingAchievements: showsPill,
                        onPlayGame: () => pressed.add('play'),
                        onShowRandomGame: canRandom
                            ? () => pressed.add('random')
                            : null,
                        onToggleFavorite: () => pressed.add('favorite'),
                        onOpenGameSettings: () => pressed.add('settings'),
                        hiddenItems: hidden,
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
    await tester.pump();
  }

  /// What each item looks like on the footer.
  final itemFinders = <String, Finder Function()>{
    GameViewItem.fileName: () => find.text('A Game (USA).chd'),
    GameViewItem.playTime: () => find.byIcon(Symbols.schedule_rounded),
    GameViewItem.rating: () => find.byIcon(Symbols.star_rounded),
    GameViewItem.random: () => find.byIcon(Symbols.casino_rounded),
    GameViewItem.favorite: () => find.byIcon(Symbols.favorite_rounded),
    GameViewItem.settings: () => find.byIcon(Symbols.settings_rounded),
    GameViewItem.play: () =>
        find.text(AppLocale.en[AppLocale.playButton]! as String),
  };

  testWidgets('everything shows by default', (tester) async {
    await pumpFooter(tester);
    for (final entry in itemFinders.entries) {
      expect(entry.value(), findsWidgets, reason: entry.key);
    }
  });

  for (final item in itemFinders.keys) {
    testWidgets('hiding $item takes away only $item', (tester) async {
      await pumpFooter(tester, hidden: {item});
      expect(itemFinders[item]!(), findsNothing, reason: item);
      for (final other in itemFinders.keys.where((o) => o != item)) {
        expect(itemFinders[other]!(), findsWidgets, reason: other);
      }
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('the achievements pill can be hidden', (tester) async {
    final pill = find.byIcon(Symbols.emoji_events_rounded);
    await pumpFooter(tester, showsPill: true);
    expect(pill, findsWidgets);

    await pumpFooter(
      tester,
      showsPill: true,
      hidden: {GameViewItem.achievements},
    );
    expect(pill, findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a footer with everything hidden still lays out', (tester) async {
    await pumpFooter(
      tester,
      showsPill: true,
      hidden: GameViewItem.itemsFor[GameViewItem.list]!.toSet(),
      width: 435, // the handheld card's own width
    );
    expect(tester.takeException(), isNull);
    for (final finder in itemFinders.values) {
      expect(finder(), findsNothing);
    }
  });

  testWidgets('the row keeps its height whatever is hidden', (tester) async {
    await pumpFooter(tester);
    final full = tester.getRect(find.byType(ExcludeFocus)).height;
    await pumpFooter(
      tester,
      hidden: GameViewItem.itemsFor[GameViewItem.list]!.toSet(),
    );
    expect(tester.getRect(find.byType(ExcludeFocus)).height, full);
  });
}
