import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/utils/gamepad_nav.dart';
import 'package:neostation/utils/select_tap.dart';

/// A Select tap waits out the chord window only where a chord could follow.
/// Elsewhere — the Systems screen opening the notification bell — it fires on
/// release, so Select does not feel slow.
void main() {
  late DateTime clock;

  setUp(() {
    clock = DateTime(2026);
    GamepadNavigation.debugSetClock(() => clock);
  });

  tearDown(() {
    GamepadNavigation.debugResetClock();
    GamepadNavigation.globalSelectTap = null;
  });

  void advance(FakeAsync async, Duration by) {
    clock = clock.add(by);
    async.elapse(by);
  }

  test('with no chords the tap fires on release', () {
    fakeAsync((async) {
      var taps = 0;
      final nav = GamepadNavigation(onSelectButton: () => taps++);
      nav.debugSelectEdge(down: true);
      advance(async, const Duration(milliseconds: 80));
      nav.debugSelectEdge(down: false);
      expect(taps, 1);
      advance(async, SelectTap.chordWindow);
      expect(taps, 1);
    });
  });

  test('with no chords and no own action the app-wide tap fires', () {
    fakeAsync((async) {
      var taps = 0;
      GamepadNavigation.globalSelectTap = () => taps++;
      final nav = GamepadNavigation();
      nav.debugSelectEdge(down: true);
      advance(async, const Duration(milliseconds: 80));
      nav.debugSelectEdge(down: false);
      expect(taps, 1);
    });
  });

  test('a pulsing held Select still fires once', () {
    fakeAsync((async) {
      var taps = 0;
      final nav = GamepadNavigation(onSelectButton: () => taps++);
      nav.debugSelectEdge(down: true);
      for (var i = 0; i < 5; i++) {
        advance(async, const Duration(milliseconds: 60));
        nav.debugSelectEdge(down: false);
        advance(async, const Duration(milliseconds: 60));
        nav.debugSelectEdge(down: true);
      }
      advance(async, const Duration(milliseconds: 60));
      nav.debugSelectEdge(down: false);
      advance(async, SelectTap.chordWindow);
      expect(taps, 1);
    });
  });

  test('with chords the tap still waits out the chord window', () {
    fakeAsync((async) {
      var taps = 0;
      final nav = GamepadNavigation(
        onSelectButton: () => taps++,
        onSelectModifierA: () {},
      );
      nav.debugSelectEdge(down: true);
      advance(async, const Duration(milliseconds: 80));
      nav.debugSelectEdge(down: false);
      expect(taps, 0);
      advance(async, SelectTap.chordWindow);
      expect(taps, 1);
    });
  });
}
