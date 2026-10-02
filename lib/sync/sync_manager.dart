/// Central registry for sync providers.
///
/// Providers are registered at startup and persist their selection to the
/// app config via the [persist] callback supplied to [setActive].
///
/// ## Community contribution flow
///
/// ```
/// // 1. In lib/sync/providers/my_provider.dart:
/// class MyProvider implements ISyncProvider { ... }
///
/// // 2. In main.dart, before runApp():
/// SyncManager.instance.register(MyProvider());
/// SyncManager.instance.restoreActive(savedProviderId);
/// ```
library;

import 'package:flutter/foundation.dart';
import 'i_sync_provider.dart';
import 'providers/neo_sync_adapter.dart';

class SyncManager extends ChangeNotifier {
  SyncManager._();

  static final SyncManager instance = SyncManager._();

  final Map<String, ISyncProvider> _registry = {};
  String _activeProviderId = NeoSyncAdapter.kProviderId;

  // ── Registration ───────────────────────────────────────────────────────────

  /// Add [provider] to the registry.
  ///
  /// Throws if a provider with the same [ISyncProvider.providerId] is already
  /// registered — each id must be globally unique.
  void register(ISyncProvider provider) {
    assert(
      !_registry.containsKey(provider.providerId),
      'SyncManager: provider "${provider.providerId}" is already registered.',
    );
    _registry[provider.providerId] = provider;
    if (provider is ChangeNotifier) {
      (provider as ChangeNotifier).addListener(notifyListeners);
    }
  }

  void unregister(String providerId) {
    final provider = _registry[providerId];
    if (provider is ChangeNotifier) {
      (provider as ChangeNotifier).removeListener(notifyListeners);
    }
    _registry.remove(providerId);
    if (_activeProviderId == providerId) {
      _activeProviderId = NeoSyncAdapter.kProviderId;
      notifyListeners();
    }
  }

  // ── Active Provider ────────────────────────────────────────────────────────

  /// Currently selected provider, or null if it is not yet registered.
  ISyncProvider? get active => _registry[_activeProviderId];

  /// The registered provider with [providerId], active or not, or null when
  /// none is registered under that id.
  ///
  /// For callers that have to reach a specific provider's own state — the
  /// RomM link paths invalidate the RomM provider's cached game status, which
  /// exists whether or not RomM is the one doing the saves.
  ISyncProvider? provider(String providerId) => _registry[providerId];

  String get activeProviderId => _activeProviderId;

  /// Switch to [providerId] and persist the choice via [persist].
  ///
  /// The [persist] callback should write the id to SQLite config, e.g.:
  /// ```dart
  /// persist: (id) => sqliteConfigProvider.updateActiveSyncProvider(id),
  /// ```
  /// Returns false if [providerId] is not registered.
  Future<bool> setActive(
    String providerId, {
    required Future<void> Function(String) persist,
  }) async {
    if (!_registry.containsKey(providerId)) return false;
    _activeProviderId = providerId;
    await persist(providerId);
    notifyListeners();
    return true;
  }

  /// Hands save sync back to NeoSync if [providerId] currently owns it.
  ///
  /// Called when a provider is deliberately signed out. Leaving a disconnected
  /// provider active silently stops **all** save sync — it errors out on every
  /// hook while NeoSync sits idle — and nothing in the UI would attribute that
  /// to the disconnect that caused it.
  ///
  /// Returns true when ownership actually moved. A provider that did not own
  /// save sync is a no-op, so signing out of RomM never disturbs a NeoSync
  /// user's setting, and [persist] is not called.
  Future<bool> releaseIfActive(
    String providerId, {
    required Future<void> Function(String) persist,
  }) async {
    if (_activeProviderId != providerId) return false;
    return setActive(NeoSyncAdapter.kProviderId, persist: persist);
  }

  /// Restore the user's previously chosen provider from config on startup.
  /// Falls back to NeoSync if [savedProviderId] is null or not registered.
  void restoreActive(String? savedProviderId) {
    if (savedProviderId != null && _registry.containsKey(savedProviderId)) {
      _activeProviderId = savedProviderId;
    }
  }

  // ── Discovery ──────────────────────────────────────────────────────────────

  List<SyncProviderMeta> get availableProviders =>
      _registry.values.map((p) => p.meta).toList();

  bool isRegistered(String providerId) => _registry.containsKey(providerId);

  ISyncProvider? operator [](String providerId) => _registry[providerId];
}
