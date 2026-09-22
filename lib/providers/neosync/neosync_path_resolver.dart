part of '../neo_sync_provider.dart';

/// Centraliza la resolución de rutas para NeoSync
extension NeoSyncPathResolver on NeoSyncProvider {
  /// Resuelve una lista de rutas de sincronización para un sistema
  Future<List<String>> resolveUniversalPaths(
    SystemModel system, {
    GameModel? game,
    bool ensureExists = true,
  }) async {
    final folders = system.neosync.getFoldersForCurrentPlatform();
    final List<String> resolvedPaths = [];

    for (final folder in folders) {
      final resolved = await _resolveSinglePath(
        folder,
        system,
        game: game,
        ensureExists: ensureExists,
      );
      resolvedPaths.addAll(resolved);
    }

    // User-selected custom save folders (ARMSX2, ARMSX1, etc.) are stored per
    // system + emulator in the NeoSync module. Append every configured folder
    // for this system so custom emulator saves sync regardless of the JSON.
    final customFolders = await NeoSyncSaveFolderRepository.getFoldersForSystem(
      system.folderName,
    );
    if (customFolders.isNotEmpty) {
      for (final folderPath in customFolders.values) {
        if (!ensureExists || Directory(folderPath).existsSync()) {
          resolvedPaths.add(folderPath);
        }
      }
    }

    // Eliminar duplicados y rutas inexistentes si requireExists es true
    var result = resolvedPaths.toSet();
    if (ensureExists) {
      result = result.where((p) => Directory(p).existsSync()).toSet();
    }
    return result.toList();
  }

  /// Resuelve un string de ruta (con posibles placeholders) a una o más rutas absolutas
  Future<List<String>> _resolveSinglePath(
    String pathStr,
    SystemModel system, {
    GameModel? game,
    bool ensureExists = true,
  }) async {
    // 1. Placeholder {SYNC_DIR} (Saves y States de RetroArch)
    if (pathStr == '{SYNC_DIR}') {
      final List<String> paths = [];
      final saves = await _getRetroArchSavesPath();
      if (saves != null) paths.add(saves);
      final states = await _getRetroArchStatesPath();
      if (states != null) paths.add(states);
      return paths;
    }

    // 2. Placeholder {NETHERSX2_MEMCARDS} (AetherSX2/NetherSX2 memcards)
    if (pathStr == '{NETHERSX2_MEMCARDS}' && Platform.isAndroid) {
      final possiblePaths = [
        '/storage/emulated/0/Android/data/xyz.aethersx2.android/files/memcards',
        '/storage/emulated/0/Android/data/com.aethersx2.android/files/memcards',
        '/sdcard/Android/data/xyz.aethersx2.android/files/memcards',
      ];
      for (final p in possiblePaths) {
        if (Directory(p).existsSync()) return [p];
      }
      if (!ensureExists) return [possiblePaths.first];
      return [];
    }

    // 3. Placeholder {PCSX2_MEMCARDS} (PCSX2 on Windows/Android)
    if (pathStr == '{PCSX2_MEMCARDS}') {
      final List<String> paths = [];
      final p = await _getPCSX2MemcardsPath();
      if (p != null) paths.add(p);
      return paths;
    }

    // 4. Placeholder {FLYCAST_SAVES} (Flycast on Windows/Android)
    if (pathStr == '{FLYCAST_SAVES}') {
      final List<String> paths = [];
      final p = await _getFlycastSavesPath();
      if (p != null) paths.add(p);
      return paths;
    }

    // 3. Placeholder {SWITCH_NAND} o ${nandDir.path} (Switch NAND)
    if (pathStr.contains('{SWITCH_NAND}') ||
        pathStr.contains(r'${nandDir.path}')) {
      final nands = await SwitchSaveDetector.detectEmulatorNandPaths();
      final List<String> paths = [];

      String? titleId = game?.titleId;

      // If titleId not in DB, try extracting from ROM file and persist it.
      if ((titleId == null || titleId.isEmpty) && game?.romPath != null) {
        try {
          final info = await SwitchTitleExtractor.extractGameInfo(
            game!.romPath!,
          );
          if (info != null && info.titleId.isNotEmpty) {
            titleId = info.titleId;
            await GameRepository.updateGameTitleId(game.romname, titleId);
          }
        } catch (e) {
          NeoSyncProvider._log.e(
            'Error updating game titleId for ${game?.romname}: $e',
          );
        }
      }

      // Last resort: scan NAND save dirs and reverse-lookup by titleId in DB.
      // Needed on Android when ROM file is inaccessible (installed titles, etc.).
      if ((titleId == null || titleId.isEmpty) &&
          game != null &&
          nands.isNotEmpty) {
        titleId = await _findTitleIdByNandScan(nands, game.romname);
        if (titleId != null) {
          await GameRepository.updateGameTitleId(game.romname, titleId);
        }
      }

      for (final nand in nands) {
        final placeholder = pathStr.contains('{SWITCH_NAND}')
            ? '{SWITCH_NAND}'
            : r'${nandDir.path}';

        // Intentar resolver carpeta específica de guardado si tenemos titleId
        if (titleId != null && titleId.isNotEmpty && pathStr == placeholder) {
          final saveInfo = await SwitchSaveDetector.findSaveForTitleId(
            nand.nandDirectory,
            titleId,
          );
          if (saveInfo != null) {
            paths.add(saveInfo.savePath);

            continue;
          }
        }

        final resolved = pathStr.replaceFirst(placeholder, nand.nandDirectory);
        paths.add(resolved);
      }
      return paths;
    }

    // 4. RetroArch Placeholders
    if (pathStr == '{RETROARCH_SAVES}') {
      final p = await _getRetroArchSavesPath();
      return p != null ? [p] : [];
    }
    if (pathStr == '{RETROARCH_STATES}') {
      final p = await _getRetroArchStatesPath();
      return p != null ? [p] : [];
    }
    if (pathStr == '{RETROARCH_SYSTEM}') {
      final p = await _getRetroArchSystemPath();
      return p != null ? [p] : [];
    }

    // 4. Resolución estándar vía ConfigService (Home, AppData, etc.)
    final resolved = ConfigService.resolvePath(pathStr);

    // Si es absoluta y existe, retornarla
    if (path.isAbsolute(resolved)) {
      if (!ensureExists || Directory(resolved).existsSync()) {
        return [resolved];
      }
      return [];
    }

    // Si es relativa, intentar resolverla respecto a carpetas del sistema
    // (Esto es para sistemas que definen carpetas de ROMs pero los saves están cerca)
    for (final sysFolder in system.folders) {
      final absPath = path.join(sysFolder, resolved);
      if (Directory(absPath).existsSync()) {
        return [absPath];
      }
    }

    if (!ensureExists && system.folders.isNotEmpty) {
      return [path.join(system.folders.first, resolved)];
    }

    return [];
  }

  /// Helper to calculate relative path for sync, with special handling for various systems
  Future<String?> _calculateSyncRelativePath(
    GameModel game,
    File file,
    String basePath, {
    bool isState = false,
    String? explicitSystemFolder,
  }) async {
    // Switch saves are a tree under the Title ID (ExtraData1/data.bin, ...).
    // They are NOT compatible with the v2 per-file layout: same-named files
    // from different subtrees would overwrite each other in the cloud, so the
    // emulator/Title-ID structure must be encoded first.
    if (game.systemFolderName == 'switch') {
      return await calculateSwitchRelativePath(file, game);
    }

    // Try the NeoSync v2 standard path first. It carries system + emulator, so
    // the cloud always knows which emulator produced the save.
    final v2Path = await _buildV2CloudPath(
      game,
      file,
      basePath,
      isState: isState,
      explicitSystemFolder: explicitSystemFolder,
    );
    if (v2Path == null) {
      // Only RetroArch files whose core is unresolvable return null; skip the
      // upload rather than invent a legacy `saves/...` path or `retroarch.unknown`.
      NeoSyncProvider._log.i(
        'RA sync path: skipped ${file.path} (no resolvable core)',
      );
      return null;
    }
    if (v2Path.startsWith('v2/saves/') || v2Path.startsWith('v2/states/')) {
      return v2Path;
    }

    // Check for Dreamcast game
    bool isDreamcast =
        game.systemFolderName == 'dreamcast' || game.systemFolderName == 'dc';
    if (!isDreamcast) {
      try {
        final systemId = await GameRepository.getSystemIdForGame(game.romname);
        if (systemId != null) isDreamcast = systemId == '18';
      } catch (e) {
        NeoSyncProvider._log.e(
          'Error getting system ID for Dreamcast check (${game.romname}): $e',
        );
      }
    }

    if (isDreamcast && file.path.toLowerCase().contains('vmu_save')) {
      // Force structure: saves/dc/filename.bin
      return 'saves/dc/${path.basename(file.path)}';
    }

    // Special handling for NetherSX2 on Android
    if (Platform.isAndroid && file.path.contains('xyz.aethersx2.android')) {
      return 'saves/NetherSX2/${path.basename(file.path)}';
    }

    // Special handling for PS2 (RetroArch/PCSX2)
    // Force structure: saves/PS2/filename.ps2 to match standard convention
    bool isPS2 = game.systemFolderName == 'ps2';
    if (!isPS2) {
      try {
        final systemId = await GameRepository.getSystemIdForGame(game.romname);
        if (systemId != null) isPS2 = systemId == '21';
      } catch (e) {
        NeoSyncProvider._log.e(
          'Error getting system ID for PS2 check (${game.romname}): $e',
        );
      }
    }

    if (isPS2 && file.path.toLowerCase().endsWith('.ps2')) {
      return 'saves/PS2/${path.basename(file.path)}';
    }

    return _calculateRelativePath(file, basePath, isState: isState);
  }

  /// Returns the canonical NeoSync file kind for [file].
  ///
  /// The kind is derived only from the file itself (never from the cloud
  /// namespace), so the same save is classified identically on every device and
  /// OS: `state` for save states, `shared` for memory cards / VMU that hold
  /// many games, `save` otherwise.
  String _syncTypeForFile(File file, {required bool isState}) =>
      CloudPathBuilder.syncTypeForPath(file.path, isState: isState);

  /// Calcula la ruta relativa para sincronización
  String _calculateRelativePath(
    File file,
    String basePath, {
    bool isState = false,
  }) {
    var relative = path.relative(file.path, from: basePath);
    String root = isState ? 'states' : 'saves';

    // Si RetroArch está en la raíz o similar, 'parent' de basePath podría ser útil
    // Pero por consistencia, NeoSync guarda como 'root/relative' si no es absoluto
    if (!relative.startsWith('..')) {
      return path.join(root, relative).replaceAll('\\', '/');
    }

    // Si está fuera de basePath, usar solo el nombre del archivo
    return path.join(root, path.basename(file.path)).replaceAll('\\', '/');
  }

  /// Builds a NeoSync v2 cloud path for a game save/state.
  ///
  /// Uses the standard `saves|states/<system>/<emulator-slug>/<scope>/...`
  /// layout so the emulator that produced the save is always identifiable.
  /// When the emulator slug cannot be determined for a non-RetroArch file it
  /// falls back to the legacy relative path so existing flows keep working;
  /// for a RetroArch file it returns null so the caller skips the upload
  /// instead of inventing `retroarch.unknown`.
  Future<String?> _buildV2CloudPath(
    GameModel game,
    File file,
    String basePath, {
    bool isState = false,
    String? explicitSystemFolder,
  }) async {
    var system = await _getSystemForGame(game);

    // If the save lives under the RetroArch saves/states dir, prefer the core
    // folder as the emulator source of truth. RetroArch stores
    // `<savesPath>/<core>/<game>.srm`, and the game's emulator metadata may
    // point at a standalone app instead of the core that wrote the save.
    String? emulatorSlug;
    String? systemFolderFromCore;
    final savesPath = await _getRetroArchSavesPath();
    final statesPath = await _getRetroArchStatesPath();
    String? retroBase;
    if (savesPath != null && path.isWithin(savesPath, file.path)) {
      retroBase = savesPath;
    } else if (statesPath != null && path.isWithin(statesPath, file.path)) {
      retroBase = statesPath;
    }
    if (retroBase != null) {
      // RetroArch saves/states are stored under their original on-disk path
      // relative to the RetroArch save/state directory (the v1 convention:
      // `saves/FinalBurn Neo/fbneo/<file>` or `states/FinalBurn Neo/<file>`),
      // so the game-start flow produces the same file name as the auto-upload.
      return _calculateRelativePath(file, retroBase, isState: isState);
    }
    emulatorSlug ??= await _resolveEmulatorSlugForGame(game, system);
    // Priority: the caller's explicit system (from the games list context),
    // then the game's own system, then the core-derived fallback. Finally the
    // emulator is cross-checked so the save never lands under a system the
    // emulator doesn't support.
    var systemFolder =
        explicitSystemFolder ??
        game.systemFolderName ??
        system?.folderName ??
        systemFolderFromCore;
    systemFolder = await _reconcileEmulatorSystem(systemFolder, emulatorSlug);

    if (systemFolder == null || emulatorSlug == null) {
      return _calculateRelativePath(file, basePath, isState: isState);
    }

    final fileName = path.basename(file.path);

    // Memory-card style files are shared between games (PS2 .ps2 memcards,
    // Dreamcast VMU, etc.), so they go under the `shared` scope without a game
    // segment. Everything else is per-game. The game segment is the save base
    // name (not the game title) so it stays consistent with the auto-upload
    // flow, which only has the file path to derive it from; a save uploaded by
    // either flow must resolve to the same cloud path.
    final lowerName = fileName.toLowerCase();
    final isSharedCard =
        (systemFolder == 'ps2' && lowerName.endsWith('.ps2')) ||
        (systemFolder == 'dc' && lowerName.contains('vmu_save')) ||
        systemFolder == 'dreamcast' && lowerName.contains('vmu_save');

    final scope = isSharedCard ? 'shared' : 'game';

    return CloudPathBuilder.build(
      system: systemFolder,
      emulatorSlug: emulatorSlug,
      scope: scope,
      filePath: fileName,
      gameName: isSharedCard ? null : path.basenameWithoutExtension(file.path),
      isState: isState,
    );
  }

  /// Resolves the local RetroArch core folder name from an emulator slug.
  ///
  /// The v2 cloud path carries the derived slug (`retroarch.mgba`), but the
  /// on-disk layout uses the core folder name (`mgba`, `mednafen_psx_hw`, ...).
  /// Only returns a folder that actually exists under [baseFolder], because the
  /// per-core subfolder layout is what the upload encodes in the first place.
  /// When no matching core folder exists on disk the save is a flat-layout
  /// save (`<base>/<game>.srm`) and must be restored flat — returning null here
  /// is what keeps the download from inventing a `<base>/<core>/` subfolder
  /// that RetroArch would never read.
  /// Resolves the NeoSync v2 game hash (`ra_hash`) for an upload.
  ///
  /// The cloud `game_hash` identifies the actual ROM behind a save. It uses the
  /// RetroAchievements hash (the real content hash, which for ZIP ROMs reflects
  /// the file *inside* the archive) rather than the save file's own hash. If the
  /// hash is already cached in the local DB it is returned; otherwise it is
  /// generated and persisted by [RetroAchievementsHashService].
  Future<String?> _resolveGameHashForUpload(GameModel game) async {
    try {
      return await RetroAchievementsHashService.generateHashForGame(game);
    } catch (e) {
      NeoSyncProvider._log.w('Error resolving game hash for ${game.name}: $e');
      return null;
    }
  }

  /// Resolves the NeoSync v2 emulator slug for a RetroArch save/state file.
  ///
  /// Only a per-core subfolder layout (`<base>/<core>/<game>.srm`) encodes the
  /// core in the path; flat saves (`<base>/<game>.srm`) have a single segment
  /// that is the file itself. For flat saves the slug is only derived from the
  /// game's own emulator *iff* that emulator is itself a RetroArch core (e.g.
  /// `gba.ra.mgba` -> `retroarch.mgba`); a standalone emulator such as GBA Free
  /// must never be reported as the producer of a RetroArch save. Returns null
  /// when no core can be determined so callers skip the upload instead of
  /// inventing `retroarch.unknown`.
  Future<String?> _resolveRetroArchEmulatorSlug(
    File file,
    String retroArchBase,
  ) async {
    final coreName = _retroArchCoreFolderForFile(file, retroArchBase);
    if (coreName != null) {
      NeoSyncProvider._log.i('RA slug: core "$coreName" for ${file.path}');
      return CloudPathBuilder.retroArchCoreSlug(coreName);
    }

    final fileName = path.basenameWithoutExtension(file.path);
    try {
      final row = await GameRepository.findRomByFilenamePrefix('$fileName%');
      if (row == null) {
        NeoSyncProvider._log.w(
          'RA slug: no game matched flat save "$fileName"; skipping',
        );
        return null;
      }
      final game = _gameModelFromRomRow(row, fileName);
      final slug = _retroArchCoreSlugFromGame(game);
      NeoSyncProvider._log.i(
        slug == null
            ? 'RA slug: flat save "$fileName" has no RetroArch core '
                  '(emulator "${game.emulatorName ?? 'unknown'}"); skipping'
            : 'RA slug: flat save "$fileName" -> $slug',
      );
      return slug;
    } catch (e) {
      NeoSyncProvider._log.w('Error resolving emulator slug for $fileName: $e');
      return null;
    }
  }

  /// Returns the RetroArch core folder name when [file] lives in a per-core
  /// subfolder under [basePath] (`<base>/<core>/<game>.srm`), else null.
  String? _retroArchCoreFolderForFile(File file, String basePath) {
    final relativeToBase = path.relative(file.path, from: basePath);
    final segments = relativeToBase.split(RegExp(r'[/\\]'));
    if (segments.length > 1) {
      final coreName = segments.first;
      // Guard against a wrong base path that exposes the saves/states root as
      // the "core" folder, which produced a bogus `retroarch.saves` slug.
      final lower = coreName.toLowerCase();
      if (coreName.isNotEmpty && lower != 'saves' && lower != 'states') {
        return coreName;
      }
    }
    return null;
  }

  /// Derives a `retroarch.<core>` slug from [game]'s emulator, but ONLY when
  /// that emulator is itself a RetroArch core (`gba.ra.mgba`,
  /// `gba.ra64.mgba`, `gba.ra32.mgba` or a core name). A standalone emulator
  /// (GBA Free, DuckStation, AetherSX2...) may be selected for a game whose
  /// save was actually written by a RetroArch core, so it is never trusted for
  /// a RetroArch save. Returns null when no RetroArch core can be determined.
  String? _retroArchCoreSlugFromGame(GameModel game) {
    final uniqueId = game.emulatorName?.trim() ?? '';
    if (uniqueId.isNotEmpty) {
      final lower = uniqueId.toLowerCase();
      if (lower.contains('.ra.') ||
          lower.contains('.ra64.') ||
          lower.contains('.ra32.')) {
        return CloudPathBuilder.slugFromEmulatorUniqueId(uniqueId);
      }
    }
    if (game.coreName != null && game.coreName!.isNotEmpty) {
      return CloudPathBuilder.retroArchCoreSlug(game.coreName!);
    }
    return null;
  }

  /// Builds a lightweight [GameModel] from a `findRomByFilenamePrefix` row so
  /// emulator/slug resolution can reuse the standard game metadata lookups.
  GameModel _gameModelFromRomRow(Map<String, dynamic> row, String fallback) {
    final romname = row['filename']?.toString() ?? fallback;
    final title = row['title_name']?.toString() ?? romname;
    return GameModel(
      name: title,
      realname: title,
      romname: romname,
      romPath: row['rom_path']?.toString(),
      systemFolderName: row['folder_name']?.toString(),
      emulatorName: row['emulator_name']?.toString(),
      year: '',
      developer: '',
      publisher: '',
      genre: '',
      players: '',
      rating: 0.0,
    );
  }

  /// Resolves the system folder name for a RetroArch save file.
  ///
  /// RetroArch organizes saves under `<base>/<core>/<game>.srm`. A core can
  /// serve several systems (e.g. `mgba` runs GBA, GB and GB-hacks), so the
  /// system is first resolved from the game by its ROM base name — the game
  /// belongs to exactly one system. Only if no game is found does it fall back
  /// to mapping the core via the emulators table. Returns null when neither
  /// matches.
  Future<String?> _systemFolderForRetroArchFile(
    File file,
    String retroArchBase,
  ) async {
    final fileName = path.basenameWithoutExtension(file.path);

    // The save base name usually matches the ROM name, so find the game by
    // prefix and use its system.
    try {
      final row = await GameRepository.findRomByFilenamePrefix('$fileName%');
      if (row != null) {
        final folder = row['folder_name']?.toString();
        if (folder != null && folder.isNotEmpty) return folder;
      }
    } catch (e) {
      NeoSyncProvider._log.w('Error resolving game system for $fileName: $e');
    }

    final relativeToBase = path.relative(file.path, from: retroArchBase);
    final segments = relativeToBase.split(RegExp(r'[/\\]'));
    // Only a per-core subfolder layout (<base>/<core>/<game>.srm) encodes the
    // core in the path. Flat saves (<base>/<game>.srm) have a single segment
    // that is the file itself, so there is no core folder to map back.
    if (segments.length <= 1) return null;
    final coreName = segments.first;
    if (coreName.isEmpty) return null;

    try {
      final rows = await SqliteService.findSystemByCoreName(coreName);
      if (rows == null || rows.isEmpty) return null;
      return rows.first['folder_name']?.toString();
    } catch (e) {
      NeoSyncProvider._log.w('Error mapping core $coreName to system: $e');
      return null;
    }
  }

  /// Resolves the NeoSync v2 emulator slug for a game.
  ///
  /// Tries, in order: the emulator's stored `neosync_slug`, a derivation from
  /// the game's emulator unique id (handles RetroArch cores collapsing
  /// RA/RA64/RA32), then the system's default standalone slug. Returns null
  /// when no emulator information is available.
  Future<String?> _resolveEmulatorSlugForGame(
    GameModel game,
    SystemModel? system,
  ) async {
    final uniqueId = game.emulatorName?.trim() ?? '';
    if (uniqueId.isNotEmpty) {
      return CloudPathBuilder.slugFromEmulatorUniqueId(uniqueId);
    }

    if (game.coreName != null && game.coreName!.isNotEmpty) {
      return CloudPathBuilder.retroArchCoreSlug(game.coreName!);
    }

    if (system == null) return null;
    try {
      final standalone = await SqliteService.getStandaloneEmulatorsBySystemId(
        system.id ?? system.folderName,
      );
      if (standalone.isNotEmpty) {
        final slug = standalone.first['neosync_slug']?.toString();
        if (slug != null && slug.isNotEmpty) return slug;
        final uniqueId = standalone.first['unique_identifier']?.toString();
        if (uniqueId != null && uniqueId.isNotEmpty) {
          return CloudPathBuilder.slugFromEmulatorUniqueId(uniqueId);
        }
      }
    } catch (e) {
      NeoSyncProvider._log.w('Error resolving emulator slug: $e');
    }
    return null;
  }

  /// Ensures [system] and [emulatorSlug] agree.
  ///
  /// A save must never be tagged with a system the emulator doesn't support.
  /// When the emulator is only registered for other systems (e.g. a NES core
  /// saving under a cps1 game that got mis-associated in the local DB) the
  /// first system the emulator actually supports is returned instead. When the
  /// pair is consistent, or the emulator is unknown, [system] is kept.
  Future<String?> _reconcileEmulatorSystem(
    String? system,
    String? emulatorSlug,
  ) async {
    if (system == null || emulatorSlug == null) return system;
    try {
      final systems = await SqliteService.findSystemsByEmulatorSlug(
        emulatorSlug,
      );
      if (systems.isEmpty || systems.contains(system)) return system;
      NeoSyncProvider._log.w(
        'Emulator $emulatorSlug is not registered for system $system; '
        'using ${systems.first} instead',
      );
      return systems.first;
    } catch (e) {
      NeoSyncProvider._log.w('Error reconciling emulator/system: $e');
      return system;
    }
  }

  /// Resuelve la ruta local para un archivo de la nube para un juego específico
  /// Resuelve la ruta local para un archivo de la nube para un juego específico
  /// Puede retornar múltiples rutas si el sistema lo requiere (ej. múltiples emuladores Switch)
  Future<List<String>> resolveCloudFileToLocalPath(
    GameModel game,
    NeoSyncFile cloudFile,
  ) async {
    final system = await _getSystemForGame(game);
    if (system == null) return [];

    final resolvedFolders = await resolveUniversalPaths(
      system,
      game: game,
      ensureExists:
          false, // Permitir carpetas que aún no existen para descargar
    );
    if (resolvedFolders.isEmpty) return [];

    // The backend stores the real on-disk path (relative to the emulator's
    // save/state directory) in file_path, e.g. `FinalBurn Neo/fbneo/<file>`
    // for RetroArch or `eden/<game>/<file>` for Switch. The kind (save, state,
    // custom, shared) is carried by the `type` column, so placement no longer
    // has to infer it from the path.
    final isState = cloudFile.type == 'state';
    final relativeName = cloudFile.filePath.isNotEmpty
        ? cloudFile.filePath
        : cloudFile.fileName;

    // Buscar la carpeta más apropiada.
    String targetFolder = resolvedFolders.first;

    // Prefer the configured custom folder for standalone emulators and shared
    // memory cards (type shared/custom), e.g. ARMSX2 .ps2, DuckStation memcards.
    // Custom folders are only offered for standalone emulators, so RetroArch
    // saves (no matching custom folder) fall through to the standard
    // resolution below.
    if (cloudFile.emulator != null && cloudFile.emulator!.isNotEmpty) {
      final customFolder = await NeoSyncSaveFolderRepository.getFolder(
        system.folderName,
        cloudFile.emulator!,
      );
      if (customFolder != null && customFolder.isNotEmpty) {
        // Standalone saves are stored under `v2/custom/<emulator>/<relative>`
        // in R2; strip that namespace so the file lands under the custom folder.
        var rel = relativeName;
        final prefix = 'v2/custom/${cloudFile.emulator}/';
        if (rel.startsWith(prefix)) {
          rel = rel.substring(prefix.length);
        } else {
          final m = RegExp(r'^v2/custom/[^/]+/(.+)$').firstMatch(rel);
          if (m != null) rel = m.group(1)!;
        }
        final target = path.join(customFolder, rel);
        NeoSyncProvider._log.i(
          'Download: ${cloudFile.filePath} -> custom folder $target',
        );
        return [target];
      }
    }

    if (isState) {
      final statesPath = await _getRetroArchStatesPath();
      if (statesPath != null) {
        targetFolder = statesPath;
      } else {
        // Fallback: buscar carpeta que parezca de states
        for (final folder in resolvedFolders) {
          if (folder.toLowerCase().contains('state') ||
              folder.toLowerCase().contains('sstates')) {
            targetFolder = folder;
            break;
          }
        }
      }
    } else {
      final savesPath = await _getRetroArchSavesPath();
      if (savesPath != null) {
        targetFolder = savesPath;
      } else {
        // Fallback: buscar carpeta que parezca de saves
        for (final folder in resolvedFolders) {
          if (folder.toLowerCase().contains('save') ||
              folder.toLowerCase().contains('memcards')) {
            targetFolder = folder;
            break;
          }
        }
      }
    }

    // Para sistemas con memory cards compartidas (PS2, Dreamcast), el relativeName ya es el filename
    // si usamos el logic de _calculateSyncRelativePath inverso.
    // Pero en general, cloudFile.fileName is 'saves/subfolder/file.ext'.
    // The relativeName after removing 'saves/' is 'subfolder/file.ext'.

    // Identificación robusta para Switch
    final isSwitch =
        system.id?.toLowerCase() == 'switch' ||
        system.folderName.toLowerCase() == 'switch' ||
        game.systemId?.toLowerCase() == 'switch' ||
        game.systemFolderName?.toLowerCase() == 'switch';

    if (isSwitch && !isState) {
      String? titleId = game.titleId;

      // Si no tenemos titleId, intentar recuperarlo de la BD con búsqueda más flexible
      if (titleId == null || titleId.isEmpty) {
        try {
          titleId = await GameRepository.getTitleIdForGame(
            game.romname,
            game.name,
          );
        } catch (e) {
          NeoSyncProvider._log.e(
            'Error fetching titleId via flexible lookup: $e',
          );
        }
      }

      // FALLBACK: Si todavía no hay titleId, intentar extraerlo del ROM real
      if ((titleId == null || titleId.isEmpty) && game.romPath != null) {
        try {
          final info = await SwitchTitleExtractor.extractGameInfo(
            game.romPath!,
          );
          if (info != null) {
            titleId = info.titleId;

            try {
              await GameRepository.updateGameTitleId(game.romname, titleId);
            } catch (dbError) {
              NeoSyncProvider._log.e(
                'Error updating DB with extracted titleId: $dbError',
              );
            }
          }
        } catch (e) {
          NeoSyncProvider._log.e('Error extracting titleId from ROM: $e');
        }
      }

      if (titleId != null && titleId.isNotEmpty) {
        final List<String> resultPaths = [];

        // relativeName is similar to `eden/A Short Hike/ExtraData1/file.dat`
        final parts = relativeName.split(RegExp(r'[/\\]'));
        String internalPath = path.basename(relativeName);
        String? emulatorPrefix;

        // Si tenemos la estructura de 3 niveles (emulator/game/internal), extraemos el internal y el prefix
        if (parts.length >= 3) {
          emulatorPrefix = parts[0].toLowerCase();
          internalPath = parts.sublist(2).join(Platform.pathSeparator);
        }

        final allEmulators = await SwitchSaveDetector.detectEmulatorNandPaths();

        // Filtrar emuladores basándonos en el prefijo del archivo de la nube para independencia
        List<EmulatorNandInfo> emulators = allEmulators;
        if (emulatorPrefix != null) {
          emulators = allEmulators.where((emu) {
            final name = emu.emulatorName.toLowerCase();
            // Match flexible: 'eden' -> 'Eden', 'Eden Legacy', 'Eden Optimized', etc.
            return name.contains(emulatorPrefix!);
          }).toList();

          if (emulators.isEmpty) {
            return [];
          }
        }

        if (emulators.isNotEmpty) {
          for (final emu in emulators) {
            // 1. Intentar encontrar save existente para este emulador
            final saveInfo = await SwitchSaveDetector.findSaveForTitleId(
              emu.nandDirectory,
              titleId,
            );

            if (saveInfo != null) {
              final fullPath = path.join(saveInfo.savePath, internalPath);
              resultPaths.add(fullPath);
            } else {
              // 2. Si no existe, construir la ruta en este NAND
              final saveBasePath = path.join(
                emu.nandDirectory,
                'user',
                'save',
                '0000000000000000',
              );
              final saveBaseDir = Directory(saveBasePath);

              // Buscar el primer directorio de usuario disponible o usar default
              String userId = '00000000000000000000000000000000';
              if (saveBaseDir.existsSync()) {
                final entities = saveBaseDir.listSync().whereType<Directory>();
                if (entities.isNotEmpty) {
                  userId = path.basename(entities.first.path);
                }
              }

              final fullPath = path.join(
                saveBasePath,
                userId,
                titleId,
                internalPath,
              );
              resultPaths.add(fullPath);
            }
          }
        }

        if (resultPaths.isNotEmpty) return resultPaths;
      }
    }

    return [path.join(targetFolder, relativeName)];
  }

  // =========================================
  // RETROARCH PATH HELPERS (Centralized)
  // =========================================

  Future<String?> _getRetroArchSavesPath() async {
    try {
      final config = await RetroArchConfigService().getMergedConfig();
      return config.savefileDirectory;
    } catch (e) {
      NeoSyncProvider._log.e('Error getting RetroArch saves path: $e');
      return null;
    }
  }

  Future<String?> _getRetroArchStatesPath() async {
    try {
      final config = await RetroArchConfigService().getMergedConfig();
      return config.savestateDirectory;
    } catch (e) {
      NeoSyncProvider._log.e('Error getting RetroArch states path: $e');
      return null;
    }
  }

  Future<String?> _getRetroArchSystemPath() async {
    try {
      final config = await RetroArchConfigService().getMergedConfig();
      return config.systemDirectory;
    } catch (e) {
      NeoSyncProvider._log.e('Error getting RetroArch system path: $e');
      return null;
    }
  }

  // =========================================
  // HELPER METHODS (Restored/Moved)
  // =========================================

  /// Gets all save files recursively from a directory.
  ///
  /// NeoSync backup copies (`*.neosync.bak`) are excluded so the recovery
  /// safety net is never itself uploaded or synced.
  Future<List<File>> _getSaveFiles(String directoryPath) async {
    final dir = Directory(directoryPath);
    if (!await dir.exists()) return [];

    try {
      return await dir
          .list(recursive: true)
          .where((entity) => entity is File)
          .cast<File>()
          .where((file) => !file.path.toLowerCase().endsWith('.neosync.bak'))
          .toList();
    } catch (e) {
      NeoSyncProvider._log.e('Error listing save files in $directoryPath: $e');
      return [];
    }
  }

  /// Calculates relative path for Switch saves
  /// Format: saves/[emulator]/[Game Name]/[internal_structure]
  Future<String> calculateSwitchRelativePath(File file, GameModel game) async {
    final sanitizedGameName = game.name.replaceAll(
      RegExp(r'[<>:"/\\|?*]'),
      '_',
    );

    String emulatorName = 'switch';
    final lowerPath = file.path.toLowerCase();

    // First, try to detect based on known NAND directories
    try {
      final emulators = await SwitchSaveDetector.detectEmulatorNandPaths();
      for (final emu in emulators) {
        if (path.isWithin(emu.nandDirectory, file.path) ||
            file.path.startsWith(emu.nandDirectory)) {
          final nameLower = emu.emulatorName.toLowerCase();
          if (nameLower.contains('eden')) {
            emulatorName = 'eden';
          } else if (nameLower.contains('citron')) {
            emulatorName = 'citron';
          } else if (nameLower.contains('yuzu')) {
            emulatorName = 'yuzu';
          } else if (nameLower.contains('suyu')) {
            emulatorName = 'suyu';
          } else if (nameLower.contains('sudachi')) {
            emulatorName = 'sudachi';
          }
          break;
        }
      }
    } catch (e) {
      NeoSyncProvider._log.e('Error checking emulator nand paths: $e');
    }

    // Fallback if not found via NAND
    if (emulatorName == 'switch') {
      if (lowerPath.contains('eden') || lowerPath.contains('yuanshen')) {
        emulatorName = 'eden';
      } else if (lowerPath.contains('citron')) {
        emulatorName = 'citron';
      } else if (lowerPath.contains('yuzu')) {
        emulatorName = 'yuzu';
      } else if (lowerPath.contains('suyu')) {
        emulatorName = 'suyu';
      } else if (lowerPath.contains('sudachi')) {
        emulatorName = 'sudachi';
      }
    }

    String internalPath = path.basename(file.path);

    // Try to preserve internal structure after the Title ID
    final pathParts = file.path.split(Platform.pathSeparator);
    final saveIndex = pathParts.indexOf('save');
    if (saveIndex != -1 && saveIndex + 3 < pathParts.length) {
      if (saveIndex + 4 < pathParts.length) {
        internalPath = pathParts.sublist(saveIndex + 4).join('/');
      }
    }

    return path
        .join('saves', emulatorName, sanitizedGameName, internalPath)
        .replaceAll('\\', '/');
  }

  Future<String?> _getPCSX2MemcardsPath() async {
    if (Platform.isAndroid) {
      final possiblePaths = [
        '/storage/emulated/0/Android/data/xyz.aethersx2.android/files/memcards',
        '/storage/emulated/0/Android/data/com.aethersx2.android/files/memcards',
      ];
      for (final p in possiblePaths) {
        if (Directory(p).existsSync()) return p;
      }
      return null;
    } else if (Platform.isWindows) {
      // 1. Try database
      try {
        final exePath = await EmulatorRepository.getEmulatorPath(
          '%pcsx2%',
          '%PCSX2%',
        );
        if (exePath != null) {
          final dir = path.dirname(exePath);
          final portable = path.join(dir, 'memcards');
          if (Directory(portable).existsSync()) return portable;
        }
      } catch (e) {
        /* ignore */
      }

      // 2. Try standard Documents location
      final docs = path.join(
        Platform.environment['USERPROFILE'] ?? '',
        'Documents',
        'PCSX2',
        'memcards',
      );
      if (Directory(docs).existsSync()) return docs;
    }
    return null;
  }

  Future<String?> _getFlycastSavesPath() async {
    if (Platform.isAndroid) {
      // RetroArch is usually used for DC on Android, or Flycast standalone
      final possible =
          '/storage/emulated/0/Android/data/com.flycast.emulator/files/data';
      if (Directory(possible).existsSync()) return possible;
      return null;
    } else if (Platform.isWindows) {
      // 1. Try database
      try {
        final exePath = await EmulatorRepository.getEmulatorPath(
          '%flycast%',
          '%Flycast%',
        );
        if (exePath != null) {
          final dir = path.dirname(exePath);
          final dataDir = path.join(dir, 'data');
          if (Directory(dataDir).existsSync()) return dataDir;
          if (Directory(dir).existsSync()) return dir;
        }
      } catch (e) {
        /* ignore */
      }
    }
    return null;
  }

  /// Scans NAND save directories across detected emulators to find which titleId
  /// belongs to the given ROM. Used as last resort when titleId is not in the DB
  /// and cannot be extracted from the ROM file (e.g., installed titles on Android).
  Future<String?> _findTitleIdByNandScan(
    List<EmulatorNandInfo> nands,
    String romname,
  ) async {
    for (final nand in nands) {
      try {
        final saveBasePath = path.join(
          nand.nandDirectory,
          'user',
          'save',
          '0000000000000000',
        );
        final saveBaseDir = Directory(saveBasePath);
        if (!saveBaseDir.existsSync()) continue;

        // List userId dirs (one level deep — fast)
        final userIdDirs = saveBaseDir.listSync().whereType<Directory>();
        for (final userIdDir in userIdDirs) {
          final titleIdDirs = userIdDir.listSync().whereType<Directory>();
          for (final titleIdDir in titleIdDirs) {
            final candidate = path.basename(titleIdDir.path);
            try {
              final row = await GameRepository.findSwitchGameByTitleId(
                candidate,
              );
              if (row != null && row['filename'].toString() == romname) {
                NeoSyncProvider._log.i(
                  'Resolved titleId "$candidate" for $romname via NAND scan',
                );
                return candidate;
              }
            } catch (e) {
              NeoSyncProvider._log.e(
                'Error finding Switch game by titleId $candidate: $e',
              );
            }
          }
        }
      } catch (e) {
        NeoSyncProvider._log.e(
          'Error scanning NAND directory for ${nand.emulatorName}: $e',
        );
      }
    }
    return null;
  }
}
