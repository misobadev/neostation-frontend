import 'package:flutter_test/flutter_test.dart';

import 'package:neostation/screens/search_screen/search_filter.dart';

void main() {
  group('searchResultActionsFor', () {
    test('a local row offers Go to game and Play only', () {
      expect(searchResultActionsFor(isRemote: false, hasLocal: true), [
        SearchResultAction.goTo,
        SearchResultAction.play,
      ]);
    });

    // The case manual linking exists for: a locally renamed ROM is never
    // recognised as downloaded, so the remote row for it resolves to no local
    // game and offers Download alone. The way in is the local row.
    test('a local row offers Link while RomM is connected', () {
      final actions = searchResultActionsFor(
        isRemote: false,
        hasLocal: true,
        canLink: true,
      );

      expect(actions, [
        SearchResultAction.goTo,
        SearchResultAction.play,
        SearchResultAction.link,
      ]);
      expect(
        actions.take(2),
        searchResultActionsFor(isRemote: false, hasLocal: true),
        reason: 'the existing D-pad order for Go to / Play is unchanged',
      );
    });

    test('a remote row without a local match still offers Download only', () {
      expect(
        searchResultActionsFor(isRemote: true, hasLocal: false, canLink: true),
        [SearchResultAction.download],
        reason: 'there is no local game to link from a remote row',
      );
    });

    test(
      'a remote row with a local match appends Link after Go to and Play',
      () {
        final actions = searchResultActionsFor(isRemote: true, hasLocal: true);

        expect(actions, [
          SearchResultAction.goTo,
          SearchResultAction.play,
          SearchResultAction.link,
        ]);
        expect(
          actions.take(2),
          searchResultActionsFor(isRemote: false, hasLocal: true),
          reason: 'the existing D-pad order for Go to / Play is unchanged',
        );
      },
    );

    test('a remote row without a local match offers Download only', () {
      expect(searchResultActionsFor(isRemote: true, hasLocal: false), [
        SearchResultAction.download,
      ]);
    });

    test('Link never appears without a local game to link', () {
      for (final isRemote in [true, false]) {
        for (final canLink in [true, false]) {
          expect(
            searchResultActionsFor(
              isRemote: isRemote,
              hasLocal: false,
              canLink: canLink,
            ),
            isNot(contains(SearchResultAction.link)),
          );
        }
      }
      expect(
        searchResultActionsFor(isRemote: false, hasLocal: true),
        isNot(contains(SearchResultAction.link)),
        reason: 'without RomM connected there is nothing to link to',
      );
    });
  });
}
