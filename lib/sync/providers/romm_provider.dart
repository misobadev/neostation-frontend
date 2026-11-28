/// RomM save-sync provider.
///
/// Syncs emulator save files and save states between the local device and a
/// self-hosted RomM instance, mirroring NeoSync's per-game flow (download newer
/// remote saves before launch, upload changed local saves after the game
/// closes).
///
/// It reuses the existing, already-authenticated [RommProvider] (library browse)
/// connection — no second login — and delegates local save-file *location* to
/// [NeoSyncProvider]'s battle-tested path resolution. Sync state is tracked in
/// the shared, provider-agnostic `app_neo_sync_state` table via [SyncRepository].
///
/// Saves are keyed by RomM `rom_id`, which is only known for games downloaded
/// from RomM (recorded in `app_romm_rom_map` at download time). Games with no
/// mapping are treated as not-linked and skipped.
library;

import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as path;
import 'package:neostation/models/core_emulator_model.dart';
import 'package:neostation/models/game_model.dart';
import 'package:neostation/models/neo_sync_models.dart';
import 'package:neostation/models/romm_asset.dart';
import 'package:neostation/models/romm_platform.dart';
import 'package:neostation/models/retroarch_config_model.dart';
import 'package:neostation/models/romm_rom.dart';
import 'package:neostation/models/system_model.dart';
import 'package:neostation/providers/neo_sync_provider.dart';
import 'package:neostation/repositories/emulator_repository.dart';
import 'package:neostation/repositories/neosync_save_folder_repository.dart';
import 'package:neostation/repositories/game_repository.dart';
import 'package:neostation/services/retroarch_config_service.dart';
import 'package:neostation/providers/romm_provider.dart';
import 'package:neostation/repositories/romm_save_map_repository.dart';
import 'package:neostation/repositories/sync_repository.dart';
import 'package:neostation/repositories/system_repository.dart';
import 'package:neostation/services/game/game_launch_service.dart';
import 'package:neostation/services/logger_service.dart';
import 'package:neostation/utils/cloud_path_builder.dart';
import 'package:neostation/utils/kept_save_copy.dart';
import 'package:neostation/services/romm/romm_library_linker.dart';
import 'package:neostation/services/romm_playtime_service.dart';
import 'package:neostation/services/romm_service.dart';

import '../i_sync_provider.dart';
import '../open_game_guard.dart';
import '../open_game_return.dart';
import '../retroarch_state_signature.dart';
import '../sync_manager.dart';
import '../../utils/emulator_loader.dart';
import '../../utils/kept_cloud_copy_notice.dart';
import '../../utils/rom_stem.dart';
import '../../utils/safe_path.dart';

/// Locates the local save/state files belonging to a game.
typedef LocateGameSaves = Future<List<LocalSaveFile>> Function(GameModel game);

/// Resolves the candidate local destination paths for a cloud file named
/// [relativeName] (e.g. `saves/Game.srm`) belonging to a game.
typedef ResolveSaveTargets = Future<List<String>> Function(
  GameModel game,
  String relativeName,
);

/// Enumerates the local library, for the pending-upload sweep.
typedef ListLocalGames = Future<List<GameModel>> Function();

/// The card folder of a system in RetroArch's system folder when its
/// RetroArch core is set up here (see `retroArchSystemCardHome`).
typedef ResolveSystemCardHome = Future<String?> Function(String? system);

/// Where a card named `fileName` goes in RetroArch's system folder (see
/// `retroArchSystemCardTarget`).
typedef ResolveSystemCardTarget = Future<List<String>?> Function(
  String system,
  String fileName,
);

/// The standalone save folders configured for a system (the Saves tab's
/// Standalone save folders), by system folder name.
typedef ListSaveFolders = Future<List<String>> Function(
  String systemFolderName,
);

/// Where [game]'s emulator keeps its saves, when that emulator is standalone:
/// `standalone: false` when it is a RetroArch core or can't be told, so the
/// usual RetroArch placement applies; `folder: null` when it is standalone
/// and no folder is configured for it.
typedef ResolveStandaloneSaveFolder =
    Future<({bool standalone, String? folder})> Function(GameModel game);

/// RetroArch's folder name for the core [game] launches with, or null when
/// it launches with something else or that can't be told.
typedef ResolveLaunchCoreFolder = Future<String?> Function(GameModel game);

/// RetroArch's folder names for the cores of every system but [game]'s, in
/// lower case (a core several systems share, [game]'s among them, is not one).
typedef ResolveOtherSystemsCoreFolders = Future<Set<String>> Function(
  GameModel game,
);

/// The emulator a game launches with, and the system's emulators.
typedef _LaunchEmulator = ({
  SystemModel system,
  String uniqueId,
  List<CoreEmulatorModel> emulators,
});

/// Outcome of the pre-upload check that protects a remote copy the local one is
/// about to replace.
enum _RemoteGuard {
  /// The server holds nothing this device has not already accounted for, so the
  /// upload is an ordinary one-sided change.
  clear,

  /// Both sides genuinely changed and the remote bytes were saved beside the
  /// local file before the upload overwrote them.
  preserved,

  /// The remote copy could not be read, so it could not be protected. The
  /// upload is abandoned for this pass rather than performed blind.
  unreadable,
}

/// How long a listing of every save serves a game's status check (a
/// highlight) before it is asked for again.
const _everySaveMaxAge = Duration(seconds: 60);

/// What became of one [RomMSyncProvider._upload].
enum _UploadOutcome {
  uploaded,

  /// The file was gone by the time it would have been sent.
  noFile,

  /// The transfer failed, so the save is still pending.
  failed,
}

/// Whether a game still has a save waiting to go up, which decides whether
/// [RomMSyncProvider.uploadFailures] names the game.
enum _Pending {
  /// Every local save is on the server, or none of them is ours to send.
  none,

  /// A save is waiting. After an upload attempt, that attempt failed.
  waiting,

  /// A save was left on purpose: a file both sides changed, which a sweep
  /// leaves for the post-close hook to settle. It is still waiting, but no
  /// failure kept it there, so an earlier report of the game stands and no new
  /// one starts.
  deferred,

  /// Nothing could tell, such as a save folder that could not be read. An
  /// earlier report of the game stands.
  unknown,
}

/// What [RomMSyncProvider._syncGame] made of a game: the cloud state to show,
/// and what an upload-capable pass left waiting to go up.
typedef _GameSync = ({GameSyncStatus status, _Pending uploads});

/// What became of one [RomMSyncProvider._download]: whether it wrote, whether
/// it refused a state written by a different core, and whether it failed (the
/// server's copy could not be fetched or written, or this device's copy of a
/// save changed here could not be kept first, or would be read through a
/// link). A routine refusal (no target, an expired launch deadline, a newer
/// local copy) is none of these.
typedef _DownloadOutcome = ({bool wrote, bool coreMismatch, bool failed});

/// Identifies a game in the library. Two systems can each hold a `Same.zip`.
typedef _GameKey = ({String? system, String romname});

///
/// By [romStem], so "Game.iso" (a game list's) and "Game" (a library row's)
/// are one game.
_GameKey _keyOf(GameModel game) =>
    (system: game.systemFolderName, romname: romStem(game.romname));

/// The saves [RomMSyncProvider] could not upload, for the app to report.
class RommUploadFailures {
  /// The games whose saves are still waiting to go up, in the order they first
  /// failed.
  final List<String> games;

  /// A failure that could not say which games, such as a sweep the server
  /// stopped or one that never got going.
  final bool unidentified;

  const RommUploadFailures(this.games, {this.unidentified = false});

  static const none = RommUploadFailures([]);

  bool get isEmpty => games.isEmpty && !unidentified;
}

class RomMSyncProvider extends ChangeNotifier implements ISyncProvider {
  static const String kProviderId = 'romm';

  /// Tolerance (ms) for local-vs-recorded mtime comparisons, matching NeoSync.
  static const int _mtimeToleranceMs = 2000;

  /// Label stamped onto RomM's `emulator` field for assets we create.
  ///
  /// Deliberately a *constant*, not the save's per-core subfolder. RomM uses
  /// this value as a directory component when it stores the file, so encoding
  /// something device-specific in it gives two devices two different storage
  /// paths for one logical save — and because RomM matches assets on
  /// `(rom_id, file_name)` alone, they then fight over a single row that only
  /// ever serves whichever device created it. A device-independent label keeps
  /// every device on one path, which is what lets a save actually round-trip.
  ///
  /// Where the file belongs *locally* is a local question, answered on download
  /// from this device's own RetroArch configuration — see [_localSubfolder].
  static const String _assetLabel = 'neostation';

  /// Tests: whether folder names differing only in case are one folder, in
  /// place of the platform's answer.
  @visibleForTesting
  static bool? debugFoldersIgnoreCase;

  /// RomM `slot` sent with every save we create.
  ///
  /// A slot opts the save into RomM's `(rom_id, slot)` pairing, which is how
  /// slot-aware clients find it: `lodordev/lodor` uploads and negotiates under
  /// `const syncSlot = "autosave"` and treats a NULL slot as archival, so a
  /// save we create without one is permanently invisible to it. The name is
  /// therefore not ours to choose — it has to be the one such clients pair on.
  ///
  /// The cost is cosmetic and bounded: RomM datetime-tags a slotted upload
  /// (`<name> [YYYY-MM-DD_HH-MM-SS].<ext>`), so the save reads as tagged in
  /// RomM's own UI. It is tagged *once*, at creation — every later sync is a
  /// `PUT` to that row, which carries no slot and leaves the name alone
  /// (verified against RomM 5.2.0). [localNameForAsset] strips the tag on the
  /// way back down, so nothing local ever sees it.
  ///
  /// Saves only. `/api/states` has no slot parameter and ignores one.
  static const String _saveSlot = 'autosave';

  static final _log = LoggerService.instance;

  /// Authenticated RomM connection, shared with the library browser.
  final RommProvider _browse;

  /// Used only to locate/place local save files (path resolution reuse).
  final NeoSyncProvider _neoSync;

  /// Test seams for NeoSync's path resolution. [NeoSyncProvider]'s
  /// `locateGameSaveFiles`/`resolveLocalTargetPaths` live in an `extension`
  /// (static dispatch), so they can't be faked by subclassing — tests inject
  /// replacements here instead, mirroring [RommBulkSync.run]'s callbacks.
  final LocateGameSaves? _locateOverride;
  final ResolveSaveTargets? _resolveTargetsOverride;
  final ListLocalGames? _listGamesOverride;
  final ListSaveFolders? _saveFoldersOverride;
  final ResolveStandaloneSaveFolder? _standaloneFolderOverride;
  final ResolveLaunchCoreFolder? _launchCoreFolderOverride;
  final ResolveOtherSystemsCoreFolders? _otherSystemsCoreFoldersOverride;
  final ResolveSystemCardHome? _systemCardHomeOverride;
  final ResolveSystemCardTarget? _systemCardTargetOverride;

  final Map<String, GameSyncState> _gameSyncStates = {};

  /// The connect-time link pass. Built from [_browse] and the repositories
  /// unless a test hands one in (a subclass recording [RommLibraryLinker.run]
  /// is enough to test the schedule without a server or a database).
  late final RommLibraryLinker _linker;

  RomMSyncProvider(
    this._browse,
    this._neoSync, {
    @visibleForTesting LocateGameSaves? locateSaves,
    @visibleForTesting ResolveSaveTargets? resolveTargets,
    @visibleForTesting ListLocalGames? listGames,
    @visibleForTesting ListSaveFolders? saveFolders,
    @visibleForTesting ResolveStandaloneSaveFolder? standaloneSaveFolder,
    @visibleForTesting ResolveLaunchCoreFolder? launchCoreFolder,
    @visibleForTesting ResolveOtherSystemsCoreFolders? otherSystemsCoreFolders,
    @visibleForTesting ResolveSystemCardHome? systemCardHome,
    @visibleForTesting ResolveSystemCardTarget? systemCardTarget,
    @visibleForTesting this._autoSweep = true,
    @visibleForTesting RommLibraryLinker? linker,
    @visibleForTesting Duration sweepStartupDelay = _sweepStartupDelay,
    @visibleForTesting OpenGameGuard? openGames,
  }) : _locateOverride = locateSaves,
       _openGamesOverride = openGames,
       _resolveTargetsOverride = resolveTargets,
       _listGamesOverride = listGames,
       _saveFoldersOverride = saveFolders,
       _standaloneFolderOverride = standaloneSaveFolder,
       _launchCoreFolderOverride = launchCoreFolder,
       _otherSystemsCoreFoldersOverride = otherSystemsCoreFolders,
       _systemCardHomeOverride = systemCardHome,
       _systemCardTargetOverride = systemCardTarget,
       _startupDelay = sweepStartupDelay {
    _linker = linker ?? _buildLinker();
    if (!_autoSweep) return;
    _wasConnected = _browse.isConnected;
    _browse.addListener(_onBrowseChanged);
    // Constructed *after* the browse provider restored its saved config (see
    // main.dart) is the normal startup order, so the connect that matters has
    // usually already happened and there is no transition left to listen for.
    if (_wasConnected) _scheduleSweep();
  }

  final OpenGameGuard? _openGamesOverride;

  /// Which games may still be open in an emulator: no pass but a launch's
  /// downloads their saves (see [OpenGameGuard]).
  OpenGameGuard get _openGames => _openGamesOverride ?? OpenGameGuard.instance;

  /// Whether the save at [target] of [game] may be open in an emulator: the
  /// game may be, or, for a memory card every game of its system shares, any
  /// game of that system may be.
  bool _saveMayBeOpen(GameModel game, String target) =>
      _openGames.openIn(
        game.romname,
        game.systemFolderName,
        savePath: target,
      ) !=
      null;

  /// Whether the connect-triggered sweep is wired up. Off in tests, which drive
  /// [retryPendingUploads] directly rather than waiting out a timer.
  final bool _autoSweep;

  /// [_sweepStartupDelay], or whatever a test shortened it to.
  final Duration _startupDelay;

  bool _disposed = false;

  @override
  void dispose() {
    _disposed = true;
    if (_autoSweep) _browse.removeListener(_onBrowseChanged);
    _sweeping.dispose();
    _uploadFailures.dispose();
    super.dispose();
  }

  Future<List<LocalSaveFile>> _locateSaves(GameModel game) =>
      (_locateOverride ?? _neoSync.locateGameSaveFiles)(game);

  /// Where [game]'s downloads go (see [_Placement]). The emulator the game
  /// launches with is looked up once for both questions that need it.
  _Placement _placementFor(GameModel game) {
    Future<_LaunchEmulator?>? launch;
    Future<_LaunchEmulator?> launchEmulator() =>
        launch ??= _launchEmulator(game);
    return _Placement(
      folders: () async {
        final system = game.systemFolderName;
        return system == null || system.isEmpty
            ? const <String>[]
            : _saveFolders(system);
      },
      standalone: () => _standaloneSaveFolder(game, launchEmulator),
      coreFolder: () => _launchCoreFolder(game, launchEmulator),
      otherSystemsCores: () => _otherSystemsCoreFolders(game),
      retroArchConfig: () => RetroArchConfigService().getMergedConfig(),
      contentDir: RetroArchConfigService.contentDirName(game.romPath),
    );
  }

  /// [game]'s saves a sync of it looks at: the syncable ones found for it,
  /// with the memory cards that every game of its system shares narrowed to
  /// the ones the emulator it launches with uses.
  ///
  /// RomM keeps one copy of a save per game and file name, whatever the
  /// emulator, so two local cards of one name would both pair with it. A
  /// game that launches with a standalone emulator never uses the card a
  /// RetroArch core keeps in RetroArch's system folder. One that launches
  /// with the RetroArch core, where that core is set up, uses only the cards
  /// in the system folder: a card of the same kind elsewhere (one downloaded
  /// into the saves folder before, a standalone emulator's) is left out, and
  /// a card the server has goes into the system folder. Where the core isn't
  /// set up, nothing changes.
  Future<List<LocalSaveFile>> _passSaves(
    GameModel game,
    _Placement placement,
  ) async {
    final saves = await _readByRetroArch(
      game,
      syncableSaves(game, await _locateSaves(game)),
      placement,
    );
    final system = game.systemFolderName;
    if (!sharesMemoryCards(system)) return saves;
    bool cardNamed(LocalSaveFile s) =>
        !s.relativePath.startsWith('states/') &&
        CloudPathBuilder.isRetroArchSystemCardName(
          system,
          path.basename(s.filePath),
        );
    // Nothing to narrow: no lookup (a highlight or the sweep's check runs this
    // for every game).
    if (!saves.any((s) => s.inRetroArchSystemFolder || cardNamed(s))) {
      return saves;
    }
    final home = await _systemCardHome(system);
    // A card in the card folder, whatever claimed it: a standalone emulator's
    // save folder set to that folder lists it as that folder's.
    bool inHome(LocalSaveFile s) =>
        s.inRetroArchSystemFolder ||
        (home != null &&
            cardNamed(s) &&
            path.equals(
              path.normalize(path.absolute(path.dirname(s.filePath))),
              home,
            ));
    // The emulator is only looked up where the core is set up.
    final systemCardsUsed =
        home != null && !(await placement.standalone()).standalone;
    return [
      for (final s in saves)
        if (systemCardsUsed
            ? inHome(s) || !cardNamed(s)
            : !s.inRetroArchSystemFolder)
          s,
    ];
  }

  /// [saves] without the files in RetroArch's saves and states folders that
  /// RetroArch doesn't read for [game]. They stay on disk as they are.
  ///
  /// Where RetroArch sorts saves into folders, two kinds of file sit beside
  /// the ones it reads, with the same names (NEO-281):
  /// - another game's save in another content folder, when it sorts by the
  ///   folder the game is in. Paired by name, the server's copy of this
  ///   game's save would be written over it.
  /// - a copy in the folder's root, which an older version downloaded there
  ///   before it knew of that sorting. Paired, it would compete with the real
  ///   save for the same server copy.
  ///
  /// With RetroArch's settings read, they decide. Without them (Android), a
  /// root copy is left out only when a namesake sits in one of this game's
  /// own folders (see [_RetroArchLayout.reads]) and the copy is still exactly
  /// what NeoStation wrote: a root save RetroArch has written since is the
  /// one it uses, and keeps syncing.
  Future<List<LocalSaveFile>> _readByRetroArch(
    GameModel game,
    List<LocalSaveFile> saves,
    _Placement placement,
  ) async {
    final RetroArchConfig config;
    try {
      config = await RetroArchConfigService().getMergedConfig();
    } catch (e) {
      _log.w('RomM: could not read RetroArch settings: $e');
      return saves;
    }
    final layout = await placement.retroArch(config);
    final where = Map<LocalSaveFile, String?>.identity();
    for (final s in saves) {
      where[s] = layout.subfolderOf(s);
    }
    // Nothing in a subfolder: nothing to tell apart (the common case, and a
    // highlight's status check runs this for every game).
    if (where.values.every((sub) => sub == null || sub.isEmpty)) return saves;

    bool isState(LocalSaveFile s) => s.relativePath.startsWith('states/');
    Future<bool> rootCopyLeftOut(LocalSaveFile copy) async {
      final name = path.basename(copy.filePath);
      final namesakes = <LocalSaveFile>[];
      for (final other in saves) {
        final sub = where[other];
        if (identical(other, copy) || sub == null || sub.isEmpty) continue;
        if (isState(other) != isState(copy)) continue;
        if (path.basename(other.filePath) != name) continue;
        if (await layout.reads(sub, isState(copy))) namesakes.add(other);
      }
      if (namesakes.isEmpty) return false;
      // With the settings read, RetroArch reads one place: the namesake's.
      if (config.settingsRead) return true;
      // Without them, the root copy is a leftover only while RetroArch has
      // written the namesake since and the copy is as last synced: a root
      // save RetroArch uses is the newer one.
      final copyMs = copy.lastModified.millisecondsSinceEpoch;
      return namesakes.any(
            (n) =>
                n.lastModified.millisecondsSinceEpoch >
                copyMs + _mtimeToleranceMs,
          ) &&
          await _unchangedSinceLastSync(copy.filePath);
    }

    final kept = <LocalSaveFile>[];
    for (final s in saves) {
      final sub = where[s];
      final bool notThisGames, leftOver;
      try {
        notThisGames =
            sub != null && await layout.anotherGames(sub, isState(s));
        leftOver =
            !notThisGames &&
            sub != null &&
            sub.isEmpty &&
            await rootCopyLeftOut(s);
      } catch (e) {
        // Where RetroArch reads can't be told: kept, as before.
        _log.w('RomM ${game.romname}: could not place ${s.filePath}: $e');
        kept.add(s);
        continue;
      }
      if (notThisGames) {
        _log.d(
          'RomM ${game.romname}: ${s.filePath} left out (another game\'s '
          'folder)',
        );
        continue;
      }
      if (leftOver) {
        _log.d(
          'RomM ${game.romname}: ${s.filePath} left out (RetroArch reads the '
          'copy in a subfolder)',
        );
        continue;
      }
      kept.add(s);
    }
    return kept;
  }

  Future<String?> _systemCardHome(String? system) =>
      (_systemCardHomeOverride ?? _neoSync.retroArchSystemCardHome)(system);

  Future<List<String>?> _systemCardTarget(String system, String name) =>
      (_systemCardTargetOverride ?? _neoSync.retroArchSystemCardTarget)(
        system,
        name,
      );

  Future<List<String>> _resolveTargets(GameModel game, String relativeName) =>
      (_resolveTargetsOverride ?? _neoSync.resolveLocalTargetPaths)(
        game,
        relativeName,
      );

  Future<List<String>> _saveFolders(String systemFolderName) async {
    final override = _saveFoldersOverride;
    if (override != null) return override(systemFolderName);
    final folders = await NeoSyncSaveFolderRepository.getFoldersForSystem(
      systemFolderName,
    );
    return folders.values.toList();
  }

  /// The emulator [game] launches with, so a save lands where the emulator
  /// that will open it reads it. Null when that can't be told.
  Future<_LaunchEmulator?> _launchEmulator(GameModel game) async {
    final folderName = game.systemFolderName;
    if (folderName == null || folderName.isEmpty) return null;
    final system = await SystemRepository.getSystemByFolderName(folderName);
    if (system == null) return null;
    final uniqueId = await GameLaunchService.resolveLaunchEmulatorId(
      system,
      game,
    );
    if (uniqueId == null) return null;
    return (
      system: system,
      uniqueId: uniqueId,
      emulators: await loadEmulatorsForSystem(system),
    );
  }

  Future<({bool standalone, String? folder})> _standaloneSaveFolder(
    GameModel game,
    Future<_LaunchEmulator?> Function() launchEmulator,
  ) async {
    final override = _standaloneFolderOverride;
    if (override != null) return override(game);
    final launch = await launchEmulator();
    if (launch == null) return (standalone: false, folder: null);
    return standaloneSaveFolderFor(
      uniqueId: launch.uniqueId,
      emulators: launch.emulators,
      folders: await NeoSyncSaveFolderRepository.getFoldersForSystem(
        launch.system.folderName,
      ),
    );
  }

  /// RetroArch's folder name for the core [game] launches with (NEO-279),
  /// or null when it launches with a standalone emulator or that can't be
  /// told.
  Future<String?> _launchCoreFolder(
    GameModel game,
    Future<_LaunchEmulator?> Function() launchEmulator,
  ) async {
    final override = _launchCoreFolderOverride;
    if (override != null) return override(game);
    final launch = await launchEmulator();
    if (launch == null) return null;
    return launchCoreFolderFor(
      uniqueId: launch.uniqueId,
      emulators: launch.emulators,
    );
  }

  /// RetroArch's folder name for the emulator [uniqueId] among [emulators]:
  /// its core's name, or null when it isn't a RetroArch core or isn't listed.
  @visibleForTesting
  static String? launchCoreFolderFor({
    required String uniqueId,
    required List<CoreEmulatorModel> emulators,
  }) => RetroArchConfigService.coreFolderName(
    emulators.where((e) => e.uniqueId == uniqueId).firstOrNull?.name,
  );

  Future<Set<String>> _otherSystemsCoreFolders(GameModel game) async {
    final override = _otherSystemsCoreFoldersOverride;
    if (override != null) return override(game);
    final folderName = game.systemFolderName;
    if (folderName == null || folderName.isEmpty) return const {};
    final system = await SystemRepository.getSystemByFolderName(folderName);
    if (system?.id == null) return const {};
    return otherSystemsCoreFoldersFor(
      systemId: system!.id!,
      emulators: await EmulatorRepository.getEmulatorNamesCurrentOs(),
    );
  }

  /// RetroArch's folder names for the cores of every system but [systemId]
  /// among [emulators], leaving out any core [systemId] has too. In lower
  /// case: systems spell one core differently (`Picodrive`, `PicoDrive`).
  @visibleForTesting
  static Set<String> otherSystemsCoreFoldersFor({
    required String systemId,
    required List<({String systemId, String name})> emulators,
  }) {
    final mine = <String>{}, others = <String>{};
    for (final e in emulators) {
      final folder = RetroArchConfigService.coreFolderName(e.name);
      if (folder == null) continue;
      (e.systemId == systemId ? mine : others).add(folder.toLowerCase());
    }
    return others.difference(mine);
  }

  /// Whether the emulator [uniqueId] is standalone, and the save folder
  /// configured for it in [folders] (by emulator unique id), if any.
  ///
  /// Decided as the folder picker decides it: a RetroArch core is never
  /// standalone, even when it is flagged so, and an emulator this device
  /// doesn't list is treated as not standalone, which keeps the RetroArch
  /// placement used before standalone folders were known here.
  @visibleForTesting
  static ({bool standalone, String? folder}) standaloneSaveFolderFor({
    required String uniqueId,
    required List<CoreEmulatorModel> emulators,
    required Map<String, String> folders,
  }) {
    const notStandalone = (standalone: false, folder: null);
    if (CloudPathBuilder.slugFromEmulatorUniqueId(uniqueId)
        .startsWith('retroarch.')) {
      return notStandalone;
    }
    final emulator = emulators.where((e) => e.uniqueId == uniqueId).firstOrNull;
    if (emulator == null || !emulator.isStandalone) return notStandalone;
    final folder = folders[uniqueId];
    return (
      standalone: true,
      folder: folder == null || folder.isEmpty ? null : folder,
    );
  }

  /// Where a download of [asset] is written: null when it must not be
  /// written at all (the reason is logged).
  ///
  /// A standalone emulator reads its saves from the folder configured for it,
  /// never from RetroArch's saves folder, so its downloads go there: onto the
  /// file they replace when that file is in a configured folder ([paired]),
  /// or into the emulator's folder otherwise (a copy outside its folders is
  /// never paired for such a game; see the reconcile loop in [_syncGame]). A
  /// standalone emulator with no folder gets nothing, rather than a copy in
  /// RetroArch's folder that no emulator opens. A memory card that every game
  /// of its system shares goes into RetroArch's system folder where the core
  /// keeps it there (see [_passSaves]): onto the card when it is one there,
  /// into the card folder when this device has none, and nowhere when
  /// something else is in its place. Everything else is placed the RetroArch
  /// way, by [_resolveTargets].
  ///
  /// A file in a configured folder goes back where it came from: the copy a
  /// sync pairs is the one the launch emulator uses (see [_passSaves]).
  Future<List<String>?> _downloadTargets(
    GameModel game,
    RommAsset asset, {
    required String relativeName,
    required String localName,
    required _Placement placement,
    LocalSaveFile? paired,
  }) async {
    if (paired != null && await placement.inSaveFolder(paired.filePath)) {
      return [paired.filePath];
    }
    final standalone = await placement.standalone();
    if (standalone.standalone) {
      final folder = standalone.folder;
      if (folder == null) {
        _log.i(
          'RomM download: ${asset.fileName} not written — ${game.romname} '
          'launches with a standalone emulator with no save folder set',
        );
        return null;
      }
      if (asset.isState) {
        _log.i(
          'RomM download: ${asset.fileName} not written — a save state, and '
          '${game.romname} launches with a standalone emulator',
        );
        return null;
      }
      final target = safeJoin(folder, localName);
      return target == null ? const [] : [target];
    }
    // The card a RetroArch core keeps in RetroArch's system folder is written
    // where it is; one this device lacks goes there when the core is set up
    // (see [_passSaves]).
    if (!asset.isState && paired != null && paired.inRetroArchSystemFolder) {
      return [paired.filePath];
    }
    final system = game.systemFolderName;
    if (!asset.isState &&
        system != null &&
        sharesMemoryCards(system) &&
        CloudPathBuilder.isRetroArchSystemCardName(system, localName)) {
      // Empty when something is already in its place: nothing is written.
      final target = await _systemCardTarget(system, localName);
      if (target != null) return target;
    }
    // The save this device has, where it is one RetroArch reads for this
    // game (NEO-281): exactly the file, even when the settings can't say
    // which subfolder RetroArch uses.
    if (paired != null) {
      try {
        final layout = await placement.retroArch();
        final sub = layout.subfolderOf(paired);
        if (sub != null && await layout.reads(sub, asset.isState)) {
          return [paired.filePath];
        }
      } catch (e) {
        _log.w('RomM download: could not tell where RetroArch reads: $e');
      }
    }
    return _resolveTargets(game, relativeName);
  }

  /// The library, for the sweep. Injectable for the same reason the path
  /// resolution is: reaching the real one means seeding `user_roms` and its
  /// system join, which says nothing about the behaviour under test.
  Future<List<GameModel>> _listGames() async {
    final override = _listGamesOverride;
    if (override != null) return override();
    final rows = await GameRepository.getAllGames();
    return rows.map(GameModel.fromDatabaseModel).toList();
  }

  RommService get _svc => _browse.service;

  // ── Identity ───────────────────────────────────────────────────────────────

  @override
  String get providerId => kProviderId;

  @override
  SyncProviderMeta get meta => const SyncProviderMeta(
    id: kProviderId,
    name: 'RomM',
    description:
        'Self-hosted sync via your own RomM instance. Uses your RomM '
        'connection — only games downloaded from RomM are synced.',
    author: 'Community',
    iconAssetPath: 'assets/icons/romm.png',
  );

  // ── State ──────────────────────────────────────────────────────────────────

  @override
  SyncProviderStatus get status {
    switch (_browse.status) {
      case RommConnectionStatus.connected:
        return SyncProviderStatus.connected;
      case RommConnectionStatus.connecting:
        return SyncProviderStatus.connecting;
      case RommConnectionStatus.error:
        return SyncProviderStatus.error;
      case RommConnectionStatus.disconnected:
        return SyncProviderStatus.disconnected;
    }
  }

  @override
  bool get isAuthenticated => _browse.isConnected;

  /// The connection's error only. The browse provider also records failed
  /// searches and collection loads, which say nothing about syncing saves.
  @override
  String? get lastError =>
      _browse.status == RommConnectionStatus.error ? _browse.lastError : null;

  // ── Lifecycle ──────────────────────────────────────────────────────────────

  @override
  Future<void> initialize() async {
    // The browse RommProvider restores config + tokens in its own initialize().
  }

  // ── Authentication ─────────────────────────────────────────────────────────

  @override
  Future<SyncResult> login() async {
    if (_browse.isConnected) return SyncResult.ok();
    return SyncResult.fail(
      SyncError.authRequired,
      message: 'Connect to RomM in Settings → RomM first',
    );
  }

  @override
  Future<void> logout() async {
    _everySaveCache = null;
    await _browse.disconnect();
  }

  // ── Mapping / discovery helpers ─────────────────────────────────────────────

  /// Resolves the RomM `rom_id` for [game], or null if the game isn't linked
  /// to a RomM ROM (i.e. wasn't downloaded from RomM).
  Future<int?> _resolveRomId(GameModel game) async {
    final systemFolder = game.systemFolderName;
    if (systemFolder == null || systemFolder.isEmpty) return null;
    return RommSaveMapRepository.getRommRomId(game.romname, systemFolder);
  }

  GameSyncState _buildState(
    GameModel game,
    GameSyncStatus status, {
    String? errorMessage,
  }) => GameSyncState(
    gameId: game.romname,
    gameName: game.name,
    status: status,
    // Null counts as disabled, matching the [_syncGame] gate and NeoSync.
    cloudEnabled: game.cloudSyncEnabled == true,
    errorMessage: errorMessage,
  );

  // ── Core per-game sync ──────────────────────────────────────────────────────

  /// Bidirectional sync for [game]. When [downloadOnly] is true (pre-launch),
  /// only newer/missing remote files are pulled; otherwise local changes are
  /// also pushed.
  ///
  /// [statusOnly] reconciles without transferring anything, for the cloud-state
  /// indicator. Moving the highlight onto a game in the list must not push or
  /// pull a save: the transfers belong to the launch lifecycle, where the user
  /// has actually asked for the game.
  ///
  /// What it reports left to upload is [_Pending.unknown] when the pass never
  /// got as far as comparing the saves (no connection, or a listing that
  /// failed), for the caller to answer from the disk. When only one of the two
  /// listings failed, the other kind is synced as usual and the game still
  /// reports [GameSyncStatus.error].
  Future<_GameSync> _syncGame(
    GameModel game, {
    required bool downloadOnly,
    bool statusOnly = false,
    bool uploadOnly = false,
    SyncDeadline? deadline,
  }) async {
    if (!_browse.isConnected) {
      return (status: GameSyncStatus.error, uploads: _Pending.unknown);
    }
    const disabled = (status: GameSyncStatus.disabled, uploads: _Pending.none);
    // Honour the sync opt-outs exactly the way NeoSync does: a null per-game
    // flag counts as disabled, and a system whose config sets `sync: false`
    // (e.g. shared-memcard systems the user deliberately excluded) is skipped
    // regardless of the per-game flag.
    if (game.cloudSyncEnabled != true) return disabled;
    final systemFolder = game.systemFolderName;
    if (systemFolder != null && systemFolder.isNotEmpty) {
      final system = await SystemRepository.getSystemByFolderName(systemFolder);
      if (system != null && !system.neosync.sync) return disabled;
    }

    final romId = await _resolveRomId(game);
    if (romId == null) {
      // Not a RomM-linked game (wasn't downloaded through the app). Report
      // "disabled" — sync simply doesn't apply — rather than "no save found",
      // which would be a lie whenever the game has perfectly good local saves.
      return disabled;
    }

    // Where downloads go, worked out once per pass and only if one needs it:
    // finding the game's emulator enumerates the system's emulators.
    final placement = _placementFor(game);

    // A game that may still be open in an emulator (on Android, NeoStation
    // coming back to the front doesn't mean it closed): a save written now
    // would be ignored, then overwritten by the emulator's own copy. Only a
    // launch downloads its saves; this pass leaves them for the next one
    // ("left for a launch") and still uploads.
    final noPulls =
        deadline == null &&
        !statusOnly &&
        _openGames.mayBeOpen(game.romname, game.systemFolderName);

    // The two listings are independent GETs; fetch them concurrently so the
    // launch-blocking sync pays one round-trip, not two serial ones. Each is
    // also independent in failure: RomM can fail one (its states route, say)
    // while the other answers, and the kind that listed still syncs. They are
    // asked for before this device's saves are looked at, which reads
    // RetroArch's configuration and may look up the game's emulator.
    Future<List<RommAsset>?> listed(
      String kind,
      Future<List<RommAsset>> Function() list,
    ) async {
      try {
        return await list();
      } catch (e) {
        _log.e('RomM list$kind failed for ${game.romname}: $e');
        return null;
      }
    }

    final listings = Future.wait([
      listed('Saves', () => _svc.listSaves(romId: romId)),
      listed('States', () => _svc.listStates(romId: romId)),
    ]);
    final localFiles = await _passSaves(game, placement);

    // PS2 and Dreamcast: every game of the system shares the memory cards.
    final sharesCards = sharesMemoryCards(game.systemFolderName);
    final localCards = sharesCards
        ? localFiles
              .where(
                (l) =>
                    !l.relativePath.startsWith('states/') &&
                    isSharedMemoryCard(l.filePath),
              )
              .toList()
        : const <LocalSaveFile>[];
    // A launch on a device with no card yet places the server's, from any
    // game (step 3 below): the emulator would otherwise make a blank one, and
    // the session played on it would end up in a copy when the next launch
    // takes the server's.
    final placeCards =
        sharesCards &&
        !localCards.any(
          (l) => CloudPathBuilder.isRetroArchSystemCardName(
            game.systemFolderName,
            path.basename(l.filePath),
          ),
        ) &&
        downloadOnly &&
        !statusOnly &&
        deadline != null;
    // Every save the user has, under any game: asked for only for a card this
    // device has never synced, or one to place, and alongside this game's
    // listings, so a launch waits for one round trip. Null when the listing
    // failed.
    Future<List<RommAsset>?>? everySave;
    if (placeCards || await _anyNeverSynced(localCards)) {
      everySave = _everySaveListed(fresh: !statusOnly);
    }

    final results = await listings;
    final savesListed = results[0] != null;
    final statesListed = results[1] != null;
    if (!savesListed && !statesListed) {
      return (status: GameSyncStatus.error, uploads: _Pending.unknown);
    }
    // Collapse a slot's version history before anything looks at the listing,
    // so the pairing loop and the remote-only pass below agree on which asset
    // represents each local file. Conflict backups are dropped first: they
    // must never reach the pairing loop, and filtering them here is cheaper
    // than deduping them and discarding the survivor.
    final remote = latestPerLocalName(
      syncableRemote([...?results[0], ...?results[1]]),
    );
    // Only the local files of a kind that listed are compared. With no
    // listing, a local file would look missing on the server and take the
    // local-only upload, which RomM applies by file name: it could replace a
    // newer copy that nothing here has seen.
    final partial = !savesListed || !statesListed;
    final reconciled = partial
        ? localFiles
              .where(
                (l) => l.relativePath.startsWith('states/') == statesListed,
              )
              .toList()
        : localFiles;

    // Assets already paired with a local file. Keyed by kind *and* id: the two
    // endpoints number their rows independently, so a bare id would let a save
    // mask a state that happens to share it.
    final matchedRemote = <({bool isState, int id})>{};
    int uploaded = 0, downloaded = 0, coreMismatched = 0;
    int conflictsPreserved = 0, uploadsFailed = 0, uploadsDeferred = 0;
    // The conflict copies this pass keeps, by save; see the tidy below.
    final keptThisPass = <String, String>{};
    int downloadsFailed = 0;
    void countUpload(_UploadOutcome outcome) {
      if (outcome == _UploadOutcome.uploaded) uploaded++;
      if (outcome == _UploadOutcome.failed) uploadsFailed++;
    }

    void countDownload(_DownloadOutcome r) {
      if (r.wrote) downloaded++;
      if (r.coreMismatch) coreMismatched++;
      if (r.failed) downloadsFailed++;
    }

    bool anyLocal = reconciled.isNotEmpty;
    bool anyRemote = remote.isNotEmpty;

    // A card this device has never synced, left for the next launch to take
    // or for the next post-close sync to send: not up to date. Unchecked: the
    // listing of every save failed, so nothing was decided for it.
    var takeLeftForLaunch = false, uploadLeftForClose = false;
    var cardsUnchecked = false;

    // 1) Reconcile each local file against its remote counterpart.
    for (final local in reconciled) {
      // A game that launches with a standalone emulator only has the copy in
      // that emulator's folder. One elsewhere — RetroArch's, as an older
      // version downloaded it there — is not its save: pairing it would keep
      // fetching the server's copy into the folder and never settle, or, with
      // the server unchanged, leave the folder without the save. Left out, the
      // server's copy is placed like any save this device lacks.
      // Only asked on a system with folders set, so a highlighted game's
      // status check doesn't enumerate emulators for every RetroArch game.
      if ((await placement.folders()).isNotEmpty &&
          !await placement.inSaveFolder(local.filePath) &&
          (await placement.standalone()).standalone) {
        continue;
      }
      final isState = local.relativePath.startsWith('states/');
      final baseName = path.basename(local.filePath);
      RommAsset? match;
      for (final a in remote) {
        // The remote name is normalised, never the local one: a slotted asset
        // is `Game [2026-07-24_01-20-16].srm` server-side and `Game.srm` here.
        if (a.isState == isState && localNameForAsset(a) == baseName) {
          match = a;
          break;
        }
      }
      if (match != null) matchedRemote.add(match.key);

      final localMs = local.lastModified.millisecondsSinceEpoch;
      final sharedCard =
          sharesCards && !isState && isSharedMemoryCard(local.filePath);
      final recorded = sharedCard
          ? await _cardSyncRecord(local.filePath)
          : await SyncRepository.getSyncState(kProviderId, local.filePath);

      // A memory card every game of its system shares, which this device has
      // never synced with RomM. The server's card wins, as NeoSync's does
      // (#849): one that differs is taken by the launch, this device's kept
      // as a dated copy. Pushing it instead is how a blank card an emulator
      // has just made on a new device replaced the real one. RomM keeps a
      // copy under every game, so the server's card is the newest copy of
      // that name under any game: a game with no copy of its own is no sign
      // the server has no card.
      if (sharedCard && recorded == null) {
        everySave ??= _everySaveListed(fresh: !statusOnly);
        final saves = await everySave;
        if (saves == null) {
          // Where the newest copy is can't be told, so nothing is taken or
          // sent: this game's own copy may be an old one. After a game
          // closes, that is a save that may not have gone up: reported, and
          // retried by the sweep, as a failed upload is.
          cardsUnchecked = true;
          if (!downloadOnly && !uploadOnly) {
            uploadsFailed++;
          } else if (!downloadOnly) {
            uploadsDeferred++;
          }
          continue;
        }
        final card = _serverCard(baseName, match, saves);
        // A post-close sync of it that failed is retried by the sweep, which
        // lists afresh as post-close does.
        final retry = uploadOnly && _failedUploads.containsKey(_keyOf(game));
        if (card == null) {
          if (!downloadOnly && (!uploadOnly || retry)) {
            // No copy anywhere: the first device's card goes up, once a
            // session has ended (as for any new save). Not otherwise from a
            // sweep, which has no session to vouch for it.
            countUpload(await _upload(romId, local, isState));
          } else {
            if (!downloadOnly) uploadsDeferred++;
            uploadLeftForClose = true;
            if (!statusOnly) {
              _log.i(
                'RomM: $baseName not synced from this device before and on '
                'no game on the server — it goes up after the game closes',
              );
            }
          }
          continue;
        }
        final digest = await _md5OfFile(local.filePath);
        if (digest != null &&
            await _serverHoldsSameBytes(card, digest, local)) {
          // The same card: recorded, so later changes sync as usual. A
          // status check writes nothing.
          if (!statusOnly) {
            await _recordSynced(local, card.updatedAtMs, digest);
          }
          if (match != null || statusOnly || downloadOnly || uploadOnly) {
            continue;
          }
          // Recorded, and this game has no copy: it goes up below, like any
          // save the server lacks.
        } else if (downloadOnly && !statusOnly && deadline != null) {
          // Only the launch takes it: elsewhere an emulator may still have
          // the card open (Android can't tell), and only the launch knows
          // nothing is using it yet.
          if (await FileSystemEntity.type(local.filePath, followLinks: false) ==
              FileSystemEntityType.link) {
            // Its copy would read through the link (see [_download]), and
            // without one the take would lose it: left as it is.
            takeLeftForLaunch = true;
            _log.w(
              'RomM: $baseName not synced from this device before, and a '
              'link — left as it is, not taken and not uploaded',
            );
            continue;
          }
          final taken = await _download(
            game,
            card,
            localFiles: localFiles,
            placement: placement,
            paired: local,
            deadline: deadline,
            firstCardSync: true,
          );
          countDownload(taken);
          // Abandoned at the deadline: still the next launch's to take.
          if (!taken.wrote && !taken.failed) takeLeftForLaunch = true;
          continue;
        } else {
          // The card is the next launch's to take. For a retry of a failed
          // post-close sync that settles it: nothing of it is to go up.
          if (!downloadOnly && !retry) uploadsDeferred++;
          takeLeftForLaunch = true;
          if (!statusOnly) {
            _log.i(
              'RomM: ${path.basename(local.filePath)} not synced from this '
              'device before and not the server\'s card — left for the next '
              'launch, which takes the server\'s and keeps this one',
            );
          }
          continue;
        }
      }

      final recordedLocalMs = (recorded?['local_modified_at'] as int?) ?? 0;
      final recordedCloudMs = (recorded?['cloud_updated_at'] as int?) ?? 0;

      final localChanged =
          recorded == null || localMs > recordedLocalMs + _mtimeToleranceMs;

      if (match == null) {
        // Local only → upload (unless pre-launch download-only pass).
        if (!downloadOnly && !statusOnly) {
          countUpload(await _upload(romId, local, isState));
        }
        continue;
      }

      final remoteChanged = match.updatedAtMs > recordedCloudMs;

      // Pull when the server has moved on. Requiring an *untouched* local copy
      // here sounds safer than it is: RetroArch rewrites `<game>.state.auto` on
      // every exit whenever auto-save-state is on — a common setting — so
      // `localChanged` is true essentially always, and a pre-launch pass that
      // insisted on it would never pull anything. Cross-device sync would be
      // dead for those users rather than merely occasionally stale.
      //
      // Attempting the pull is safe because it is not the decision that
      // overwrites anything: [_download]'s per-target guard refuses to write
      // over a local file newer than the remote whose bytes changed since the
      // last sync, so a genuinely-ahead local save survives and simply uploads
      // on the next upload-capable pass.
      // What changes is only the case where the server copy is strictly newer
      // than the local one, which is exactly the other device's session.
      //
      // Deliberately scoped to the download-only (pre-launch) pass. After a
      // game closes, the session that just ended still wins outright — that is
      // the [localChanged] branch below, untouched.
      if (statusOnly) {
        continue;
      } else if (remoteChanged && (!localChanged || downloadOnly)) {
        // A retry sweep exists to push what a failed upload left behind; the
        // pull belongs to the pre-launch hook, which knows a game is about to
        // start and has a deadline to answer to.
        if (uploadOnly) continue;
        // "The server moved on" is a statement about timestamps, not content.
        // A device that uploaded, then another that pulled and re-uploaded the
        // identical file, both bump `updated_at` without a byte changing — and
        // RomM's own `content_hash` says so for free. Hashing the local file
        // costs a fraction of the transfer it replaces, and settling the pair
        // here also stops the mtime path re-asking the same question forever.
        final pullDigest = await _md5OfFile(local.filePath);
        if (pullDigest != null &&
            await _serverHoldsSameBytes(match, pullDigest, local)) {
          await _recordSynced(local, match.updatedAtMs, pullDigest);
          continue;
        }
        if (noPulls) {
          takeLeftForLaunch = true;
          _log.i(
            'RomM: ${path.basename(local.filePath)} left for the next launch '
            '— the game may still be open in an emulator',
          );
          continue;
        }
        countDownload(
          await _download(
            game,
            match,
            localFiles: localFiles,
            placement: placement,
            paired: local,
            deadline: deadline,
          ),
        );
      } else if (localChanged && !downloadOnly) {
        // Local newer (or both changed → prefer local). The asset exists, so
        // this replaces it in place rather than creating a second one.
        //
        // "Prefer local" is only defensible when a session just ended, which is
        // the post-close hook's authority and not a sweep's: a sweep runs on
        // connect, with nothing to say the local copy is the newer *session*.
        // Pushing a both-changed file from here is exactly how the item-5
        // hazard comes back — the other device's newer save overwritten by an
        // older local one — so a sweep leaves ties to the hook that can settle
        // them.
        if (uploadOnly && remoteChanged) {
          uploadsDeferred++;
          continue;
        }
        // `localChanged` is an mtime answer, and mtime lies in the direction
        // that costs the most: RetroArch rewrites `<game>.state.auto` on every
        // exit whether or not the bytes moved, so a device with auto-save-state
        // on re-uploads the same file after every session. Two hashes settle
        // it — the one recorded at the last sync (which covers states, where
        // RomM has no `content_hash` of its own) and the server's, which
        // catches a second device that already pushed these exact bytes.
        final pushDigest = await _md5OfFile(local.filePath);
        if (pushDigest != null) {
          // Both hashes are asked, never short-circuited, because the answers
          // are not interchangeable: only the server's says anything about the
          // copy that is actually up there. The recorded hash says this device
          // has not changed its file, which is reason enough to skip the
          // upload but no reason at all to claim [match] has been seen — and
          // recording its stamp would mark a remote copy consumed that nothing
          // ever compared or fetched, leaving `remoteChanged` false from then
          // on and stranding the other device's save for good. So the cloud
          // stamp only moves when [_serverHoldsSameBytes] vouched for it;
          // otherwise it stays put and the next pass, with the local mtime now
          // settled, takes the pull branch and collects what is waiting.
          //
          // States live on this path exclusively — RomM gives them no
          // `content_hash` to check — so it carries the ordinary two-device
          // case, not an exotic one.
          final serverMatches = await _serverHoldsSameBytes(
            match,
            pushDigest,
            local,
          );
          if (serverMatches || pushDigest == recorded?['file_hash']) {
            await _recordSynced(
              local,
              serverMatches ? match.updatedAtMs : recordedCloudMs,
              pushDigest,
            );
            continue;
          }
        }
        // Both sides moved since this device last agreed with the server, and
        // the gate above has ruled out the false alarms (identical bytes, an
        // untouched local file). What is left is a real conflict, and pushing
        // over it is what destroyed another device's state on `main`. The
        // outcome still prefers local — the session that just ended wins — but
        // the copy it replaces is kept first.
        String? keptCopy;
        if (remoteChanged) {
          final guard = await _guardDivergedRemote(
            match,
            local,
            recordedHash: recorded?['file_hash'] as String?,
            pushDigest: pushDigest,
            onKept: (copy) {
              keptThisPass[local.filePath] = copy;
              keptCopy = copy;
            },
          );
          if (guard == _RemoteGuard.unreadable) {
            // Nothing recorded: the file stays pending and the next pass asks
            // again, which is the non-destructive way to fail. Still a failed
            // upload: the save the session just made is not on the server.
            _log.w(
              'RomM: leaving ${path.basename(local.filePath)} pending — the '
              'remote copy it would replace could not be read',
            );
            uploadsFailed++;
            continue;
          }
          if (guard == _RemoteGuard.preserved) conflictsPreserved++;
        }
        final outcome = await _upload(
          romId,
          local,
          isState,
          existing: match,
          digest: pushDigest,
        );
        countUpload(outcome);
        // Only once this device's copy has replaced the other on the server:
        // until then the kept copy is not yet the only one left.
        final kept = keptCopy;
        if (kept != null && outcome == _UploadOutcome.uploaded) {
          reportKeptCloudCopy(
            gameName: game.name,
            savePath: local.filePath,
            backupPath: kept,
          );
        }
      }
    }

    // A card to place comes from every game's listing (step 3), so this
    // game's own copy, which may be an older one, isn't placed here first.
    final cardsToPlace = placeCards ? await everySave : null;
    bool placeable(RommAsset a) =>
        !a.isState &&
        CloudPathBuilder.isRetroArchSystemCardName(
          game.systemFolderName,
          localNameForAsset(a),
        );

    // 2) Remote-only files → download.
    for (final a in remote) {
      if (statusOnly || uploadOnly) break;
      if (matchedRemote.contains(a.key)) continue;
      if (cardsToPlace != null && placeable(a)) continue;
      if (noPulls) {
        // As above: the next launch places it.
        takeLeftForLaunch = true;
        continue;
      }
      countDownload(
        await _download(
          game,
          a,
          localFiles: localFiles,
          placement: placement,
          deadline: deadline,
        ),
      );
    }

    // 3) No memory card on this device yet: the server's cards, the newest
    // copy of each under any game, are placed like any download.
    if (placeCards) {
      if (cardsToPlace == null) {
        cardsUnchecked = true;
      } else {
        for (final a in cardsToPlace.where(placeable)) {
          final placed = await _download(
            game,
            a,
            localFiles: localFiles,
            placement: placement,
            deadline: deadline,
          );
          countDownload(placed);
          anyRemote = true;
          // Abandoned at the deadline: the next launch's to place. One that
          // can't go there (something already in its place) isn't.
          if (!placed.wrote && !placed.failed && deadline.isExpired) {
            takeLeftForLaunch = true;
          }
        }
      }
    }

    _log.i(
      'RomM sync ${game.romname}: $uploaded up, $downloaded down '
      '(${reconciled.length} local, ${remote.length} remote)'
      '${partial ? ', ${savesListed ? 'states' : 'saves'} not listed' : ''}'
      '${uploadsFailed > 0 ? ', $uploadsFailed upload(s) failed' : ''}'
      '${downloadsFailed > 0 ? ', $downloadsFailed download(s) failed' : ''}'
      '${uploadsDeferred > 0 ? ', $uploadsDeferred deferred' : ''}'
      '${coreMismatched > 0 ? ', $coreMismatched kept (different core)' : ''}'
      '${conflictsPreserved > 0 ? ', $conflictsPreserved conflict backup(s)' : ''}',
    );

    // A save this pass kept a conflict copy of now has one more copy; at most
    // a few stay. Only the post-close pass keeps conflict copies, so the
    // pre-launch pass reads nothing here (a copy of this device's save kept
    // before a download is tidied where it is kept, in [_download]).
    for (final MapEntry(key: save, value: copy) in keptThisPass.entries) {
      await tidyKeptCopies(
        save,
        sources: rommKeptCopySources,
        justKept: {copy},
      );
    }

    // Playtime rides along with the upload-capable passes only. The pre-launch
    // pass is on the launch's critical path and playtime changes nothing about
    // the game that's about to start, so it stays out of that budget.
    if (!downloadOnly && !statusOnly) {
      await _syncPlaytime(game, romId);
    }

    // A save that didn't reach the server is still pending, which no status
    // below can say: "local only" or "up to date" would read as success.
    if (uploadsFailed > 0) {
      return (status: GameSyncStatus.error, uploads: _Pending.waiting);
    }
    // The kind that didn't list was never compared, so whether it has a save
    // waiting is for the disk to say, as after a listing that failed outright.
    if (partial) {
      return (status: GameSyncStatus.error, uploads: _Pending.unknown);
    }
    final uploads = uploadsDeferred > 0 ? _Pending.deferred : _Pending.none;
    // A save the server has that didn't come down is as much a failed sync as
    // one that didn't go up: the game would start on the older copy.
    if (downloadsFailed > 0) {
      return (status: GameSyncStatus.error, uploads: uploads);
    }
    if (cardsUnchecked) {
      return (status: GameSyncStatus.error, uploads: uploads);
    }
    if (takeLeftForLaunch) {
      return (status: GameSyncStatus.cloudOnly, uploads: uploads);
    }
    if (uploadLeftForClose) {
      return (status: GameSyncStatus.localOnly, uploads: uploads);
    }
    if (!anyLocal && !anyRemote) {
      return (status: GameSyncStatus.noSaveFound, uploads: uploads);
    }
    if (!anyRemote) return (status: GameSyncStatus.localOnly, uploads: uploads);
    if (!anyLocal && downloaded == 0) {
      return (status: GameSyncStatus.cloudOnly, uploads: uploads);
    }
    return (status: GameSyncStatus.upToDate, uploads: uploads);
  }

  /// Pushes queued play sessions and pulls back playtime recorded elsewhere.
  ///
  /// Best-effort by design: playtime is a statistic, so a failure here must
  /// never change the save-sync status the user is shown, and never throw into
  /// the launch/close flow. [RommPlaytimeService] throttles the pull itself, so
  /// this is cheap to call from the per-selection save detection.
  Future<void> _syncPlaytime(GameModel game, int romId) async {
    if (!_svc.playtimeSyncAvailable) return;
    try {
      await RommPlaytimeService.flushQueuedSessions(_svc);
      final romPath = game.romPath;
      if (romPath != null && romPath.isNotEmpty) {
        await RommPlaytimeService.pullPlaytime(
          _svc,
          romId: romId,
          romPath: romPath,
        );
      }
    } catch (e) {
      _log.w('RomM playtime sync failed for ${game.romname}: $e');
    }
  }

  /// Extracts the save-folder subpath (e.g. RetroArch's per-core `FCEUmm`
  /// folder) from a local file's `saves/…`/`states/…` relative path, so it can
  /// be preserved across the round-trip via RomM's `emulator` field. Returns
  /// empty when the file sits directly in the saves/states root.
  /// Extensions RetroArch writes *beside* a save state as its thumbnail. These
  /// are screenshots, not save data — RetroArch regenerates them, and RomM has
  /// a dedicated `screenshotFile` field for the one place a thumbnail belongs.
  static const Set<String> _thumbnailExtensions = {
    '.png',
    '.jpg',
    '.jpeg',
    '.bmp',
  };

  /// Narrows the locator's results to files that are really [game]'s save data.
  ///
  /// NeoSync's locator matches any file whose name *contains* the game name and
  /// applies no extension filter at all. That looseness is load-bearing for the
  /// cases it was built for — shared PS2/Dreamcast memory cards and Switch
  /// saves matched by title id, neither of which carries the game's name in the
  /// filename — so it is left alone and tightened here, at RomM's door.
  ///
  /// Three things get dropped:
  ///
  /// * **Thumbnails.** A `.state.png` was being uploaded to RomM as a save
  ///   state. Confirmed on device: one play session produced four "states",
  ///   two of which were screenshots.
  /// * **A longer-named game's saves.** `contains` makes the match one-way:
  ///   a game called `Extra Mario Bros.` matches `Extra Mario Bros. [Hacks].state`,
  ///   so the shorter title would sync the longer one's saves as its own. A
  ///   file is rejected only when it can be *proved* to belong elsewhere —
  ///   its name starts with this game's name but continues with something
  ///   other than an extension. Files that don't start with the game's name at
  ///   all are left untouched, which is what keeps the memory-card and Switch
  ///   paths working.
  @visibleForTesting
  static List<LocalSaveFile> syncableSaves(
    GameModel game,
    List<LocalSaveFile> found,
  ) {
    final romName = _romNameWithoutExtension(game.romname).toLowerCase();

    return found.where((f) {
      final name = path.basename(f.filePath);
      final lower = name.toLowerCase();

      // Kept copies of saves (our conflict backups, this device's copies kept
      // before a download, NeoSync's). They begin with the game's name and
      // continue with a dot, so every other rule here reads them as ordinary
      // save data — and uploading a copy kept precisely because it was *not*
      // the save to sync would undo the point of keeping it.
      if (isKeptCopyPath(name)) {
        _log.i('RomM: skipping kept copy $name');
        return false;
      }

      if (_thumbnailExtensions.contains(path.extension(lower))) {
        _log.i('RomM: skipping thumbnail $name');
        return false;
      }

      if (romName.isNotEmpty && lower.startsWith(romName)) {
        final remainder = lower.substring(romName.length);
        // '' is the game's own name verbatim; '.state', '.state.auto', '.srm'
        // are its saves. Anything else — ' [Hacks].state' — is another title's.
        if (remainder.isNotEmpty && !remainder.startsWith('.')) {
          _log.i('RomM: skipping $name (belongs to a longer-named title)');
          return false;
        }
      }

      return true;
    }).toList();
  }

  /// Drops a single trailing extension, matching how the library indexes a
  /// ROM's name. Only the last one: a title may contain dots of its own.
  static String _romNameWithoutExtension(String romname) => romStem(romname);

  /// RomM's server-applied version tag, copied verbatim from its own
  /// `DATETIME_TAG_PATTERN` (`backend/endpoints/saves.py`, RomM 5.1.0).
  static final RegExp _datetimeTag = RegExp(
    r' \[\d{4}-\d{2}-\d{2}_\d{2}-\d{2}-\d{2}\]',
  );

  /// The local filename [asset] belongs under, with RomM's datetime tag removed.
  ///
  /// RomM renames every save uploaded with a `slot` to
  /// `<name> [YYYY-MM-DD_HH-MM-SS].<ext>`: the tag is how it versions a slot, so
  /// filenames are deliberately *not* the identity server-side. Locally they are
  /// the whole identity — RetroArch loads `<rom>.srm` and nothing else — so
  /// writing the tagged name produces a file the emulator ignores and this
  /// provider then refuses to sync ([syncableSaves] rejects exactly those names).
  /// Left unfixed, the emulator boots a fresh save and the post-close hook
  /// uploads that blank file as the copy every device syncs from.
  ///
  /// Two rules, both deliberate:
  ///
  /// * **Strip the datetime pattern, never RomM's `file_name_no_tags`.** That
  ///   field looks like the built-in answer but strips *every* trailing bracket
  ///   group, so `Pokemon - Pisces [Hack] [2026-07-24_01-20-16].srm` comes back
  ///   as `Pokemon - Pisces` — losing a `[Hack]` suffix that is a permanent part
  ///   of the name RetroArch expects. Replacing the pattern is also what the
  ///   server itself does before re-tagging.
  /// * **Saves only.** `/api/states` has no slot parameter and never tags, so a
  ///   bracketed timestamp in a state's name is the name, not a version tag.
  @visibleForTesting
  static String localNameForAsset(RommAsset asset) => asset.isState
      ? asset.fileName
      : asset.fileName.replaceAll(_datetimeTag, '');

  /// Drops remote assets that are kept copies of saves, or whose names are
  /// unsafe.
  ///
  /// [syncableSaves] refuses to *upload* a kept copy of a save
  /// ([isKeptCopyPath]: a conflict backup under [conflictBackupMarker], this
  /// device's copy kept before a download, NeoSync's copies). Without the same
  /// rule on the way down the guard is one-directional: an asset named
  /// `<game>.state.romm-conflict-<stamp>` has no local counterpart to pair
  /// with, so the remote-only pass downloads it, and every device that syncs
  /// the game acquires a permanent copy the upload side then refuses to touch —
  /// unreconcilable and unremovable from the app.
  ///
  /// A copy is by definition kept for a person to inspect *locally*, never
  /// something to distribute, so its name is the whole test. Both the raw
  /// `file_name` and the [localNameForAsset] it becomes are checked: stripping
  /// a datetime tag can join a name into a kept copy's (`Game.srm.romm
  /// [2026-01-01_00-00-00]-local-…`) or into an unsafe one.
  @visibleForTesting
  static List<RommAsset> syncableRemote(List<RommAsset> remote) {
    return remote.where((a) {
      final localName = localNameForAsset(a);
      if (isKeptCopyPath(a.fileName) || isKeptCopyPath(localName)) {
        _log.i('RomM: skipping remote kept copy ${a.fileName}');
        return false;
      }
      // The name becomes a local file name; the server must not be able to
      // point it anywhere but the save/state folder.
      if (!isSafeFileName(a.fileName) || !isSafeFileName(localName)) {
        _log.w('RomM: skipping remote asset with unsafe name ${a.fileName}');
        return false;
      }
      return true;
    }).toList();
  }

  /// Collapses a remote listing to one asset per local filename, newest first.
  ///
  /// A slot accrues a row per upload, so a server can hold dozens of versions of
  /// one save — all of which normalise to the same local name. Without this the
  /// provider downloads every one of them in turn, each overwriting the last,
  /// and the file left on disk is whichever happened to be listed last.
  ///
  /// Newest by `updated_at` wins, ties broken by the higher (later) asset id.
  /// Saves and states are kept apart, matching how they are paired.
  ///
  /// Note what this does to a server holding *both* an old untagged NeoStation
  /// asset and a newer slotted lineage: they collapse together, the newer one
  /// wins, and the untagged asset is simply never matched again. That is the
  /// intended migration — it stays put as a backup. If the untagged asset is
  /// instead the newer one, it keeps winning until another client writes to the
  /// slot. Pairing always follows the newest asset, so the *bytes* converge even
  /// while the row being updated alternates between the two lineages.
  @visibleForTesting
  static List<RommAsset> latestPerLocalName(List<RommAsset> remote) {
    final best = <String, RommAsset>{};
    for (final a in remote) {
      final key = '${a.isState ? 's' : 'f'}:${localNameForAsset(a)}';
      final current = best[key];
      if (current == null ||
          a.updatedAtMs > current.updatedAtMs ||
          (a.updatedAtMs == current.updatedAtMs && a.id > current.id)) {
        best[key] = a;
      }
    }
    // Preserve the server's ordering for the survivors; only duplicates go.
    // Identity, not id: `/api/saves` and `/api/states` number their rows
    // independently, so a save and a state can share an id.
    final kept = Set<RommAsset>.identity()..addAll(best.values);
    return remote.where(kept.contains).toList();
  }

  /// The subfolder a downloaded file belongs in under *this* device's RetroArch
  /// save/state directory, or `''` for the directory root. A file this device
  /// already has where RetroArch reads it is written there instead (see
  /// [_downloadTargets]).
  ///
  /// Placement is a local question and is answered locally. The alternative,
  /// replaying a subfolder recorded on the server, breaks the moment two
  /// devices are configured differently: a handheld with
  /// `sort_savestates_enable` on wants `states/FCEUmm/`, while a Steam Deck
  /// with it off wants the root — and whichever uploaded first would dictate a
  /// path the other's emulator never reads.
  ///
  /// RetroArch's settings decide the shape (see
  /// [RetroArchConfigService.saveSubfolder]): the name of the folder the game
  /// is in when it sorts by content folder (NEO-281), then the core's when it
  /// sorts by core. The core's name is taken from where this game's other
  /// files of the same kind already are, when they are in that shape (ground
  /// truth, and immune to core renames), and from the emulator the game
  /// launches with otherwise (NEO-279). With the settings unread, the launch
  /// core's folder is used where RetroArch has already made one (see
  /// [_coreFolderInUse]).
  Future<String> _localSubfolder(
    GameModel game,
    bool isState,
    List<LocalSaveFile> localFiles,
    _Placement placement,
  ) async {
    try {
      final layout = await placement.retroArch();
      final cfg = layout.config;
      if (!cfg.settingsRead) {
        return await _coreFolderInUse(layout, isState, placement);
      }
      final byCore = isState
          ? cfg.sortSavestatesByCore
          : cfg.sortSavefilesByCore;
      final byContent = isState
          ? cfg.sortSavestatesByContent
          : cfg.sortSavefilesByContent;
      if (!byCore && !byContent) return '';

      final contentDir = byContent ? layout.contentDir : null;
      if (!byCore) {
        return RetroArchConfigService.saveSubfolder(contentDir: contentDir);
      }

      String? core;
      for (final f in localFiles) {
        if (f.relativePath.startsWith('states/') != isState) continue;
        final sub = layout.subfolderOf(f);
        if (sub == null || sub.isEmpty) continue;
        if (!await layout.reads(sub, isState)) continue;
        core = sub.split('/').last;
        break;
      }
      core ??= await placement.coreFolder();
      return RetroArchConfigService.saveSubfolder(
        contentDir: contentDir,
        core: core,
      );
    } catch (e) {
      // Placement is a best-effort refinement; the directory root is always a
      // valid destination and must never be the reason a sync fails.
      _log.w('RomM: could not resolve local save subfolder: $e');
      return '';
    }
  }

  /// Where RetroArch seems to sort this game's saves (or states) by core,
  /// when its settings couldn't be read (Android, usually): the folder named
  /// after the core the game launches with, if RetroArch's folder already has
  /// one with something in it, inside the game's content folder first. `''`
  /// when it has none.
  ///
  /// RetroArch makes that folder when it sorts by core, so one in use is the
  /// best sign there is without the setting. It is not proof: a folder left
  /// from when sorting was on reads the same. An empty one is not counted, nor
  /// is a content folder alone: its name is the user's own, and may be there
  /// for any reason. The name is returned as it is on disk, which can differ
  /// in case from the emulator's name where the file system ignores case.
  Future<String> _coreFolderInUse(
    _RetroArchLayout layout,
    bool isState,
    _Placement placement,
  ) async {
    final cfg = layout.config;
    final dir = isState ? cfg.savestateDirectory : cfg.savefileDirectory;
    if (dir == null || dir.isEmpty) return '';
    final core = await placement.coreFolder();
    if (core == null || !isSafeFileName(core)) return '';
    final content = layout.contentDir;
    if (content != null) {
      final contentOnDisk = await _childFolderNamed(dir, content);
      if (contentOnDisk != null) {
        final coreOnDisk = await _childFolderNamed(
          path.join(dir, contentOnDisk),
          core,
          inUse: true,
        );
        if (coreOnDisk != null) return '$contentOnDisk/$coreOnDisk';
      }
    }
    return await _childFolderNamed(dir, core, inUse: true) ?? '';
  }

  /// The name, as it is on disk, of the folder called [name] directly inside
  /// [parent], or null when there is none. With [inUse], an empty folder
  /// doesn't count.
  static Future<String?> _childFolderNamed(
    String parent,
    String name, {
    bool inUse = false,
  }) async {
    try {
      await for (final entity in Directory(parent).list(followLinks: false)) {
        if (entity is! Directory) continue;
        final onDisk = path.basename(entity.path);
        if (!_RetroArchLayout.sameName(onDisk, name)) continue;
        if (inUse && await entity.list().isEmpty) continue;
        return onDisk;
      }
    } on FileSystemException {
      // Not there, or not readable: no sign either way.
    }
    return null;
  }

  /// A `403` that reaches the provider is a *persistent* permission denial: the
  /// service layer ([RommService._sendWithAuthRetry]) already re-authenticated
  /// and retried once, so a stale/empty-scope token would have recovered. What
  /// remains is a genuine authorization failure — e.g. a RomM 5.0 account that
  /// lacks `assets.write` under the granular per-user permission system.
  ///
  /// These must abort the sync with an error status; swallowing them to a
  /// `false` (no-op) return would make a dropped save look like a clean,
  /// up-to-date sync — silently losing the user's progress.
  @visibleForTesting
  static bool isPermissionDenied(Object e) =>
      e is RommException && e.statusCode == 403;

  /// The local file's first four bytes, as a zip archive would start them.
  static const List<int> _zipMagic = [0x50, 0x4B, 0x03, 0x04];

  /// Infix marking a conflict backup written by [_guardDivergedRemote].
  ///
  /// Deliberately not a plain extension swap: the file sits next to the save it
  /// came from so the user can find it, and the full original name stays
  /// visible in front of the marker (`Game.srm.romm-conflict-<stamp>`).
  @visibleForTesting
  static const String conflictBackupMarker = '.romm-conflict-';

  /// MD5 of the file at [filePath], or null when it cannot be read.
  ///
  /// MD5 because that is what RomM computes — `hashlib.md5` over the stored
  /// file, streamed in 8 KiB chunks (`AssetsHandler._compute_file_hash`, RomM
  /// 5.1.0) — so this value is directly comparable with `content_hash`. It is a
  /// change detector, never a security check; the comparison it feeds only ever
  /// decides whether a transfer can be skipped.
  ///
  /// Streamed rather than read whole: a PS2 shared memory card is 8 MB and this
  /// runs on the launch path.
  static Future<String?> _md5OfFile(String filePath) async {
    try {
      final file = File(filePath);
      if (!await file.exists()) return null;
      return (await md5.bind(file.openRead()).first).toString();
    } catch (e) {
      _log.w('RomM hash failed ($filePath): $e');
      return null;
    }
  }

  /// Whether the file at [filePath] still holds the bytes recorded at its
  /// last sync, so only its time moved: an emulator that rewrites the same
  /// save on exit makes it look newer than the server's copy without changing
  /// anything in it. False when nothing was recorded, or on any doubt.
  static Future<bool> _unchangedSinceLastSync(String filePath) async {
    try {
      final recorded = await SyncRepository.getSyncState(kProviderId, filePath);
      final hash = recorded?['file_hash'] as String?;
      if (hash == null || hash.isEmpty) return false;
      return await _md5OfFile(filePath) == hash;
    } catch (e) {
      _log.w('RomM: could not compare $filePath with its last sync: $e');
      return false;
    }
  }

  /// Whether the save at [filePath], whose bytes hash to [digest] and whose
  /// time is [localMs], changed on this device since its last sync: its bytes
  /// differ from the ones recorded then, or nothing was recorded (never
  /// synced). A record from before hashes were kept goes by its time. True on
  /// any doubt, since the answer decides whether a copy is kept before the
  /// save is written over.
  static Future<bool> _changedHereSinceLastSync(
    String filePath,
    Digest digest,
    int localMs,
  ) async {
    try {
      final recorded = await SyncRepository.getSyncState(kProviderId, filePath);
      if (recorded == null) return true;
      final hash = recorded['file_hash'] as String?;
      if (hash != null && hash.isNotEmpty) return digest.toString() != hash;
      final recordedMs = recorded['local_modified_at'] as int?;
      return recordedMs == null || localMs > recordedMs + _mtimeToleranceMs;
    } catch (e) {
      _log.w('RomM: could not compare $filePath with its last sync: $e');
      return true;
    }
  }

  /// [commitRommLocalSlot], once the server's card is written over [target]:
  /// should that fail too, the staged copy is left where it is (the only
  /// copy of the card as it was) rather than failing a download that already
  /// happened, and its path returned.
  static Future<String> _commitSlotQuietly(String target, String staged) async {
    try {
      return await commitRommLocalSlot(target, staged);
    } catch (e) {
      _log.e(
        'RomM download: could not keep $staged as the slot of $target — '
        'left as it is: $e',
      );
      return staged;
    }
  }

  /// Removes a copy [_download] kept and then didn't need.
  static Future<void> _deleteKeptCopy(String copyPath) async {
    try {
      await File(copyPath).delete();
    } catch (e) {
      _log.w('RomM: could not remove $copyPath: $e');
    }
  }

  /// Keeps at most [maxKeptCopiesPerSave] copies of [savePath], [justKept]
  /// among them.
  static Future<void> _tidyQuietly(String savePath, String justKept) async {
    try {
      await tidyKeptCopies(
        savePath,
        sources: rommKeptCopySources,
        justKept: {justKept},
      );
    } catch (e) {
      _log.w('RomM: could not tidy the kept copies of $savePath: $e');
    }
  }

  /// Whether RomM's own `content_hash` for [asset] provably describes the same
  /// bytes as [digest], an [_md5OfFile] of [local].
  ///
  /// False whenever the comparison cannot be trusted, which keeps every
  /// uncertain case on the existing transfer path — the worst outcome of a
  /// "no" here is the redundant upload or download this gate set out to avoid,
  /// while a wrong "yes" would silently skip a real one. Three cases:
  ///
  /// * **States.** RomM's `StateSchema` has no `content_hash` field at all
  ///   (verified against 5.1.0), so `/api/states` can never answer this. States
  ///   are covered instead by the hash recorded at the last sync.
  /// * **No hash.** Older servers, and rows whose file went missing, leave it
  ///   null; RomM backfills them with a maintenance task on its own schedule.
  /// * **Zip archives.** RomM hashes a zip entry-wise — MD5 over
  ///   `"<name>:<md5>"` lines for the sorted entries
  ///   (`AssetsHandler._compute_zip_hash`) — so its value is not an MD5 of the
  ///   file's bytes and must never be compared with one.
  static Future<bool> _serverHoldsSameBytes(
    RommAsset asset,
    String digest,
    LocalSaveFile local,
  ) async {
    final remote = asset.contentHash;
    if (asset.isState || remote == null || remote.isEmpty) return false;
    if (remote.toLowerCase() != digest) return false;
    return !await _looksZipped(local.filePath);
  }

  /// Whether [filePath] opens with a zip archive's local-file-header magic.
  ///
  /// Deliberately a header sniff and not a real archive test: it exists only to
  /// withhold the [_serverHoldsSameBytes] shortcut from files RomM may have
  /// hashed entry-wise, and a false positive costs one ordinary transfer.
  static Future<bool> _looksZipped(String filePath) async {
    try {
      final handle = await File(filePath).open();
      try {
        final head = await handle.read(_zipMagic.length);
        if (head.length < _zipMagic.length) return false;
        for (var i = 0; i < _zipMagic.length; i++) {
          if (head[i] != _zipMagic[i]) return false;
        }
        return true;
      } finally {
        await handle.close();
      }
    } catch (e) {
      _log.w('RomM zip probe failed ($filePath): $e');
      return false;
    }
  }

  /// Protects the server's copy of [match] from an upload of [local] that would
  /// replace bytes this device has never seen.
  ///
  /// This is the narrowing of the "prefer local" tie-break. The branch that
  /// calls it has always resolved a both-sides-changed pair by pushing the
  /// local file over the remote one, on the reasoning that a session just
  /// ended here. That reasoning is sound and is kept — what was wrong was the
  /// *evidence*: "both changed" was an mtime answer, and the loser was
  /// destroyed with no copy left anywhere. A hardware A/B confirmed it, a
  /// second device's save state ceasing to exist on the server and on both
  /// devices while the pass reported `1 up, 0 down`.
  ///
  /// So the question asked here is byte-level, and the answer only ever costs
  /// the remote copy a read:
  ///
  /// * **[_RemoteGuard.clear]** — the server holds the very bytes this device
  ///   recorded at its last sync, so nothing has diverged and the upload is an
  ///   ordinary one-sided change. Also the answer when the server turns out to
  ///   hold *our* new bytes already, which the upload would only rewrite.
  /// * **[_RemoteGuard.preserved]** — the two really do differ. The remote
  ///   bytes are written beside [local] under [conflictBackupMarker] and the
  ///   upload then proceeds, so the outcome the user sees is unchanged and the
  ///   copy that used to be destroyed is recoverable by hand.
  /// * **[_RemoteGuard.unreadable]** — the remote copy could not be fetched.
  ///   The caller abandons the upload for this pass; nothing is recorded, so
  ///   the file stays pending and the next pass asks again. Non-destructive,
  ///   which a blind overwrite would not be.
  ///
  /// [recordedHash] is the digest banked at the last sync and is the whole
  /// basis for "has the *remote* moved": since #403 that column holds a hash
  /// this provider computed, so it is comparable both with RomM's `content_hash`
  /// for an ordinary save and with an MD5 of freshly fetched bytes. Without one
  /// (a pair this device has never synced) nothing can be ruled out, and the
  /// remote copy is preserved rather than assumed stale.
  ///
  /// The fetch is what makes this cover **states**, where RomM exposes no
  /// `content_hash` at all and a zipped save's is entry-wise. Only the
  /// post-close pass reaches here — the sweep bails on `uploadOnly &&
  /// remoteChanged` before this point and the pre-launch pass never takes the
  /// upload branch — so there is no launch deadline to spend it against.
  ///
  /// [onKept] gets the kept copy's path when it is written.
  Future<_RemoteGuard> _guardDivergedRemote(
    RommAsset match,
    LocalSaveFile local, {
    required String? recordedHash,
    required String? pushDigest,
    void Function(String copyPath)? onKept,
  }) async {
    // Cheap path: RomM's own hash can rule divergence out without a transfer,
    // but only where it is an MD5 of the stored bytes. States have none and a
    // zip's is computed entry-wise, so both fall through to the fetch. Only
    // equality is trusted here; "different" still needs the bytes, to keep.
    final serverHash = match.contentHash;
    if (recordedHash != null &&
        recordedHash.isNotEmpty &&
        !match.isState &&
        serverHash != null &&
        serverHash.isNotEmpty &&
        serverHash.toLowerCase() == recordedHash &&
        !await _looksZipped(local.filePath)) {
      return _RemoteGuard.clear;
    }

    final Uint8List? bytes;
    try {
      bytes = await _fetchAssetBytes(match);
    } catch (e) {
      if (isPermissionDenied(e)) rethrow;
      _log.e('RomM conflict guard: cannot read ${match.fileName}: $e');
      return _RemoteGuard.unreadable;
    }
    if (bytes == null) return _RemoteGuard.unreadable;

    final remoteDigest = md5.convert(bytes).toString();
    // Unchanged since this device last agreed with the server, or already the
    // bytes about to be pushed. Neither is a conflict.
    if (remoteDigest == recordedHash || remoteDigest == pushDigest) {
      return _RemoteGuard.clear;
    }

    final backup = File(
      '${local.filePath}$conflictBackupMarker${_backupStamp()}',
    );
    var created = false;
    try {
      await backup.parent.create(recursive: true);
      // Only a file this guard creates is removed should the write fail.
      created = !await backup.exists();
      await backup.writeAsBytes(bytes, flush: true);
      _log.w(
        'RomM conflict: ${path.basename(local.filePath)} and the server both '
        'changed since the last sync — kept the remote copy as '
        '${path.basename(backup.path)} before uploading the local one',
      );
      onKept?.call(backup.path);
      return _RemoteGuard.preserved;
    } catch (e) {
      _log.e(
        'RomM conflict guard: cannot write backup for ${local.filePath}: $e',
      );
      // Cut short, it would be listed as a copy to restore.
      try {
        if (created) await backup.delete();
      } on FileSystemException {
        // Nothing more to undo.
      }
      return _RemoteGuard.unreadable;
    }
  }

  /// A launch of [game] wrote the server's copy ([bytes], hashing to
  /// [downloaded]) over the save at [target], which held [before], while the
  /// game may still have been open in an emulator. That emulator may ignore
  /// the save and later write its own copy back over it, so the server's copy
  /// is kept in Save history ([rommLaunchCopyPath]: from the server, before
  /// an upload, the same kind of copy; one per save, replaced by the next
  /// such launch), and the download is recorded for NeoStation to check when
  /// it comes back to the front. [unsyncedHere]: the save held changes made
  /// here and not yet synced. The copy is written after the save, so the tidy
  /// doesn't take it for one the save already holds.
  Future<void> _keptAtOpenGameLaunch(
    GameModel game,
    String target,
    Uint8List bytes, {
    required Digest before,
    required Digest downloaded,
    required bool unsyncedHere,
  }) async {
    // The server's copy held this device's bytes (a state has no hash to
    // tell before the download): nothing to keep or to check.
    if (before == downloaded) return;
    final copy = rommLaunchCopyPath(target);
    try {
      if (await writeLaunchCopy(copy, bytes)) {
        _log.w(
          'RomM download: ${game.romname} may still be open in an emulator — '
          'kept the server\'s copy of ${path.basename(target)} as '
          '${path.basename(copy)}',
        );
      }
    } catch (e) {
      _log.e('RomM download: could not keep the server\'s copy as $copy: $e');
    }
    await _openGames.recordDownload(
      providerId: kProviderId,
      romname: game.romname,
      systemFolder: game.systemFolderName,
      path: target,
      beforeHash: before.toString(),
      downloadedHash: downloaded.toString(),
      gameName: game.name,
      unsyncedHere: unsyncedHere,
    );
  }

  @override
  Future<bool> rebaselineIgnoredDownload(
    String savePath, {
    String? expectedHash,
  }) async {
    try {
      return await SyncRepository.resetToFile(
        kProviderId,
        savePath,
        expectedHash: expectedHash,
      );
    } catch (e) {
      _log.w('RomM: could not reset the sync record of $savePath: $e');
      return false;
    }
  }

  @override
  Future<bool> markChangedOnBothSides(String savePath) async {
    try {
      return await SyncRepository.markChangedOnBothSides(kProviderId, savePath);
    } catch (e) {
      _log.w('RomM: could not update the sync record of $savePath: $e');
      return false;
    }
  }

  /// [OpenGameReturn.checkLaunchDownloads], when there is anything to check.
  Future<void> _checkLaunchDownloads() async {
    if (_openGames.downloads.isEmpty) return;
    await OpenGameReturn.checkLaunchDownloads(
      guard: _openGames,
      providerFor: (id) =>
          id == kProviderId ? this : SyncManager.instance.provider(id),
    );
  }

  /// `2026-08-21_19-30-00`, for a conflict backup's filename.
  ///
  /// Local time, colon-free and sortable: it is read by a person looking in
  /// their saves folder, not parsed by anything.
  static String _backupStamp() {
    final n = DateTime.now();
    String p2(int v) => v.toString().padLeft(2, '0');
    return '${n.year}-${p2(n.month)}-${p2(n.day)}_'
        '${p2(n.hour)}-${p2(n.minute)}-${p2(n.second)}';
  }

  /// This device's record of the shared memory card at [filePath], kept under
  /// its path as listed (by an upload, or a download onto it) or, by a
  /// download placed in a folder, normalised. When both exist, the later one.
  static Future<Map<String, dynamic>?> _cardSyncRecord(String filePath) async {
    final normalised = path.normalize(path.absolute(filePath));
    Map<String, dynamic>? newest;
    for (final key in {filePath, normalised}) {
      final record = await SyncRepository.getSyncState(kProviderId, key);
      if (record == null) continue;
      int at(Map<String, dynamic> r) => (r['local_modified_at'] as int?) ?? 0;
      if (newest == null || at(record) > at(newest)) newest = record;
    }
    return newest;
  }

  /// Whether this device has never synced one of [cards] with RomM.
  static Future<bool> _anyNeverSynced(List<LocalSaveFile> cards) async {
    for (final card in cards) {
      if (await _cardSyncRecord(card.filePath) == null) return true;
    }
    return false;
  }

  /// Every save the user has on the server, under any game, newest per name;
  /// null when the listing failed. Unless [fresh], a listing up to
  /// [_everySaveMaxAge] old is reused: a highlight only shows a status, and a
  /// list of PS2 games would otherwise ask for every save at each one.
  Future<List<RommAsset>?> _everySaveListed({required bool fresh}) async {
    final cached = _everySaveCache;
    if (!fresh &&
        cached != null &&
        DateTime.now().difference(cached.at) < _everySaveMaxAge) {
      return cached.saves;
    }
    try {
      final saves = latestPerLocalName(
        syncableRemote(await _svc.listAllSaves()),
      );
      _everySaveCache = (at: DateTime.now(), saves: saves);
      return saves;
    } catch (e) {
      _log.e('RomM listing every save failed: $e');
      return null;
    }
  }

  ({DateTime at, List<RommAsset> saves})? _everySaveCache;

  /// The server's copy of the shared memory card named [localName]: the newest
  /// of [thisGame]'s and those in [everySave] (every game's), or null when no
  /// game has one.
  static RommAsset? _serverCard(
    String localName,
    RommAsset? thisGame,
    List<RommAsset> everySave,
  ) => latestPerLocalName([
    ?thisGame,
    ...everySave.where((a) => !a.isState && localNameForAsset(a) == localName),
  ]).firstOrNull;

  /// Records [local] as settled at [cloudUpdatedAt], no transfer having been
  /// needed.
  ///
  /// [cloudUpdatedAt] is the caller's claim about how much of the server it has
  /// actually accounted for, which is not always the matched asset's stamp: a
  /// skip decided from this device's own records leaves it where it was, so the
  /// remote copy stays unseen and a later pass still pulls it.
  ///
  /// Writing this row is the point of the skip, not bookkeeping around it:
  /// without it the mtime comparison asks the same question on every pass and
  /// this file pays for a hash forever. The stat is re-read rather than reusing
  /// the locator's, so the recorded mtime is the one a later pass will see.
  Future<void> _recordSynced(
    LocalSaveFile local,
    int cloudUpdatedAt,
    String digest,
  ) async {
    try {
      final stat = await File(local.filePath).stat();
      await SyncRepository.saveSyncState(
        kProviderId,
        local.filePath,
        stat.modified.millisecondsSinceEpoch,
        cloudUpdatedAt,
        stat.size,
        fileHash: digest,
      );
    } catch (e) {
      _log.w('RomM sync-state record failed (${local.filePath}): $e');
    }
  }

  /// Sends [local] to RomM, updating [existing] in place when the asset is
  /// already there and creating it otherwise.
  ///
  /// The update path matters: see [RommService.updateSave] for why a repeat
  /// `POST` corrupts the row/file relationship instead of overwriting.
  ///
  /// Only the create path carries [_saveSlot]. `PUT` has no slot parameter, so
  /// an asset created before this device started slotting keeps its NULL slot
  /// for life: slotting reaches new saves, never the existing library.
  Future<_UploadOutcome> _upload(
    int romId,
    LocalSaveFile local,
    bool isState, {
    RommAsset? existing,
    String? digest,
  }) async {
    try {
      final file = File(local.filePath);
      if (!await file.exists()) return _UploadOutcome.noFile;
      final RommAsset asset;
      if (existing != null) {
        asset = isState
            ? await _svc.updateState(existing.id, file)
            : await _svc.updateSave(existing.id, file);
      } else {
        asset = isState
            ? await _svc.uploadState(romId, file, emulator: _assetLabel)
            : await _svc.uploadSave(
                romId,
                file,
                emulator: _assetLabel,
                slot: _saveSlot,
              );
      }
      final stat = await file.stat();
      // Record *our* hash of the bytes just sent, not the server's echo of it.
      // The two agree for an ordinary save, but RomM hashes a zip archive
      // entry-wise rather than byte-wise, and states carry no `content_hash` at
      // all — so storing the server's value would leave exactly the files this
      // gate exists for without one. The reader ([_syncGame]) only ever
      // compares it against another [_md5OfFile] result, so self-consistency is
      // what matters.
      await SyncRepository.saveSyncState(
        kProviderId,
        local.filePath,
        stat.modified.millisecondsSinceEpoch,
        asset.updatedAtMs,
        local.fileSize,
        fileHash: digest ?? await _md5OfFile(local.filePath),
      );
      return _UploadOutcome.uploaded;
    } catch (e) {
      if (isPermissionDenied(e)) rethrow;
      _log.e('RomM upload failed (${local.filePath}): $e');
      return _UploadOutcome.failed;
    }
  }

  /// The bytes RomM holds for [asset], or null when they cannot be fetched.
  ///
  /// Both saves and states download via the asset's `download_path`; only saves
  /// have the `/content` convenience route, used as a fallback. A state with no
  /// `download_path` is unreadable, which is a server-side data problem rather
  /// than something a caller can retry differently.
  Future<Uint8List?> _fetchAssetBytes(RommAsset asset) async {
    final dp = asset.downloadPath;
    if (dp != null && dp.isNotEmpty) return _svc.downloadAssetByPath(dp);
    if (!asset.isState) return _svc.downloadSaveContent(asset.id);
    _log.w('RomM download: state ${asset.fileName} has no download_path');
    return null;
  }

  /// Fetches [asset] and writes it to this device's local target(s).
  ///
  /// [_DownloadOutcome.coreMismatch] reports the one refusal a caller needs to
  /// distinguish from an ordinary no-op: the transfer was declined because the
  /// remote state was written by a different core (see the guard below).
  /// [_DownloadOutcome.failed] reports that the server's copy could not be
  /// fetched or written, or that this device's copy of a save changed here
  /// could not be kept first, or would be read through a link (that target is
  /// then left as it was). Everything else (no target, an expired deadline,
  /// a newer local copy) is a routine `wrote: false`.
  ///
  /// [firstCardSync] takes the server's copy of a shared memory card this
  /// device has never synced: it is written onto [paired], whatever its time,
  /// and the bell says the card was synced from here for the first time.
  Future<_DownloadOutcome> _download(
    GameModel game,
    RommAsset asset, {
    required List<LocalSaveFile> localFiles,
    required _Placement placement,
    LocalSaveFile? paired,
    SyncDeadline? deadline,
    bool firstCardSync = false,
  }) async {
    assert(!firstCardSync || paired != null);
    var skippedCoreMismatch = false;
    try {
      // Placement comes from this device's own RetroArch layout, never from the
      // asset's `emulator` field — that value belongs to whichever device
      // created the asset and says nothing about where this one reads saves.
      //
      // The *name* comes from [localNameForAsset], not the asset: RomM's
      // datetime tag is server-side versioning, and a file written under it is
      // one the emulator will never load.
      final prefix = asset.isState ? 'states' : 'saves';
      final sub = await _localSubfolder(
        game,
        asset.isState,
        localFiles,
        placement,
      );
      final localName = localNameForAsset(asset);
      final relativeName = sub.isNotEmpty
          ? '$prefix/$sub/$localName'
          : '$prefix/$localName';
      final targets = firstCardSync && paired != null
          ? [paired.filePath]
          : await _downloadTargets(
              game,
              asset,
              relativeName: relativeName,
              localName: localName,
              placement: placement,
              paired: paired,
            );
      if (targets == null) {
        return (wrote: false, coreMismatch: false, failed: false);
      }
      if (targets.isEmpty) {
        _log.w('RomM download: no local target for ${asset.fileName}');
        return (wrote: false, coreMismatch: false, failed: false);
      }
      final bytes = await _fetchAssetBytes(asset);
      if (bytes == null) {
        return (wrote: false, coreMismatch: false, failed: true);
      }

      // Pre-launch deadline guard: the network fetch is done, but if the
      // launch-blocking wait has already elapsed the game is running on the
      // local save. Abandon here — before any write — so we never clobber the
      // .srm the emulator now has open or record bogus sync state.
      if (deadline?.isExpired ?? false) {
        _log.i(
          'RomM download: abandon ${asset.fileName} (launch deadline passed)',
        );
        return (wrote: false, coreMismatch: false, failed: false);
      }

      // Hashed once: compared with each target's bytes, and recorded as the
      // hash of what each target now holds.
      final serverDigest = md5.convert(bytes);
      var wroteAny = false;
      var failedAny = false;
      for (final target in targets) {
        final f = File(target);
        String? keptHere;
        List<int>? localBytes;
        int? localMsHere;
        // A save that is a link (single saves are linked in from elsewhere on
        // desktops) is written through, as it always was. Only its copy is
        // refused: one at a save's place may point anywhere, and the copy
        // would read through it. A link swapped in after this look is still
        // followed; dart:io can't open a file without following links.
        final isLink =
            await FileSystemEntity.type(target, followLinks: false) ==
            FileSystemEntityType.link;
        // A memory card every game of its system shares. The server's copy
        // under this game may come from a card this device never had (another
        // game's copy of it), which nothing here can tell from an ordinary
        // pull: this device's card is kept whenever the bytes differ.
        final sharedCard =
            !asset.isState &&
            sharesMemoryCards(game.systemFolderName) &&
            isSharedMemoryCard(target);
        var changedHere = false;
        // [keptHere] is the card staged for its slot, not yet the slot.
        var slotStaged = false;
        // Per-target guard (mirrors NeoSync): never overwrite a copy that is
        // newer than the remote asset, unless its bytes are still the ones
        // recorded at the last sync (only its time moved, as when an emulator
        // rewrites the same save on exit). resolveLocalTargetPaths can return
        // several folders and the higher-level decision only inspected one, so
        // a different folder may hold newer local progress we must not clobber.
        if (await f.exists()) {
          final localMs = (await f.stat()).modified.millisecondsSinceEpoch;
          localMsHere = localMs;
          // A first sync of a shared card takes the server's whatever the
          // time: a card an emulator has just made is newer than any.
          if (!firstCardSync &&
              localMs > asset.updatedAtMs + _mtimeToleranceMs &&
              !await _unchangedSinceLastSync(target)) {
            _log.i('RomM download: skip $target (local newer than remote)');
            continue;
          }
          final current = await f.readAsBytes();
          localBytes = current;
          // Core guard. A save state only loads in the core that wrote it, and
          // RetroArch fails silently when it doesn't — so replacing a local
          // state with another device's incompatible one destroys a working
          // save with nothing to show for it. Confirmed on device: a Thor
          // (FCEUmm) and a Deck (Mesen) alternating sessions overwrite each
          // other's state every launch, leaving neither able to resume.
          //
          // Deliberately compares the bytes rather than a label on the asset:
          // saves are shared with other frontends, which upload a plain
          // `<game>.state` and know nothing of any convention we invent. RomM
          // 5.1.0 could not carry one anyway — it identifies an asset by
          // (rom_id, file_name) and ignores `emulator`, so a second core's
          // state cannot coexist and the field keeps whichever label created
          // the asset.
          //
          // [RetroArchStateSignature.differ] answers false whenever either side
          // is unidentifiable, so states from cores without a magic, and
          // standalone emulators' own formats, keep syncing exactly as before.
          if (asset.isState && RetroArchStateSignature.differ(current, bytes)) {
            _log.w(
              'RomM download: skip $target — the remote state was written by a '
              'different core and would not load here',
            );
            skippedCoreMismatch = true;
            continue;
          }
          // A save changed here since the last sync, or never synced, holds
          // progress the server's copy doesn't: the server's is only newer by
          // the clock, which says nothing about this device's last session
          // (played offline, say). It is kept as its own copy, listed in Save
          // history, before the server's is written over it; if it can't be
          // kept, this target is left as it was. A save already holding the
          // server's bytes loses nothing.
          final localDigest = md5.convert(current);
          if (localDigest != serverDigest) {
            changedHere = await _changedHereSinceLastSync(
              target,
              localDigest,
              localMs,
            );
          }
          // A shared card that is a link and unchanged here is written
          // through, as before: its copy would read through the link.
          if (changedHere ||
              (sharedCard && !isLink && localDigest != serverDigest)) {
            if (isLink) {
              _log.w(
                'RomM download: skip $target — it changed here, and no copy is '
                'made through a link',
              );
              failedAny = true;
              continue;
            }
            try {
              if (firstCardSync) {
                // Possibly the only copy of everything this device's games
                // saved on the card: never tidied away.
                keptHere = await keepRommFirstSyncCopy(target, bytes: current);
              } else if (changedHere) {
                keptHere = await keepRommLocalCopy(target, bytes: current);
              } else {
                // A card unchanged here goes in its one slot, which the next
                // such download overwrites: routine downloads would otherwise
                // push the dated copies (a conflict's, one changed here) out.
                keptHere = await stageRommLocalSlot(target, bytes: current);
                slotStaged = true;
              }
            } catch (e) {
              _log.e(
                'RomM download: could not keep this device\'s $target before '
                'writing the server\'s copy over it — left as it was: $e',
              );
              failedAny = true;
              continue;
            }
          }
        }
        // Asked again right before the write: everything above takes time on
        // the launch path, and a launch that went ahead meanwhile has the save
        // open, so it is left as it was.
        if (deadline?.isExpired ?? false) {
          if (keptHere != null) await _deleteKeptCopy(keptHere);
          _log.i(
            'RomM download: abandon ${asset.fileName} (launch deadline passed '
            'before writing $target)',
          );
          return (
            wrote: wroteAny,
            coreMismatch: skippedCoreMismatch,
            failed: failedAny,
          );
        }
        try {
          await f.parent.create(recursive: true);
          await f.writeAsBytes(bytes, flush: true);
        } catch (_) {
          // A write cut short can leave the save truncated: this device's
          // bytes are put back, with their time, so the next pass sees the
          // save as it was. If even that fails, a kept copy stays, listed in
          // Save history.
          if (localBytes != null) {
            try {
              await f.writeAsBytes(localBytes, flush: true);
              if (localMsHere != null) {
                try {
                  await f.setLastModified(
                    DateTime.fromMillisecondsSinceEpoch(localMsHere),
                  );
                } catch (e) {
                  _log.w(
                    'RomM download: could not restore the time of $target: $e',
                  );
                }
              }
              if (keptHere != null) await _deleteKeptCopy(keptHere);
            } catch (e) {
              final kept = keptHere == null
                  ? null
                  : slotStaged
                  ? await _commitSlotQuietly(target, keptHere)
                  : keptHere;
              _log.e(
                'RomM download: $target could not be written or put back'
                '${kept == null ? '' : '; this device\'s copy is kept as ${path.basename(kept)}'}'
                ': $e',
              );
              if (kept != null) await _tidyQuietly(target, kept);
            }
          }
          rethrow;
        }
        wroteAny = true;
        if (keptHere != null && slotStaged) {
          keptHere = await _commitSlotQuietly(target, keptHere);
        }
        if (keptHere != null) {
          _log.w(
            firstCardSync
                ? 'RomM download: $target not synced from this device before '
                      '— kept this device\'s card as '
                      '${path.basename(keptHere)} and took the server\'s'
                : changedHere
                ? 'RomM download: $target had changed here too — kept this '
                      'device\'s copy as ${path.basename(keptHere)} before '
                      'writing the server\'s newer one'
                : 'RomM download: kept this device\'s card $target as '
                      '${path.basename(keptHere)} before writing the server\'s',
          );
          // An ordinary pull over a card unchanged here is not news; the copy
          // waits in Save history.
          if (firstCardSync) {
            reportFirstCardSyncTookCloud(gameName: game.name, savePath: target);
          } else if (changedHere) {
            reportNewerCloudCopy(gameName: game.name, savePath: target);
          }
          await _tidyQuietly(target, keptHere);
        }
        final stat = await f.stat();
        await SyncRepository.saveSyncState(
          kProviderId,
          target,
          stat.modified.millisecondsSinceEpoch,
          asset.updatedAtMs,
          bytes.length,
          // Ours, for the reason given in [_upload] — and free here, since the
          // bytes are already in memory.
          fileHash: serverDigest.toString(),
        );
        if (deadline != null &&
            localBytes != null &&
            _saveMayBeOpen(game, target)) {
          await _keptAtOpenGameLaunch(
            game,
            target,
            bytes,
            before: md5.convert(localBytes),
            downloaded: serverDigest,
            // A card's first sync from here: never synced, so unsynced.
            unsyncedHere: changedHere || firstCardSync,
          );
        }
      }
      return (
        wrote: wroteAny,
        coreMismatch: skippedCoreMismatch,
        failed: failedAny,
      );
    } catch (e) {
      if (isPermissionDenied(e)) rethrow;
      _log.e('RomM download failed (${asset.fileName}): $e');
      return (wrote: false, coreMismatch: skippedCoreMismatch, failed: true);
    }
  }

  // ── Game-specific sync operations (interface) ───────────────────────────────

  /// Records [game] as failed in the visible sync state and returns the matching
  /// fail result. Used by every per-game sync entry point so a hard failure
  /// (notably a RomM 5.0 permission denial that [isPermissionDenied] let bubble
  /// up) surfaces as an error state instead of leaving stale state that would
  /// read as a clean, up-to-date sync.
  SyncResult _failGame(GameModel game, Object error) {
    _gameSyncStates[game.romname] = _buildState(
      game,
      GameSyncStatus.error,
      errorMessage: error.toString(),
    );
    notifyListeners();
    return SyncResult.fail(SyncError.unknown, message: error.toString());
  }

  @override
  Future<SyncResult> detectGameSaveFiles(GameModel game) => _runGameSync(
    game,
    downloadOnly: true,
    statusOnly: true,
  ).then((sync) => sync.result);

  /// Runs one per-game hook's sync and publishes the resulting cloud state.
  ///
  /// A status-level failure (server unreachable, a listing or an upload that
  /// failed) is recorded and reported as visibly as a thrown one: "local only"
  /// or "up to date" would read as success. [_syncGame] has logged its cause.
  /// Every caller treats a failure as best-effort, so it never blocks a game
  /// from starting; it only keeps the UI honest.
  ///
  /// Also returns what the sync left waiting to go up, which is
  /// [_Pending.unknown] when it threw.
  Future<({SyncResult result, _Pending uploads})> _runGameSync(
    GameModel game, {
    required bool downloadOnly,
    bool statusOnly = false,
    SyncDeadline? deadline,
  }) async {
    // A status-only check writes nothing, so it doesn't hold up a move.
    if (!statusOnly) _activeSyncs++;
    try {
      final sync = await _syncGame(
        game,
        downloadOnly: downloadOnly,
        statusOnly: statusOnly,
        deadline: deadline,
      );
      if (sync.status == GameSyncStatus.error) {
        return (
          result: _failGame(game, 'RomM save sync failed'),
          uploads: sync.uploads,
        );
      }
      _gameSyncStates[game.romname] = _buildState(game, sync.status);
      notifyListeners();
      return (result: SyncResult.ok(), uploads: sync.uploads);
    } catch (e) {
      return (result: _failGame(game, e), uploads: _Pending.unknown);
    } finally {
      if (!statusOnly) _activeSyncs--;
    }
  }

  /// Per-game syncs and playtime pulls in progress.
  int _activeSyncs = 0;

  /// A save sync, the upload sweep or the playtime pull is running. Each
  /// writes the database (sync state, playtime), so moving the user data waits
  /// for it: anything written after the move copied the database would be
  /// lost with the old folder. A status-only check writes nothing and doesn't
  /// count.
  bool get isSyncing => _activeSyncs > 0 || _sweeping.value != null;

  @override
  GameSyncState? getGameSyncState(String gameId) => _gameSyncStates[gameId];

  /// Forgets the cached sync state for one game so the next status computation
  /// starts from scratch.
  ///
  /// Called after a link path writes an `app_romm_rom_map` row for a game that
  /// was already on the device. Until then [_syncGame] found no rom id and
  /// cached [GameSyncStatus.disabled] — the grey cloud — and nothing would
  /// recompute it before a restart. Dropping the entry (and notifying, so the
  /// badge re-asks) lets the link show without one.
  ///
  /// The "downloaded" memo on the browse side is invalidated too, through its
  /// owner: the new row is also what [RommProvider]'s existing-file probe uses
  /// to recognise a multi-disc game by its recorded playlist name, so a stale
  /// memo could keep reporting a freshly linked game as not downloaded. That
  /// call is a wholesale, no-op-when-empty clear, so repeated invalidations are
  /// cheap.
  void invalidateGameSyncState(String romname) {
    final removed = _gameSyncStates.remove(romname) != null;
    _browse.invalidateDownloadedCache();
    if (removed && !_disposed) notifyListeners();
  }

  /// [invalidateGameSyncState] for every game the link pass just linked, with
  /// the browse-side cache cleared and listeners notified *once*.
  ///
  /// The single-game form clears the whole downloaded-cache each call, which
  /// is fine for one link from the browser and a needless storm for the
  /// hundreds a connect pass can write. One clear covers them all.
  void invalidateGameSyncStates(Iterable<String> romnames) {
    var removed = false;
    for (final romname in romnames) {
      removed = _gameSyncStates.remove(romname) != null || removed;
    }
    _browse.invalidateDownloadedCache();
    if (removed && !_disposed) notifyListeners();
  }

  @override
  Future<SyncResult> syncGameSavesBeforeLaunch(
    GameModel game, {
    SyncDeadline? deadline,
  }) => _runGameSync(
    game,
    downloadOnly: true,
    deadline: deadline,
  ).then((sync) => sync.result);

  /// Deliberately not [detectGameSaveFiles]: this is the one hook that must
  /// actually push. Detection went status-only so that merely highlighting a
  /// game stops moving saves, and routing the post-close hook through it would
  /// silently strand every save the user just made.
  ///
  /// Most uploads happen here, so a failure is reported the way a failed sweep
  /// is: the game joins [uploadFailures] until its saves go up.
  @override
  Future<SyncResult> syncGameSavesAfterClose(GameModel game) async {
    final sync = await _runGameSync(game, downloadOnly: false);
    await _recordUploadOutcome(game, sync.uploads);
    return sync.result;
  }

  /// Reports [game] in [uploadFailures] while [uploads] left a save waiting
  /// to go up, and stops reporting it once nothing is. When the sync could not
  /// tell, the disk is asked: a failed listing with nothing new to send left no
  /// save behind. A failure while disconnected is not reported, as a sweep's
  /// is not: the next connect retries it.
  Future<void> _recordUploadOutcome(GameModel game, _Pending uploads) async {
    if (!_browse.isConnected) return;
    final left = uploads == _Pending.unknown
        ? await _pendingUpload(game, afterClose: true)
        : uploads;
    if (_noteUpload(game, left)) _reportUploadFailures();
  }

  @override
  Future<void> updateGameCloudSyncEnabled(String gameId, bool enabled) async {
    final existing = _gameSyncStates[gameId];
    if (existing != null) {
      _gameSyncStates[gameId] = existing.copyWith(
        cloudEnabled: enabled,
        status: enabled ? existing.status : GameSyncStatus.disabled,
      );
      notifyListeners();
    }
  }

  // ── Core sync operations (interface) ────────────────────────────────────────

  @override
  Future<SyncResult> uploadSave(
    String gameId,
    File file, {
    String? customFileName,
  }) async {
    final romId = int.tryParse(gameId);
    if (romId == null) {
      return SyncResult.fail(
        SyncError.configInvalid,
        message: 'uploadSave expects a RomM rom_id',
      );
    }
    try {
      await _svc.uploadSave(romId, file, slot: _saveSlot);
      return SyncResult.ok();
    } catch (e) {
      return SyncResult.fail(SyncError.networkError, message: e.toString());
    }
  }

  @override
  Future<SyncResult> downloadSave(String gameId, String fileId) async {
    final assetId = int.tryParse(fileId);
    if (assetId == null) {
      return SyncResult.fail(SyncError.fileNotFound, message: 'Invalid fileId');
    }
    try {
      final bytes = await _svc.downloadSaveContent(assetId);
      return SyncResult.ok(data: bytes);
    } catch (e) {
      return SyncResult.fail(SyncError.networkError, message: e.toString());
    }
  }

  @override
  Future<List<SyncFile>> listSaves({String? gameId}) async {
    final romId = gameId == null ? null : int.tryParse(gameId);
    if (romId == null) return const [];
    try {
      // Independent GETs → fetch concurrently rather than serially.
      final results = await Future.wait([
        _svc.listSaves(romId: romId),
        _svc.listStates(romId: romId),
      ]);
      // Conflict backups are filtered here too, not just in [_syncGame]. This
      // reports what a caller may sync, not an inventory of the server, and a
      // backup is never syncable in either direction — leaving it in would put
      // the download gap back the moment anything transfers from this listing.
      final assets = syncableRemote([...results[0], ...results[1]]);
      return assets
          .map(
            (a) => SyncFile(
              id: a.id.toString(),
              fileName: a.fileName,
              gameId: gameId,
              fileSize: a.fileSizeBytes,
              uploadedAt: a.createdAt ?? DateTime.now(),
              modifiedAt: a.updatedAt,
              checksum: a.contentHash,
            ),
          )
          .toList();
    } catch (e) {
      _log.e('RomM listSaves failed: $e');
      return const [];
    }
  }

  @override
  Future<SyncResult> fullSync() async {
    // Not a bidirectional sync of the library, and deliberately so: pulls are
    // scoped to the game about to launch, where a deadline and a known target
    // make them safe. What a global pass *can* honestly do is push what never
    // made it up, so this is the pending-upload sweep. Anything calling it gets
    // real work rather than the "syncs per-game on launch/close" no-op it used
    // to answer with, which looked like success and did nothing.
    return retryPendingUploads();
  }

  // ── Pending-upload sweep ───────────────────────────────────────────────────

  /// How long after connecting the automatic sweep waits before starting.
  ///
  /// Long enough to stay off the cold-start path: connecting happens during
  /// `initialize()`, and phase one walks the save folders of every linked game.
  /// Startup is this app's measured bottleneck, and a retry that has already
  /// waited for an offline stretch to end can wait another half minute.
  static const Duration _sweepStartupDelay = Duration(seconds: 30);

  /// The sweep in progress, or null. Also the guard against overlapping sweeps
  /// (connect + a manual [fullSync]).
  final _sweeping = ValueNotifier<Future<SyncResult>?>(null);

  /// The pending-upload sweep in progress, automatic or manual, or null when
  /// none is. The Saves tab shows one it did not start as busy and refreshes
  /// when it ends. A separate notifier, because notifying this
  /// provider's listeners would rebuild the library UI twice per sweep for a
  /// change it does not show.
  ValueListenable<Future<SyncResult>?> get runningSweep => _sweeping;

  /// Guard against overlapping link passes, the same way [_sweeping] guards
  /// the sweep. A skipped pass is not rescheduled; the next connect runs it.
  bool _linking = false;

  /// Whether [_browse] was connected at the last notification, so the sweep
  /// fires on the *transition* rather than on every notify a connected provider
  /// emits (which is one per browse page, download tick and token refresh).
  bool _wasConnected = false;

  /// Re-attempts the uploads a failed post-close hook left behind.
  ///
  /// Uploads happen on one hook only — shortly after a game closes — so a
  /// failure there (offline, server unreachable, app killed mid-upload) used to
  /// wait for the next play-and-quit *of that same game* before anything tried
  /// again. This sweeps every RomM-linked game instead, making connect (or a
  /// manual [fullSync]) the catch-up point after an offline stretch.
  ///
  /// Upload-only, and narrower than the post-close hook on purpose: a file is
  /// pushed only when the local copy has moved since we last recorded it **and
  /// the server's has not**. See the both-changed note in [_syncGame] — a sweep
  /// has no just-ended session to break a tie with, and claiming that authority
  /// is how it would overwrite another device's newer save.
  ///
  /// Two-phase on purpose. Phase one is local only (locate saves, compare with
  /// the recorded sync state) and decides which games are candidates; only those
  /// pay the two listing round-trips of phase two. A library with nothing
  /// pending therefore costs no network at all, which is what makes this safe to
  /// fire automatically.
  ///
  /// Never throws. A game that fails is counted and stepped over — except a
  /// permission denial, which would fail identically for every remaining game
  /// and so ends the sweep.
  Future<SyncResult> retryPendingUploads() async {
    if (!_browse.isConnected) return SyncResult.fail(SyncError.authRequired);
    // Whichever call got here first is doing the same work, but this one did
    // nothing and cannot vouch for that sweep's outcome, so it is not a success.
    if (_sweeping.value != null) {
      return SyncResult.fail(SyncError.busy, message: 'Sweep already running');
    }
    // An error (the library or link index unreadable) becomes a failed result,
    // so followers never see it, and is reported as a sweep that names no
    // games, like one a permission denial stops.
    final sweep = _sweepPendingUploads().catchError((Object e) {
      _log.e('RomM upload sweep failed: $e');
      _reportUploadFailures(unidentified: true);
      return SyncResult.fail(SyncError.unknown, message: e.toString());
    });
    _sweeping.value = sweep;
    try {
      return await sweep;
    } finally {
      if (!_disposed) _sweeping.value = null;
    }
  }

  /// Games whose saves did not upload, to their display names, in the order
  /// they first failed. Kept by the sweep and by each post-close sync, each
  /// recording a game's outcome as it learns it, so the latest one stands.
  final Map<_GameKey, String> _failedUploads = {};

  /// Records what an upload attempt [left] of [game]'s saves. Returns whether
  /// that is news: a failure, which is reported again each time it recurs, or
  /// a game that no longer fails.
  bool _noteUpload(GameModel game, _Pending left) {
    switch (left) {
      case _Pending.waiting:
        _failedUploads[_keyOf(game)] = game.name;
        return true;
      case _Pending.none:
        return _failedUploads.remove(_keyOf(game)) != null;
      case _Pending.deferred:
      case _Pending.unknown:
        // Nothing settled either way.
        return false;
    }
  }

  /// The current upload failures, which the app shows as a notification.
  /// Every report is a new value, so a failure that repeats is shown again.
  ValueListenable<RommUploadFailures> get uploadFailures => _uploadFailures;
  final _uploadFailures = ValueNotifier(RommUploadFailures.none);

  /// Publishes [_failedUploads], or with [unidentified], a failure that names
  /// no game.
  void _reportUploadFailures({bool unidentified = false}) {
    if (_disposed) return;
    _uploadFailures.value = RommUploadFailures(
      List.unmodifiable(_failedUploads.values),
      unidentified: unidentified,
    );
  }

  /// [retryPendingUploads] itself, run under its guard against overlap.
  ///
  /// Uploads outlive the Saves tab, so the sweep reports its own outcome in
  /// [uploadFailures], whoever started it. It records each game's outcome as
  /// it reaches the game rather than replacing the list at the end, so a
  /// post-close sync that fails behind it, for a game it has already passed,
  /// is still reported once it ends.
  Future<SyncResult> _sweepPendingUploads() async {
    // A save the emulator wrote back over a launch's download would read as
    // a change to upload (on a cold start, say, after Android closed
    // NeoStation behind the emulator): told apart first.
    await _checkLaunchDownloads();
    final index = await RommSaveMapRepository.getRomIdIndex();
    if (index.isEmpty) {
      _log.i('RomM upload sweep: no linked games');
      // With nothing linked, nothing can be waiting to go up.
      _failedUploads.clear();
      _reportUploadFailures();
      return SyncResult.ok(message: 'No RomM-linked games to sweep');
    }

    var linked = 0, candidates = 0, synced = 0, failed = 0, deferred = 0;
    final listed = <_GameKey>{};
    var touched = false;
    for (final game in await _listGames()) {
      // A disconnect (or a sign-out) mid-sweep ends it; every remaining game
      // would fail against a server we no longer have credentials for.
      if (!_browse.isConnected) break;
      listed.add(_keyOf(game));

      final folder = game.systemFolderName;
      final sweepable =
          folder != null &&
          folder.isNotEmpty &&
          index.lookup(game.romname, folder) != null &&
          game.cloudSyncEnabled == true;
      if (sweepable) linked++;
      final pending = sweepable ? await _pendingUpload(game) : _Pending.none;
      if (pending != _Pending.waiting) {
        // Nothing of this game's is waiting to go up, or its saves could not
        // be checked.
        _noteUpload(game, pending);
        continue;
      }

      candidates++;
      try {
        final sync = await _syncGame(
          game,
          downloadOnly: false,
          uploadOnly: true,
        );
        // A sync that could not tell is answered from the disk again: one that
        // listed only saves or only states may have sent some since the
        // pre-check. If the disk can't say either, the pre-check's answer
        // stands.
        var left = sync.uploads;
        if (left == _Pending.unknown) left = await _pendingUpload(game);
        if (left == _Pending.unknown) left = pending;
        if (left == _Pending.waiting) {
          failed++;
        } else if (left == _Pending.deferred) {
          deferred++;
        } else {
          synced++;
        }
        _noteUpload(game, left);
        _gameSyncStates[game.romname] = _buildState(game, sync.status);
        touched = true;
      } catch (e) {
        if (isPermissionDenied(e)) {
          _log.e('RomM upload sweep: permission denied, stopping: $e');
          _gameSyncStates[game.romname] = _buildState(
            game,
            GameSyncStatus.error,
            errorMessage: e.toString(),
          );
          if (touched) notifyListeners();
          // It stopped short, so it cannot say which games are left.
          _reportUploadFailures(unidentified: true);
          // Same error shape [_failGame] uses for a bubbled-up 403, so a
          // sweep failure reads like any other hard sync failure.
          return SyncResult.fail(SyncError.unknown, message: e.toString());
        }
        _log.e('RomM upload sweep: ${game.romname} failed: $e');
        failed++;
        _noteUpload(game, pending);
      }
    }

    // One notification for the whole sweep: it can touch hundreds of games,
    // and notifying per game would rebuild the library UI hundreds of times.
    if (touched) notifyListeners();
    // A disconnect ended the sweep, which says nothing about the uploads.
    if (!_browse.isConnected) {
      return SyncResult.fail(SyncError.authRequired);
    }
    // A game that left the library has nothing left to upload. The listing
    // predates the sweep, so a game missing from it may instead be one added
    // since, whose upload failed after it closed: the library as it is now
    // decides.
    if (_failedUploads.keys.any((key) => !listed.contains(key))) {
      final current = {for (final game in await _listGames()) _keyOf(game)};
      _failedUploads.removeWhere((key, _) => !current.contains(key));
    }
    _reportUploadFailures();
    if (candidates == 0) {
      // Logged even when it does nothing: this is the only outward sign the
      // automatic sweep ran at all, and phase one costs no network.
      _log.i('RomM upload sweep: nothing pending ($linked linked games)');
      return SyncResult.ok(message: 'Nothing pending');
    }
    _log.i(
      'RomM upload sweep: $candidates pending, $synced synced, $failed failed, '
      '$deferred deferred',
    );
    if (failed > 0) {
      return SyncResult.fail(
        SyncError.unknown,
        message: '$failed of $candidates pending games failed to sync',
      );
    }
    return SyncResult.ok(
      message: '$synced of $candidates pending games synced',
    );
  }

  /// [_Pending.waiting] when [game] has a local save the server has not been
  /// told about — either never recorded, or changed since it was recorded —
  /// and [_Pending.unknown] when its save folder could not be read.
  /// [_Pending.deferred] when the only such save is a memory card every game
  /// shares that this device has never synced: that waits for the game's own
  /// syncs, unless its upload already failed.
  ///
  /// The point of this check is that it touches only the disk and the local
  /// sync-state table, so the sweep can rule a game out without a round trip.
  ///
  /// [afterClose]: asked for a post-close sync that could not tell, where a
  /// never-synced card may be the session's and not have gone up: waiting.
  Future<_Pending> _pendingUpload(
    GameModel game, {
    bool afterClose = false,
  }) async {
    final List<LocalSaveFile> localFiles;
    try {
      localFiles = await _passSaves(game, _placementFor(game));
    } catch (e) {
      // Not worth a round trip to find out, and no reason to stop reporting a
      // save that failed before.
      _log.w('RomM: cannot locate saves for ${game.romname}: $e');
      return _Pending.unknown;
    }
    final sharesCards = sharesMemoryCards(game.systemFolderName);
    var left = _Pending.none;
    for (final local in localFiles) {
      final sharedCard =
          sharesCards &&
          !local.relativePath.startsWith('states/') &&
          isSharedMemoryCard(local.filePath);
      final recorded = sharedCard
          ? await _cardSyncRecord(local.filePath)
          : await SyncRepository.getSyncState(kProviderId, local.filePath);
      // A shared memory card this device has never synced is not a sweep's to
      // send (only after the game closes is it known to be the card in use),
      // unless the upload after it closed failed: that is retried.
      if (recorded == null && sharedCard) {
        if (afterClose || _failedUploads.containsKey(_keyOf(game))) {
          return _Pending.waiting;
        }
        left = _Pending.deferred;
        continue;
      }
      // No record at all: either a first upload that failed, or a save made
      // before RomM sync was on. Both want pushing.
      if (recorded == null) return _Pending.waiting;
      final recordedLocalMs = (recorded['local_modified_at'] as int?) ?? 0;
      if (local.lastModified.millisecondsSinceEpoch >
          recordedLocalMs + _mtimeToleranceMs) {
        return _Pending.waiting;
      }
    }
    return left;
  }

  /// Fires the connect-time work once, on a disconnected → connected
  /// transition.
  ///
  /// A skipped run is not rescheduled; the next connect picks it up.
  void _onBrowseChanged() {
    final connected = _browse.isConnected;
    if (connected == _wasConnected) return;
    _wasConnected = connected;
    // Another server or account may follow: its saves are not these.
    _everySaveCache = null;
    if (!connected) return;
    _scheduleSweep();
  }

  void _scheduleSweep() {
    unawaited(
      Future<void>.delayed(_startupDelay).then((_) async {
        if (_disposed) return;
        if (!_browse.isConnected) {
          _log.i('RomM upload sweep: skipped, disconnected before it ran');
          return;
        }
        if (_browse.bulkSync.isRunning) {
          _log.i(
            'RomM connect-time link pass and upload sweep skipped: '
            'a bulk ROM sync is running',
          );
          return;
        }

        // Playtime first, and deliberately *not* behind the active-provider
        // gate below: it is a statistic, not save authority. See
        // [pullRecentPlaytime].
        try {
          await pullRecentPlaytime();
        } catch (e) {
          _log.w('RomM playtime pull failed: $e');
        }
        if (_disposed || !_browse.isConnected) return;

        if (SyncManager.instance.activeProviderId != kProviderId) {
          _log.i('RomM upload sweep: skipped, RomM is not the save provider');
          return;
        }
        try {
          await retryPendingUploads();
        } catch (e) {
          // retryPendingUploads is documented not to throw; this is the
          // belt-and-braces that keeps an unawaited future from going unhandled.
          _log.w('RomM upload sweep failed: $e');
        }
      }),
    );
  }

  /// Runs the library-wide link pass once, under the sweep's guards.
  ///
  /// Called from Settings > Tools, not from the connect path. It used to run 30
  /// seconds after every connect transition and outside the active-provider
  /// gate, which meant someone running NeoSync for saves, who never opened the
  /// RomM screen, still paid a full server walk on every launch — minutes, on a
  /// real device with a large library, with the JSON decoded on the platform
  /// thread, where a long frame is an ANR rather than a dropped frame.
  ///
  /// The consent half mattered more than the cost. A mapping row is the gate
  /// for save sync, so an unattended pass that linked most of a library also
  /// enrolled games whose saves then uploaded unasked. A row existing only for
  /// games the user downloaded is what made save sync opt-in, which is what the
  /// doc at the top of this file describes; the pass widened that silently.
  /// Behind a button with a confirmation, it does not.
  ///
  /// Linking on download, the A press on a browse tile and the Manage tab's
  /// picker are all unchanged — each is cheap and already user-initiated.
  ///
  /// Skipped — with a log line saying why — when disconnected, when a bulk
  /// ROM sync is running (its enumeration is walking the same server and its
  /// downloads are writing the same table), or when a pass is already in
  /// flight. Skipping never reschedules. On completion the games the pass
  /// linked have their cached sync state dropped in one go, so the badge and
  /// the browse grid see the links without a restart.
  ///
  /// Returns the pass summary, or null when the pass was **skipped** — one of
  /// the three guards above, and nothing else. A null therefore means "not run,
  /// and that is fine", which is what the caller reports.
  ///
  /// The linker's own failures (library, platform list or platform-to-system
  /// resolution unreadable) are [RommLinkPassException] and propagate. They
  /// used to be caught here and turned into a null, which made a real server
  /// error indistinguishable from a deliberate skip: the Tools run reported
  /// "unavailable" for a failed library read, sending anyone who saw it looking
  /// for a connection problem that was not there.
  Future<RommLinkPassSummary?> linkLibrary({
    void Function(int done, int total, String system)? onProgress,
  }) async {
    if (!_browse.isConnected) {
      _log.i('RomM link pass skipped: disconnected');
      return null;
    }
    if (_browse.bulkSync.isRunning) {
      _log.i('RomM link pass skipped: a bulk ROM sync is running');
      return null;
    }
    if (_linking) {
      _log.i('RomM link pass skipped: a pass is already running');
      return null;
    }
    _linking = true;
    try {
      final summary = await _linker.run(onProgress: onProgress);
      if (summary.linkedRomnames.isNotEmpty) {
        invalidateGameSyncStates(summary.linkedRomnames);
      }
      return summary;
    } finally {
      _linking = false;
    }
  }

  /// The production linker: server access through [_browse], the library and
  /// the map through their repositories, and a stop check tied to this
  /// provider's lifetime.
  RommLibraryLinker _buildLinker() => RommLibraryLinker(
    listPlatforms: listPlatformsForLinkPass,
    resolveSystem: _browse.systemForPlatform,
    fetchPage: ({required platformId, required limit, required offset}) => _svc
        .getRomsPage(platformIds: [platformId], limit: limit, offset: offset),
    listGames: GameRepository.getRommLinkRows,
    loadRomIdIndex: RommSaveMapRepository.getRomIdIndex,
    putMappingsIfAbsent: RommSaveMapRepository.putMappingsIfAbsent,
    shouldStop: () => _disposed || !_browse.isConnected,
  );

  /// The server's platform list, reloaded for this pass.
  ///
  /// Going through [RommProvider.loadPlatforms] rather than the service means
  /// its support classification runs, which warms the per-platform system
  /// cache [RommProvider.systemForPlatform] reads and lets it try each
  /// platform's `fs_slug`, and the browse screen gets the fresh list too.
  ///
  /// The load is forced. The list the RomM tab (or the match picker, the
  /// search filter, an earlier pass) cached for the session would let a pass
  /// start against a server that has since gone away: every platform then
  /// failed on its own, and the pass ended as "nothing new to link". A forced
  /// load asks the server, and its failure — swallowed by the provider into
  /// [RommProvider.platformsFailure] — fails the pass with its reason, cached
  /// list or not. Only that load's own failure counts: [RommProvider.lastError]
  /// is shared with the other loads and the connection. A failed reload keeps
  /// the browse screen's list as it was.
  ///
  /// A load already in flight is awaited, not raced: `loadPlatforms` returns
  /// at once while one is running, so the forced load would do nothing. That
  /// holds both before the forced call and after it (the browse screen can
  /// start a load in between). Should the list still be empty and loading
  /// after that, the pass fails with that as its named reason.
  @visibleForTesting
  Future<List<RommPlatform>> listPlatformsForLinkPass() async {
    if (_browse.isLoadingPlatforms) {
      _log.i('RomM link pass waiting: the platform list is still loading');
      await _browse.platformsLoaded;
    }
    await _browse.loadPlatforms(force: true);
    if (_browse.isLoadingPlatforms) await _browse.platformsLoaded;
    final platforms = _browse.platforms;
    final failure = _browse.platformsFailure;
    if (failure != null) {
      // The failure itself, so the Tools run can say why in the app language.
      throw failure;
    }
    if (platforms.isEmpty && _browse.isLoadingPlatforms) {
      throw StateError('the platform list is still loading');
    }
    return platforms;
  }

  /// Folds playtime recorded on other devices into the local totals.
  ///
  /// Sessions are *pushed* on connect whatever the save-sync toggle says, but
  /// the matching pull only ever ran inside a RomM-active save sync — so a user
  /// who keeps NeoSync as their save provider uploaded their play and never got
  /// anyone else's back. This closes that half, and is therefore **not** gated
  /// on RomM being the active save provider: playtime is a statistic, and
  /// nothing about it decides which copy of a save wins.
  ///
  /// Bounded by asking the server which ROMs are worth asking about:
  /// [RommService.getRecentlyPlayedRoms] returns only ROMs that have ever been
  /// played (5 of 9,899 on the dev library), newest first. Without that the
  /// pull would be one session request per linked game — hundreds after a bulk
  /// sync, on every connect. The per-ROM pull is throttled again by
  /// [RommPlaytimeService.pullInterval], so reconnecting inside that window
  /// costs one request in total.
  ///
  /// Never throws: a failure here must not stop the upload sweep that follows.
  Future<void> pullRecentPlaytime() async {
    _activeSyncs++;
    try {
      await _pullRecentPlaytime();
    } finally {
      _activeSyncs--;
    }
  }

  Future<void> _pullRecentPlaytime() async {
    if (!_browse.isConnected || !_svc.playtimePullAvailable) return;

    final List<RommRom> recent;
    try {
      recent = await _svc.getRecentlyPlayedRoms();
    } catch (e) {
      _log.w('RomM playtime pull: could not list recently played: $e');
      return;
    }
    if (recent.isEmpty) return;

    final paths = await RommSaveMapRepository.getRomPathsForRomIds(
      recent.map((r) => r.id),
    );
    if (paths.isEmpty) {
      _log.i(
        'RomM playtime pull: ${recent.length} played on the server, '
        'none linked here',
      );
      return;
    }

    var applied = 0;
    for (final rom in recent) {
      if (_disposed || !_browse.isConnected) break;
      final romPath = paths[rom.id];
      if (romPath == null) continue;
      try {
        if (await RommPlaytimeService.pullPlaytime(
          _svc,
          romId: rom.id,
          romPath: romPath,
        )) {
          applied++;
        }
      } catch (e) {
        _log.w('RomM playtime pull failed for rom ${rom.id}: $e');
      }
    }
    _log.i(
      'RomM playtime pull: ${paths.length} of ${recent.length} played games '
      'linked here, $applied updated',
    );
  }

  @override
  Future<SyncResult> deleteRemote(String fileId) async => SyncResult.fail(
    SyncError.unknown,
    message: 'deleteRemote not supported by $providerId',
  );

  @override
  Future<SyncQuota?> getQuota() async => null;
}

/// A sync pass's answers about where [RomMSyncProvider] puts a game's
/// downloads, each looked up on first use and then reused.
class _Placement {
  _Placement({
    required Future<List<String>> Function() folders,
    required Future<({bool standalone, String? folder})> Function() standalone,
    required Future<String?> Function() coreFolder,
    required Future<Set<String>> Function() otherSystemsCores,
    required Future<RetroArchConfig> Function() retroArchConfig,
    required this.contentDir,
  }) : _foldersLookup = folders,
       _standaloneLookup = standalone,
       _coreFolderLookup = coreFolder,
       _otherSystemsCoresLookup = otherSystemsCores,
       _retroArchConfigLookup = retroArchConfig;

  final Future<List<String>> Function() _foldersLookup;
  final Future<({bool standalone, String? folder})> Function()
  _standaloneLookup;
  Future<List<String>>? _folders;
  Future<({bool standalone, String? folder})>? _standalone;
  final Future<String?> Function() _coreFolderLookup;
  Future<String?>? _coreFolder;
  final Future<Set<String>> Function() _otherSystemsCoresLookup;
  Future<Set<String>>? _otherSystemsCores;
  final Future<RetroArchConfig> Function() _retroArchConfigLookup;
  Future<_RetroArchLayout>? _retroArch;

  /// The name RetroArch gives the game's content folder, if any.
  final String? contentDir;

  /// The game's system's configured standalone save folders.
  Future<List<String>> folders() => _folders ??= _foldersLookup();

  /// Whether [filePath] is inside one of [folders].
  Future<bool> inSaveFolder(String filePath) async => (await folders()).any(
    (root) => path.equals(root, filePath) || path.isWithin(root, filePath),
  );

  /// Whether the game launches with a standalone emulator, and its folder.
  Future<({bool standalone, String? folder})> standalone() =>
      _standalone ??= _standaloneLookup();

  /// RetroArch's folder name for the core the game launches with, if any.
  Future<String?> coreFolder() => _coreFolder ??= _coreFolderLookup();

  /// RetroArch's folder names for other systems' cores (not the game's).
  Future<Set<String>> otherSystemsCores() =>
      _otherSystemsCores ??= _otherSystemsCoresLookup();

  /// RetroArch's folders as the game sees them, from [config] when the
  /// caller already has it.
  Future<_RetroArchLayout> retroArch([
    RetroArchConfig? config,
  ]) => _retroArch ??=
      (config != null ? Future.value(config) : _retroArchConfigLookup()).then(
        (c) => _RetroArchLayout(c, contentDir, coreFolder, otherSystemsCores),
      );
}

/// RetroArch's saves and states folders as a sync of one game sees them.
class _RetroArchLayout {
  _RetroArchLayout(
    this.config,
    this.contentDir,
    this._launchCore,
    this._otherSystemsCores,
  );

  final RetroArchConfig config;

  /// The name RetroArch gives the game's content folder, if it has one (see
  /// [RetroArchConfigService.contentDirName]).
  final String? contentDir;

  /// RetroArch's folder name for the core the game launches with.
  final Future<String?> Function() _launchCore;

  /// RetroArch's folder names for other systems' cores, in lower case (see
  /// [RomMSyncProvider.otherSystemsCoreFoldersFor]).
  final Future<Set<String>> Function() _otherSystemsCores;

  /// Whether folder names are the same regardless of case, as they are on
  /// the file systems Windows and macOS use and on Android's shared storage.
  static bool get _caseInsensitive =>
      RomMSyncProvider.debugFoldersIgnoreCase ??
      (Platform.isWindows || Platform.isMacOS || Platform.isAndroid);

  static bool sameName(String a, String b) =>
      _caseInsensitive ? a.toLowerCase() == b.toLowerCase() : a == b;

  Future<bool> _anotherSystemsCore(String folder) async =>
      (await _otherSystemsCores()).contains(folder.toLowerCase());

  bool _byCore(bool isState) =>
      isState ? config.sortSavestatesByCore : config.sortSavefilesByCore;

  bool _byContent(bool isState) =>
      isState ? config.sortSavestatesByContent : config.sortSavefilesByContent;

  /// Where [file] sits in RetroArch's saves or states folder, whichever is
  /// its kind: the subfolder, `''` for the folder itself, or null when it is
  /// somewhere else (RetroArch's system folder, a standalone emulator's
  /// folder, any other). Told from the file's own path: a file found outside
  /// the folder a [LocalSaveFile.relativePath] is counted from is given a
  /// `saves/<name>` one, the same as a file in the folder's root.
  String? subfolderOf(LocalSaveFile file) {
    if (file.inRetroArchSystemFolder || file.customFolderEmulator != null) {
      return null;
    }
    final dir = file.relativePath.startsWith('states/')
        ? config.savestateDirectory
        : config.savefileDirectory;
    if (dir == null || dir.isEmpty) return null;
    final root = path.normalize(path.absolute(dir));
    final parent = path.normalize(path.absolute(path.dirname(file.filePath)));
    if (path.equals(root, parent)) return '';
    if (!path.isWithin(root, parent)) return null;
    return path.split(path.relative(parent, from: root)).join('/');
  }

  /// Whether RetroArch reads this game's saves (or states, [isState]) from
  /// [subfolder] of its folder.
  ///
  /// With its settings read, that is the one subfolder they make (see
  /// [RetroArchConfigService.saveSubfolder]), whatever the core's name. Without
  /// them, any this game's files can be in under one of RetroArch's sortings:
  /// the folder itself, its content folder, the folder of the core it
  /// launches with, or that core's folder inside its content folder.
  Future<bool> reads(String subfolder, bool isState) async {
    final parts = subfolder.isEmpty ? const <String>[] : subfolder.split('/');
    if (config.settingsRead) {
      final content = _byContent(isState) ? contentDir : null;
      final depth = (content == null ? 0 : 1) + (_byCore(isState) ? 1 : 0);
      if (parts.length != depth) return false;
      if (content != null && !sameName(parts.first, content)) return false;
      return !_byCore(isState) || !await _anotherSystemsCore(parts.last);
    }
    final content = contentDir;
    if (parts.isEmpty) return true;
    if (parts.length == 1 &&
        content != null &&
        sameName(parts.first, content)) {
      return true;
    }
    if (parts.length > 2) return false;
    final core = await _launchCore();
    if (core == null || core.isEmpty) return false;
    return parts.length == 1
        ? sameName(parts.first, core)
        : content != null &&
              sameName(parts.first, content) &&
              sameName(parts.last, core);
  }

  /// Whether [subfolder] holds another game's files, with RetroArch's
  /// settings read: it is under another content folder when RetroArch sorts
  /// this kind by the folder the game is in, or another system's core folder
  /// when it sorts by core.
  Future<bool> anotherGames(String subfolder, bool isState) async {
    if (!config.settingsRead || subfolder.isEmpty) return false;
    final parts = subfolder.split('/');
    final content = contentDir;
    if (_byContent(isState) &&
        content != null &&
        !sameName(parts.first, content)) {
      return true;
    }
    if (!_byCore(isState)) return false;
    final coreAt = _byContent(isState) && content != null ? 1 : 0;
    return parts.length == coreAt + 1 &&
        await _anotherSystemsCore(parts[coreAt]);
  }
}
