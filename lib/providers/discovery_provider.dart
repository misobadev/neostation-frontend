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
  DiscoveryProvider({DiscoveryService service = const DiscoveryService()})
    : _service = service;

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

  /// Loads the board, reusing the one already in memory when it is still for
  /// the current week.
  ///
  /// [force] re-reads regardless, which is what a returning launch needs: play
  /// time changed while the game was running, and the hero's eligibility and
  /// the hidden gem's "never played" rule both depend on it.
  Future<void> load({bool force = false}) async {
    if (_loading) return;
    if (!force &&
        _board != null &&
        _board!.weekKey == _service.currentWeekKey) {
      return;
    }

    _loading = true;
    _failed = false;
    notifyListeners();

    try {
      _board = await _service.loadBoard();
    } catch (e, stackTrace) {
      _failed = true;
      _log.e('DiscoveryProvider: failed to load the board: $e');
      _log.e('   StackTrace: $stackTrace');
    } finally {
      _loading = false;
      notifyListeners();
    }
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

    try {
      _board = await _service.reroll(
        slotId,
        alsoExclude: {..._rolledAway[slotId] ?? const []},
      );
      if (replaced != null) _remember(slotId, replaced);
      _failed = false;
    } catch (e, stackTrace) {
      _log.e('DiscoveryProvider: failed to re-roll $slotId: $e');
      _log.e('   StackTrace: $stackTrace');
    } finally {
      _loading = false;
      notifyListeners();
    }
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
