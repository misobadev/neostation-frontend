import '../../models/database_game_model.dart';
import '../../models/smart_collection_rules.dart';

/// One evaluator is shared by previews, counts, badges and collection loading.
/// The caller captures [now] once so rolling windows agree within a snapshot.
class SmartCollectionEvaluator {
  const SmartCollectionEvaluator(this.now);
  final DateTime now;

  static bool isEligible(DatabaseGameModel game) =>
      !game.isHidden &&
      !['android', 'music'].contains(game.systemFolderName) &&
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
      final last = game.lastPlayed;
      if (last == null) return false;
      final cutoff = now.subtract(Duration(days: (rule.value as num).toInt()));
      final within = !last.isBefore(cutoff) && !last.isAfter(now);
      return rule.operator == SmartOperator.withinDays
          ? within
          : last.isBefore(cutoff);
    }
    final text = switch (rule.field) {
      SmartField.title =>
        (game.screenscraperRealName?.trim().isNotEmpty ?? false)
            ? game.screenscraperRealName
            : (game.realName?.trim().isNotEmpty ?? false)
            ? game.realName
            : game.filename,
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
      if (text == null || text.trim().isEmpty) return false;
      final actual = _normalizeText(text);
      final expected = _normalizeText(rule.value as String);
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
        game.rating != null && game.rating! > 0 ? game.rating! / 2 : null,
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

  // Fold Latin accents for matching without changing stored/displayed metadata.
  static final _combiningAccents = RegExp(r'[\u0300-\u036f]');
  static const _accentGroups = {
    'a': 'àáâãäåāăą',
    'c': 'çćĉċč',
    'd': 'ďđ',
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
  };
  static final _accentReplacements = {
    for (final group in _accentGroups.entries)
      for (final rune in group.value.runes) rune: group.key,
  };

  static String _normalizeText(String text) => String.fromCharCodes(
    text
        .trim()
        .toLowerCase()
        .replaceAll(_combiningAccents, '')
        .runes
        .map((rune) => _accentReplacements[rune]?.codeUnitAt(0) ?? rune),
  );

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
      final last = game.lastPlayed;
      if (last == null) continue;
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
