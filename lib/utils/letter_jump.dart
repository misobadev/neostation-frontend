import 'package:neostation/models/game_model.dart';
import 'game_name_sort.dart';

/// ES-DE style alphabetical "letter jump" helpers.
///
/// When a direction is held long enough the game views stop stepping one item
/// at a time and start hopping between alphabetical groups instead, dwelling on
/// each group briefly so the user can release on the letter they want. The
/// grouping rules live here so the list, grid and carousel all agree on what
/// counts as a letter boundary.
class LetterJump {
  LetterJump._();

  static final RegExp _alphaNumeric = RegExp(r'[A-Z0-9]');

  /// Label shown for games whose name starts with punctuation or a symbol.
  static const String other = '#';

  /// The alphabetical bucket a [game] belongs to: its first character upper
  /// cased, with a leading English article ignored, and anything that isn't a
  /// letter or digit collapsed into [other].
  static String letterFor(GameModel game, {bool ignoreArticles = true}) {
    final displayName = game.name.isNotEmpty ? game.name : game.romname;
    return letterForName(displayName, ignoreArticles: ignoreArticles);
  }

  /// [letterFor] for a bare display name. Returns [other] for empty names.
  static String letterForName(
    String displayName, {
    bool ignoreArticles = true,
  }) {
    final cleanName = gameNameSortKey(
      displayName,
      ignoreArticles: ignoreArticles,
    ).trim().toUpperCase();
    if (cleanName.isEmpty) return other;

    final firstChar = cleanName[0];
    return _alphaNumeric.hasMatch(firstChar) ? firstChar : other;
  }

  /// Index of the first item of the neighbouring alphabetical group, or `null`
  /// when there is no further group in that direction.
  ///
  /// The scan is purely positional — it compares adjacent items rather than
  /// assuming a sorted A→Z run — so a favourites-first ordering simply reads as
  /// its own set of groups and the jump still lands on group boundaries.
  ///
  /// Going [forward] lands on the first item whose letter differs from the
  /// current one. Going backwards lands on the *start* of the current group
  /// first (the usual "rewind to the top of this letter" behaviour), and only
  /// steps into the previous group once the cursor is already there.
  static int? targetIndex({
    required int length,
    required int currentIndex,
    required bool forward,
    required String Function(int index) letterAt,
  }) {
    if (length <= 0 || currentIndex < 0 || currentIndex >= length) return null;

    final current = letterAt(currentIndex);

    if (forward) {
      for (var i = currentIndex + 1; i < length; i++) {
        if (letterAt(i) != current) return i;
      }
      return null;
    }

    final groupStart = _groupStart(currentIndex, current, letterAt);
    if (groupStart < currentIndex) return groupStart;

    final previous = currentIndex - 1;
    if (previous < 0) return null;
    return _groupStart(previous, letterAt(previous), letterAt);
  }

  /// First index of the contiguous run of [letter] that contains [index].
  static int _groupStart(
    int index,
    String letter,
    String Function(int index) letterAt,
  ) {
    var start = index;
    while (start > 0 && letterAt(start - 1) == letter) {
      start--;
    }
    return start;
  }
}
