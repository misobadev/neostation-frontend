part of '../neo_sync_provider.dart';

extension NeoSyncUpload on NeoSyncProvider {
  /// Auto-sync solo para subidas (archivos locales nuevos o modificados)
  Future<void> autoSyncUploads() async {
    if (!isNeoSyncAuthenticated) {
      return;
    }
    if (_isSyncing) return;

    _setSyncing(true);
    _error = null;
    _syncProgress = 0.0;
    _syncStatus = 'Auto-detecting local files...';
    _totalFiles = 0;
    _processedFiles = 0;
    _uploadedFiles = 0;
    _skippedFiles = 0;
    _downloadedFiles = 0;
    _processedItems = [];
    notify();

    try {
      // 1. Collect RetroArch files (Saves and States)
      final savesPath = await _getRetroArchSavesPath();
      List<File> retroArchSaves = [];
      if (savesPath != null) {
        retroArchSaves = await _getSaveFiles(savesPath);
      }

      final statesPath = await _getRetroArchStatesPath();
      List<File> retroArchStates = [];
      if (statesPath != null) {
        retroArchStates = await _getSaveFiles(statesPath);
      }

      // 2. Collect user-configured custom save folders (ARMSX2, ARMSX1, ...).
      // Standalone emulators — including Switch (Eden, Citron, Yuzu, ...) — are
      // ALWAYS synced through a custom folder, never auto-detected, so this is
      // the only source for standalone saves.
      final customFiles =
          <
            ({File file, String system, String emulatorSlug, String folderRoot})
          >[];
      try {
        final systems = await SystemRepository.getAllSystems();
        for (final system in systems) {
          final folders = await NeoSyncSaveFolderRepository.getFoldersForSystem(
            system.folderName,
          );
          for (final entry in folders.entries) {
            if (!Directory(entry.value).existsSync()) continue;
            final files = await _getSaveFiles(entry.value);
            for (final file in files) {
              customFiles.add((
                file: file,
                system: system.folderName,
                emulatorSlug: entry.key,
                folderRoot: entry.value,
              ));
            }
          }
        }
      } catch (e) {
        NeoSyncProvider._log.e('Error scanning custom save folders: $e');
      }

      _totalFiles =
          retroArchSaves.length + retroArchStates.length + customFiles.length;

      if (_totalFiles == 0) {
        _syncStatus = 'No local save files found';
        _processedItems.add('No local save files found for auto-sync');
        return;
      }

      _processedItems.add('Auto-syncing $_totalFiles local files...');
      _syncStatus = 'Checking files for upload...';
      notify();

      // Process RetroArch Saves (derive emulator slug from the core folder)
      for (final file in retroArchSaves) {
        await _processAutoUploadFile(
          file,
          savesPath!,
          isState: false,
          retroArchBasePath: savesPath,
        );
        _processedFiles++;
        _syncProgress = _totalFiles > 0 ? _processedFiles / _totalFiles : 0.0;
        notify();
      }

      // Process RetroArch States (derive emulator slug from the core folder)
      for (final file in retroArchStates) {
        await _processAutoUploadFile(
          file,
          statesPath!,
          isState: true,
          retroArchBasePath: statesPath,
        );
        _processedFiles++;
        _syncProgress = _totalFiles > 0 ? _processedFiles / _totalFiles : 0.0;
        notify();
      }

      // Process custom save folders using their emulator slug namespace.
      for (final entry in customFiles) {
        await _processAutoUploadFile(
          entry.file,
          entry.folderRoot,
          isState: false,
          customFolderSystem: entry.system,
          customFolderEmulatorSlug: entry.emulatorSlug,
        );
        _processedFiles++;
        _syncProgress = _totalFiles > 0 ? _processedFiles / _totalFiles : 0.0;
        notify();
      }

      _syncProgress = 1.0;
      _syncStatus =
          'Auto-upload completed: $_uploadedFiles uploaded, $_skippedFiles already synced';
      _processedItems.add(
        'Auto-upload completed: $_uploadedFiles uploaded, $_skippedFiles already synced',
      );
    } catch (e) {
      if (e is QuotaExceededException) {
        _error = 'Storage quota exceeded after ${e.attemptCount} attempts';
        _syncStatus = 'Quota exceeded - Auto-sync disabled';
        _processedItems.add('Storage quota exceeded - sync stopped');
      } else {
        _error = 'Error during auto-sync: $e';
        _syncStatus = 'Error: $_error';
        _processedItems.add('Auto-sync error: $e');
      }
    } finally {
      _setSyncing(false);
    }
  }

  /// Procesa un archivo para auto-subida (versión optimizada)
  Future<void> _processAutoUploadFile(
    File file,
    String basePath, {
    bool isState = false,
    String? customFolderSystem,
    String? customFolderEmulatorSlug,
    String? retroArchBasePath,
    List<NeoSyncFile>? cloudFiles,
  }) async {
    try {
      final String relativePath;
      String? syncSystemId;
      String? syncEmulatorId;
      String syncType = 'save';
      if (customFolderSystem != null && customFolderEmulatorSlug != null) {
        // The configured folder root is the basePath for the standalone folder,
        // so a nested layout (e.g. `memcards/slot1/Mcd001.ps2`) is preserved.
        // file_path keeps the real on-disk path; the backend builds the R2
        // object key as `user_id/v2/custom/<emulator>/<relative>` where
        // `<emulator>` is the emulator's unique id (e.g. `ps2.com.armsx2`).
        final relativeToFolder = path
            .relative(file.path, from: basePath)
            .replaceAll('\\', '/');
        relativePath = relativeToFolder;
        syncSystemId = customFolderSystem;
        syncEmulatorId = customFolderEmulatorSlug;
        syncType = 'custom';
      } else if (retroArchBasePath != null) {
        final fileName = path.basenameWithoutExtension(file.path);

        // Only sync RetroArch saves that belong to a game still in the local
        // library (the save base name matches a ROM) or that are shared memory
        // cards. Orphan saves left behind by removed games (e.g. a Naomi EEPROM
        // whose ROM is no longer on disk) must not be uploaded, otherwise the
        // auto-sync picks them up while scanning the whole saves folder.
        final isSharedCard = _syncTypeForFile(file, isState: false) == 'shared';
        syncType = _syncTypeForFile(file, isState: isState);
        final gameRow = await GameRepository.findRomForSaveName(fileName);
        if (gameRow == null && !isSharedCard) {
          _skippedFiles++;
          _processedItems.add(
            'Skipped save for a game not in your library: '
            '${path.basename(file.path)}',
          );
          return;
        }

        // RetroArch stores saves as <savesPath>/<core>/<game>.srm when per-core
        // subfolders are enabled, or flat as <savesPath>/<game>.srm otherwise.
        // Derive the emulator slug from the RetroArch core folder when present;
        // for flat saves only the game's own RetroArch core is trusted (never a
        // standalone emulator). When no core can be resolved the save is
        // skipped instead of being uploaded under `retroarch.unknown`.
        final emulatorSlug = await _resolveRetroArchEmulatorSlug(
          file,
          retroArchBasePath,
        );
        if (emulatorSlug == null) {
          NeoSyncProvider._log.w(
            'RA upload skipped for ${file.path}: no resolvable core',
          );
          _skippedFiles++;
          _processedItems.add(
            'Skipped RetroArch save (no core resolved): '
            '${path.basename(file.path)}',
          );
          return;
        }
        var system = await _systemFolderForRetroArchFile(
          file,
          retroArchBasePath,
        );
        // The emulator must actually be registered for the resolved system;
        // otherwise trust the emulator's own system (a save from a NES core can
        // never belong to cps1, no matter what the game metadata says).
        system = await _reconcileEmulatorSystem(system, emulatorSlug);
        if (system == null) {
          NeoSyncProvider._log.w(
            'RA upload skipped for ${file.path}: no system resolved '
            '(emulator $emulatorSlug)',
          );
          _skippedFiles++;
          _processedItems.add(
            'Skipped RetroArch save (no system resolved): '
            '${path.basename(file.path)}',
          );
          return;
        }
        NeoSyncProvider._log.i(
          'RA upload: ${file.path} -> system=$system emulator=$emulatorSlug',
        );
        // Store the save under the original RetroArch on-disk path relative to
        // the RetroArch save/state directory (e.g. `saves/FinalBurn Neo/fbneo/<file>`
        // or `states/Snes9x/<file>`), exactly like the v1 flow did. This keeps
        // the file name faithful to the real RetroArch layout (including the
        // MAME/FBNeo internal subfolder) so a download places it back where it
        // was written, instead of re-deriving the folder from the emulator slug.
        relativePath = _calculateRelativePath(
          file,
          retroArchBasePath,
          isState: isState,
        );
        syncSystemId = system;
        syncEmulatorId = emulatorSlug;
      } else {
        relativePath = _calculateRelativePath(file, basePath, isState: isState);
        syncType = isState ? 'state' : 'save';
      }
      final rawGameName = _extractGameNameFromPath(file.path);
      // The NeoSync backend hard-rejects an upload whose game_name is empty.
      // Guard against a basename that resolves to '' (e.g. a path ending in a
      // separator) so a custom-folder save is never silently dropped.
      final gameName = rawGameName.isEmpty ? 'Shared Save' : rawGameName;
      if (rawGameName.isEmpty) {
        NeoSyncProvider._log.w(
          'Upload: empty game_name for ${file.path}; using fallback '
          '"$gameName"',
        );
      }

      // Resolve the game hash (ra_hash) so the v2 upload carries the ROM hash.
      // The save base name usually matches the ROM name, so find the game by
      // prefix and use its hash.
      String? gameHash;
      String? romName;
      try {
        final fileName = path.basenameWithoutExtension(file.path);
        final row = await GameRepository.findRomForSaveName(fileName);
        if (row != null) {
          final game = _gameModelFromRomRow(row, fileName);
          romName = game.romname;
          gameHash = await _resolveGameHashForUpload(game);
        }
      } catch (e) {
        NeoSyncProvider._log.w(
          'Error resolving game hash for ${path.basename(file.path)}: $e',
        );
      }

      // Changed here and on another device since the last sync: the other
      // device's copy is kept beside it before this one is uploaded, as in a
      // game's own sync. Only where the cloud list was read ([cloudFiles],
      // the standalone-folder sync).
      String? cloudCopy;
      // The save's game may still be open in an emulator: only its launch
      // writes the save, and the server decides a newer copy by the file's
      // time, which the emulator moves when it writes its own copy back.
      final gameMayBeOpen = identical(
        _launchDeadlineFor(romName, syncSystemId),
        NeoSyncProvider._gameMayBeOpen,
      );
      var cloudNewer = false;
      if (cloudFiles != null) {
        final stat = await file.stat();
        final local = LocalSaveFile(
          filePath: file.path,
          fileName: path.basename(file.path),
          fileSize: stat.size,
          lastModified: stat.modified,
          gameName: gameName,
          isSynced: false,
          relativePath: relativePath,
        );
        // This file's entry: one under its emulator (or, for a memory card,
        // under one writing the same card format) over one under none
        // (uploaded before saves named one), then, of duplicates, the newest,
        // as a game's own sync takes the newest.
        NeoSyncFile? cloud;
        for (final candidate in cloudFiles) {
          if (!_cloudMatchesLocal(candidate, local)) continue;
          if (cloud == null) {
            cloud = candidate;
            continue;
          }
          final named = candidate.emulator != null;
          final bestNamed = cloud.emulator != null;
          if (named != bestNamed) {
            if (named) cloud = candidate;
          } else if ((candidate.fileModifiedAtTimestamp ?? 0) >
              (cloud.fileModifiedAtTimestamp ?? 0)) {
            cloud = candidate;
          }
        }
        if (cloud != null) {
          final comparison = await _compareWithCloud(local, cloud);
          cloudNewer = comparison.status == neo_sync.GameSyncStatus.cloudOnly;
          // A memory card every game of its system shares that this device
          // has never synced, and that isn't the same as the cloud's: a
          // game's own sync takes the cloud's card and keeps this one. Sent
          // from here, a blank card an emulator just created would replace
          // every other device's card.
          if (comparison.status != neo_sync.GameSyncStatus.upToDate &&
              isSharedMemoryCard(file.path) &&
              await _neverSynced(file.path)) {
            _leftForLaunchFiles++;
            _processedItems.add(
              "Left for the game's next launch: $relativePath (never synced "
              'here)',
            );
            return;
          }
          if (gameMayBeOpen && cloudNewer) {
            _savesLeftForLaunchFiles++;
            _processedItems.add(
              "Left for the game's next launch: $relativePath (the cloud "
              'copy is newer, and the game may still be open in an emulator)',
            );
            return;
          }
          if (comparison.bothChanged) {
            final kept = await _keepCloudCopy(local, cloud);
            if (!kept.ok) {
              _processedItems.add(
                "Not uploaded: $relativePath (the other device's copy could "
                'not be kept)',
              );
              return;
            }
            cloudCopy = kept.keptPath;
          }
        }
      }

      // A save the emulator wrote back over a launch's download, its record
      // reset to it so the next launch downloads the cloud copy again
      // ([rebaselineIgnoredDownload]): never sent from here, open game or not
      // (another game launched since, or a reboot), or the server would take
      // it as newer by its time. The next launch, or the game's own sync,
      // takes the cloud copy.
      if (await _resetForNextLaunch(file)) {
        _savesLeftForLaunchFiles++;
        _processedItems.add(
          "Left for the game's next launch: $relativePath (the emulator "
          'ignored the save its launch downloaded)',
        );
        return;
      }

      final result = await _neoSyncService.syncFile(
        file,
        gameName,
        customFilename: relativePath,
        systemId: syncSystemId,
        emulatorId: syncEmulatorId,
        gameHash: gameHash,
        isState: isState,
        scope: null,
        type: syncType,
        // As for a game's own upload: a newer cloud copy is only written while
        // no launch of the save's game, or on a system whose games share
        // memory cards (a PS2 or Dreamcast card), of that system, has gone
        // ahead, and, while that game may still be open in an emulator, only
        // by its launch.
        deadline: () => _launchDeadlineFor(romName, syncSystemId),
      );

      // One tidy, whether or not the upload went through, keeping both
      // copies this file just got: the other device's, and this device's
      // when the cloud's turned out newer.
      final keptLocal = result['keptLocalPath'];
      if (cloudCopy != null || keptLocal is String) {
        await tidyKeptCopies(
          file.path,
          sources: neoSyncKeptCopySources,
          justKept: {?cloudCopy, if (keptLocal is String) keptLocal},
        );
      }
      if (result['success']) {
        if (result['skipped'] == true) {
          _skippedFiles++;
          _processedItems.add('Already synced: $relativePath');
        } else {
          _uploadedFiles++;
          _processedItems.add('Auto-uploaded: $relativePath');
          _resetQuotaAttempts();
          if (cloudCopy != null) {
            reportKeptCloudCopy(
              gameName: gameName,
              savePath: file.path,
              backupPath: cloudCopy,
            );
          }
        }
        if (result['downloaded'] == true && keptLocal is String) {
          reportNewerCloudCopy(gameName: gameName, savePath: file.path);
        }
      } else if (result['abandoned'] == true &&
          identical(
            _launchDeadlineFor(romName, syncSystemId),
            NeoSyncProvider._gameMayBeOpen,
          )) {
        // Not a failure: the newer cloud copy waits for the game's launch.
        _savesLeftForLaunchFiles++;
        _processedItems.add(
          "Left for the game's next launch: $relativePath (the game may "
          'still be open in an emulator)',
        );
      } else {
        final errorMessage = result['message'] ?? '';
        _processedItems.add('Failed to upload: $relativePath - $errorMessage');
        if (_checkQuotaExceeded(errorMessage)) {
          throw QuotaExceededException(errorMessage, _quotaExceededAttempts);
        }
      }
    } catch (e) {
      if (e is! QuotaExceededException) {
        _processedItems.add('Error processing ${path.basename(file.path)}: $e');
      } else {
        rethrow;
      }
    }
  }

  /// Whether [file]'s record was reset by [rebaselineIgnoredDownload]: it
  /// holds the file's bytes with no cloud copy seen.
  Future<bool> _resetForNextLaunch(File file) async {
    try {
      final record = await _syncRecord(file.path);
      if (record == null || (record['cloud_updated_at'] as int? ?? -1) != 0) {
        return false;
      }
      final hash = _neoSyncService.calculateFileHash(await file.readAsBytes());
      return record['file_hash'] == hash;
    } on FileSystemException {
      return false;
    }
  }

  /// Uploads every file in a single configured custom save folder.
  ///
  /// Used right after the user selects a folder so its existing saves are
  /// backed up immediately, without waiting for the next global auto-sync.
  Future<CustomFolderUploadOutcome> syncCustomSaveFolder(
    String systemFolderName,
    String emulatorSlug,
  ) async {
    if (!isNeoSyncAuthenticated) return CustomFolderUploadOutcome.notSignedIn;
    if (_isSyncing) return CustomFolderUploadOutcome.busy;

    // Claimed before the first await, so two uploads started together can't
    // both get past the check above. Listeners hear about it once there is a
    // folder to upload.
    _isSyncing = true;
    // A Stop from before this upload started isn't meant for it; one pressed
    // from here on is.
    _customFolderUploadCancelled = false;
    final String? folder;
    try {
      folder = await NeoSyncSaveFolderRepository.getFolder(
        systemFolderName,
        emulatorSlug,
      );
    } catch (_) {
      _isSyncing = false;
      rethrow;
    }
    if (folder == null || folder.isEmpty || !Directory(folder).existsSync()) {
      _isSyncing = false;
      return CustomFolderUploadOutcome.noFolder;
    }
    // A save the emulator wrote back over a launch's download would read as
    // a change to upload: told apart first.
    try {
      await _checkLaunchDownloads();
    } catch (_) {
      _isSyncing = false;
      rethrow;
    }

    // Neither clears nor sets the provider-wide error: that error turns every
    // game's NeoSync mark red, and this upload's outcome is reported to its
    // caller instead (the folders view, or the bell for the automatic one).
    _setSyncing(true);
    _syncProgress = 0.0;
    _syncStatus = 'Uploading standalone save folder...';
    _totalFiles = 0;
    _processedFiles = 0;
    _uploadedFiles = 0;
    _skippedFiles = 0;
    _leftForLaunchFiles = 0;
    _savesLeftForLaunchFiles = 0;
    _downloadedFiles = 0;
    _processedItems = [];
    notify();

    try {
      final files = await _getSaveFiles(folder);
      _totalFiles = files.length;
      if (files.isEmpty) {
        _syncStatus = 'No save files found in the selected folder';
        _processedItems.add(_syncStatus);
        return CustomFolderUploadOutcome.empty;
      }

      // Each save is compared with its cloud copy, as a game's own sync does,
      // so one changed here and on another device keeps the other device's
      // copy before this one is uploaded. Without the list nothing is
      // uploaded on a guess.
      // As at a launch: another device may have uploaded seconds ago.
      _markCloudListStale(olderThan: NeoSyncProvider._cloudListLaunchMaxAge);
      final allCloudFiles = await _cloudFileList();
      if (allCloudFiles == null) {
        _syncStatus = 'Could not list the cloud saves: nothing uploaded';
        _processedItems.add(_syncStatus);
        return CustomFolderUploadOutcome.failed;
      }
      // This folder's saves in the cloud: kept as `custom` files under its
      // emulator (or, uploaded before saves named one, under none). A memory
      // card of an emulator writing the same card format is the same card:
      // the cloud keeps one card of a name whichever emulator sent it.
      final cloudFiles = [
        for (final cloud in allCloudFiles)
          if (!_isKeptCopyInCloud(cloud) &&
              cloud.type == 'custom' &&
              (cloud.emulator == null ||
                  cloud.emulator == emulatorSlug ||
                  (isSharedMemoryCard(cloud.filePath) &&
                      CloudPathBuilder.sameMemoryCardFormat(
                        cloud.emulator!,
                        emulatorSlug,
                      ))))
            cloud,
      ];

      _processedItems.add('Uploading $_totalFiles save files...');
      notify();

      for (final file in files) {
        if (_customFolderUploadCancelled) {
          _syncStatus =
              'Upload stopped: $_uploadedFiles uploaded, $_skippedFiles '
              'already synced';
          _processedItems.add(_syncStatus);
          return CustomFolderUploadOutcome.cancelled;
        }
        // A memory card every game of its system shares that a game's own
        // sync is working on is left to it, so the two never keep or write
        // the same card's copies at once. The folder sync doesn't claim cards
        // itself: a launch on the system then syncs the card too, and keeps
        // its deadline until that sync is done.
        if (isSharedMemoryCard(file.path) &&
            _sharedCardsInFlight.contains(file.path)) {
          _skippedFiles++;
          _processedItems.add(
            'Being synced by a game: ${path.basename(file.path)}',
          );
        } else {
          await _processAutoUploadFile(
            file,
            folder,
            isState: false,
            customFolderSystem: systemFolderName,
            customFolderEmulatorSlug: emulatorSlug,
            cloudFiles: cloudFiles,
          );
        }
        _processedFiles++;
        _syncProgress = _totalFiles > 0 ? _processedFiles / _totalFiles : 0.0;
        notify();
      }

      // A save that neither uploaded nor was already in sync failed.
      final failed =
          _processedFiles -
          _uploadedFiles -
          _skippedFiles -
          _leftForLaunchFiles -
          _savesLeftForLaunchFiles;
      _syncProgress = 1.0;
      _syncStatus =
          'Upload complete: $_uploadedFiles uploaded, $_skippedFiles already '
          'synced, ${_leftForLaunchFiles + _savesLeftForLaunchFiles} left for '
          'a launch, $failed failed';
      _processedItems.add(_syncStatus);
      return failed > 0
          ? CustomFolderUploadOutcome.failed
          : CustomFolderUploadOutcome.uploaded;
    } on QuotaExceededException catch (e) {
      final message = 'Error uploading standalone save folder: $e';
      _syncStatus = 'Error: $message';
      _processedItems.add(_syncStatus);
      NeoSyncProvider._log.e(message);
      return CustomFolderUploadOutcome.quotaExceeded;
    } catch (e) {
      final message = 'Error uploading standalone save folder: $e';
      _syncStatus = 'Error: $message';
      _processedItems.add(_syncStatus);
      NeoSyncProvider._log.e(message);
      return CustomFolderUploadOutcome.failed;
    } finally {
      _setSyncing(false);
    }
  }
}
