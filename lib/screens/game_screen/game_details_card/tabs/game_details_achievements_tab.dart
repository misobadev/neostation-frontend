import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:neostation/l10n/app_locale.dart';
import 'package:neostation/services/sfx_service.dart';
import 'package:neostation/screens/game_screen/game_details_card/widgets/header_action_button.dart';
import 'package:neostation/screens/game_screen/game_details_card/widgets/panel_gate_highlight.dart';
import 'package:neostation/themes/chrome_surface.dart';
import 'package:neostation/themes/corner_radii.dart';
import '../../../../models/retro_achievements_game_info.dart';

/// How far the panel's content sits from its own edge, horizontally.
///
/// Wider than the 8.r it keeps vertically, and deliberately so. The card is
/// laid out against a 640x480 design and `.r` scales off the shorter axis, so
/// on the 16:9 panels the app actually runs on an inset that reads as generous
/// top-to-bottom is tight left-to-right. It cost this panel more than most:
/// every other edge in here is text or a chip, which carries its own optical
/// bearing, while the badge grid is a block of hard-edged artwork that filled
/// its column exactly and left the outermost tiles butting into the accent
/// edge. Matching the 12.r the panel itself is inset from the card gives the
/// grid the same air the text already had.
const double _contentInsetH = 12.0;

/// An overlay component that renders RetroAchievements progress, stats, and a navigable grid.
///
/// Handles heuristic sorting (unlocked first), percentage calculation, and
/// bidirectional gamepad navigation for trophy exploration.
class GameDetailsAchievementsTab extends StatefulWidget {
  final GameInfoAndUserProgress? gameInfo;
  final bool isLoading;

  /// How many achievements the bundled snapshot lists for this game, or `null`
  /// when it is not matched. Known without any lookup, which is what lets the
  /// header be right while [gameInfo] is still outstanding.
  final int? snapshotAchievementTotal;
  final VoidCallback onRefresh;
  final double topOffset;
  final double bottomOffset;
  final double leftOffset;
  final double rightOffset;
  final Widget? headerAction;

  /// Opens the manual match picker. Shown both when a set was found (the match
  /// may still be the wrong one) and when none was, which is where a user is
  /// most likely to want it.
  final VoidCallback? onFixMatch;

  /// The ROM's RetroAchievements hash, or `null` when it has not been hashed.
  ///
  /// The one fact that explains every state this panel can be in: a set that
  /// looks wrong was matched from this string, and a game with no set at all
  /// either has no hash yet or has one RetroAchievements does not know. It is
  /// also what a user is asked for when they report a missing set, so it is
  /// worth being readable rather than only being in the database.
  final String? raHash;

  const GameDetailsAchievementsTab({
    super.key,
    this.gameInfo,
    required this.isLoading,
    this.snapshotAchievementTotal,
    required this.onRefresh,
    this.topOffset = 55.0,
    this.bottomOffset = 110.0,
    this.leftOffset = 12.0,
    this.rightOffset = 12.0,
    this.headerAction,
    this.onFixMatch,
    this.raHash,
  });

  @override
  State<GameDetailsAchievementsTab> createState() =>
      GameDetailsAchievementsTabState();
}

class GameDetailsAchievementsTabState
    extends State<GameDetailsAchievementsTab> {
  int _selectedAchievementIndex = 0;
  final Map<int, GlobalKey> _achievementKeys = {};
  final ScrollController _scrollController = ScrollController();

  /// Whether the panel owns the D-pad.
  ///
  /// Reaching this tab must not swallow the D-pad: while inactive, left/right
  /// keep walking the details tabs and up/down keep moving the game list, so
  /// there is always a way out. A activates the panel, B leaves it.
  bool _isPanelActive = false;

  /// Which header action holds focus, or -1 while the badge grid does.
  ///
  /// Up from the grid's top row lands here, down goes back to the badges, and
  /// left/right walk the actions — so REFRESH and FIX MATCH are reachable
  /// without a touchscreen.
  int _headerFocusIndex = -1;

  /// Whether the panel currently owns the D-pad.
  bool get isPanelActive => _isPanelActive;

  /// Hands the D-pad to the panel. Returns whether the input was consumed.
  ///
  /// Refuses only when there is nothing to reach at all — no badges *and* no
  /// header action — since activating an empty panel is the trap this gate
  /// exists to prevent. An unmatched game keeps its FIX MATCH reachable.
  bool enterPanel() {
    if (_isPanelActive) return true; // Already inside — A stays consumed.

    final hasBadges = _getSortedAchievements().isNotEmpty;
    if (!hasBadges && _headerActions().isEmpty) return false;

    setState(() {
      _isPanelActive = true;
      // With no badges to land on, the header is the only place to be.
      _headerFocusIndex = hasBadges ? -1 : 0;
    });
    if (hasBadges) {
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => _scrollToSelectedAchievement(),
      );
    }
    return true;
  }

  /// Gives the D-pad back to the details card. Returns whether it was held.
  bool exitPanel() {
    if (!_isPanelActive) return false;

    setState(() {
      _isPanelActive = false;
      _headerFocusIndex = -1;
    });
    return true;
  }

  /// Runs the focused header action (gamepad A).
  ///
  /// Always reports the button as consumed while the panel is active: A must
  /// not fall through and launch the game from under a panel the user is
  /// still navigating.
  bool activateFocused() {
    if (!_isPanelActive) return false;

    final actions = _headerActions();
    if (_headerFocusIndex >= 0 && _headerFocusIndex < actions.length) {
      SfxService().playNavSound();
      actions[_headerFocusIndex].onTap();
    }
    return true;
  }

  @override
  void didUpdateWidget(GameDetailsAchievementsTab oldWidget) {
    super.didUpdateWidget(oldWidget);

    // A different game means a different set: start at its first badge rather
    // than an index that pointed into the previous game's grid.
    final oldId = oldWidget.gameInfo?.id;
    final newId = widget.gameInfo?.id;
    if (oldId != newId) {
      _selectedAchievementIndex = 0;
      _isPanelActive = false;
      _headerFocusIndex = -1;
    }
  }

  /// The header actions the D-pad can reach, in the order they are drawn.
  ///
  /// The gate chip is deliberately absent: it is a legend for A/B, not a
  /// button to land on. An unmatched game has no set to refresh, so FIX MATCH
  /// is all it offers.
  List<_HeaderAction> _headerActions() {
    return [
      if (widget.gameInfo != null)
        _HeaderAction(label: AppLocale.refresh, onTap: widget.onRefresh),
      if (widget.onFixMatch != null)
        _HeaderAction(label: AppLocale.raFixMatch, onTap: widget.onFixMatch!),
    ];
  }

  /// Moves header focus by [delta], clamped to the ends so the run of actions
  /// has edges rather than wrapping under the user.
  void _moveHeaderFocus(int delta) {
    final actions = _headerActions();
    if (actions.isEmpty) return;
    final next = (_headerFocusIndex + delta).clamp(0, actions.length - 1);
    if (next == _headerFocusIndex) return;
    setState(() => _headerFocusIndex = next);
  }

  /// Lazily retrieves or creates a GlobalKey for an achievement item to enable 'ensureVisible' logic.
  GlobalKey _getAchievementKey(int index) {
    return _achievementKeys.putIfAbsent(index, () => GlobalKey());
  }

  /// Sorts achievements by unlock status (priority) and then by original display order.
  List<Achievement> _getSortedAchievements() {
    if (widget.gameInfo == null) return [];
    final achievements = widget.gameInfo!.achievements.values.toList();
    achievements.sort((Achievement a, Achievement b) {
      final aUnlocked = a.dateEarned != null && a.dateEarned!.isNotEmpty;
      final bUnlocked = b.dateEarned != null && b.dateEarned!.isNotEmpty;

      // Secondary-sort unlocked achievements to the top of the grid.
      if (aUnlocked != bUnlocked) {
        return aUnlocked ? -1 : 1;
      }
      return a.displayOrder.compareTo(b.displayOrder);
    });
    return achievements;
  }

  /// Ensures the currently focused achievement is scrolled into the viewport.
  void _scrollToSelectedAchievement() {
    final key = _achievementKeys[_selectedAchievementIndex];
    if (key?.currentContext != null) {
      Scrollable.ensureVisible(
        key!.currentContext!,
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOut,
        alignment: 0.5,
      );
    }
  }

  /// Gamepad navigation delegate: Move focus up by one grid row (6 items), or
  /// out of the grid's top row and into the header actions.
  void moveUp() {
    if (!_isPanelActive) return;
    if (_headerFocusIndex >= 0) return; // Already at the top of the panel.

    final achievements = _getSortedAchievements();
    final count = achievements.length;
    if (count == 0) return;

    if (_selectedAchievementIndex < 6) {
      if (_headerActions().isEmpty) return;
      setState(() => _headerFocusIndex = 0);
      return;
    }

    setState(() => _selectedAchievementIndex -= 6);
    _scrollToSelectedAchievement();
  }

  /// Gamepad navigation delegate: Move focus down by one grid row (6 items),
  /// or back into the grid from the header actions.
  void moveDown() {
    if (!_isPanelActive) return;

    final achievements = _getSortedAchievements();
    final count = achievements.length;

    if (_headerFocusIndex >= 0) {
      if (count == 0) return; // Nothing below the header to drop into.
      setState(() => _headerFocusIndex = -1);
      _scrollToSelectedAchievement();
      return;
    }

    if (count == 0) return;
    setState(() {
      if (_selectedAchievementIndex + 6 < count) {
        _selectedAchievementIndex += 6;
      }
    });
    _scrollToSelectedAchievement();
  }

  /// Gamepad navigation delegate: Move focus left by one badge, or one header
  /// action while the header holds focus.
  void moveLeft() {
    if (!_isPanelActive) return;
    if (_headerFocusIndex >= 0) {
      _moveHeaderFocus(-1);
      return;
    }

    final achievements = _getSortedAchievements();
    final count = achievements.length;
    if (count == 0) return;
    setState(() {
      _selectedAchievementIndex =
          (_selectedAchievementIndex - 1 + count) % count;
    });
    _scrollToSelectedAchievement();
  }

  /// Gamepad navigation delegate: Move focus right by one badge, or one header
  /// action while the header holds focus.
  void moveRight() {
    if (!_isPanelActive) return;
    if (_headerFocusIndex >= 0) {
      _moveHeaderFocus(1);
      return;
    }

    final achievements = _getSortedAchievements();
    final count = achievements.length;
    if (count == 0) return;
    setState(() {
      _selectedAchievementIndex = (_selectedAchievementIndex + 1) % count;
    });
    _scrollToSelectedAchievement();
  }

  /// Action trigger delegate: Currently unused for achievements (selection is purely visual).
  void trigger() {}

  /// The ROM's RetroAchievements hash, along the foot of the panel.
  ///
  /// Drawn in every one of the panel's three states and always at the same
  /// height, because the state it is most useful in — no set found — is the one
  /// a user reaches by *waiting* through the other two, and a line that arrives
  /// only at the end would shift the badge grid up as the fetch lands. A game
  /// that has not been hashed yet reads as a dash rather than dropping the line,
  /// which is itself the answer to "why is there no set here".
  Widget _buildHashLine(BuildContext context) {
    final String hash = (widget.raHash ?? '').trim();
    final Color color = Theme.of(
      context,
    ).colorScheme.onSurface.withValues(alpha: 0.5);

    return Padding(
      padding: EdgeInsets.fromLTRB(
        _contentInsetH.r,
        4.r,
        _contentInsetH.r,
        8.r,
      ),
      child: Row(
        children: [
          Icon(Symbols.tag_rounded, size: 12.r, color: color),
          SizedBox(width: 4.r),
          Text(
            '${AppLocale.raHash.getString(context)}:',
            style: TextStyle(fontSize: 11.r, color: color),
          ),
          SizedBox(width: 4.r),
          Expanded(
            // Scaled down rather than clipped. A hash is read character by
            // character against one on a website, so the one thing this line
            // must never do is hide its tail: an ellipsis would leave a string
            // that looks complete and is not. `scaleDown` renders it at the
            // full size below whenever the panel is wide enough and only
            // shrinks it \u2014 whole \u2014 when it is not.
            child: FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: Text(
                hash.isEmpty ? '\u2013' : hash,
                maxLines: 1,
                softWrap: false,
                style: TextStyle(
                  fontSize: 11.r,
                  // Monospaced, like every other raw identifier the app shows:
                  // a proportional font makes that character-by-character
                  // comparison harder than it needs to be.
                  fontFamily: 'monospace',
                  color: color,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final radii = Theme.of(context).extension<CornerRadii>() ?? CornerRadii.m();

    // Scenario 1: Metadata is being fetched.
    if (widget.gameInfo == null) {
      if (widget.isLoading) {
        // Same shell, same header, same grid geometry as a resolved set: only
        // the numbers and the badges are outstanding. Replacing the panel with
        // a centred spinner and a "loading" line meant its whole shape changed
        // and changed back around a fetch, which read as a flash rather than
        // as progress. The count comes from the bundled snapshot, so for a
        // matched game the header is right from the first frame and only the
        // earned figure is a dash.
        final int? snapshotTotal = widget.snapshotAchievementTotal;

        return Positioned(
          left: widget.leftOffset.r,
          right: widget.rightOffset.r,
          top: widget.topOffset.r,
          bottom: widget.bottomOffset.r,
          child: Container(
            decoration: BoxDecoration(
              color: ChromeSurface.fill(context),
              borderRadius: radii.radiusExternal,
              // Invisible, but it holds the same inset the settled panel's
              // gate edge takes. A border is part of a box, so a loading
              // shell built without one is 2.r wider on the inside than the
              // panel that replaces it, and every line of content stepped in
              // by that much on the frame the set landed — the one shift this
              // shell exists to avoid.
              border: PanelGateHighlight.border(
                context,
                isDrivable: false,
                isActive: false,
                restingColor: Colors.transparent,
              ),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.25),
                  blurRadius: 2.r,
                  offset: Offset(2.0.r, 2.0.r),
                ),
              ],
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: EdgeInsets.fromLTRB(
                    _contentInsetH.r,
                    8.r,
                    _contentInsetH.r,
                    0,
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(
                            Symbols.emoji_events_rounded,
                            color: Colors.orange,
                            size: 13.r,
                          ),
                          SizedBox(width: 8.r),
                          // A dash rather than a zero for the figure nobody
                          // has answered yet — the same reading the footer
                          // pill gives the same gap.
                          if (snapshotTotal != null && snapshotTotal > 0)
                            Text(
                              '\u2013 / $snapshotTotal  \u00b7  \u2013%',
                              style: TextStyle(
                                color: Theme.of(
                                  context,
                                ).colorScheme.onSurface.withValues(alpha: 0.75),
                                fontSize: 11.r,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          const Spacer(),
                          // Holds open exactly the height the settled header's
                          // action chips will take. A chip is taller than the
                          // count text beside it, so a header built without one
                          // is shorter than the header that replaces it, and
                          // the divider and the whole badge grid stepped down
                          // at the moment the set landed. Reserving it with the
                          // real widget rather than a measured constant is what
                          // keeps the two headers the same height if the chip's
                          // padding ever changes.
                          Visibility(
                            visible: false,
                            maintainSize: true,
                            maintainAnimation: true,
                            maintainState: true,
                            child: HeaderActionButton(
                              // Label-only, like every chip the settled header
                              // draws now that the gate chip and its button
                              // glyph are gone: the glyph used to be what set
                              // the row's height, so reserving one here would
                              // hold the loading header open taller than the
                              // header that replaces it.
                              label: AppLocale.refresh
                                  .getString(context)
                                  .toUpperCase(),
                              onTap: () {},
                              backgroundColor: Colors.transparent,
                              foregroundColor: Colors.transparent,
                            ),
                          ),
                        ],
                      ),
                      // The one moving element, and it sits exactly where the
                      // divider does once the set lands, so nothing shifts
                      // when it goes.
                      SizedBox(
                        height: 10.r,
                        child: Center(
                          child: LinearProgressIndicator(
                            minHeight: 1.r,
                            backgroundColor: Theme.of(
                              context,
                            ).colorScheme.onSurface.withValues(alpha: 0.1),
                            color: Theme.of(
                              context,
                            ).colorScheme.onSurface.withValues(alpha: 0.35),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: Padding(
                    padding: EdgeInsets.symmetric(horizontal: _contentInsetH.r),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // The left pane holds the focused badge's text, and
                        // there is no focused badge yet.
                        const Expanded(flex: 4, child: SizedBox.shrink()),
                        SizedBox(width: 12.r),
                        Expanded(
                          flex: 6,
                          child: _AchievementsSkeleton(count: snapshotTotal),
                        ),
                      ],
                    ),
                  ),
                ),
                _buildHashLine(context),
              ],
            ),
          ),
        );
      }

      // Scenario 2: Data is missing or system is unsupported.
      return Positioned(
        left: widget.leftOffset.r,
        right: widget.rightOffset.r,
        top: widget.topOffset.r,
        bottom: widget.bottomOffset.r,
        child: Container(
          decoration: BoxDecoration(
            color: ChromeSurface.fill(context),
            borderRadius: radii.radiusExternal,
            // Invisible, and here for the same reason the loading shell above
            // draws one: a border is part of a box's inset, so a panel built
            // without one is 2.r wider and taller on the inside than the two
            // panels that draw a gate edge. Every line of this state's content
            // sat 2.r further out and further down than the same line on a
            // matched game — measured as a 6px step on the hash line, which is
            // the element close enough to the edge to make it obvious.
            border: PanelGateHighlight.border(
              context,
              isDrivable: false,
              isActive: false,
              restingColor: Colors.transparent,
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.25),
                blurRadius: 2.r,
                offset: Offset(2.0.r, 2.0.r),
              ),
            ],
          ),
          // Column rather than a bare Center: the hash line sits at the foot of
          // this state too, and this is the state it earns its place in — the
          // string a user needs to look the game up with, on the panel that
          // just told them there is nothing to look up.
          child: Column(
            children: [
              Expanded(
                child: Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Symbols.videogame_asset_off_rounded,
                        size: 48.r,
                        color: Theme.of(context).colorScheme.onSurface,
                      ),
                      SizedBox(height: 16.r),
                      Text(
                        AppLocale.noAchievementsFound.getString(context),
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.onSurface,
                          fontSize: 14.r,
                        ),
                      ),
                      if (widget.onFixMatch != null) ...[
                        SizedBox(height: 12.r),
                        HeaderActionButton(
                          isFocused: _isPanelActive && _headerFocusIndex == 0,
                          label: AppLocale.raFixMatch
                              .getString(context)
                              .toUpperCase(),
                          onTap: widget.onFixMatch!,
                          backgroundColor: Theme.of(
                            context,
                          ).colorScheme.primary,
                          foregroundColor: Theme.of(
                            context,
                          ).colorScheme.onPrimary,
                        ),
                      ],
                    ],
                  ),
                ),
              ),
              _buildHashLine(context),
            ],
          ),
        ),
      );
    }

    // Scenario 3: Achievements resolved successfully.
    final achievements = _getSortedAchievements();
    final headerActions = _headerActions();
    final total = achievements.length;
    final unlocked = achievements
        .where((a) => a.dateEarned != null && a.dateEarned!.isNotEmpty)
        .length;
    final percentage = total > 0
        ? (unlocked / total * 100).toStringAsFixed(0)
        : '0';

    return Positioned(
      left: widget.leftOffset.r,
      right: widget.rightOffset.r,
      top: widget.topOffset.r,
      bottom: widget.bottomOffset.r,
      // The panel is its own affordance now: its edge lights up while there
      // is a set in here to walk, and a tap anywhere on it is the touch
      // equivalent of the A gate. B is still the way back out.
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onTap: () {
          if (_isPanelActive || achievements.isEmpty) return;
          SfxService().playNavSound();
          enterPanel();
        },
        child: AnimatedContainer(
          duration: PanelGateHighlight.duration,
          curve: Curves.easeOut,
          decoration: BoxDecoration(
            color: ChromeSurface.fill(context),
            borderRadius: radii.radiusExternal,
            border: PanelGateHighlight.border(
              context,
              isDrivable: achievements.isNotEmpty,
              isActive: _isPanelActive,
              restingColor: Colors.transparent,
            ),
            boxShadow: PanelGateHighlight.shadows(
              context,
              isActive: _isPanelActive,
              resting: BoxShadow(
                color: Theme.of(
                  context,
                ).colorScheme.shadow.withValues(alpha: 0.25),
                blurRadius: 2.r,
                offset: Offset(2.0.r, 2.0.r),
              ),
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Header: Contains progress stats and the manual refresh action.
              Padding(
                padding: EdgeInsets.fromLTRB(
                  _contentInsetH.r,
                  8.r,
                  _contentInsetH.r,
                  0,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // One line, three zones: identity, progress, actions. The
                    // count is flexible so a long title can never crash into it
                    // (the header used to be two fixed Rows in a spaceBetween,
                    // which is why the title butted up against the count chip),
                    // and it is plain muted text rather than a filled pill: the
                    // card's own footer already carries the progress bar, so a
                    // second high-contrast block of the same numbers was the
                    // loudest thing in the panel.
                    Row(
                      children: [
                        Icon(
                          Symbols.emoji_events_rounded,
                          color: Colors.orange,
                          size: 13.r,
                        ),
                        SizedBox(width: 8.r),
                        // No title: the selected tab in the card's header strip
                        // is already the trophy, so naming the panel again only
                        // costs the actions room they need.
                        Text(
                          '$unlocked / $total  ·  $percentage%',
                          style: TextStyle(
                            color: Theme.of(
                              context,
                            ).colorScheme.onSurface.withValues(alpha: 0.75),
                            fontSize: 11.r,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const Spacer(),
                        Row(
                          children: [
                            // No gate chip: the panel's own edge says whether
                            // there is a set in here to walk and whether it
                            // currently holds the D-pad, which leaves this row to
                            // the actions the D-pad actually walks.
                            // Label-only chips: they are D-pad targets now, so a
                            // button glyph on them would advertise a shortcut
                            // that no longer exists.
                            for (final (index, action) in headerActions.indexed)
                              Padding(
                                padding: EdgeInsets.only(
                                  left: index == 0 ? 0 : 6.r,
                                ),
                                child: HeaderActionButton(
                                  label: action.label
                                      .getString(context)
                                      .toUpperCase(),
                                  onTap: () {
                                    setState(() => _headerFocusIndex = index);
                                    action.onTap();
                                  },
                                  isFocused:
                                      _isPanelActive &&
                                      _headerFocusIndex == index,
                                  backgroundColor: Theme.of(
                                    context,
                                  ).colorScheme.surfaceContainerHighest,
                                  foregroundColor: Theme.of(
                                    context,
                                  ).colorScheme.onSurface,
                                ),
                              ),
                            if (widget.headerAction != null) ...[
                              SizedBox(width: 6.r),
                              widget.headerAction!,
                            ],
                          ],
                        ),
                      ],
                    ),
                    Divider(
                      color: Theme.of(
                        context,
                      ).colorScheme.onSurface.withValues(alpha: 0.1),
                      height: 10.r,
                    ),
                  ],
                ),
              ),

              // Content: Dual-pane layout (Metadata on left, Grid on right).
              Expanded(
                child: Padding(
                  padding: EdgeInsets.symmetric(horizontal: _contentInsetH.r),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        flex: 4,
                        child: _SelectedAchievementInfo(
                          achievements: achievements,
                          selectedIndex: _selectedAchievementIndex,
                        ),
                      ),
                      SizedBox(width: 12.r),
                      Expanded(
                        flex: 6,
                        child: _AchievementsGrid(
                          achievements: achievements,
                          selectedIndex: _selectedAchievementIndex,
                          // The badges are only live while the header cursor
                          // is parked.
                          isFocused: _isPanelActive && _headerFocusIndex < 0,
                          scrollController: _scrollController,
                          getKey: _getAchievementKey,
                          onSelect: (index) {
                            SfxService().playNavSound();
                            setState(() {
                              _selectedAchievementIndex = index;
                              // A tap is the touch equivalent of the A gate.
                              _isPanelActive = true;
                              _headerFocusIndex = -1;
                            });
                          },
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              _buildHashLine(context),
            ],
          ),
        ),
      ),
    );
  }
}

/// A compact button styled for the achievement header.
/// A D-pad reachable action in the achievements header.
class _HeaderAction {
  /// Localization key for the chip's label.
  final String label;

  final VoidCallback onTap;

  const _HeaderAction({required this.label, required this.onTap});
}

/// Pane that displays the title, description, and point value of the focused achievement.
class _SelectedAchievementInfo extends StatelessWidget {
  final List<Achievement> achievements;
  final int selectedIndex;

  const _SelectedAchievementInfo({
    required this.achievements,
    required this.selectedIndex,
  });

  @override
  Widget build(BuildContext context) {
    final radii = Theme.of(context).extension<CornerRadii>() ?? CornerRadii.m();
    if (achievements.isEmpty) return const SizedBox.shrink();
    final safeIndex = selectedIndex.clamp(0, achievements.length - 1);
    final achievement = achievements[safeIndex];
    final isUnlocked =
        achievement.dateEarned != null && achievement.dateEarned!.isNotEmpty;

    // Title, description and points read as one block. They used to be pinned
    // to opposite ends of the pane, which left a gap the size of the artwork
    // grid between a two-line description and its points chip.
    return Align(
      alignment: Alignment.topCenter,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Text(
              achievement.title,
              style: TextStyle(
                color: isUnlocked
                    ? Colors.orange
                    : Theme.of(context).colorScheme.onSurface,
                fontSize: 10.r,
                fontWeight: FontWeight.bold,
              ),
              textAlign: TextAlign.center,
            ),
            SizedBox(height: 6.r),
            Text(
              achievement.description,
              style: TextStyle(
                color: Theme.of(
                  context,
                ).colorScheme.onSurface.withValues(alpha: 0.8),
                fontSize: 9.r,
                height: 1.4,
              ),
              textAlign: TextAlign.center,
            ),
            SizedBox(height: 8.r),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  padding: EdgeInsets.symmetric(horizontal: 6.r, vertical: 2.r),
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.secondary,
                    borderRadius: radii.radiusInternal,
                  ),
                  child: Text(
                    '${achievement.points} ${AppLocale.points.getString(context)}',
                    style: TextStyle(color: Colors.white, fontSize: 9.r),
                  ),
                ),
                if (isUnlocked) ...[
                  SizedBox(width: 6.r),
                  Text(
                    AppLocale.unlocked.getString(context),
                    style: TextStyle(
                      color: Colors.greenAccent,
                      fontSize: 10.r,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Navigable grid of trophy badges loaded dynamically from RetroAchievements infrastructure.
/// Placeholder badges shown while a set is being fetched.
///
/// Mirrors [_AchievementsGrid]'s geometry exactly, so the real badges land in
/// the tiles the placeholders were already occupying instead of arriving into
/// an empty pane. Static rather than shimmering: the header's progress line is
/// already saying that something is happening, and a second animation for the
/// same fact is the noise this panel was rebuilt to lose.
class _AchievementsSkeleton extends StatelessWidget {
  /// How many tiles to draw. Falls back to a plausible grid when the snapshot
  /// has no count, and is capped because the pane scrolls anyway — the tiles
  /// past the fold would never be seen.
  final int? count;

  const _AchievementsSkeleton({required this.count});

  static const int _fallbackCount = 24;
  static const int _maxCount = 36;

  @override
  Widget build(BuildContext context) {
    final radii = Theme.of(context).extension<CornerRadii>() ?? CornerRadii.m();
    final int tiles = (count ?? _fallbackCount).clamp(1, _maxCount);

    return GridView.builder(
      physics: const NeverScrollableScrollPhysics(),
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 6,
        crossAxisSpacing: 4.r,
        mainAxisSpacing: 4.r,
        childAspectRatio: 1.0,
      ),
      itemCount: tiles,
      itemBuilder: (context, index) => DecoratedBox(
        decoration: BoxDecoration(
          color: Theme.of(
            context,
          ).colorScheme.onSurface.withValues(alpha: 0.06),
          borderRadius: radii.radiusInternal,
        ),
      ),
    );
  }
}

class _AchievementsGrid extends StatelessWidget {
  final List<Achievement> achievements;
  final int selectedIndex;
  final ScrollController scrollController;
  final GlobalKey Function(int) getKey;
  final ValueChanged<int> onSelect;

  /// Whether the grid owns the D-pad. Drives how loud the cursor is drawn: a
  /// full cursor on a grid that ignores the D-pad is what made the tab look
  /// stuck.
  final bool isFocused;

  const _AchievementsGrid({
    required this.achievements,
    required this.selectedIndex,
    required this.isFocused,
    required this.scrollController,
    required this.getKey,
    required this.onSelect,
  });

  @override
  Widget build(BuildContext context) {
    final radii = Theme.of(context).extension<CornerRadii>() ?? CornerRadii.m();
    return GridView.builder(
      controller: scrollController,
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 6,
        crossAxisSpacing: 4.r,
        mainAxisSpacing: 4.r,
        childAspectRatio: 1.0,
      ),
      itemCount: achievements.length,
      itemBuilder: (context, index) {
        final achievement = achievements[index];
        final isUnlocked =
            achievement.dateEarned != null &&
            achievement.dateEarned!.isNotEmpty;
        final isSelected = index == selectedIndex;

        return GestureDetector(
          key: getKey(index),
          onTap: () => onSelect(index),
          child: Container(
            decoration: BoxDecoration(
              border: Border.all(
                color: isSelected
                    ? Theme.of(context).colorScheme.secondary.withValues(
                        alpha: isFocused ? 1.0 : 0.35,
                      )
                    : (isUnlocked
                          ? Colors.orange.withValues(alpha: 0.5)
                          : Colors.transparent),
                width: isSelected ? 2.r : 1.r,
              ),
              borderRadius: radii.radiusInternal,
            ),
            child: ClipRRect(
              borderRadius: radii.radiusInternal,
              child: Image.network(
                // Use the standard RA Badge CDN protocol for locked vs unlocked icons.
                isUnlocked
                    ? 'https://media.retroachievements.org/Badge/${achievement.badgeName}.png'
                    : 'https://media.retroachievements.org/Badge/${achievement.badgeName}_lock.png',
                cacheWidth: 64,
                fit: BoxFit.cover,
              ),
            ),
          ),
        );
      },
    );
  }
}
