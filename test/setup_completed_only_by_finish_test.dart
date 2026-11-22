import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Setup counts as done only once the wizard finishes. A ROM folder used to
/// count too, but it is picked halfway through the wizard: an app closed or
/// restarted after that step skipped the scan, the ES-DE import and the art
/// pack, and opened on an empty library.
void main() {
  final wrapper = File('lib/widgets/permission_check_wrapper.dart')
      .readAsStringSync();

  String method(String signature) {
    final start = wrapper.indexOf(signature);
    expect(start, isNot(-1), reason: '$signature not found');
    final end = wrapper.indexOf('\n  }\n', start);
    return wrapper.substring(start, end);
  }

  test('the start-up check does not take a ROM folder as a finished setup', () {
    final check = method('Future<void> _checkInitialSetup()');
    expect(check, isNot(contains('romFolder')));
    expect(check, contains('config.setupCompleted'));
  });

  test('finishing the wizard saves the flag in both places', () {
    final finish = method('Future<void> _completeSetup()');
    expect(finish, contains('configProvider.completeSetup()'));
    expect(finish, contains('prefs.setBool(setupCompletedKey, true)'));
  });
}
