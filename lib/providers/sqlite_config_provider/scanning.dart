part of '../sqlite_config_provider.dart';

/// ROM scanning and system detection for [SqliteConfigProvider].
///
/// Owns filesystem ROM scanning (foreground + background), per-system rescans,
/// ROM-folder management, and loading/refreshing the detected/available system
/// lists from the database. Extracted verbatim from the host, which retains the
/// class declaration, all state, lifecycle wiring, and secondary-display logic.
/// `notifyListeners()` routes through the host's `_notify()` bridge and the
/// static `_log` is host-qualified (both required from an extension).
/// Bell entry for ROM roots that stopped resolving. A fixed id so consecutive
/// scans replace the warning in place rather than stacking one per launch.
const String _unreachableRomFoldersNotificationId = 'rom-folders-unreachable';

/// Bell entry for a ROM folder refused because its path was transient.
const String _transientRomFolderNotificationId = 'rom-folder-transient';

/// Bell entry for a desktop scan that had no ROM root left to walk. A fixed id
/// for the same reason as [_unreachableRomFoldersNotificationId].
const String _noRomFoldersNotificationId = 'rom-folders-missing';

/// Bell entry for Android ROM folders that are configured but hold no
/// persistent SAF grant, so their games silently scan as empty. A fixed id so
/// consecutive scans replace the warning in place.
const String _safPermissionNotificationId = 'rom-folders-saf-permission';

extension SqliteConfigScanning on SqliteConfigProvider {
  /// Registers a new filesystem directory as a ROM source.
  ///
  /// Automatically triggers a system detection scan unless [scan] is set to false.
  Future<void> addRomFolder(String folderPath, {bool scan = true}) async {
    if (folderPath.isEmpty) return;
    if (_config.romFolders.contains(folderPath)) return;
    if (_config.romFolders.length >= 5) return;

    // A desktop-portal document path outlives neither the reboot nor the grant
    // that produced it, so storing one hands the user a library that silently
    // empties later. Refuse it at the door and say why.
    if (isTransientPortalPath(folderPath)) {
      _error =
          'That folder came from a temporary desktop-portal path '
          '($folderPath) and would stop working after a restart. '
          'Pick it again with the built-in folder browser.';
      SqliteConfigProvider._log.w(
        'Rejected transient portal ROM folder: $folderPath',
      );
      // Settings > Directories, the screen this is normally reached from,
      // never reads `_error` — without the bell the pick would simply appear
      // to do nothing, which is no better than the silent failure being fixed.
      GlobalNotificationService().show(
        id: _transientRomFolderNotificationId,
        title: 'ROM folder not added',
        message: _error!,
        type: GlobalNotificationType.error,
      );
      _notify();
      return;
    }

    try {
      _setLoading(true);
      final newList = [..._config.romFolders, folderPath];
      _config = _config.copyWith(
        romFolders: newList,
        lastScan: DateTime.now(),
        setupCompleted: true,
      );
      await SqliteConfigService.saveConfig(_config);
      if (scan) {
        await scanSystems();
      }
      _notify();
    } catch (e) {
      _error = 'Error adding ROM folder: $e';
      SqliteConfigProvider._log.e('$_error');
    } finally {
      _setLoading(false);
    }
  }

  /// Removes a registered ROM directory and purges associated ROM entries from the database.
  Future<void> removeRomFolder(String folderPath) async {
    try {
      _setLoading(true);

      // 1. Surgical cleanup in the DB before updating the config
      await GameRepository.deleteRomsByFolderPath(folderPath);

      // 2. Update local and persistent configuration
      final newList = _config.romFolders.where((p) => p != folderPath).toList();
      _config = _config.copyWith(romFolders: newList, lastScan: DateTime.now());
      await SqliteConfigService.saveConfig(_config);

      // 3. Decide whether to scan or just finish
      if (newList.isNotEmpty) {
        // Folders still remain, scan to ensure consistency
        await scanSystems();
      } else {
        await SystemRepository.updateDetectedSystems([]);
        await _loadDetectedSystems(); // Reload local list (now filtered)
      }

      _notify();
    } catch (e) {
      _error = 'Error removing ROM folder: $e';
      SqliteConfigProvider._log.e('$_error');
    } finally {
      _setLoading(false);
    }
  }

  /// On Android, every configured ROM root must hold its own persistent SAF
  /// grant for the scan to read it. A folder can end up configured without one
  /// (a path entered outside the SAF picker, or a grant revoked in system
  /// settings), and the scan then silently walks it as if it were empty and
  /// every game inside is lost — exactly the "Switch games on a second disk
  /// never show up" report.
  ///
  /// Rather than opening the system picker from inside a background scan
  /// (which risks a hung `_isScanning` if the activity is recreated while the
  /// picker is up, and re-prompts on every scan because a re-picked parent
  /// rarely matches the stored URI), this just tells the user what is wrong and
  /// where to fix it via a bell notification. The re-grant happens on the
  /// Settings > Directories screen, where a picker can never stall the scan.
  ///
  /// Note: even with All-Files-Access held, the native fast walk only covers
  /// the primary volume on API 30+; folders on SD/USB volumes still fall back
  /// to the SAF walk and need their own grant, so every configured root is
  /// checked here regardless of the broad-permission flag.
  Future<void> _ensureAndroidSafPermissions() async {
    if (!Platform.isAndroid) return;

    final missing = <String>[];
    for (final folder in _config.romFolders) {
      if (!folder.startsWith('content://')) continue;
      final ok = await SafDirectoryService.hasPermission(folder);
      if (!ok) {
        missing.add(folder);
      }
    }

    if (missing.isEmpty) {
      GlobalNotificationService().dismiss(_safPermissionNotificationId);
      return;
    }

    final plural = missing.length == 1 ? '' : 's';
    SqliteConfigProvider._log.w(
      'SAF permission missing for ${missing.length} ROM folder(s): $missing',
    );
    GlobalNotificationService().show(
      id: _safPermissionNotificationId,
      title: 'ROM folder$plural missing storage access',
      message:
          '${missing.length} ROM folder$plural cannot be read. '
          'Re-grant access in Settings > Directories.',
      type: GlobalNotificationType.error,
    );
  }

  /// Scans the registered ROM folders to detect supported emulation systems.
  ///
  /// Orchestrates permission checks, platform identification, and background
  /// ROM file scanning. Supports special handling for Android-specific
  /// virtual systems (e.g., 'Android Apps').
  Future<void> scanSystems({bool waitForAndroidStorage = false}) async {
    // Allow scanning even if there are no folders (to clean systems or inject Android Apps)
    // if (_config.romFolders.isEmpty) return;

    // Protection against concurrent calls
    if (_isScanning) {
      SqliteConfigProvider._log.w(
        'Already scanning, ignoring duplicate call...',
      );
      return;
    }

    _setScanning(true);
    _error = null;
    // Re-probe the fast SAF walk once per scan: the permission behind it can be
    // granted or revoked between scans, but not during one.
    SafDirectoryService.resetFastWalkAvailability();
    // Settle fast-scan mode before anything reports it. `_config.romFolders`
    // cannot change for the rest of this call, so deciding here is the same
    // decision the scan phase used to make further down — except the line
    // below now describes the scan actually about to run. It used to print the
    // value left by provider init, so the first scan after a folder was added
    // logged `romFolders=1, fastScan=true`: self-contradictory, and misleading
    // in exactly the situation this log line exists to diagnose.
    _isFastScan = _config.romFolders.isEmpty;
    SqliteConfigProvider._log.i(
      'scanSystems starting (romFolders=${_config.romFolders.length}, '
      'fastScan=$_isFastScan)',
    );

    // Verify permissions in Android BEFORE scanning
    if (Platform.isAndroid) {
      // On Android 13+, hasBroadPermissions returns true (simulated).
      // For older versions, we check if we have broad permissions OR if we use SAF.
      final hasBroadPermissions =
          await PermissionService.hasStoragePermissions();
      final hasSafFolders = _config.romFolders.any(
        (f) => f.startsWith('content://'),
      );

      // Only block if no ONE has access and we have folders configured.
      if (!hasBroadPermissions &&
          !hasSafFolders &&
          _config.romFolders.isNotEmpty) {
        _error =
            'Storage access required. Please select a ROM folder using the file picker.';
        SqliteConfigProvider._log.e('$_error');
        _setScanning(false);
        _notify();
        return;
      }

      // Verify access to directories
      for (final path in _config.romFolders) {
        // On Android 13+ with SAF, canAccessDirectory now returns true for content://
        final canAccess = await PermissionService.canAccessDirectory(path);
        if (!canAccess) {
          _error =
              'Cannot access ROM folder: $path. Please check storage permissions.';
          SqliteConfigProvider._log.e('$_error');
          _setScanning(false);
          _notify();
          return;
        }
      }

      // Detect configured folders that lost their persistent SAF grant and
      // tell the user, otherwise the scan walks them as empty and drops the
      // games inside. Guarded so a surprise failure here can never leave the
      // scan half-started (`_isScanning` is only cleared in the finally below).
      try {
        await _ensureAndroidSafPermissions();
      } catch (e) {
        SqliteConfigProvider._log.e(
          'Error checking SAF permissions before scan: $e',
        );
      }

      // On some handhelds launched as the default launcher, Android starts the
      // app before the SD card is ready. A scan at that point finds no folders
      // and subsequently prunes every existing ROM record. Only delay the
      // automatic startup scan, and only when a previous library exists: manual
      // scans must remain immediate and an intentionally empty library must not
      // be held up.
      if (waitForAndroidStorage &&
          await _hasStoredRoms() &&
          !await _waitForAndroidRomFolders()) {
        _scanStatus = 'ROM storage is not ready; existing games were kept.';
        SqliteConfigProvider._log.w(
          'Startup scan skipped because Android ROM storage never became ready',
        );
        _setScanning(false);
        _notify();
        return;
      }
    }

    // A configured ROM root can stop resolving between scans: an unmounted
    // drive, a deleted folder, or a desktop-portal document path whose grant
    // expired. Off Android nothing verified that until now, so the walk found
    // nothing and the prune phase deleted every ROM row — indistinguishable
    // from data loss to the user. Keep the library and explain instead.
    if (!Platform.isAndroid && _config.romFolders.isNotEmpty) {
      final unreachable = <String>[];
      for (final folder in _config.romFolders) {
        if (!await Directory(folder).exists()) unreachable.add(folder);
      }
      if (unreachable.isNotEmpty && await _hasStoredRoms()) {
        // A portal grant cannot be restored by plugging anything back in, so
        // that case needs different advice from a missing drive.
        final advice = unreachable.any(isTransientPortalPath)
            ? 'That path came from a temporary desktop-portal grant and '
                  'cannot come back — remove it in Settings > Directories '
                  'and add the folder again.'
            : 'Reconnect the drive, or remove the folder in '
                  'Settings > Directories.';
        final plural = unreachable.length == 1 ? '' : 's';
        _error =
            'Cannot reach ROM folder$plural: ${unreachable.join(', ')}. '
            'Existing games were kept. $advice';
        SqliteConfigProvider._log.e(
          'Scan aborted, ${unreachable.length} unreachable ROM folder(s); '
          'library preserved: ${unreachable.join(', ')}',
        );
        // The preserved library is worth nothing if the screen behind this
        // stays blank. `_scanCompleted` is only set at the far end of a
        // successful scan, and the systems screen renders neither the library
        // nor the setup prompt until it flips — an early return without it
        // leaves an empty page, which is the very symptom being fixed.
        _scanCompleted = true;
        // `_error` reaches only the initial-setup widget, which is shown when
        // no systems are detected — impossible here, since this branch needs
        // stored ROMs. The bell is the one surface that both survives the scan
        // ending and does not need a BuildContext from this layer.
        GlobalNotificationService().show(
          id: _unreachableRomFoldersNotificationId,
          title: 'ROM folder$plural unavailable',
          message: _error!,
          type: GlobalNotificationType.error,
        );
        _setScanning(false);
        _notify();
        return;
      }
      if (unreachable.isNotEmpty) {
        // No library at risk, so scanning on is safe — but still say so.
        SqliteConfigProvider._log.w(
          'Unreachable ROM folder(s) ignored (no stored ROMs): '
          '${unreachable.join(', ')}',
        );
      }
    }

    // The same silence covers the case where no root is configured at all.
    // `_isFastScan` below turns an empty folder list into a scan that walks
    // nothing and still reports success: that is deliberate on Android, where
    // the virtual Android Apps systems are injected regardless, but off
    // Android it leaves nothing to scan and no way to tell. The list can empty
    // itself without the user removing anything — a blanket config save that
    // carried no folders (fixed in #316, but older databases already lost
    // theirs), or a `loadConfig` failure falling back to `ConfigModel.empty` —
    // while Settings > Directories reads the folder table directly and so
    // still shows a folder that is configured as far as the user can tell.
    // Every scan is then a no-op that flickers past, and the library keeps
    // working from stored `rom_path` rows, so nothing new is ever picked up.
    if (!Platform.isAndroid &&
        _config.romFolders.isEmpty &&
        await _hasStoredRoms()) {
      _error =
          'No ROM folder is configured, so there was nothing to scan. '
          'Existing games were kept. Add your ROM folder again in '
          'Settings > Directories.';
      SqliteConfigProvider._log.e(
        'Scan aborted, no ROM folders configured while the library holds '
        'ROMs; library preserved',
      );
      // Same reasoning as the unreachable-roots branch above: flip
      // `_scanCompleted` so the systems screen renders the preserved library,
      // and report through the bell because `_error` only reaches the
      // initial-setup widget.
      _scanCompleted = true;
      GlobalNotificationService().show(
        id: _noRomFoldersNotificationId,
        title: 'No ROM folder configured',
        message: _error!,
        type: GlobalNotificationType.error,
      );
      _setScanning(false);
      _notify();
      return;
    }

    // Getting this far means nothing blocked the scan, so retire a warning
    // left by an earlier one instead of leaving the user chasing a folder they
    // have already reconnected or removed.
    GlobalNotificationService().dismiss(_unreachableRomFoldersNotificationId);
    GlobalNotificationService().dismiss(_noRomFoldersNotificationId);

    // Initialize progress
    _totalSystemsToScan = 0;
    _scannedSystemsCount = 0;
    _scanProgress = 0.0;
    _scanStatus = 'Please Wait...';

    try {
      // Reload from synchronized database during initialization
      await _loadAvailableSystems();

      // Fast Scan mode (no ROM folders) was settled before the opening log
      // line, so that it and this agree.
      final bool isFastScan = _isFastScan;

      // Detect systems
      List<SystemModel> detectedSystems;

      if (Platform.isAndroid) {
        // On Android, do NOT use File IO based detection
        // Systems will be detected automatically during SAF scanning
        detectedSystems = [];
      } else {
        // On Desktop, use File IO based detection
        detectedSystems = await SqliteConfigService.detectSystems(
          romFolders: _config.romFolders,
          availableSystems: _availableSystems,
        );
      }

      // Determine the systems to use for initial detection
      List<SystemModel> systemsForMapping = _availableSystems;

      // Filter systems if it's a Fast Scan for instant progress
      if (isFastScan) {
        // Only include those that auto-detect or are virtual depending on platform
        final List<String> fastScanFolders = Platform.isAndroid
            ? ['android']
            : [];

        systemsForMapping = _availableSystems.where((s) {
          return fastScanFolders.contains(s.folderName);
        }).toList();

        // Also ensure that detectedSystems only contains these if we were on desktop
        detectedSystems = detectedSystems
            .where((s) => fastScanFolders.contains(s.folderName))
            .toList();
      }

      // On Android, inject virtual systems (Android Apps/Games) if not detected by folders
      if (Platform.isAndroid) {
        final androidSystems = [
          {'folder': 'android'},
          {'folder': 'all'},
        ];

        for (final sysInfo in androidSystems) {
          final sysFolder = sysInfo['folder']?.toString() ?? 'android';

          // If the system was not detected by folder
          if (!detectedSystems.any((s) => s.folderName == sysFolder)) {
            try {
              // Search in available systems (only by folder name to avoid corrupt ID collisions)
              final system = _availableSystems.firstWhere(
                (s) => s.folderName == sysFolder,
                orElse: () =>
                    throw StateError('System not found in available list'),
              );

              // Add it to the list of detected so that it is scanned
              // CRITICAL: Force the correct folder name to ensure asset resolution works
              // even if the database has an old name (like 'android')
              final systemToInject = system.copyWith(folderName: sysFolder);

              detectedSystems = [...detectedSystems, systemToInject];
            } catch (e) {
              SqliteConfigProvider._log.e('Failed to inject $sysFolder: $e');
              // If it doesn't exist in available (shouldn't happen), ignore
            }
          }
        }
      }

      // Update last scan timestamp surgically to avoid wiping detectedSystems in DB
      final now = DateTime.now();
      await ConfigRepository.saveUserConfig(lastScan: now.toIso8601String());

      final systemNames = detectedSystems.map((s) => s.folderName).toList();
      _config = _config.copyWith(
        lastScan: now,
        // On Android, keep existing detectedSystems while scanning in background
        // to maintain UI stability and persistence.
        detectedSystems: Platform.isAndroid
            ? _config.detectedSystems
            : systemNames,
      );

      // CRITICAL: On Android, pre-filter systems based on existing physical folders
      // to avoid scanning all 72 systems if the user only has a few.
      if (Platform.isAndroid) {
        final Map<String, Map<String, String>> existingFoldersMap =
            await SqliteDatabaseService.getExistingSubdirectories(
              _config.romFolders,
            );

        // Use lowercase for case-insensitive matching
        final Set<String> allExistingFolders = existingFoldersMap.values
            .expand((m) => m.keys.map((k) => k.toLowerCase()))
            .toSet();

        final filteredSystems = systemsForMapping.where((system) {
          // A system exists if its primary folder or any of its alternatives exists
          final lowerPrimary = system.folderName.toLowerCase();
          if (allExistingFolders.contains(lowerPrimary)) return true;

          for (final altFolder in system.folders) {
            if (allExistingFolders.contains(altFolder.toLowerCase())) {
              return true;
            }
          }

          // Special case: Android and ALL are always included for scanning
          if (system.folderName == 'android' || system.folderName == 'all') {
            return true;
          }

          return false;
        }).toList();

        SqliteConfigProvider._log.i(
          'AndroidPreFilter: ${allExistingFolders.length} existing subfolder(s); '
          '${filteredSystems.length} system(s) matched',
        );

        // Android Fix: Combine filtered systems with legacy systems from DB
        // so that deleted systems get a chance to be pruned.
        final legacySystems = await SystemRepository.getDetectedSystems();
        final Map<String, SystemModel> combinedMap = {};

        for (final s in filteredSystems) {
          combinedMap[s.id!] = s;
        }

        for (final s in legacySystems) {
          if (!combinedMap.containsKey(s.id)) {
            combinedMap[s.id!] = s;
          }
        }

        _detectedSystems = combinedMap.values.toList();
      } else {
        // On Desktop, combine systems detected by folder with systems
        // that are already in the database (legacy) to ensure they are pruned
        // if their folder was moved or deleted.
        final legacySystems = await SystemRepository.getDetectedSystems();
        final Map<String, SystemModel> combinedMap = {};

        // Add systems detected now
        for (final s in detectedSystems) {
          combinedMap[s.id!] = s;
        }

        // Add systems that were already there (if not already added)
        for (final s in legacySystems) {
          if (!combinedMap.containsKey(s.id)) {
            combinedMap[s.id!] = s;
          }
        }

        _detectedSystems = combinedMap.values.toList();
      }

      // If app was killed by OS while an emulator was running, skip ROM
      // scanning so the user can return to the system browser without delay.
      final skipScan = await GameSessionPersistence.consumeSkipStartupScan();
      if (skipScan) {
        SqliteConfigProvider._log.i(
          'Skipping ROM scan because app was killed during a game session',
        );
      } else {
        _totalSystemsToScan = _detectedSystems.length;
        _scanStatus = 'Scanning ROMs...';
        await _scanRomsInBackground();
      }

      // Apply preferred order
      _sortDetectedSystems();

      _scanCompleted = true;
    } catch (e) {
      _error = 'Error scanning ROMs: $e';
      SqliteConfigProvider._log.e('$_error');
    } finally {
      _setScanning(false);
      _notify();
    }
  }

  /// Returns whether the local library contains ROMs that a premature scan
  /// could otherwise remove as missing.
  Future<bool> _hasStoredRoms() async {
    final db = await SqliteService.getDatabase();
    final rows = await db.rawQuery('SELECT EXISTS(SELECT 1 FROM user_roms)');
    return rows.isNotEmpty && rows.first.values.first == 1;
  }

  /// Waits briefly for configured Android ROM roots to expose their
  /// directories. SAF can report a valid persisted permission while the
  /// physical SD volume is still mounting, so [canAccessDirectory] alone is
  /// insufficient.
  ///
  /// Every root that already holds games has to come up, not just one: with
  /// ROMs split between internal storage and an SD card, internal storage is
  /// ready at once while the card is still mounting. Returns false only when
  /// no root came up at all; a root still missing after the wait keeps its
  /// games through the scan's own offline-root guard.
  Future<bool> _waitForAndroidRomFolders() async {
    const retryDelay = Duration(seconds: 3);
    const maxAttempts = 10;

    final rootsWithGames = <String>{
      for (final root in _config.romFolders)
        if (await GameRepository.hasRomsUnderFolder(root)) root,
    };

    for (var attempt = 1; attempt <= maxAttempts; attempt++) {
      final folders = await SqliteDatabaseService.getExistingSubdirectories(
        _config.romFolders,
      );
      final offline = SqliteDatabaseService.offlineRomRoots(folders);
      final anyOnline = offline.length < folders.length;
      if (anyOnline && !offline.any(rootsWithGames.contains)) {
        return true;
      }
      if (attempt == maxAttempts) {
        if (anyOnline) {
          SqliteConfigProvider._log.w(
            'ROM folder(s) still not ready after the startup wait, scanning '
            'the rest and keeping their games: '
            '${offline.where(rootsWithGames.contains).join(', ')}',
          );
        }
        return anyOnline;
      }

      _scanStatus = 'Waiting for ROM storage ($attempt/$maxAttempts)...';
      _notify();
      await Future<void>.delayed(retryDelay);
    }
    return false;
  }

  /// Executes a full ROM scan across all detected systems in the background.
  ///
  /// This multi-phase process identifies new ROMs, prunes missing entries,
  /// and updates system-level statistics while maintaining UI responsiveness
  /// via batch processing.
  Future<void> _scanRomsInBackground() async {
    // Protection against concurrent executions
    if (_isScanningRoms) {
      return;
    }

    _isScanningRoms = true;

    try {
      // Snapshot of systems to scan to avoid concurrent modification issues
      // as refreshSystem might remove empty systems from _detectedSystems
      final systemsToScan = List<SystemModel>.from(_detectedSystems);

      // Pre-fetch subdirectories map to optimize scanning (avoids re-listing root)
      final rootFoldersMap =
          await SqliteDatabaseService.getExistingSubdirectories(
            _config.romFolders,
          );

      const batchSize = 1; // Process 1 system at a time for better granularity

      // The scan has two phases:
      // Phase 1: Scan ROMs (95% of progress: 0.0 - 0.95)
      // Phase 2: Update DB (5% of progress: 0.95 - 1.0)
      const scanPhaseWeight = 0.95;

      for (int i = 0; i < systemsToScan.length; i += batchSize) {
        final endIndex = (i + batchSize < systemsToScan.length)
            ? i + batchSize
            : systemsToScan.length;

        final batch = systemsToScan.sublist(i, endIndex);

        // Update progress state
        _scanStatus = '${batch.map((s) => s.realName).join(', ')}...';
        _notify();

        // Process batch in parallel
        await Future.wait(
          batch.map(
            (system) => _scanSystemRoms(system, rootFoldersMap: rootFoldersMap),
          ),
        );

        // Update progress of the scanning phase (0.0 - 0.95)
        _scannedSystemsCount += batch.length;
        final scanPhaseProgress = _scannedSystemsCount / _totalSystemsToScan;
        _scanProgress = (scanPhaseProgress * scanPhaseWeight).clamp(
          0.0,
          scanPhaseWeight,
        );

        _notify();

        // Yield to the event loop so the progress UI can paint between systems.
        // This used to be a fixed 100 ms sleep, which cost 3.3 s (65% of the
        // whole scan) across 37 systems while throttling nothing — the loop is
        // already await-serialized. A zero-duration yield keeps the paint
        // opportunity at no measurable cost.
        if (endIndex < _detectedSystems.length) {
          await Future<void>.delayed(Duration.zero);
        }
      }

      // Phase 2: Update the systems list (0.95 - 1.0)
      _scanStatus = 'Updating systems list...';
      _scanProgress = scanPhaseWeight; // 95%
      _notify();

      // Update user_detected_systems table: only keep systems with compatible ROMs.
      // Query actual ROM counts instead of reading stale user_detected_systems.
      final allSystems = await SystemRepository.getAllSystems();
      final systemsToKeep = <SystemModel>[];

      // Count systems with games, excluding virtual/media systems for 'all' logic
      int emulatorSystemsWithGamesCount = 0;
      final virtualSystems = [
        'android',
        'music',
        'all',
        'steam',
        SystemFolderNames.collections,
      ];

      // Build the set of existing folders once for efficient lookup.
      final allExistingFolders = rootFoldersMap.values
          .expand((m) => m.keys.map((k) => k.toLowerCase()))
          .toSet();

      // Hidden games per system, in a single query. They stay in the ROM count
      // that decides whether a system is kept (otherwise a system whose games
      // are all hidden would vanish, taking the unhide UI with it) but are
      // subtracted from the count shown on the system card, which has to match
      // the list the user actually sees.
      final hiddenBySystem = await GameRepository.getHiddenRomCountsBySystem();

      // First pass: collect all systems except the ones the passes below add on
      // their own terms ('all', 'collections'). Skipping 'collections' here also
      // stops a user ROM folder that happens to be called "collections" from
      // adding the card twice.
      for (final system in allSystems) {
        if (system.folderName == 'all') continue;
        if (system.folderName == SystemFolderNames.collections) continue;

        final romCount = await SystemRepository.getRomCountForSystem(
          system.id!,
        );

        bool hasFolderWhenNonRecursive = false;
        if (!system.recursiveScan) {
          final lowerPrimary = system.folderName.toLowerCase();
          if (allExistingFolders.contains(lowerPrimary)) {
            hasFolderWhenNonRecursive = true;
          } else {
            for (final altFolder in system.folders) {
              if (allExistingFolders.contains(altFolder.toLowerCase())) {
                hasFolderWhenNonRecursive = true;
                break;
              }
            }
          }
        }

        final bool isAndroidVirtual =
            (system.folderName == 'android' && Platform.isAndroid);

        if (romCount > 0 || hasFolderWhenNonRecursive || isAndroidVirtual) {
          final visibleRomCount = romCount - (hiddenBySystem[system.id!] ?? 0);
          systemsToKeep.add(system.copyWith(romCount: visibleRomCount));

          // Increment count for 'all' logic if it's a real emulator system with games
          if (romCount > 0 && !virtualSystems.contains(system.folderName)) {
            emulatorSystemsWithGamesCount++;
          }
        }
      }

      // Second pass: decide if we add 'all'
      if (emulatorSystemsWithGamesCount > 0) {
        final allSystem = allSystems.firstWhere((s) => s.folderName == 'all');
        final romCount = await SystemRepository.getRomCountForSystem(
          allSystem.id!,
        );
        systemsToKeep.add(allSystem.copyWith(romCount: romCount));
      }

      // Third pass: add 'favorites' virtual system if there are favorite games (excluding music)
      final db = await SqliteService.getDatabase();
      final favResult = await db.rawQuery(
        "SELECT COUNT(*) as count FROM user_roms WHERE is_favorite = 1 AND app_system_id != 'music'",
      );
      final hasFavorites =
          (int.tryParse(favResult.first['count'].toString()) ?? 0) > 0;
      if (hasFavorites) {
        try {
          final favSystem = allSystems.firstWhere(
            (s) => s.folderName == SystemFolderNames.favorites,
          );
          systemsToKeep.add(favSystem);
        } catch (_) {
          // favorites system not found in available systems, ignore
        }
      }

      // Fourth pass: add the 'collections' virtual system. Unlike favorites this
      // is unconditional (D5 in docs/collections/05-decisions-and-risks.md):
      // collections live in user_collections, not in the ROM scan, and the card
      // is the only place the user can create their first one — hiding it while
      // empty would leave no way in.
      try {
        final collectionsSystem = allSystems.firstWhere(
          (s) => s.folderName == SystemFolderNames.collections,
        );
        systemsToKeep.add(collectionsSystem);
      } catch (_) {
        // 'collections' is missing from app_systems (an install whose systems
        // bundle predates it); nothing to add until the next systems sync.
      }

      final folderNames = systemsToKeep.map((s) => s.folderName).toList();
      await SystemRepository.updateDetectedSystems(folderNames);

      await _refreshDetectedSystemsFromDatabase();

      // Completar al 100%
      _scanStatus = 'ROMs Scanned';
      _scanProgress = 1.0;
      _notify();
    } catch (e) {
      SqliteConfigProvider._log.e('Error scanning ROMs: $e');
      _scanStatus = 'Error scanning ROMs';
      _notify();
    } finally {
      _isScanningRoms = false; // Liberar el lock
    }
  }

  /// Performs an isolated scan for a specific system.
  Future<ScanSummary> _scanSystemRoms(
    SystemModel system, {
    Map<String, Map<String, String>>? rootFoldersMap,
  }) async {
    try {
      // Allow scanning for Android system even if no ROM folders are selected
      if (_config.romFolders.isEmpty && system.folderName != 'android') {
        return ScanSummary(
          added: 0,
          removed: 0,
          total: 0,
          systemName: system.realName,
        );
      }

      final summary = await SqliteDatabaseService.scanSystemRoms(
        system,
        _config.romFolders,
        ignoreHiddenFiles: _config.ignoreHiddenFiles,
        rootFoldersMap: rootFoldersMap,
      );

      SqliteConfigProvider._log.i(
        'ScanResult[${system.realName}]: added=${summary.added} '
        'removed=${summary.removed} total=${summary.total}',
      );

      // Update ROM count in system
      await refreshSystem(system, rootFoldersMap: rootFoldersMap);

      // Trigger Steam scraper if it's the Steam system
      if (system.folderName == 'steam') {
        // We don't pass 'provider' here because SqliteConfigProvider is not SqliteDatabaseProvider
        // The service will handle UI refreshes independently if needed, or we can look into passing a callback
        SteamScraperService.scrapeSteamGames();
      }

      return summary;
    } catch (e) {
      SqliteConfigProvider._log.e('Error scanning ${system.realName}: $e');
      return ScanSummary(
        added: 0,
        removed: 0,
        total: 0,
        systemName: system.realName,
      );
    }
  }

  /// Refreshes the metadata and detection status for a specific system.
  ///
  /// Implements "incremental persistence" to ensure systems remain visible
  /// if they have ROMs or physical directories, while pruning empty systems.
  Future<void> refreshSystem(
    SystemModel system, {
    Map<String, Map<String, String>>? rootFoldersMap,
  }) async {
    try {
      // Reload the full system from the DB to ensure we have the most recent
      // configuration (such as recursiveScan) and the correct romCount.
      final updatedSystem = await SystemRepository.getSystemByFolderName(
        system.folderName,
      );
      if (updatedSystem == null) {
        SqliteConfigProvider._log.w(
          'System ${system.folderName} not found in DB during refresh',
        );
        return;
      }

      // Determine whether the system's folder still physically exists.
      // We only need this when recursive scan is OFF: if the folder exists but
      // romCount == 0 it means all ROMs live in sub-folders and the user must
      // stay able to re-enable recursive scan from the system settings dialog.
      bool hasFolderWhenNonRecursive = false;
      if (!updatedSystem.recursiveScan) {
        final effectiveRootFoldersMap =
            rootFoldersMap ??
            await SqliteDatabaseService.getExistingSubdirectories(
              _config.romFolders,
            );
        final allExistingFolders = effectiveRootFoldersMap.values
            .expand((m) => m.keys.map((k) => k.toLowerCase()))
            .toSet();
        final lowerPrimary = updatedSystem.folderName.toLowerCase();
        if (allExistingFolders.contains(lowerPrimary)) {
          hasFolderWhenNonRecursive = true;
        } else {
          for (final altFolder in updatedSystem.folders) {
            if (allExistingFolders.contains(altFolder.toLowerCase())) {
              hasFolderWhenNonRecursive = true;
              break;
            }
          }
        }
      }

      // Raw ROM count, hidden games included. [updatedSystem.romCount] is the
      // visible one (what the card shows), and pruning on it would make a
      // system whose games are all hidden disappear — along with the only place
      // to unhide them.
      final totalRomCount = await SystemRepository.getRomCountForSystem(
        updatedSystem.id!,
      );

      // INCREMENTAL PERSISTENCE: Keep a system when it has ROMs, when its
      // folder exists and recursive scan is explicitly OFF (user can re-enable),
      // or when it is a virtual system (android / all).
      final bool shouldKeep =
          totalRomCount > 0 ||
          hasFolderWhenNonRecursive ||
          (updatedSystem.folderName == 'android' && Platform.isAndroid) ||
          updatedSystem.folderName == 'all' ||
          updatedSystem.folderName == SystemFolderNames.favorites ||
          updatedSystem.folderName == SystemFolderNames.collections;

      if (shouldKeep) {
        await SystemRepository.addDetectedSystem(
          updatedSystem.id!,
          updatedSystem.folderName,
        );
      } else {
        // SYSTEM PRUNING: romCount == 0 and not a virtual system → remove
        // from DB and from the in-memory list so it disappears from the UI.
        await SystemRepository.removeDetectedSystem(updatedSystem.id!);
      }

      // Update in the local list
      final index = _detectedSystems.indexWhere(
        (s) => s.folderName == system.folderName,
      );

      if (index != -1) {
        if (shouldKeep) {
          // Increment the image version from the current in-memory instance
          // to force UI elements (images) to discard cache/rebuild
          final currentSystem = _detectedSystems[index];
          final newVersion = (currentSystem.imageVersion) + 1;

          _detectedSystems[index] = updatedSystem.copyWith(
            imageVersion: newVersion,
          );
        } else {
          // Surgical removal from the in-memory list so it disappears from the UI
          _detectedSystems.removeAt(index);
        }
        _notify();
      } else if (shouldKeep) {
        // If not found in memory but it should exist, load from DB to sync UI
        await _refreshDetectedSystemsFromDatabase();
        _notify();
      }
    } catch (e) {
      SqliteConfigProvider._log.e(
        'Error updating system state for ${system.realName}: $e',
      );
    }
  }

  /// Displays a platform-appropriate directory picker to select a ROM root folder.
  ///
  /// On Android, uses Scoped Storage (SAF) or a custom TV-optimized picker.
  Future<void> selectRomFolder({
    bool scan = true,
    BuildContext? context,
  }) async {
    try {
      String? result;

      if (Platform.isAndroid) {
        final isTV = await PermissionService.isTelevision();
        if (isTV && context != null && context.mounted) {
          result = await TvDirectoryPicker.show(context);
        } else {
          try {
            final uri = await PermissionService.requestFolderAccess();
            result = uri?.toString();
          } on PlatformException catch (e) {
            if (e.code == 'PICKER_FAILED' &&
                context != null &&
                context.mounted) {
              result = await TvDirectoryPicker.show(context);
            }
          }
        }
      } else if (context != null && context.mounted) {
        // Desktop: the platform picker, falling back to the in-app browser
        // where no XDG portal backend exists (SteamOS Game Mode).
        result = await TvDirectoryPicker.pickDirectory(
          context,
          dialogTitle: 'Select ROM Folder',
        );
      } else {
        // Desktop without a context to host the fallback browser.
        result = await FilePicker.getDirectoryPath(
          dialogTitle: 'Select ROM Folder',
        );
      }

      if (result != null) {
        await addRomFolder(result, scan: scan);
      }
    } catch (e) {
      SqliteConfigProvider._log.e('Error selecting rom folder: $e');
    }
  }

  /// Manually triggers a re-scan for a specific system's ROMs.
  Future<void> rescanSystem(SystemModel system) async {
    if (_config.romFolders.isEmpty) return;

    try {
      _setLoading(true);
      await _scanSystemRoms(system);
    } catch (e) {
      _error = 'Error rescanning ${system.realName}: $e';
      SqliteConfigProvider._log.e('$_error');
    } finally {
      _setLoading(false);
      _notify();
    }
  }

  /// Synchronizes the internal permission state with the Android OS.
  Future<void> refreshAllFilesAccess() async {
    if (!Platform.isAndroid) return;

    try {
      final hasAccess = await PermissionService.hasAllFilesAccess();
      if (hasAccess != _hasAllFilesAccess) {
        _hasAllFilesAccess = hasAccess;
        _notify();
      }
    } catch (e) {
      SqliteConfigProvider._log.e(
        'Error refreshing all files access in provider: $e',
      );
    }
  }

  /// Performs a background scan for a system without blocking UI notifications.
  Future<ScanSummary> rescanSystemSilent(SystemModel system) async {
    if (_config.romFolders.isEmpty) {
      return ScanSummary(
        added: 0,
        removed: 0,
        total: 0,
        systemName: system.realName,
      );
    }

    try {
      _isSilentScanning = true;
      _silentScannedSystem = system;
      _lastScanSummary = null;
      _notify();

      final summary = await _scanSystemRoms(system);
      _lastScanSummary = summary;

      return summary;
    } catch (e) {
      SqliteConfigProvider._log.e(
        'Error rescanning silent ${system.realName}: $e',
      );
      return ScanSummary(
        added: 0,
        removed: 0,
        total: 0,
        systemName: system.realName,
      );
    } finally {
      _isSilentScanning = false;
      _silentScannedSystem = null;
      _notify();
    }
  }

  /// Resets all user configurations and purges detected system metadata.
  Future<void> clearConfig() async {
    try {
      _setLoading(true);

      await SqliteConfigService.clearUserConfig();

      _config = ConfigModel.empty;
      _detectedSystems = [];
      _scanCompleted = false;

      // Reset progress
      _totalSystemsToScan = 0;
      _scannedSystemsCount = 0;
      _scanProgress = 0.0;
      _scanStatus = '';
    } catch (e) {
      _error = 'Error clearing config: $e';
      SqliteConfigProvider._log.e('$_error');
    } finally {
      _setLoading(false);
      _notify();
    }
  }

  /// Retrieves aggregate statistics (e.g., total systems, total games) from the database.
  Future<Map<String, int>> getQuickStats() async {
    try {
      return await SystemRepository.getSystemStats();
    } catch (e) {
      SqliteConfigProvider._log.e('Error getting stats: $e');
      return {};
    }
  }

  Future<void> _loadConfig() async {
    _config = await SqliteConfigService.loadConfig();
    if (_detectedSystems.isNotEmpty) {
      _sortDetectedSystems();
    }
  }

  Future<void> _loadAvailableSystems() async {
    _availableSystems = await SqliteConfigService.loadAvailableSystems();
  }

  /// Reloads system and emulator definitions from the DB into memory.
  /// Must be called after external DB updates (e.g., systems update download)
  /// so the next scan uses the latest definitions.
  Future<void> reloadSystemDefinitions() async {
    await Future.wait([_loadAvailableSystems(), _loadAvailableEmulators()]);
    _notify();
  }

  Future<void> _loadHiddenSystems() async {
    try {
      _hiddenSystems = await SystemRepository.getHiddenSystems();
    } catch (e) {
      SqliteConfigProvider._log.e('Error loading hidden systems: $e');
      _hiddenSystems = {};
    }
  }

  Future<void> toggleSystemHidden(String folderName) async {
    final isNowHidden = !_hiddenSystems.contains(folderName);
    if (isNowHidden) {
      _hiddenSystems = {..._hiddenSystems, folderName};
    } else {
      _hiddenSystems = _hiddenSystems.where((f) => f != folderName).toSet();
    }
    await SystemRepository.setSystemHidden(folderName, isNowHidden);
    _notify();
  }

  Future<void> _loadAvailableEmulators() async {
    _availableEmulators = await SqliteConfigService.loadAvailableEmulators();
  }

  Future<void> _loadDetectedSystems() async {
    // We always attempt to load detected systems from the database.
    // This ensures that even if _config.detectedSystems is stale or empty in memory,
    // we fetch the source of truth from the 'user_detected_systems' table.
    try {
      final systems = await SystemRepository.getDetectedSystems();
      _detectedSystems = systems;
      _sortDetectedSystems();
      SqliteConfigProvider._log.i(
        'Detected systems loaded from DB: ${systems.length}',
      );
      for (var s in systems) {
        SqliteConfigProvider._log.d(' - ${s.folderName}: ${s.romCount} ROMs');
      }

      // DEFENSIVE: Update _config if it differs from what was just loaded from DB
      final systemNames = systems.map((s) => s.folderName).toList();
      if (_config.detectedSystems.length != systemNames.length) {
        _config = _config.copyWith(detectedSystems: systemNames);
      }
      _notify();
    } catch (e) {
      SqliteConfigProvider._log.e('Error loading detected systems: $e');
    }
  }

  /// Guarantees the 'collections' virtual system is in `user_detected_systems`.
  ///
  /// The ROM scan adds it (fourth pass above), but a device with
  /// `scanOnStartup` off may go many launches without running one — and the
  /// Collections card is the only route to creating a first collection (D5), so
  /// its visibility must not depend on a scan happening. Cheap no-op once the
  /// card is already there.
  Future<void> _ensureCollectionsSystemDetected() async {
    try {
      if (_detectedSystems.any(
        (s) => s.folderName == SystemFolderNames.collections,
      )) {
        return;
      }

      final collectionsSystem = await SystemRepository.getSystemByFolderName(
        SystemFolderNames.collections,
      );
      final id = collectionsSystem?.id;
      if (id == null) {
        // The systems bundle on this install predates collections.json; the
        // next systems sync creates the row and the next launch picks it up.
        return;
      }

      await SystemRepository.addDetectedSystem(
        id,
        SystemFolderNames.collections,
      );
      await _refreshDetectedSystemsFromDatabase();
      _notify();
    } catch (e) {
      SqliteConfigProvider._log.w(
        'Could not register the Collections system: $e',
      );
    }
  }

  /// Public method to refresh detected systems from the database.
  ///
  /// Called after external changes (e.g., toggling a favorite) that may affect
  /// the presence of virtual systems like 'favorites'.
  Future<void> refreshDetectedSystems() async {
    await _loadDetectedSystems();
  }

  /// Synchronizes the list of detected systems with the current state of the database.
  Future<void> _refreshDetectedSystemsFromDatabase() async {
    try {
      // Obtener sistemas que realmente tienen ROMs desde la base de datos
      _detectedSystems = await SystemRepository.getDetectedSystems();
      _sortDetectedSystems();
    } catch (e) {
      SqliteConfigProvider._log.e('Error updating systems from DB: $e');
    }
  }

  /// Re-orders the detected systems list based on current sorting preferences.
  ///
  /// Implements special "float-to-top" logic for priority systems like 'All Games'
  /// and 'Android Apps'.
  void _sortDetectedSystems() {
    if (_detectedSystems.isEmpty) return;

    final sortBy = _config.systemSortBy;
    final isAsc = _config.systemSortOrder == 'asc';

    // Map priority folders that should NEVER be sorted
    final priorityMap = <String, int>{
      'all': 1,
      'favorites': 2,
      SystemFolderNames.collections: 3,
      'music': 4,
      'android': 5,
    };

    _detectedSystems.sort((a, b) {
      final pA = priorityMap[a.folderName] ?? 999;
      final pB = priorityMap[b.folderName] ?? 999;

      if (pA != pB) {
        return pA.compareTo(pB); // Priority objects always float to the top
      }

      // If both are normal systems (999), sort them
      if (pA != 999) {
        return 0; // Both are special and have same priority somehow
      }

      int comparison = 0;

      if (sortBy == 'year') {
        // Sort by year (launchDate). If no date is available, it goes to the end.
        final dateA = a.launchDate ?? '9999';
        final dateB = b.launchDate ?? '9999';
        comparison = dateA.compareTo(dateB);
      } else if (sortBy == 'manufacturer') {
        final mA = (a.manufacturer ?? '').toLowerCase();
        final mB = (b.manufacturer ?? '').toLowerCase();
        comparison = mA.compareTo(mB);
        if (comparison == 0) {
          final dateA = a.launchDate ?? '9999';
          final dateB = b.launchDate ?? '9999';
          comparison = dateA.compareTo(dateB);
        }
      } else if (sortBy == 'manufacturer_type') {
        final mA = (a.manufacturer ?? '').toLowerCase();
        final mB = (b.manufacturer ?? '').toLowerCase();
        comparison = mA.compareTo(mB);
        if (comparison == 0) {
          final tA = (a.type ?? '').toLowerCase();
          final tB = (b.type ?? '').toLowerCase();
          comparison = tA.compareTo(tB);
        }
        if (comparison == 0) {
          final dateA = a.launchDate ?? '9999';
          final dateB = b.launchDate ?? '9999';
          comparison = dateA.compareTo(dateB);
        }
      } else {
        // Default: Alphabetical by real name
        comparison = a.realName.toLowerCase().compareTo(
          b.realName.toLowerCase(),
        );
      }

      return isAsc ? comparison : -comparison;
    });
  }
}
