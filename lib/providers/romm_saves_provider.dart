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
  List<RommAsset> _assets = [];
  bool _loading = false;
  bool _syncing = false;
  bool _deleting = false;
  bool _disposed = false;
  int _generation = 0;
  Object? _loadError;
  SyncResult? _syncResult;

  List<RommAsset> get assets => List.unmodifiable(_assets);
  bool get loading => _loading;

  /// True during a retry, and during a sweep this provider did not start, such
  /// as the automatic one after connect, since a retry would only overlap it.
  bool get syncing => _syncing || _sweep?.value != null;
  bool get deleting => _deleting;
  Object? get loadError => _loadError;
  SyncResult? get syncResult => _syncResult;

  /// Memoized and requested only for visible games. Missing art/metadata never
  /// prevents the inventory from loading, and a refresh retries failed lookups.
  Future<RommSaveGameInfo> gameInfo(int? romId) {
    if (romId == null || _disposed || !_browse.isConnected) {
      return Future.value(const RommSaveGameInfo());
    }
    final generation = _generation;
    return _gameInfo.putIfAbsent(
      romId,
      () => _readGameInfo(romId, generation).then((info) {
        if (generation == _generation) _loadedInfo[romId] = info;
        return info;
      }),
    );
  }

  /// What [gameInfo] has already resolved for [romId], or null while it is
  /// pending, so a newly built tile can show it in its first frame.
  RommSaveGameInfo? loadedGameInfo(int? romId) =>
      romId == null ? const RommSaveGameInfo() : _loadedInfo[romId];

  Future<RommSaveGameInfo> _readGameInfo(int romId, int generation) async {
    await _metadataGate.acquire();
    try {
      if (_disposed || generation != _generation) {
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
      if (_disposed || generation != _generation) {
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
    _generation++;
    _gameInfo.clear();
    _loadedInfo.clear();
    _assets = [];
    _loading = false;
    _loadError = null;
    _syncResult = null;
    notifyListeners();
  }

  /// A sweep started elsewhere shows here as a retry would: busy while it
  /// runs, then its result and a refresh so its uploads appear. A retry's own
  /// sweep is left to [retryUploads], which already does both.
  void _sweepChanged() {
    if (_disposed || _syncing) return;
    notifyListeners();
    final running = _sweep!.value;
    if (running != null) _followSweep(running);
  }

  Future<void> _followSweep(Future<SyncResult> sweep) async {
    SyncResult result;
    try {
      result = await sweep;
    } catch (_) {
      result = SyncResult.fail(SyncError.unknown);
    }
    // A disconnect has already cleared this session's state.
    if (_disposed || !_browse.isConnected) return;
    _syncResult = result;
    notifyListeners();
    // A refresh would make an in-flight delete abandon its remaining batches
    // and report failure; the next refresh shows the uploads instead.
    if (!_deleting) await refresh();
  }

  Future<void> refresh() async {
    if (_disposed || !_browse.isConnected) return;
    final generation = ++_generation;
    _gameInfo.clear();
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
      _assets = assets;
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
        !_browse.isConnected ||
        sync?.providerId != RomMSyncProvider.kProviderId) {
      return;
    }
    final generation = _generation;
    _syncing = true;
    _syncResult = null;
    notifyListeners();
    try {
      final result = await sync!.fullSync();
      if (_disposed || generation != _generation) return;
      _syncResult = result;
    } catch (_) {
      if (_disposed || generation != _generation) return;
      _syncResult = SyncResult.fail(SyncError.unknown);
    } finally {
      _syncing = false;
      if (!_disposed) notifyListeners();
    }
    // A busy result means another sweep (the automatic one after connect) is
    // still uploading, so a refresh now would miss its files and reload every
    // game's artwork for nothing. [_followSweep] takes its result and
    // refreshes when it ends.
    if (!_disposed &&
        generation == _generation &&
        _syncResult?.error != SyncError.busy) {
      await refresh();
    }
  }

  /// Permanently removes [assets] from the server. Local copies are untouched,
  /// so a device that still syncs the game uploads its copies again.
  ///
  /// Returns whether all of them are gone. Any that are leave the list even
  /// when others could not be deleted.
  Future<bool> delete(List<RommAsset> assets) async {
    if (_disposed ||
        assets.isEmpty ||
        _loading ||
        syncing ||
        _deleting ||
        !_browse.isConnected) {
      return false;
    }
    final generation = _generation;
    _deleting = true;
    notifyListeners();
    final gone = <RommAsset>[];
    for (final isState in [false, true]) {
      final batch = assets.where((a) => a.isState == isState).toList();
      if (batch.isNotEmpty) {
        gone.addAll(await _deleteBatch(batch, generation));
      }
    }
    if (_disposed) return false;
    _deleting = false;
    if (generation != _generation) {
      notifyListeners();
      return false;
    }
    // Drop them locally rather than refreshing, which would reload every
    // game's artwork. Saves and states are numbered independently, so match
    // both.
    _assets = _assets
        .where((a) => !gone.any((g) => g.isState == a.isState && g.id == a.id))
        .toList();
    notifyListeners();
    return gone.length == assets.length;
  }

  /// Deletes [batch], all saves or all states as each has its own endpoint, in
  /// one request. Returns the files no longer on the server.
  Future<List<RommAsset>> _deleteBatch(
    List<RommAsset> batch,
    int generation,
  ) async {
    // A connection change can reuse these IDs for unrelated files. Do not
    // send queued batches or 404 retries after the original session ends.
    if (_disposed || generation != _generation || !_browse.isConnected) {
      return const [];
    }
    final ids = [for (final asset in batch) asset.id];
    try {
      await (batch.first.isState
          ? _browse.service.deleteStates(ids)
          : _browse.service.deleteSaves(ids));
      return batch;
    } on RommException catch (error) {
      if (error.statusCode != 404) return const [];
      // Already gone, e.g. deleted from another device: what the user asked
      // for. RomM stops a batch with a 404 at the first file it no longer has,
      // keeping the rest, so a batch goes again a file at a time to finish.
      if (batch.length == 1) return batch;
      final gone = <RommAsset>[];
      for (final asset in batch) {
        gone.addAll(await _deleteBatch([asset], generation));
      }
      return gone;
    } catch (_) {
      // Reported to the caller as a failed delete.
      return const [];
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _generation++;
    _browse.removeListener(_connectionChanged);
    _sweep?.removeListener(_sweepChanged);
    super.dispose();
  }
}
