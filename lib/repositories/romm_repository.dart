import 'dart:convert';

import '../data/datasources/sqlite_service.dart';
import '../services/credential_store.dart';

import 'package:neostation/services/logger_service.dart';

/// Repository for RomM server credentials and tokens (single-row config).
///
/// Per the architecture rules, this is the only layer that touches
/// [SqliteService] for RomM data access.
///
/// The password and the API key live in [CredentialStore], not in the database.
/// They used to be base64-encoded in `user_romm_config`, which is encoding
/// rather than encryption: anyone who opened `data.sqlite` read them straight
/// out, and a RomM Client API Token never expires and has no refresh flow. The
/// columns are still read as a fallback and are emptied as each secret moves,
/// so a database written by an older build (or by the local dev seeder, which
/// writes the table directly) keeps working.
///
/// The access and refresh tokens deliberately stay in the database. They are
/// short-lived, rewritten constantly by the refresh path, and a lost one costs
/// nothing because the password grant just issues another.
class RommRepository {
  static final _log = LoggerService.instance;

  /// Credential store keys. Stable: changing one strands existing logins.
  static const String _passwordKey = 'romm_password';
  static const String _apiKeyKey = 'romm_api_key';

  /// Persists the server URL and credentials. Tokens are cleared whenever the
  /// credentials change so a fresh authentication is forced.
  ///
  /// The two authentication modes are mutually exclusive: pass either
  /// [username]/[password] or [apiKey]. Whichever is left empty is deleted from
  /// the credential store and written to the database as empty, so switching a
  /// connection from one mode to the other never leaves the previous mode's
  /// secret behind to be picked up on the next launch.
  static Future<bool> saveConfig({
    required String serverUrl,
    String username = '',
    String password = '',
    String apiKey = '',
  }) async {
    try {
      final db = await SqliteService.getDatabase();

      // Store each secret first, so the column only ever holds what the
      // credential store could not keep.
      final passwordColumn = await _storeSecret(_passwordKey, password);
      final apiKeyColumn = await _storeSecret(_apiKeyKey, apiKey);

      await db.insert('user_romm_config', {
        'id': 1,
        'server_url': serverUrl,
        'username': username,
        'password': passwordColumn,
        'api_key': apiKeyColumn,
        'access_token': null,
        'refresh_token': null,
        'token_expires': null,
        'updated_at': DateTime.now().toIso8601String(),
      }, conflictAlgorithm: ConflictAlgorithm.replace);

      return true;
    } catch (e) {
      _log.e('Error saving RomM config: $e');
      return false;
    }
  }

  /// Persists [value] under [key] and returns what the database column should
  /// hold: empty once the credential store has it, or the base64 fallback when
  /// nothing could be persisted.
  ///
  /// An empty [value] is deleted rather than written as empty. The two
  /// authentication modes are mutually exclusive, and a stale key left in one
  /// backend would otherwise be read back as a live credential for a mode the
  /// user has switched away from.
  static Future<String> _storeSecret(String key, String value) async {
    if (value.isEmpty) {
      await CredentialStore.delete(key);
      return '';
    }

    final outcome = await CredentialStore.write(key, value);
    if (outcome == CredentialWriteOutcome.sessionOnly) {
      // Nothing could store it. Keeping the old base64 column is worse than
      // nothing for secrecy but better for the user: it is the only copy that
      // survives a restart, and it is what this build did before.
      _log.w('RomM: "$key" could not be persisted; keeping it in the database');
      return _encodeSecret(value);
    }
    return '';
  }

  /// Returns the stored config with the secrets decoded, or null if none.
  ///
  /// Keys: `server_url`, `username`, `password`, `api_key`, `access_token`,
  /// `refresh_token`, `token_expires` (int millis since epoch, nullable),
  /// `last_verified`. A non-empty `api_key` means the connection authenticates
  /// with a Client API Token rather than the password grant.
  static Future<Map<String, dynamic>?> getConfig() async {
    try {
      final db = await SqliteService.getDatabase();
      final result = await db.query('user_romm_config');
      if (result.isEmpty) return null;

      final row = result.first;
      final serverUrl = row['server_url']?.toString();
      if (serverUrl == null || serverUrl.isEmpty) return null;

      return {
        'server_url': serverUrl,
        'username': row['username']?.toString() ?? '',
        'password': await _readSecret(
          _passwordKey,
          row['password'],
          'password',
        ),
        'api_key': await _readSecret(_apiKeyKey, row['api_key'], 'api_key'),
        'access_token': row['access_token']?.toString(),
        'refresh_token': row['refresh_token']?.toString(),
        'token_expires': int.tryParse(row['token_expires']?.toString() ?? ''),
        'last_verified': row['last_verified']?.toString(),
      };
    } catch (e) {
      _log.e('Error getting RomM config: $e');
      return null;
    }
  }

  /// Returns the secret for [key], preferring [CredentialStore] and falling
  /// back to the legacy base64 [column].
  ///
  /// A value found in the column is written through to the store and
  /// [columnName] is emptied, but only once the store confirms a persistent
  /// write. Blanking after a session-only write would disconnect a working
  /// server on the next launch, which is worse than the leak being fixed.
  ///
  /// Any read failure is treated as "could not look", never as "nothing
  /// stored": the column is used as-is and left untouched, because dropping a
  /// live connection over a transient keychain error is the one outcome worth
  /// avoiding here.
  static Future<String> _readSecret(
    String key,
    Object? column,
    String columnName,
  ) async {
    try {
      final stored = await CredentialStore.read(key);
      if (stored != null && stored.isNotEmpty) return stored;
    } catch (e) {
      _log.w('RomM: credential store unreadable for "$key": $e');
      return _decodeSecret(column);
    }

    final legacy = _decodeSecret(column);
    if (legacy.isEmpty) return '';

    final outcome = await CredentialStore.write(key, legacy);
    if (outcome == CredentialWriteOutcome.sessionOnly) {
      _log.w('RomM: "$key" could not be persisted; leaving it in the database');
      return legacy;
    }

    await _blankColumn(columnName);
    _log.i('RomM: moved "$key" out of the database into the credential store');
    return legacy;
  }

  /// Empties a legacy secret column once the value lives in the credential
  /// store. Best effort: failing to clear it only delays the cleanup to the
  /// next read, so it must never fail the surrounding config read.
  static Future<void> _blankColumn(String columnName) async {
    try {
      final db = await SqliteService.getDatabase();
      await db.update(
        'user_romm_config',
        {columnName: ''},
        where: 'id = ?',
        whereArgs: [1],
      );
    } catch (e) {
      _log.e('Error clearing the RomM $columnName column: $e');
    }
  }

  /// Base64-encodes a secret for storage; an empty secret stays empty so the
  /// "is this mode in use?" check is a plain `isNotEmpty` on the way back out.
  static String _encodeSecret(String value) =>
      value.isEmpty ? '' : base64Encode(utf8.encode(value));

  /// Inverse of [_encodeSecret], tolerating a null/absent column and any value
  /// that isn't valid base64 (both read back as "not set").
  static String _decodeSecret(Object? stored) {
    final encoded = stored?.toString();
    if (encoded == null || encoded.isEmpty) return '';
    try {
      return utf8.decode(base64Decode(encoded));
    } catch (_) {
      return '';
    }
  }

  /// Updates the cached JWT tokens after a successful authentication.
  ///
  /// [tokenExpires] is millis-since-epoch when the access token expires.
  static Future<bool> saveTokens({
    required String accessToken,
    String? refreshToken,
    int? tokenExpires,
  }) async {
    try {
      final db = await SqliteService.getDatabase();
      await db.update(
        'user_romm_config',
        {
          'access_token': accessToken,
          'refresh_token': ?refreshToken,
          'token_expires': tokenExpires,
          'last_verified': DateTime.now().toIso8601String(),
          'updated_at': DateTime.now().toIso8601String(),
        },
        where: 'id = ?',
        whereArgs: [1],
      );
      return true;
    } catch (e) {
      _log.e('Error saving RomM tokens: $e');
      return false;
    }
  }

  /// Removes all stored RomM configuration (used on disconnect).
  ///
  /// The credential store is cleared first and unconditionally: a row deleted
  /// from the database while the secrets survived in the keychain would leave
  /// a disconnected server's credentials behind with nothing left pointing at
  /// them.
  static Future<bool> clearConfig() async {
    await CredentialStore.delete(_passwordKey);
    await CredentialStore.delete(_apiKeyKey);

    try {
      final db = await SqliteService.getDatabase();
      await db.delete('user_romm_config');
      return true;
    } catch (e) {
      _log.e('Error clearing RomM config: $e');
      return false;
    }
  }
}
