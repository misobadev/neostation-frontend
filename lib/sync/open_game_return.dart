/// What a sync does when NeoStation comes back to the front while a game may
/// still be open in an emulator: it uploads the saves that changed and
/// downloads nothing (the guard sees to that; see [OpenGameGuard]), and first
/// checks the saves a launch downloaded while the game may have been open.
library;

import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:neostation/models/game_model.dart';
import 'package:neostation/repositories/game_repository.dart';
import 'package:neostation/repositories/system_repository.dart';
import 'package:neostation/services/game/game_session_manager.dart';
import 'package:neostation/services/global_notification_service.dart';
import 'package:neostation/services/logger_service.dart';
import 'package:neostation/utils/kept_cloud_copy_notice.dart';
import 'package:neostation/utils/rom_stem.dart';

import 'i_sync_provider.dart';
import 'open_game_guard.dart';
import 'sync_manager.dart';

class OpenGameReturn {
  OpenGameReturn._();

  static final _log = LoggerService.instance;

  /// Games whose return sync is running, so the sync after a session ends
  /// and the one when NeoStation comes back never run for a game at once
  /// (RomM has no per-game lock of its own), and a launch of the game waits
  /// for it, or leaves its saves alone ([syncBeforeLaunch]).
  static final Map<String, Future<void>> _inFlight = {};

  /// The check of launch downloads running, per guard: concurrent callers
  /// (a return, a launch, a sync pass) share it.
  static final Map<OpenGameGuard, Future<int>> _checking = {};

  /// When each game's return sync last ran, for [returnSyncInterval].
  static final Map<String, DateTime> _lastSynced = {};

  /// A game's saves are synced at most this often by the syncs when
  /// NeoStation comes back to the front: switching between NeoStation and an
  /// emulator is quick and often repeated. The check of launch downloads,
  /// local only, runs every time.
  static const Duration returnSyncInterval = Duration(minutes: 2);

  /// The clock [returnSyncInterval] is measured with; tests set their own.
  @visibleForTesting
  static DateTime Function() now = DateTime.now;

  /// Forgets the throttle's times; for tests.
  @visibleForTesting
  static void resetForTesting() {
    _lastSynced.clear();
    _inFlight.clear();
    _checking.clear();
    now = DateTime.now;
  }

  static Timer? _scheduled;

  /// By [romStem], so a game named with its extension (a game list's) and
  /// without (Last Played, search, a library row) is one game.
  static String _key(String romname, String? systemFolder) =>
      '${systemFolder ?? ''}/${romStem(romname)}';

  /// Checks the launch downloads ([checkLaunchDownloads]), then runs
  /// [provider]'s after-close sync for [game], which uploads what changed
  /// and, while the game may still be open, downloads nothing. Skipped when
  /// one is already running for the game.
  static Future<void> syncGame(
    GameModel game,
    ISyncProvider provider, {
    OpenGameGuard? guard,
  }) async {
    final key = _key(game.romname, game.systemFolderName);
    if (_inFlight.containsKey(key)) {
      _log.i('Return sync of ${game.romname} already running; skipped');
      return;
    }
    final done = Completer<void>();
    _inFlight[key] = done.future;
    try {
      _lastSynced[key] = now();
      await checkLaunchDownloads(guard: guard);
      await provider.syncGameSavesAfterClose(game);
    } finally {
      _inFlight.remove(key);
      done.complete();
    }
  }

  /// Checks every save a launch downloaded while its game may still have
  /// been open in an emulator, whatever the game: a shared memory card's
  /// download is recorded under the game launched, and another game of the
  /// system may write it back. Returns how many the emulator ignored.
  ///
  /// A save holding what it held before the download again: the emulator
  /// still had the game open, ignored the download and wrote its own copy
  /// back. That copy isn't uploaded over the server's: the provider's record
  /// is reset to it ([ISyncProvider.rebaselineIgnoredDownload]), so the next
  /// launch downloads the server's copy again, and the bell says to quit the
  /// game in the emulator first. Unless the save held changes made here and
  /// not yet synced when it was downloaded over
  /// ([LaunchDownload.unsyncedHere]): then it is this device's progress, and
  /// its record is marked changed on both sides
  /// ([ISyncProvider.markChangedOnBothSides]), so it goes up with the
  /// server's copy kept first as a dated copy.
  ///
  /// A save that changed since the download is synced as usual (the server's
  /// copy was kept in Save history at the launch). One still holding the
  /// download, or that can't be read, can't be told yet, and is checked again
  /// at the next check, unless its game can no longer be open (that emulator
  /// launched another game, or the device restarted): this was its last
  /// check.
  ///
  /// Concurrent calls share one check (with the first caller's
  /// [providerFor] and [notifications]).
  static Future<int> checkLaunchDownloads({
    OpenGameGuard? guard,
    ISyncProvider? Function(String providerId)? providerFor,
    GlobalNotificationService? notifications,
  }) {
    final openGames = guard ?? OpenGameGuard.instance;
    final running = _checking[openGames];
    if (running != null) return running;
    final check =
        _checkLaunchDownloads(
          openGames,
          providerFor ?? SyncManager.instance.provider,
          notifications,
        ).whenComplete(() {
          // A block, not an arrow: the removed value is this check's own future,
          // which whenComplete would wait for.
          _checking.remove(openGames);
        });
    _checking[openGames] = check;
    return check;
  }

  static Future<int> _checkLaunchDownloads(
    OpenGameGuard openGames,
    ISyncProvider? Function(String providerId) providerFor,
    GlobalNotificationService? notifications,
  ) async {
    var ignored = 0;
    // Only the entry checked is forgotten (a restore forgets every
    // provider's), and only after its action: a NeoStation killed in between
    // repeats the action, which does the same again, rather than losing it.
    Future<void> forget(LaunchDownload download) => openGames.forgetDownload(
      download.path,
      providerId: download.providerId,
    );
    for (final download in openGames.downloads) {
      final open = openGames.mayBeOpen(download.romname, download.systemFolder);
      final hash = await _md5Of(download.path);
      if (hash == null) {
        // Can't be told now. While its game may be open the next check tries
        // again; once it can't be, for a day (a memory card may not be
        // mounted yet when NeoStation starts after a restart).
        if (!open && openGames.keptLongEnough(download)) {
          await forget(download);
        }
        continue;
      }
      if (hash == download.downloadedHash && open) continue;
      if (hash != download.beforeHash) {
        await forget(download);
        continue;
      }
      final provider = providerFor(download.providerId);
      // An action that didn't write the record (no provider, an error, the
      // save changed meanwhile) keeps the entry for the next check; once its
      // game can't be open, for a day at most.
      Future<void> keepOrForget() async {
        if (!open && openGames.keptLongEnough(download)) {
          await forget(download);
        }
      }

      if (download.unsyncedHere) {
        _log.i(
          '${download.path} holds what it held before the launch download '
          'again, with changes made here not yet synced: synced as changed '
          'on both sides',
        );
        if (await provider?.markChangedOnBothSides(download.path) != true) {
          await keepOrForget();
          continue;
        }
        await forget(download);
        continue;
      }
      _log.w(
        'The emulator ignored the save downloaded at the launch of '
        '${download.romname} (${download.path} holds its old copy again): '
        'not uploaded, left for the next launch',
      );
      final reset = await provider?.rebaselineIgnoredDownload(
        download.path,
        expectedHash: hash,
      );
      if (reset != true) {
        await keepOrForget();
        continue;
      }
      await forget(download);
      reportIgnoredLaunchDownload(
        gameName: download.gameName ?? download.romname,
        savePath: download.path,
        notifications: notifications,
      );
      ignored++;
    }
    return ignored;
  }

  /// The sync before a launch of [game] with [provider]: a return sync of the
  /// game still running (NeoStation just came back from it) is waited for
  /// first, at most [returnSyncWait]. If it is still running then, this
  /// launch syncs nothing, so the two never sync the game's saves at once
  /// (the game starts on its local save; the next launch pulls). Otherwise,
  /// within [budget] (the pre-launch deadline and timeout, which start after
  /// that wait), the launch downloads are checked, so one the emulator wrote
  /// back isn't taken for a change made here and uploaded over the server's
  /// copy, and the provider's pre-launch sync runs. [systemFolder] is the
  /// game's system, when the game doesn't name it.
  ///
  /// Best effort: a failure or a timeout never blocks the launch, which waits
  /// [returnSyncWait] + [budget] at most.
  static Future<SyncResult> syncBeforeLaunch(
    GameModel game,
    ISyncProvider provider, {
    String? systemFolder,
    OpenGameGuard? guard,
    Duration returnSyncWait = const Duration(seconds: 5),
    Duration budget = const Duration(seconds: 8),
  }) async {
    final key = _key(game.romname, game.systemFolderName ?? systemFolder);
    final running = _inFlight[key];
    if (running != null) {
      await running.timeout(returnSyncWait, onTimeout: () {});
      if (_inFlight.containsKey(key)) {
        _log.w(
          'Pre-launch sync of ${game.romname} skipped: its return sync is '
          'still running; the game starts on its local save',
        );
        return SyncResult.ok(message: 'Skipped: return sync still running');
      }
    }
    final deadline = SyncDeadline(budget);
    Future<SyncResult> sync() async {
      await checkLaunchDownloads(guard: guard);
      return provider.syncGameSavesBeforeLaunch(game, deadline: deadline);
    }

    try {
      return await sync().timeout(
        budget,
        onTimeout: () => SyncResult.fail(SyncError.networkError),
      );
    } catch (_) {
      return SyncResult.fail(SyncError.unknown);
    }
  }

  /// NeoStation came back to the front: a moment later, once a session that
  /// was running has ended (its own sync covers its game), every game that
  /// may still be open gets [syncGame]. Repeated calls restart the wait.
  static void scheduleReturnSync({
    Duration delay = const Duration(seconds: 3),
  }) {
    _scheduled?.cancel();
    _scheduled = Timer(delay, () {
      _scheduled = null;
      unawaited(runReturnSync());
    });
  }

  /// The launch downloads are checked, then [syncGame] runs for every game
  /// that may still be open, one at a time, with the active provider, at
  /// most once per [returnSyncInterval] for each game. Nothing while a game
  /// is launching or running.
  @visibleForTesting
  static Future<void> runReturnSync({
    OpenGameGuard? guard,
    ISyncProvider? provider,
    Future<GameModel?> Function(OpenGameLaunch launch)? findGame,
    ISyncProvider? Function(String providerId)? providerFor,
  }) async {
    final openGames = guard ?? OpenGameGuard.instance;
    try {
      await openGames.load();
      if (GameSessionManager.isGameLaunchInProgress) return;
      await checkLaunchDownloads(guard: openGames, providerFor: providerFor);
      final sync = provider ?? SyncManager.instance.active;
      // Signed out or offline: nothing can go up, and a failed sync would
      // mark each game red.
      if (sync == null || !sync.isAuthenticated) return;
      for (final launch in openGames.launches) {
        // A launch started meanwhile has the game; its sync covers it.
        if (GameSessionManager.isGameLaunchInProgress) return;
        final last = _lastSynced[_key(launch.romname, launch.systemFolder)];
        if (last != null && now().difference(last) < returnSyncInterval) {
          continue;
        }
        final found = await (findGame ?? _gameFor)(launch);
        if (found == null) continue;
        final game = gameForLaunch(found, launch);
        // Asked again: finding the game took a moment.
        if (GameSessionManager.isGameLaunchInProgress) return;
        await syncGame(game, sync, guard: openGames);
      }
    } catch (e) {
      _log.e('Return sync failed: $e');
    }
  }

  /// The library's game [launch] launched, named as the game lists name it:
  /// its indexed file name, extension included (found by the launch's ROM
  /// path; [GameModel.fromDatabaseModel] strips the extension, and a launch
  /// from Last Played or search names the game without it).
  static Future<GameModel?> _gameFor(OpenGameLaunch launch) async {
    final folder = launch.systemFolder;
    if (folder == null) return null;
    final system = await SystemRepository.getSystemByFolderName(folder);
    final systemId = system?.id;
    if (systemId == null) return null;
    final romPath = launch.romPath;
    final indexed = romPath == null
        ? null
        : await GameRepository.indexedFilename(systemId, romPath);
    final row =
        (indexed == null
            ? null
            : await GameRepository.getSingleGame(systemId, indexed)) ??
        await GameRepository.getSingleGame(systemId, launch.romname);
    if (row == null) return null;
    final game = GameModel.fromDatabaseModel(row);
    return indexed == null ? game : game.copyWith(romname: indexed);
  }

  /// [game], found for [launch], named in the game lists' form: with its
  /// extension, the launch's name when [game]'s has none and is the same ROM
  /// ([romStem]), so the guard and the providers' per-game keys match the
  /// game lists'. Its system folder is filled in from the launch when it has
  /// none.
  @visibleForTesting
  static GameModel gameForLaunch(GameModel game, OpenGameLaunch launch) {
    final hasExtension = romStem(game.romname) != game.romname;
    final launchName =
        romStem(launch.romname) == romStem(game.romname) &&
        romStem(launch.romname) != launch.romname;
    return game.copyWith(
      romname: !hasExtension && launchName ? launch.romname : game.romname,
      systemFolderName: game.systemFolderName ?? launch.systemFolder,
    );
  }

  static Future<String?> _md5Of(String path) async {
    try {
      final file = File(path);
      if (!await file.exists()) return null;
      return (await md5.bind(file.openRead()).first).toString();
    } catch (e) {
      _log.w('Could not hash $path: $e');
      return null;
    }
  }
}
