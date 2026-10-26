import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  // The service tests cannot catch lifecycle ordering in SystemGamesList.
  // Guard the synchronous provider read before the loader's first await.
  test('collections provider is assigned before the initial games load', () {
    final source = File(
      'lib/screens/game_screen/my_games_list.dart',
    ).readAsStringSync();
    final start = source.indexOf('void initState()');
    final end = source.indexOf('\n  ///', start);
    final init = source.substring(start, end);
    final assignment = init.indexOf(
      '_collectionsProvider = context.read<CollectionsProvider>();',
    );
    expect(assignment, greaterThanOrEqualTo(0));
    expect(
      assignment,
      lessThan(init.indexOf('_loadGames();')),
      reason:
          'Both manual and smart collection loads read smartPaths '
          'synchronously, before the first await.',
    );
  });
}
