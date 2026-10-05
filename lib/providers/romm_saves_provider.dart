import 'package:flutter/foundation.dart';

import '../models/romm_asset.dart';
import '../models/sync_models.dart';
import '../sync/providers/romm_provider.dart';
import '../sync/sync_manager.dart';
import 'romm_provider.dart';

/// Remote inventory state for the Saves tab. Merely browsing never syncs files.
class RommSavesProvider extends ChangeNotifier {
  RommSavesProvider(this._browse, this._manager) {
    _browse.addListener(_connectionChanged);
  }

  final RommProvider _browse;
  final SyncManager _manager;
  List<RommAsset> _assets = [];
  bool _loading = false;
  bool _syncing = false;
  bool _disposed = false;
  int _generation = 0;
  Object? _loadError;
  SyncResult? _syncResult;

  List<RommAsset> get assets => List.unmodifiable(_assets);
  bool get loading => _loading;
  bool get syncing => _syncing;
  Object? get loadError => _loadError;
  SyncResult? get syncResult => _syncResult;

  void _connectionChanged() {
    if (_browse.isConnected) return;
    _generation++;
    _assets = [];
    _loading = false;
    _loadError = null;
    _syncResult = null;
    notifyListeners();
  }

  Future<void> refresh() async {
    if (_disposed || !_browse.isConnected) return;
    final generation = ++_generation;
    _loading = true;
    _loadError = null;
    notifyListeners();
    try {
      final assets = await _browse.service.listSaveAssets();
      if (_disposed || generation != _generation) return;
      assets.sort((a, b) {
        final order = b.updatedAtMs.compareTo(a.updatedAtMs);
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

  @override
  void dispose() {
    _disposed = true;
    _generation++;
    _browse.removeListener(_connectionChanged);
    super.dispose();
  }
}
