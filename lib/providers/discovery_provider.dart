import 'dart:async';

import 'package:flutter/foundation.dart';

import '../models/discovery_models.dart';
import '../services/discovery/discovery_service.dart';
import '../services/logger_service.dart';

/// Presentation state for the Discovery tab.
///
/// Owns nothing the database does not already hold: the board is rebuilt from
/// `user_discovery_picks` rather than cached across weeks, so a rollover, a
/// rescan or a re-roll from anywhere else all converge on the same answer.
class DiscoveryProvider extends ChangeNotifier {
  DiscoveryProvider({this._service = const DiscoveryService()});

  final DiscoveryService _service;
  final _log = LoggerService.instance;

  DiscoveryBoard? _board;
  bool _loading = false;
  bool _failed = false;

  DiscoveryBoard? get board => _board;

  /// Whether a board is being computed. The first load runs a full library
  /// scan, so the tab shows a spinner rather than an empty storefront.
  bool get loading => _loading;

  /// Whether the last attempt threw. The tab offers a retry rather than
  /// pretending the library is empty.
  bool get failed => _failed;

  /// Whether a board has been produced at least once this session.
  bool get hasBoard => _board != null;

  /// The systems hidden in Settings, as the tab last reported them.
  Set<String> _hiddenSystems = const {};

  /// The hidden systems the board in memory was built under.
  ///
  /// The candidate query leaves hidden systems out, but the board is kept for
  /// the week, so without this a system hidden after the board was built kept
  /// its games on it until the week rolled over.
  Set<String> _boardHiddenSystems = const {};

  /// Whether the board has to be built again at the next chance: it was asked
  /// for while a load or a re-roll was running, or the library changed in a
  /// way the hidden systems don't show (see [markStale]).
  bool _stale = false;

  /// Loads the board, reusing the one already in memory when it is still for
  /// the current week, was built under the same hidden systems and hasn't been
  /// marked stale.
  ///
  /// [force] re-reads regardless, which is what a returning launch needs: play
  /// time changed while the game was running, and the hero's eligibility and
  /// the hidden gem's "never played" rule both depend on it. Asked for while a
  /// board is being built, it runs once that one is done.
  ///
  /// [hiddenSystems] is the set of system folders hidden in Settings. Passing
  /// a set that differs from the one the board was built under rebuilds it;
  /// leaving it out keeps the last set passed.
  Future<void> load({bool force = false, Set<String>? hiddenSystems}) async {
    if (hiddenSystems != null) _hiddenSystems = Set.of(hiddenSystems);
    if (force) _stale = true;
    if (_loading) return;
    final hiddenChanged = !setEquals(_boardHiddenSystems, _hiddenSystems);
    if (!_stale &&
        !hiddenChanged &&
        _board != null &&
        _board!.weekKey == _service.currentWeekKey) {
      return;
    }

    _stale = false;
    // The board in memory may hold games of a system hidden since: the tab
    // would show them, and push them to the second screen, until the new board
    // is ready. Dropping it shows the loading state instead.
    if (hiddenChanged) _board = null;
    _loading = true;
    _failed = false;
    notifyListeners();

    final buildingUnder = _hiddenSystems;
    try {
      _board = await _service.loadBoard();
      _boardHiddenSystems = buildingUnder;
    } catch (e, stackTrace) {
      _failed = true;
      _log.e('DiscoveryProvider: failed to load the board: $e');
      _log.e('   StackTrace: $stackTrace');
    } finally {
      _loading = false;
      notifyListeners();
    }

    await _catchUp();
  }

  /// Rebuilds the board because the library changed in a way the hidden
  /// systems don't show: a game was hidden, or shown again.
  ///
  /// A board already built is rebuilt straight away, since the Discovery tab
  /// can stay mounted under a route where the game was hidden (Search, for
  /// one) and would otherwise keep recommending it. When the tab isn't mounted
  /// that rebuild is not needed yet, but hiding a game is rare enough not to
  /// track which. With no board yet there is nothing to correct: the tab's
  /// first load reads the library afresh.
  void markStale() {
    _stale = true;
    if (_board != null && !_loading) unawaited(load());
  }

  /// Builds the board again when it was asked for while a load or a re-roll
  /// was running: that call returned early, and the board just built may still
  /// hold games hidden in the meantime. Not after a failure, which the tab
  /// offers to retry rather than retrying on its own.
  Future<void> _catchUp() async {
    if (_failed) return;
    if (!_stale && setEquals(_boardHiddenSystems, _hiddenSystems)) return;
    await load();
  }

  /// Games each slot has already shown and rolled away from this session.
  ///
  /// Only the pick currently on the board is off limits as far as the database
  /// is concerned, so without this a slot re-rolled several times hands back
  /// the game from two rolls ago. Session state on purpose: it is about the
  /// run of presses the user is making now, and a restart should not owe them
  /// anything.
  final Map<String, List<String>> _rolledAway = {};

  /// How many rolls back a slot remembers. Long enough to stop a short cycle,
  /// short enough that a small library still has somewhere to go.
  static const int _rolledAwayMemory = 12;

  /// Swaps the pick in [slotId] for a different game.
  ///
  /// The new pick is persisted, so it is what the tab shows for the rest of the
  /// week — including after a restart.
  Future<void> reroll(String slotId) async {
    if (_loading) return;

    _loading = true;
    notifyListeners();

    final replaced = _pathOf(slotId);
    final buildingUnder = _hiddenSystems;

    try {
      _board = await _service.reroll(
        slotId,
        alsoExclude: {..._rolledAway[slotId] ?? const []},
      );
      _boardHiddenSystems = buildingUnder;
      if (replaced != null) _remember(slotId, replaced);
      _failed = false;
    } catch (e, stackTrace) {
      _log.e('DiscoveryProvider: failed to re-roll $slotId: $e');
      _log.e('   StackTrace: $stackTrace');
    } finally {
      _loading = false;
      notifyListeners();
    }

    await _catchUp();
  }

  /// The game currently in [slotId], or null when the slot is empty.
  String? _pathOf(String slotId) {
    for (final entry in _board?.entries ?? const <DiscoveryBoardEntry>[]) {
      if (entry.pick.slotId == slotId) return entry.pick.romPath;
    }
    return null;
  }

  void _remember(String slotId, String romPath) {
    final seen = _rolledAway.putIfAbsent(slotId, () => []);
    seen.remove(romPath);
    seen.add(romPath);
    if (seen.length > _rolledAwayMemory) seen.removeAt(0);
  }
}
