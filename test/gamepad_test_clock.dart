import 'package:neostation/utils/gamepad_nav.dart';

DateTime _now = DateTime.now();

/// The time [GamepadNavigation] sees in the current test.
DateTime get gamepadNow => _now;

/// Installs a controllable clock in [GamepadNavigation].
void resetGamepadClock() {
  _now = DateTime.now();
  GamepadNavigation.debugSetClock(() => _now);
}

/// Moves the navigator's clock forward without burning real time.
void advanceGamepadClock(Duration duration) {
  _now = _now.add(duration);
}

/// Restores the production clock.
void restoreGamepadClock() {
  GamepadNavigation.debugResetClock();
}
