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
    FileProvider? fileProvider,
    Future<String?> Function(int)? loadLocalCover,
  }) : _files = fileProvider,
       _loadLocalCover = loadLocalCover {
    _browse.addListener(_connectionChanged);
  }

  final RommProvider _browse;
  final SyncManager _manager;
  final FileProvider? _files;
  final Future<String?> Function(int)? _loadLocalCover;
  final _metadataGate = LifoSemaphore(3);
  final Map<int, Future<RommSaveGameInfo>> _gameInfo = {};
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
  bool get syncing => _syncing;
  bool get deleting => _deleting;
  Object? get loadError => _loadError;
  SyncResult? get syncResult => _syncResult;

  /// Memoized and requested only for visible games. Missing art/metadata never
  /// prevents the inventory from loading, and a refresh retries failed lookups.
  Future<RommSaveGameInfo> gameInfo(int? romId) {
    if (romId == null || _disposed || !_browse.isConnected) {
      return Future.value(const RommSaveGameInfo());
    }
    return _gameInfo.putIfAbsent(
      romId,
      () => _readGameInfo(romId, _generation),
    );
  }

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
    _assets = [];
    _loading = false;
    _loadError = null;
    _syncResult = null;
    notifyListeners();
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
        _syncing ||
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
    if (!_disposed && generation == _generation) await refresh();
  }

  /// Permanently removes [asset] from the server. Local copies are untouched,
  /// so a device that still syncs the game uploads its copy again.
  Future<bool> delete(RommAsset asset) async {
    if (_disposed ||
        _loading ||
        _syncing ||
        _deleting ||
        !_browse.isConnected) {
      return false;
    }
    _deleting = true;
    notifyListeners();
    var deleted = false;
    try {
      final ids = [asset.id];
      await (asset.isState
          ? _browse.service.deleteStates(ids)
          : _browse.service.deleteSaves(ids));
      deleted = true;
    } on RommException catch (error) {
      // Already gone, e.g. deleted from another device: what the user asked for.
      deleted = error.statusCode == 404;
    } catch (_) {
      // Reported to the caller as a failed delete.
    }
    if (_disposed) return deleted;
    _deleting = false;
    // Drop it locally rather than refreshing, which would reload every game's
    // artwork. Saves and states are numbered independently, so match both.
    if (deleted) {
      _assets = _assets
          .where((a) => a.isState != asset.isState || a.id != asset.id)
          .toList();
    }
    notifyListeners();
    return deleted;
  }

  @override
  void dispose() {
    _disposed = true;
    _generation++;
    _browse.removeListener(_connectionChanged);
    super.dispose();
  }
}
