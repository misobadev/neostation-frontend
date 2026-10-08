import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/models/collection_model.dart';
import 'package:neostation/models/database_game_model.dart';
import 'package:neostation/models/smart_collection_rules.dart';
import 'package:neostation/services/collections/smart_collection_evaluator.dart';

void main() {
  final now = DateTime.utc(2026, 10, 4, 12);
  final evaluator = SmartCollectionEvaluator(now);
  DatabaseGameModel game({
    String system = 'snes',
    bool hidden = false,
    String? genre,
    String? developer,
    String? publisher,
    String? title,
    String? year,
    double? rating,
    int? seconds,
    DateTime? last,
    bool favorite = false,
  }) => DatabaseGameModel(
    filename: 'Chrono Trigger.sfc',
    romPath: 'content://roms/primary%3Asnes%2FChrono.sfc',
    systemFolderName: system,
    isHidden: hidden,
    genre: genre,
    developer: developer,
    publisher: publisher,
    realName: title,
    year: year,
    rating: rating,
    playTime: seconds,
    lastPlayed: last,
    isFavorite: favorite,
  );
  bool matches(
    DatabaseGameModel g,
    SmartField field,
    SmartOperator op,
    Object value, {
    num? upper,
  }) => evaluator.matches(
    g,
    SmartCollectionRules(
      rules: [
        SmartRule(field: field, operator: op, value: value, upper: upper),
      ],
    ),
  );

  test('Pokemon title rule includes Pokémon', () {
    expect(
      matches(
        game(title: 'Pokémon Emerald'),
        SmartField.title,
        SmartOperator.contains,
        'Pokemon',
      ),
      isTrue,
    );
  });

  test('text rules ignore accents on either side for every operator', () {
    for (final title in ['Pokémon', 'Poke\u0301mon', 'Pokemon']) {
      for (final query in ['Pokemon', 'POKÉMON', 'Poke\u0301mon']) {
        for (final op in operatorsFor(SmartField.title)) {
          expect(
            matches(game(title: title), SmartField.title, op, query),
            op == SmartOperator.contains || op == SmartOperator.isEqual,
            reason: '$title $op $query',
          );
        }
      }
    }
    for (final field in [
      SmartField.genre,
      SmartField.developer,
      SmartField.publisher,
    ]) {
      expect(
        matches(
          game(genre: 'Énigme', developer: 'Énigme', publisher: 'Énigme'),
          field,
          SmartOperator.isNot,
          'enigme',
        ),
        isFalse,
      );
      expect(
        matches(
          game(genre: 'Énigme', developer: 'Énigme', publisher: 'Énigme'),
          field,
          SmartOperator.isEqual,
          'enigme',
        ),
        isTrue,
      );
    }
    expect(
      matches(
        game(title: 'ポケモン'),
        SmartField.title,
        SmartOperator.isEqual,
        'ポケモン',
      ),
      isTrue,
    );
    expect(
      matches(
        game(title: 'Pokémon'),
        SmartField.title,
        SmartOperator.contains,
        'Mario',
      ),
      isFalse,
    );
  });

  test('all/any and multiple systems combine correctly', () {
    final rules = [
      SmartRule(
        field: SmartField.system,
        operator: SmartOperator.isEqual,
        value: ['snes', 'nes'],
      ),
      SmartRule(
        field: SmartField.genre,
        operator: SmartOperator.isEqual,
        value: 'RPG',
      ),
      SmartRule(
        field: SmartField.played,
        operator: SmartOperator.isEqual,
        value: false,
      ),
    ];
    expect(
      evaluator.matches(game(genre: 'rpg'), SmartCollectionRules(rules: rules)),
      isTrue,
    );
    expect(
      evaluator.matches(
        game(genre: 'Action'),
        SmartCollectionRules(rules: rules),
      ),
      isFalse,
    );
    expect(
      evaluator.matches(
        game(genre: 'Action'),
        SmartCollectionRules(matchAll: false, rules: rules),
      ),
      isTrue,
    );
    expect(
      matches(game(system: 'ps1'), SmartField.system, SmartOperator.isNot, [
        'snes',
      ]),
      isTrue,
    );
  });

  test('metadata text comparison trims and ignores case', () {
    expect(
      matches(
        game(genre: ' RPG, Adventure '),
        SmartField.genre,
        SmartOperator.contains,
        'adventure',
      ),
      isTrue,
    );
    expect(
      matches(
        game(developer: ' Square '),
        SmartField.developer,
        SmartOperator.isEqual,
        'square',
      ),
      isTrue,
    );
    expect(
      matches(
        game(publisher: 'Nintendo'),
        SmartField.publisher,
        SmartOperator.isNot,
        'Square',
      ),
      isTrue,
    );
    expect(
      matches(
        game(title: 'Chrono Trigger'),
        SmartField.title,
        SmartOperator.contains,
        'CHRONO',
      ),
      isTrue,
    );
    expect(
      matches(
        game(),
        SmartField.title,
        SmartOperator.isEqual,
        'chrono trigger.sfc',
      ),
      isTrue,
    );
    expect(
      matches(game(), SmartField.title, SmartOperator.notContains, 'mario'),
      isTrue,
    );
    expect(
      matches(game(), SmartField.genre, SmartOperator.isNot, 'RPG'),
      isFalse,
    );
    expect(
      matches(game(), SmartField.publisher, SmartOperator.contains, 'Nintendo'),
      isFalse,
    );
  });

  test('numeric operators include bounds and use display rating scale', () {
    expect(
      matches(
        game(year: '1995-03-11'),
        SmartField.year,
        SmartOperator.isEqual,
        1995,
      ),
      isTrue,
    );
    expect(
      matches(game(year: '1995'), SmartField.year, SmartOperator.before, 1996),
      isTrue,
    );
    expect(
      matches(game(year: '1995'), SmartField.year, SmartOperator.after, 1994),
      isTrue,
    );
    expect(
      matches(
        game(year: '1995'),
        SmartField.year,
        SmartOperator.between,
        1995,
        upper: 2000,
      ),
      isTrue,
    );
    expect(
      matches(
        game(year: 'unknown'),
        SmartField.year,
        SmartOperator.before,
        2000,
      ),
      isFalse,
    );
    expect(
      matches(game(rating: 17), SmartField.rating, SmartOperator.atLeast, 8.5),
      isTrue,
    );
    expect(
      matches(game(rating: 17), SmartField.rating, SmartOperator.atMost, 8.4),
      isFalse,
    );
    expect(
      matches(
        game(rating: 17),
        SmartField.rating,
        SmartOperator.between,
        8.5,
        upper: 9,
      ),
      isTrue,
    );
    for (final unrated in [null, 0.0]) {
      expect(
        matches(
          game(rating: unrated),
          SmartField.rating,
          SmartOperator.atMost,
          5,
        ),
        isFalse,
      );
    }
    expect(
      matches(
        game(seconds: 90),
        SmartField.playTime,
        SmartOperator.atLeast,
        1.5,
      ),
      isTrue,
    );
    expect(
      matches(
        game(seconds: 91),
        SmartField.playTime,
        SmartOperator.atMost,
        1.5,
      ),
      isFalse,
    );
    expect(
      matches(game(), SmartField.playTime, SmartOperator.atMost, 0),
      isTrue,
    );
  });

  test('played and favourite use persisted state', () {
    expect(
      matches(game(), SmartField.played, SmartOperator.isEqual, false),
      isTrue,
    );
    expect(
      matches(game(seconds: 1), SmartField.played, SmartOperator.isEqual, true),
      isTrue,
    );
    expect(
      matches(game(last: now), SmartField.played, SmartOperator.isEqual, true),
      isTrue,
    );
    expect(
      matches(
        game(favorite: true),
        SmartField.favorite,
        SmartOperator.isEqual,
        true,
      ),
      isTrue,
    );
  });

  test(
    'rolling days use exact elapsed boundaries and exclude missing timestamps',
    () {
      final cutoff = now.subtract(const Duration(days: 7));
      expect(
        matches(
          game(last: cutoff),
          SmartField.lastPlayed,
          SmartOperator.withinDays,
          7,
        ),
        isTrue,
      );
      expect(
        matches(
          game(last: cutoff),
          SmartField.lastPlayed,
          SmartOperator.notWithinDays,
          7,
        ),
        isFalse,
      );
      expect(
        matches(
          game(last: cutoff.subtract(const Duration(milliseconds: 1))),
          SmartField.lastPlayed,
          SmartOperator.notWithinDays,
          7,
        ),
        isTrue,
      );
      expect(
        matches(
          game(last: now.add(const Duration(days: 1))),
          SmartField.lastPlayed,
          SmartOperator.withinDays,
          7,
        ),
        isFalse,
      );
      for (final op in [
        SmartOperator.withinDays,
        SmartOperator.notWithinDays,
      ]) {
        expect(matches(game(), SmartField.lastPlayed, op, 7), isFalse);
      }
      final definition = SmartCollectionRules(
        rules: [
          SmartRule(
            field: SmartField.lastPlayed,
            operator: SmartOperator.withinDays,
            value: 7,
          ),
        ],
      );
      expect(
        evaluator.nextBoundary([game(last: cutoff)], [definition]),
        now.add(const Duration(milliseconds: 1)),
      );
    },
  );

  test('hidden games, apps and music never match even in any mode', () {
    for (final g in [
      game(hidden: true),
      game(system: 'android'),
      game(system: 'music'),
    ]) {
      expect(
        matches(g, SmartField.played, SmartOperator.isEqual, false),
        isFalse,
      );
    }
  });

  test('definitions round trip all typed values and reject invalid shapes', () {
    final definition = SmartCollectionRules(
      matchAll: false,
      rules: [
        SmartRule(
          field: SmartField.system,
          operator: SmartOperator.isEqual,
          value: ['snes'],
        ),
        SmartRule(
          field: SmartField.favorite,
          operator: SmartOperator.isEqual,
          value: false,
        ),
        SmartRule(
          field: SmartField.rating,
          operator: SmartOperator.between,
          value: 7.5,
          upper: 9,
        ),
      ],
    );
    expect(
      SmartCollectionRules.decode(definition.encode()).encode(),
      definition.encode(),
    );
    for (final source in [
      '{}',
      '{"version":2,"mode":"all","rules":[]}',
      '{"version":1,"mode":"bad","rules":[]}',
      '{"version":1,"mode":"all","rules":[]}',
      '{"version":1,"mode":"all","rules":[{"field":"unknown"}]}',
    ]) {
      expect(() => SmartCollectionRules.decode(source), throwsA(anything));
    }
    expect(
      () => SmartRule(
        field: SmartField.rating,
        operator: SmartOperator.atLeast,
        value: 11,
      ),
      throwsFormatException,
    );
    expect(
      () => SmartRule(
        field: SmartField.lastPlayed,
        operator: SmartOperator.withinDays,
        value: 1.5,
      ),
      throwsFormatException,
    );
    expect(
      () => SmartRule(
        field: SmartField.year,
        operator: SmartOperator.between,
        value: 2000,
        upper: 1999,
      ),
      throwsFormatException,
    );
    expect(
      () => SmartRule(
        field: SmartField.system,
        operator: SmartOperator.isEqual,
        value: <String>[],
      ),
      throwsFormatException,
    );
    expect(
      () => SmartRule(
        field: SmartField.rating,
        operator: SmartOperator.contains,
        value: '8',
      ),
      throwsFormatException,
    );
  });

  test('invalid persisted definitions stay smart with no evaluable rules', () {
    final c = CollectionModel.fromJson({
      'id': 'c',
      'name': 'Bad',
      'collection_type': 'smart',
      'rules_json': '{broken',
    });
    expect(c.isSmart, isTrue);
    expect(c.rulesInvalid, isTrue);
    expect(c.rules, isNull);
    expect(c.copyWith(name: 'Renamed').toJson()['rules_json'], '{broken');
    expect(CollectionModel.fromJson({'id': 'old'}).isSmart, isFalse);
  });

  test(
    'evaluating a large library is bounded and retains all matching ROMs',
    () {
      final rules = SmartCollectionRules(
        rules: [
          SmartRule(
            field: SmartField.system,
            operator: SmartOperator.isEqual,
            value: ['snes'],
          ),
          SmartRule(
            field: SmartField.played,
            operator: SmartOperator.isEqual,
            value: false,
          ),
        ],
      );
      final games = List.generate(
        20000,
        (i) => game(system: i.isEven ? 'snes' : 'nes'),
      );
      final watch = Stopwatch()..start();
      expect(games.where((g) => evaluator.matches(g, rules)).length, 10000);
      watch.stop();
      expect(watch.elapsed, lessThan(const Duration(seconds: 5)));
    },
  );
}
