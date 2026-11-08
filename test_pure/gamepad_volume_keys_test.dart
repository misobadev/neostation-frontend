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
    final dispatch = body(
      activity,
      'override fun dispatchKeyEvent(keyEvent: KeyEvent): Boolean',
    );
    final volume =
        RegExp(
          r'if \(EventListener\.isSystemKey\(keyEvent\.keyCode\)\)\s*\{?\s*'
          r'return super\.dispatchKeyEvent\(keyEvent\)',
        ).firstMatch(dispatch)?.start ??
        -1;
    expect(volume, isNot(-1));
    expect(
      volume,
      lessThan(dispatch.indexOf('if (gamepadBlocked) return true')),
    );
    // And a key the plugin didn't take still reaches Android.
    expect(
      dispatch,
      contains(
        'return if (handled) true else super.dispatchKeyEvent(keyEvent)',
      ),
    );
  });
}
