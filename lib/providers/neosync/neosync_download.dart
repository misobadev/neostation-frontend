part of '../neo_sync_provider.dart';

extension NeoSyncDownload on NeoSyncProvider {
  /// Auto-sync para descargas (archivos de la nube que no están localmente o son más nuevos)
  Future<void> autoSyncDownloads() async {
    if (!isNeoSyncAuthenticated) {
      return;
    }
    if (_isSyncing) return;

    _setSyncing(true);
    _error = null;
    _syncProgress = 0.0;
    _syncStatus = 'Fetching cloud files...';
    _totalFiles = 0;
    _processedFiles = 0;
    _downloadedFiles = 0;
    _processedItems = [];
    notify();

    try {
      final result = await _neoSyncService.getAllFiles();
      if (!result['success']) {
        throw Exception('Failed to fetch cloud files: ${result['message']}');
      }

      final cloudFiles = _dedupeCloudFiles(
        result['files'] as List<NeoSyncFile>,
      );
      if (cloudFiles.isEmpty) {
        _syncStatus = 'No cloud files found';
        _processedItems.add('No cloud files found for auto-sync');
        _setSyncing(false);
        return;
      }

      _totalFiles = cloudFiles.length;
      _processedItems.add('Auto-syncing $_totalFiles cloud files...');
      _syncStatus = 'Checking cloud files...';
      notify();

      // Collect RetroArch folders to resolve locally
      final savesPath = await _getRetroArchSavesPath();

      for (final cloudFile in cloudFiles) {
        await _processAutoDownloadFile(cloudFile, savesPath ?? '');
        _processedFiles++;
        _syncProgress = _totalFiles > 0 ? _processedFiles / _totalFiles : 0.0;
        notify();
      }

      _syncProgress = 1.0;
      _syncStatus =
          'Auto-download completed: $_downloadedFiles files downloaded';
      _processedItems.add(
        'Auto-download completed: $_downloadedFiles files downloaded',
      );
    } catch (e) {
      _error = 'Error during auto-sync download: $e';
      _syncStatus = 'Error: $_error';
      _processedItems.add('Auto-sync download error: $e');
      NeoSyncProvider._log.e('Auto-sync downloads error: $e');
    } finally {
      _setSyncing(false);
    }
  }

  /// Fase 2: Descargar archivos de la nube
  Future<void> _performDownloadPhase(String savesPath) async {
    _syncStatus = 'Phase 2: Downloading cloud files...';
    _processedItems.add('Phase 2: Downloading files from cloud...');
    notify();

    final result = await _neoSyncService.getAllFiles();
    if (!result['success']) {
      throw Exception('Failed to fetch cloud files: ${result['message']}');
    }

    final cloudFiles = _dedupeCloudFiles(result['files'] as List<NeoSyncFile>);
    if (cloudFiles.isEmpty) {
      _processedItems.add('No cloud files found');
      return;
    }

    _processedItems.add('Found ${cloudFiles.length} cloud files to process');

    for (final cloudFile in cloudFiles) {
      await _processDownloadFileWithConflictDetection(cloudFile, savesPath);
      _processedFiles++;
      _syncProgress = _totalFiles > 0 ? _processedFiles / _totalFiles : 0.0;
      notify();
    }
  }

  /// Procesa un archivo para auto-descarga (Universal)
  Future<void> _processAutoDownloadFile(
    NeoSyncFile cloudFile,
    String savesPath,
  ) async {
    try {
      // Standalone and shared memory cards carry their system + emulator in the
      // metadata (not in the on-disk path), so they route straight to the
      // configured custom folder without needing a game match. This works the
      // same on every OS because it never parses a platform-specific path.
      if (cloudFile.type == 'shared' || cloudFile.type == 'custom') {
        await _downloadSharedCloudFile(cloudFile);
        return;
      }

      // 1. Resolve the game associated with the file
      GameModel? game = await _findGameForCloudFile(cloudFile);

      if (game == null) {
        NeoSyncProvider._log.w(
          'Download: no game matched ${cloudFile.fileName} '
          '(system "${cloudFile.systemName ?? '?'}" / "${cloudFile.gameName}")',
        );
        _processedItems.add(
          'No game matched cloud file: ${cloudFile.fileName}',
        );
        return;
      }

      // 2. Resolve local path using the universal system
      final localPaths = await resolveCloudFileToLocalPath(game, cloudFile);

      if (localPaths.isEmpty) {
        NeoSyncProvider._log.w(
          'Download: no local path resolved for ${cloudFile.fileName} '
          '(game "${game.name}")',
        );
        _processedItems.add(
          'No destination for ${cloudFile.fileName} (${game.name})',
        );
        return;
      }

      for (final localPath in localPaths) {
        final localFile = File(localPath);
        if (localFile.existsSync()) {
          if (await _shouldDownloadOverLocal(cloudFile, localFile)) {
            await _downloadCloudFileImpl(cloudFile, localFile);
            _downloadedFiles++;
            _processedItems.add('Auto-updated: ${cloudFile.fileName}');
          } else {
            NeoSyncProvider._log.i(
              'Download: keeping local ${cloudFile.fileName} '
              '(local is newer or changed since last sync)',
            );
            _skippedFiles++;
          }
        } else {
          await localFile.parent.create(recursive: true);
          await _downloadCloudFileImpl(cloudFile, localFile);
          _downloadedFiles++;
          _processedItems.add('Auto-downloaded new: ${cloudFile.fileName}');
        }
      }
    } catch (e) {
      NeoSyncProvider._log.e(
        'Download: error processing ${cloudFile.fileName}: $e',
      );
      _processedItems.add('Error downloading ${cloudFile.fileName}: $e');
    }
  }

  /// Helper para encontrar el juego de un archivo de nube
  Future<GameModel?> _findGameForCloudFile(NeoSyncFile cloudFile) async {
    final parts = cloudFile.fileName.split('/');

    // Switch saves are stored under `eden/<game>/<file>` (or the legacy
    // `saves/eden/<game>/<file>`). Detect the emulator prefix and take the game
    // name that follows it.
    const switchEmulators = {
      'switch',
      'eden',
      'citron',
      'yuzu',
      'suyu',
      'sudachi',
    };
    final hasLegacyRoot =
        parts.isNotEmpty && (parts.first == 'saves' || parts.first == 'states');
    final emulatorIndex = hasLegacyRoot ? 1 : 0;
    final gameIndex = emulatorIndex + 1;

    if (parts.length > gameIndex &&
        switchEmulators.contains(parts[emulatorIndex])) {
      final gameNameInPath = parts[gameIndex];
      try {
        final row = await GameRepository.findSwitchGameByName(gameNameInPath);
        if (row != null) {
          final romname = row['filename'].toString();
          final title = row['title_name']?.toString();
          final titleId = row['title_id']?.toString();
          final romPath = row['rom_path']?.toString();

          return GameModel(
            name: title ?? romname,
            realname: title ?? romname,
            romname: romname,
            romPath: romPath,
            titleName: title,
            systemFolderName: 'switch',
            systemId: 'switch',
            year: '',
            developer: '',
            publisher: '',
            genre: '',
            players: '',
            rating: 0.0,
          ).copyWith(titleId: titleId);
        }
      } catch (e) {
        NeoSyncProvider._log.e('Error finding Switch game by name: $e');
      }
    }

    {
      final name = path.basenameWithoutExtension(cloudFile.fileName);
      // Attempt to search in DB
      try {
        final row = await GameRepository.findRomByFilenamePrefix(name);
        if (row != null) {
          final romname = row['filename'].toString();
          final title = row['title_name']?.toString();
          final sysFolder = row['folder_name']?.toString() ?? '';

          return GameModel(
            name: title ?? romname,
            realname: title ?? romname,
            romname: romname,
            systemFolderName: sysFolder,
            year: '',
            developer: '',
            publisher: '',
            genre: '',
            players: '',
            rating: 0.0,
          );
        }
      } catch (e) {
        NeoSyncProvider._log.e('Error finding game for file: $e');
      }
    }
    return null;
  }

  /// Descarga un archivo de la nube
  Future<void> _downloadCloudFileImpl(
    NeoSyncFile cloudFile,
    File localFile,
  ) async {
    NeoSyncProvider._log.i(
      'Download: starting ${cloudFile.fileName} -> ${localFile.path}',
    );
    final result = await _neoSyncService.downloadFile(cloudFile.id);
    if (result['success'] == true && result['data'] != null) {
      final bytes = result['data'] as List<int>;
      try {
        await localFile.parent.create(recursive: true);
        await _backupLocalFile(localFile);
        await localFile.writeAsBytes(bytes, flush: true);
        NeoSyncProvider._log.i(
          'Download: OK ${bytes.length} bytes -> ${localFile.path}',
        );
      } on FileSystemException catch (e) {
        NeoSyncProvider._log.e(
          'Download: WRITE FAILED for ${localFile.path}: '
          '${e.osError?.message ?? e.message} (errno ${e.osError?.errorCode})',
        );
        _processedItems.add(
          'Write failed on ${localFile.path}: '
          '${e.osError?.message ?? e.message}',
        );
        rethrow;
      } catch (e) {
        NeoSyncProvider._log.e(
          'Download: write to ${localFile.path} errored: $e',
        );
        rethrow;
      }

      // Save the actual local sync state in the database.
      // This avoids the "Operation not permitted" error on Android 11+ when trying
      // to change the timestamp with setLastModified.
      try {
        final stat = await localFile.stat();
        await SyncRepository.saveSyncState(
          NeoSyncProvider.kSyncProviderId,
          localFile.path,
          stat.modified.millisecondsSinceEpoch,
          cloudFile.fileModifiedAtTimestamp ?? 0,
          stat.size,
          fileHash: cloudFile.checksum,
        );
      } catch (e) {
        NeoSyncProvider._log.w(
          'Download: could not save sync state for ${localFile.path}: $e',
        );
      }
    } else {
      final reason = result['message'] ?? 'Unknown download failure';
      final statusCode = result['status_code'];
      NeoSyncProvider._log.e(
        'Download: FAILED for ${cloudFile.fileName} -> ${localFile.path}: '
        '$reason (status ${statusCode ?? 'n/a'})',
      );
      _processedItems.add('Download failed: ${cloudFile.fileName} - $reason');
      throw Exception(reason);
    }
  }

  /// Procesa descarga con detección de conflictos
  Future<void> _processDownloadFileWithConflictDetection(
    NeoSyncFile cloudFile,
    String savesPath,
  ) async {
    if (cloudFile.type == 'shared' || cloudFile.type == 'custom') {
      await _downloadSharedCloudFile(cloudFile);
      return;
    }

    GameModel? game = await _findGameForCloudFile(cloudFile);
    if (game == null) {
      NeoSyncProvider._log.w(
        'Download: conflict phase, no game for ${cloudFile.fileName}; skipping',
      );
      return;
    }

    final localPaths = await resolveCloudFileToLocalPath(game, cloudFile);

    if (localPaths.isEmpty) {
      NeoSyncProvider._log.w(
        'Download: conflict phase, no path for ${cloudFile.fileName} '
        '(${game.name}); skipping',
      );
      return;
    }

    for (final localPath in localPaths) {
      final localFile = File(localPath);
      if (localFile.existsSync()) {
        if (await _shouldDownloadOverLocal(cloudFile, localFile)) {
          await _downloadCloudFileImpl(cloudFile, localFile);
          _downloadedFiles++;
          _processedItems.add('Updated: ${cloudFile.fileName}');
        } else {
          NeoSyncProvider._log.i(
            'Download: keeping local ${cloudFile.fileName} '
            '(local is newer or changed since last sync)',
          );
          _skippedFiles++;
        }
      } else {
        await localFile.parent.create(recursive: true);
        await _downloadCloudFileImpl(cloudFile, localFile);
        _downloadedFiles++;
        _processedItems.add('Downloaded: ${cloudFile.fileName}');
      }
    }
  }

  /// Downloads a standalone/shared cloud file (PS2 memcard, Dreamcast VMU, ...)
  /// into its configured custom save folder.
  ///
  /// The system + emulator come from the file metadata, so no game lookup is
  /// needed and the same logic applies on Android, Windows, Linux and macOS.
  /// Returns true when the file was placed; false when no custom folder is
  /// configured for that system+emulator.
  Future<bool> _downloadSharedCloudFile(NeoSyncFile cloudFile) async {
    final systemFolder = cloudFile.systemName ?? '';
    final emulatorSlug = cloudFile.emulator ?? '';
    if (emulatorSlug.isEmpty) {
      NeoSyncProvider._log.w(
        'Download: shared ${cloudFile.fileName} skipped: no emulator metadata',
      );
      _skippedFiles++;
      _processedItems.add(
        'Skipped cloud file (no emulator): ${cloudFile.fileName}',
      );
      return false;
    }

    final customFolder = await NeoSyncSaveFolderRepository.getFolder(
      systemFolder,
      emulatorSlug,
    );
    if (customFolder == null || customFolder.isEmpty) {
      NeoSyncProvider._log.w(
        'Download: shared ${cloudFile.fileName} skipped: no custom save '
        'folder for system=$systemFolder emulator=$emulatorSlug',
      );
      _skippedFiles++;
      _processedItems.add(
        'Skipped cloud file (no standalone folder): ${cloudFile.fileName}',
      );
      return false;
    }

    var rel = cloudFile.filePath.isNotEmpty
        ? cloudFile.filePath
        : cloudFile.fileName;
    // Strip any residual cloud namespace so only the on-disk relative path
    // remains (handles legacy rows that stored the full v2/custom path).
    final m = RegExp(r'^v2/custom/[^/]+/(.+)$').firstMatch(rel);
    if (m != null) rel = m.group(1)!;

    final localFile = File(path.join(customFolder, rel));
    await localFile.parent.create(recursive: true);
    if (!localFile.existsSync() ||
        await _shouldDownloadOverLocal(cloudFile, localFile)) {
      await _downloadCloudFileImpl(cloudFile, localFile);
      _downloadedFiles++;
      _processedItems.add('Standalone save: ${cloudFile.fileName}');
    } else {
      NeoSyncProvider._log.i(
        'Download: shared already current ${cloudFile.fileName}',
      );
      _skippedFiles++;
    }
    return true;
  }

  /// Whether the cloud copy should overwrite [localFile].
  ///
  /// Prefers the local copy on conflict so gameplay progress is never lost, and
  /// uses the content modification time (`fileModifiedAtTimestamp`) instead of
  /// the upload time (`createdAt`), so a save uploaded later from another device
  /// with older content can never roll the local save back.
  Future<bool> _shouldDownloadOverLocal(
    NeoSyncFile cloudFile,
    File localFile,
  ) async {
    final localStat = await localFile.stat();
    final localTime = localStat.modified.millisecondsSinceEpoch;
    final cloudTime =
        cloudFile.fileModifiedAtTimestamp ??
        cloudFile.uploadedAt.millisecondsSinceEpoch;

    // Identical content: nothing to do.
    try {
      final localBytes = await localFile.readAsBytes();
      final localHash = _neoSyncService.calculateFileHash(localBytes);
      if (cloudFile.checksum != null &&
          cloudFile.checksum!.isNotEmpty &&
          cloudFile.checksum == localHash) {
        return false;
      }
    } catch (e) {
      NeoSyncProvider._log.w('Download: could not hash ${localFile.path}: $e');
    }

    final syncState = await SyncRepository.getSyncState(
      NeoSyncProvider.kSyncProviderId,
      localFile.path,
    );

    if (syncState != null) {
      final savedLocalTime = syncState['local_modified_at'] as int? ?? 0;
      final savedCloudTime = syncState['cloud_updated_at'] as int? ?? 0;
      const toleranceMs = 2000;
      final localChanged = (localTime - savedLocalTime).abs() > toleranceMs;
      final cloudChanged = cloudTime > savedCloudTime;

      if (localChanged) {
        // The local file was edited since the last sync: prefer local.
        NeoSyncProvider._log.i(
          'Download: local changed since last sync for ${localFile.path}; '
          'keeping local',
        );
        return false;
      }
      if (cloudChanged) return true;
      return cloudTime > localTime;
    }

    // No recorded state: only take the cloud copy when its content is newer.
    return cloudTime > localTime;
  }

  /// Collapses cloud rows that represent the same logical save (same on-disk
  /// path + kind, case-insensitive) keeping the one with the newest content.
  ///
  /// Legacy duplicate rows (from the unstable cloud namespace) must never make
  /// the client pick an older version just because it was uploaded later.
  List<NeoSyncFile> _dedupeCloudFiles(List<NeoSyncFile> files) =>
      CloudPathBuilder.dedupeCloudFiles(files);
}
