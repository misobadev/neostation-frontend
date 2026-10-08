import 'dart:async';
import 'package:flutter/widgets.dart';
import '../models/smart_collection_rules.dart';
import '../models/database_game_model.dart';
import '../services/collections/smart_collections_service.dart';

import '../models/collection_model.dart';
import '../models/game_model.dart';
import '../services/collections/collections_service.dart';

/// Holds the user's collections for the widget tree.
///
/// Two consumers depend on being notified: the systems carousel/grid (the
/// Collections card's game count) and the collections browser screen.
///
/// Every mutation writes through [CollectionsService] and then re-reads the
/// list, so the game counts stay honest without a second query per collection —
/// the listing query already computes them in one `GROUP BY`.
///
/// Nothing here is static. `subDisplay()` runs a second Flutter engine that
/// shares the SQLite file and nothing in memory, so a process-wide cache would
/// go stale the moment either engine wrote (CLAUDE.md, dual-display devices).
class CollectionsProvider extends ChangeNotifier with WidgetsBindingObserver {
  CollectionsProvider({List<ChangeNotifier> sources = const []})
    : _sources = sources {
    WidgetsBinding.instance.addObserver(this);
    for (final source in _sources) {
      source.addListener(_scheduleRefresh);
    }
  }

  final List<ChangeNotifier> _sources;
  Timer? _debounce;
  Timer? _boundaryTimer;
  bool _disposed = false;
  bool _pending = false;
  Future<void>? _loadFuture;
  int _revision = 0;
  int get revision => _revision;

  void _scheduleRefresh() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 300), () => load());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) load();
  }

  @override
  void dispose() {
    _disposed = true;
    _debounce?.cancel();
    _boundaryTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    for (final source in _sources) {
      source.removeListener(_scheduleRefresh);
    }
    super.dispose();
  }

  Future<void> _readSnapshot() async {
    final snapshot = await SmartCollectionsService.snapshot();
    if (_disposed) return;
    _collections = snapshot.collections;
    _memberRomPaths = snapshot.memberPaths;
    _revision++;
    _boundaryTimer?.cancel();
    if (snapshot.nextBoundary != null) {
      final delay = snapshot.nextBoundary!.difference(DateTime.now());
      _boundaryTimer = Timer(
        delay.isNegative ? Duration.zero : delay,
        () => load(),
      );
    }
  }

  List<CollectionModel> _collections = const [];
  bool _isLoading = false;
  bool _hasLoaded = false;

  /// Every `rom_path` that belongs to at least one collection.
  ///
  /// Held here so the games views can badge a row without a query per card.
  /// Refreshed with the list itself, which is exactly when membership can have
  /// changed from this engine.
  Set<String> _memberRomPaths = const {};

  /// Bumped whenever a collection's artwork file is replaced in place.
  ///
  /// Replacing a file at the same path changes no `ValueKey`, so widgets need a
  /// value that does change to force a repaint — the same reason
  /// `SystemInfo.imageVersion` exists.
  int _imageVersion = 0;

  /// The collections, ordered by `sort_order` then name.
  List<CollectionModel> get collections => List.unmodifiable(_collections);

  /// True while a [load] is in flight.
  bool get isLoading => _isLoading;

  /// True once the first [load] has completed, successfully or not.
  bool get hasLoaded => _hasLoaded;

  /// Total games across all collections, **counting a game once per
  /// collection it is filed in**. This is what the Collections card shows.
  ///
  /// Deliberately not a distinct count, at the maintainer's call, and it was
  /// distinct for a day before being changed — so the reasoning is worth
  /// keeping. The browser lists every collection with its own count directly
  /// under the card, and a reader adds those up. A card reading 6 over
  /// collections of 1, 4 and 4 looks broken, and nothing on screen explains
  /// the overlap that accounts for it; the arithmetic working is worth more
  /// here than the stricter number, because the per-collection counts are the
  /// visible source of truth.
  ///
  /// Known consequence, accepted: with enough overlap this can exceed the
  /// number of games in the library. If that ever needs fixing, do it by
  /// showing the overlap rather than by silently switching the number back —
  /// the distinct count is `_memberRomPaths.length`, already loaded for the
  /// games views' badge.
  ///
  /// Note the question only exists *across* collections. Within one,
  /// [CollectionModel.gameCount] is already distinct and needs no `DISTINCT`:
  /// `user_collection_items` is keyed on `(collection_id, rom_path)`, so the
  /// same game cannot be filed in one collection twice.
  int get totalGameCount => _collections.fold(0, (sum, c) => sum + c.gameCount);

  /// Seeds [collections] without a database, so a test can pin what the counts
  /// derived from them mean. Not a general setter: nothing in the app may
  /// bypass [CollectionsService] to change state.
  @visibleForTesting
  void debugSetCollections(List<CollectionModel> collections) {
    _collections = List.unmodifiable(collections);
  }

  /// Cache-busting counter for collection artwork.
  int get imageVersion => _imageVersion;

  /// Whether [romPath] is filed in any collection.
  ///
  /// Membership of a *particular* collection still needs [collectionIdsFor];
  /// this answers only the question a badge asks.
  bool isInAnyCollection(String? romPath) =>
      romPath != null &&
      romPath.isNotEmpty &&
      _memberRomPaths.contains(romPath);

  /// Returns the collection with [id], or null if it is not loaded.
  CollectionModel? byId(String id) {
    for (final collection in _collections) {
      if (collection.id == id) return collection;
    }
    return null;
  }

  /// Re-reads every collection (and its game count) from the database.
  ///
  /// Safe to call repeatedly; concurrent calls collapse into the first.
  Future<void> load() {
    if (_disposed) return Future.value();
    if (_loadFuture != null) {
      _pending = true;
      return _loadFuture!;
    }
    // Defer the first read so the future is installed before notifications.
    _loadFuture = Future<void>.microtask(
      _load,
    ).whenComplete(() => _loadFuture = null);
    return _loadFuture!;
  }

  Future<void> _load() async {
    if (_disposed) return;
    _isLoading = true;
    notifyListeners();
    try {
      do {
        _pending = false;
        await _readSnapshot();
      } while (_pending && !_disposed);
    } catch (error) {
      // Preserve the last successful snapshot on transient database failure.
      debugPrint('Collection refresh failed: $error');
    } finally {
      _isLoading = false;
      _hasLoaded = true;
      if (!_disposed) notifyListeners();
    }
  }

  /// Creates a collection and returns it, refreshing the list.
  Future<CollectionModel> create(
    String name, {
    String? imageSourcePath,
    SmartCollectionRules? rules,
  }) async {
    final created = await CollectionsService.createCollection(
      name,
      imageSourcePath: imageSourcePath,
      rules: rules,
    );
    await _refresh();
    return created;
  }

  Future<void> updateRules(String id, SmartCollectionRules rules) async {
    await CollectionsService.updateRules(id, rules);
    await _refresh();
  }

  Future<List<DatabaseGameModel>> ruleLibrary() =>
      SmartCollectionsService.library();

  /// Renames a collection and refreshes the list.
  Future<void> rename(String id, String name) async {
    await CollectionsService.renameCollection(id, name);
    await _refresh();
  }

  /// Deletes a collection (and its artwork) and refreshes the list.
  Future<void> delete(String id) async {
    await CollectionsService.deleteCollection(id);
    await _refresh();
  }

  /// Replaces a collection's artwork with a copy of [pickedFilePath].
  ///
  /// Bumps [imageVersion] on success so widgets keyed on it repaint even though
  /// the file path is unchanged.
  Future<String?> setImage(String id, String pickedFilePath) async {
    final target = await CollectionsService.setCollectionImage(
      id,
      pickedFilePath,
    );
    if (target != null) _imageVersion++;
    await _refresh();
    return target;
  }

  /// Clears a collection's artwork and bumps [imageVersion].
  Future<void> clearImage(String id) async {
    await CollectionsService.clearCollectionImage(id);
    _imageVersion++;
    await _refresh();
  }

  /// Adds [game] to a collection, refreshing the counts.
  Future<void> addGame(String collectionId, GameModel game) async {
    await CollectionsService.addGame(collectionId, game);
    await _refresh();
  }

  /// Removes [game] from a collection, refreshing the counts.
  Future<void> removeGame(String collectionId, GameModel game) async {
    await CollectionsService.removeGame(collectionId, game);
    await _refresh();
  }

  /// Toggles [game]'s membership and returns whether it is now a member.
  Future<bool> toggleGame(String collectionId, GameModel game) async {
    final isMember = await CollectionsService.toggleGame(collectionId, game);
    await _refresh();
    return isMember;
  }

  /// Returns the ids of the collections [game] belongs to.
  ///
  /// Read straight from the database rather than from [collections]: membership
  /// is not held in memory, and the second engine may have changed it.
  Future<Set<String>> collectionIdsFor(GameModel game) =>
      CollectionsService.collectionIdsFor(game);

  /// Re-reads after a mutation, bypassing [load]'s in-flight guard.
  Future<void> _refresh() async {
    await load();
  }
}
