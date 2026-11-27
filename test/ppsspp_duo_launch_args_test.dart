import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/services/launcher_service.dart';

/// PPSSPP Duo (https://github.com/mkaflowski/PPSSPP-Duo) is a PPSSPP fork for
/// dual-screen Android handhelds such as the AYN Thor. It installs next to
/// regular PPSSPP under its own package, `org.ppsspp.ppssppduo`, but keeps
/// upstream's `org.ppsspp.ppsspp` namespace, so its activity is
/// `org.ppsspp.ppsspp.PpssppActivity`, as in PPSSPP Gold and Legacy.
///
/// The activity must therefore be written out in full: the `.PpssppActivity`
/// shorthand would expand to `org.ppsspp.ppssppduo.PpssppActivity`, a class
/// that does not exist in the app.
void main() {
  late Map<String, dynamic> duo;

  setUpAll(() {
    final json = jsonDecode(
      File('assets/systems/psp.json').readAsStringSync(),
    ) as Map<String, dynamic>;
    final emulators = (json['emulators'] as List).cast<Map<String, dynamic>>();
    duo = emulators.singleWhere(
      (e) => e['unique_id'] == 'psp.org.ppsspp.ppssppduo',
    );
  });

  test('PPSSPP Duo opens the game in org.ppsspp.ppssppduo', () {
    final platforms = duo['platforms'] as Map<String, dynamic>;
    final android = platforms['android'] as Map<String, dynamic>;
    final args = LauncherService.splitArgs(
      android['launch_arguments'] as String,
    );

    expect(
      args,
      containsAllInOrder([
        '-n',
        'org.ppsspp.ppssppduo/org.ppsspp.ppsspp.PpssppActivity',
        '-a',
        'android.intent.action.VIEW',
        '-d',
        '{file.uri}',
      ]),
    );
    expect(platforms.keys, ['android'], reason: 'PPSSPP Duo is Android-only');
  });
}
