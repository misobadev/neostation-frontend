import '../../models/smart_collection_rules.dart';
import 'smart_collections_service.dart';
import 'dart:io';
import 'dart:math';

import 'package:flutter/painting.dart';
import 'package:path/path.dart' as path;

import 'package:neostation/services/logger_service.dart';
import '../../models/collection_model.dart';
import '../../models/game_model.dart';
import '../../repositories/collection_repository.dart';
import '../config_service.dart';
import '../game/game_list_service.dart';

/// User-defined collections of games.
///
/// Owns the read/write API above [CollectionRepository]: CRUD on the
/// collections themselves, membership add/remove keyed on `rom_path`, and the
/// artwork file handling under `<userData>/media/collections/`.
///
/// Deliberately stateless — no in-memory cache. `subDisplay()` runs a second
/// Flutter engine that shares the SQLite file and nothing in memory, so a
/// static cache here would go stale across engines the moment either side
/// wrote (CLAUDE.md, dual-display devices).
class CollectionsService {
  CollectionsService._();

  static final _log = LoggerService.instance;

  static final Random _random = Random.secure();

  /// Image extensions a collection's artwork may use, matching the
  /// custom-system-art picker.
  static const List<String> supportedImageExtensions = [
    'png',
    'jpg',
    'jpeg',
    'webp',
    'gif',
  ];

  // ── Collections ────────────────────────────────────────────────────────────

  /// Returns every collection, ordered by `sort_order` then name, each with its
  /// game count already filled in by the listing query.
  static Future<List<CollectionModel>> getCollections() async {
    try {
      return (await SmartCollectionsService.snapshot()).collections;
    } catch (e) {
      _log.e('Error loading collections: $e');
      return [];
    }
  }

  /// Returns a single collection, or null when it no longer exists.
  static Future<CollectionModel?> getCollection(String id) async {
    try {
      final row = await CollectionRepository.getCollectionById(id);
      if (row == null) return null;
      final collection = CollectionModel.fromJson(row);
      if (collection.isSmart) {
        final count = collection.rules == null
            ? 0
            : (await SmartCollectionsService.preview(collection.rules!)).length;
        return collection.copyWith(gameCount: count);
      }
      return collection;
    } catch (e) {
      _log.e('Error loading collection $id: $e');
      return null;
    }
  }

  /// Creates a collection named [name], appended at the end of the list.
  ///
  /// [imageSourcePath], when given, is copied into the collection media folder
  /// exactly as [setCollectionImage] does. A copy failure does not fail the
  /// create — the collection is still worth having without artwork.
  static Future<CollectionModel> createCollection(
    String name, {
    String? imageSourcePath,
    SmartCollectionRules? rules,
  }) async {
    final id = _generateUuidV4();
    final trimmed = name.trim();

    if (trimmed.isEmpty) throw ArgumentError('Collection name is empty');
    await CollectionRepository.insertCollection(
      id: id,
      name: trimmed,
      rulesJson: rules?.encode(),
    );

    String? imagePath;
    if (imageSourcePath != null && imageSourcePath.isNotEmpty) {
      imagePath = await setCollectionImage(id, imageSourcePath);
    }

    final created = await getCollection(id);
    return created ??
        CollectionModel(
          id: id,
          name: trimmed,
          imagePath: imagePath,
          isSmart: rules != null,
          rules: rules,
        );
  }

  /// Renames a collection. Duplicate names are allowed by design.
  static Future<void> renameCollection(String id, String name) async {
    final trimmed = name.trim();
    if (trimmed.isEmpty) return;
    await CollectionRepository.updateCollection(id, name: trimmed);
  }

  /// Deletes a collection, its membership rows, and its artwork file.
  ///
  /// The file delete is best effort: an unreadable or already-missing image
  /// must not stop the collection going away.
  static Future<void> deleteCollection(String id) async {
    final existing = await getCollection(id);
    await CollectionRepository.deleteCollection(id);
    await _deleteImageFile(existing?.imagePath);
  }

  /// Moves [id] to position [sortOrder] in the collections list.
  static Future<void> setCollectionSortOrder(String id, int sortOrder) =>
      CollectionRepository.updateCollection(id, sortOrder: sortOrder);

  // ── Artwork ────────────────────────────────────────────────────────────────

  /// Copies [pickedFilePath] into `<userData>/media/collections/` and stores it
  /// as the collection's image, returning the new absolute path (null on
  /// failure).
  ///
  /// The target is named after the collection **id**, not its name, so a rename
  /// never orphans the file. The image cache is evicted afterwards because
  /// replacing a file at the same path changes no `ValueKey` — without this the
  /// old picture keeps being painted (mirrors the custom-system-art flow).
  ///
  /// Picking the file is the caller's job: the picker differs between desktop
  /// and Android TV, and this layer must not reach for a `BuildContext`.
  static Future<String?> setCollectionImage(
    String id,
    String pickedFilePath,
  ) async {
    try {
      final source = File(pickedFilePath);
      if (!source.existsSync()) {
        _log.w('Collection image source does not exist: $pickedFilePath');
        return null;
      }

      final targetDir = Directory(await collectionsMediaDirectory());
      if (!targetDir.existsSync()) {
        await targetDir.create(recursive: true);
      }

      // A previous image may have a different extension; drop it so the
      // collection is never left with two artwork files.
      final previous = (await getCollection(id))?.imagePath;

      final extension = path.extension(source.path);
      final target = path.join(targetDir.path, '$id$extension');
      await source.copy(target);

      if (previous != null && previous != target) {
        await _deleteImageFile(previous);
      }

      await _evictImageCache(target);
      await CollectionRepository.updateCollection(id, imagePath: target);
      return target;
    } catch (e) {
      _log.e('Error setting image for collection $id: $e');
      return null;
    }
  }

  /// Clears a collection's artwork, deleting the file (best effort).
  static Future<void> clearCollectionImage(String id) async {
    final existing = await getCollection(id);
    await CollectionRepository.updateCollection(id, clearImagePath: true);
    await _deleteImageFile(existing?.imagePath);
    await _evictImageCache(existing?.imagePath);
  }

  /// Absolute path of the folder collection artwork is stored in.
  static Future<String> collectionsMediaDirectory() async {
    final userDataPath = await ConfigService.getUserDataPath();
    return path.join(userDataPath, 'media', 'collections');
  }

  // ── Membership ─────────────────────────────────────────────────────────────

  /// Adds [game] to a collection. Re-adding is a no-op.
  ///
  /// Keyed on the raw `rom_path`: on Android that is a URL-encoded SAF
  /// `content://` URI and must be stored exactly as `user_roms` holds it, or
  /// membership and favourites disagree about the same game.
  static Future<void> addGame(String collectionId, GameModel game) async {
    await _requireManual(collectionId);
    final romPath = game.romPath;
    if (romPath == null || romPath.isEmpty) return;
    await CollectionRepository.addRomToCollection(collectionId, romPath);
  }

  /// Removes [game] from a collection. Removing a non-member is a no-op.
  static Future<void> removeGame(String collectionId, GameModel game) async {
    await _requireManual(collectionId);
    final romPath = game.romPath;
    if (romPath == null || romPath.isEmpty) return;
    await CollectionRepository.removeRomFromCollection(collectionId, romPath);
  }

  /// Adds or removes [game] and returns whether it is now a member.
  static Future<bool> toggleGame(String collectionId, GameModel game) async {
    await _requireManual(collectionId);
    final romPath = game.romPath;
    if (romPath == null || romPath.isEmpty) return false;

    final ids = await CollectionRepository.getCollectionIdsForRom(romPath);
    if (ids.contains(collectionId)) {
      await CollectionRepository.removeRomFromCollection(collectionId, romPath);
      return false;
    }
    await CollectionRepository.addRomToCollection(collectionId, romPath);
    return true;
  }

  /// Returns the ids of every collection [game] belongs to.
  ///
  /// One query — this is what the context menu ticks its entries from.
  static Future<Set<String>> collectionIdsFor(GameModel game) async {
    final romPath = game.romPath;
    if (romPath == null || romPath.isEmpty) return <String>{};
    try {
      return await SmartCollectionsService.collectionIdsFor(romPath);
    } catch (e) {
      _log.e('Error reading collections for ${game.romname}: $e');
      return <String>{};
    }
  }

  /// Every `rom_path` filed in at least one collection.
  ///
  /// Read whole rather than per game: the games views badge every visible row,
  /// and one query beats one per card.
  static Future<Set<String>> memberRomPaths() async {
    try {
      return (await SmartCollectionsService.snapshot()).memberPaths;
    } catch (e) {
      _log.e('Error reading collection membership: $e');
      return <String>{};
    }
  }

  /// Loads a collection's games as display-ready [GameModel]s.
  ///
  /// Delegates to the games loader so per-system naming preferences
  /// (extension/tag stripping, scraped-title coalescing) and hidden-ROM
  /// filtering are applied exactly as they are for favourites.
  static Future<List<GameModel>> loadGamesForCollection(String collectionId) =>
      GameListService.loadGamesForCollection(collectionId);

  static Future<void> updateRules(String id, SmartCollectionRules rules) async {
    final collection = await getCollection(id);
    if (collection == null || !collection.isSmart) {
      throw StateError('Only smart collections have rules');
    }
    await CollectionRepository.updateCollection(id, rulesJson: rules.encode());
  }

  static Future<void> _requireManual(String id) async {
    final collection = await getCollection(id);
    if (collection == null || collection.isSmart) {
      throw StateError('Membership is editable only for manual collections');
    }
  }

  // ── Internals ──────────────────────────────────────────────────────────────

  /// Generates a RFC 4122 version 4 UUID without pulling in a dependency.
  ///
  /// The bare (unprefixed) form is what the `collection:<uuid>` synthesized
  /// folder name and the artwork filename both carry.
  static String _generateUuidV4() {
    final bytes = List<int>.generate(16, (_) => _random.nextInt(256));
    bytes[6] = (bytes[6] & 0x0f) | 0x40; // version 4
    bytes[8] = (bytes[8] & 0x3f) | 0x80; // variant 1
    final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
        '${hex.substring(12, 16)}-${hex.substring(16, 20)}-'
        '${hex.substring(20)}';
  }

  /// Deletes an artwork file, ignoring every failure.
  static Future<void> _deleteImageFile(String? imagePath) async {
    if (imagePath == null || imagePath.isEmpty) return;
    try {
      final file = File(imagePath);
      if (file.existsSync()) await file.delete();
    } catch (e) {
      _log.w('Could not delete collection image $imagePath: $e');
    }
  }

  /// Drops [imagePath] from Flutter's image caches so the next paint reloads
  /// it from disk.
  static Future<void> _evictImageCache(String? imagePath) async {
    if (imagePath == null || imagePath.isEmpty) return;
    try {
      await FileImage(File(imagePath)).evict();
      PaintingBinding.instance.imageCache.clear();
      PaintingBinding.instance.imageCache.clearLiveImages();
    } catch (e) {
      _log.w('Could not evict collection image cache: $e');
    }
  }
}
