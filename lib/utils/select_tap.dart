/// Decides what a Select (View) press means: a chord modifier, a plain tap, or
/// nothing at all.
///
/// Select does double duty — held, it unlocks the Select+face-button chords
/// (scrape / legend / random); tapped, it fires its own action (mute the
/// preview video). Telling those apart is fiddly enough to live on its own,
/// away from the event plumbing in `GamepadNavigation`:
///
/// * Android delivers a held button as a stream of auto-repeat presses, and
///   some controllers *pulse* down+up while the button is still physically
///   held. So neither "a press means a new hold" nor "a release means the
///   button is up" can be taken at face value — a press or release landing
///   inside [chordWindow] of the last one continues the current hold.
/// * A hold that unlocked a chord must not also fire the tap action when it
///   ends, or every scrape would toggle the sound too.
/// * Because of the pulsing, where chords exist a tap can only be dispatched
///   once [chordWindow] has passed with no chord — see [releaseSchedulesTap]
///   and [tapStillValid]. A layer with no chords fires it on release.
///
/// This type is pure: it holds no timers and reads no clock. The caller passes
/// the current time in and owns the deferred dispatch, which is what makes the
/// rules above testable.
class SelectTap {
  /// How long after a Select press a face button still counts as a chord, and
  /// equally how long a pending tap waits to see whether one arrives.
  static const Duration chordWindow = Duration(milliseconds: 400);

  /// A Select press shorter than this, having fired no chord, is a tap.
  static const Duration tapMax = Duration(milliseconds: 500);

  bool _held = false;

  /// When Select was last pressed *or* released. Both edges refresh it so the
  /// chord window survives a pulse-release.
  DateTime? _lastEdge;

  /// When the current hold began — not restarted by key-repeat or a pulse.
  DateTime? _pressStart;

  bool _chordUsed = false;

  /// Whether Select is currently down, as far as this state machine can tell.
  bool get held => _held;

  /// Whether a chord fired during the current hold.
  bool get chordUsed => _chordUsed;

  /// Records a Select press. Presses that merely continue the current hold
  /// (key-repeat, pulse re-assert) keep the original press time and chord flag.
  void press(DateTime now) {
    if (!_isContinuation(now)) {
      _pressStart = now;
      _chordUsed = false;
    }
    _held = true;
    _lastEdge = now;
  }

  /// Records a Select release and reports whether it should schedule a deferred
  /// tap dispatch. The caller waits [chordWindow] and then re-checks
  /// [tapStillValid] before actually firing, because the release may turn out
  /// to have been a pulse in the middle of a chord.
  bool releaseSchedulesTap(DateTime now) {
    final start = _pressStart;
    final wasTap =
        !_chordUsed && start != null && now.difference(start) <= tapMax;
    _held = false;
    _pressStart = null;
    _lastEdge = now;
    return wasTap;
  }

  /// Whether a face button pressed now should fire its Select chord: Select is
  /// still down, or was seen within [chordWindow] (the pulse case).
  bool isChordActive(DateTime now) {
    if (_held) return true;
    final last = _lastEdge;
    return last != null && now.difference(last) < chordWindow;
  }

  /// Marks that a chord fired during this hold, which cancels any pending tap.
  void chordFired() {
    _chordUsed = true;
  }

  /// Whether a tap scheduled earlier should still be dispatched. False once a
  /// chord has fired, or if Select has gone back down (the release was a pulse).
  bool get tapStillValid => !_chordUsed && !_held;

  /// Clears all state so a hold can't leak across navigation-layer changes
  /// (e.g. opening a dialog while Select is down).
  void reset() {
    _held = false;
    _lastEdge = null;
    _pressStart = null;
    _chordUsed = false;
  }

  /// A press landing while held, or inside [chordWindow] of the last edge, is
  /// the same physical hold rather than a fresh press.
  bool _isContinuation(DateTime now) {
    if (_held) return true;
    final last = _lastEdge;
    return last != null && now.difference(last) < chordWindow;
  }
}
