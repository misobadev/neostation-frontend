/// Tracks a real leave/return pair, including focus changes during handoff.
class ShortcutFocusTracker {
  bool _left = false;
  bool returned = false;

  void blur() {
    _left = true;
    returned = false;
  }

  void focus() {
    if (_left) returned = true;
  }

  void reset() {
    _left = false;
    returned = false;
  }
}
