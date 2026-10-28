import 'package:neostation/constants/game_view_items.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:provider/provider.dart';
import 'package:neostation/l10n/app_locale.dart';
import 'package:neostation/providers/sqlite_config_provider.dart';
import 'package:neostation/models/game_model.dart';
import 'package:neostation/models/system_model.dart';
import 'package:neostation/sync/i_sync_provider.dart';
import 'package:neostation/widgets/neo_sync_status_icon.dart';
import 'package:neostation/models/retro_achievements_game_info.dart';
import 'package:neostation/screens/game_screen/game_details_card/widgets/game_details_footer.dart';
import 'package:neostation/services/sfx_service.dart';
import 'package:neostation/utils/ra_coverage.dart';
import 'package:neostation/themes/app_themes.dart';
import 'package:neostation/utils/game_utils.dart';
import 'package:neostation/widgets/marquee_text.dart';
import 'package:neostation/themes/chrome_surface.dart';
import '../../themes/corner_radii.dart';

/// A reusable footer used by the game grid and carousel views.
///
/// Mirrors the layout of the details list footer: the game name and optional ROM
/// subtitle are anchored to the left, while the rating, RetroAchievements
/// summary, and Play button are grouped on the right.
class GameViewFooter extends StatelessWidget {
  final GameModel game;
  final VoidCallback onPlay;
  final bool hasRetroAchievements;
  final bool isLoadingAchievements;
  final GameInfoAndUserProgress? currentGameInfo;
  final VoidCallback? onShowAchievements;

  /// Toggles global video sound. The grid and carousel have no video surface of
  /// their own — the preview plays on the secondary display — so this pill is
  /// their only mute affordance, mirroring the Select hint on the details card.
  /// Omit it to hide the pill.
  final VoidCallback? onToggleMute;

  /// Whether the selected game actually has a preview video. There is nothing
  /// to mute without one, so the pill stays hidden rather than offering a
  /// control that does nothing for this game.
  final bool hasVideo;

  /// Whether the selection is a subfolder rather than a game: A descends into
  /// it, so the confirm button reads OPEN instead of PLAY.
  final bool isFolder;

  /// The game's *own* system and the active sync provider, for the cloud-sync
  /// status icon; both null hides it.
  ///
  /// This footer carries that indicator because nothing else in these two
  /// views can: it used to sit on the vertical action rail, which is gone. The
  /// system is the game's rather than the view's, so an aggregate view reports
  /// on the game in front of the user and not on the placeholder it is
  /// browsing under.
  final SystemModel? system;
  final ISyncProvider? syncProvider;

  /// Which games view this footer belongs to ([GameViewItem.grid] or
  /// [GameViewItem.carousel]): each keeps its own choice of what the footer
  /// shows.
  final String view;

  const GameViewFooter({
    super.key,
    required this.game,
    required this.onPlay,
    this.hasRetroAchievements = false,
    this.isLoadingAchievements = false,
    this.currentGameInfo,
    this.onShowAchievements,
    this.onToggleMute,
    this.hasVideo = false,
    this.isFolder = false,
    this.system,
    this.syncProvider,
    this.view = GameViewItem.grid,
  });

  @override
  Widget build(BuildContext context) {
    // Unlike the details-card footer this one mirrors, the grid and carousel
    // footers sit on the flat scaffold surface, not on top of the game's
    // artwork. The white-on-black-shadow treatment inherited from that footer
    // therefore renders as near-invisible ghost text in the light theme
    // (white fill on a light background, readable only via its own outline).
    // Take the colours from the scheme and drop the shadows: there is no busy
    // background here for them to lift the text off.
    final scheme = Theme.of(context).colorScheme;
    // Watched here rather than passed in, like the cloud-mark setting below:
    // the hosts memoize this widget, so a value read there would not reach a
    // footer already built.
    final hidden = GameViewItem.hiddenIn(
      context.select<SqliteConfigProvider, Set<String>>(
        (p) => p.config.gameViewHiddenItems,
      ),
      view,
    );
    bool shown(String item) => !hidden.contains(item);

    return Container(
      padding: EdgeInsets.symmetric(horizontal: 12.r, vertical: 8.r),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          // Identity section: title and optional ROM subtitle.
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                MarqueeText(
                  text: GameUtils.formatGameName(game.name),
                  isActive: true,
                  style: TextStyle(
                    color: scheme.onSurface,
                    fontSize: 18.r,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                // Always reserve the ROM-filename subtitle's line height so the
                // identity column stays a constant height. Unscraped games have
                // no subtitle; without this reservation the shorter column
                // re-centers the rating/RA pill + PLAY row upward. The empty
                // string still lays out a full line box via the forced strut.
                Text(
                  game.showRomFileNameSubtitle && shown(GameViewItem.fileName)
                      ? game.romname
                      : '',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  strutStyle: StrutStyle(
                    fontSize: 12.r,
                    forceStrutHeight: true,
                  ),
                  style: TextStyle(
                    color: scheme.onSurface.withValues(alpha: 0.72),
                    fontSize: 12.r,
                    fontWeight: FontWeight.w400,
                  ),
                ),
              ],
            ),
          ),

          SizedBox(width: 12.r),

          // Action/status section: rating, RetroAchievements, play.
          ExcludeFocus(
            child: Row(
              children: [
                // The cloud mark leads the row, next to the name it reports on
                // rather than among the controls at the far end. It is a marker
                // on the file, not a fact to read, so it stays a bare glyph:
                // the filled chip it wore on the old action rail is what made
                // it read as a button sitting among buttons.
                //
                // It is here and not on the identity column's second line
                // because every "nothing to say" state collapses it to zero
                // size, and that column's height is load-bearing — see the
                // subtitle's forced strut above.
                // Watched here rather than passed in: the views that host this
                // footer memoize the widget instance, so a setting read there
                // would not reach a footer already built.
                if (!isFolder &&
                    system != null &&
                    syncProvider != null &&
                    context.select<SqliteConfigProvider, bool>(
                      (p) => p.config.showCloudSyncIcon,
                    )) ...[
                  NeoSyncStatusIcon(
                    system: system!,
                    game: game,
                    syncProvider: syncProvider!,
                    size: 16.0,
                    showBackground: false,
                    showGlyphShadow: false,
                  ),
                  SizedBox(width: 8.r),
                ],
                if (onToggleMute != null && hasVideo) ...[
                  _MuteHintPill(onToggleMute: onToggleMute!),
                  SizedBox(width: 6.r),
                ],
                if (game.rating > 0 && shown(GameViewItem.rating)) ...[
                  _SteamStyleRating(game: game),
                  SizedBox(width: 6.r),
                ],
                // The details card's own test, shared rather than restated:
                // signed out nothing is ever loaded, so the pill would settle
                // on its "none" state for every game in the library and read as
                // "this game has no achievements" rather than "nobody asked";
                // and a game RetroAchievements has answered zero for gets no
                // pill at all rather than one saying so. A lookup still in
                // flight keeps it — only a settled zero hides it.
                if (shown(GameViewItem.achievements) &&
                    GameDetailsFooter.showsAchievementsFor(
                      context,
                      game: game,
                      hasRetroAchievements: hasRetroAchievements,
                      isLoadingAchievements: isLoadingAchievements,
                      currentGameInfo: currentGameInfo,
                    )) ...[
                  _CompactAchievementsIndicator(
                    game: game,
                    isLoading: isLoadingAchievements,
                    gameInfo: currentGameInfo,
                    onTap: onShowAchievements,
                  ),
                  SizedBox(width: 6.r),
                ],
                // Accumulated play time as its own pill to the left of PLAY
                // (only once the game has been played), mirroring the details
                // card footer.
                if (shown(GameViewItem.playTime) &&
                    GameUtils.formatPlayTime(game.playTime ?? 0) != '0s') ...[
                  _PlayTimePill(game: game),
                  SizedBox(width: 6.r),
                ],
                if (shown(GameViewItem.play)) _buildPlayButton(context),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPlayButton(BuildContext context) {
    return Builder(
      builder: (context) {
        final radii =
            Theme.of(context).extension<CornerRadii>() ?? CornerRadii.m();
        final isFocused = Focus.of(context).hasFocus;
        return AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          height: 32.r,
          decoration: BoxDecoration(
            color: isFocused
                ? const Color(0xFF36F184)
                : const Color(0xFF2ECC71),
            borderRadius: radii.radiusExternal,
            border: Border.all(color: const Color(0xFF36F184), width: 1.r),
            boxShadow: [
              BoxShadow(
                color: Theme.of(
                  context,
                ).colorScheme.shadow.withValues(alpha: 0.1),
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
              borderRadius: radii.radiusExternal,
              onTap: () {
                SfxService().playEnterSound();
                onPlay();
              },
              child: Center(
                child: Padding(
                  padding: EdgeInsets.symmetric(horizontal: 12.r),
                  child: Text(
                    isFolder
                        // Same word the systems view uses for descending into
                        // a container; upper-cased to match PLAY beside it.
                        ? AppLocale.enter.getString(context).toUpperCase()
                        : AppLocale.playButton.getString(context),
                    maxLines: 1,
                    softWrap: false,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.onPrimary,
                      fontWeight: FontWeight.w900,
                      fontSize: 11.r,
                      letterSpacing: 1.5,
                      height: 1.0,
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// The one surface every status pill in this footer draws itself on.
///
/// [ChromeSurface] already unified the *fill*, but the rest of the pill
/// treatment stayed copy-pasted, and the drop shadows had drifted apart: 0.5 on
/// the rating and play-time pills, 0.1 on the achievements pill, none on the
/// mute pill. Because the fill is translucent by design, a shadow underneath it
/// bleeds through and darkens the body — so those three alphas rendered as
/// three visibly different pills side by side, and at 0.5 the rating pill
/// landed darker than the page background and read as pressed next to its
/// raised neighbours.
///
/// Border, radius and elevation now live here alongside the token so they
/// cannot drift again; 0.1 matches the PLAY button next to them.
BoxDecoration _pillDecoration(BuildContext context) {
  final theme = Theme.of(context);
  final radii = theme.extension<CornerRadii>() ?? CornerRadii.m();
  return BoxDecoration(
    color: ChromeSurface.fill(context),
    borderRadius: radii.radiusExternal,
    border: Border.all(color: theme.colorScheme.outline, width: 1.r),
    boxShadow: [
      BoxShadow(
        color: theme.colorScheme.shadow.withValues(alpha: 0.1),
        blurRadius: 4.r,
        offset: Offset(2.0.r, 2.0.r),
      ),
    ],
  );
}

/// A Steam-inspired rating badge that interpolates color based on the score intensity.
/// Compact pill showing accumulated play time as a clock (HH:MM:SS), sized to
/// match the rating / achievements pills in this footer.
class _PlayTimePill extends StatelessWidget {
  final GameModel game;

  const _PlayTimePill({required this.game});

  String _formatClock(int seconds) {
    final h = seconds ~/ 3600;
    final m = (seconds % 3600) ~/ 60;
    final s = seconds % 60;
    String pad(int v) => v.toString().padLeft(2, '0');
    return '${pad(h)}:${pad(m)}:${pad(s)}';
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 32.r,
      padding: EdgeInsets.symmetric(horizontal: 8.r, vertical: 4.r),
      decoration: _pillDecoration(context),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Icon(
            Symbols.schedule_rounded,
            color: Theme.of(context).colorScheme.onSurface,
            size: 15.r,
          ),
          SizedBox(width: 4.r),
          Text(
            _formatClock(game.playTime ?? 0),
            style: TextStyle(
              color: Theme.of(context).colorScheme.onSurface,
              fontSize: 12.r,
              fontWeight: FontWeight.w800,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );
  }
}

class _SteamStyleRating extends StatelessWidget {
  final GameModel game;

  const _SteamStyleRating({required this.game});

  @override
  Widget build(BuildContext context) {
    final ratingValue = (game.rating / 2).clamp(0.0, 10.0);
    final colorRatio = (ratingValue - 1) / 9;
    final customColors = AppThemes.getCustomColors(context);
    final ratingColor = Color.lerp(
      customColors.errorColor,
      customColors.successColor,
      colorRatio,
    )!;

    return Container(
      height: 32.r,
      padding: EdgeInsets.symmetric(horizontal: 8.r, vertical: 4.r),
      decoration: _pillDecoration(context),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Icon(Symbols.star_rounded, color: ratingColor, size: 15.r),
          SizedBox(width: 4.r),
          // Reserve width for the widest possible value ("10") so the pill
          // stays a static size regardless of the current score (e.g. "1"
          // no longer renders narrower than "10"). Scale/font-independent.
          Stack(
            alignment: Alignment.centerLeft,
            children: [
              Opacity(
                opacity: 0,
                child: Text(
                  '10',
                  style: TextStyle(fontSize: 13.r, fontWeight: FontWeight.w900),
                ),
              ),
              Text(
                ratingValue.toStringAsFixed(0),
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurface,
                  fontSize: 13.r,
                  fontWeight: FontWeight.w900,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Compact RetroAchievements indicator reused from the details footer.
class _CompactAchievementsIndicator extends StatelessWidget {
  final GameModel game;
  final bool isLoading;
  final GameInfoAndUserProgress? gameInfo;
  final VoidCallback? onTap;

  const _CompactAchievementsIndicator({
    required this.game,
    required this.isLoading,
    this.gameInfo,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final radii = Theme.of(context).extension<CornerRadii>() ?? CornerRadii.m();

    // The bundled snapshot already records how many achievements a matched
    // game has, so the total needs no network call — only the user's earned
    // count does. Show it straight away instead of a spinner, and let the live
    // lookup overwrite it when it lands.
    final localTotal = game.raCoverage == RaCoverage.matched
        ? (game.raNumAchievements ?? 0)
        : 0;
    final total = gameInfo?.numAchievements ?? localTotal;
    final awarded = gameInfo?.numAwardedToUser;
    final knowsProgress = awarded != null && gameInfo != null;

    final noAchievements = !isLoading && total == 0;

    // A dash rather than a zero while the earned count is outstanding: "0/45"
    // is a claim about the user's progress that has not been fetched yet. And
    // zero only reads as "No Achievements" when RetroAchievements actually
    // answered: a ROM nothing could hash says "Unknown", the same word the
    // search screen's achievements filter files it under.
    final progressText = total > 0
        ? (knowsProgress ? '$awarded/$total' : '\u2013/$total')
        : (isLoading
              ? AppLocale.loading.getString(context)
              : raCoverageAnswersZero(game.raCoverage)
              ? AppLocale.noAchievements.getString(context)
              : AppLocale.raCoverageUnknown.getString(context));

    // Whether the earned count is still outstanding for a game that has
    // achievements to earn. The bundled snapshot gives us the total instantly,
    // so this gap is every single selection change.
    final awaitingProgress = !knowsProgress && total > 0;

    // Always determinate. This used to run an indeterminate bar through the
    // gap above, which put an orange sweep across the pill on every game the
    // user moved onto — a flash that said "working" about a lookup that
    // resolves in a moment and that the text ("-/45") already reports.
    final progress = knowsProgress && total > 0 ? awarded / total : 0.0;

    final theme = Theme.of(context);
    // Orange is for a real, known score; an empty bar that is empty only
    // because nobody has answered yet stays neutral.
    final statusColor = noAchievements || awaitingProgress
        ? theme.colorScheme.onSurface
        : Colors.orange;

    final gameIconUrl = gameInfo?.imageIcon.isNotEmpty == true
        ? 'https://media.retroachievements.org${gameInfo!.imageIcon}'
        : null;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () {
          if (onTap == null) return;
          SfxService().playNavSound();
          onTap!();
        },
        canRequestFocus: false,
        focusColor: Colors.transparent,
        hoverColor: Colors.transparent,
        highlightColor: Colors.transparent,
        splashColor: theme.colorScheme.onSurface.withValues(alpha: 0.1),
        // Clip the ripple to the pill's own outline rather than the tighter
        // inner radius, so it doesn't square off against the rounded corners.
        borderRadius: radii.radiusExternal,
        child: Container(
          width: 101.r,
          height: 32.r,
          decoration: _pillDecoration(context),
          child: Padding(
            // Match the rating pill's 8.r horizontal inset so the trophy icon
            // doesn't hug the pill's left border (the pill's width above is
            // widened to 101.r to absorb the padding + the 6.r icon→text gap
            // without squeezing the 56.r text/progress column).
            padding: EdgeInsets.symmetric(horizontal: 8.r, vertical: 3.r),
            child: Row(
              children: [
                ClipRRect(
                  borderRadius: radii.radiusInternal,
                  child: Container(
                    width: 22.r,
                    height: 22.r,
                    color: theme.colorScheme.surface,
                    child: gameIconUrl != null
                        ? Image.network(
                            gameIconUrl,
                            fit: BoxFit.cover,
                            errorBuilder: (_, _, _) => Icon(
                              Symbols.emoji_events_rounded,
                              color: statusColor,
                              size: 12.r,
                            ),
                          )
                        : Icon(
                            Symbols.emoji_events_rounded,
                            color: statusColor,
                            size: 12.r,
                          ),
                  ),
                ),
                SizedBox(width: 6.r),
                Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(
                      width: 56.r,
                      child: Text(
                        progressText.toUpperCase(),
                        style: TextStyle(
                          color: theme.colorScheme.onSurface,
                          fontSize: 8.r,
                          fontWeight: FontWeight.bold,
                          letterSpacing: 0.5,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    SizedBox(height: 2.r),
                    // Bar is deliberately narrower than the 56.r text row so it
                    // doesn't run to the pill's right edge — leaves a right
                    // margin under the progress count.
                    SizedBox(
                      width: 46.r,
                      child: ClipRRect(
                        borderRadius: radii.radiusInternal,
                        child: LinearProgressIndicator(
                          value: progress,
                          minHeight: 3.5.r,
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
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Select-tap hint + current sound state for the preview video, tappable for
/// touchscreen users. Watches the config provider on its own so the memoized
/// footer instance around it never has to rebuild when sound is toggled.
class _MuteHintPill extends StatelessWidget {
  final VoidCallback onToggleMute;

  const _MuteHintPill({required this.onToggleMute});

  @override
  Widget build(BuildContext context) {
    final radii = Theme.of(context).extension<CornerRadii>() ?? CornerRadii.m();
    final scheme = Theme.of(context).colorScheme;

    return Selector<SqliteConfigProvider, bool>(
      selector: (_, provider) => !provider.config.videoSound,
      builder: (context, isMuted, _) {
        // Structured like the achievements pill — transparent Material for the
        // ink, decoration on the Container — so both resolve to the same fill.
        return Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: () {
              SfxService().playNavSound();
              onToggleMute();
            },
            canRequestFocus: false,
            borderRadius: radii.radiusExternal,
            child: Container(
              height: 32.r,
              padding: EdgeInsets.symmetric(horizontal: 8.r, vertical: 4.r),
              decoration: _pillDecoration(context),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Image.asset(
                    'assets/images/gamepad/Xbox_View_button.png',
                    width: 15.r,
                    height: 15.r,
                    color: scheme.onSurface,
                  ),
                  SizedBox(width: 4.r),
                  Icon(
                    isMuted
                        ? Symbols.volume_off_rounded
                        : Symbols.volume_up_rounded,
                    size: 15.r,
                    color: scheme.onSurface,
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
