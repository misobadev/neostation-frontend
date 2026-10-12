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

/// A delete is queued while a refresh or sync finishes, then sends its
/// requests.
enum _DeleteState { idle, queued, sending }

/// What became of a [RommSavesProvider.delete].
enum RommDeleteOutcome {
  deleted,
  failed,

  /// Cancelled before any request, so nothing on the server changed.
  notSent,
}

/// Remote inventory state for the Saves tab. Merely browsing never syncs files.
class RommSavesProvider extends ChangeNotifier {
  RommSavesProvider(
    this._browse,
    this._manager, {
    ValueListenable<Future<SyncResult>?>? runningSweep,
    FileProvider? fileProvider,
    Future<String?> Function(int)? loadLocalCover,
  }) : _sweep = runningSweep ?? _rommSweep(_manager),
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

  final RommProvider _browse;
  final SyncManager _manager;
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
  List<RommAsset> _assets = const [];
  bool _loading = false;
  bool _syncing = false;
  _DeleteState _deleteState = _DeleteState.idle;
  // A sweep ended while a delete was sending, so its refresh waits for the
  // delete to finish.
  bool _refreshAfterDelete = false;
  bool _disposed = false;
  int _generation = 0;
  int _connectionGeneration = 0;
  // Disposing completes it too, as a disposed notifier never notifies again.
  Completer<void>? _changed;
  Object? _loadError;

  /// The same list until the inventory changes, so what is derived from it can
  /// be cached by identity.
  List<RommAsset> get assets => _assets;
  bool get loading => _loading;

  /// Refresh retries artwork independently of the cached game metadata.
  int get artworkRevision => _generation;

  /// True during a retry, and during a sweep this provider did not start, such
  /// as the automatic one after connect, since a retry would only overlap it.
  bool get syncing => _syncing || _sweep?.value != null;
  bool get deleting => _deleteState != _DeleteState.idle;
  Object? get loadError => _loadError;

  /// Memoized and requested only for visible games. Missing art/metadata never
  /// prevents the inventory from loading, and a refresh retries failed lookups.
  Future<RommSaveGameInfo> gameInfo(int? romId) {
    if (romId == null || _disposed || !_browse.isConnected) {
      return Future.value(const RommSaveGameInfo());
    }
    // A ROM's metadata only changes with the server, so lookups outlive
    // refreshes but not the connection.
    final connection = _connectionGeneration;
    return _gameInfo.putIfAbsent(
      romId,
      () => _readGameInfo(romId, connection).then((info) {
        if (connection == _connectionGeneration) {
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

  Future<RommSaveGameInfo> _readGameInfo(int romId, int connection) async {
    await _metadataGate.acquire();
    try {
      if (_disposed || connection != _connectionGeneration) {
        return const RommSaveGameInfo();
      }
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
      if (_disposed || connection != _connectionGeneration) {
        return const RommSaveGameInfo();
      }
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
        final game = GameModel.fromJson({'romname': link.romname});
        for (final type in ['box2d', 'screenshots']) {
          final path = game.getImagePath(link.systemFolder, type, files);
          if (await files.fileExists(path)) return path;
        }
      }
    } catch (_) {
      // A stale local link or missing media directory isn't an inventory error.
    }
    return null;
  }

  void _connectionChanged() {
    if (_browse.isConnected) return;
    _connectionGeneration++;
    _generation++;
    _gameInfo.clear();
    _loadedInfo.clear();
    _failedInfo.clear();
    _assets = const [];
    _loading = false;
    _loadError = null;
    _refreshAfterDelete = false;
    notifyListeners();
  }

  /// A sweep started elsewhere shows here as a retry would: busy while it
  /// runs, then a refresh so its uploads appear. A retry's own sweep is left
  /// to [retryUploads], which already refreshes. The sync provider reports
  /// either one's failures.
  void _sweepChanged() {
    if (_disposed || _syncing) return;
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
    // A disconnect has already cleared this session's state.
    if (_disposed || !_browse.isConnected) return;
    // A queued delete waits for this refresh too. Once requests are being
    // sent, a refresh would invalidate the remaining delete batches, so it
    // runs after them instead.
    if (_deleteState == _DeleteState.sending) {
      _refreshAfterDelete = true;
    } else {
      await refresh();
    }
  }

  Future<void> refresh() async {
    if (_disposed || !_browse.isConnected) return;
    final generation = ++_generation;
    _failedInfo.forEach(_gameInfo.remove);
    _failedInfo.clear();
    // Artwork retries with the new revision, including covers the server had
    // no image for, which it may have since.
    _browse.service.forgetDeadCovers([
      for (final info in _loadedInfo.values) ...info.serverCovers,
    ]);
    _loading = true;
    _loadError = null;
    notifyListeners();
    try {
      final assets = await _browse.service.listSaveAssets();
      if (_disposed || generation != _generation) return;
      assets.sort((a, b) {
        final order = (b.updatedAt ?? b.createdAt ?? DateTime(1970)).compareTo(
          a.updatedAt ?? a.createdAt ?? DateTime(1970),
        );
        return order != 0 ? order : a.fileName.compareTo(b.fileName);
      });
      _assets = List.unmodifiable(assets);
    } catch (error) {
      if (_disposed || generation != _generation) return;
      _loadError = error;
    } finally {
      if (!_disposed && generation == _generation) {
        _loading = false;
        notifyListeners();
      }
    }
  }

  Future<void> retryUploads() async {
    final sync = _manager.active;
    if (_disposed ||
        syncing ||
        deleting ||
        !_browse.isConnected ||
        sync?.providerId != RomMSyncProvider.kProviderId) {
      return;
    }
    final generation = _generation;
    _syncing = true;
    notifyListeners();
    SyncResult? result;
    try {
      result = await sync!.fullSync();
    } catch (_) {
      // The sync provider reports its own failures; the refresh still runs.
    } finally {
      _syncing = false;
      if (!_disposed) notifyListeners();
    }
    // A busy result means another sweep (the automatic one after connect) is
    // still uploading, so a refresh now would miss its files and reload every
    // game's artwork for nothing. [_followSweep] refreshes when it ends.
    if (!_disposed &&
        generation == _generation &&
        result?.error != SyncError.busy) {
      await refresh();
    }
  }

  /// Permanently removes [assets] from the server. Local copies are untouched,
  /// so a device that still syncs the game uploads its copies again.
  ///
  /// Deleted only when all of them are gone. Any that are leave the list even
  /// when others could not be deleted. One made during a refresh or sync waits
  /// for it to finish rather than failing unsent. Disposing cancels one still
  /// waiting, but one already sending finishes and reports its outcome.
  Future<RommDeleteOutcome> delete(List<RommAsset> assets) async {
    if (_disposed || assets.isEmpty || deleting || !_browse.isConnected) {
      return RommDeleteOutcome.notSent;
    }
    // Asset IDs must never reach a different server/account. Watched here, not
    // through [_connectionChanged], so it holds after this provider is gone.
    final session = _browse.service.session;
    var disconnected = false;
    void watchConnection() {
      if (!_browse.isConnected) disconnected = true;
    }

    bool sameConnection() =>
        !disconnected &&
        _browse.isConnected &&
        _browse.service.session == session;
    _browse.addListener(watchConnection);
    _deleteState = _DeleteState.queued;
    notifyListeners();
    try {
      // A sweep finishing can start a refresh in the same turn that wakes us.
      // Recheck here so no async gap separates the idle check and the request.
      while (!_disposed && sameConnection() && (_loading || syncing)) {
        await _nextChange();
      }
      if (_disposed || !sameConnection()) return RommDeleteOutcome.notSent;
      _deleteState = _DeleteState.sending;
      final generation = _generation;
      final gone = <RommAsset>[];
      final notFound = <RommAsset>[];
      for (final isState in [false, true]) {
        final batch = assets.where((a) => a.isState == isState).toList();
        if (batch.isNotEmpty) {
          gone.addAll(await _deleteBatch(batch, sameConnection, notFound));
        }
      }
      if (notFound.isNotEmpty) {
        gone.addAll(await _unlisted(notFound, sameConnection));
      }
      // Drop them locally rather than listing the whole inventory again, unless
      // the list was since closed or replaced. Saves and states are numbered
      // independently, so match both.
      if (!_disposed && generation == _generation) {
        _assets = List.unmodifiable(
          _assets.where(
            (a) => !gone.any((g) => g.isState == a.isState && g.id == a.id),
          ),
        );
      }
      return gone.length == assets.length
          ? RommDeleteOutcome.deleted
          : RommDeleteOutcome.failed;
    } finally {
      _browse.removeListener(watchConnection);
      _deleteState = _DeleteState.idle;
      if (!_disposed) {
        notifyListeners();
        if (_refreshAfterDelete) {
          _refreshAfterDelete = false;
          unawaited(refresh());
        }
      }
    }
  }

  /// Completes at this provider's next notification, or once it is disposed.
  Future<void> _nextChange() {
    final changed = _changed = Completer<void>();
    void done() {
      removeListener(done);
      if (!changed.isCompleted) changed.complete();
    }

    addListener(done);
    return changed.future;
  }

  /// Deletes [batch], all saves or all states as each has its own endpoint, in
  /// one request. Returns the files it deleted, and adds any the server
  /// answered 404 for to [notFound].
  Future<List<RommAsset>> _deleteBatch(
    List<RommAsset> batch,
    bool Function() sameConnection,
    List<RommAsset> notFound,
  ) async {
    // A connection change can reuse these IDs for unrelated files. Do not
    // send queued batches or 404 retries after the original session ends. The
    // service makes the same check again before every request it sends.
    if (!sameConnection()) return const [];
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
        gone.addAll(await _deleteBatch([asset], sameConnection, notFound));
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
  Future<List<RommAsset>> _unlisted(
    List<RommAsset> assets,
    bool Function() sameConnection,
  ) async {
    if (!sameConnection()) return const [];
    try {
      final listed = await _browse.service.listSaveAssets();
      return assets
          .where(
            (a) => !listed.any((l) => l.isState == a.isState && l.id == a.id),
          )
          .toList();
    } catch (_) {
      // Unconfirmed, so reported as a failed delete.
      return const [];
    }
  }

  @override
  void dispose() {
    _disposed = true;
    final changed = _changed;
    if (changed != null && !changed.isCompleted) changed.complete();
    _generation++;
    _browse.removeListener(_connectionChanged);
    _sweep?.removeListener(_sweepChanged);
    super.dispose();
  }
}
