/// Contract that every sync provider must satisfy.
///
/// ## Adding a community provider
///
/// 1. Create `lib/sync/providers/my_provider.dart` with a class that
///    implements [ISyncProvider].
/// 2. Register it in `main.dart` before the widget tree starts:
///    ```dart
///    SyncManager.instance.register(MyProvider());
///    ```
/// 3. Done — no changes to core app logic required.
library;

import 'dart:io';

import 'package:neostation/models/game_model.dart';
import 'package:neostation/models/neo_sync_models.dart';
import 'package:neostation/models/sync_models.dart';

export 'package:neostation/models/sync_models.dart';

abstract class ISyncProvider {
  // ── Identity ───────────────────────────────────────────────────────────────

  /// Short unique key used in config storage (e.g. "neosync", "gdrive").
  /// Must be stable — changing it loses the user's persisted preference.
  String get providerId;

  /// Human-readable metadata displayed in the provider picker UI.
  SyncProviderMeta get meta;

  // ── State ──────────────────────────────────────────────────────────────────

  SyncProviderStatus get status;

  bool get isAuthenticated;

  /// The provider's own connection or sync error; null when there is none.
  ///
  /// Unrelated calls such as listing or browsing must not set it: a game's sync
  /// status mark shows it whatever that game's own state.
  String? get lastError;

  // ── Lifecycle ──────────────────────────────────────────────────────────────

  /// Called once at startup. Restore persisted tokens and validate the session.
  Future<void> initialize();

  /// Release resources (HTTP clients, listeners, etc.).
  void dispose();

  // ── Authentication ─────────────────────────────────────────────────────────

  /// Begin the auth flow appropriate for this provider.
  ///
  /// - OAuth providers open a browser / WebView.
  /// - API-key providers validate the stored key against the remote.
  /// - Local providers verify the target path exists.
  Future<SyncResult> login();

  /// Clear credentials and end the session.
  ///
  /// **Signing a provider out does not release save sync.** A provider cannot
  /// do that itself: handing ownership back means `SyncManager.setActive`,
  /// which needs a `persist` callback that lives at the config layer. The
  /// caller must therefore pair a sign-out with
  /// `SyncManager.instance.releaseIfActive(providerId, persist: …)`, or the
  /// signed-out provider keeps owning save sync and every save hook fails
  /// silently while the other providers sit idle.
  ///
  /// Both RomM disconnect paths do this today; this method has no callers at
  /// all, so nothing currently depends on the pairing being remembered.
  Future<void> logout();

  // ── Core Sync Operations ───────────────────────────────────────────────────

  /// Upload a single save [file] for [gameId].
  Future<SyncResult> uploadSave(
    String gameId,
    File file, {
    String? customFileName,
  });

  /// Download the save identified by [fileId] for [gameId].
  /// On success, [SyncResult.data] contains the local [File].
  Future<SyncResult> downloadSave(String gameId, String fileId);

  /// List available saves. Pass [gameId] to filter to a single game.
  Future<List<SyncFile>> listSaves({String? gameId});

  /// Run a full bidirectional sync (upload new local files, download newer
  /// remote files). Implementations may show conflict dialogs here.
  Future<SyncResult> fullSync();

  // ── Game-specific sync operations ─────────────────────────────────────────

  /// Detects local and remote save files for a specific game and updates
  /// the internal sync state. Returns a [SyncResult] indicating success.
  Future<SyncResult> detectGameSaveFiles(GameModel game) async =>
      SyncResult.fail(
        SyncError.unknown,
        message: 'detectGameSaveFiles not supported by $providerId',
      );

  /// Returns the current sync state for [gameId], or null if not tracked.
  GameSyncState? getGameSyncState(String gameId) => null;

  /// Performs pre-launch synchronization (e.g. download cloud saves before
  /// starting the game).
  ///
  /// [deadline] cooperatively bounds the work: the launch caller also applies a
  /// hard [Future.timeout], but that cannot cancel an in-flight download, so
  /// implementations must check [SyncDeadline.isExpired] after each network
  /// fetch and abandon the write (without touching save files or sync state)
  /// once it expires. See [SyncDeadline].
  Future<SyncResult> syncGameSavesBeforeLaunch(
    GameModel game, {
    SyncDeadline? deadline,
  }) async => SyncResult.fail(
    SyncError.unknown,
    message: 'syncGameSavesBeforeLaunch not supported by $providerId',
  );

  /// Performs post-close synchronization (e.g. upload modified saves after
  /// the game exits).
  Future<SyncResult> syncGameSavesAfterClose(GameModel game) async =>
      SyncResult.fail(
        SyncError.unknown,
        message: 'syncGameSavesAfterClose not supported by $providerId',
      );

  /// Updates whether cloud sync is enabled for a specific game.
  Future<void> updateGameCloudSyncEnabled(String gameId, bool enabled) async {}

  // ── Optional Capabilities (override as needed) ─────────────────────────────

  /// Storage quota info. Return null if the provider has no quota concept.
  Future<SyncQuota?> getQuota() async => null;

  /// Delete a remote save by [fileId].
  Future<SyncResult> deleteRemote(String fileId) async => SyncResult.fail(
    SyncError.unknown,
    message: 'deleteRemote not supported by $providerId',
  );
}
