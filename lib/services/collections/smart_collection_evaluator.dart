import '../../constants/system_folder_names.dart';
import '../../utils/game_rating.dart';
import '../../models/database_game_model.dart';
import '../../models/smart_collection_rules.dart';

/// One evaluator is shared by previews, smart counts and collection loading.
/// The caller captures [now] once so rolling windows agree within a snapshot.
class SmartCollectionEvaluator {
  SmartCollectionEvaluator(this.now, {this.titleOf});
  final DateTime now;

  /// The title the lists display for a game, under its system's naming
  /// settings. Falls back to [DatabaseGameModel.displayTitle].
  final String Function(DatabaseGameModel game)? titleOf;

  /// Rule values are normalised once per evaluator, not once per game.
  final Map<String, String> _expected = {};

  /// Installed apps and music tracks are not games a rule can select. A new
  /// non-game system folder needs adding here.
  static const _ineligibleSystems = {
    SystemFolderNames.android,
    SystemFolderNames.music,
  };

  static bool isEligible(DatabaseGameModel game) =>
      !game.isHidden &&
      !_ineligibleSystems.contains(game.systemFolderName) &&
      game.romPath.isNotEmpty;

  bool matches(DatabaseGameModel game, SmartCollectionRules definition) {
    if (!isEligible(game)) return false;
    return definition.matchAll
        ? definition.rules.every((rule) => matchesRule(game, rule))
        : definition.rules.any((rule) => matchesRule(game, rule));
  }

  bool matchesRule(DatabaseGameModel game, SmartRule rule) {
    if (rule.field == SmartField.system) {
      final system = game.systemFolderName;
      if (system == null || system.isEmpty) return false;
      final found = (rule.value as List<String>).contains(system);
      return rule.operator == SmartOperator.isNot ? !found : found;
    }
    if (rule.field == SmartField.favorite || rule.field == SmartField.played) {
      final value = rule.field == SmartField.favorite
          ? game.isFavorite
          : game.lastPlayed != null || (game.playTime ?? 0) > 0;
      return value == rule.value;
    }
    if (rule.field == SmartField.lastPlayed) {
      final played = game.lastPlayed;
      if (played == null) return rule.operator == SmartOperator.notWithinDays;
      // A future date (clock skew, a sync from a device running ahead) counts
      // as played now, so the game lands in exactly one of the two rules.
      final last = played.isAfter(now) ? now : played;
      final cutoff = now.subtract(Duration(days: (rule.value as num).toInt()));
      final within = !last.isBefore(cutoff);
      return rule.operator == SmartOperator.withinDays ? within : !within;
    }
    final text = switch (rule.field) {
      SmartField.title => titleOf?.call(game) ?? game.displayTitle,
      SmartField.genre => game.genre,
      SmartField.developer => game.developer,
      SmartField.publisher => game.publisher,
      _ => null,
    };
    if ([
      SmartField.title,
      SmartField.genre,
      SmartField.developer,
      SmartField.publisher,
    ].contains(rule.field)) {
      if (text == null || text.trim().isEmpty) {
        return rule.operator == SmartOperator.isNot ||
            rule.operator == SmartOperator.notContains;
      }
      final actual = normalizeText(text);
      final expected = _expected.putIfAbsent(
        rule.value as String,
        () => normalizeText(rule.value as String),
      );
      return switch (rule.operator) {
        SmartOperator.isEqual => actual == expected,
        SmartOperator.isNot => actual != expected,
        SmartOperator.contains => actual.contains(expected),
        SmartOperator.notContains => !actual.contains(expected),
        _ => false,
      };
    }
    final num? actual = switch (rule.field) {
      SmartField.year => int.tryParse(
        RegExp(r'\d{4}')
                .firstMatch(
                  game.year ?? game.releaseDate?.toIso8601String() ?? '',
                )
                ?.group(0) ??
            '',
      ),
      SmartField.rating =>
        game.rating != null && game.rating! > 0
            ? gameRatingScore(game.rating!)
            : null,
      SmartField.playTime => (game.playTime ?? 0) / 60,
      _ => null,
    };
    if (actual == null) return false;
    final expected = rule.value as num;
    return switch (rule.operator) {
      SmartOperator.isEqual => actual == expected,
      SmartOperator.before => actual < expected,
      SmartOperator.after => actual > expected,
      SmartOperator.atLeast => actual >= expected,
      SmartOperator.atMost => actual <= expected,
      SmartOperator.between => actual >= expected && actual <= rule.upper!,
      _ => false,
    };
  }

  // Matching folds case, accents, ligatures, full-width forms and quote
  // styles without changing stored or displayed metadata. Dart has no NFKD,
  // so the folds that matter for game titles are spelled out, and decomposed
  // kana and Hangul (macOS filenames are NFD) are recomposed.
  static const _accentGroups = {
    'a': 'àáâãäåāăą',
    'c': 'çćĉċč',
    'd': 'ďđð',
    'e': 'èéêëēĕėęě',
    'g': 'ĝğġģ',
    'h': 'ĥħ',
    'i': 'ìíîïĩīĭįı',
    'j': 'ĵ',
    'k': 'ķ',
    'l': 'ĺļľŀł',
    'n': 'ñńņň',
    'o': 'òóôõöøōŏő',
    'r': 'ŕŗř',
    's': 'śŝşš',
    't': 'ţťŧ',
    'u': 'ùúûüũūŭůűų',
    'w': 'ŵ',
    'y': 'ýÿŷ',
    'z': 'źżž',
    "'": '‘’‚‛′`´',
    '"': '“”„‟″',
    '-': '‐‑‒–—―',
  };
  static const _expansions = {
    'æ': 'ae',
    'œ': 'oe',
    'ß': 'ss',
    'ĳ': 'ij',
    'þ': 'th',
    'ﬀ': 'ff',
    'ﬁ': 'fi',
    'ﬂ': 'fl',
  };
  static final _replacements = <int, List<int>>{
    for (final group in _accentGroups.entries)
      for (final rune in group.value.runes) rune: group.key.runes.toList(),
    for (final entry in _expansions.entries)
      entry.key.runes.single: entry.value.runes.toList(),
  };

  // Base kana followed by its voiced (dakuten) or semi-voiced (handakuten)
  // form. Katakana are the same pairs shifted by 0x60.
  static const _voiced = 'かがきぎくぐけげこごさざしじすずせぜそぞただちぢつづてでとどはばひびふぶへべほぼうゔ';
  static const _semiVoiced = 'はぱひぴふぷへぺほぽ';
  static Map<int, int> _kanaPairs(String pairs) {
    final runes = pairs.runes.toList();
    return {
      for (var i = 0; i < runes.length; i += 2) ...{
        runes[i]: runes[i + 1],
        runes[i] + 0x60: runes[i + 1] + 0x60,
      },
    };
  }

  static final _dakuten = _kanaPairs(_voiced)
    ..addAll({0x30EF: 0x30F7, 0x30F0: 0x30F8, 0x30F1: 0x30F9, 0x30F2: 0x30FA});
  static final _handakuten = _kanaPairs(_semiVoiced);

  static String normalizeText(String text) {
    final out = <int>[];
    for (var rune in text.trim().toLowerCase().runes) {
      // Full-width ASCII and the ideographic space.
      if (rune >= 0xFF01 && rune <= 0xFF5E) rune -= 0xFEE0;
      if (rune == 0x3000) rune = 0x20;
      if (rune >= 0x41 && rune <= 0x5A) rune += 0x20;
      final last = out.isEmpty ? null : out.last;
      // Combining or spacing (han)dakuten after a kana.
      if (last != null && (rune == 0x3099 || rune == 0x309B)) {
        final composed = _dakuten[last];
        if (composed != null) {
          out.last = composed;
          continue;
        }
      }
      if (last != null && (rune == 0x309A || rune == 0x309C)) {
        final composed = _handakuten[last];
        if (composed != null) {
          out.last = composed;
          continue;
        }
      }
      // Conjoining Hangul jamo: L + V, then LV + T.
      if (last != null &&
          rune >= 0x1161 &&
          rune <= 0x1175 &&
          last >= 0x1100 &&
          last <= 0x1112) {
        out.last = 0xAC00 + ((last - 0x1100) * 21 + (rune - 0x1161)) * 28;
        continue;
      }
      if (last != null &&
          rune >= 0x11A8 &&
          rune <= 0x11C2 &&
          last >= 0xAC00 &&
          last <= 0xD7A3 &&
          (last - 0xAC00) % 28 == 0) {
        out.last = last + (rune - 0x11A7);
        continue;
      }
      // Combining diacritics left over from decomposed Latin text.
      if (rune >= 0x300 && rune <= 0x36F) continue;
      final replacement = _replacements[rune];
      if (replacement != null) {
        out.addAll(replacement);
      } else {
        out.add(rune);
      }
    }
    return String.fromCharCodes(out);
  }

  /// Earliest instant at which a matching rolling rule can change its answer.
  DateTime? nextBoundary(
    Iterable<DatabaseGameModel> games,
    Iterable<SmartCollectionRules> definitions,
  ) {
    DateTime? next;
    final days = definitions
        .expand((d) => d.rules)
        .where((r) => r.field == SmartField.lastPlayed)
        .map((r) => (r.value as num).toInt())
        .toSet();
    for (final game in games) {
      final played = game.lastPlayed;
      if (played == null) continue;
      final last = played.isAfter(now) ? now : played;
      for (final day in days) {
        final boundary = last
            .add(Duration(days: day))
            .add(const Duration(milliseconds: 1));
        if (boundary.isAfter(now) &&
            (next == null || boundary.isBefore(next))) {
          next = boundary;
        }
      }
    }
    return next;
  }
}
