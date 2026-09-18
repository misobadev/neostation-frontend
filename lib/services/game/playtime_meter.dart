/// Counts the time a game is actually being played.
///
/// Playtime used to be the wall-clock gap between launch and exit, so a
/// handheld put to sleep mid-game logged the whole night as play. This meter
/// measures on a monotonic clock instead, which stops while the device is
/// suspended, and is paused outright while the screen is off, which covers a
/// device that stays awake with the display dark.
class PlaytimeMeter {
  PlaytimeMeter({Duration Function()? clock}) : _clock = clock ?? _monotonic;

  static final Stopwatch _monotonicWatch = Stopwatch()..start();
  static Duration _monotonic() => _monotonicWatch.elapsed;

  final Duration Function() _clock;

  /// Time banked by segments that have already ended.
  Duration _banked = Duration.zero;

  /// Clock reading when the current segment began; null while not counting.
  Duration? _segmentStart;

  /// Whole seconds already handed out by [takeUnreported].
  int _reportedSeconds = 0;

  bool get isRunning => _segmentStart != null;

  /// Total time counted since [start].
  Duration get elapsed {
    final segmentStart = _segmentStart;
    if (segmentStart == null) return _banked;
    return _banked + (_clock() - segmentStart);
  }

  /// Resets the meter for a new session. Starts counting unless [paused].
  void start({bool paused = false}) {
    _banked = Duration.zero;
    _reportedSeconds = 0;
    _segmentStart = paused ? null : _clock();
  }

  /// Stops counting and keeps what has been counted so far.
  void pause() {
    final segmentStart = _segmentStart;
    if (segmentStart == null) return;
    _banked += _clock() - segmentStart;
    _segmentStart = null;
  }

  /// Carries on counting from where [pause] left off.
  void resume() {
    _segmentStart ??= _clock();
  }

  /// Whole seconds counted since the previous call, for incremental saves.
  int takeUnreported() {
    final total = elapsed.inSeconds;
    final unreported = total - _reportedSeconds;
    _reportedSeconds = total;
    return unreported;
  }
}
