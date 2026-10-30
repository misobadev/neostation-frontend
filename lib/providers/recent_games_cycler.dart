import 'dart:async';

import 'package:flutter/foundation.dart';

/// Which of the last few played games the systems screen's recent card shows.
///
/// The card is one slot in front of the systems, but it cycles through up to
/// [maxGames] recent games: on its own every [interval] while it is not
/// focused, and by LT/RT while it is. It holds still while focused so that A
/// launches the game the user is looking at, not one the timer swapped in
/// under the press.
///
/// Shared between the carousel, the grid and the [MySystems] host that builds
/// the footer and options for the same card, so all three agree on the game.
class RecentGamesCycler extends ChangeNotifier {
  /// How many recently played games the card cycles through.
  static const int maxGames = 5;

  /// How long the card shows each game before moving on by itself.
  static const Duration interval = Duration(seconds: 5);

  int _position = 0;
  int _count = 0;
  int _direction = 1;
  String? _newestKey;
  bool _focused = true;
  Timer? _timer;

  /// Raw position, for hosts that rebuild when the card moves. Use [pick] for
  /// the index of the game to show.
  int get position => _position;

  /// How many recent games the card is cycling through, as of the last [pick].
  int get count => _count;

  /// Index of the game the card shows, as of the last [pick].
  int get index => _count == 0 ? 0 : _position % _count;

  /// Which way the card last moved: 1 forward (RT or the timer), -1 back (LT).
  /// Drives the direction the card slides.
  int get direction => _direction;

  /// The index into [keys] (most recent first) the card should show.
  ///
  /// [keys] identify the recent games (their ROM paths). Called while building
  /// the systems list, so it never notifies: it only records how many games
  /// there are to cycle through, and snaps back to the newest when a game is
  /// played, so the card leads with what the user just came back from.
  int pick(List<String> keys) {
    final newest = keys.isEmpty ? null : keys.first;
    if (newest != _newestKey) {
      _newestKey = newest;
      _position = 0;
    }
    final countChanged = keys.length != _count;
    _count = keys.length;
    if (countChanged) _syncTimer();
    if (_count == 0) return 0;
    return _position % _count;
  }

  /// Moves the card [delta] games along (negative goes back), wrapping.
  ///
  /// Restarts the auto-cycle interval, so a game picked by hand gets its full
  /// time on screen once focus moves away.
  void step(int delta) {
    if (_count < 2) return;
    _direction = delta < 0 ? -1 : 1;
    _position = (_position + delta) % _count;
    _syncTimer(restart: true);
    notifyListeners();
  }

  /// Tells the cycler whether the recent card is the focused one.
  ///
  /// Called from the host's build, so it never notifies; it only starts or
  /// stops the timer.
  void setFocused(bool focused) {
    if (focused == _focused) return;
    _focused = focused;
    _syncTimer(restart: true);
  }

  void _syncTimer({bool restart = false}) {
    final shouldRun = !_focused && _count > 1;
    if (!shouldRun) {
      _timer?.cancel();
      _timer = null;
      return;
    }
    if (_timer != null && !restart) return;
    _timer?.cancel();
    _timer = Timer.periodic(interval, (_) {
      _direction = 1;
      _position = (_position + 1) % _count;
      notifyListeners();
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    _timer = null;
    super.dispose();
  }
}
