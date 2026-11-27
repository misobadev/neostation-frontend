import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/services/launcher_service.dart';

/// Peanuts Native (https://github.com/igawa6/peanuts-native, issue #867) is
/// an Android-only native port of Switch games, not an emulator. Frontends
/// start it through the exported `<application id>.Launch` alias, which has
/// no intent filters, so it accepts an intent with no action. The `game`
/// extra with the file's real path is the form its docs (`FRONTENDS.md`)
/// call the most reliable, because the app opens games by path.
///
/// It only launches its own `.nup` files, so the Switch system has to list
/// that extension for the scanner to find them.
void main() {
  const package = 'dev.nxnative.android.peanuts';

  late Map<String, dynamic> json;
  late Map<String, dynamic> emulator;

  setUpAll(() {
    json = jsonDecode(
      File('assets/systems/switch.json').readAsStringSync(),
    ) as Map<String, dynamic>;
    emulator = (json['emulators'] as List)
        .cast<Map<String, dynamic>>()
        .singleWhere((e) => e['unique_id'] == 'switch.$package');
  });

  test('starts the game through the Launch alias with its path', () {
    final platforms = emulator['platforms'] as Map<String, dynamic>;
    final android = platforms['android'] as Map<String, dynamic>;
    final args = LauncherService.splitArgs(
      android['launch_arguments'] as String,
    );

    expect(
      args,
      containsAllInOrder(['-n', '$package/$package.Launch', '-e', 'game']),
    );
    expect(args.last, '{file.path}');
    expect(args, isNot(contains('-a')), reason: 'the alias needs no action');
    expect(platforms.keys, ['android'], reason: 'Android-only');
  });

  test('the Switch system scans .nup files', () {
    final system = json['system'] as Map<String, dynamic>;
    expect(system['extensions'] as List, contains('nup'));
  });
}
