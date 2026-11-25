import 'dart:io';

import 'package:test/test.dart';

/// The volume buttons did nothing while NeoStation was in front on handhelds
/// whose controller reports them (an Anbernic RG477M; the AYN Thor's
/// controller key layout maps them too). The vendored gamepad plugin consumed every key from a
/// device it tracks as a gamepad, volume included, and the app never handed
/// it on to Android. While a launch blocked input, even a separate volume
/// rocker was swallowed.
///
/// The Kotlin side has no test run in CI, so this reads the sources.
void main() {
  const plugin =
      'packages/gamepads_android/android/src/main/kotlin/org/flame_engine/'
      'gamepads_android';
  final listener = File('$plugin/EventListener.kt').readAsStringSync();
  final pluginClass = File('$plugin/GamepadsAndroidPlugin.kt')
      .readAsStringSync();
  final activity = File(
    'android/app/src/main/kotlin/com/neogamelab/neostation/MainActivity.kt',
  ).readAsStringSync();
  final bottomActivity = File(
    'android/app/src/main/kotlin/com/neogamelab/neostation/'
    'SecondaryDisplayActivity.kt',
  ).readAsStringSync();

  // From [signature] to the end of its body, at 4-space member indent.
  String body(String source, String signature) {
    final start = source.indexOf(signature);
    expect(start, isNot(-1), reason: '$signature not found');
    final end = source.indexOf('\n    }\n', start);
    expect(end, isNot(-1), reason: '$signature has no end');
    return source.substring(start, end);
  }

  test('the volume keys are the keys left to the system', () {
    final keys = RegExp(r'systemKeys\s*=\s*setOf\(([^)]*)\)')
        .firstMatch(listener);
    expect(keys, isNotNull, reason: 'no systemKeys set in EventListener');
    final names = RegExp(r'KeyEvent\.(KEYCODE_\w+)')
        .allMatches(keys![1]!)
        .map((m) => m[1])
        .toSet();
    expect(names, {
      'KEYCODE_VOLUME_UP',
      'KEYCODE_VOLUME_DOWN',
      'KEYCODE_VOLUME_MUTE',
    });
  });

  test('the plugin neither consumes nor forwards them', () {
    final onKey = body(listener, 'fun onKeyEvent(');
    final passOn = onKey.indexOf(
      'if (isSystemKey(keyEvent.keyCode)) return false',
    );
    expect(passOn, isNot(-1));
    expect(passOn, lessThan(onKey.indexOf('channel.invokeMethod')));
  });

  test('the plugin hands the listener\'s answer to the activity', () {
    expect(
      pluginClass,
      matches(
        RegExp(
          r'registerKeyEventHandler \{ event ->\s*'
          r'if \(devices\.containsKey\(event\.deviceId\)\) \{\s*'
          r'events\.onKeyEvent\(event, channel\)',
        ),
      ),
    );
  });

  test('the activity gives them to Android, even while input is blocked', () {
    // Key handling lives in handleGamepadKey, shared by both screens: it
    // returns false for a key Android should get.
    final handle = body(
      activity,
      'internal fun handleGamepadKey(keyEvent: KeyEvent): Boolean',
    );
    final volume = handle.indexOf(
      'if (EventListener.isSystemKey(keyEvent.keyCode)) return false',
    );
    expect(volume, isNot(-1));
    final blocked = handle.indexOf('if (gamepadBlocked) return true');
    expect(blocked, isNot(-1));
    expect(volume, lessThan(blocked));

    // And a key it didn't take (volume included) still reaches Android.
    final dispatch = body(
      activity,
      'override fun dispatchKeyEvent(keyEvent: KeyEvent): Boolean',
    );
    expect(
      dispatch,
      matches(
        RegExp(
          r'if \(handleGamepadKey\(keyEvent\)\) return true\s*'
          r'return super\.dispatchKeyEvent\(keyEvent\)',
        ),
      ),
    );
  });

  test('the bottom screen hands them to Android too', () {
    final dispatch = body(
      bottomActivity,
      'override fun dispatchKeyEvent(event: KeyEvent): Boolean',
    );
    // Swapped, it shows the main UI: the same handling as the top screen.
    expect(
      dispatch,
      matches(
        RegExp(
          r'if \(m\.handleGamepadKey\(event\)\) return true\s*'
          r'return super\.dispatchKeyEvent\(event\)',
        ),
      ),
    );
    // Showing the secondary UI, it forwards keys to the main UI, but a
    // volume key the main UI leaves still goes to Android from here.
    final forwarded = dispatch.indexOf(
      'if (m.dispatchKeyFromSecondaryUi(event)) return true',
    );
    expect(forwarded, isNot(-1));
    final volume = dispatch.indexOf(
      'EventListener.isSystemKey(event.keyCode)',
      forwarded,
    );
    expect(volume, isNot(-1));
    expect(
      dispatch.indexOf('super.dispatchKeyEvent(event)', volume),
      isNot(-1),
    );

    final fromSecondary = body(
      activity,
      'internal fun dispatchKeyFromSecondaryUi(event: KeyEvent): Boolean',
    );
    final handled = fromSecondary.indexOf(
      'if (handleGamepadKey(event)) return true',
    );
    const volumeOut =
        'if (EventListener.isSystemKey(event.keyCode)) return false';
    final passOn = fromSecondary.indexOf(volumeOut, handled);
    final toMainUi = fromSecondary.indexOf('superDispatchKeyEvent(event)');
    expect(handled, isNot(-1));
    expect(passOn, greaterThan(handled));
    expect(toMainUi, greaterThan(passOn));
    // While a game covers the main UI the other keys are dropped, but the
    // volume still goes to Android first.
    final covered = fromSecondary.indexOf('if (isMainUiCovered())');
    expect(covered, isNot(-1));
    final coveredVolume = fromSecondary.indexOf(volumeOut, covered);
    expect(coveredVolume, greaterThan(covered));
    expect(
      coveredVolume,
      lessThan(fromSecondary.indexOf('return true', covered)),
    );
  });

  test('swapped, the top screen hands them to Android too', () {
    final dispatch = body(
      activity,
      'override fun dispatchKeyEvent(keyEvent: KeyEvent): Boolean',
    );
    expect(
      dispatch,
      matches(
        RegExp(
          r'if \(dispatchKeyFromSecondaryUi\(keyEvent\)\) return true\s*'
          r'return EventListener\.isSystemKey\(keyEvent\.keyCode\) && '
          r'super\.dispatchKeyEvent\(keyEvent\)',
        ),
      ),
    );
  });
}
