import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/services/launcher_service.dart';

/// DroidDeck's front end (behind its `.MainActivity` alias, since DroidDeck
/// 0.6.0) is a standard-launch-mode activity. The first launch's intent
/// becomes the root intent of DroidDeck's task, and Android answers an
/// identical intent into that task by only bringing the task to the front:
/// relaunching the same game while DroidDeck was running opened DroidDeck on
/// its home screen and started nothing.
///
/// `--activity-clear-top` makes Android finish that front-end activity, and
/// anything DroidDeck stacked above it in the same task, and start a fresh one
/// carrying the new intent. On an AYN Thor with DroidDeck 0.6.9, a relaunch
/// with a game running brought the same Steam session back (the game kept
/// running). `--activity-clear-task` is not used: it would also clear a task
/// that only shares the front end's affinity, such as one holding DroidDeck's
/// Steam session without the front end.
void main() {
  for (final system in ['steam', 'windows']) {
    group('$system: Standalone DroidDeck', () {
      late List<String> args;
      late Map<String, dynamic> android;

      setUpAll(() {
        final json =
            jsonDecode(File('assets/systems/$system.json').readAsStringSync())
                as Map<String, dynamic>;
        final emulator = (json['emulators'] as List)
            .cast<Map<String, dynamic>>()
            .singleWhere(
              (e) => e['unique_id'] == '$system.com.droiddeck.launcher',
            );
        android =
            (emulator['platforms'] as Map<String, dynamic>)['android']
                as Map<String, dynamic>;
        args = LauncherService.splitArgs(android['launch_arguments'] as String);
      });

      test('a relaunch of the same game replaces the running front end', () {
        expect(args, contains('--activity-clear-top'));
      });

      test('never clears a whole task', () {
        expect(args, isNot(contains('--activity-clear-task')));
      });

      test('still opens the launch file through the front end', () {
        expect(
          args,
          containsAllInOrder([
            '-a',
            'android.intent.action.VIEW',
            '-n',
            'com.droiddeck.launcher/.MainActivity',
            '-d',
            '{file.uri}',
          ]),
        );
        expect(android['keep_saf_uri'], isTrue);
      });
    });
  }
}
