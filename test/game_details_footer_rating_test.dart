import 'package:flutter/material.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:neostation/l10n/app_locale.dart';
import 'package:neostation/models/game_model.dart';
import 'package:neostation/models/system_model.dart';
import 'package:neostation/providers/retro_achievements_provider.dart';
import 'package:neostation/services/sfx_service.dart';
import 'package:neostation/screens/game_screen/game_details_card/widgets/game_details_footer.dart';
import 'package:neostation/themes/chrome_surface.dart';
import 'package:neostation/widgets/neo_glass.dart';

/// The details card's footer is one row: the readouts on the left, the
/// controls on the right, and nothing above it.
///
/// It got there by losing two text lines. The metadata strip (players,
/// publisher, year, genre) was painting scraped facts onto the game's fanart
/// that the info tab is the place for; the cloud-sync glyph that rode at the
/// end of that line spent a while as a chip in this row and now lives on the
/// game list's own selected row, which is where the selection it reports on
/// actually is. The ROM filename came back from that cull — it is the one
/// identity fact the list row does not carry — but on the play-time clock's
/// line rather than one of its own. What is left is pinned here because each
/// piece has been moved before:
///
///  * The score has been in five places — a pill in this row, a segment of
///    the metadata marquee (where a long publisher could scroll it out of
///    sight), a bare readout on the artwork, a chip back in the row, and once
///    a bare slot again when the chip's width was wanted for the achievements
///    pill. The width was real; the look was worse. The chip stayed and the
///    width came off the row's other side, when the cloud glyph left it.
///  * PLAY was removed as a third route to something A and a double tap
///    already did. It is back because the rail that carried every *other*
///    touch affordance was removed too, which left touch with one pressable
///    thing in the whole view.
///  * The row's height is the load-bearing claim: it no longer depends on what
///    the selected game carries, so nothing in the footer moves as the cursor
///    walks a list of scraped and unscraped, matched and unmatched games.
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

  /// The details card's own width, not the screen's. On a 1920-wide handheld
  /// the sidebar takes the first third, which leaves the card ~435 of the
  /// footer's design units -- the width the row actually has to fit in.
  const double handheldCardWidth = 435;

  /// The score's own number.
  ///
  /// The play-time clock above the row lays every character in its own [Text],
  /// so a bare `find.text('1')` matches its digits as well — this scopes the
  /// search to the chip the star is in.
  Finder scoreText(String number) => find.descendant(
    of: find
        .ancestor(
          of: find.byIcon(Symbols.star_rounded),
          matching: find.byWidgetPredicate(
            (w) => w is NeoGlass || (w is Container && w.decoration != null),
          ),
        )
        .first,
    matching: find.text(number),
  );

  Future<void> pumpFooter(
    WidgetTester tester, {
    GameModel? game,
    bool showsPill = false,
    bool canRandom = true,
    double width = 640,
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

  testWidgets('the scraped facts are not on the footer at all', (tester) async {
    await pumpFooter(tester);

    // Publisher, year and genre belong to the info tab now; painting them on
    // the artwork here was the duplicate. The filename is the exception: it is
    // the one identity fact neither the info tab's strip nor the list row
    // beside the card carries, so it is back on the clock's line.
    expect(find.text('Sony'), findsNothing);
    expect(find.text('1999'), findsNothing);
    expect(find.text('RPG'), findsNothing);
    expect(find.text('A Game (USA).chd'), findsOneWidget);
  });

  testWidgets('the filename shares the clock line, name left and clock right', (
    tester,
  ) async {
    // One line for both: the reading is a fixed, short block that wants the
    // right edge and the name is the variable-width thing, so the name takes
    // whatever the clock leaves rather than claiming a second line.
    await pumpFooter(tester, game: _game(playTime: 3671), width: 640);

    final name = tester.getRect(find.text('A Game (USA).chd'));
    final clock = tester.getRect(find.byIcon(Symbols.schedule_rounded));

    expect(name.right, lessThanOrEqualTo(clock.left), reason: 'name left');
    expect(
      name.center.dy,
      moreOrLessEquals(clock.center.dy, epsilon: 2.0),
      reason: 'one line, not stacked',
    );
    expect(
      clock.bottom,
      lessThanOrEqualTo(tester.getRect(find.byType(ExcludeFocus)).top),
      reason: 'still above the controls row',
    );
  });

  testWidgets('an unscraped game leaves the clock its line', (tester) async {
    // `showRomFileNameSubtitle` is set only where the display name came from
    // somewhere other than the filename; a filename under a name derived from
    // that same filename says nothing, so there is nothing to render and the
    // line is unchanged in height either way.
    await pumpFooter(tester, game: _game(showRomFileNameSubtitle: false));

    expect(find.text('A Game (USA).chd'), findsNothing);
    expect(find.byIcon(Symbols.schedule_rounded), findsOneWidget);
  });

  testWidgets('the score is a whole number, rounded up', (tester) async {
    // The decimal cost the chip a character it had to reserve on every game,
    // and the chip is fixed-width, so that reservation came off the
    // achievements pill beside it. The half point lives in the colour ramp.
    await pumpFooter(tester, game: _game(rating: 17.0));
    expect(scoreText('9'), findsOneWidget);
    expect(find.text('8.5'), findsNothing);

    await pumpFooter(tester, game: _game(rating: 16.0));
    expect(scoreText('8'), findsOneWidget);

    // Rounded up, not to nearest: a game that scored at all never reads "0".
    await pumpFooter(tester, game: _game(rating: 1.0));
    expect(scoreText('1'), findsOneWidget);
  });

  testWidgets('the score leads the row and the controls close it', (
    tester,
  ) async {
    await pumpFooter(tester, showsPill: true);

    final star = tester.getRect(find.byIcon(Symbols.star_rounded));
    final trophy = tester.getRect(find.byIcon(Symbols.emoji_events_rounded));
    final heart = tester.getRect(find.byIcon(Symbols.favorite_rounded));
    final play = tester.getRect(find.text('PLAY'));

    expect(star.right, lessThanOrEqualTo(trophy.left));
    expect(trophy.right, lessThanOrEqualTo(heart.left));
    expect(heart.right, lessThanOrEqualTo(play.left));

    // One row: everything on it shares a centre line.
    for (final other in [trophy, heart, play]) {
      expect(
        star.center.dy,
        moreOrLessEquals(other.center.dy, epsilon: 2.0),
        reason: 'one row, not a stack',
      );
    }
  });

  testWidgets('the play-time clock is above the row, not on it', (
    tester,
  ) async {
    // It was on the row once, and that is the era the achievements pill beside
    // it rendered seven pixels wide: the reading is 96 to 112 units and the
    // row's spare on the handheld card is about 46. The line above costs the
    // row nothing, because the row's budget is horizontal and a line is not.
    await pumpFooter(tester, game: _game(playTime: 3671), width: 640);

    final clock = find.byIcon(Symbols.schedule_rounded);
    expect(clock, findsOneWidget);

    // A gap, not just "not overlapping". The clock and PLAY are both at the
    // right margin, so with the two lines butted together the reading sat on
    // the button's top edge and read as hanging off it — and the shadow under
    // the digits closed most of what little space there was.
    expect(
      tester.getRect(find.byType(ExcludeFocus)).top -
          tester.getRect(clock).bottom,
      greaterThanOrEqualTo(4.0),
      reason: 'above the row with air between, not sitting on PLAY',
    );
  });

  testWidgets('the clock line is reserved even for an unplayed game', (
    tester,
  ) async {
    // The footer's height is what every panel above it is positioned off, so a
    // line that came and went with the selected game would move the panels as
    // the cursor walked the list.
    await pumpFooter(tester, game: _game(playTime: 3671));
    final played = tester.getSize(find.byType(GameDetailsFooter));

    await pumpFooter(tester, game: _game(playTime: null));
    expect(find.byIcon(Symbols.schedule_rounded), findsNothing);
    expect(
      tester.getSize(find.byType(GameDetailsFooter)).height,
      played.height,
    );
  });

  testWidgets('the icon buttons are circles and PLAY is not', (tester) async {
    // Everything on the row wears the same chip, fully rounded, so the square
    // controls come out as circles and the wider ones as stadiums -- that is
    // what makes the row read as one set rather than a strip of tiles, and it
    // does not follow the theme's corner style to get there: that is for
    // panels and cards. PLAY keeps the theme's corner precisely so it stays
    // out of the set; it is the row's primary action, not one more chip in it.
    await pumpFooter(tester, showsPill: true);

    for (final finder in [
      // The score chip, by the star inside it.
      find.byIcon(Symbols.star_rounded),
      find.byIcon(Symbols.casino_rounded),
      find.byIcon(Symbols.favorite_rounded),
      find.byIcon(Symbols.settings_rounded),
    ]) {
      final chip = _decoratedAncestor(tester, finder);
      expect(
        _radiusOf(chip),
        greaterThanOrEqualTo(chip.size!.height / 2),
        reason: 'fully rounded, not a rounded square',
      );
    }

    final play = _decoratedAncestor(tester, find.text('PLAY'));
    expect(
      _radiusOf(play),
      lessThan(play.size!.height / 2),
      reason: 'squarer than the chips beside it, not a stadium',
    );
  });

  testWidgets('the score wears the same chip as the controls', (tester) async {
    // A row of chips with one bare readout floating at its head did not read
    // as "that one is not pressable", it read as unfinished — and the chip it
    // got back is pressable, so the row now means one thing by a chip.
    //
    // Taking it off was tried, for the width: the chip is 10 units of padding
    // and a hand-swept reservation, all of it charged to the achievements pill.
    // The width came off the cloud glyph instead, which left the row entirely.
    await pumpFooter(tester);

    final score = _decoratedAncestor(tester, find.byIcon(Symbols.star_rounded));
    final gear = _decoratedAncestor(
      tester,
      find.byIcon(Symbols.settings_rounded),
    );

    expect(score.widget, isA<NeoGlass>());
    expect(gear.widget, isA<NeoGlass>());
    expect(
      (score.widget as NeoGlass).cornerRadius,
      (gear.widget as NeoGlass).cornerRadius,
      reason: 'the score wears the same chip as the controls',
    );
    expect(score.size!.height, gear.size!.height);
  });

  testWidgets('the pill keeps a usable share on a handheld-sized card', (
    tester,
  ) async {
    // The bug this pins: the pill is the row's only Expanded, so it is handed
    // whatever the fixed items leave and has no floor of its own. On the Thor
    // those items came to more than the card was wide, and the pill rendered
    // 7px across -- full height, right shape, none of its contents, and no
    // overflow banner to say so. Sizing the row is what buys the share back,
    // so the budget has to be pinned at the width it broke on.
    await pumpFooter(tester, showsPill: true, width: handheldCardWidth);

    expect(find.byIcon(Symbols.emoji_events_rounded), findsOneWidget);

    final pill = _decoratedAncestor(
      tester,
      find.byIcon(Symbols.emoji_events_rounded),
    );
    expect(
      pill.size!.width,
      greaterThanOrEqualTo(64.0),
      reason: 'the icon, the count and a bar with somewhere to fill',
    );
  });

  testWidgets('a wide card does not stretch the pill across it', (
    tester,
  ) async {
    // The pill is the row's only Expanded, which is what let it be starved to
    // seven pixels on a narrow card and would let it run on for half a wide
    // one. It carries an icon, a short count and a bar; past a point more
    // width is just a longer bar.
    //
    // The handheld card no longer reaches the cap — the row grew and the score
    // took its chip back, so what is left there is under it. The cap is
    // asserted where it binds, from 640 up.
    final widths = <double>{};
    for (final card in [640.0, 900.0, 1200.0]) {
      await pumpFooter(tester, showsPill: true, width: card);
      widths.add(
        _decoratedAncestor(
          tester,
          find.byIcon(Symbols.emoji_events_rounded),
        ).size!.width,
      );
    }

    expect(widths, hasLength(1), reason: 'one width from 640 up, got $widths');

    // And the handheld card is under it, not over: the cap never grows a pill.
    await pumpFooter(tester, showsPill: true, width: handheldCardWidth);
    expect(
      _decoratedAncestor(
        tester,
        find.byIcon(Symbols.emoji_events_rounded),
      ).size!.width,
      lessThanOrEqualTo(widths.single),
    );

    // And the slack lands between the pill and the controls, not beside the
    // score: the controls stay on the right margin.
    await pumpFooter(tester, showsPill: true, width: 1200);
    final play = _chipRect(tester, find.text('PLAY'));
    final pill = _chipRect(tester, find.byIcon(Symbols.emoji_events_rounded));
    final score = _chipRect(tester, find.byIcon(Symbols.star_rounded));
    expect(1200 - play.right, lessThan(20), reason: 'controls hug the right');
    expect(pill.left - score.right, lessThan(20), reason: 'readouts hug left');
  });

  testWidgets('a card too narrow for the pill gets no pill, not a splinter', (
    tester,
  ) async {
    // 325 is inside the one window where this decision is live: the fixed
    // items still fit (below ~289 the row overflows outright, which no real
    // card is narrow enough to reach) but what they leave is under the pill's
    // floor. The window moved down with the score's slot when it lost its chip
    // — it was 350 against a ~314 floor while the score was still 73 wide.
    await pumpFooter(tester, showsPill: true, width: 325);

    expect(
      find.byIcon(Symbols.emoji_events_rounded),
      findsNothing,
      reason: 'omitted outright rather than drawn as a dark sliver',
    );
    // The rest of the row is unaffected: the controls are what the row is for.
    // On a card this narrow, Play gives up its label and keeps the A action.
    final playGlyph = find.byType(Image);
    expect(playGlyph, findsOneWidget);
    expect(tester.getSize(playGlyph).width, greaterThan(0));
    expect(find.byIcon(Symbols.settings_rounded), findsOneWidget);
  });

  testWidgets('the score chip is the same width whatever the score', (
    tester,
  ) async {
    // The number runs from "1" to "10", and the achievements pill beside it is
    // the row's only Expanded -- so a score that sized to its content handed
    // the pill a different width on every game, and on a 10 game it pushed the
    // pill under its floor and off the row entirely.
    //
    final chipWidths = <double>{};
    final pillLefts = <double>{};
    final pillWidths = <double>{};
    for (final rating in [0.1, 16.0, 17.0, 20.0]) {
      await pumpFooter(
        tester,
        showsPill: true,
        width: handheldCardWidth,
        game: _game(rating: rating),
      );
      final pill = _chipRect(tester, find.byIcon(Symbols.emoji_events_rounded));
      pillLefts.add(pill.left);
      pillWidths.add(pill.width);
      chipWidths.add(
        _chipRect(tester, find.byIcon(Symbols.star_rounded)).width,
      );
    }

    expect(chipWidths, hasLength(1), reason: 'one footprint for every score');
    expect(pillLefts, hasLength(1), reason: 'so is where the pill starts');
    expect(
      pillWidths,
      hasLength(1),
      reason: 'so the pill does not resize as the cursor walks the list',
    );
  });

  testWidgets('the score chip is inset optically, not geometrically', (
    tester,
  ) async {
    // Guard against this being "tidied" back to a symmetric inset. Measured on
    // device, the star's ink sits about 9px inside its icon box while the
    // number's last digit runs nearly to the edge of its own, so equal insets
    // put the group 5px right of where it looks centred. The widget rects are
    // symmetric either way, which is exactly why the imbalance survived until
    // someone looked at the pixels.
    await pumpFooter(tester, width: handheldCardWidth);

    final chip = _chipRect(tester, find.byIcon(Symbols.star_rounded));
    final star = tester.getRect(find.byIcon(Symbols.star_rounded));
    final number = tester.getRect(scoreText('9'));

    expect(
      star.left - chip.left,
      lessThan(chip.right - number.right),
      reason: 'the star side is tighter, to pay for the ink inside its box',
    );
  });

  testWidgets('the row is evenly spaced', (tester) async {
    // It was 8 either side of the pill and 6 between the buttons, which reads
    // as unevenly spaced rather than as a rhythm.
    //
    // On a wide card the pill meets its cap and the leftover collects at its
    // right edge, so this is asserted at the handheld width, where the pill is
    // under the cap and takes up every unit the row does not spend.
    await pumpFooter(tester, showsPill: true, width: handheldCardWidth);

    final playButton = find.byWidgetPredicate(
      (widget) =>
          widget is Container &&
          widget.decoration is BoxDecoration &&
          (widget.decoration! as BoxDecoration).color ==
              const Color(0xFF2ECC71),
    );
    final rects = [
      for (final finder in [
        find.byIcon(Symbols.star_rounded),
        find.byIcon(Symbols.emoji_events_rounded),
        find.byIcon(Symbols.casino_rounded),
        find.byIcon(Symbols.favorite_rounded),
        find.byIcon(Symbols.settings_rounded),
      ])
        _chipRect(tester, finder),
      tester.getRect(playButton),
    ];

    final gaps = [
      for (int i = 1; i < rects.length; i++) rects[i].left - rects[i - 1].right,
    ];

    for (final gap in gaps) {
      expect(
        gap,
        moreOrLessEquals(gaps.first, epsilon: 0.5),
        reason: 'one gap between every pair, got $gaps',
      );
    }
  });

  testWidgets('the row is the same height whatever the game carries', (
    tester,
  ) async {
    // The four states that each used to resize this footer: a pill or none, a
    // score or none, a clock or none, and the metadata strip an unscraped game
    // never had.
    await pumpFooter(tester, showsPill: true);
    final withPill = tester.getSize(find.byType(GameDetailsFooter));

    await pumpFooter(tester);
    final noPill = tester.getSize(find.byType(GameDetailsFooter));

    await pumpFooter(tester, game: _game(rating: 0, playTime: null));
    final bare = tester.getSize(find.byType(GameDetailsFooter));

    expect(noPill.height, withPill.height);
    expect(bare.height, withPill.height);
  });

  testWidgets('every control is a touch route to what the pad already does', (
    tester,
  ) async {
    await pumpFooter(tester);

    await tester.tap(find.byIcon(Symbols.casino_rounded));
    await tester.tap(find.byIcon(Symbols.favorite_rounded));
    await tester.tap(find.byIcon(Symbols.settings_rounded));
    await tester.tap(find.text('PLAY'));

    expect(pressed, ['random', 'favorite', 'settings', 'play']);
  });

  testWidgets('the score opens the tab it summarizes', (tester) async {
    // The chip was the one element on the row that looked pressable and was
    // not. The score is the shortest summary of what the game info tab holds,
    // so that is where the press goes.
    await pumpFooter(tester);

    await tester.tap(find.byIcon(Symbols.star_rounded));

    expect(pressed, ['gameInfo']);
  });

  testWidgets('an unscored game has no chip to press', (tester) async {
    // No chip at all below a rating of 1, so there is nothing to tap and
    // nothing that looks like it should be tapped.
    await pumpFooter(tester, game: _game(rating: 0));

    expect(find.byIcon(Symbols.star_rounded), findsNothing);
  });

  testWidgets('the heart reports the flag it toggles', (tester) async {
    await pumpFooter(tester);
    expect(
      tester.widget<Icon>(find.byIcon(Symbols.favorite_rounded)).fill,
      0,
      reason: 'an outline on a game that is not a favourite',
    );

    await pumpFooter(tester, game: _game(isFavorite: true));
    expect(
      tester.widget<Icon>(find.byIcon(Symbols.favorite_rounded)).fill,
      1,
      reason: 'filled once it is one, so the toggle reads without a press',
    );
  });

  testWidgets('a host with no random dialog gets no button for one', (
    tester,
  ) async {
    await pumpFooter(tester, canRandom: false);

    expect(find.byIcon(Symbols.casino_rounded), findsNothing);
    // The rest of the row is untouched by its absence.
    expect(find.byIcon(Symbols.favorite_rounded), findsOneWidget);
    expect(find.text('PLAY'), findsOneWidget);
  });

  testWidgets('nothing on the row can take the gamepad cursor', (tester) async {
    // The card owns no focusable widgets: the list beside it drives selection,
    // and a second cursor inside the card would fight it.
    await pumpFooter(tester, showsPill: true);

    expect(find.byType(ExcludeFocus), findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(ExcludeFocus),
        matching: find.text('PLAY'),
      ),
      findsOneWidget,
    );
  });
}

/// The nearest ancestor of [of] that actually draws a chip. The chips are
/// [NeoGlass] surfaces; a [Container] that still carries a [BoxDecoration] is
/// the fallback (e.g. the PLAY button, which is deliberately not part of the
/// glass set).
Element _decoratedAncestor(WidgetTester tester, Finder of) {
  final glass = find
      .ancestor(of: of, matching: find.byType(NeoGlass))
      .evaluate();
  if (glass.isNotEmpty) return glass.first;
  return find
      .ancestor(of: of, matching: find.byType(Container))
      .evaluate()
      .firstWhere((e) => (e.widget as Container).decoration is BoxDecoration);
}

double _radiusOf(Element chip) {
  final widget = chip.widget;
  if (widget is NeoGlass) return widget.cornerRadius;
  return (((widget as Container).decoration as BoxDecoration).borderRadius
          as BorderRadius)
      .topLeft
      .x;
}

/// The on-screen rectangle of the chip [of] sits inside.
Rect _chipRect(WidgetTester tester, Finder of) {
  final box = _decoratedAncestor(tester, of).renderObject! as RenderBox;
  return box.localToGlobal(Offset.zero) & box.size;
}
