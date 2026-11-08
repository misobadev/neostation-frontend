import 'dart:io';

import 'package:test/test.dart';

/// The setup wizard moves the user data without a restart. Everything that
/// resolved a folder from the old location at start-up has to look again, or
/// the rest of the session reads and writes in the wrong place: the art
/// folder ([FileProvider]) left scraped art invisible until the next launch,
/// and the log went on into the old folder.
void main() {
  final wizard = File('lib/widgets/setup_wizard.dart').readAsStringSync();
  final mainDart = File('lib/main.dart').readAsStringSync();

  // The body of a class method: from its signature to the closing brace at
  // the class member indent.
  String method(String signature) {
    final start = wizard.indexOf(signature);
    expect(start, isNot(-1), reason: '$signature not found');
    final end = wizard.indexOf('\n  }\n', start);
    expect(end, isNot(-1), reason: '$signature has no end');
    return wizard.substring(start, end);
  }

  for (final signature in [
    'Future<String?> _changeUserDataLocation(',
    'Future<void> _resetUnwritableUserDataPath(',
  ]) {
    group(signature, () {
      late String body;
      setUp(() => body = method(signature));

      test('re-resolves the art folder after the database moves', () {
        final database = body.lastIndexOf(
          'SqliteConfigProvider>().reinitialize()',
        );
        final fallback = body.lastIndexOf('configProvider.reinitialize()');
        final moved = database > fallback ? database : fallback;
        final art = body.indexOf('context.read<FileProvider>().reinitialize()');
        expect(art, isNot(-1));
        expect(art, greaterThan(moved));
      });

      test('reopens the log in the new folder', () {
        final database = body.lastIndexOf(
          'SqliteConfigProvider>().reinitialize()',
        );
        final fallback = body.lastIndexOf('configProvider.reinitialize()');
        final moved = database > fallback ? database : fallback;
        final logFile = body.indexOf('LoggerService.instance.reinitialize()');
        expect(logFile, isNot(-1));
        expect(logFile, greaterThan(moved));
      });
    });
  }

  test('start-up tries the art folder again once the database is open', () {
    final database = mainDart.indexOf(
      'await sqliteConfigProvider.initialize()',
    );
    final first = mainDart.indexOf('await fileProvider.initialize()');
    final retry = mainDart.indexOf(
      'await fileProvider.initialize()',
      first + 1,
    );
    expect(first, isNot(-1));
    expect(retry, greaterThan(database));
  });
}
