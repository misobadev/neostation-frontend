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
        } catch (_) {}
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
  Future<String> _calculateSyncRelativePath(
    GameModel game,
    File file,
    String basePath, {
    bool isState = false,
  }) async {
    // Check for Dreamcast game
    bool isDreamcast =
        game.systemFolderName == 'dreamcast' || game.systemFolderName == 'dc';
    if (!isDreamcast) {
      try {
        final systemId = await GameRepository.getSystemIdForGame(game.romname);
        if (systemId != null) isDreamcast = systemId == '18';
      } catch (e) {
        /* ignore */
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
        /* ignore */
      }
    }

    if (isPS2 && file.path.toLowerCase().endsWith('.ps2')) {
      return 'saves/PS2/${path.basename(file.path)}';
    }

    if (game.systemFolderName == 'switch') {
      return await calculateSwitchRelativePath(file, game);
    }

    return _calculateRelativePath(file, basePath, isState: isState);
  }

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

    final isState = cloudFile.fileName.startsWith('states/');
    final isSave = cloudFile.fileName.startsWith('saves/');

    // Buscar la carpeta más apropiada.
    String targetFolder = resolvedFolders.first;

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
    } else if (isSave) {
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

    // Limpiar el nombre del archivo (quitar prefijos 'saves/' o 'states/')
    String relativeName = cloudFile.fileName;
    if (isState) {
      relativeName = relativeName.replaceFirst(RegExp(r'^states[/\\]'), '');
    }
    if (isSave) {
      relativeName = relativeName.replaceFirst(RegExp(r'^saves[/\\]'), '');
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

    if (isSwitch && isSave) {
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

  /// Gets all save files recursively from a directory
  Future<List<File>> _getSaveFiles(String directoryPath) async {
    final dir = Directory(directoryPath);
    if (!await dir.exists()) return [];

    try {
      return dir
          .list(recursive: true)
          .where((entity) => entity is File)
          .cast<File>()
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
            } catch (_) {}
          }
        }
      } catch (_) {}
    }
    return null;
  }
}
