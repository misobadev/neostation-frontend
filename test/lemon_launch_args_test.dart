import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/services/launcher_service.dart';

/// Lemon (https://github.com/Ghael-V/Lemon-Project, issue #684) is an
/// Android-only Switch emulator forked from Eden. It ships three builds that
/// install side by side, each under its own package name, but every build
/// keeps the same Kotlin namespace, so its EmulationActivity lives at
/// `dev.lemon.lemon_emu.activities.EmulationActivity` whatever the package.
///
/// The activity must therefore be written out in full: the `.Activity`
/// shorthand would expand to `<package>.activities.EmulationActivity`, a
/// class that does not exist in any Lemon build. Like Eden, Lemon starts a
/// game from the intent's data URI under the `TECH_DISCOVERED` action.
void main() {
  const activity = 'dev.lemon.lemon_emu.activities.EmulationActivity';
  const builds = {
    'switch.dev.lemon.lemon_emulator': 'dev.lemon.lemon_emulator',
    'switch.dev.lemon.lemon_emulator.lite': 'dev.lemon.lemon_emulator.lite',
    'switch.com.antutu.ABenchMark': 'com.antutu.ABenchMark',
  };

  late List<Map<String, dynamic>> emulators;

  setUpAll(() {
    final json = jsonDecode(
      File('assets/systems/switch.json').readAsStringSync(),
    ) as Map<String, dynamic>;
    emulators = (json['emulators'] as List).cast<Map<String, dynamic>>();
  });

  builds.forEach((uniqueId, package) {
    test('$uniqueId opens the game in $package', () {
      final emulator = emulators.singleWhere((e) => e['unique_id'] == uniqueId);
      final platforms = emulator['platforms'] as Map<String, dynamic>;
      final android = platforms['android'] as Map<String, dynamic>;
      final args = LauncherService.splitArgs(
        android['launch_arguments'] as String,
      );

      expect(
        args,
        containsAllInOrder([
          '-n',
          '$package/$activity',
          '-a',
          'android.nfc.action.TECH_DISCOVERED',
          '-d',
          '{file.uri}',
        ]),
      );
      expect(platforms.keys, ['android'], reason: 'Lemon is Android-only');
    });
  });
}
