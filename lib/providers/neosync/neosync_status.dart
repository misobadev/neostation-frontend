part of '../neo_sync_provider.dart';

extension NeoSyncStatus on NeoSyncProvider {
  /// Loads the list of cloud files.
  ///
  /// A failure is only logged, like [loadQuota]'s: listing is not a sync, so it
  /// neither sets nor clears [error], which the games' NeoSync marks read as a
  /// failed sync. Nothing shows this load, so it leaves [isLoadingOnlineFiles]
  /// to the online save list's own loads.
  Future<bool> loadFiles() async {
    if (!isNeoSyncAuthenticated) return false;

    try {
      final account = _authService?.currentUser?.id;
      final generation = _filesGeneration;
      final removals = _filesRemovals;
      final result = await _neoSyncService.getAllFiles();

      if (result['success']) {
        // A list asked for before a save was deleted may still have it in, so
        // it's dropped; the trimmed one is kept.
        if (removals == _filesRemovals) {
          _files = result['files'];
          if (generation == _filesGeneration) {
            _filesFetchedAt = _now();
            _filesAccountId = account;
          }
        }
        notify();
        return true;
      } else {
        NeoSyncProvider._log.e('Failed to load files: ${result['message']}');
        return false;
      }
    } catch (e) {
      NeoSyncProvider._log.e('Error loading files: $e');
      return false;
    }
  }

  /// Loads the quota information
  Future<bool> loadQuota() async {
    if (!isNeoSyncAuthenticated) return false;

    try {
      final result = await _neoSyncService.getQuota();

      if (result['success']) {
        _quota = result['quota'];
        notify();
        return true;
      } else {
        NeoSyncProvider._log.e('Failed to load quota: ${result['message']}');
        return false;
      }
    } catch (e) {
      NeoSyncProvider._log.e('Error loading quota: $e');
      return false;
    }
  }

  /// Deletes a file
  Future<bool> deleteFile(NeoSyncFile file) async {
    if (!isNeoSyncAuthenticated) return false;

    try {
      final result = await _neoSyncService.deleteFile(file.id);

      if (result['success']) {
        // Remove from local list for immediate response
        _files.removeWhere((f) => f.id == file.id);
        notify();
        return true;
      } else {
        return false;
      }
    } catch (e) {
      return false;
    }
  }

  /// Loads the online file page described by the current filter and page.
  ///
  /// Returns false only when this load failed (recorded in
  /// [onlineFilesLoadFailed]); a load overtaken by a newer one reports no
  /// failure.
  Future<bool> loadOnlineFiles() async {
    _isLoadingOnlineFiles = true;
    _onlineFilesLoadFailed = false;
    notify();

    final generation = ++_onlineLoadGeneration;

    try {
      final result = await _neoSyncService.getFiles(
        filter: _onlineFilter.copyWith(
          limit: NeoSyncProvider._onlinePageSize,
          offset: (_onlinePage - 1) * NeoSyncProvider._onlinePageSize,
        ),
      );
      if (generation != _onlineLoadGeneration) return true;
      if (result['success']) {
        _onlineFiles = result['files'] as List<NeoSyncFile>;
        _onlineTotal = result['total'] as int;
        _onlineCounts = result['counts'] as Map<String, dynamic>?;
        _onlineSystems =
            (result['systems'] as List<dynamic>?)
                ?.map((e) => e.toString())
                .toList() ??
            const <String>[];
        _onlineEmulators =
            (result['emulators'] as List<dynamic>?)
                ?.map((e) => e.toString())
                .toList() ??
            const <String>[];
        return true;
      } else {
        NeoSyncProvider._log.e(
          'Failed to load online files: ${result['message']}',
        );
        _onlineFiles = [];
        _onlineTotal = 0;
        _onlineFilesLoadFailed = true;
        return false;
      }
    } catch (e) {
      if (generation != _onlineLoadGeneration) return true;
      NeoSyncProvider._log.e('Error loading online files: $e');
      _onlineFiles = [];
      _onlineTotal = 0;
      _onlineFilesLoadFailed = true;
      return false;
    } finally {
      if (generation == _onlineLoadGeneration) {
        _isLoadingOnlineFiles = false;
        notify();
      }
    }
  }

  /// Applies a new filter and reloads from the first page.
  Future<void> setOnlineFilter(NeoSyncFileFilter filter) async {
    _onlineFilter = filter;
    _onlinePage = 1;
    await loadOnlineFiles();
  }

  /// Clears every dimension of the online filter.
  Future<void> clearOnlineFilter() async {
    await setOnlineFilter(
      const NeoSyncFileFilter(sort: 'modified', dir: 'desc'),
    );
  }

  /// Navigates to [page] (clamped), keeping the current filter.
  Future<void> goOnlinePage(int page) async {
    final target = page < 1
        ? 1
        : (page > onlineTotalPages ? onlineTotalPages : page);
    if (target == _onlinePage) return;
    _onlinePage = target;
    await loadOnlineFiles();
  }

  Future<void> nextOnlinePage() => goOnlinePage(_onlinePage + 1);

  Future<void> previousOnlinePage() => goOnlinePage(_onlinePage - 1);

  /// Deletes an online file (used in NeoSyncContent)
  Future<bool> deleteOnlineFile(String fileId) async {
    try {
      final result = await _neoSyncService.deleteFile(fileId);
      if (result['success']) {
        // Remove the file from the local lists
        _onlineFiles.removeWhere((file) => file.id == fileId);
        _files = _files.where((file) => file.id != fileId).toList();
        // A listing under way may still have the file in it.
        _filesRemovals++;
        _markCloudListStale();
        if (_onlineTotal > 0) _onlineTotal -= 1;
        // Step back a page when the last item of the last page was removed.
        if (_onlineFiles.isEmpty && _onlinePage > 1) {
          _onlinePage -= 1;
          notify();
          await loadOnlineFiles();
        } else {
          notify();
        }
        return true;
      } else {
        NeoSyncProvider._log.e(
          'Failed to delete online file: ${result['message']}',
        );
        return false;
      }
    } catch (e) {
      NeoSyncProvider._log.e('Error deleting online file: $e');
      return false;
    }
  }
}
