import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/services/launcher_service.dart';

/// GBA Duo (https://github.com/khumam/gba-duo) is a GB/GBC/GBA player for
/// dual-screen Android handhelds such as the AYN Thor. Frontends open games
/// through its `com.khumam.gbaduo.library.LaunchActivity` trampoline, which
/// reads the ROM from the intent's data.
///
/// It must get the original SAF `content://` URI (`keep_saf_uri`): the app
/// has no storage permission, finds the ROM's file name by decoding the URI,
/// and only forwards the read grant that came with the intent's data.
void main() {
  const systems = ['gb', 'gbc', 'gba', 'gb-hacks', 'gbc-hacks', 'gba-hacks'];

  for (final system in systems) {
    test('GBA Duo opens $system games through LaunchActivity', () {
      final json = jsonDecode(
        File('assets/systems/$system.json').readAsStringSync(),
      ) as Map<String, dynamic>;
      final emulators = (json['emulators'] as List)
          .cast<Map<String, dynamic>>();
      final duo = emulators.singleWhere(
        (e) => e['unique_id'] == '$system.com.khumam.gbaduo',
      );

      final platforms = duo['platforms'] as Map<String, dynamic>;
      final android = platforms['android'] as Map<String, dynamic>;
      final args = LauncherService.splitArgs(
        android['launch_arguments'] as String,
      );

      expect(
        args,
        containsAllInOrder([
          '-n',
          'com.khumam.gbaduo/.library.LaunchActivity',
          '-a',
          'android.intent.action.VIEW',
          '-d',
          '{file.localuri}',
        ]),
      );
      expect(android['keep_saf_uri'], isTrue);
      expect(platforms.keys, ['android'], reason: 'GBA Duo is Android-only');
    });
  }
}
