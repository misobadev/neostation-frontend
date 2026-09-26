part of '../ra_content.dart';

/// The see-all rows open a ROM-independent RetroAchievements game page. The
/// local library and RomM remain available through the weekly-game card; a
/// normal RA row is an information request and should never trigger a
/// download as a side effect.
extension _DrillDownHost on _RAContentState {
  Future<void> _openUnlocks({int focusAction = 2}) {
    _setDashboardAction(focusAction);
    return _openRaPage(
      RaUnlocksPage(onActivate: (item) => _activateUnlock(item)),
    );
  }

  Future<void> _openGames({int focusAction = 3}) {
    _setDashboardAction(focusAction);
    return _openRaPage(RaGamesPage(onActivate: (item) => _activateGame(item)));
  }

  Future<void> _openEvents() {
    _setDashboardAction(1);
    return _openRaPage(
      RaCollectionPage(
        events: true,
        onOpenGame: (id, title) {
          _openRaGameAchievements(gameId: id, gameTitle: title);
        },
      ),
    );
  }

  Future<void> _openAwards() {
    _setDashboardAction(4);
    return _openRaPage(
      RaCollectionPage(
        events: false,
        onOpenGame: (id, title) {
          _openRaGameAchievements(gameId: id, gameTitle: title);
        },
      ),
    );
  }

  Future<void> _openRaPage(Widget page) async {
    if (_raPageInFlight || !mounted) return;
    _raPageInFlight = true;
    try {
      await Navigator.of(context).push(MaterialPageRoute(builder: (_) => page));
    } finally {
      _raPageInFlight = false;
    }
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
