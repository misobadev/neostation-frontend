part of '../neo_sync_provider.dart';

extension NeoSyncCore on NeoSyncProvider {
  Future<void> updateSelectedGame(
    String romname,
    Future<GameModel?> Function(String romname) findGameModelByRomName,
  ) async {
    // Updates the internal state of the selected game
    _selectedGameRomname = romname;

    // Get the game model to store the name
    final gameModel = await findGameModelByRomName(romname);
    _selectedGameName = gameModel?.name ?? romname;

    // If the game does not exist in the map, add it
    if (!_gameSyncStates.containsKey(romname)) {
      _gameSyncStates[romname] = neo_sync.GameSyncState(
        gameId: romname,
        gameName: _selectedGameName!,
        status: neo_sync.GameSyncStatus.noSaveFound,
        cloudEnabled: true,
        localSave: null,
        cloudSave: null,
        lastSync: null,
        errorMessage: null,
      );
    }
    // Checks the sync state for the selected game
    await checkSelectedGameSaveStatus(findGameModelByRomName);
    notify();
  }

  /// Checks the synchronization state only for the selected game
  Future<void> checkSelectedGameSaveStatus(
    Future<GameModel?> Function(String romname) findGameModelByRomName,
  ) async {
    // Clear multi-emulator files tracking for new check (PS2 and Switch shared memory cards/saves)
    _processedMultiEmulatorFilesInSession.clear();

    if (_selectedGameRomname == null) {
      _syncStatus = 'No selected game for status check';
      _processedItems.add('No selected game for NeoSync save status check');
      NeoSyncProvider._log.w('No selected game for NeoSync save status check');
      notify();
      return;
    }

    final selectedGameState = _gameSyncStates[_selectedGameRomname];
    if (selectedGameState != null) {
      // Find the game model (GameModel) using the romname
      final selectedGameModel = await findGameModelByRomName(
        _selectedGameRomname!,
      );
      if (selectedGameModel != null) {
        // Only checks the state, does not sync
        await _checkGameSaveStatus(selectedGameModel);
        _syncStatus = 'Checked save status for selected game';
        _processedItems.add(
          'Checked save status for: ${selectedGameState.gameName}',
        );
        notify();
        return;
      } else {
        _syncStatus = 'Selected game model not found';
        _processedItems.add('Selected game model not found for status check');
        NeoSyncProvider._log.w(
          'Selected game model not found for status check',
        );
        notify();
        return;
      }
    }
    _syncStatus = 'No selected game for status check';
    _processedItems.add('No selected game for NeoSync save status check');
    NeoSyncProvider._log.w('No selected game for NeoSync save status check');
    notify();
    return;
  }

  /// Only checks the synchronization state for a game (no sync actions)
  Future<void> _checkGameSaveStatus(GameModel game) async {
    // Find local save for this game
    final localSave = await _findGameSaveFile(game);
    // Find cloud save for this game
    final cloudSave = await _getCloudSaveForGame(game, localSave: localSave);
    // Determine the synchronization state
    final syncStatus = await _calculateGameSyncStatus(localSave, cloudSave);

    // PRESERVE the quotaExceeded state if already set or if the global flag is active
    final currentState = _gameSyncStates[game.romname];
    final finalStatus =
        currentState?.status == neo_sync.GameSyncStatus.quotaExceeded ||
            _quotaExceededActive
        ? neo_sync.GameSyncStatus.quotaExceeded
        : syncStatus;

    // Update the state in the map
    _updateGameSyncState(
      game.romname,
      game.name,
      finalStatus,
      localSave: localSave,
      cloudSave: cloudSave,
    );
  }

  void setAuthService(AuthService authService) {
    _authService = authService;
    notify();
  }

  bool get isNeoSyncAuthenticated {
    return _authService?.isLoggedIn == true;
  }

  /// Unified synchronization: Uploads and downloads with automatic resolution
  Future<void> syncWithConflictResolution() async {
    if (!isNeoSyncAuthenticated) {
      return;
    }
    if (_isSyncing) return;

    _setSyncing(true);
    _error = null;
    _syncProgress = 0.0;
    _syncStatus = 'Starting unified sync...';
    _totalFiles = 0;
    _processedFiles = 0;
    _uploadedFiles = 0;
    _skippedFiles = 0;
    _downloadedFiles = 0;
    _processedItems = [];

    notify();

    try {
      final savesPath = await _getRetroArchSavesPath();
      if (savesPath == null) {
        _syncStatus = 'RetroArch saves directory not found';
        _processedItems.add('RetroArch saves directory not found');
        return;
      }

      // Phase 1: Upload local files
      await _performUploadPhase(savesPath);

      // Phase 2: Download cloud files
      await _performDownloadPhase(savesPath);

      _syncProgress = 1.0;
      _syncStatus =
          'Unified sync completed: '
          '$_uploadedFiles uploaded, $_downloadedFiles downloaded, '
          '$_skippedFiles already synced';
      _processedItems.add('Unified sync completed successfully!');
    } catch (e) {
      if (e is QuotaExceededException) {
        _error = 'Storage quota exceeded after ${e.attemptCount} attempts';
        _syncStatus = 'Quota exceeded - sync stopped';
        _processedItems.add('Storage quota exceeded - sync stopped');
        NeoSyncProvider._log.e(
          'Sync stopped due to quota exceeded: ${e.message}',
        );
      } else {
        _error = 'Error during sync: $e';
        _syncStatus = 'Error: $_error';
        _processedItems.add('Sync error: $e');
        NeoSyncProvider._log.e('Unified sync error: $e');
      }
    } finally {
      _setSyncing(false);
    }
  }

  /// Steam-style auto-sync: Detects and synchronizes files automatically
  Future<void> autoSync() async {
    if (!isNeoSyncAuthenticated) {
      return;
    }
    if (_isSyncing || _isAutoSyncing) return;

    _setAutoSyncing(true);
    try {
      await autoSyncUploads();
      await autoSyncDownloads();
    } finally {
      _setAutoSyncing(false);
    }
  }

  /// Stops the ongoing synchronization
  void stopSyncing() {
    _isSyncing = false;
    _syncStatus = 'Sync stopped by user';
    // Defer the notification to avoid setState during build
    WidgetsBinding.instance.addPostFrameCallback((_) {
      notify();
    });
  }

  void clearError() {
    _error = null;
    // Defer the notification to avoid setState during build
    WidgetsBinding.instance.addPostFrameCallback((_) {
      notify();
    });
  }

  /// Enables or disables auto-sync
  void setAutoSyncEnabled(bool enabled) {
    _autoSyncEnabled = enabled;
    notify();
  }

  /// Runs auto-sync before starting a game (Steam-style)
  Future<void> syncBeforeGameStart() async {
    if (!isNeoSyncAuthenticated) {
      return;
    }
    if (!_autoSyncEnabled) return;

    _processedItems.add('Syncing saves before game start...');
    await autoSync();
  }

  /// Runs auto-sync after closing a game (Steam-style)
  Future<void> syncAfterGameEnd() async {
    if (!isNeoSyncAuthenticated) {
      return;
    }
    if (!_autoSyncEnabled) return;

    _processedItems.add('Syncing saves after game end...');
    await autoSyncUploads(); // Only upload local changes after the game
  }

  /// Runs only download auto-sync when initializing the app
  Future<void> syncOnAppStart() async {
    if (!isNeoSyncAuthenticated) {
      return;
    }
    if (!_autoSyncEnabled) return;

    _processedItems.add('Checking for cloud updates on app start...');
    await autoSyncDownloads(); // Only download on initialization
  }

  /// Resets the state of the quota exceeded dialog
  void resetQuotaExceededDialog() {
    _quotaExceededDialogShown = false;
    _quotaExceededAttempts = 0;
    _quotaExceededActive = false; // Also reset the global flag
  }

  /// Shows the quota exceeded dialog
  Future<String?> showQuotaExceededDialog(BuildContext context) async {
    if (_quotaExceededDialogShown) return null;

    _quotaExceededDialogShown = true;
    notify();

    return showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (context) => QuotaExceededDialog(
        quota: _quota!,
        attemptCount: _quotaExceededAttempts,
        onUpgradePlan: () {
          // Navigate to the plan upgrade screen (not yet implemented).
        },
        onManageFiles: () {
          // Navigate to the file management screen (not yet implemented).
        },
      ),
    );
  }

  /// Gets all local saves with their synchronization state
  Future<List<LocalSaveFile>> getLocalSaveFiles() async {
    final savesPath = await _getRetroArchSavesPath();
    if (savesPath == null) {
      NeoSyncProvider._log.w('RetroArch saves directory not found');
      return [];
    }

    final saveFiles = await _getSaveFiles(savesPath);
    final localSaveFiles = <LocalSaveFile>[];

    // Create a map of synced files by name for quick comparison
    final syncedFilesMap = <String, NeoSyncFile>{};
    for (final syncedFile in _files) {
      // Normalize separators for consistent comparison
      final normalizedFileName = syncedFile.fileName.replaceAll('\\', '/');
      syncedFilesMap[normalizedFileName] = syncedFile;
    }

    for (final file in saveFiles) {
      try {
        final stat = await file.stat();
        final fileName = file.path.split(Platform.pathSeparator).last;
        final gameName = _extractGameNameFromPath(file.path);

        // Calculate the full relative path (same as used for uploading)
        String relativePath = '';
        final normalizedFilePath = file.path.replaceAll('\\', '/');
        final normalizedSavesPath = savesPath.replaceAll('\\', '/');

        final savesPathWithSeparator = normalizedSavesPath.endsWith('/')
            ? normalizedSavesPath
            : '$normalizedSavesPath/';

        if (normalizedFilePath.startsWith(savesPathWithSeparator)) {
          relativePath = normalizedFilePath.substring(
            savesPathWithSeparator.length,
          );
        } else {
          relativePath = fileName;
        }

        // Normalizar separadores para comparación consistente
        relativePath = relativePath.replaceAll('\\', '/');

        // Verificar si está sincronizado comparando con archivos en la nube usando la ruta relativa
        final syncedFile = syncedFilesMap[relativePath];
        bool isSynced = false;

        if (syncedFile != null) {
          // Comparar timestamps y tamaños para determinar si está sincronizado
          final localTimestamp = stat.modified.millisecondsSinceEpoch;
          final cloudTimestamp = syncedFile.fileModifiedAtTimestamp;

          // Considerar sincronizado si los timestamps coinciden o la diferencia es mínima
          if (cloudTimestamp != null) {
            final timeDiff = (localTimestamp - cloudTimestamp).abs();
            isSynced = timeDiff < 1000; // 1 segundo de tolerancia
          }

          // También verificar tamaño si timestamps no están disponibles
          if (!isSynced && syncedFile.fileSize == stat.size) {
            isSynced = true;
          }
        }

        localSaveFiles.add(
          LocalSaveFile(
            filePath: file.path,
            fileName: fileName,
            fileSize: stat.size,
            lastModified: stat.modified,
            gameName: gameName,
            isSynced: isSynced,
            relativePath: relativePath,
          ),
        );
      } catch (e) {
        NeoSyncProvider._log.w(
          'Error processing local save file ${file.path}: $e',
        );
      }
    }

    // Ordenar por fecha de modificación (más recientes primero)
    localSaveFiles.sort((a, b) => b.lastModified.compareTo(a.lastModified));

    return localSaveFiles;
  }

  // ==========================================
  // MÉTODOS PARA SINCRONIZACIÓN POR JUEGO
  // ==========================================

  /// Detecta automáticamente archivos de guardado para un juego específico
  /// y realiza sincronización automática cuando es apropiado
  Future<void> detectGameSaveFiles(GameModel game) async {
    if (!isNeoSyncAuthenticated) {
      return;
    }
    if (game.cloudSyncEnabled != true) {
      // Si el sync está deshabilitado para este juego, no hacer nada
      _updateGameSyncState(
        game.romname,
        game.name,
        neo_sync.GameSyncStatus.disabled,
      );
      return;
    }

    // Verificar si el sistema tiene sync deshabilitado
    final system = await _getSystemForGame(game);
    if (system != null && !system.neosync.sync) {
      _updateGameSyncState(
        game.romname,
        game.name,
        neo_sync.GameSyncStatus.disabled,
      );
      return;
    }

    // PRIMERO: Actualizar estado a "checking/syncing" para mostrar feedback visual inmediato
    _updateGameSyncState(
      game.romname,
      game.name,
      neo_sync.GameSyncStatus.syncing,
    );

    try {
      // Identificar si es un sistema de "memory cards compartidas"
      final system = await _getSystemForGame(game);
      final isSharedSystem =
          system?.folderName == 'ps2' || system?.folderName == 'dreamcast';

      // Verificar si hay configuración de emulador válida en Windows
      if (system != null && Platform.isWindows) {
        bool hasValidEmulator = true;

        if (system.id == 'switch') {
          final emulatorsList =
              await EmulatorRepository.getStandaloneEmulatorsBySystemId(
                'switch',
              );
          hasValidEmulator = false;

          // Revisar primero el seleccionado por el usuario
          for (final emu in emulatorsList) {
            if (emu['is_user_default'].toString() == '1') {
              final path = emu['emulator_path']?.toString();
              if (path != null && path.trim().isNotEmpty) {
                hasValidEmulator = true;
              }
              break;
            }
          }

          // Si no hay de usuario, revisar el default del sistema
          if (!hasValidEmulator &&
              !emulatorsList.any(
                (e) => e['is_user_default'].toString() == '1',
              )) {
            for (final emu in emulatorsList) {
              if (emu['is_default'].toString() == '1') {
                final path = emu['emulator_path']?.toString();
                if (path != null && path.trim().isNotEmpty) {
                  hasValidEmulator = true;
                }
                break;
              }
            }
          }
        } else {
          // Para RetroArch y otros sistemas, verificar si las rutas se pueden resolver.
          final resolvedPaths = await resolveUniversalPaths(
            system,
            game: game,
            ensureExists: false,
          );
          if (resolvedPaths.isEmpty) {
            hasValidEmulator = false;
          }
        }

        if (!hasValidEmulator) {
          NeoSyncProvider._log.w(
            'No valid emulator path configured for ${system.realName} in Windows, marking as missingEmulator',
          );
          _updateGameSyncState(
            game.romname,
            game.name,
            neo_sync.GameSyncStatus.missingEmulator,
          );
          return;
        }
      }

      // Buscar TODOS los archivos de save locales para este juego (saves y states)
      final localSaveFiles = await _findGameSaveFiles(game);

      // Si no hay archivos locales, verificar si hay archivos en la nube para descargar
      if (localSaveFiles.isEmpty) {
        // Buscar archivos en la nube para este juego
        final cloudFiles = await _getCloudSaveFilesForGame(game);

        if (cloudFiles.isNotEmpty) {
          // Descargar todos los archivos de la nube
          bool allDownloadsSucceeded = true;
          for (final cloudFile in cloudFiles) {
            final downloadSuccess = await _autoDownloadCloudSave(
              game,
              cloudFile,
            );
            if (!downloadSuccess) {
              allDownloadsSucceeded = false;
            }
          }

          // Después de descargar, el estado se actualizará automáticamente
          // Pero NO sobrescribir si ya hay un error de quota exceeded
          final currentState = _gameSyncStates[game.romname];
          if (currentState?.status != neo_sync.GameSyncStatus.quotaExceeded) {
            final status = allDownloadsSucceeded
                ? neo_sync.GameSyncStatus.upToDate
                : neo_sync.GameSyncStatus.upToDate;
            _updateGameSyncState(game.romname, game.name, status);
          }
          return;
        } else {
          // No hay archivos locales ni en la nube
          _updateGameSyncState(
            game.romname,
            game.name,
            neo_sync.GameSyncStatus.noSaveFound,
          );
          return;
        }
      }

      // Hay archivos locales, verificar sincronización para cada uno
      bool allUploadsSucceeded = true; // Track if any uploads failed
      bool quotaExceededDuringProcessing = false;
      bool allCloudDownloadsSucceeded = true;

      final cloudFiles = await _getCloudSaveFilesForGame(game);

      // 1. Verificar cada archivo local contra la nube
      for (final localFile in localSaveFiles) {
        // OPTIMIZACIÓN: Si es compartido y ya lo procesamos en esta sesión, saltar el sync activo
        if (isSharedSystem &&
            _processedMultiEmulatorFilesInSession.contains(
              localFile.filePath,
            )) {
          continue;
        }

        // Encontrar archivo correspondiente en la nube por nombre (relativePath ya es el namespace)
        final cloudFile = cloudFiles.firstWhere(
          (cf) => cf.fileName == localFile.relativePath,
          orElse: () => NeoSyncFile(
            id: '',
            fileName: '',
            filePath: '',
            fileSize: 0,
            gameName: '',
            uploadedAt: DateTime.now(),
            userId: '',
            checksum: '',
          ),
        );

        if (cloudFile.fileName.isEmpty) {
          // No existe en la nube, subir
          try {
            final uploadSuccess = await _autoUploadLocalSave(game, localFile);
            if (!uploadSuccess) allUploadsSucceeded = false;
            if (uploadSuccess && isSharedSystem) {
              _processedMultiEmulatorFilesInSession.add(localFile.filePath);
            }
          } on QuotaExceededException {
            quotaExceededDuringProcessing = true;
            allUploadsSucceeded = false;
          }
        } else {
          // Ambos existen, comparar
          final syncStatus = await _calculateGameSyncStatus(
            localFile,
            cloudFile,
          );

          if (syncStatus == neo_sync.GameSyncStatus.localOnly) {
            try {
              final success = await _autoUploadLocalSave(game, localFile);
              if (!success) allUploadsSucceeded = false;
              if (success && isSharedSystem) {
                _processedMultiEmulatorFilesInSession.add(localFile.filePath);
              }
            } on QuotaExceededException {
              quotaExceededDuringProcessing = true;
              allUploadsSucceeded = false;
            }
          } else if (syncStatus == neo_sync.GameSyncStatus.cloudOnly) {
            try {
              final success = await _autoDownloadCloudSave(game, cloudFile);
              if (!success) allCloudDownloadsSucceeded = false;
              if (success && isSharedSystem) {
                _processedMultiEmulatorFilesInSession.add(localFile.filePath);
              }
            } on QuotaExceededException {
              quotaExceededDuringProcessing = true;
              allCloudDownloadsSucceeded = false;
            }
          } else if (syncStatus == neo_sync.GameSyncStatus.upToDate) {
            // Si está al día, marcar como procesado para no volver a chequearlo
            if (isSharedSystem) {
              _processedMultiEmulatorFilesInSession.add(localFile.filePath);
            }
          }
        }
      }

      // 2. Verificar archivos en la nube que no existen localmente
      for (final cloudFile in cloudFiles) {
        // Resolver rutas locales para chequear si ya fueron procesadas
        final localPaths = await resolveCloudFileToLocalPath(game, cloudFile);
        if (localPaths.isEmpty) continue;

        bool allProcessed = localPaths.isNotEmpty;
        if (isSharedSystem) {
          for (final path in localPaths) {
            if (!_processedMultiEmulatorFilesInSession.contains(path)) {
              allProcessed = false;
              break;
            }
          }
        } else {
          allProcessed = false; // Forzamos chequeo si no es sistema compartido
        }

        if (allProcessed) {
          continue;
        }

        final existsLocally = localSaveFiles.any(
          (lf) => lf.relativePath == cloudFile.fileName,
        );

        if (!existsLocally) {
          try {
            final success = await _autoDownloadCloudSave(game, cloudFile);
            if (!success) allCloudDownloadsSucceeded = false;

            if (success && isSharedSystem) {
              for (final path in localPaths) {
                _processedMultiEmulatorFilesInSession.add(path);
              }
            }
          } on QuotaExceededException {
            quotaExceededDuringProcessing = true;
            allCloudDownloadsSucceeded = false;
          }
        }
      }

      // 3. Actualizar estado final
      neo_sync.GameSyncStatus finalStatus;
      if (_quotaExceededActive || quotaExceededDuringProcessing) {
        finalStatus = neo_sync.GameSyncStatus.quotaExceeded;
      } else if (!allUploadsSucceeded || !allCloudDownloadsSucceeded) {
        NeoSyncProvider._log.w(
          'Sync had errors for ${game.name}, marking as upToDate',
        );
        finalStatus = neo_sync.GameSyncStatus.upToDate;
      } else {
        finalStatus = neo_sync.GameSyncStatus.upToDate;
      }

      _updateGameSyncState(game.romname, game.name, finalStatus);
    } catch (e) {
      NeoSyncProvider._log.w('Error detecting saves for ${game.name}: $e');
      _updateGameSyncState(
        game.romname,
        game.name,
        neo_sync.GameSyncStatus.noSaveFound,
      );
    }
  }

  /// Obtiene el nombre del ROM sin extensión para comparación con archivos de save
  String _getRomNameWithoutExtension(String romname) {
    // Remover la extensión del archivo si existe
    if (romname.contains('.')) {
      return romname.substring(0, romname.lastIndexOf('.'));
    }
    return romname;
  }

  Future<bool> _autoUploadLocalSave(
    GameModel game,
    LocalSaveFile localSave,
  ) async {
    try {
      final file = File(localSave.filePath);
      if (!file.existsSync()) return false;

      // 1. Obtener el sistema para resolver sus rutas JSON
      final system = await _getSystemForGame(game);
      if (system == null) return false;

      // Verificar si el sistema tiene sync deshabilitado
      if (!system.neosync.sync) {
        return false;
      }

      // 2. Determinar la ruta relativa de manera universal
      final savesPath = await _getRetroArchSavesPath();
      final statesPath = await _getRetroArchStatesPath();

      String basePath = file.parent.path;
      bool isState = false;

      if (statesPath != null && path.isWithin(statesPath, file.path)) {
        basePath = statesPath;
        isState = true;
      } else if (savesPath != null && path.isWithin(savesPath, file.path)) {
        basePath = savesPath;
        isState = false;
      }

      final relativePath = await _calculateSyncRelativePath(
        game,
        file,
        basePath,
        isState: isState,
        explicitSystemFolder: game.systemFolderName,
      );
      if (relativePath == null) {
        NeoSyncProvider._log.w(
          'Auto-upload skipped for ${game.name}: no resolvable sync path',
        );
        return false;
      }

      final parsed = CloudPathBuilder.parse(relativePath);
      // RetroArch saves use the v1-style relative path, which the cloud path
      // parser cannot see an emulator in, so derive the RetroArch slug from the
      // save's core folder (ground truth), falling back to the game metadata.
      final emulatorId =
          parsed?.emulatorSlug ??
          await _resolveRetroArchEmulatorSlug(file, basePath) ??
          _retroArchCoreSlugFromGame(game);
      final result = await _neoSyncService.syncFile(
        file,
        game.name,
        customFilename: relativePath,
        systemId: parsed?.system ?? game.systemFolderName,
        emulatorId: emulatorId,
        gameHash: await _resolveGameHashForUpload(game),
        isState: isState,
        scope: parsed?.scope,
      );

      if (result['success']) {
        return true;
      } else {
        final errorMessage = result['message']?.toString().toLowerCase() ?? '';
        if (errorMessage.contains('quota') &&
            errorMessage.contains('exceeded')) {
          _quotaExceededActive = true;
          throw QuotaExceededException('Storage quota exceeded', 1);
        }
        return false;
      }
    } on QuotaExceededException {
      rethrow;
    } catch (e) {
      NeoSyncProvider._log.w('Error auto-uploading save for ${game.name}: $e');
      return false;
    }
  }

  /// Descarga automáticamente un save de la nube
  Future<bool> _autoDownloadCloudSave(
    GameModel game,
    NeoSyncFile cloudSave,
  ) async {
    try {
      // 1. Resolver la ruta local de manera universal
      final localPaths = await resolveCloudFileToLocalPath(game, cloudSave);
      if (localPaths.isEmpty) {
        NeoSyncProvider._log.w(
          'Auto-download: no path for ${cloudSave.fileName} '
          '(${game.name}); skipping',
        );
        return false;
      }

      // Verificar si el sistema tiene sync deshabilitado
      final system = await _getSystemForGame(game);
      if (system != null && !system.neosync.sync) {
        NeoSyncProvider._log.w(
          'Auto-download: sync disabled for ${system.realName}; '
          'skipping ${cloudSave.fileName}',
        );
        return false;
      }

      NeoSyncProvider._log.i(
        'Auto-download: ${cloudSave.fileName} -> ${localPaths.join(', ')}',
      );
      bool anySuccess = false;
      for (final localPath in localPaths) {
        final localFile = File(localPath);

        // 2. Crear directorio si no existe
        await localFile.parent.create(recursive: true);

        // 3. Descargar el archivo
        await _downloadCloudFile(cloudSave, localFile);
        anySuccess = true;
      }

      return anySuccess;
    } on QuotaExceededException {
      rethrow;
    } catch (e) {
      NeoSyncProvider._log.w(
        'Error auto-downloading save for ${game.name}: $e',
      );
      return false;
    }
  }

  /// Busca TODOS los archivos de guardado locales para un juego específico (saves y states)
  /// Whether [candidate] (a filename or full path, case-insensitive) refers to
  /// a save/state of the game with [romName].
  ///
  /// The ROM name must end at a word boundary (`.`, `_`, space, `[`, `(`, `/`),
  /// so a save like `mvsc2u.zip.eeprom` never matches the game `mvsc` the way a
  /// plain substring check would. A plain substring check is what uploaded the
  /// orphan Naomi EEPROM under the unrelated CPS2 "Clash of Super Heroes".
  bool _saveBelongsToRom(String candidate, String romName) {
    final g = romName.trim().toLowerCase();
    if (g.isEmpty) return false;
    final c = candidate.toLowerCase();
    if (c == g) return true;
    const boundaries = ['.', '_', ' ', '[', '(', '/'];
    for (final b in boundaries) {
      if (c.contains('$g$b')) return true;
    }
    // The ROM name as the final path segment (a game folder).
    return c.endsWith('/$g');
  }

  Future<List<LocalSaveFile>> _findGameSaveFiles(GameModel game) async {
    try {
      // 1. Obtener el sistema para resolver sus rutas JSON
      final system = await _getSystemForGame(game);
      if (system == null) return [];

      // Verificar si el sistema tiene sync deshabilitado
      if (!system.neosync.sync) return [];

      // 2. Resolver rutas universales desde el JSON
      final resolvedFolders = await resolveUniversalPaths(system, game: game);
      if (resolvedFolders.isEmpty) return [];

      // 3. Escanear archivos en esas rutas pero en un Isolate para no bloquear la UI
      final List<File> allFiles = [];
      const int maxFileSize = 10 * 1024 * 1024; // 10MB

      // Execute heavy listing and filtering in background
      final List<String> filePaths = await Isolate.run(() {
        final List<String> paths = [];
        for (final folderPath in resolvedFolders) {
          final dir = Directory(folderPath);
          if (dir.existsSync()) {
            final files = dir.listSync(recursive: true).whereType<File>().where(
              (file) {
                try {
                  final size = file.lengthSync();
                  return size <= maxFileSize;
                } catch (e) {
                  return false;
                }
              },
            );
            paths.addAll(files.map((f) => f.path));
          }
        }
        return paths;
      });

      allFiles.addAll(filePaths.map((path) => File(path)));

      // 4. Filtrar archivos según el sistema
      final List<LocalSaveFile> matchingFiles = [];
      final gameRomName = _getRomNameWithoutExtension(
        game.romname,
      ).toLowerCase();

      // Identificar si es un sistema de "memory cards compartidas"
      final isSharedSystem =
          system.folderName == 'ps2' || system.folderName == 'dc';

      final statesPath = await _getRetroArchStatesPath();
      final savesPath = await _getRetroArchSavesPath();

      for (final file in allFiles) {
        try {
          final fileName = path.basename(file.path).toLowerCase();
          bool isMatch = false;

          if (isSharedSystem) {
            // Para sistemas compartidos, cualquier archivo de save/state válido es un match
            // PS2: .ps2, DC: vmu_save
            if (system.folderName == 'ps2' && fileName.endsWith('.ps2')) {
              isMatch = true;
            } else if (system.folderName == 'dc' &&
                fileName.startsWith('vmu_save') &&
                fileName.endsWith('.bin')) {
              isMatch = true;
            }
          } else {
            // Standard systems match by ROM name with a word boundary, so
            // mvsc2u.zip.eeprom can never match the game "mvsc". The full path
            // is also checked in case the game name lives in the containing
            // folder instead of the file itself (e.g. Switch).
            final fullPathLower = file.path.toLowerCase();

            if (_saveBelongsToRom(fileName, gameRomName) ||
                _saveBelongsToRom(fullPathLower, gameRomName)) {
              isMatch = true;
            } else if (system.folderName == 'switch' &&
                game.titleId != null &&
                game.titleId!.isNotEmpty &&
                fullPathLower.contains(game.titleId!.toLowerCase())) {
              // Switch special case: match by Title ID in the path
              isMatch = true;
            }
          }

          if (isMatch) {
            final stat = await file.stat();

            String basePath = file.parent.path;
            bool isState = false;

            if (statesPath != null && path.isWithin(statesPath, file.path)) {
              basePath = statesPath;
              isState = true;
            } else if (savesPath != null &&
                path.isWithin(savesPath, file.path)) {
              basePath = savesPath;
              isState = false;
            }

            final relativePath = _calculateRelativePath(
              file,
              basePath,
              isState: isState,
            );

            matchingFiles.add(
              LocalSaveFile(
                filePath: file.path,
                fileName: path.basename(file.path),
                fileSize: stat.size,
                lastModified: stat.modified,
                gameName: isSharedSystem
                    ? '${system.realName} Shared'
                    : game.name,
                isSynced: false,
                relativePath: relativePath,
              ),
            );

            // Marcar como procesado si es compartido para evitar re-comprobación en esta sesión
            if (isSharedSystem) {
              _processedMultiEmulatorFilesInSession.add(file.path);
            }
          }
        } catch (e) {
          NeoSyncProvider._log.e('Error matching file: $e');
        }
      }

      return matchingFiles;
    } catch (e) {
      NeoSyncProvider._log.e('Error in universal _findGameSaveFiles: $e');
      return [];
    }
  }

  /// Busca archivo de guardado local para un juego específico (legacy method - returns first match)
  Future<LocalSaveFile?> _findGameSaveFile(GameModel game) async {
    final allFiles = await _findGameSaveFiles(game);
    return allFiles.isNotEmpty ? allFiles.first : null;
  }

  // ── Public reuse hooks for other sync providers (e.g. RomM) ───────────────

  /// Locates local save/state files for [game], reusing NeoSync's path
  /// resolution and filename matching. Each [LocalSaveFile.relativePath] is
  /// prefixed with `saves/` or `states/` so callers can tell them apart.
  Future<List<LocalSaveFile>> locateGameSaveFiles(GameModel game) =>
      _findGameSaveFiles(game);

  /// Resolves candidate local destination paths for a cloud file named
  /// [relativeName] (e.g. `saves/Game.srm` or `states/Game.state`) belonging to
  /// [game]. Returns an empty list if no destination can be resolved.
  Future<List<String>> resolveLocalTargetPaths(
    GameModel game,
    String relativeName,
  ) => resolveCloudFileToLocalPath(
    game,
    localTargetCloudFile(game, relativeName),
  );

  /// Obtiene TODOS los archivos de guardado de la nube para un juego específico
  Future<List<NeoSyncFile>> _getCloudSaveFilesForGame(GameModel game) async {
    try {
      // 1. Obtener el sistema para resolver sus características
      final system = await _getSystemForGame(game);
      if (system == null) return [];

      // Verificar si el sistema tiene sync deshabilitado
      if (!system.neosync.sync) return [];

      // 2. Cargar archivos de la nube si no están cargados
      if (_files.isEmpty) {
        final result = await _neoSyncService.getAllFiles();
        if (result['success']) {
          _files = result['files'];
        } else {
          return [];
        }
      }

      final gameRomName = _getRomNameWithoutExtension(
        game.romname,
      ).toLowerCase();
      final List<NeoSyncFile> matchingFiles = [];

      // Identificar si es un sistema de "memory cards compartidas"
      final isSharedSystem =
          system.folderName == 'ps2' || system.folderName == 'dc';

      for (final cloudFile in _files) {
        final fileName = path.basename(cloudFile.fileName).toLowerCase();
        bool isMatch = false;

        if (isSharedSystem) {
          // Para sistemas compartidos, filtrar estrictamente por sistema
          if (system.folderName == 'ps2' && fileName.endsWith('.ps2')) {
            isMatch = true;
          } else if (system.folderName == 'dc' &&
              fileName.startsWith('vmu_save') &&
              fileName.endsWith('.bin')) {
            isMatch = true;
          }
        } else {
          // Standard systems match by ROM name with a word boundary. The full
          // cloud path is checked too in case it lives in folders (e.g. Switch).
          final fullCloudPathLower = cloudFile.fileName.toLowerCase();

          if (_saveBelongsToRom(fileName, gameRomName) ||
              _saveBelongsToRom(fullCloudPathLower, gameRomName)) {
            isMatch = true;
          }
        }

        if (isMatch) {
          matchingFiles.add(cloudFile);
        }
      }

      return matchingFiles;
    } catch (e) {
      NeoSyncProvider._log.e(
        'Error getting cloud save files for ${game.name}: $e',
      );
      return [];
    }
  }

  /// Obtiene archivo de guardado de la nube para un juego específico (legacy method - returns first match)
  Future<NeoSyncFile?> _getCloudSaveForGame(
    GameModel game, {
    LocalSaveFile? localSave,
  }) async {
    final allFiles = await _getCloudSaveFilesForGame(game);
    return allFiles.isNotEmpty ? allFiles.first : null;
  }

  /// Calcula el estado de sincronización para un juego basado en save local y de nube
  Future<neo_sync.GameSyncStatus> _calculateGameSyncStatus(
    LocalSaveFile? localSave,
    NeoSyncFile? cloudSave,
  ) async {
    if (localSave == null && cloudSave == null) {
      return neo_sync.GameSyncStatus.noSaveFound;
    }

    if (localSave == null && cloudSave != null) {
      return neo_sync.GameSyncStatus.cloudOnly;
    }

    if (localSave != null && cloudSave == null) {
      return neo_sync.GameSyncStatus.localOnly;
    }

    // Ambos tienen saves, verificar sincronización comparando timestamps y hashes
    assert(localSave != null && cloudSave != null);

    try {
      // Leer el archivo local para calcular hash
      final localFile = File(localSave!.filePath);
      if (!localFile.existsSync()) {
        return neo_sync.GameSyncStatus.localOnly; // Archivo local desapareció
      }

      final localBytes = await localFile.readAsBytes();
      final localHash = _neoSyncService.calculateFileHash(localBytes);

      // Comparar hashes si están disponibles
      final cloudHash = cloudSave!.checksum;
      final hashesMatch = cloudHash != null && localHash == cloudHash;

      // 1. Si los hashes coinciden → Contenido idéntico
      if (hashesMatch) {
        return neo_sync.GameSyncStatus.upToDate;
      }

      // 2. Si los hashes NO coinciden (contenido diferente), evaluar el estado guardado.
      final syncState = await SyncRepository.getSyncState(
        NeoSyncProvider.kSyncProviderId,
        localSave.filePath,
      );

      final cloudTime = cloudSave.fileModifiedAtTimestamp ?? 0;
      final localTime = localSave.lastModified.millisecondsSinceEpoch;

      if (syncState != null) {
        final savedLocalTime = syncState['local_modified_at'] as int;
        final savedCloudTime = syncState['cloud_updated_at'] as int;

        // Tolerance of 2 seconds for local changes (FAT32/exFAT resolution)
        final localChanged = (localTime - savedLocalTime).abs() > 2000;
        final cloudChanged = cloudTime > savedCloudTime;

        if (localChanged && !cloudChanged) {
          return neo_sync.GameSyncStatus.localOnly; // Local avanzó, subir
        } else if (!localChanged && cloudChanged) {
          return neo_sync.GameSyncStatus.cloudOnly; // Nube avanzó, bajar
        } else if (localChanged && cloudChanged) {
          // Ambos cambiaron - siempre preferir local (subir)
          return neo_sync.GameSyncStatus.localOnly;
        } else {
          // Ninguno de los dos cambió desde la última sincronización, pero los hashes son distintos.
          // Fallback a comparar timestamps crudos si no sabemos qué pasó.
          if (localTime > cloudTime) {
            return neo_sync.GameSyncStatus.localOnly;
          } else {
            return neo_sync.GameSyncStatus.cloudOnly;
          }
        }
      }

      // Si NO hay estado guardado (primera vez o borrado), fallback a lógica base
      const int toleranceMs = 2000;
      final timeDiff = (localTime - cloudTime).abs();

      if (timeDiff <= toleranceMs) {
        if (localTime > cloudTime) {
          return neo_sync.GameSyncStatus.localOnly;
        } else {
          return neo_sync.GameSyncStatus.cloudOnly;
        }
      }

      if (localTime > cloudTime) {
        return neo_sync.GameSyncStatus.localOnly;
      } else {
        return neo_sync.GameSyncStatus.cloudOnly;
      }
    } catch (e) {
      NeoSyncProvider._log.w('Error calculating sync status: $e');
      return neo_sync.GameSyncStatus.localOnly;
    }
  }

  /// Actualiza el estado de sincronización de un juego
  void _updateGameSyncState(
    String gameId,
    String gameName,
    neo_sync.GameSyncStatus status, {
    LocalSaveFile? localSave,
    NeoSyncFile? cloudSave,
  }) {
    final currentState = _gameSyncStates[gameId];
    final newState = neo_sync.GameSyncState(
      gameId: gameId,
      gameName: gameName,
      status: status,
      cloudEnabled: currentState?.cloudEnabled ?? true,
      localSave: localSave,
      cloudSave: cloudSave,
      lastSync: DateTime.now(),
    );

    _gameSyncStates[gameId] = newState;
    notify();
  }

  /// Actualiza la configuración de sincronización en la nube para un juego
  Future<void> updateGameCloudSyncEnabled(String gameId, bool enabled) async {
    try {
      // systemFolderName and filename resolution for this gameId is not yet implemented;
      // only local state is updated for now.
      final currentState = _gameSyncStates[gameId];
      if (currentState != null) {
        final newState = currentState.copyWith(cloudEnabled: enabled);
        _gameSyncStates[gameId] = newState;
      }

      if (enabled) {
        _updateGameSyncState(
          gameId,
          currentState?.gameName ?? gameId,
          neo_sync.GameSyncStatus.noSaveFound,
        );
      } else {
        _updateGameSyncState(
          gameId,
          currentState?.gameName ?? gameId,
          neo_sync.GameSyncStatus.disabled,
        );
      }
    } catch (e) {
      NeoSyncProvider._log.e('Error updating cloud sync for game $gameId: $e');
    }
  }

  // ==========================================
  // MÉTODOS PÚBLICOS PARA DESCARGA INDIVIDUAL
  // ==========================================

  /// Obtiene la ruta del directorio de saves de RetroArch (método público)
  Future<String?> getRetroArchSavesPath() async {
    return _getRetroArchSavesPath();
  }

  /// Descarga un archivo de la nube a un archivo local (método público)
  Future<void> downloadCloudFile(NeoSyncFile cloudFile, File localFile) async {
    return _downloadCloudFile(cloudFile, localFile);
  }

  /// Helper to calculate relative path for sync, with special handling for Dreamcast
  /// Sincroniza saves antes de iniciar un juego (al estilo Steam)
  Future<void> syncGameSavesBeforeLaunch(
    GameModel game, {
    SyncDeadline? deadline,
  }) async {
    if (!isNeoSyncAuthenticated) return;
    if (game.cloudSyncEnabled != true) return;

    // Expose the deadline to the shared download path (_downloadCloudFile) so a
    // late download abandons its write once the launch has proceeded.
    _launchDeadline = deadline;
    try {
      // Detectar saves actuales
      await detectGameSaveFiles(game);

      final gameState = _gameSyncStates[game.romname];
      if (gameState == null) return;

      // Always proceed with sync (auto-resolve)

      // Sincronizar solo si es necesario
      if (gameState.status == neo_sync.GameSyncStatus.localOnly &&
          gameState.localSave != null) {
        // Subir save local que no está en la nube
        final file = File(gameState.localSave!.filePath);
        if (file.existsSync()) {
          // Calcular la ruta relativa correcta
          final savesPath = await _getRetroArchSavesPath();
          if (savesPath != null) {
            final relativePath = await _calculateSyncRelativePath(
              game,
              file,
              savesPath,
              explicitSystemFolder: game.systemFolderName,
            );
            if (relativePath == null) {
              NeoSyncProvider._log.w(
                'Pre-launch upload skipped for ${game.name}: no sync path',
              );
              return;
            }

            final parsed = CloudPathBuilder.parse(relativePath);
            final result = await _neoSyncService.syncFile(
              file,
              game.name,
              customFilename: relativePath,
              systemId: parsed?.system ?? game.systemFolderName,
              emulatorId: parsed?.emulatorSlug,
              gameHash: await _resolveGameHashForUpload(game),
              isState: false,
              scope: parsed?.scope,
            );

            if (result['success']) {
              // Actualizar estado después del sync
              await detectGameSaveFiles(game);
            }
          }
        }
      } else if (gameState.status == neo_sync.GameSyncStatus.cloudOnly &&
          gameState.cloudSave != null) {
        // Descargar save de la nube
        await restoreCloudBackup(gameState.cloudSave!);
        // Actualizar estado
        await detectGameSaveFiles(game);
      }
    } on QuotaExceededException {
      NeoSyncProvider._log.e(
        'Pre-launch sync failed: storage quota exceeded for ${game.name}',
      );
      // Actualizar el estado del juego a quota exceeded
      _updateGameSyncState(
        game.romname,
        game.name,
        neo_sync.GameSyncStatus.quotaExceeded,
      );
    } catch (e) {
      NeoSyncProvider._log.w('Error in pre-launch sync for ${game.name}: $e');
    } finally {
      _launchDeadline = null;
    }
  }

  /// Sincroniza saves después de cerrar un juego (al estilo Steam)
  Future<void> syncGameSavesAfterClose(GameModel game) async {
    if (!isNeoSyncAuthenticated) return;
    if (game.cloudSyncEnabled != true) return;

    try {
      // Pequeña pausa para asegurar que el juego haya terminado de escribir saves
      await Future.delayed(const Duration(seconds: 1));

      // Detectar saves actuales (pueden haber cambiado durante el juego)
      await detectGameSaveFiles(game);

      final gameState = _gameSyncStates[game.romname];
      if (gameState == null || gameState.localSave == null) return;

      // Subir el save local (puede haber sido modificado durante el juego)
      final file = File(gameState.localSave!.filePath);
      if (file.existsSync()) {
        // Calcular la ruta relativa correcta
        final savesPath = await _getRetroArchSavesPath();
        if (savesPath != null) {
          final relativePath = await _calculateSyncRelativePath(
            game,
            file,
            savesPath,
            explicitSystemFolder: game.systemFolderName,
          );
          if (relativePath == null) {
            NeoSyncProvider._log.w(
              'Post-game upload skipped for ${game.name}: no sync path',
            );
            return;
          }

          final parsed = CloudPathBuilder.parse(relativePath);
          final result = await _neoSyncService.syncFile(
            file,
            game.name,
            customFilename: relativePath,
            systemId: parsed?.system ?? game.systemFolderName,
            emulatorId: parsed?.emulatorSlug,
            gameHash: await _resolveGameHashForUpload(game),
            isState: false,
            scope: parsed?.scope,
          );

          if (result['success']) {
            // Actualizar estado después del sync
            await detectGameSaveFiles(game);
          }
        }
      }
    } on QuotaExceededException {
      NeoSyncProvider._log.e(
        'Post-game sync failed: storage quota exceeded for ${game.name}',
      );
      // Actualizar el estado del juego a quota exceeded
      _updateGameSyncState(
        game.romname,
        game.name,
        neo_sync.GameSyncStatus.quotaExceeded,
      );
    } catch (e) {
      NeoSyncProvider._log.w('Error in post-game sync for ${game.name}: $e');
    }
  }

  /// Restaura un backup desde la nube (descarga y sobreescribe local)
  Future<void> restoreCloudBackup(NeoSyncFile cloudFile) async {
    try {
      final savesPath = await _getRetroArchSavesPath();
      if (savesPath == null) {
        throw Exception('RetroArch saves directory not found');
      }

      String targetPath;
      final fileName = cloudFile.fileName.replaceAll('\\', '/'); // Normalize

      // Manejo específico para Dreamcast VMU
      if (fileName.toLowerCase().contains('vmu_save') &&
          fileName.toLowerCase().endsWith('.bin')) {
        final systemDir = await _getRetroArchSystemPath();
        targetPath = path.join(
          systemDir ?? savesPath,
          'dc',
          path.basename(fileName),
        );
      } else if (fileName.startsWith('saves/')) {
        // Relativo a raiz (subir un nivel desde savesPath)
        final rootPath = Directory(savesPath).parent.path;
        targetPath = path.join(rootPath, fileName);
      } else {
        // Relativo a savesPath
        targetPath = path.join(savesPath, fileName);
      }

      final file = File(targetPath);
      NeoSyncProvider._log.i('Restore: ${cloudFile.fileName} -> ${file.path}');
      // Asegurar directorio existe
      await file.parent.create(recursive: true);

      // Usar el método común de descarga
      await _downloadCloudFile(cloudFile, file);
    } catch (e) {
      NeoSyncProvider._log.e('Restore: FAILED for ${cloudFile.fileName}: $e');
      rethrow;
    }
  }
}

/// Builds the [NeoSyncFile] that [NeoSyncCore.resolveLocalTargetPaths]
/// hands to the resolver for a provider-relative name like `saves/<core>/<file>`
/// or `states/<file>`.
///
/// The resolver places by [NeoSyncFile.type] and joins [NeoSyncFile.filePath]
/// onto the save or state directory, because NeoSync's backend stores the path
/// relative to that directory. A caller-supplied name still carries its
/// `saves/`/`states/` root, so that root becomes the type and is stripped here;
/// passing it through wrote RomM saves to `<saves>/saves/<core>/` and states
/// under the saves directory (issue #511).
@visibleForTesting
NeoSyncFile localTargetCloudFile(GameModel game, String relativeName) {
  final match = RegExp(r'^(saves|states)[/\\](.+)$').firstMatch(relativeName);
  final isState = match?.group(1) == 'states';
  final rest = match?.group(2) ?? relativeName;
  return NeoSyncFile(
    id: '',
    fileName: rest,
    filePath: rest,
    fileSize: 0,
    gameName: game.name,
    uploadedAt: DateTime.now(),
    userId: '',
    type: isState ? 'state' : 'save',
  );
}
