import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/neoassets_scrape_models.dart';
import '../services/credential_store.dart';
import '../services/logger_service.dart';

/// Persists the NeoAssets metadata account: the personal API key (in
/// [CredentialStore], like every other secret) or the choice to scrape as a
/// guest, and, in preferences, the last account snapshot and the user's
/// metadata language.
///
/// Kept apart from every other provider's credentials on purpose: the
/// providers share the scraped library, not their accounts.
class NeoAssetsAccountRepository {
  NeoAssetsAccountRepository._();

  static final _log = LoggerService.instance;

  /// Credential store key. Stable: changing it strands existing sign-ins.
  static const String _apiKeyKey = 'neoassets_scrape_api_key';
  static const String _accountPref = 'neoassets_scrape_account';
  static const String _languagePref = 'neoassets_scrape_language';
  static const String _guestPref = 'neoassets_scrape_guest';

  static String? _cachedKey;

  static Future<String?> getApiKey() async {
    if (_cachedKey != null) return _cachedKey;
    try {
      final key = await CredentialStore.read(_apiKeyKey);
      if (key != null && key.isNotEmpty) _cachedKey = key;
      return _cachedKey;
    } on CredentialStoreException catch (e) {
      // Unreadable is not signed out: report no key for now, keep the stored
      // one for the next read.
      _log.w('NeoAssets key unreadable: $e');
      return null;
    }
  }

  static Future<bool> hasApiKey() async => (await getApiKey()) != null;

  /// Whether the user chose to scrape as a guest, with no personal key.
  static Future<bool> isGuest() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_guestPref) ?? false;
  }

  /// A NeoAssets session of either kind: a personal key or a guest.
  static Future<bool> hasSession() async =>
      await isGuest() || await hasApiKey();

  /// Starts a guest session, dropping any personal key.
  static Future<void> saveGuest(NeoAssetsAccount account) async {
    await clear();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_guestPref, true);
    await saveAccount(account);
  }

  static Future<bool> saveApiKey(String key, NeoAssetsAccount account) async {
    try {
      await CredentialStore.write(_apiKeyKey, key);
      _cachedKey = key;
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_guestPref);
      await saveAccount(account);
      return true;
    } catch (e) {
      _log.e('Error saving NeoAssets key: $e');
      return false;
    }
  }

  static Future<void> saveAccount(NeoAssetsAccount account) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_accountPref, json.encode(account.toJson()));
  }

  static Future<NeoAssetsAccount?> getAccount() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_accountPref);
      if (raw == null) return null;
      return NeoAssetsAccount.fromJson(
        json.decode(raw) as Map<String, dynamic>,
      );
    } catch (_) {
      return null;
    }
  }

  static Future<void> clear() async {
    _cachedKey = null;
    try {
      await CredentialStore.delete(_apiKeyKey);
    } catch (e) {
      _log.w('Error deleting NeoAssets key: $e');
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_accountPref);
    await prefs.remove(_guestPref);
  }

  /// Language the game descriptions are shown in first. Defaults to English.
  static Future<String> getLanguage() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_languagePref) ?? 'en';
  }

  static Future<void> setLanguage(String code) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_languagePref, code);
  }
}
