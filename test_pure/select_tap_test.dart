import 'package:test/test.dart';
import 'package:neostation/utils/select_tap.dart';

/// Fixed origin for the fake clock. [SelectTap] only ever compares times, so
/// the absolute value is arbitrary.
final DateTime t0 = DateTime(2026, 1, 1);

/// `t(120)` = 120ms after the origin.
DateTime t(int ms) => t0.add(Duration(milliseconds: ms));

void main() {
  late SelectTap tap;

  setUp(() => tap = SelectTap());

  group('a plain tap', () {
    test('schedules a tap and stays valid when nothing else happens', () {
      tap.press(t(0));
      expect(tap.releaseSchedulesTap(t(80)), isTrue);
      expect(tap.tapStillValid, isTrue);
    });

    test('a press just under the tap ceiling still counts', () {
      tap.press(t(0));
      expect(
        tap.releaseSchedulesTap(t(SelectTap.tapMax.inMilliseconds)),
        isTrue,
      );
    });

    test('a hold longer than the tap ceiling does not', () {
      tap.press(t(0));
      expect(
        tap.releaseSchedulesTap(t(SelectTap.tapMax.inMilliseconds + 1)),
        isFalse,
      );
    });

    test('a release with no press at all schedules nothing', () {
      // Can happen after reset() drops a hold mid-press.
      expect(tap.releaseSchedulesTap(t(10)), isFalse);
    });
  });

  group('a chord', () {
    test('suppresses the tap on release', () {
      tap.press(t(0));
      expect(tap.isChordActive(t(50)), isTrue);
      tap.chordFired();
      expect(tap.releaseSchedulesTap(t(80)), isFalse);
    });

    test('landing after the release still invalidates the pending tap', () {
      // The dispatch is deferred precisely so this can't fire the tap action:
      // the chord arrives while the tap is still waiting out the chord window.
      tap.press(t(0));
      expect(tap.releaseSchedulesTap(t(60)), isTrue);
      expect(tap.isChordActive(t(90)), isTrue, reason: 'pulse-release window');
      tap.chordFired();
      expect(tap.tapStillValid, isFalse);
    });

    test('is not active once the chord window has elapsed', () {
      tap.press(t(0));
      tap.releaseSchedulesTap(t(10));
      expect(
        tap.isChordActive(t(SelectTap.chordWindow.inMilliseconds + 10)),
        isFalse,
      );
    });

    test('stays active for as long as Select is genuinely held', () {
      tap.press(t(0));
      expect(tap.isChordActive(t(5000)), isTrue);
    });
  });

  group('key-repeat and pulse continuations', () {
    test(
      'repeat presses do not restart the hold, so a long hold is not a tap',
      () {
        // Android streams auto-repeat presses while the button is held. If each
        // one reset the press time, releasing after 2s would look like a tap.
        for (var ms = 0; ms <= 2000; ms += 100) {
          tap.press(t(ms));
        }
        expect(tap.releaseSchedulesTap(t(2050)), isFalse);
      },
    );

    test('a pulse down-up-down keeps the original press time', () {
      // Controller pulses while the button is physically held the whole time.
      // The final release is within tapMax of the *second* press but not of the
      // first, so this only passes if the hold is still measured from t0.
      tap.press(t(0));
      tap.releaseSchedulesTap(t(20));
      tap.press(t(300));
      expect(
        tap.releaseSchedulesTap(t(SelectTap.tapMax.inMilliseconds + 60)),
        isFalse,
        reason: 'the hold began at t0, not at the second press',
      );
    });

    test('a chord is not forgotten across a pulse within the same hold', () {
      // Regression guard: resetting chordUsed on every pulse-press would let a
      // held Select fire the tap action between chords.
      tap.press(t(0));
      tap.chordFired();
      tap.releaseSchedulesTap(t(20));
      tap.press(t(40));
      expect(tap.chordUsed, isTrue);
      expect(tap.releaseSchedulesTap(t(60)), isFalse);
    });

    test('a genuinely separate press after the window is a fresh tap', () {
      tap.press(t(0));
      tap.chordFired();
      tap.releaseSchedulesTap(t(20));

      final second = SelectTap.chordWindow.inMilliseconds + 100;
      tap.press(t(second));
      expect(tap.chordUsed, isFalse, reason: 'new hold, chord flag cleared');
      expect(tap.releaseSchedulesTap(t(second + 50)), isTrue);
    });

    test('a pending tap is invalid while Select is back down', () {
      tap.press(t(0));
      expect(tap.releaseSchedulesTap(t(30)), isTrue);
      tap.press(t(50));
      expect(tap.tapStillValid, isFalse);
    });
  });

  group('held state', () {
    test('tracks the press and release edges', () {
      expect(tap.held, isFalse);
      tap.press(t(0));
      expect(tap.held, isTrue);
      tap.releaseSchedulesTap(t(30));
      expect(tap.held, isFalse);
    });
  });

  group('reset', () {
    test('drops the hold, the chord flag and the chord window', () {
      tap.press(t(0));
      tap.chordFired();
      tap.reset();

      expect(tap.held, isFalse);
      expect(tap.chordUsed, isFalse);
      expect(tap.isChordActive(t(10)), isFalse);
      expect(tap.tapStillValid, isTrue);
    });

    test('a press after reset starts a fresh hold', () {
      tap.press(t(0));
      tap.reset();
      tap.press(t(10));
      expect(tap.releaseSchedulesTap(t(60)), isTrue);
    });
  });
}
