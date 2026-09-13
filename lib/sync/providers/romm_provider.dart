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
import 'package:neostation/models/game_model.dart';
import 'package:neostation/models/neo_sync_models.dart';
import 'package:neostation/models/romm_asset.dart';
import 'package:neostation/models/romm_platform.dart';
import 'package:neostation/models/romm_rom.dart';
import 'package:neostation/providers/neo_sync_provider.dart';
import 'package:neostation/repositories/emulator_repository.dart';
import 'package:neostation/repositories/game_repository.dart';
import 'package:neostation/services/retroarch_config_service.dart';
import 'package:neostation/providers/romm_provider.dart';
import 'package:neostation/repositories/romm_save_map_repository.dart';
import 'package:neostation/repositories/sync_repository.dart';
import 'package:neostation/repositories/system_repository.dart';
import 'package:neostation/services/logger_service.dart';
import 'package:neostation/services/romm/romm_library_linker.dart';
import 'package:neostation/services/romm_playtime_service.dart';
import 'package:neostation/services/romm_service.dart';

import '../i_sync_provider.dart';
import '../retroarch_state_signature.dart';
import '../sync_manager.dart';

/// Locates the local save/state files belonging to a game.
typedef LocateGameSaves = Future<List<LocalSaveFile>> Function(GameModel game);

/// Resolves the candidate local destination paths for a cloud file named
/// [relativeName] (e.g. `saves/Game.srm`) belonging to a game.
typedef ResolveSaveTargets =
    Future<List<String>> Function(GameModel game, String relativeName);

/// Enumerates the local library, for the pending-upload sweep.
typedef ListLocalGames = Future<List<GameModel>> Function();

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
    @visibleForTesting bool autoSweep = true,
    @visibleForTesting RommLibraryLinker? linker,
    @visibleForTesting Duration sweepStartupDelay = _sweepStartupDelay,
  }) : _locateOverride = locateSaves,
       _resolveTargetsOverride = resolveTargets,
       _listGamesOverride = listGames,
       _autoSweep = autoSweep,
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
    super.dispose();
  }

  Future<List<LocalSaveFile>> _locateSaves(GameModel game) =>
      (_locateOverride ?? _neoSync.locateGameSaveFiles)(game);

  Future<List<String>> _resolveTargets(GameModel game, String relativeName) =>
      (_resolveTargetsOverride ?? _neoSync.resolveLocalTargetPaths)(
        game,
        relativeName,
      );

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

  @override
  String? get lastError => _browse.lastError;

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
  Future<GameSyncStatus> _syncGame(
    GameModel game, {
    required bool downloadOnly,
    bool statusOnly = false,
    bool uploadOnly = false,
    SyncDeadline? deadline,
  }) async {
    if (!_browse.isConnected) return GameSyncStatus.error;
    // Honour the sync opt-outs exactly the way NeoSync does: a null per-game
    // flag counts as disabled, and a system whose config sets `sync: false`
    // (e.g. shared-memcard systems the user deliberately excluded) is skipped
    // regardless of the per-game flag.
    if (game.cloudSyncEnabled != true) return GameSyncStatus.disabled;
    final systemFolder = game.systemFolderName;
    if (systemFolder != null && systemFolder.isNotEmpty) {
      final system = await SystemRepository.getSystemByFolderName(systemFolder);
      if (system != null && !system.neosync.sync) {
        return GameSyncStatus.disabled;
      }
    }

    final romId = await _resolveRomId(game);
    if (romId == null) {
      // Not a RomM-linked game (wasn't downloaded through the app). Report
      // "disabled" — sync simply doesn't apply — rather than "no save found",
      // which would be a lie whenever the game has perfectly good local saves.
      return GameSyncStatus.disabled;
    }

    final localFiles = syncableSaves(game, await _locateSaves(game));

    final List<RommAsset> remote;
    try {
      // The two listings are independent GETs; fetch them concurrently so the
      // launch-blocking sync pays one round-trip, not two serial ones.
      final results = await Future.wait([
        _svc.listSaves(romId: romId),
        _svc.listStates(romId: romId),
      ]);
      // Collapse a slot's version history before anything looks at the listing,
      // so the pairing loop and the remote-only pass below agree on which asset
      // represents each local file. Conflict backups are dropped first: they
      // must never reach the pairing loop, and filtering them here is cheaper
      // than deduping them and discarding the survivor.
      remote = latestPerLocalName(
        syncableRemote([...results[0], ...results[1]]),
      );
    } catch (e) {
      _log.e('RomM listSaves/listStates failed for ${game.romname}: $e');
      return GameSyncStatus.error;
    }

    // Assets already paired with a local file. Keyed by kind *and* id: the two
    // endpoints number their rows independently, so a bare id would let a save
    // mask a state that happens to share it.
    final matchedRemote = <String>{};
    String remoteKey(RommAsset a) => '${a.isState ? 's' : 'f'}:${a.id}';
    int uploaded = 0, downloaded = 0, coreMismatched = 0;
    int conflictsPreserved = 0;
    bool anyLocal = localFiles.isNotEmpty;
    bool anyRemote = remote.isNotEmpty;

    // 1) Reconcile each local file against its remote counterpart.
    for (final local in localFiles) {
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
      if (match != null) matchedRemote.add(remoteKey(match));

      final localMs = local.lastModified.millisecondsSinceEpoch;
      final recorded = await SyncRepository.getSyncState(
        kProviderId,
        local.filePath,
      );
      final recordedLocalMs = (recorded?['local_modified_at'] as int?) ?? 0;
      final recordedCloudMs = (recorded?['cloud_updated_at'] as int?) ?? 0;

      final localChanged =
          recorded == null || localMs > recordedLocalMs + _mtimeToleranceMs;

      if (match == null) {
        // Local only → upload (unless pre-launch download-only pass).
        if (!downloadOnly && !statusOnly) {
          if (await _upload(romId, local, isState)) uploaded++;
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
      // overwrites anything: [_download]'s per-target mtime guard refuses to
      // write over a local file newer than the remote, so a genuinely-ahead
      // local save survives and simply uploads on the next upload-capable pass.
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
        final r = await _download(
          game,
          match,
          localFiles: localFiles,
          deadline: deadline,
        );
        if (r.wrote) downloaded++;
        if (r.coreMismatch) coreMismatched++;
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
        if (uploadOnly && remoteChanged) continue;
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
        if (remoteChanged) {
          final guard = await _guardDivergedRemote(
            match,
            local,
            recordedHash: recorded?['file_hash'] as String?,
            pushDigest: pushDigest,
          );
          if (guard == _RemoteGuard.unreadable) {
            // Nothing recorded: the file stays pending and the next pass asks
            // again, which is the non-destructive way to fail.
            _log.w(
              'RomM: leaving ${path.basename(local.filePath)} pending — the '
              'remote copy it would replace could not be read',
            );
            continue;
          }
          if (guard == _RemoteGuard.preserved) conflictsPreserved++;
        }
        if (await _upload(
          romId,
          local,
          isState,
          existing: match,
          digest: pushDigest,
        )) {
          uploaded++;
        }
      }
    }

    // 2) Remote-only files → download.
    for (final a in remote) {
      if (statusOnly || uploadOnly) break;
      if (matchedRemote.contains(remoteKey(a))) continue;
      final r = await _download(
        game,
        a,
        localFiles: localFiles,
        deadline: deadline,
      );
      if (r.wrote) downloaded++;
      if (r.coreMismatch) coreMismatched++;
    }

    _log.i(
      'RomM sync ${game.romname}: $uploaded up, $downloaded down '
      '(${localFiles.length} local, ${remote.length} remote)'
      '${coreMismatched > 0 ? ', $coreMismatched kept (different core)' : ''}'
      '${conflictsPreserved > 0 ? ', $conflictsPreserved conflict backup(s)' : ''}',
    );

    // Playtime rides along with the upload-capable passes only. The pre-launch
    // pass is on the launch's critical path and playtime changes nothing about
    // the game that's about to start, so it stays out of that budget.
    if (!downloadOnly && !statusOnly) {
      await _syncPlaytime(game, romId);
    }

    if (!anyLocal && !anyRemote) return GameSyncStatus.noSaveFound;
    if (!anyRemote) return GameSyncStatus.localOnly;
    if (!anyLocal && downloaded == 0) return GameSyncStatus.cloudOnly;
    return GameSyncStatus.upToDate;
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

      // Our own conflict backups. They begin with the game's name and continue
      // with a dot, so every other rule here reads them as ordinary save data —
      // and uploading a copy kept precisely because it was *not* this device's
      // truth would undo the point of keeping it.
      if (lower.contains(conflictBackupMarker)) {
        _log.i('RomM: skipping conflict backup $name');
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
  static String _romNameWithoutExtension(String romname) {
    final dot = romname.lastIndexOf('.');
    if (dot <= 0) return romname;
    final ext = romname.substring(dot);
    // Guard against clipping a title that simply ends in a period ("Mr. Do.").
    return RegExp(r'^\.[A-Za-z0-9]{1,5}$').hasMatch(ext)
        ? romname.substring(0, dot)
        : romname;
  }

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

  /// Drops remote assets that are conflict backups.
  ///
  /// [syncableSaves] refuses to *upload* a local file carrying
  /// [conflictBackupMarker]. Without the same rule on the way down the guard is
  /// one-directional: an asset named `<game>.state.romm-conflict-<stamp>` has no
  /// local counterpart to pair with, so the remote-only pass downloads it, and
  /// every device that syncs the game acquires a permanent copy the upload side
  /// then refuses to touch — unreconcilable and unremovable from the app.
  ///
  /// A backup is by definition a copy this system kept for a person to inspect
  /// *locally*, never something to distribute, so its own marker is the whole
  /// test. Deliberately checked against the raw `file_name` rather than
  /// [localNameForAsset]: the marker survives tag-stripping, but the point is to
  /// reject the asset before anything derives a local name from it.
  @visibleForTesting
  static List<RommAsset> syncableRemote(List<RommAsset> remote) {
    return remote.where((a) {
      if (a.fileName.toLowerCase().contains(conflictBackupMarker)) {
        _log.i('RomM: skipping remote conflict backup ${a.fileName}');
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

  String _subfolderOf(LocalSaveFile local) {
    final parts = local.relativePath.split('/');
    if (parts.length <= 2) return '';
    return parts.sublist(1, parts.length - 1).join('/');
  }

  /// The subfolder a downloaded file belongs in under *this* device's RetroArch
  /// save/state directory — its per-core folder, or `''` for the directory root.
  ///
  /// Placement is a local question and is answered locally. The alternative,
  /// replaying a subfolder recorded on the server, breaks the moment two
  /// devices are configured differently: a handheld with
  /// `sort_savestates_enable` on wants `states/FCEUmm/`, while a Steam Deck
  /// with it off wants the root — and whichever uploaded first would dictate a
  /// path the other's emulator never reads.
  ///
  /// The RetroArch setting decides *whether* there is a subfolder; the core
  /// name is taken from an existing local file of the same kind when one is
  /// present (ground truth, and immune to core renames) and derived from the
  /// emulator's name otherwise.
  Future<String> _localSubfolder(
    GameModel game,
    bool isState,
    List<LocalSaveFile> localFiles,
  ) async {
    try {
      final cfg = await RetroArchConfigService().getMergedConfig();
      final sorts = isState
          ? cfg.sortSavestatesByCore
          : cfg.sortSavefilesByCore;
      if (!sorts) return '';

      final prefix = isState ? 'states/' : 'saves/';
      for (final f in localFiles) {
        if (!f.relativePath.startsWith(prefix)) continue;
        final sub = _subfolderOf(f);
        if (sub.isNotEmpty) return sub;
      }

      final folder = game.systemFolderName;
      if (folder == null || folder.isEmpty) return '';
      final system = await SystemRepository.getSystemByFolderName(folder);
      if (system?.id == null) return '';
      final emulator =
          await EmulatorRepository.getUserDefaultEmulatorForSystem(
            system!.id!,
          ) ??
          await EmulatorRepository.getDefaultEmulatorForSystem(system.id!);
      return RetroArchConfigService.coreFolderName(emulator?.name) ?? '';
    } catch (e) {
      // Placement is a best-effort refinement; the directory root is always a
      // valid destination and must never be the reason a sync fails.
      _log.w('RomM: could not resolve local save subfolder: $e');
      return '';
    }
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
  Future<_RemoteGuard> _guardDivergedRemote(
    RommAsset match,
    LocalSaveFile local, {
    required String? recordedHash,
    required String? pushDigest,
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

    try {
      final backup = File(
        '${local.filePath}$conflictBackupMarker${_backupStamp()}',
      );
      await backup.parent.create(recursive: true);
      await backup.writeAsBytes(bytes, flush: true);
      _log.w(
        'RomM conflict: ${path.basename(local.filePath)} and the server both '
        'changed since the last sync — kept the remote copy as '
        '${path.basename(backup.path)} before uploading the local one',
      );
      return _RemoteGuard.preserved;
    } catch (e) {
      _log.e(
        'RomM conflict guard: cannot write backup for ${local.filePath}: $e',
      );
      return _RemoteGuard.unreadable;
    }
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
  Future<bool> _upload(
    int romId,
    LocalSaveFile local,
    bool isState, {
    RommAsset? existing,
    String? digest,
  }) async {
    try {
      final file = File(local.filePath);
      if (!await file.exists()) return false;
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
      return true;
    } catch (e) {
      if (isPermissionDenied(e)) rethrow;
      _log.e('RomM upload failed (${local.filePath}): $e');
      return false;
    }
  }

  /// Fetches [asset] and writes it to this device's local target(s).
  ///
  /// [coreMismatch] reports the one refusal a caller needs to distinguish from
  /// an ordinary no-op: the transfer was declined because the remote state was
  /// written by a different core (see the guard below). Everything else — no
  /// target, an expired deadline, a newer local copy — is a routine `wrote:
  /// false`.
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

  Future<({bool wrote, bool coreMismatch})> _download(
    GameModel game,
    RommAsset asset, {
    required List<LocalSaveFile> localFiles,
    SyncDeadline? deadline,
  }) async {
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
      final sub = await _localSubfolder(game, asset.isState, localFiles);
      final localName = localNameForAsset(asset);
      final relativeName = sub.isNotEmpty
          ? '$prefix/$sub/$localName'
          : '$prefix/$localName';
      final targets = await _resolveTargets(game, relativeName);
      if (targets.isEmpty) {
        _log.w('RomM download: no local target for ${asset.fileName}');
        return (wrote: false, coreMismatch: false);
      }
      final bytes = await _fetchAssetBytes(asset);
      if (bytes == null) return (wrote: false, coreMismatch: false);

      // Pre-launch deadline guard: the network fetch is done, but if the
      // launch-blocking wait has already elapsed the game is running on the
      // local save. Abandon here — before any write — so we never clobber the
      // .srm the emulator now has open or record bogus sync state.
      if (deadline?.isExpired ?? false) {
        _log.i(
          'RomM download: abandon ${asset.fileName} (launch deadline passed)',
        );
        return (wrote: false, coreMismatch: false);
      }

      var wroteAny = false;
      for (final target in targets) {
        final f = File(target);
        // Per-target guard (mirrors NeoSync): never overwrite a copy that is
        // newer than the remote asset. resolveLocalTargetPaths can return
        // several folders and the higher-level decision only inspected one, so
        // a different folder may hold newer local progress we must not clobber.
        if (await f.exists()) {
          final localMs = (await f.stat()).modified.millisecondsSinceEpoch;
          if (localMs > asset.updatedAtMs + _mtimeToleranceMs) {
            _log.i('RomM download: skip $target (local newer than remote)');
            continue;
          }
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
          if (asset.isState &&
              RetroArchStateSignature.differ(await f.readAsBytes(), bytes)) {
            _log.w(
              'RomM download: skip $target — the remote state was written by a '
              'different core and would not load here',
            );
            skippedCoreMismatch = true;
            continue;
          }
        }
        await f.parent.create(recursive: true);
        await f.writeAsBytes(bytes, flush: true);
        final stat = await f.stat();
        await SyncRepository.saveSyncState(
          kProviderId,
          target,
          stat.modified.millisecondsSinceEpoch,
          asset.updatedAtMs,
          bytes.length,
          // Ours, for the reason given in [_upload] — and free here, since the
          // bytes are already in memory.
          fileHash: md5.convert(bytes).toString(),
        );
        wroteAny = true;
      }
      return (wrote: wroteAny, coreMismatch: skippedCoreMismatch);
    } catch (e) {
      if (isPermissionDenied(e)) rethrow;
      _log.e('RomM download failed (${asset.fileName}): $e');
      return (wrote: false, coreMismatch: skippedCoreMismatch);
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
  Future<SyncResult> detectGameSaveFiles(GameModel game) =>
      _runGameSync(game, downloadOnly: true, statusOnly: true);

  /// Runs a per-game sync and publishes the resulting cloud state.
  Future<SyncResult> _runGameSync(
    GameModel game, {
    required bool downloadOnly,
    bool statusOnly = false,
  }) async {
    try {
      final status = await _syncGame(
        game,
        downloadOnly: downloadOnly,
        statusOnly: statusOnly,
      );
      _gameSyncStates[game.romname] = _buildState(game, status);
      notifyListeners();
      return SyncResult.ok();
    } catch (e) {
      return _failGame(game, e);
    }
  }

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
  }) async {
    try {
      final status = await _syncGame(
        game,
        downloadOnly: true,
        deadline: deadline,
      );
      if (status == GameSyncStatus.error) {
        // A status-level failure (server unreachable, listing failed) must be
        // as visible as a thrown one: record the error state and report
        // failure. The launch flow treats any failure as best-effort, so this
        // never blocks the game from starting — it only keeps the UI honest.
        return _failGame(game, _browse.lastError ?? 'RomM save sync failed');
      }
      return SyncResult.ok();
    } catch (e) {
      // Surface a permission denial (or any hard failure) as an error state so a
      // dropped pre-launch download isn't invisible; without this the UI would
      // keep whatever state it had and read as a clean sync.
      return _failGame(game, e);
    }
  }

  @override
  Future<SyncResult> syncGameSavesAfterClose(GameModel game) =>
      // Deliberately not [detectGameSaveFiles]: this is the one hook that must
      // actually push. Detection went status-only so that merely highlighting a
      // game stops moving saves, and routing the post-close hook through it
      // would silently strand every save the user just made.
      _runGameSync(game, downloadOnly: false);

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

  /// Guard against overlapping sweeps (connect + a manual [fullSync]).
  bool _sweeping = false;

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
    // Not an error: whichever call got here first is doing the same work.
    if (_sweeping) return SyncResult.ok(message: 'Sweep already running');
    _sweeping = true;
    try {
      final index = await RommSaveMapRepository.getRomIdIndex();
      if (index.isEmpty) {
        _log.i('RomM upload sweep: no linked games');
        return SyncResult.ok(message: 'No RomM-linked games to sweep');
      }

      var linked = 0, candidates = 0, synced = 0, failed = 0;
      final touched = <String>[];
      for (final game in await _listGames()) {
        // A disconnect (or a sign-out) mid-sweep ends it; every remaining game
        // would fail against a server we no longer have credentials for.
        if (!_browse.isConnected) break;

        final folder = game.systemFolderName;
        if (folder == null || folder.isEmpty) continue;
        if (index.lookup(game.romname, folder) == null) continue;
        if (game.cloudSyncEnabled != true) continue;
        linked++;
        if (!await _hasPendingUpload(game)) continue;

        candidates++;
        try {
          final status = await _syncGame(
            game,
            downloadOnly: false,
            uploadOnly: true,
          );
          if (status == GameSyncStatus.error) {
            failed++;
          } else {
            synced++;
          }
          _gameSyncStates[game.romname] = _buildState(game, status);
          touched.add(game.romname);
        } catch (e) {
          if (isPermissionDenied(e)) {
            _log.e('RomM upload sweep: permission denied, stopping: $e');
            _gameSyncStates[game.romname] = _buildState(
              game,
              GameSyncStatus.error,
              errorMessage: e.toString(),
            );
            if (touched.isNotEmpty) notifyListeners();
            // Same error shape [_failGame] uses for a bubbled-up 403, so a
            // sweep failure reads like any other hard sync failure.
            return SyncResult.fail(SyncError.unknown, message: e.toString());
          }
          _log.e('RomM upload sweep: ${game.romname} failed: $e');
          failed++;
        }
      }

      // One notification for the whole sweep: it can touch hundreds of games,
      // and notifying per game would rebuild the library UI hundreds of times.
      if (touched.isNotEmpty) notifyListeners();
      if (candidates == 0) {
        // Logged even when it does nothing: this is the only outward sign the
        // automatic sweep ran at all, and phase one costs no network.
        _log.i('RomM upload sweep: nothing pending ($linked linked games)');
        return SyncResult.ok(message: 'Nothing pending');
      }
      _log.i(
        'RomM upload sweep: $candidates pending, $synced synced, $failed failed',
      );
      return SyncResult.ok(
        message: '$synced of $candidates pending games synced',
      );
    } finally {
      _sweeping = false;
    }
  }

  /// True when [game] has a local save the server has not been told about —
  /// either never recorded, or changed since it was recorded.
  ///
  /// The point of this check is that it touches only the disk and the local
  /// sync-state table, so the sweep can rule a game out without a round trip.
  Future<bool> _hasPendingUpload(GameModel game) async {
    final List<LocalSaveFile> localFiles;
    try {
      localFiles = syncableSaves(game, await _locateSaves(game));
    } catch (e) {
      // Unreadable save folder: not a pending upload, and not worth a round
      // trip to find out. The post-close hook will report it properly.
      _log.w('RomM upload sweep: cannot locate saves for ${game.romname}: $e');
      return false;
    }
    for (final local in localFiles) {
      final recorded = await SyncRepository.getSyncState(
        kProviderId,
        local.filePath,
      );
      // No record at all: either a first upload that failed, or a save made
      // before RomM sync was on. Both want pushing.
      if (recorded == null) return true;
      final recordedLocalMs = (recorded['local_modified_at'] as int?) ?? 0;
      if (local.lastModified.millisecondsSinceEpoch >
          recordedLocalMs + _mtimeToleranceMs) {
        return true;
      }
    }
    return false;
  }

  /// Fires the connect-time work once, on a disconnected → connected
  /// transition.
  ///
  /// A skipped run is not rescheduled; the next connect picks it up.
  void _onBrowseChanged() {
    final connected = _browse.isConnected;
    if (connected == _wasConnected) return;
    _wasConnected = connected;
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

        // Link pre-existing ROMs before the sweep, so games linked here are
        // swept in this same connect. Like playtime, not behind the
        // active-provider gate: a link is what makes the badge, playtime and
        // the browse grid's "downloaded" state right, whoever owns saves.
        try {
          await linkLibrary();
        } catch (e) {
          // linkLibrary is documented not to throw; belt-and-braces so an
          // unawaited future can't go unhandled.
          _log.w('RomM link pass failed: $e');
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

  /// Runs the connect-time link pass once, under the sweep's guards.
  ///
  /// Skipped — with a log line saying why — when disconnected, when a bulk
  /// ROM sync is running (its enumeration is walking the same server and its
  /// downloads are writing the same table), or when a pass is already in
  /// flight. Skipping never reschedules. On completion the games the pass
  /// linked have their cached sync state dropped in one go, so the badge and
  /// the browse grid see the links without a restart.
  ///
  /// Never throws: the linker's own failures (library, platform list, or
  /// platform-to-system resolution unreadable) are logged here and read as
  /// "nothing linked". Returns the pass summary, or null when the pass was
  /// skipped.
  Future<RommLinkPassSummary?> linkLibrary() async {
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
      final summary = await _linker.run();
      if (summary.linkedRomnames.isNotEmpty) {
        invalidateGameSyncStates(summary.linkedRomnames);
      }
      return summary;
    } on RommLinkPassException catch (e) {
      _log.w(e.toString());
      return null;
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

  /// The browse provider's platform list, loaded if it hasn't been yet.
  ///
  /// Going through [RommProvider.loadPlatforms] rather than the service means
  /// the list is shared with the browse screen (a no-op when it already
  /// loaded it) and, more to the point, that its support classification has
  /// run — which warms the per-platform system cache
  /// [RommProvider.systemForPlatform] reads and lets it try each platform's
  /// `fs_slug`. The provider swallows a failed load into
  /// [RommProvider.lastError], which is surfaced here as an error so the pass
  /// reports it rather than reading "no platforms".
  ///
  /// A load already in flight (the browse screen opened just before the pass
  /// fired) is awaited, not raced: `loadPlatforms` returns at once while one
  /// is running, and the pass would otherwise read an empty list and report
  /// "0 platforms processed, complete" with nothing to say why. Should the
  /// list still be empty and loading after that (a forced reload started
  /// underneath us), the pass fails with that as its named reason.
  @visibleForTesting
  Future<List<RommPlatform>> listPlatformsForLinkPass() async {
    if (_browse.isLoadingPlatforms) {
      _log.i('RomM link pass waiting: the platform list is still loading');
      await _browse.platformsLoaded;
    }
    await _browse.loadPlatforms();
    final platforms = _browse.platforms;
    if (platforms.isEmpty && _browse.lastError != null) {
      throw StateError(_browse.lastError!);
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
    if (!_browse.isConnected || !_svc.playtimeSyncAvailable) return;

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
