import 'dart:io';

import 'package:test/test.dart';

/// Wiring for NEO-244: a user-data folder missing at startup is noticed on
/// every platform before anything can create it, and NeoStation's Android
/// document provider (which runs whenever a Files app or folder picker opens,
/// with or without the app) no longer creates it again behind the user's back.
void main() {
  final main = File('lib/main.dart').readAsStringSync();

  String body(String source, String signature, String end) {
    final start = source.indexOf(signature);
    expect(start, isNot(-1), reason: '$signature not found');
    final stop = source.indexOf(end, start);
    expect(stop, isNot(-1), reason: '$signature has no end');
    return source.substring(start, stop);
  }

  test(
    'the startup check runs on every platform, before the log file opens',
    () {
      final run = body(main, 'void main() async {', '\n}\n');
      final gate = run.indexOf('await _awaitUserDataStorage();');
      final notes = run.indexOf('for (final note in storageNotes)');
      final log = run.indexOf('await log.init();');
      expect(gate, isNot(-1));
      expect(log, isNot(-1));
      expect(gate, lessThan(log), reason: 'app.log would create the folder');
      expect(
        notes,
        greaterThan(log),
        reason: 'what the check found must reach app.log',
      );
      final before = run.substring(0, gate);
      expect(
        RegExp(r'if \(Platform\.isAndroid\) \{\s*$').hasMatch(before),
        isFalse,
        reason: 'the check is Android-only',
      );
    },
  );

  test(
    'starting with an empty folder is offered only for a missing folder',
    () {
      final gate = body(main, '_awaitUserDataStorage() async {', '\n}\n');
      expect(gate, contains('ConfigService.createMissingUserDataFolder()'));
      expect(gate, contains('UserDataProblem.folderMissing'));
      expect(gate, contains('createFailed = true'));
    },
  );

  test('the document provider creates only the default folder', () {
    final provider = File(
      'android/app/src/main/kotlin/com/neogamelab/neostation/'
      'NeoDocumentsProvider.kt',
    ).readAsStringSync();
    final baseDir = body(provider, 'private fun baseDir(): File?', '\n    }\n');
    final custom = baseDir.indexOf('if (!customPath.isNullOrEmpty())');
    final defaultBranch = baseDir.indexOf('} else {', custom);
    expect(custom, isNot(-1));
    expect(defaultBranch, isNot(-1));
    final customBranch = baseDir.substring(custom, defaultBranch);
    expect(customBranch, isNot(contains('mkdirs')));
    expect(customBranch, contains('return null'));
    expect(
      RegExp(r'mkdirs').allMatches(baseDir).length,
      1,
      reason: 'only the default folder is created',
    );
  });
  test('the startup screen reads gamepads through the gamepads plugin', () {
    final screen = body(main, 'class _StartupStorageErrorAppState', '\n}\n');
    expect(screen, contains('GamepadNavigation('));
    expect(screen, contains('onSelectItem:'));
    expect(screen, contains('onBack:'));
    expect(screen, contains('onWestButton:'));
    expect(screen, contains('_gamepad.initialize();'));
    expect(screen, contains('_gamepad.activate();'));
    expect(screen, contains('_gamepad.dispose()'));
  });
}
