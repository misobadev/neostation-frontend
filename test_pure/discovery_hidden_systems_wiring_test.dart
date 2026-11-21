import 'dart:io';

import 'package:test/test.dart';

// The board is kept for the week, and the provider only rebuilds it when it is
// told the hidden systems changed. The tab is built afresh on every visit, so
// its first load is where a system hidden in Settings since the board was
// built has to reach the provider.

String method(String source, String signature) {
  final start = source.indexOf(signature);
  expect(start, isNot(-1), reason: '$signature not found');
  final end = source.indexOf('\n  }\n', start);
  expect(end, isNot(-1), reason: '$signature has no end');
  return source.substring(start, end);
}

void main() {
  test("the tab's first load passes the systems hidden in Settings", () {
    final initState = method(
      File('lib/screens/discovery_screen/discovery_content.dart')
          .readAsStringSync(),
      'void initState(',
    );
    final load = initState.indexOf('context.read<DiscoveryProvider>().load(');
    expect(load, isNot(-1));
    // Compared without whitespace, so the formatter's line breaks don't count.
    expect(
      initState.substring(load).replaceAll(RegExp(r'\s'), ''),
      contains(
        'hiddenSystems:context.read<SqliteConfigProvider>().hiddenSystemFolders',
      ),
    );
  });

  test('the second screen is not sent a pick from a dropped board', () {
    // Hiding a system drops the board; a push queued while the old one was
    // still laid out must not reach the bottom screen afterwards.
    final sync = method(
      File('lib/screens/discovery_screen/discovery_content.dart')
          .readAsStringSync(),
      'void _syncSecondaryDisplay(',
    ).replaceAll(RegExp(r'\s'), '');
    final guard = sync.indexOf(
      'if(context.read<DiscoveryProvider>().board==null)return;',
    );
    expect(guard, isNot(-1));
    expect(guard, lessThan(sync.indexOf('_selectedEntry')));
  });

  test('a board that is not laid out leaves no tiles behind', () {
    final source = File('lib/screens/discovery_screen/discovery_content.dart')
        .readAsStringSync()
        .replaceAll(RegExp(r'\s'), '');
    final reset = source.indexOf(
      'if(board==null||board.libraryIsEmpty)_tiles=const[];',
    );
    expect(reset, isNot(-1));
    // Before the first branch that returns without laying the board out.
    expect(
      reset,
      lessThan(source.indexOf('if(provider.loading&&board==null)')),
    );
  });
}
