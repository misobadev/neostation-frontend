import 'dart:io';

import 'package:test/test.dart';

/// The version of [package] that `pubspec.lock` resolves, without any
/// pre-release or build suffix.
List<int> lockedVersion(String package) {
  final lock = File('pubspec.lock').readAsStringSync().replaceAll('\r\n', '\n');
  final match = RegExp(
    '\\n  ${RegExp.escape(package)}:\\n(?:    .*\\n)*?    version: "([^"]+)"',
  ).firstMatch(lock);
  expect(match, isNotNull, reason: '$package is missing from pubspec.lock.');
  return match!
      .group(1)!
      .split(RegExp('[-+]'))
      .first
      .split('.')
      .map(int.parse)
      .toList();
}

/// Compares two versions part by part: negative when [a] is lower.
int compareVersions(List<int> a, List<int> b) {
  for (var i = 0; i < a.length || i < b.length; i++) {
    final x = i < a.length ? a[i] : 0;
    final y = i < b.length ? b[i] : 0;
    if (x != y) return x - y;
  }
  return 0;
}

void main() {
  test('compareVersions orders versions part by part', () {
    expect(compareVersions([2, 4, 27], [2, 4, 27]), 0);
    expect(compareVersions([2, 4, 28], [2, 4, 27]), greaterThan(0));
    expect(compareVersions([2, 4, 99], [2, 5, 0]), lessThan(0));
    expect(compareVersions([2, 5], [2, 5, 0]), 0);
  });

  test('shared_preferences_android stays on the 2.4 line', () {
    // 2.5.0-2.5.4 keep one registration for the whole process. On dual-screen
    // devices the bottom screen runs a second engine; with "Disable on
    // secondary screen" on (hide_bottom_screen), it is destroyed right after
    // launch and takes the main engine's registration with it, so every
    // SharedPreferences call there fails with "No instance with no name has
    // been registered": 0.16.1 could not start (GitHub #829). 2.5.5 registers
    // per engine, but only with Flutter 3.50's engine IDs; on 3.47, turning the
    // setting on while the app runs still breaks the running app.
    // 2.4.x uses a channel per engine.
    // Lift this with the Flutter 3.50 upgrade (NEO-242): move to 2.5.5 or
    // later, and drop the shared_preferences_android ignore in
    // .github/dependabot.yml.
    final version = lockedVersion('shared_preferences_android');
    expect(
      compareVersions(version, [2, 4, 27]) >= 0 &&
          compareVersions(version, [2, 5, 0]) < 0,
      isTrue,
      reason:
          'shared_preferences_android ${version.join('.')} is outside '
          '>=2.4.27 <2.5.0; 2.5.x before Flutter 3.50 breaks preferences on '
          'dual-screen devices (NEO-249).',
    );
  });
}
