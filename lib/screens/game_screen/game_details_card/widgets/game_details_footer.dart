import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:provider/provider.dart';
import 'package:neostation/providers/retro_achievements_provider.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:neostation/l10n/app_locale.dart';
import 'package:neostation/services/sfx_service.dart';
import 'package:neostation/themes/app_themes.dart';
import '../../../../models/system_model.dart';
import '../../../../models/game_model.dart';
import '../../../../models/retro_achievements_game_info.dart';
import '../../../../themes/corner_radii.dart';
import '../../../../utils/game_utils.dart';
import '../../../../utils/game_list_responsive.dart';
import '../../../../widgets/neo_glass.dart';
import '../../../../widgets/monospaced_clock.dart';
import '../../music/music_player.dart';
import 'scrolling_status_line.dart';
import 'package:neostation/utils/ra_coverage.dart';

/// A sticky footer component for the game details card that provides actionable controls and status summaries.
///
/// Manages high-level game interactions (Play), summarizes cloud synchronization
/// health, and provides quick access to trophy progress. Dynamically adjusts for specialized
/// systems like the Music Player.
class GameDetailsFooter extends StatelessWidget {
  final SystemModel system;
  final GameModel game;
  final bool isMusicSystem;
  final bool hasScreenScraper;
  final bool isSecondaryScreenActive;
  final VoidCallback onShowAchievements;
  final bool hasRetroAchievements;
  final bool isLoadingAchievements;
  final GameInfoAndUserProgress? currentGameInfo;

  /// Launches the selected game. The same action A takes on the pad, and the
  /// same one a second tap on an already-selected sidebar row takes.
  final VoidCallback onPlayGame;

  /// Opens the random-game dialog. Null hides the button, for hosts that have
  /// no such dialog to open.
  final VoidCallback? onShowRandomGame;

  /// Adds or removes this game from Favourites. The host owns the write and
  /// the follow-up (the Favourites system card appearing, the row leaving the
  /// Favourites view); the button only reports the current flag.
  final VoidCallback onToggleFavorite;

  /// Opens the per-game settings dialog — the same one Start opens.
  final VoidCallback onOpenGameSettings;

  /// Walks the card to its game info tab. The score chip's tap target: the
  /// number is a summary of the facts that tab holds, so pressing it goes to
  /// them rather than doing nothing.
  final VoidCallback onShowGameInfo;

  const GameDetailsFooter({
    super.key,
    required this.system,
    required this.game,
    required this.isMusicSystem,
    required this.hasScreenScraper,
    required this.isSecondaryScreenActive,
    required this.onShowAchievements,
    required this.hasRetroAchievements,
    required this.isLoadingAchievements,
    this.currentGameInfo,
    required this.onPlayGame,
    this.onShowRandomGame,
    required this.onToggleFavorite,
    required this.onOpenGameSettings,
    required this.onShowGameInfo,
  });

  @override
  Widget build(BuildContext context) {
    // Scenario 1: Specialized Music Player UI.
    if (isMusicSystem) {
      return Positioned(
        bottom: -0.5.r,
        left: -0.5.r,
        right: -0.5.r,
        child: MusicPlayer(systemColor: system.colorAsColor),
      );
    }

    // Scenario 2: Standard Game Metadata UI.
    final bool hasRating = game.rating > 0;
    final bool hasPlayTime =
        GameUtils.formatPlayTime(game.playTime ?? 0) != '0s';
    final bool showsAchievements = _showsAchievements(context);
    final viewport = MediaQuery.sizeOf(context);
    final bool showSecondaryActions = !GameListResponsive.isCompactViewport(
      viewport.width,
      viewport.height,
    );

    // One row, always the same height, in reading order: what the game *is*
    // on the left, what you can *do* with it on the right.
    //
    // The two text lines that used to sit above this row are one line now. The
    // metadata strip (players, publisher, year, genre) reads better in the
    // game info tab, which already carried half of those facts, so the strip
    // is not repeated on the artwork. The ROM filename that had the second of
    // those lines to itself is back, sharing the play-time clock's line.
    //
    // The cloud-sync glyph rode at that strip's end, spent a while as a chip
    // in this row, and now lives on the game list's own selected row, at the
    // end of the title. It says something about *the selected game*, and the
    // list is where the selection is: on the card it was a second place to
    // look for a mark the row could carry itself, and it was taking a chip's
    // width off the achievements pill on every synced game.
    //
    // Neither of the survivors is on the row. The clock was there once and that
    // is what starved the achievements pill down to seven pixels; a play-time
    // reading is 96 to 112 units wide and the row's spare, on the handheld
    // card, is about 46. The line above costs the row nothing, which is the
    // only place the clock fits without the pill paying for it, and the
    // filename rides the same line rather than reclaiming one of its own.
    //
    // Fixed height, both parts of it: the line is reserved whether or not the
    // game has a reading to put on it, so the footer does not resize with what
    // the selected game happens to carry — see [gameDetailsPanelBottomOffset],
    // which is a constant for the same reason.
    return Positioned(
      bottom: -0.5.r,
      left: -0.5.r,
      right: -0.5.r,
      child: ClipRRect(
        child: RepaintBoundary(
          child: Container(
            padding: EdgeInsets.only(
              left: 12.r,
              right: 12.r,
              bottom: _bottomPadding.r,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // The line above the row: the ROM filename on the left, the
                // play-time clock on the right.
                //
                // The clock had this line to itself and the filename was not
                // rendered anywhere on the card. They pair well: the reading is
                // a fixed, short glyph+digits block that wants the right edge,
                // and the name is the one variable-width thing here, so giving
                // it whatever the clock leaves costs the clock nothing and puts
                // the name back without a third line.
                SizedBox(
                  height: _clockLine.r,
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      // Takes the line's whole width when there is no reading
                      // beside it, and scrolls when it is longer than what it
                      // gets.
                      Expanded(child: _InlineRomFileName(game: game)),
                      if (hasPlayTime) ...[
                        SizedBox(width: 10.r),
                        _InlinePlayTime(game: game),
                      ],
                    ],
                  ),
                ),
                SizedBox(height: _clockRowGap.r),
                SizedBox(
                  height: _bottomRowHeight,
                  // The whole row is touch-only. Every action on it has a
                  // hardware binding already (A launches, Y opens the context
                  // menu, Start opens settings), and a focusable widget inside
                  // the card would put a second cursor in a view that owns its
                  // own selection.
                  child: ExcludeFocus(
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        // Readouts first: the score, then the achievements pill
                        // taking whatever the controls leave it.
                        if (hasRating) ...[
                          _InlineRating(game: game, onTap: onShowGameInfo),
                          SizedBox(width: _rowGap),
                        ],
                        Expanded(
                          child: showsAchievements
                              ? Align(
                                  // Left, so a capped pill leaves its slack between
                                  // itself and the controls rather than beside the
                                  // score.
                                  alignment: Alignment.centerLeft,
                                  child: LayoutBuilder(
                                    builder: (context, constraints) =>
                                        _buildCompactAchievementsIndicator(
                                          context,
                                          availableWidth: constraints.maxWidth,
                                        ),
                                  ),
                                )
                              // Nothing to report, but the slot stays: it is what
                              // pushes the controls to the right margin.
                              : const SizedBox.shrink(),
                        ),
                        SizedBox(width: _rowGap),
                        // Controls, in the order the removed rail had them.
                        if (showSecondaryActions) ...[
                          if (onShowRandomGame != null) ...[
                            _FooterActionButton(
                              // The same dice the Y context menu gives Random, so the
                              // action carries one glyph wherever it is offered.
                              icon: Symbols.casino_rounded,
                              onTap: onShowRandomGame!,
                            ),
                            SizedBox(width: _rowGap),
                          ],
                          _FooterActionButton(
                            icon: Symbols.favorite_rounded,
                            // Filled and tinted when the game is already a
                            // favourite: the button is a toggle, so its state has to
                            // be readable without pressing it.
                            isOn: game.isFavorite == true,
                            onTap: onToggleFavorite,
                          ),
                          SizedBox(width: _rowGap),
                          _FooterActionButton(
                            icon: Symbols.settings_rounded,
                            onTap: onOpenGameSettings,
                          ),
                          SizedBox(width: _rowGap),
                        ],
                        _buildPlayButton(context),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// High-contrast primary button for launching the emulator.
  ///
  /// It was dropped once as a third route to something A and a double tap on
  /// the sidebar row already did. It is back because those two are the only
  /// routes there are: the rail that carried every other touch affordance went
  /// with it, and a games view whose one visible control was an achievements
  /// pill gave touch nothing to press.
  Widget _buildPlayButton(BuildContext context) {
    // The one control on the row that keeps the theme's corner. Fully rounded
    // it read as one more chip in the set, and PLAY is not one of the set --
    // it is the row's primary action, and the squarer corner is part of what
    // separates it from the three icon buttons beside it.
    final BorderRadius radius =
        Theme.of(context).extension<CornerRadii>()?.radiusExternal ??
        BorderRadius.circular(14.r);

    return Container(
      // Deliberately a fixed width. The achievements pill beside it is
      // Expanded, so anything this button takes comes straight out of that
      // pill; long labels are absorbed by scaling the text down rather than by
      // growing the button (see the FittedBox below). 88 rather than 80 since
      // the row grew: the badge and the label grew with it, and at 80 the
      // English label was the one being scaled down to fit.
      width: 88.r,
      height: _controlSize.r,
      decoration: BoxDecoration(
        color: const Color(0xFF2ECC71),
        borderRadius: radius,
        border: Border.all(color: const Color(0xFF36F184), width: 1.r),
        boxShadow: [
          BoxShadow(
            color: Theme.of(context).colorScheme.shadow.withValues(alpha: 0.1),
            blurRadius: 4.r,
            offset: Offset(2.0.r, 2.0.r),
          ),
        ],
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          canRequestFocus: false,
          focusColor: Colors.transparent,
          hoverColor: Colors.transparent,
          highlightColor: Colors.transparent,
          splashColor: Colors.white.withValues(alpha: 0.1),
          borderRadius: radius,
          onTap: () {
            SfxService().playEnterSound();
            onPlayGame();
          },
          child: Padding(
            padding: EdgeInsets.only(right: 8.r),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Image.asset(
                  'assets/images/gamepad/Xbox_A_button.png',
                  width: 28.r,
                  height: 28.r,
                  color: Theme.of(context).colorScheme.onPrimary,
                ),
                SizedBox(width: 6.r),
                // The label is localized and the button is a fixed width, so
                // only the English "PLAY" fits at the full 13.r: the German,
                // Russian and CJK labels used to render past its right edge.
                // scaleDown shrinks just those to fit and never scales up, so
                // the button's footprint stays constant either way.
                Flexible(
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Text(
                      AppLocale.playButton.getString(context),
                      maxLines: 1,
                      softWrap: false,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.onPrimary,
                        fontWeight: FontWeight.w900,
                        fontSize: 13.r,
                        letterSpacing: 1.0,
                        height: 1.0,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// How many achievements this game has, if anything knows.
  ///
  /// The bundled snapshot already records the count for a matched game, so
  /// this costs no network call — only the user's *earned* count does. See
  /// _CompactAchievementsIndicator, which does the same.
  int get _achievementTotal {
    final int localTotal = game.raCoverage == RaCoverage.matched
        ? (game.raNumAchievements ?? 0)
        : 0;
    return currentGameInfo?.numAchievements ?? localTotal;
  }

  /// Whether the achievements pill has anything to report.
  ///
  /// False collapses the whole action row, not just the pill, and the lines
  /// above drop into the space — so this is the one thing deciding how tall
  /// the footer is.
  ///
  /// Signed out, nothing ever loads achievement data, so the pill would settle
  /// on its "none" state for every game and claim the game has no achievements
  /// when the truth is that nobody asked. While a lookup is genuinely
  /// outstanding the pill stays (it says "Loading"); it is only a *settled*
  /// zero that hides it, which is the same condition the pill itself calls
  /// `noAchievements`.
  bool _showsAchievements(BuildContext context) => showsAchievementsFor(
    context,
    game: game,
    hasRetroAchievements: hasRetroAchievements,
    isLoadingAchievements: isLoadingAchievements,
    currentGameInfo: currentGameInfo,
  );

  /// [_showsAchievements] for callers that only hold the inputs — the tab
  /// panels above the footer, which need the same answer to know how much
  /// room the footer will take.
  static bool showsAchievementsFor(
    BuildContext context, {
    required GameModel game,
    required bool hasRetroAchievements,
    required bool isLoadingAchievements,
    GameInfoAndUserProgress? currentGameInfo,
  }) {
    if (!hasRetroAchievements) return false;
    if (!context.select<RetroAchievementsProvider, bool>(
      (ra) => ra.isConnected,
    )) {
      return false;
    }
    final int localTotal = game.raCoverage == RaCoverage.matched
        ? (game.raNumAchievements ?? 0)
        : 0;
    final int total = currentGameInfo?.numAchievements ?? localTotal;
    return isLoadingAchievements || total > 0;
  }

  /// Resolves the current RetroAchievements progress into a compact visual badge.
  Widget _buildCompactAchievementsIndicator(
    BuildContext context, {
    required double availableWidth,
  }) {
    if (!_showsAchievements(context)) return const SizedBox.shrink();

    // Nothing rather than a splinter — see [_pillMinWidth].
    if (availableWidth < _pillMinWidth.r) return const SizedBox.shrink();

    // The badge takes its slot up to [_pillMaxWidth] and no further; the slack
    // past that falls between it and the controls, so the row stays "readouts
    // left, controls right" instead of stretching one pill across the card.
    //
    // It used to animate between 120.r and
    // full width, yielding the space to its right whenever a play-time pill was
    // there; the clock is inline text now and claims its width up front, so
    // there is no second width to ease to.
    final int total = _achievementTotal;
    final int? awarded = currentGameInfo?.numAwardedToUser;
    final bool knowsProgress = awarded != null && currentGameInfo != null;

    final bool noAchievements = !isLoadingAchievements && total == 0;

    // A dash rather than a zero while the earned count is outstanding, and
    // "Unknown" rather than "No Achievements" when the zero is a gap in what
    // the app could hash instead of an answer from RetroAchievements. See
    // _CompactAchievementsIndicator, which makes the same distinction.
    final String progressText = total > 0
        ? (knowsProgress ? '$awarded/$total' : '\u2013/$total')
        : (isLoadingAchievements
              ? AppLocale.loading.getString(context)
              : raCoverageAnswersZero(game.raCoverage)
              ? AppLocale.noAchievements.getString(context)
              : AppLocale.raCoverageUnknown.getString(context));

    // Whether the earned count is still outstanding for a game that has
    // achievements to earn. The bundled snapshot gives us the total instantly,
    // so this gap is every single selection change: the pill knows "49
    // achievements" before it knows "0 of them".
    final bool awaitingProgress = !knowsProgress && total > 0;

    // Always determinate. This used to run an indeterminate bar through the
    // gap above, which meant an orange sweep across the pill on *every* game
    // the user moved onto — a flash that said "working" about a lookup that
    // resolves in a moment and that the text ("-/49") already reports. A still
    // bar that fills in when the number lands is the same information without
    // the strobe.
    final double progress = knowsProgress && total > 0 ? awarded / total : 0.0;

    final theme = Theme.of(context);
    // Orange is for a real, known score. An empty bar that is empty only
    // because nobody has answered yet stays neutral, so the colour arriving is
    // itself the signal that the number is real.
    final Color statusColor = noAchievements || awaitingProgress
        ? theme.colorScheme.onSurface
        : Colors.orange;

    final String? gameIconUrl = currentGameInfo?.imageIcon.isNotEmpty == true
        ? 'https://media.retroachievements.org${currentGameInfo!.imageIcon}'
        : null;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () {
          SfxService().playNavSound();
          onShowAchievements();
        },
        canRequestFocus: false,
        focusColor: Colors.transparent,
        hoverColor: Colors.transparent,
        highlightColor: Colors.transparent,
        splashColor: theme.colorScheme.onSurface.withValues(alpha: 0.1),
        borderRadius: _controlRadius,
        child: NeoGlass(
          cornerRadius: _bottomRow.r,
          child: SizedBox(
            width: availableWidth.clamp(0.0, _pillMaxWidth.r),
            height: _bottomRowHeight,
            child: Padding(
              // Symmetric 8.r horizontal inset so neither the trophy icon nor the
              // progress bar hugs the pill border. The progress column is always
              // Expanded, so it simply absorbs the padding at any pill width.
              padding: EdgeInsets.symmetric(horizontal: 6.r, vertical: 4.r),
              child: Row(
                children: [
                  // RetroAchievements game icon.
                  ClipRRect(
                    borderRadius:
                        Theme.of(
                          context,
                        ).extension<CornerRadii>()?.radiusInternal ??
                        BorderRadius.circular(14.r),
                    child: Container(
                      width: _pillIconSize,
                      height: _pillIconSize,
                      color: theme.colorScheme.surface,
                      child: gameIconUrl != null
                          ? Image.network(
                              gameIconUrl,
                              fit: BoxFit.cover,
                              errorBuilder: (_, _, _) => Icon(
                                Symbols.emoji_events_rounded,
                                color: statusColor,
                                size: 16.r,
                              ),
                            )
                          : Icon(
                              Symbols.emoji_events_rounded,
                              color: statusColor,
                              size: 16.r,
                            ),
                    ),
                  ),
                  SizedBox(width: 6.r),
                  // Progress bar and achievement count. When the legend is hidden
                  // the pill stretches, so let this column (and its bar) fill the
                  // extra width via Expanded; otherwise keep the fixed 70.r width.
                  Expanded(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        SizedBox(
                          width: double.infinity,
                          child: Text(
                            progressText.toUpperCase(),
                            style: TextStyle(
                              color: theme.colorScheme.onSurface,
                              fontSize: 11.r,
                              fontWeight: FontWeight.bold,
                              letterSpacing: 0.5,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        SizedBox(height: 4.r),
                        // Hold the bar short of the pill's right edge so it
                        // doesn't run all the way across — mirrors the grid/
                        // carousel pill's right margin under the progress count.
                        Padding(
                          padding: EdgeInsets.only(right: 6.r),
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(4.r),
                            child: LinearProgressIndicator(
                              value: progress,
                              minHeight: 6.r,
                              backgroundColor: theme.colorScheme.onSurface
                                  .withValues(alpha: 0.1),
                              valueColor: AlwaysStoppedAnimation<Color>(
                                statusColor,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The corner every chrome element on the row wears *except* PLAY: fully
/// rounded, so the square controls come out as circles and the achievements
/// pill as a stadium.
///
/// Deliberately not the theme's [CornerRadii]. That extension sets the corner
/// style for the app's panels and cards, and at its squarer settings this row
/// read as a strip of tiles; the controls are meant to read as a set of
/// buttons floating on the artwork, which is a shape, not a preference. PLAY
/// keeps the theme's corner precisely because it is *not* part of that set --
/// see [GameDetailsFooter._buildPlayButton].
BorderRadius get _controlRadius => BorderRadius.circular(_bottomRow.r);

/// Height of the footer's row, and the size of every square control on it.
///
/// One number, so the achievements pill, the sync chip, the three icon buttons
/// and PLAY all line up on both edges.
///
/// It was the achievements pill's own 45, from when the pill was the only
/// thing on the row.
///
/// Everything on the row is sized off this, so it is the dial for the row's
/// width budget -- and the pill is the only Expanded here, so it silently
/// absorbs whatever the fixed items leave. At 45, with six things on the row,
/// what they left on a 1920 handheld was seven pixels: the pill rendered
/// full-height, right-shaped and empty, with no overflow to say so. Sizing the
/// row down to 34 is what paid for all six being here, and the note recording
/// that sweep put the starving point just above 40 --
/// `docs/collections/08-list-footer-sizing.md`.
///
/// Then two things came off the row's fixed side. The cloud-sync glyph left
/// altogether for the game list's selected row (~39 with its gap), and the
/// score's chip was slimmed by the decimal point and a tighter reservation
/// (~25). That is ~64 the pill did not have when 40 was the ceiling, and it is
/// what this is spending: each unit here costs three, one per square control.
///
/// 40, which leaves the pill about 115 on the handheld card — well clear of
/// [_pillMinWidth], and under [_pillMaxWidth], so the cap only binds on wider
/// cards now. The ceiling is not a fixed number: it is whatever leaves the pill
/// above its floor, and it moves every time something joins or leaves the row.
/// Anything that puts an item back has to come out of here again — which is
/// why the play-time clock went above the row rather than on it.
const double _bottomRow = 40;

/// The one gap between every pair of things on the row.
///
/// It was 8 either side of the achievements pill and 6 between the buttons,
/// which is close enough to look like a mistake rather than a rhythm -- the
/// controls read as unevenly spaced even though each pair was deliberate.
double get _rowGap => 5.r;

/// The score chip's width, fixed.
///
/// It cannot size to its content. The number is one or two characters ("8"
/// against "10"), and since the achievements pill beside it is the row's only
/// Expanded, every character the score gains comes straight out of the pill --
/// so the pill was a different width on every game, and on a game scoring 10 it
/// fell under [_pillMinWidth] and vanished outright. A readout that moves what
/// is beside it as the cursor walks the list is what the rest of this footer
/// was rebuilt to stop.
///
/// The number is swept down by eye until the chip starts scaling it, and the
/// floor moves with whatever else is in the chip and with how many characters
/// the number has:
///
///     "8.5", star 18.r, gap 5.r -> floor 80
///     "8.5", star 16.r, gap 4.r -> floor 75
///     "8.5", star 14.r, gap 3.r -> floor 72   (73 shipped)
///
/// Two things came out of that string since. The decimal point went — the score
/// is drawn whole — and the chip came off and went back on around a bigger
/// star and number, sized for the taller row. Measured at 16.r: the star is 16
/// wide, a digit 16.3, the gap 3, the padding 4 + 6 — so the widest content,
/// "10", needs 61.7. 64 is that plus wobble room, and the [FittedBox] takes
/// anything past it out of the number rather than out of the pill.
///
/// Still 9 under the 73 it was at the smaller sizes, because the decimal point
/// was worth more than the growth. Widening it takes width off the pill.
const double _scoreWidth = 64;

/// The widest the achievements pill is allowed to get.
///
/// It is the row's only Expanded, which is what let it be starved to seven
/// pixels on a narrow card — and, on a wide one, what would let it run on for
/// half the card. It carries an icon, a short count and a bar: past a point
/// more width is just a longer bar, and the row reads better as a group of
/// readouts on the left and a group of controls on the right with air between
/// them than as one enormous pill pushing them apart.
///
/// 132 was what the handheld card gave it when this was tuned, so the cap
/// changed nothing there and only wider cards (desktop, and the Deck) met it.
/// The handheld card is under it now — the row grew to 40 and the score took
/// its chip back — so it lands around 115 there, and the cap binds from about
/// a 640-wide card up.
///
/// Left where it is deliberately. The cap is a ceiling on how long the bar is
/// allowed to get, not a target: raising it to track whatever the handheld
/// happens to leave would make every change to the row a change to the cap.
const double _pillMaxWidth = 132;

/// The narrowest the achievements pill can be and still say anything: its
/// icon, the count and a bar with somewhere to fill.
///
/// Below this it is omitted outright rather than drawn as a sliver. The row's
/// budget is fixed items plus whatever is left, and "whatever is left" has no
/// floor of its own -- a card narrow enough leaves a few pixels, which is a
/// dark splinter between two chips rather than a control. Losing the pill on a
/// card that cannot hold one is the honest outcome; the D-pad still reaches
/// the achievements tab.
const double _pillMinWidth = 64;

/// [_bottomRow] unscaled, for the widgets that take a bare `double` and apply
/// `.r` themselves.
const double _controlSize = _bottomRow;

/// Height of the play-time line above the row.
///
/// Reserved whether or not the selected game has a reading to put on it: the
/// footer's height is the one thing every panel above it is positioned off
/// (see [gameDetailsPanelBottomOffset]), so a line that appeared only for
/// played games would move the panels as the cursor walked the list -- which
/// is the exact fault the row below it was rebuilt to fix.
///
/// 26 holds the 18.r reading and its 20.r glyph with a little air. The clock is
/// up here rather than on the row because it does not fit on the row: a
/// play-time reading measures 96 to 112 units and the row's spare, on the
/// handheld card, is about 46. It was on the row once, and that is the era the
/// achievements pill rendered seven pixels wide.
const double _clockLine = 26;

/// Air between the line above and the row of controls.
///
/// The line and the row used to butt straight together, which was survivable
/// while the play-time clock sat at the left of the line, above the score chip.
/// The clock is at the right margin now, and so is PLAY — the two are flush to
/// within a couple of pixels — so the reading was sitting directly on the
/// button's top edge with about 8 units between them, of which the shadow under
/// the digits took three. It read as the digits hanging off the button rather
/// than as a line above it.
///
/// Counted into [gameDetailsPanelBottomOffset] with the rest of the footer, so
/// the panels above still stop clear of it.
const double _clockRowGap = 6;

/// Slack under the row, so the content does not sit on the card's edge.
const double _bottomPadding = 11;

/// Gap the tab panels keep between themselves and the footer.
const double _panelGap = 13;

double get _bottomRowHeight => _bottomRow.r;

/// The achievements pill's game icon: the row's height less its own vertical
/// padding, so the artwork fills the chip rather than floating in it.
double get _pillIconSize => (_bottomRow - 10).r;

/// How far above the card's bottom edge a tab panel should stop.
///
/// A constant now. The footer used to grow and shrink with the selected game —
/// a metadata strip that an unscraped game did not have, an achievements pill
/// that an unmatched one did not get — so a panel that reserved a fixed band
/// either ended above bare artwork or was overdrawn. The row holds the
/// controls, and those are there for every game; the play-time line above it
/// is reserved for every game whether or not it has a reading. So there is
/// nothing left to vary.
///
/// Unscaled, like the panels' own offsets — the caller applies `.r`.
double gameDetailsPanelBottomOffset() =>
    _clockLine + _clockRowGap + _bottomRow + _bottomPadding + _panelGap;

/// One square control on the footer's row: a glyph on the same pill the
/// achievements indicator wears, so the row reads as a set.
///
/// [isOn] is for the favourite toggle, the one control here whose state is
/// worth reading at a glance: on, the glyph fills and takes the theme's
/// error colour, which is the same treatment the context menu gives a
/// membership that is already set.
class _FooterActionButton extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;
  final bool isOn;

  const _FooterActionButton({
    required this.icon,
    required this.onTap,
    this.isOn = false,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final BorderRadius radius = _controlRadius;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () {
          SfxService().playNavSound();
          onTap();
        },
        canRequestFocus: false,
        focusColor: Colors.transparent,
        hoverColor: Colors.transparent,
        highlightColor: Colors.transparent,
        splashColor: theme.colorScheme.onSurface.withValues(alpha: 0.1),
        borderRadius: radius,
        child: NeoGlass(
          cornerRadius: _bottomRow.r,
          child: SizedBox(
            width: _bottomRowHeight,
            height: _bottomRowHeight,
            child: Icon(
              icon,
              size: 21.r,
              fill: isOn ? 1 : 0,
              color: isOn
                  ? AppThemes.getCustomColors(context).errorColor
                  : theme.colorScheme.onSurface,
            ),
          ),
        ),
      ),
    );
  }
}

/// Score as a star and a number, at the head of the footer's row.
///
/// It has been in four places, and the middle two are the mistakes worth not
/// repeating. It started as a pill in this row, which was removed on the rule
/// that the row is for controls and a score answers to nothing. It then spent
/// a while as one more segment of the metadata marquee, at the strip's own
/// size — which cost it the emphasis along with the chrome, and let a long
/// publisher scroll it out of sight. It came back to the row as a bare glyph
/// and number on the artwork, which read as a caption that had drifted in.
///
/// It wears a chip, and the rule that took it off was the wrong rule: a row of
/// chips with one bare readout floating at its head does not read as "that one
/// is not pressable", it reads as unfinished. It was tried bare, on the
/// argument that a readout should not charge the row's only Expanded for its
/// own edges — the width was real, the look was worse, and the width came back
/// off the row's other side instead when the cloud glyph left it.
///
/// It presses, and it goes to the game info tab. The chip spent a while as the
/// one element on the row that looked pressable and was not, which is a worse
/// answer than either a bare readout or a working one: a score is the shortest
/// possible summary of what that tab holds, so the tap has an obvious
/// destination and takes it. Same ink as the controls beside it, and like them
/// it cannot take the gamepad cursor — the pad reaches that tab with the
/// bumpers already, and this is the touch route to it.
///
/// The colour ramp — error at the bottom of the range, success at the top — is
/// what makes the number readable without reading it, and it is what lets the
/// number be whole: the half point a decimal would have carried is in the
/// colour, and the character it would have cost is width this row does not have
/// to spare.
class _InlineRating extends StatelessWidget {
  final GameModel game;

  /// Opens the game info tab.
  final VoidCallback onTap;

  const _InlineRating({required this.game, required this.onTap});

  @override
  Widget build(BuildContext context) {
    // Normalizes a 0-20 score to a 0.0-10.0 scale for color interpolation.
    final ratingValue = (game.rating / 2).clamp(0.0, 10.0);
    // Drawn as a whole number, rounded up. The point and its decimal are a
    // character the chip has to reserve on every game, and the chip's width
    // comes off the achievements pill; the colour keeps the half point they
    // carried. Up rather than to nearest, so a game that scored at all never
    // reads "0".
    final displayRating = ratingValue.ceil();
    final colorRatio = (ratingValue - 1) / 9;
    final customColors = AppThemes.getCustomColors(context);
    final ratingColor = Color.lerp(
      customColors.errorColor,
      customColors.successColor,
      colorRatio,
    )!;

    final theme = Theme.of(context);

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () {
          SfxService().playNavSound();
          onTap();
        },
        canRequestFocus: false,
        focusColor: Colors.transparent,
        hoverColor: Colors.transparent,
        highlightColor: Colors.transparent,
        splashColor: theme.colorScheme.onSurface.withValues(alpha: 0.1),
        borderRadius: _controlRadius,
        child: NeoGlass(
          cornerRadius: _bottomRow.r,
          child: SizedBox(
            width: _scoreWidth.r,
            height: _bottomRowHeight,
            child: Padding(
              // Tighter than the row's own gap, because this chip is mostly air at the
              // row's height already and every unit of it is one the achievements pill
              // beside it does not get — and deliberately 2.r narrower on the left.
              //
              // That asymmetry is an optical correction, not a slip: measured on
              // device, the star's ink sits about 9px inside its own icon box while
              // the number's last digit runs nearly to the edge of its, so a
              // *geometrically* centred group reads 5px left-heavy. It survives the
              // decimal's removal because it is about the star, not the number. The
              // widget rects are symmetric either way — this is only visible in the
              // pixels, which is why the numbers came off a screenshot.
              padding: EdgeInsets.only(left: 4.r, right: 6.r),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Icon(
                    Symbols.star_rounded,
                    color: ratingColor,
                    size: 16.r,
                    fill: 1,
                  ),
                  SizedBox(width: 3.r),
                  // scaleDown never scales up, so every score that fits is untouched.
                  // Nothing reaches it at these sizes — it is here so a font-metric
                  // wobble shrinks the number rather than growing the chip.
                  Flexible(
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Text(
                        '$displayRating',
                        maxLines: 1,
                        softWrap: false,
                        style: TextStyle(
                          color: theme.colorScheme.onSurface,
                          fontSize: 16.r,
                          fontWeight: FontWeight.w800,
                          height: 1.15,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Shadows that lift a bare glyph or a line of text off the game's fanart.
///
/// The row below carries none of these: every element on it sits on a chip, and
/// a shadow inside a chip is grime. This line is painted straight onto the
/// artwork, where a light frame under a white reading takes it away entirely.
List<Shadow> get _onArtShadows => [
  Shadow(blurRadius: 1.r, color: Colors.black, offset: const Offset(2, 2)),
];

/// How far [_onArtShadows] reaches past the glyphs it sits under: the 2px
/// offset, plus the blur's own spread either side of that.
///
/// The filename needs it as slack in its marquee clip. Without it the name
/// keeps its whole shadow while it fits and loses the bottom of it the moment
/// it is long enough to scroll — see [ScrollingStatusLine.shadowRoom].
double get _onArtShadowRoom => 6.r;

/// The ROM filename, on the left of the play-time clock's line.
///
/// It is the one identity fact the list sidebar beside this card does not
/// carry: the row there renders the *resolved display name*, and this is what
/// that name was matched from. There is no game title on the card for the same
/// reason in reverse — it would be a strict duplicate of the selected row.
///
/// Only populated for scraped games: [GameListService] sets
/// `showRomFileNameSubtitle` exclusively on the scraped branch, because a
/// filename under a name derived from that same filename says nothing. For an
/// unscraped game, or a user running `preferFileName`, this renders nothing at
/// all and the clock simply keeps its line — the line's height is reserved
/// either way, so the footer does not resize as the cursor walks the list.
///
/// White with a drop shadow, matching the clock: this paints straight onto the
/// game's fanart, which can be any colour under it.
class _InlineRomFileName extends StatelessWidget {
  final GameModel game;

  const _InlineRomFileName({required this.game});

  @override
  Widget build(BuildContext context) {
    final String label = game.showRomFileNameSubtitle ? game.romname : '';
    if (label.isEmpty) return const SizedBox.shrink();

    // The clock's own 15.r. They share a line, and two sizes on one line read
    // as a heading with a caption after it rather than as two facts about the
    // same game. The weight still separates them: w600 here against the
    // reading's w700.
    final TextStyle style = TextStyle(
      color: Colors.white,
      fontSize: 15.r,
      fontWeight: FontWeight.w600,
      height: 1.15,
      shadows: _onArtShadows,
    );

    // No `RepaintBoundary` around this, deliberately. One looks free here —
    // the footer rebuilds on every sync tick and every achievements poll, and
    // a boundary would keep those off this line — but the marquee below moves
    // this exact widget every 50ms, and a retained layer is *repositioned*
    // rather than repainted. The damage the engine works out for that move is
    // the layer's paint bounds, which for a `Text` is its line box and not the
    // drop shadow hanging past it: the shadow's pixels are then neither
    // cleared where they were nor drawn where they now belong, so the name
    // scrolls out from under its own shadow and leaves it standing. It only
    // shows up where a frame is a partial repaint, which is why it comes in
    // from devices and not from a desktop build.
    final Widget text = Text(
      label,
      maxLines: 1,
      // No wrapping and no ellipsis: whichever branch below is taken, this
      // text is laid out at its full width — either because it fits, or
      // because the marquee is going to scroll past its end.
      softWrap: false,
      strutStyle: StrutStyle(
        fontSize: 15.r,
        height: 1.15,
        forceStrutHeight: true,
      ),
      style: style,
    );

    return LayoutBuilder(
      builder: (context, constraints) {
        final TextPainter painter = TextPainter(
          text: TextSpan(text: label, style: style),
          maxLines: 1,
          textDirection: Directionality.of(context),
          textScaler: MediaQuery.textScalerOf(context),
        )..layout();
        final bool overflows = painter.width > constraints.maxWidth;
        painter.dispose();

        // Left in both branches: a name that fits sits at the margin, and one
        // that does not starts there and travels. `ScrollingStatusLine` holds
        // still until it genuinely overflows, but it is only given the line at
        // all when the measurement above says it will move — a viewport and a
        // 50ms timer are not worth arming for every short name.
        if (!overflows) {
          return Align(alignment: Alignment.centerLeft, child: text);
        }
        return ScrollingStatusLine(
          resetKey: game.romname,
          shadowRoom: _onArtShadowRoom,
          children: [text],
        );
      },
    );
  }
}

/// Accumulated play time as a clock glyph and an HH:MM:SS reading, on its own
/// line above the footer's row.
///
/// It was on the row, as a pill, and then as a bare readout among the controls.
/// Both cost the achievements pill beside them width they could not spare — the
/// reading alone is 112 units at 14.r, against a row whose whole surplus on the
/// handheld card is about 46 — so it came off the row entirely for a while.
/// Up here it is free: the line is vertical space, and the row's budget is
/// horizontal.
///
/// White with a drop shadow, not the theme's `onSurface`: this line paints
/// straight onto the game's fanart, which can be any colour under it.
class _InlinePlayTime extends StatelessWidget {
  final GameModel game;

  const _InlinePlayTime({required this.game});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        // `fill: 0` against the app-wide `IconThemeData(fill: 1.0)` in
        // `main.dart`: filled, this glyph is a solid disc with the hands
        // knocked out of it, and a white disc on fanart reads as a badge rather
        // than a clock.
        // 17/15 rather than 20/18. The row below grew when the cloud glyph
        // left it and this line was sized to match, which made a readout that
        // reports on nothing the loudest thing above the artwork. It is a
        // secondary fact and now reads as one; the line's own height is
        // unchanged, so nothing below it moves.
        Icon(
          Symbols.schedule_rounded,
          color: Colors.white,
          size: 17.r,
          fill: 0,
          shadows: _onArtShadows,
        ),
        SizedBox(width: 5.r),
        // Hand-laid cells rather than `FontFeature.tabularFigures()`: Anta
        // carries no `tnum` table, so that feature is silently a no-op and the
        // reading jitters as the seconds tick.
        MonospacedClock(
          text: MonospacedClock.format(game.playTime ?? 0),
          style: TextStyle(
            color: Colors.white,
            fontSize: 15.r,
            fontWeight: FontWeight.w700,
            height: 1.15,
            shadows: _onArtShadows,
          ),
        ),
      ],
    );
  }
}
