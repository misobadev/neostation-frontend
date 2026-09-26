import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:neostation/l10n/app_locale.dart';
import 'package:neostation/models/retro_achievements_game_info.dart';
import 'package:neostation/models/retro_achievements_leaderboard.dart';
import 'package:neostation/providers/retro_achievements_provider.dart';
import 'package:neostation/screens/game_screen/game_details_card/tabs/game_details_leaderboards_tab.dart';
import 'package:neostation/services/gamepad/gamepad_navigation_manager.dart';
import 'package:neostation/widgets/ra_earned_badge.dart';
import 'ra_achievement_browser.dart';
import 'package:neostation/utils/gamepad_nav.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

/// A ROM-independent RetroAchievements game view. It is intentionally keyed
/// by the RA game id so rows from the dashboard can open it even when the
/// player has not installed that game locally.
class RaGameAchievementsPage extends StatefulWidget {
  final int gameId;
  final String? fallbackTitle;
  final int? highlightAchievementId;

  const RaGameAchievementsPage({
    super.key,
    required this.gameId,
    this.fallbackTitle,
    this.highlightAchievementId,
  });

  @override
  State<RaGameAchievementsPage> createState() => _RaGameAchievementsPageState();
}

class _RaGameAchievementsPageState extends State<RaGameAchievementsPage> {
  final GlobalKey<GameDetailsLeaderboardsTabState> _leaderboardsKey =
      GlobalKey<GameDetailsLeaderboardsTabState>();
  final _browserKey = GlobalKey<RaAchievementBrowserState>();
  GamepadNavigation? _gamepadNav;
  GameInfoAndUserProgress? _gameInfo;
  bool _headerFocused = false;
  int _headerActionIndex = 0;
  bool _leaderboardsView = false;
  bool _gameHeaderVisible = true;
  bool _headerRevealArmed = true;
  bool _loading = true;
  String? _error;
  bool _requestInFlight = false;

  @override
  void initState() {
    super.initState();
    _gamepadNav = GamepadNavigation(
      onNavigateUp: _moveUp,
      onNavigateDown: _moveDown,
      onNavigateLeft: _moveLeft,
      onNavigateRight: _moveRight,
      onSelectItem: _activate,
      onBack: _handleBack,
      allowRepeat: false,
    )..initialize();
    GamepadNavigationManager.pushLayer(
      'ra_game_achievements',
      onActivate: () => _gamepadNav?.activate(),
      onDeactivate: () => _gamepadNav?.deactivate(),
    );
    unawaited(_load());
  }

  @override
  void dispose() {
    GamepadNavigationManager.popLayer('ra_game_achievements');
    _gamepadNav?.dispose();

    super.dispose();
  }

  Future<void> _load({bool forceRefresh = false}) async {
    if (_requestInFlight) return;
    _requestInFlight = true;
    if (mounted) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }
    final provider = context.read<RetroAchievementsProvider>();
    final info = await provider.getGameInfoAndUserProgress(
      widget.gameId,
      forceRefresh: forceRefresh,
    );
    if (!mounted) return;
    setState(() {
      _gameInfo = info;
      _loading = false;
      _error = info == null
          ? (provider.error ??
                AppLocale.raErrorGameInfoUnavailable.getString(context))
          : null;
    });
    _requestInFlight = false;
  }

  void _moveUp() {
    if (_leaderboardsView) {
      _leaderboardsKey.currentState?.moveUp();
      return;
    }
    if (_headerFocused) return;
    if (_browserKey.currentState?.move(0, -1) != true &&
        _headerActions.isNotEmpty) {
      setState(() => _headerFocused = true);
    }
  }

  void _moveDown() {
    if (_leaderboardsView) {
      _leaderboardsKey.currentState?.moveDown();
      return;
    }
    if (_headerFocused) {
      setState(() => _headerFocused = false);
      _browserKey.currentState?.enterFilters();
      return;
    }
    _browserKey.currentState?.move(0, 1);
  }

  void _moveLeft() {
    if (_leaderboardsView) return;
    if (_headerFocused) {
      _moveHeaderAction(-1);
      return;
    }
    _browserKey.currentState?.move(-1, 0);
  }

  void _moveRight() {
    if (_leaderboardsView) return;
    if (_headerFocused) {
      _moveHeaderAction(1);
      return;
    }
    _browserKey.currentState?.move(1, 0);
  }

  List<String> get _headerActions => [
    if (_gameInfo?.guideUrl case final url? when _isHttpUrl(url)) 'guide',
  ];

  void _moveHeaderAction(int delta) {
    final actions = _headerActions;
    if (actions.isEmpty) return;
    setState(() {
      _headerActionIndex =
          (_headerActionIndex + delta + actions.length) % actions.length;
    });
  }

  void _activateHeaderAction() {
    final actions = _headerActions;
    if (actions.isEmpty) return;
    final action = actions[_headerActionIndex.clamp(0, actions.length - 1)];
    switch (action) {
      case 'guide':
        final url = _gameInfo?.guideUrl;
        if (url != null && _isHttpUrl(url)) {
          unawaited(launchUrl(Uri.parse(url)));
        }
    }
  }

  void _showLeaderboards() {
    setState(() {
      _leaderboardsView = true;
      _headerFocused = false;
      _gameHeaderVisible = false;
      _headerRevealArmed = false;
    });
    // Arm the leaderboard panel after it has been inserted by the view switch
    // so the next D-pad press moves its first row immediately.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _leaderboardsKey.currentState?.enterPanel();
    });
  }

  void _activate() {
    if (_leaderboardsView) {
      final state = _leaderboardsKey.currentState;
      if (state != null && state.isPanelActive) {
        state.activateFocused();
      } else {
        state?.enterPanel();
      }
      return;
    }
    if (_headerFocused) {
      _activateHeaderAction();
      return;
    }
    if (_error != null) {
      unawaited(_load());
      return;
    }
    _browserKey.currentState?.selectCurrent();
  }

  void _handleBack() {
    if (_leaderboardsView) {
      final state = _leaderboardsKey.currentState;
      if (state?.exitPanel() == true) return;
      setState(() => _leaderboardsView = false);
      return;
    }
    if (_headerFocused) {
      setState(() => _headerFocused = false);
      return;
    }
    if (_browserKey.currentState?.back() == true) return;
    Navigator.of(context).maybePop();
  }

  String _imageUrl(String path) {
    if (path.isEmpty) return '';
    if (path.startsWith('http://') || path.startsWith('https://')) return path;
    return 'https://media.retroachievements.org$path';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final info = _gameInfo;
    return Scaffold(
      backgroundColor: theme.colorScheme.surface,
      appBar: AppBar(
        title: Text(
          info?.title ??
              widget.fallbackTitle ??
              AppLocale.achievements.getString(context),
        ),
        leading: IconButton(
          tooltip: AppLocale.back.getString(context),
          onPressed: _handleBack,
          icon: const Icon(Symbols.arrow_back_rounded),
        ),
        actions: [
          if (info?.guideUrl case final url? when _isHttpUrl(url))
            IconButton(
              tooltip: AppLocale.raGuide.getString(context),
              onPressed: () => launchUrl(Uri.parse(url)),
              color: _headerActionFocused('guide')
                  ? theme.colorScheme.primary
                  : null,
              icon: const Icon(Symbols.menu_book_rounded),
            ),
        ],
      ),
      body: Column(
        children: [
          AnimatedSize(
            duration: const Duration(milliseconds: 180),
            curve: Curves.easeOut,
            alignment: Alignment.topCenter,
            child: _gameHeaderVisible
                ? _buildGameHeader(context, info)
                : const SizedBox.shrink(),
          ),
          Expanded(
            child: NotificationListener<ScrollNotification>(
              onNotification: _handleContentScroll,
              child: _leaderboardsView
                  ? _buildLeaderboards(context)
                  : _buildAchievements(context, info),
            ),
          ),
        ],
      ),
    );
  }

  bool _isHttpUrl(String value) {
    final scheme = Uri.tryParse(value)?.scheme.toLowerCase();
    return scheme == 'http' || scheme == 'https';
  }

  Widget _buildGameHeader(BuildContext context, GameInfoAndUserProgress? info) {
    final theme = Theme.of(context);
    final total = info?.numAchievements ?? 0;
    final earned = info?.numAwardedToUser ?? 0;
    final next = info == null ? null : _nextAchievement(info);
    final title =
        info?.title ??
        widget.fallbackTitle ??
        AppLocale.achievements.getString(context);
    final progressLabel = AppLocale.raAchievementProgress
        .getString(context)
        .replaceFirst('{earned}', '$earned')
        .replaceFirst('{total}', '$total');
    return Container(
      padding: EdgeInsets.fromLTRB(16.r, 14.r, 16.r, 14.r),
      decoration: BoxDecoration(
        color: theme.cardColor.withValues(alpha: 0.3),
        border: Border(
          bottom: BorderSide(
            color: theme.colorScheme.outline.withValues(alpha: 0.2),
          ),
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _boxArt(context, info?.imageBoxArt ?? ''),
          SizedBox(width: 16.r),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleLarge,
                ),
                if ((info?.consoleName ?? '').isNotEmpty)
                  Text(info!.consoleName, style: theme.textTheme.bodySmall),
                if (info == null && _loading)
                  Padding(
                    padding: EdgeInsets.only(top: 10.r),
                    child: const LinearProgressIndicator(),
                  )
                else if (info != null) ...[
                  SizedBox(height: 8.r),
                  Text(progressLabel, style: theme.textTheme.bodySmall),
                  SizedBox(height: 5.r),
                  _combinedProgressMeter(context, info),
                  if (info.highestAwardKind case final award?
                      when award.trim().isNotEmpty)
                    Padding(
                      padding: EdgeInsets.only(top: 6.r),
                      child: Row(
                        children: [
                          Icon(Symbols.emoji_events_rounded, size: 15.r),
                          SizedBox(width: 4.r),
                          Text(
                            _awardLabel(context, award),
                            style: theme.textTheme.labelMedium,
                          ),
                        ],
                      ),
                    ),
                  if (next != null)
                    Padding(
                      padding: EdgeInsets.only(top: 5.r),
                      child: Text(
                        '${AppLocale.next.getString(context)}: ${next.title} · ${next.points} ${AppLocale.points.getString(context)}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.labelMedium,
                      ),
                    ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _combinedProgressMeter(
    BuildContext context,
    GameInfoAndUserProgress info,
  ) {
    final theme = Theme.of(context);
    final total = info.numAchievements;
    final casual = info.numAwardedToUser.clamp(0, total).toInt();
    final hardcore = info.numAwardedToUserHardcore.clamp(0, casual).toInt();
    final casualOnly = casual - hardcore;
    final remaining = (total - casual).clamp(0, total).toInt();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Text(
              '${AppLocale.raCasual.getString(context)} $casual/$total',
              style: theme.textTheme.labelSmall,
            ),
            const Spacer(),
            Text(
              '${AppLocale.raHardcore.getString(context)} $hardcore/$total',
              style: theme.textTheme.labelSmall,
            ),
          ],
        ),
        SizedBox(height: 4.r),
        ClipRRect(
          borderRadius: BorderRadius.circular(4.r),
          child: SizedBox(
            height: 7.r,
            child: Row(
              children: [
                if (hardcore > 0)
                  Expanded(
                    flex: hardcore,
                    child: Container(color: RaEarnedBadge.gold),
                  ),
                if (casualOnly > 0)
                  Expanded(
                    flex: casualOnly,
                    child: Container(color: RaEarnedBadge.silver),
                  ),
                if (remaining > 0)
                  Expanded(
                    flex: remaining,
                    child: Container(
                      color: theme.colorScheme.onSurface.withValues(alpha: .1),
                    ),
                  ),
                if (total == 0)
                  Expanded(
                    child: Container(
                      color: theme.colorScheme.onSurface.withValues(alpha: .1),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Achievement? _nextAchievement(GameInfoAndUserProgress info) {
    final achievements = info.achievements.values.toList()
      ..sort((a, b) => a.displayOrder.compareTo(b.displayOrder));
    for (final achievement in achievements) {
      if (!achievement.isUnlocked) return achievement;
    }
    return null;
  }

  String _awardLabel(BuildContext context, String award) {
    final normalized = award.trim().toLowerCase();
    if (normalized.contains('master')) {
      return AppLocale.raMasteryLabel.getString(context);
    }
    if (normalized.contains('beat') || normalized.contains('complet')) {
      return AppLocale.raCompletionLabel.getString(context);
    }
    return award;
  }

  Widget _boxArt(BuildContext context, String path) {
    final url = _imageUrl(path);
    return ClipRRect(
      borderRadius: BorderRadius.circular(8.r),
      child: SizedBox(
        width: 82.r,
        height: 104.r,
        child: url.isEmpty
            ? Icon(Symbols.videogame_asset_rounded, size: 28.r)
            : Image.network(
                url,
                fit: BoxFit.cover,
                errorBuilder: (_, error, stack) =>
                    Icon(Symbols.videogame_asset_rounded, size: 28.r),
              ),
      ),
    );
  }

  bool _headerActionFocused(String action) {
    final actions = _headerActions;
    return actions.isNotEmpty &&
        _headerFocused &&
        actions[_headerActionIndex.clamp(0, actions.length - 1)] == action;
  }

  bool _handleContentScroll(ScrollNotification notification) {
    if (_leaderboardsView || notification.metrics.axis != Axis.vertical) {
      return false;
    }
    final visible = notification.metrics.extentBefore <= 0;
    if (notification is UserScrollNotification) {
      _headerRevealArmed = true;
    }
    // Programmatic list re-reveals after a filter change must not unlock a
    // header that the user has already collapsed. UserScrollNotification
    // above is the explicit gesture that arms it again.
    if (visible && !_headerRevealArmed) {
      // A filter change can re-scan the list at offset zero. Keep the header
      // collapsed in that case; it should return only after the user scrolls
      // away and back to the top.
      return false;
    }
    if (_gameHeaderVisible != visible) {
      setState(() => _gameHeaderVisible = visible);
    }
    return false;
  }

  Widget _buildAchievements(
    BuildContext context,
    GameInfoAndUserProgress? info,
  ) {
    if (_loading && info == null) return _buildLoadingAchievements(context);
    if (info == null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              _error ?? AppLocale.raErrorGameInfoUnavailable.getString(context),
            ),
            TextButton(
              onPressed: _load,
              child: Text(AppLocale.retry.getString(context)),
            ),
          ],
        ),
      );
    }
    return RaAchievementBrowser(
      key: _browserKey,
      info: info,
      highlightId: widget.highlightAchievementId,
      onLeaderboards: _showLeaderboards,
      onFilterChanged: () {
        if (!_gameHeaderVisible) _headerRevealArmed = false;
      },
    );
  }

  Widget _buildLoadingAchievements(BuildContext context) {
    final theme = Theme.of(context);
    return ListView.separated(
      padding: EdgeInsets.symmetric(horizontal: 12.r, vertical: 12.r),
      itemCount: 5,
      separatorBuilder: (_, _) => SizedBox(height: 8.r),
      itemBuilder: (context, index) => Container(
        height: 64.r,
        padding: EdgeInsets.all(10.r),
        decoration: BoxDecoration(
          color: theme.cardColor.withValues(alpha: 0.18),
          borderRadius: BorderRadius.circular(10.r),
        ),
        child: Row(
          children: [
            Container(
              width: 42.r,
              height: 42.r,
              decoration: BoxDecoration(
                color: theme.colorScheme.onSurface.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(6.r),
              ),
            ),
            SizedBox(width: 10.r),
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  FractionallySizedBox(
                    widthFactor: index.isEven ? 0.72 : 0.52,
                    child: Container(
                      height: 10.r,
                      color: theme.colorScheme.onSurface.withValues(alpha: 0.1),
                    ),
                  ),
                  SizedBox(height: 7.r),
                  FractionallySizedBox(
                    widthFactor: index.isEven ? 0.44 : 0.62,
                    child: Container(
                      height: 8.r,
                      color: theme.colorScheme.onSurface.withValues(
                        alpha: 0.07,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildLeaderboards(BuildContext context) {
    final provider = context.read<RetroAchievementsProvider>();
    return Stack(
      fit: StackFit.expand,
      children: [
        GameDetailsLeaderboardsTab(
          key: _leaderboardsKey,
          gameId: widget.gameId,
          isConnected: provider.isConnected,
          loadGameLeaderboards: (id) async =>
              (await provider.getGameLeaderboards(id)) ??
              const RaGameLeaderboardsPage.empty(),
          loadLeaderboardEntries:
              (id, {required count, required offset}) async =>
                  (await provider.getLeaderboardEntries(
                    id,
                    count: count,
                    offset: offset,
                  )) ??
                  const RaLeaderboardEntriesPage.empty(),
          loadUserGameLeaderboards: (id) async =>
              (await provider.getUserGameLeaderboards(id)) ??
              const RaUserGameLeaderboardsPage.empty(),
          topOffset: 0,
          bottomOffset: 0,
        ),
      ],
    );
  }
}
