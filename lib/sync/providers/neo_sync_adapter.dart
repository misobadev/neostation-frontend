/// Adapts the existing [NeoSyncProvider] to the [ISyncProvider] interface
/// without rewriting its complex sync and quota logic.
library;

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:neostation/models/game_model.dart';
import 'package:neostation/models/neo_sync_models.dart';
import 'package:neostation/providers/neo_sync_provider.dart';

import '../i_sync_provider.dart';

/// Official & Recommended — maintained by NeoGameLab.
///
/// Maps [NeoSyncProvider]'s rich sync state to the minimal [ISyncProvider]
/// contract so [SyncManager] can treat it like any other provider.
///
/// Auth is delegated to [AuthService] (email/password login screen) because
/// NeoSync uses a custom auth microservice, not an OAuth flow that fits neatly
/// into [ISyncProvider.login]. The [login] method here serves as a guard that
/// surfaces the auth requirement to the [SyncManager] caller.
class NeoSyncAdapter extends ChangeNotifier implements ISyncProvider {
  static const String kProviderId = 'neosync';

  final NeoSyncProvider _provider;

  NeoSyncAdapter(this._provider) {
    _provider.addListener(notifyListeners);
  }

  // ── Identity ───────────────────────────────────────────────────────────────

  @override
  String get providerId => kProviderId;

  @override
  SyncProviderMeta get meta => const SyncProviderMeta(
    id: kProviderId,
    name: 'NeoSync',
    description:
        'Official NeoStation cloud sync. Includes auto '
        'resolution, per-game tracking, and quota management.',
    author: 'NeoGameLab',
    isOfficial: true,
    isRecommended: true,
    iconAssetPath: 'assets/icons/neosync.png',
  );

  // ── State ──────────────────────────────────────────────────────────────────

  @override
  SyncProviderStatus get status {
    if (_provider.isSyncing) return SyncProviderStatus.syncing;
    if (_provider.error != null) return SyncProviderStatus.error;
    if (_provider.isNeoSyncAuthenticated) return SyncProviderStatus.connected;
    return SyncProviderStatus.disconnected;
  }

  @override
  bool get isAuthenticated => _provider.isNeoSyncAuthenticated;

  @override
  String? get lastError => _provider.error;

  // ── Lifecycle ──────────────────────────────────────────────────────────────

  @override
  Future<void> initialize() async {
    // NeoSyncProvider initialises via AuthService.initialize() in main.dart.
  }

  @override
  void dispose() {
    _provider.removeListener(notifyListeners);
    super.dispose();
  }

  // ── Authentication ─────────────────────────────────────────────────────────

  @override
  Future<SyncResult> login() async {
    // NeoSync auth happens through the dedicated login screen, not here.
    // This method acts as an authentication guard for SyncManager callers.
    if (_provider.isNeoSyncAuthenticated) return SyncResult.ok();
    return SyncResult.fail(
      SyncError.authRequired,
      message: 'Open Settings → NeoSync to sign in',
    );
  }

  @override
  Future<void> logout() async {
    // Delegated to AuthService via the existing logout flow in the UI.
  }

  // ── Core Sync Operations ───────────────────────────────────────────────────

  @override
  Future<SyncResult> uploadSave(
    String gameId,
    File file, {
    String? customFileName,
  }) async {
    try {
      await _provider.autoSyncUploads();
      return SyncResult.ok();
    } catch (e) {
      return SyncResult.fail(SyncError.unknown, message: e.toString());
    }
  }

  @override
  Future<SyncResult> downloadSave(String gameId, String fileId) async {
    try {
      await _provider.autoSyncDownloads();
      return SyncResult.ok();
    } catch (e) {
      return SyncResult.fail(SyncError.unknown, message: e.toString());
    }
  }

  @override
  Future<List<SyncFile>> listSaves({String? gameId}) async {
    await _provider.loadFiles();
    return _provider.files
        .where((f) => gameId == null || f.gameName == gameId)
        .map(
          (f) => SyncFile(
            id: f.id,
            fileName: f.fileName,
            gameName: f.gameName,
            fileSize: f.fileSize,
            uploadedAt: f.uploadedAt,
            modifiedAt: f.fileModifiedAt,
            checksum: f.checksum,
          ),
        )
        .toList();
  }

  @override
  Future<SyncResult> fullSync() async {
    try {
      await _provider.syncWithConflictResolution();
      return SyncResult.ok(
        message:
            '${_provider.uploadedFiles} uploaded, '
            '${_provider.downloadedFiles} downloaded',
      );
    } catch (e) {
      return SyncResult.fail(SyncError.unknown, message: e.toString());
    }
  }

  // ── Game-specific sync operations ─────────────────────────────────────────

  @override
  Future<SyncResult> detectGameSaveFiles(GameModel game) async {
    try {
      await _provider.detectGameSaveFiles(game);
      return SyncResult.ok();
    } catch (e) {
      return SyncResult.fail(SyncError.unknown, message: e.toString());
    }
  }

  @override
  GameSyncState? getGameSyncState(String gameId) =>
      _provider.getGameSyncState(gameId);

  @override
  Future<SyncResult> syncGameSavesBeforeLaunch(
    GameModel game, {
    SyncDeadline? deadline,
  }) async {
    try {
      await _provider.syncGameSavesBeforeLaunch(game, deadline: deadline);
      return SyncResult.ok();
    } catch (e) {
      return SyncResult.fail(SyncError.unknown, message: e.toString());
    }
  }

  @override
  Future<SyncResult> syncGameSavesAfterClose(GameModel game) async {
    try {
      await _provider.syncGameSavesAfterClose(game);
      return SyncResult.ok();
    } catch (e) {
      return SyncResult.fail(SyncError.unknown, message: e.toString());
    }
  }

  @override
  Future<void> updateGameCloudSyncEnabled(String gameId, bool enabled) async {
    await _provider.updateGameCloudSyncEnabled(gameId, enabled);
  }

  // ── Optional Capabilities ──────────────────────────────────────────────────

  @override
  Future<SyncQuota?> getQuota() async {
    await _provider.loadQuota();
    final q = _provider.quota;
    if (q == null) return null;
    return SyncQuota(usedBytes: q.usedQuota, totalBytes: q.totalQuota);
  }

  @override
  Future<SyncResult> deleteRemote(String fileId) async {
    try {
      final deleted = await _provider.deleteOnlineFile(fileId);
      return deleted
          ? SyncResult.ok()
          : SyncResult.fail(SyncError.unknown, message: 'Delete failed');
    } catch (e) {
      return SyncResult.fail(SyncError.unknown, message: e.toString());
    }
  }
}
