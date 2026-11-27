import 'dart:io';

import 'package:test/test.dart';

// Discovery keeps its board for the week. Hiding a game, or showing hidden
// games again, has to tell it, or the board keeps recommending a game the user
// has just hidden until the next restart.

String method(String source, String signature) {
  final start = source.indexOf(signature);
  expect(start, isNot(-1), reason: '$signature not found');
  final end = source.indexOf('\n  }\n', start);
  expect(end, isNot(-1), reason: '$signature has no end');
  return source.substring(start, end);
}

void main() {
  test('hiding a game marks the Discovery board stale', () {
    final body = method(
      File(
        'lib/screens/game_screen/game_settings_dialog/game_settings_manage_tab.dart',
      ).readAsStringSync(),
      'Future<void> _hideGame(',
    );
    final hidden = body.indexOf('GameRepository.setGameHidden(');
    final marked = body.indexOf('discoveryProvider?.markStale()');
    expect(hidden, isNot(-1));
    expect(marked, greaterThan(hidden));
    expect(body, contains('context.read<DiscoveryProvider?>()'));
  });

  test('showing hidden games again marks the Discovery board stale, straight '
      'after the write', () {
    final source = File('lib/widgets/system_emulator_settings_dialog.dart')
        .readAsStringSync();
    for (final (signature, write) in [
      ('Future<void> _unhideGame(', 'GameRepository.setGameHidden('),
      ('Future<void> _unhideAllGames(', 'GameRepository.unhideAll'),
    ]) {
      final body = method(source, signature);
      final read = body.indexOf('context.read<DiscoveryProvider?>()');
      final written = body.indexOf(write);
      final marked = body.indexOf('discoveryProvider?.markStale()');
      expect(read, isNot(-1), reason: signature);
      expect(written, greaterThan(read), reason: signature);
      expect(marked, greaterThan(written), reason: signature);
      // Before anything that can return early once the dialog is closed.
      final firstGuard = body.indexOf('if (!mounted) return;');
      if (firstGuard != -1) {
        expect(marked, lessThan(firstGuard), reason: signature);
      }
    }
  });
}
