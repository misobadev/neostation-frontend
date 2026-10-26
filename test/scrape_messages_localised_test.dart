import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Scraping a game from the games list or the details card without a
/// ScreenScraper login (or without a system id) showed a fixed English
/// message whatever the app language. Every user-facing string goes through
/// AppLocale, so these screens must not pass a plain string literal to
/// `AppNotification.showNotification`.
void main() {
  const screens = [
    'lib/screens/game_screen/my_games_list.dart',
    'lib/screens/game_screen/game_details_card/game_details_card_list.dart',
  ];

  // `showNotification(context, 'Some text'` (single or double quotes, no
  // interpolation) that isn't immediately localised with `.getString`.
  final literal = RegExp(
    r"""showNotification\(\s*\w+,\s*(['"])((?:(?!\1)[^$])*)\1(?!\s*\.getString)""",
  );

  for (final path in screens) {
    test('$path shows only localised notifications', () {
      final source = File(path).readAsStringSync();
      final found = literal.allMatches(source).map((m) => m.group(2)).toList();
      expect(
        found,
        isEmpty,
        reason:
            'notification text must come from AppLocale (a key with a value '
            'in every language), not a string literal',
      );
    });
  }
}
