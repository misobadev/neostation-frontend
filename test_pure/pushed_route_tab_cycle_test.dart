import 'dart:io';

import 'package:test/test.dart';

/// Screens that live on a route PUSHED OVER `AppScreen` must not walk the app's
/// top-level tab strip.
///
/// The strip and its header are behind the pushed route, so cycling it changes
/// nothing the user can see: the main display keeps showing the pushed screen
/// while the secondary display and the nav sounds report a tab switch. Worse,
/// tabs that host their own gamepad layer (Search, NeoSync, RomM) stack that
/// layer above the pushed screen's, so every later press — B included — is
/// handled by a screen that is not on the display, and the device needs a
/// restart. The games carousel shipped with `AppNavigation.previousTab` /
/// `nextTab` on its bumpers and did exactly that.
///
/// `AppScreenState._cycleTab` also refuses to cycle while `Navigator.canPop()`,
/// so this is the second of two locks. Keep both: the guard covers screens
/// nobody has written yet, this test keeps the wiring honest at the source.
void main() {
  /// Everything under these paths is reached by `Navigator.push`, never as tab
  /// content.
  const pushedRouteSources = <String>[
    'lib/screens/game_screen',
    'lib/screens/settings_screen/standalone_emulators_screen.dart',
  ];

  final tabCycleCall = RegExp(r'AppNavigation\.(previousTab|nextTab)\b');

  test('screens on a pushed route never cycle the app tab strip', () {
    final offenders = <String>[];

    for (final path in pushedRouteSources) {
      final entity = FileSystemEntity.isDirectorySync(path)
          ? Directory(path)
          : null;
      final files = entity == null
          ? [File(path)]
          : entity
                .listSync(recursive: true)
                .whereType<File>()
                .where((f) => f.path.endsWith('.dart'))
                .toList();

      expect(files, isNotEmpty, reason: '$path matched no Dart source');

      for (final file in files) {
        final lines = file.readAsLinesSync();
        for (var i = 0; i < lines.length; i++) {
          // Skip comments: the carousel documents this rule in prose.
          final code = lines[i].trimLeft();
          if (code.startsWith('//') || code.startsWith('///')) continue;
          if (tabCycleCall.hasMatch(code)) {
            offenders.add('${file.path}:${i + 1}: ${code.trim()}');
          }
        }
      }
    }

    expect(
      offenders,
      isEmpty,
      reason:
          'These screens sit on a pushed route, so switching the app tab under '
          'them freezes the main display (see this file\'s doc comment). Bind '
          'the bumpers to something local, or leave them unbound:\n'
          '${offenders.join('\n')}',
    );
  });
}
