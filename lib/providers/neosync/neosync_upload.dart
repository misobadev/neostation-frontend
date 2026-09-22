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
      final saveFiles = <File>[];

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

      // 2. Collect Switch NAND files
      try {
        final emulators = await SwitchSaveDetector.detectEmulatorNandPaths();
        if (Platform.isAndroid) {
          // On Android, group by Title ID and take only the most recent
          final Map<String, List<MapEntry<File, String>>> savesByTitleId = {};

          for (final emulator in emulators) {
            final nandPath = emulator.nandDirectory;
            final savePath =
                '$nandPath${Platform.pathSeparator}user${Platform.pathSeparator}save${Platform.pathSeparator}0000000000000000';
            final saveDir = Directory(savePath);

            if (!await saveDir.exists()) {
              NeoSyncProvider._log.w(
                'Switch save dir not found for ${emulator.emulatorName}: $savePath',
              );
            }

            if (await saveDir.exists()) {
              NeoSyncProvider._log.d(
                'Scanning Switch saves for ${emulator.emulatorName}: $savePath',
              );
              final switchFiles = saveDir
                  .listSync(recursive: true)
                  .whereType<File>()
                  .where((f) => !f.path.endsWith('.') && !f.path.endsWith('..'))
                  .where((f) => !f.path.toLowerCase().endsWith('.neosync.bak'))
                  .toList();

              for (final file in switchFiles) {
                try {
                  final pathParts = file.path.split(Platform.pathSeparator);
                  final saveIndex = pathParts.indexOf('save');
                  if (saveIndex != -1 && saveIndex + 3 < pathParts.length) {
                    final titleId = pathParts[saveIndex + 3];
                    final relativePath = pathParts
                        .sublist(saveIndex + 4)
                        .join(Platform.pathSeparator);
                    final key = '$titleId/$relativePath';

                    if (!savesByTitleId.containsKey(key)) {
                      savesByTitleId[key] = [];
                    }
                    savesByTitleId[key]!.add(
                      MapEntry(file, emulator.emulatorName),
                    );
                  }
                } catch (e) {
                  saveFiles.add(file);
                }
              }
            }
          }

          for (final entry in savesByTitleId.entries) {
            final files = entry.value;
            if (files.length == 1) {
              saveFiles.add(files.first.key);
            } else {
              File? mostRecent;
              DateTime? mostRecentDate;
              for (final fileEntry in files) {
                final file = fileEntry.key;
                final lastModified = await file.lastModified();
                if (mostRecent == null ||
                    lastModified.isAfter(mostRecentDate!)) {
                  mostRecent = file;
                  mostRecentDate = lastModified;
                }
              }
              if (mostRecent != null) saveFiles.add(mostRecent);
            }
          }
        } else {
          // Desktop Switch saves
          for (final emulator in emulators) {
            final nandPath = emulator.nandDirectory;
            final savePath =
                '$nandPath${Platform.pathSeparator}user${Platform.pathSeparator}save${Platform.pathSeparator}0000000000000000';
            final saveDir = Directory(savePath);
            if (await saveDir.exists()) {
              final switchFiles = saveDir
                  .listSync(recursive: true)
                  .whereType<File>()
                  .where((f) => !f.path.endsWith('.') && !f.path.endsWith('..'))
                  .where((f) => !f.path.toLowerCase().endsWith('.neosync.bak'))
                  .toList();
              saveFiles.addAll(switchFiles);
            }
          }
        }
      } catch (e) {
        NeoSyncProvider._log.e('Error scanning Switch NAND saves: $e');
      }

      if (saveFiles.isEmpty) {
        _syncStatus = 'No local save files found';
        _processedItems.add('No local save files found for auto-sync');
        _setSyncing(false);
        return;
      }

      // 3. Collect user-configured custom save folders (ARMSX2, ARMSX1, etc.)
      // from the NeoSync module. Each entry carries its system + emulator slug
      // so the cloud path identifies the emulator that produced the save.
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
          retroArchSaves.length +
          retroArchStates.length +
          customFiles.length +
          saveFiles.length; // saveFiles contains Switch files here

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

      // Process the rest (Switch, etc.)
      for (final file in saveFiles) {
        await _processAutoUploadFile(file, file.parent.path, isState: false);
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

  /// Fase 1: Subir archivos locales
  Future<void> _performUploadPhase(String basePath) async {
    _syncStatus = 'Phase 1: Uploading local files...';
    _processedItems.add('Phase 1: Scanning and uploading local files...');
    notify();

    // Determine if it is a states folder for RetroArch
    final statesPath = await _getRetroArchStatesPath();
    final isState = statesPath != null && path.equals(basePath, statesPath);

    final saveFiles = await _getSaveFiles(basePath);
    if (saveFiles.isEmpty) {
      _processedItems.add('No local files found in ${path.basename(basePath)}');
      return;
    }

    _totalFiles = saveFiles.length * 2;
    _processedItems.add('Found ${saveFiles.length} local files to process');

    for (final file in saveFiles) {
      await _processUploadFileWithConflictDetection(
        file,
        basePath,
        isState: isState,
      );
      _processedFiles++;
      _syncProgress = _totalFiles > 0 ? _processedFiles / _totalFiles : 0.0;
      notify();
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
  }) async {
    try {
      final isNandFile = file.path.contains(
        '${Platform.pathSeparator}nand${Platform.pathSeparator}user${Platform.pathSeparator}save',
      );

      if (isNandFile) {
        await _handleSwitchNandAutoUpload(file);
        return;
      }

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
      try {
        final fileName = path.basenameWithoutExtension(file.path);
        final row = await GameRepository.findRomForSaveName(fileName);
        if (row != null) {
          final game = _gameModelFromRomRow(row, fileName);
          gameHash = await _resolveGameHashForUpload(game);
        }
      } catch (e) {
        NeoSyncProvider._log.w(
          'Error resolving game hash for ${path.basename(file.path)}: $e',
        );
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
      );

      if (result['success']) {
        if (result['skipped'] == true) {
          _skippedFiles++;
          _processedItems.add('Already synced: $relativePath');
        } else {
          _uploadedFiles++;
          _processedItems.add('Auto-uploaded: $relativePath');
          _resetQuotaAttempts();
        }
      } else {
        final errorMessage = result['message'] ?? '';
        _processedItems.add('Failed to upload: $relativePath - $errorMessage');
        if (_checkQuotaExceeded(errorMessage)) {
          _quotaExceededActive = true;
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

  /// Maneja la subida automática de archivos de Switch NAND
  Future<void> _handleSwitchNandAutoUpload(File file) async {
    try {
      final pathParts = file.path.split(Platform.pathSeparator);
      final saveIndex = pathParts.indexOf('save');
      if (saveIndex != -1 && saveIndex + 3 < pathParts.length) {
        final titleId = pathParts[saveIndex + 3];

        final row = await GameRepository.findSwitchGameByTitleId(titleId);

        if (row == null) {
          NeoSyncProvider._log.w(
            'Switch upload skipped: titleId "$titleId" not found in DB (${file.path})',
          );
          _processedItems.add(
            'No game matched titleId $titleId - skipping upload',
          );
          return;
        }

        {
          final romname = row['filename'].toString();
          final titleName = row['title_name']?.toString();
          final game = GameModel(
            name: titleName ?? romname,
            realname: titleName ?? romname,
            romname: romname,
            systemFolderName: 'switch',
            year: '',
            developer: '',
            publisher: '',
            genre: '',
            players: '',
            rating: 0.0,
            titleId: titleId,
          );

          final relativePath = await calculateSwitchRelativePath(file, game);
          final result = await _neoSyncService.syncFile(
            file,
            game.name,
            customFilename: relativePath,
            type: 'save',
          );

          if (result['success']) {
            if (result['skipped'] == true) {
              _skippedFiles++;
              _processedItems.add('Already synced: $relativePath');
            } else {
              _uploadedFiles++;
              _processedItems.add('Auto-uploaded: $relativePath');
              _resetQuotaAttempts();
            }
          } else {
            final errorMessage = result['message'] ?? '';
            _processedItems.add(
              'Failed to upload: $relativePath - $errorMessage',
            );
            if (_checkQuotaExceeded(errorMessage)) {
              _quotaExceededActive = true;
              throw QuotaExceededException(
                errorMessage,
                _quotaExceededAttempts,
              );
            }
          }
        }
      }
    } catch (e) {
      NeoSyncProvider._log.e('Error processing Switch NAND file: $e');
    }
  }

  /// Procesa subida con detección de conflictos
  Future<void> _processUploadFileWithConflictDetection(
    File file,
    String basePath, {
    bool isState = false,
  }) async {
    try {
      String relativePath = _calculateRelativePath(
        file,
        basePath,
        isState: isState,
      );
      final rawGameName = _extractGameNameFromPath(file.path);
      final gameName = rawGameName.isEmpty ? 'Shared Save' : rawGameName;
      if (rawGameName.isEmpty) {
        NeoSyncProvider._log.w(
          'Upload: empty game_name for ${file.path}; using fallback '
          '"$gameName"',
        );
      }

      String? gameHash;
      String? systemId;
      String? emulatorId;
      try {
        final fileName = path.basenameWithoutExtension(file.path);
        final row = await GameRepository.findRomForSaveName(fileName);
        if (row != null) {
          final game = _gameModelFromRomRow(row, fileName);
          gameHash = await _resolveGameHashForUpload(game);
          systemId = game.systemFolderName;
          // Derive the RetroArch slug from the save's core folder (ground
          // truth); fall back to the game metadata.
          emulatorId =
              await _resolveRetroArchEmulatorSlug(file, basePath) ??
              _retroArchCoreSlugFromGame(game);
        }
      } catch (e) {
        NeoSyncProvider._log.w(
          'Error resolving game hash for ${path.basename(file.path)}: $e',
        );
      }

      final result = await _neoSyncService.syncFile(
        file,
        gameName,
        customFilename: relativePath,
        gameHash: gameHash,
        isState: isState,
        systemId: systemId,
        emulatorId: emulatorId,
        type: _syncTypeForFile(file, isState: isState),
      );

      if (result['success']) {
        if (result['skipped'] == true) {
          _skippedFiles++;
          _processedItems.add('Already synced: $relativePath');
        } else {
          _uploadedFiles++;
          _processedItems.add('Uploaded: $relativePath');
          _resetQuotaAttempts();
        }
      } else {
        final errorMessage = result['message'] ?? '';
        _processedItems.add('Failed to upload: $relativePath - $errorMessage');
        if (_checkQuotaExceeded(errorMessage)) {
          _quotaExceededActive = true;
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

  /// Uploads every file in a single configured custom save folder.
  ///
  /// Used right after the user selects a folder so its existing saves are
  /// backed up immediately, without waiting for the next global auto-sync.
  Future<void> syncCustomSaveFolder(
    String systemFolderName,
    String emulatorSlug,
  ) async {
    if (!isNeoSyncAuthenticated) return;
    if (_isSyncing) return;

    final folder = await NeoSyncSaveFolderRepository.getFolder(
      systemFolderName,
      emulatorSlug,
    );
    if (folder == null || folder.isEmpty) return;
    if (!Directory(folder).existsSync()) return;

    _setSyncing(true);
    _error = null;
    _syncProgress = 0.0;
    _syncStatus = 'Uploading standalone save folder...';
    _totalFiles = 0;
    _processedFiles = 0;
    _uploadedFiles = 0;
    _skippedFiles = 0;
    _downloadedFiles = 0;
    _processedItems = [];
    notify();

    try {
      final files = await _getSaveFiles(folder);
      _totalFiles = files.length;
      if (files.isEmpty) {
        _syncStatus = 'No save files found in the selected folder';
        _processedItems.add(_syncStatus);
        return;
      }

      _processedItems.add('Uploading $_totalFiles save files...');
      notify();

      for (final file in files) {
        await _processAutoUploadFile(
          file,
          folder,
          isState: false,
          customFolderSystem: systemFolderName,
          customFolderEmulatorSlug: emulatorSlug,
        );
        _processedFiles++;
        _syncProgress = _totalFiles > 0 ? _processedFiles / _totalFiles : 0.0;
        notify();
      }

      _syncProgress = 1.0;
      _syncStatus =
          'Upload complete: $_uploadedFiles uploaded, $_skippedFiles already synced';
      _processedItems.add(_syncStatus);
    } catch (e) {
      _error = 'Error uploading standalone save folder: $e';
      _syncStatus = 'Error: $_error';
      _processedItems.add(_syncStatus);
      NeoSyncProvider._log.e(_error!);
    } finally {
      _setSyncing(false);
    }
  }
}
