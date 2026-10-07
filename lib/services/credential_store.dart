import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'config_service.dart';
import 'credential_backend.dart';
import 'credential_file_store.dart';
import 'logger_service.dart';

/// Where a credential actually ended up.
enum CredentialWriteOutcome {
  /// The platform keychain/keyring took it, as intended.
  secureStorage,

  /// The platform store refused it and the app's encrypted file took it.
  /// The credential still survives a restart; only the OS protection is lost.
  encryptedFile,

  /// Nothing could be persisted. The credential lives in this process only, so
  /// the current session works and the next launch starts signed out.
  sessionOnly,
}

/// Thrown when every backend failed to answer a read.
///
/// This is deliberately distinct from "nothing is stored": callers must not
/// treat an unreadable store as a signed-out user, or a transient failure
/// deletes a perfectly good account.
class CredentialStoreException implements Exception {
  CredentialStoreException(this.message);

  final String message;

  @override
  String toString() => 'CredentialStoreException: $message';
}

/// The single place the app keeps user credentials.
///
/// Every platform prefers its own secure storage. What differs is what happens
/// when that fails, which on Linux is routine rather than exceptional: SteamOS
/// has no Secret Service at all, so libsecret cannot store anything and both
/// the NeoSync token and the RetroAchievements key vanished on every restart
/// (issue #302). Desktop platforms therefore fall through to an encrypted file
/// in the user-data directory, and anything still unwritable after that is kept
/// in memory so at least the current session works.
///
/// Reads walk the same chain, which also retires the plaintext
/// SharedPreferences token that macOS builds have used since the Keychain was
/// unreliable for ad-hoc-signed builds: it is read once, rewritten to a real
/// store, and removed.
class CredentialStore {
  static final _log = LoggerService.instance;

  /// Do not let a transient Android Keystore error erase credentials. This can
  /// happen during cold boot on some launchers, and the default `resetOnError`
  /// behaviour turns a temporary read failure into a permanent logout.
  ///
  /// NeoStation's macOS builds are also distributed outside the App Store. The
  /// classic Keychain remains encrypted by macOS without requiring the
  /// restricted Keychain Sharing entitlement used by the data-protection
  /// Keychain, so ad-hoc-signed builds can persist credentials securely.
  static const FlutterSecureStorage _secureStorage = FlutterSecureStorage(
    aOptions: AndroidOptions(resetOnError: false, migrateWithBackup: true),
    mOptions: MacOsOptions(usesDataProtectionKeychain: false),
  );

  /// Credentials that could not be persisted at all, kept for this process so
  /// the session the user just signed into still works.
  static final Map<String, String> _session = <String, String>{};

  static CredentialBackend? _secureOverride;
  static CredentialBackend? _fileOverride;
  static bool _fileOverrideSet = false;
  static Future<CredentialBackend?>? _fileStore;

  static CredentialBackend get _secure =>
      _secureOverride ?? const _SecureStorageBackend(_secureStorage);

  /// Replaces the backends for tests. Passing null for [file] models a platform
  /// with no fallback store.
  @visibleForTesting
  static void debugUseBackends({
    CredentialBackend? secure,
    CredentialBackend? file,
  }) {
    _secureOverride = secure;
    _fileOverride = file;
    _fileOverrideSet = true;
    _fileStore = null;
    _session.clear();
  }

  /// Replaces only the keyring for tests, leaving the real encrypted-file
  /// fallback in the user-data folder.
  @visibleForTesting
  static void debugUseSecureBackend(CredentialBackend secure) {
    debugReset();
    _secureOverride = secure;
  }

  @visibleForTesting
  static void debugReset() {
    _secureOverride = null;
    _fileOverride = null;
    _fileOverrideSet = false;
    _fileStore = null;
    _session.clear();
  }

  /// Returns the stored credential, or null when nothing is stored.
  ///
  /// Throws [CredentialStoreException] when a store existed but could not be
  /// read, so callers can preserve state instead of signing the user out.
  static Future<String?> read(String key) async {
    // The session copy only exists when persisting failed, which makes it the
    // freshest value by definition.
    final session = _session[key];
    if (session != null) return session;

    var secureFailed = false;
    var fallbackFailed = false;

    try {
      final value = await _secure.read(key);
      if (value != null && value.isNotEmpty) return value;
    } catch (e) {
      secureFailed = true;
      _log.w('CredentialStore: secure storage unreadable for "$key": $e');
    }

    final file = await _fileBackend();
    if (file != null) {
      try {
        final value = await file.read(key);
        if (value != null && value.isNotEmpty) return value;
      } catch (e) {
        fallbackFailed = true;
        _log.w('CredentialStore: credential file unreadable for "$key": $e');
      }
    }

    try {
      final legacy = await _readLegacyPreference(key);
      if (legacy != null) {
        _log.i('CredentialStore: migrating "$key" out of shared preferences');
        await write(key, legacy);
        return legacy;
      }
    } catch (e) {
      fallbackFailed = true;
      _log.w('CredentialStore: legacy preferences unreadable for "$key": $e');
    }

    // A broken keyring is the normal state on SteamOS, not a transient fault,
    // so a healthy fallback store that simply holds nothing is the answer:
    // reporting "unreadable" there would have every launch retry an auto-login
    // that can never succeed. Where there is no fallback (mobile), a failed
    // secure read still means "could not look", which is what stops a cold-boot
    // keystore hiccup being mistaken for a signed-out user.
    if (fallbackFailed || (secureFailed && file == null)) {
      throw CredentialStoreException('No credential store could be read');
    }
    return null;
  }

  /// Persists [value], reporting where it landed so the caller can warn the
  /// user when the credential will not survive a restart.
  static Future<CredentialWriteOutcome> write(String key, String value) async {
    _session.remove(key);

    try {
      await _secure.write(key, value);
      await _clearFile(key);
      await _clearLegacyPreference(key);
      return CredentialWriteOutcome.secureStorage;
    } catch (e) {
      _log.w('CredentialStore: secure storage rejected "$key": $e');
    }

    final file = await _fileBackend();
    if (file != null) {
      try {
        await file.write(key, value);
        await _clearLegacyPreference(key);
        _log.i('CredentialStore: stored "$key" in the encrypted fallback file');
        return CredentialWriteOutcome.encryptedFile;
      } catch (e) {
        _log.e('CredentialStore: credential file rejected "$key": $e');
      }
    }

    _session[key] = value;
    _log.e('CredentialStore: "$key" could not be persisted; session only');
    return CredentialWriteOutcome.sessionOnly;
  }

  /// Removes the credential from every store. Best effort by design: a store
  /// that cannot be reached now must not block clearing the others.
  static Future<void> delete(String key) async {
    _session.remove(key);

    try {
      await _secure.delete(key);
    } catch (e) {
      _log.w('CredentialStore: could not clear "$key" from secure storage: $e');
    }

    await _clearFile(key);
    await _clearLegacyPreference(key);
  }

  static Future<void> _clearFile(String key) async {
    final file = await _fileBackend();
    if (file == null) return;
    try {
      await file.delete(key);
    } catch (e) {
      _log.w('CredentialStore: could not clear "$key" from the file store: $e');
    }
  }

  /// Forgets the encrypted file store's folder, so the next use re-derives it
  /// from the current user-data path.
  ///
  /// The store is resolved on first use, at app start, so after the user-data
  /// location changes without a restart (the setup wizard) credentials would
  /// otherwise keep going to the folder the session started in, and the next
  /// launch would not find them.
  static void resetFileStore() {
    _fileStore = null;
  }

  /// The encrypted file store, or null on platforms that do not use one.
  ///
  /// Mobile is excluded on purpose: its keystore is reliable, and on Android the
  /// user-data directory can live on shared external storage, which is no place
  /// for a token file.
  static Future<CredentialBackend?> _fileBackend() {
    if (_fileOverrideSet) {
      return Future<CredentialBackend?>.value(_fileOverride);
    }
    if (!Platform.isLinux && !Platform.isMacOS && !Platform.isWindows) {
      return Future<CredentialBackend?>.value();
    }
    return _fileStore ??= _createFileStore();
  }

  static Future<CredentialBackend?> _createFileStore() async {
    try {
      return CredentialFileStore(await ConfigService.getUserDataPath());
    } catch (e) {
      _log.e('CredentialStore: no user-data path for the file store: $e');
      // Do not cache the failure: the Android-style storage wait can resolve
      // later, and a null here would otherwise stick for the whole session.
      _fileStore = null;
      return null;
    }
  }

  /// Reads the plaintext SharedPreferences copy older builds wrote on macOS.
  static Future<String?> _readLegacyPreference(String key) async {
    final prefs = await SharedPreferences.getInstance();
    final value = prefs.getString(key);
    return (value != null && value.isNotEmpty) ? value : null;
  }

  static Future<void> _clearLegacyPreference(String key) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (prefs.containsKey(key)) {
        await prefs.remove(key);
      }
    } catch (e) {
      _log.w('CredentialStore: could not clear legacy preference "$key": $e');
    }
  }
}

class _SecureStorageBackend implements CredentialBackend {
  const _SecureStorageBackend(this._storage);

  final FlutterSecureStorage _storage;

  @override
  Future<String?> read(String key) => _storage.read(key: key);

  @override
  Future<void> write(String key, String value) =>
      _storage.write(key: key, value: value);

  @override
  Future<void> delete(String key) => _storage.delete(key: key);
}
