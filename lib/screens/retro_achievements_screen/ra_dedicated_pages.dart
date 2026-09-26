import 'package:flutter/material.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:neostation/l10n/app_locale.dart';
import 'package:neostation/models/retro_achievements_dashboard_models.dart';
import 'package:neostation/services/gamepad/gamepad_navigation_manager.dart';
import 'package:neostation/utils/gamepad_nav.dart';
import 'ra_collection_tab.dart';
import 'ra_games_tab.dart';
import 'ra_unlocks_tab.dart';

/// Full-screen destinations opened from the RA dashboard. Each destination
/// owns one navigation layer so the dashboard cannot react to input while a
/// collection is in front of it.
class RaCollectionPage extends StatefulWidget {
  final bool events;
  final void Function(int gameId, String title) onOpenGame;

  const RaCollectionPage({
    super.key,
    required this.events,
    required this.onOpenGame,
  });

  @override
  State<RaCollectionPage> createState() => _RaCollectionPageState();
}

class _RaCollectionPageState extends State<RaCollectionPage> {
  final _contentKey = GlobalKey<RaCollectionTabState>();
  late final GamepadNavigation _navigation;

  String get _layerId => widget.events ? 'ra_events_page' : 'ra_awards_page';

  @override
  void initState() {
    super.initState();
    _navigation = GamepadNavigation(
      onNavigateUp: () => _contentKey.currentState?.move(0, -1),
      onNavigateDown: () => _contentKey.currentState?.move(0, 1),
      onNavigateLeft: () => _contentKey.currentState?.move(-1, 0),
      onNavigateRight: () => _contentKey.currentState?.move(1, 0),
      onSelectItem: () => _contentKey.currentState?.selectCurrent(),
      onBack: _pop,
      allowRepeat: false,
    )..initialize();
    GamepadNavigationManager.pushLayer(
      _layerId,
      onActivate: _navigation.activate,
      onDeactivate: _navigation.deactivate,
    );
  }

  @override
  void dispose() {
    GamepadNavigationManager.popLayer(_layerId);
    _navigation.dispose();
    super.dispose();
  }

  void _pop() {
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final title = widget.events
        ? AppLocale.raAotwYearTitle
              .getString(context)
              .replaceFirst('{year}', '${DateTime.now().year}')
        : AppLocale.raAwards.getString(context);
    return _RaPageScaffold(
      title: title,
      icon: widget.events
          ? Symbols.event_rounded
          : Symbols.emoji_events_rounded,
      onBack: _pop,
      child: RaCollectionTab(
        key: _contentKey,
        events: widget.events,
        active: true,
        focused: true,
        onOpenGame: widget.onOpenGame,
      ),
    );
  }
}

class RaGamesPage extends StatefulWidget {
  final void Function(RaGamesListItem item) onActivate;

  const RaGamesPage({super.key, required this.onActivate});

  @override
  State<RaGamesPage> createState() => _RaGamesPageState();
}

class _RaGamesPageState extends State<RaGamesPage> {
  final _contentKey = GlobalKey<RaGamesTabState>();
  late final GamepadNavigation _navigation;

  @override
  void initState() {
    super.initState();
    _navigation = GamepadNavigation(
      onNavigateUp: () => _contentKey.currentState?.handleNavigateUp(),
      onNavigateDown: () => _contentKey.currentState?.handleNavigateDown(),
      onNavigateLeft: () => _contentKey.currentState?.handleNavigateLeft(),
      onNavigateRight: () => _contentKey.currentState?.handleNavigateRight(),
      onSelectItem: () => _contentKey.currentState?.selectCurrent(),
      onBack: _pop,
      allowRepeat: false,
    )..initialize();
    GamepadNavigationManager.pushLayer(
      'ra_games_page',
      onActivate: _navigation.activate,
      onDeactivate: _navigation.deactivate,
    );
  }

  @override
  void dispose() {
    GamepadNavigationManager.popLayer('ra_games_page');
    _navigation.dispose();
    super.dispose();
  }

  void _pop() {
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) => _RaPageScaffold(
    title: AppLocale.raSubtabGames.getString(context),
    icon: Symbols.sports_esports_rounded,
    onBack: _pop,
    child: RaGamesTab(
      key: _contentKey,
      active: true,
      onActivate: widget.onActivate,
    ),
  );
}

class RaUnlocksPage extends StatefulWidget {
  final void Function(RetroAchievementRecentUnlockItem item) onActivate;

  const RaUnlocksPage({super.key, required this.onActivate});

  @override
  State<RaUnlocksPage> createState() => _RaUnlocksPageState();
}

class _RaUnlocksPageState extends State<RaUnlocksPage> {
  final _contentKey = GlobalKey<RaUnlocksTabState>();
  late final GamepadNavigation _navigation;

  @override
  void initState() {
    super.initState();
    _navigation = GamepadNavigation(
      onNavigateUp: () => _contentKey.currentState?.moveSelection(-1),
      onNavigateDown: () => _contentKey.currentState?.moveSelection(1),
      onNavigateLeft: () {},
      onNavigateRight: () {},
      onSelectItem: () => _contentKey.currentState?.activateCurrent(),
      onBack: _pop,
      allowRepeat: false,
    )..initialize();
    GamepadNavigationManager.pushLayer(
      'ra_unlocks_page',
      onActivate: _navigation.activate,
      onDeactivate: _navigation.deactivate,
    );
  }

  @override
  void dispose() {
    GamepadNavigationManager.popLayer('ra_unlocks_page');
    _navigation.dispose();
    super.dispose();
  }

  void _pop() {
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) => _RaPageScaffold(
    title: AppLocale.raSubtabUnlocks.getString(context),
    icon: Symbols.lock_open_rounded,
    onBack: _pop,
    child: RaUnlocksTab(
      key: _contentKey,
      active: true,
      onActivate: widget.onActivate,
    ),
  );
}

class _RaPageScaffold extends StatelessWidget {
  final String title;
  final IconData icon;
  final VoidCallback onBack;
  final Widget child;

  const _RaPageScaffold({
    required this.title,
    required this.icon,
    required this.onBack,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          onPressed: onBack,
          icon: const Icon(Symbols.arrow_back_rounded),
          tooltip: AppLocale.back.getString(context),
        ),
        title: Row(
          children: [
            Icon(icon, size: 20.r, color: theme.colorScheme.primary),
            SizedBox(width: 8.r),
            Text(title),
          ],
        ),
      ),
      body: Padding(
        padding: EdgeInsets.fromLTRB(12.r, 8.r, 12.r, 12.r),
        child: child,
      ),
    );
  }
}
