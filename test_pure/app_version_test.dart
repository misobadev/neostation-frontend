import 'dart:io';

import 'package:neostation/app_version.dart';
import 'package:neostation/utils/version_compare.dart';
import 'package:test/test.dart';

/// The update check reads [appVersion], not the platform's version string
/// (macOS keeps only numbers, so a release candidate would read as the
/// release). It has to say what pubspec.yaml says.
void main() {
  test('appVersion matches the version in pubspec.yaml', () {
    final line = File('pubspec.yaml')
        .readAsLinesSync()
        .firstWhere((line) => line.startsWith('version:'));
    final pubspecVersion = line.substring('version:'.length).trim();

    expect(
      appVersion,
      pubspecVersion.split('+').first,
      reason: 'Update lib/app_version.dart together with pubspec.yaml',
    );
    expect(parseSemVersion(appVersion), isNotNull);
  });
}
