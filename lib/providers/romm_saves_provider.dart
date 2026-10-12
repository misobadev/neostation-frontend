import 'dart:async';

import 'package:flutter/foundation.dart';

import '../models/game_model.dart';
import '../models/romm_asset.dart';
import '../models/romm_rom.dart';
import '../models/romm_save_game.dart';
import '../models/sync_models.dart';
import '../repositories/romm_save_map_repository.dart';
import '../services/romm_service.dart' show RommException;
import '../sync/providers/romm_provider.dart';
import '../sync/sync_manager.dart';
import '../utils/lifo_semaphore.dart';
import 'file_provider.dart';
import 'romm_provider.dart';

/// What became of a [RommSavesProvider.delete].
enum RommDeleteOutcome {
  deleted,
  failed,

  /// Cancelled before any request, so nothing on the server changed.
  notSent,
}

/// Remote inventory state for the Saves tab. Merely browsing never syncs files.
///
/// Belongs to the RomM connection it was created on. Asset and ROM IDs mean
/// nothing on any other: another server or account can reuse them for
/// unrelated files. So once that connection ends this provider stops for good
/// (a refresh does nothing, a delete still waiting is cancelled), and the Saves
/// tab builds a new one for the next connection.
class RommSavesProvider extends ChangeNotifier {
  RommSavesProvider(
    this._browse,
    this._manager, {
    ValueListenable<Future<SyncResult>?>? runningSweep,
    FileProvider? fileProvider,
    Future<String?> Function(int)? loadLocalCover,
  }) : _session = _browse.service.session,
       _sweep = runningSweep ?? _rommSweep(_manager),
       _files = fileProvider,
       _loadLocalCover = loadLocalCover {
    _browse.addListener(_connectionChanged);
    _sweep?.addListener(_sweepChanged);
    // One already running when the tab opens is followed like a later one.
    final running = _sweep?.value;
    if (running != null) _followSweep(running);
  }

  /// The RomM provider's running sweep, when RomM is registered.
  static ValueListenable<Future<SyncResult>?>? _rommSweep(SyncManager manager) {
    final romm = manager.provider(RomMSyncProvider.kProviderId);
    return romm is RomMSyncProvider ? romm.runningSweep : null;
  }

  /// How many games' metadata a refresh waits for before it shows the list:
  /// more cards than fit on screen at once, as cards scale with the display.
  static const int _openingGames = 8;

  final RommProvider _browse;
  final SyncManager _manager;

  /// The connection this provider belongs to (see the class doc).
  final int _session;
  final ValueListenable<Future<SyncResult>?>? _sweep;
  final FileProvider? _files;
  final Future<String?> Function(int)? _loadLocalCover;
  final _metadataGate = LifoSemaphore(3);
  final Map<int, Future<RommSaveGameInfo>> _gameInfo = {};
  // Kept across refreshes (which only retry lookups) so the last good answer
  // stays on screen until a new one replaces it.
  final Map<int, RommSaveGameInfo> _loadedInfo = {};
  // Lookups that got no metadata, which the next refresh retries.
  final Set<int> _failedInfo = {};
  // [gameInfo]'s answer when there is nothing to look up. Always the same
  // future, so a FutureBuilder given it doesn't resubscribe on every rebuild.
  // One per provider rather than one for the app: a completed future runs its
  // listeners in the zone that made it.
  final _noGameInfo = Future.value(const RommSaveGameInfo());
  // Completes once this provider is disposed or its connection ends, which
  // wakes a delete still waiting so it can give up.
  final _ended = Completer<void>();
  List<RommAsset> _assets = const [];
  Object? _loadError;
  int _generation = 0;
  int _artworkRevision = 0;
  // What a delete waits out, along with a sweep started elsewhere: the latest
  // refresh and this tab's retry.
  Future<void>? _refreshing;
  Future<void>? _retrying;
  // A delete's requests while they are out.
  Future<void>? _sending;
  bool _deleting = false;
  bool _disposed = false;

  /// The same list until the inventory changes, so what is derived from it can
  /// be cached by identity.
  List<RommAsset> get assets => _assets;
  bool get loading => _refreshing != null;

  /// Advanced by a [refresh] that retries artwork, independently of the cached
  /// game metadata.
  int get artworkRevision => _artworkRevision;

  /// True during a retry, and during a sweep this provider did not start, such
  /// as the automatic one after connect, since a retry would only overlap it.
  bool get syncing => _retrying != null || _sweep?.value != null;
  bool get deleting => _deleting;
  Object? get loadError => _loadError;

  /// Whether this provider's connection is still the current one. A delete
  /// already sending checks only this, so it finishes after disposal.
  bool get _connected =>
      _browse.isConnected && _browse.service.session == _session;
  bool get _live => !_disposed && _connected;

  /// Memoized and requested only for visible games. Missing art/metadata never
  /// prevents the inventory from loading, and a refresh retries failed lookups.
  Future<RommSaveGameInfo> gameInfo(int? romId) {
    if (romId == null || !_live) return _noGameInfo;
    return _gameInfo.putIfAbsent(
      romId,
      () => _readGameInfo(romId).then((info) {
        if (_live) {
          _loadedInfo[romId] = info;
          if (info.rom == null) _failedInfo.add(romId);
        }
        return info;
      }),
    );
  }

  /// What [gameInfo] has already resolved for [romId], or null while it is
  /// pending, so a newly built tile can show it in its first frame.
  RommSaveGameInfo? loadedGameInfo(int? romId) =>
      romId == null ? const RommSaveGameInfo() : _loadedInfo[romId];

  Future<RommSaveGameInfo> _readGameInfo(int romId) async {
    await _metadataGate.acquire();
    try {
      if (!_live) return const RommSaveGameInfo();
      // Resolve independently: device artwork remains useful when RomM's
      // detail endpoint is unavailable, and vice versa.
      final local = _readLocalCover(romId);
      RommRom? rom;
      try {
        rom = await _browse.service.getRom(romId);
      } catch (_) {
        // Save inventory is still usable without game metadata.
      }
      final cover = await local;
      if (!_live) return const RommSaveGameInfo();
      final server = Uri.tryParse(_browse.service.baseUrl);
      return RommSaveGameInfo(
        rom: rom,
        localCover: cover,
        serverCovers: rom == null || server == null
            ? const []
            : _browse.service
                  .tileCoverUrlCandidates(rom)
                  .where((url) {
                    final uri = Uri.tryParse(url);
                    // Only artwork hosted on this RomM server, never a metadata
                    // provider's external URL or a newly scraped image.
                    return uri != null &&
                        uri.scheme == server.scheme &&
                        uri.host == server.host &&
                        uri.port == server.port;
                  })
                  .toSet()
                  .toList(),
      );
    } finally {
      _metadataGate.release();
    }
  }

  Future<String?> _readLocalCover(int romId) async {
    try {
      if (_loadLocalCover != null) return await _loadLocalCover(romId);
      final files = _files;
      if (files == null || !files.isInitialized) return null;
      for (final link in await RommSaveMapRepository.localNamesForRom(romId)) {
        for (final type in ['box2d', 'screenshots']) {
          final path = await GameModel.findExistingImagePath(
            romname: link.romname,
            systemFolderName: link.systemFolder,
            imageType: type,
            fileProvider: files,
          );
          if (path != null) return path;
        }
      }
    } catch (_) {
      // A stale local link or missing media directory isn't an inventory error.
    }
    return null;
  }

  void _connectionChanged() {
    if (!_connected && !_ended.isCompleted) _ended.complete();
  }

  /// A sweep started elsewhere shows here as a retry would: busy while it
  /// runs, then a refresh so its uploads appear. The sync provider reports
  /// its failures.
  void _sweepChanged() {
    // A retry's own sweep is left to [retryUploads], which already refreshes.
    if (_disposed || _retrying != null) return;
    notifyListeners();
    final running = _sweep!.value;
    if (running != null) _followSweep(running);
  }

  Future<void> _followSweep(Future<SyncResult> sweep) async {
    try {
      await sweep;
    } catch (_) {
      // Its uploads may still have partly landed, so refresh regardless.
    }
    // A listing taken while a delete's requests are out could still show the
    // files they remove, so it waits for them. (A delete still queued waits
    // for this refresh instead.)
    final sending = _sending;
    if (sending != null) await sending;
    await refresh(retryArtwork: false);
  }

  /// Reloads the inventory and retries metadata lookups that failed.
  ///
  /// [retryArtwork] also retries the artwork that failed, including covers the
  /// server had no image for, which it may have since. Only the user's refresh
  /// does: the automatic ones, after every sweep, would otherwise ask the
  /// server for each missing cover again on every connect.
  Future<void> refresh({bool retryArtwork = true}) {
    if (!_live) return Future.value();
    final generation = ++_generation;
    _failedInfo.forEach(_gameInfo.remove);
    _failedInfo.clear();
    if (retryArtwork) {
      _artworkRevision++;
      _browse.service.forgetDeadCovers([
        for (final info in _loadedInfo.values) ...info.serverCovers,
      ]);
    }
    _loadError = null;
    final refreshing = _refreshing = _load(generation);
    notifyListeners();
    return refreshing;
  }

  /// [refresh]'s listing. A newer refresh, or the connection ending, discards
  /// it.
  Future<void> _load(int generation) async {
    bool current() => _live && generation == _generation;
    try {
      final assets = await _browse.service.listSaveAssets();
      if (!current()) return;
      assets.sort((a, b) {
        final order = (b.updatedAt ?? b.createdAt ?? DateTime(1970)).compareTo(
          a.updatedAt ?? a.createdAt ?? DateTime(1970),
        );
        return order != 0 ? order : a.fileName.compareTo(b.fileName);
      });
      final listed = List<RommAsset>.unmodifiable(assets);
      // The names of the games that open on screen, so file-derived titles
      // never flash up before them. Capped so slow metadata can't hold the
      // list back for long; the rest fill in as they arrive.
      await Future.wait([
        for (final game in RommSaveGame.group(listed).take(_openingGames))
          gameInfo(game.romId),
      ]).timeout(const Duration(seconds: 5), onTimeout: () => const []);
      if (current()) _assets = listed;
    } catch (error) {
      if (current()) _loadError = error;
    } finally {
      if (generation == _generation) {
        _refreshing = null;
        if (!_disposed) notifyListeners();
      }
    }
  }

  /// Runs the upload sweep, then lists what it uploaded. Does nothing while a
  /// sweep is running: [syncing] covers one started elsewhere, which
  /// [_followSweep] refreshes after, so this can never be the overlapping
  /// call the sweep turns away as busy.
  Future<void> retryUploads() async {
    final sync = _manager.active;
    if (!_live ||
        syncing ||
        deleting ||
        sync?.providerId != RomMSyncProvider.kProviderId) {
      return;
    }
    final generation = _generation;
    // Set before the sync starts, as starting it announces its sweep.
    final retrying = Completer<void>();
    _retrying = retrying.future;
    notifyListeners();
    try {
      await sync!.fullSync();
    } catch (_) {
      // The sync provider reports its own failures; the refresh still runs.
    } finally {
      _retrying = null;
      retrying.complete();
      if (!_disposed) notifyListeners();
    }
    // Unless a newer listing has already replaced the one it would refresh.
    if (generation == _generation) await refresh(retryArtwork: false);
  }

  /// Permanently removes [assets] from the server. Local copies are untouched,
  /// so a device that still syncs the game uploads its copies again.
  ///
  /// Deleted only when all of them are gone. Any that are leave the list even
  /// when others could not be deleted. One made during a refresh or sync waits
  /// for it to finish rather than failing unsent. Disposing cancels one still
  /// waiting, but one already sending finishes and reports its outcome.
  Future<RommDeleteOutcome> delete(List<RommAsset> assets) async {
    if (assets.isEmpty || deleting || !_live) return RommDeleteOutcome.notSent;
    _deleting = true;
    notifyListeners();
    try {
      // A listing could bring back files the delete removes, and a sync could
      // be uploading the very save being deleted, so it waits out both, and
      // whatever one hands on to (a sweep ends with a refresh). Only while
      // busy: no async gap may separate the last check and the first request.
      while (_live) {
        final busy = _refreshing ?? _retrying ?? _sweep?.value;
        if (busy == null) break;
        await Future.any([busy.then((_) {}, onError: (_) {}), _ended.future]);
      }
      if (!_live) return RommDeleteOutcome.notSent;
      final generation = _generation;
      final sending = _send(assets);
      _sending = sending;
      final gone = await sending;
      // Drop them locally rather than listing the whole inventory again, unless
      // the list was since replaced.
      if (!_disposed && generation == _generation) {
        final goneKeys = {for (final asset in gone) asset.key};
        _assets = List.unmodifiable(
          _assets.where((a) => !goneKeys.contains(a.key)),
        );
      }
      return gone.length == assets.length
          ? RommDeleteOutcome.deleted
          : RommDeleteOutcome.failed;
    } finally {
      _sending = null;
      _deleting = false;
      if (!_disposed) notifyListeners();
    }
  }

  /// Sends the deletes for [assets], all the saves and all the states in a
  /// request each, and returns the files that are gone.
  Future<List<RommAsset>> _send(List<RommAsset> assets) async {
    final gone = <RommAsset>[];
    final notFound = <RommAsset>[];
    for (final isState in [false, true]) {
      final batch = assets.where((a) => a.isState == isState).toList();
      if (batch.isNotEmpty) gone.addAll(await _deleteBatch(batch, notFound));
    }
    if (notFound.isNotEmpty) gone.addAll(await _unlisted(notFound));
    return gone;
  }

  /// Deletes [batch], all saves or all states as each has its own endpoint, in
  /// one request. Returns the files it deleted, and adds any the server
  /// answered 404 for to [notFound].
  Future<List<RommAsset>> _deleteBatch(
    List<RommAsset> batch,
    List<RommAsset> notFound,
  ) async {
    // A connection change can reuse these IDs for unrelated files. Do not
    // send queued batches or 404 retries after the original session ends. The
    // service makes the same check again before every request it sends.
    if (!_connected) return const [];
    final ids = [for (final asset in batch) asset.id];
    try {
      await (batch.first.isState
          ? _browse.service.deleteStates(ids)
          : _browse.service.deleteSaves(ids));
      return batch;
    } on RommException catch (error) {
      if (error.statusCode != 404) return const [];
      // RomM stops a batch with a 404 at the first file it no longer has,
      // keeping the rest, so a batch goes again a file at a time to finish.
      if (batch.length == 1) {
        notFound.addAll(batch);
        return const [];
      }
      final gone = <RommAsset>[];
      for (final asset in batch) {
        gone.addAll(await _deleteBatch([asset], notFound));
      }
      return gone;
    } catch (_) {
      // Reported to the caller as a failed delete.
      return const [];
    }
  }

  /// Which of [assets] the server no longer lists. A file deleted from another
  /// device is what the user asked for, but a 404 alone does not prove that:
  /// a server or proxy without the delete route answers 404 too.
  Future<List<RommAsset>> _unlisted(List<RommAsset> assets) async {
    if (!_connected) return const [];
    try {
      final listed = {
        for (final asset in await _browse.service.listSaveAssets()) asset.key,
      };
      return assets.where((a) => !listed.contains(a.key)).toList();
    } catch (_) {
      // Unconfirmed, so reported as a failed delete.
      return const [];
    }
  }

  @override
  void dispose() {
    _disposed = true;
    if (!_ended.isCompleted) _ended.complete();
    _browse.removeListener(_connectionChanged);
    _sweep?.removeListener(_sweepChanged);
    super.dispose();
  }
}
