part of '../ra_content.dart';

/// The panel's sections and the RetroAchievements game page their rows open.
/// A row is an information request: the page is ROM-independent and never
/// starts a download. The local library and RomM stay reachable through the
/// week card.
extension _DrillDownHost on _RAContentState {
  /// The panel's content for every section but the overview. Each section is
  /// built the first time it is shown and kept after, so going back to one is
  /// instant; only the one on show is active and fetches.
  Widget _buildSectionContent() {
    if (_section != RaDashboardSection.overview) {
      _visitedSections.add(_section);
    }
    final panelFocused = !_menuFocused;
    bool shows(RaDashboardSection section) => _section == section;
    Widget slot(RaDashboardSection section, Widget Function() build) =>
        _visitedSections.contains(section) ? build() : const SizedBox.shrink();
    return IndexedStack(
      index: shows(RaDashboardSection.overview) ? 0 : _section.index - 1,
      sizing: StackFit.expand,
      children: [
        slot(
          RaDashboardSection.aotw,
          () => RaCollectionTab(
            key: _eventsKey,
            events: true,
            active: shows(RaDashboardSection.aotw),
            focused: panelFocused && shows(RaDashboardSection.aotw),
            onOpenGame: (id, title) =>
                _openRaGameAchievements(gameId: id, gameTitle: title),
          ),
        ),
        slot(
          RaDashboardSection.unlocks,
          () => RaUnlocksTab(
            key: _unlocksKey,
            embedded: true,
            active: shows(RaDashboardSection.unlocks),
            focused: panelFocused && shows(RaDashboardSection.unlocks),
            onActivate: _activateUnlock,
          ),
        ),
        slot(
          RaDashboardSection.games,
          () => RaGamesTab(
            key: _gamesKey,
            embedded: true,
            active: shows(RaDashboardSection.games),
            focused: panelFocused && shows(RaDashboardSection.games),
            onActivate: _activateGame,
          ),
        ),
        slot(
          RaDashboardSection.awards,
          () => RaCollectionTab(
            key: _awardsKey,
            events: false,
            active: shows(RaDashboardSection.awards),
            focused: panelFocused && shows(RaDashboardSection.awards),
            onOpenGame: (id, title) =>
                _openRaGameAchievements(gameId: id, gameTitle: title),
          ),
        ),
      ],
    );
  }

  Future<void> _activateUnlock(RetroAchievementRecentUnlockItem item) {
    return _openRaGameAchievements(
      gameId: item.gameId,
      gameTitle: item.gameTitle,
      achievementId: item.achievementId,
    );
  }

  Future<void> _activateGame(RaGamesListItem item) {
    return _openRaGameAchievements(gameId: item.gameId, gameTitle: item.title);
  }

  Future<void> _openRaGameAchievements({
    required int gameId,
    required String gameTitle,
    int? achievementId,
  }) async {
    if (_gameActivationInFlight || gameId <= 0) return;
    _gameActivationInFlight = true;
    try {
      await Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => RaGameAchievementsPage(
            gameId: gameId,
            fallbackTitle: gameTitle,
            highlightAchievementId: achievementId,
          ),
        ),
      );
    } finally {
      _gameActivationInFlight = false;
    }
  }
}
