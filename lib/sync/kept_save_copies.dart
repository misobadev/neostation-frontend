import 'package:neostation/models/game_model.dart';
import 'package:neostation/models/neo_sync_models.dart';
import 'package:neostation/providers/neo_sync_provider.dart';
import 'package:neostation/services/game/game_session_manager.dart';
import 'package:neostation/utils/kept_save_copy.dart';

import 'providers/neo_sync_adapter.dart';
import 'providers/romm_provider.dart';
import 'sync_manager.dart';

export 'package:neostation/utils/kept_save_copy.dart';

/// The kept copies the provider [providerId] writes, as the list shows them:
/// only the active provider's, so a switch from RomM to NeoSync (or back)
/// doesn't mix in the other's, nor tidy them away. A save replaced by a
/// restore is listed under either, since the user made it.
Set<KeptCopySource> keptCopySourcesFor(String providerId) =>
    switch (providerId) {
      NeoSyncAdapter.kProviderId => neoSyncKeptCopySources,
      RomMSyncProvider.kProviderId => rommKeptCopySources,
      _ => const {},
    };

/// Why a kept copy can't be restored right now.
enum KeptCopyRefusal {
  /// A game is being launched or is running, and could write its save over
  /// the restored one.
  gameRunning,

  /// A save sync is under way and could upload or download the save while it
  /// is being replaced.
  syncing,
}

/// Thrown by [KeptSaveCopies.restore] when [reason] stops it.
class KeptCopyRefused implements Exception {
  const KeptCopyRefused(this.reason);

  final KeptCopyRefusal reason;

  @override
  String toString() => 'KeptCopyRefused($reason)';
}

/// Lists, restores and deletes the kept copies of saves for the active save
/// provider (NeoSync or RomM).
///
/// The copies sit beside the saves, so they are found where NeoSync finds a
/// game's saves (RomM uses the same lookup), including a save that is gone
/// but has copies, or, for the whole list, in every folder NeoSync looks in.
class KeptSaveCopies {
  KeptSaveCopies(
    NeoSyncProvider neoSync, {
    String Function()? activeProviderId,
    Future<List<String>> Function(GameModel game)? locateSaves,
    Future<List<String>> Function()? saveFolders,
    bool Function()? gameRunning,
    bool Function(String providerId, GameModel? game)? syncing,
  }) : _activeProviderId =
           activeProviderId ?? (() => SyncManager.instance.activeProviderId),
       _locateSaves =
           locateSaves ??
           ((game) async => [
             for (final save in await neoSync.locateKeptCopySaves(game))
               save.filePath,
           ]),
       _saveFolders = saveFolders ?? neoSync.keptCopyFolders,
       _gameRunning =
           gameRunning ?? (() => GameSessionManager.isGameLaunchInProgress),
       _syncing =
           syncing ?? ((id, game) => _providerSyncing(neoSync, id, game));

  final String Function() _activeProviderId;
  final Future<List<String>> Function(GameModel game) _locateSaves;
  final Future<List<String>> Function() _saveFolders;
  final bool Function() _gameRunning;
  final bool Function(String providerId, GameModel? game) _syncing;

  Set<KeptCopySource> get _sources => keptCopySourcesFor(_activeProviderId());

  /// [game]'s saves that have kept copies, with those copies.
  ///
  /// The copies are tidied first ([tidyKeptCopies]), so the Manage tab's
  /// count and the list agree, unless a game or a sync is under way
  /// ([whyNotNow]) and could be writing them. With [compareWithSave] false,
  /// the copies left are not compared with the save; see [groupKeptCopies].
  Future<List<KeptSaveGroup>> forGame(
    GameModel game, {
    bool compareWithSave = true,
  }) async {
    final sources = _sources;
    if (sources.isEmpty) return const [];
    final saves = await _locateSaves(game);
    if (whyNotNow(game) == null) {
      // A memory card is synced by every game of its system: any sync counts.
      final anySync = whyNotNow() != null;
      for (final save in saves) {
        if (anySync && isSharedMemoryCard(save)) continue;
        await tidyKeptCopies(save, sources: sources);
      }
    }
    return keptCopiesBeside(
      saves,
      sources: sources,
      compareWithSave: compareWithSave,
    );
  }

  /// Every save with kept copies, in every folder saves are synced from,
  /// including copies whose save is gone. Tidied first, as in [forGame].
  Future<List<KeptSaveGroup>> all() async {
    final sources = _sources;
    if (sources.isEmpty) return const [];
    final copyPaths = await listKeptCopyPaths(await _saveFolders());
    if (whyNotNow() == null) {
      final bySave = <String, List<String>>{};
      for (final copy in copyPaths) {
        final save = parseKeptCopyPath(copy)?.savePath;
        if (save != null) (bySave[save] ??= []).add(copy);
      }
      for (final MapEntry(key: save, value: copies) in bySave.entries) {
        await tidyKeptCopies(save, sources: sources, copyPaths: copies);
      }
    }
    // Copies the tidy removed are gone, so they aren't grouped.
    return groupKeptCopies(copyPaths, sources: sources);
  }

  /// Why restoring the copy at [copyPath] would be refused now, or null when
  /// it can go ahead.
  ///
  /// [game] narrows the sync check to that game where the provider tracks
  /// syncs per game; without it, any sync counts. A shared memory card is
  /// synced by every game of its system, so for one any sync counts too.
  KeptCopyRefusal? whyNotNow([GameModel? game, String? copyPath]) {
    if (_gameRunning()) return KeptCopyRefusal.gameRunning;
    final savePath = copyPath == null
        ? null
        : parseKeptCopyPath(copyPath)?.savePath;
    final syncsOf = savePath != null && isSharedMemoryCard(savePath)
        ? null
        : game;
    if (_syncing(_activeProviderId(), syncsOf)) return KeptCopyRefusal.syncing;
    return null;
  }

  /// Puts the copy at [copyPath] back as its save; see [restoreKeptCopy].
  /// Then the save's copies are tidied: the copy restored now holds the
  /// save's bytes, so it goes, and the copy of the save it replaced stays.
  ///
  /// Throws [KeptCopyRefused] when [whyNotNow] says no.
  Future<KeptCopyRestore> restore(String copyPath, {GameModel? game}) async {
    final refusal = whyNotNow(game, copyPath);
    if (refusal != null) throw KeptCopyRefused(refusal);
    final sources = _sources;
    final result = await restoreKeptCopy(copyPath);
    await tidyKeptCopies(
      result.savePath,
      sources: sources,
      justKept: {?result.replacedCopyPath},
    );
    return result;
  }

  /// Deletes the copy at [copyPath]; see [deleteKeptCopy].
  Future<void> delete(String copyPath) => deleteKeptCopy(copyPath);
}

bool _providerSyncing(
  NeoSyncProvider neoSync,
  String providerId,
  GameModel? game,
) {
  switch (providerId) {
    case NeoSyncAdapter.kProviderId:
      if (neoSync.isSyncing || neoSync.isAutoSyncing) return true;
      if (game == null) return neoSync.isAnyGameSyncing;
      return neoSync.getGameSyncState(game.romname)?.status ==
          GameSyncStatus.syncing;
    case RomMSyncProvider.kProviderId:
      final romm = SyncManager.instance.provider(RomMSyncProvider.kProviderId);
      return romm is RomMSyncProvider && romm.isSyncing;
    default:
      return false;
  }
}
