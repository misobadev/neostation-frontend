import '../../models/collection_model.dart';
import '../../models/database_game_model.dart';
import '../../models/smart_collection_rules.dart';
import '../../repositories/collection_repository.dart';
import '../../repositories/game_repository.dart';
import '../game/game_list_service.dart';
import 'smart_collection_evaluator.dart';

class CollectionsSnapshot {
  final List<CollectionModel> collections;
  final Set<String> memberPaths;
  final DateTime? nextBoundary;
  final Map<String, Set<String>> collectionPaths;
  final Set<String> manualPaths;

  /// Per smart-matched game, a hash of the fields a rule or a list row shows,
  /// so an open collection refreshes when a member changes in place.
  final Map<String, int> gameHashes;

  /// Library revision the smart results were evaluated at; null when there
  /// are no smart collections.
  final Object? libraryRevision;
  const CollectionsSnapshot(
    this.collections,
    this.memberPaths,
    this.nextBoundary, [
    this.collectionPaths = const {},
    this.manualPaths = const {},
    this.gameHashes = const {},
    this.libraryRevision,
  ]);
}

/// The eligible slim library, with each game's displayed title by `rom_path`.
class SmartRuleLibrary {
  final List<DatabaseGameModel> games;
  final Map<String, String> titles;
  const SmartRuleLibrary(this.games, [this.titles = const {}]);

  String titleOf(DatabaseGameModel game) =>
      titles[game.romPath] ?? game.displayTitle;

  SmartCollectionEvaluator evaluator(DateTime now) =>
      SmartCollectionEvaluator(now, titleOf: titleOf);
}

typedef _Evaluation = ({
  Map<String, Set<String>> paths,
  DateTime? nextBoundary,
  Map<String, int> hashes,
});

/// Stateless reads: separate Flutter engines always derive from persisted data.
class SmartCollectionsService {
  /// The rule library, read and shaped off the UI isolate.
  static Future<SmartRuleLibrary> library() =>
      GameRepository.readRuleLibrary(_buildLibrary);

  static SmartRuleLibrary _buildLibrary(RuleLibraryRows rows) {
    final games = <DatabaseGameModel>[];
    final titles = <String, String>{};
    for (final row in rows.games) {
      final game = DatabaseGameModel.fromJson(row);
      if (!SmartCollectionEvaluator.isEligible(game)) continue;
      games.add(game);
      final system = game.appSystemId ?? '';
      titles[game.romPath] = GameListService.listDisplayName(
        game,
        rows.settings[system] ?? const {},
        rows.extensions[system] ?? const {},
      );
    }
    return SmartRuleLibrary(games, titles);
  }

  static Future<List<DatabaseGameModel>> preview(
    SmartCollectionRules rules,
  ) async {
    final library = await SmartCollectionsService.library();
    final evaluator = library.evaluator(DateTime.now());
    return library.games.where((g) => evaluator.matches(g, rules)).toList();
  }

  /// Games of collection [id]. For a smart collection, [smartPaths] are the
  /// matches the provider already evaluated; without them the rules are
  /// evaluated off the UI isolate. Either way only matched rows are read in
  /// full.
  static Future<List<DatabaseGameModel>> gamesFor(
    String id, {
    Set<String>? smartPaths,
  }) async {
    final row = await CollectionRepository.getCollectionById(id);
    if (row == null) return [];
    final collection = CollectionModel.fromJson(row);
    if (!collection.isSmart) {
      return CollectionRepository.getGamesInCollection(id);
    }
    final rules = collection.rules;
    if (rules == null) return [];
    final paths =
        smartPaths ??
        (await _evaluate([collection], DateTime.now())).paths[id] ??
        const <String>{};
    final games = (await GameRepository.getGamesByRomPaths(
      paths,
    )).where(SmartCollectionEvaluator.isEligible).toList();
    // Order by the name the list shows, which honours "prefer file name".
    final names = {
      for (final e in (await GameListService.listDisplayNames(games)).entries)
        e.key: e.value.toLowerCase(),
    };
    games.sort((a, b) {
      if (a.isFavorite != b.isFavorite) return a.isFavorite ? -1 : 1;
      return names[a.romPath]!.compareTo(names[b.romPath]!);
    });
    return games;
  }

  /// Reads collections and evaluates smart rules. When [previous] was taken
  /// at the same library revision with the same definitions, its smart
  /// results are reused and only manual memberships are re-read.
  static Future<CollectionsSnapshot> snapshot({
    CollectionsSnapshot? previous,
  }) async {
    final collections = (await CollectionRepository.getCollections())
        .map(CollectionModel.fromJson)
        .toList();
    final storedPaths = await CollectionRepository.getMemberPathsByCollection();
    final manualByCollection = {
      for (final collection in collections.where((c) => !c.isSmart))
        collection.id: storedPaths[collection.id] ?? <String>{},
    };
    final members = manualByCollection.values.expand((paths) => paths).toSet();
    final smart = collections
        .where((c) => c.isSmart && c.rules != null)
        .toList();
    if (smart.isEmpty) {
      return CollectionsSnapshot(
        collections,
        members,
        null,
        manualByCollection,
        Set.of(members),
      );
    }
    // Only now: the revision installs connection-local triggers, which a
    // manual-only library has no use for.
    final revision = await GameRepository.smartLibraryRevision();
    final _Evaluation evaluation;
    if (previous != null &&
        previous.libraryRevision == revision &&
        (previous.nextBoundary == null ||
            previous.nextBoundary!.isAfter(DateTime.now())) &&
        _sameDefinitions(previous.collections, smart)) {
      evaluation = (
        paths: {
          for (final c in smart) c.id: previous.collectionPaths[c.id] ?? {},
        },
        nextBoundary: previous.nextBoundary,
        hashes: previous.gameHashes,
      );
    } else {
      evaluation = await _evaluate(smart, DateTime.now());
    }
    return CollectionsSnapshot(
      [
        for (final c in collections)
          c.isSmart
              ? c.copyWith(gameCount: evaluation.paths[c.id]?.length ?? 0)
              : c,
      ],
      members,
      evaluation.nextBoundary,
      {...manualByCollection, ...evaluation.paths},
      Set.of(members),
      evaluation.hashes,
      revision,
    );
  }

  static bool _sameDefinitions(
    List<CollectionModel> previous,
    List<CollectionModel> smart,
  ) {
    final before = {
      for (final c in previous)
        if (c.isSmart && c.rules != null) c.id: c.rules!.encode(),
    };
    return before.length == smart.length &&
        smart.every((c) => before[c.id] == c.rules!.encode());
  }

  // Kept in a separate frame so the worker closure captures only the rule
  // definitions, never the connection-local library revision.
  static Future<_Evaluation> _evaluate(
    List<CollectionModel> smart,
    DateTime now,
  ) => GameRepository.readRuleLibrary((rows) {
    final library = _buildLibrary(rows);
    final evaluator = library.evaluator(now);
    final paths = <String, Set<String>>{};
    final matched = <String>{};
    for (final collection in smart) {
      final ids = library.games
          .where((g) => evaluator.matches(g, collection.rules!))
          .map((g) => g.romPath)
          .toSet();
      paths[collection.id] = ids;
      matched.addAll(ids);
    }
    return (
      paths: paths,
      nextBoundary: evaluator.nextBoundary(
        library.games,
        smart.map((c) => c.rules!),
      ),
      hashes: {
        for (final game in library.games)
          if (matched.contains(game.romPath))
            game.romPath: Object.hash(
              library.titleOf(game),
              game.isFavorite,
              game.playTime,
              game.lastPlayed,
              game.genre,
              game.developer,
              game.publisher,
              game.year,
              game.rating,
              game.systemRealName,
            ),
      },
    );
  });

  /// Manual memberships for the game context menu; rule matches are read-only.
  static Future<Set<String>> collectionIdsFor(String romPath) async {
    final collections = (await CollectionRepository.getCollections())
        .map(CollectionModel.fromJson)
        .where((c) => !c.isSmart)
        .map((c) => c.id)
        .toSet();
    return (await CollectionRepository.getCollectionIdsForRom(
      romPath,
    )).where(collections.contains).toSet();
  }
}

/// Provider-owned snapshot memo; every access checks the shared database for
/// changes, so the second engine's writes are still seen.
class SmartCollectionSnapshotCache {
  CollectionsSnapshot? _snapshot;

  Future<CollectionsSnapshot> snapshot() async =>
      _snapshot = await SmartCollectionsService.snapshot(previous: _snapshot);
}
