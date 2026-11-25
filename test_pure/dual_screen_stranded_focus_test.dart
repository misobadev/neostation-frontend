import 'dart:io';

import 'package:test/test.dart';

/// A dock app closed on the bottom screen while a game ran on the top one left
/// Android's focused display on the bottom screen, whose window was not
/// focusable while the game covered the main UI. The next controller press
/// waited for a window that never came, and NeoStation was reported as not
/// responding (AYN Thor, PR 855).
///
/// The Kotlin side has no test run in CI, so this reads the sources.
void main() {
  const dir = 'android/app/src/main/kotlin/com/neogamelab/neostation';
  final bottom = File('$dir/SecondaryDisplayActivity.kt').readAsStringSync();
  final main = File('$dir/MainActivity.kt').readAsStringSync();

  // From [signature] to the end of its body, at [indent] member indent.
  String body(String source, String signature, {String indent = '    '}) {
    final start = source.indexOf(signature);
    expect(start, isNot(-1), reason: '$signature not found');
    final end = source.indexOf('\n$indent}\n', start);
    expect(end, isNot(-1), reason: '$signature has no end');
    return source.substring(start, end);
  }

  test('a focused secondary UI window is never left unfocusable', () {
    final rule = body(bottom, 'internal fun focusFlagsFor(', indent: '');
    expect(
      rule,
      contains('!showsMainUi && mainUiCovered && !focusedHere'),
      reason: 'only an unfocused window may drop FLAG_NOT_FOCUSABLE',
    );
  });

  test('both windows re-apply the rule when they gain or lose top resumed', () {
    final bottomTop = body(bottom, 'override fun onTopResumedActivityChanged(');
    expect(bottomTop, contains('applyFocusRole()'));
    expect(
      body(bottom, 'fun applyFocusRole('),
      contains('focusedHere = isTopResumed'),
    );

    final mainTop = body(main, 'override fun onTopResumedActivityChanged(');
    expect(mainTop, contains('applyOwnFocusRole()'));
    expect(
      body(main, 'private fun applyOwnFocusRole('),
      contains('focusedHere = isTopResumed'),
    );
  });

  test('keys reaching it while the main UI is covered are dropped', () {
    final keys = body(main, 'internal fun dispatchKeyFromSecondaryUi(');
    final covered = keys.indexOf('if (isMainUiCovered())');
    expect(covered, isNot(-1));
    // Before anything that would drive the hidden main UI.
    expect(covered, lessThan(keys.indexOf('handleGamepadKey(event)')));
    expect(keys, contains('BottomScreenEngine.showControllerHint()'));

    final motion = body(main, 'internal fun dispatchMotionFromSecondaryUi(');
    expect(motion.indexOf('if (isMainUiCovered()) return true'), isNot(-1));
  });
}
