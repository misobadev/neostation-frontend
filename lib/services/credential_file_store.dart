import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:path/path.dart' as path;
import 'package:pointycastle/export.dart';

import 'credential_backend.dart';
import 'logger_service.dart';

/// Encrypted, machine-bound credential file used when the platform's own
/// secure storage is unavailable.
///
/// SteamOS ships without a Secret Service: `org.freedesktop.secrets` is not
/// even D-Bus activatable, so libsecret cannot store anything and both the
/// NeoSync token and the RetroAchievements API key are lost on every restart
/// (issue #302). Installing gnome-keyring by hand is not a durable answer on an
/// immutable OS, so the app carries its own store for that case.
///
/// The security model, stated plainly: the key is derived from material that
/// lives on the same machine, so this protects a credential from being read out
/// of a backup, a synced folder, or a user-data directory copied to another
/// machine — not from someone who already has the user's account. That is still
/// strictly better than the plaintext SharedPreferences fallback the macOS
/// build has always used. SteamOS uses this store by default; other desktops
/// use it when the real keychain fails.
class CredentialFileStore implements CredentialBackend {
  CredentialFileStore(this.directory);

  /// Directory holding the credential file. This is the user-data directory, so
  /// credentials share the lifetime of the database that stores the matching
  /// usernames: wiping user data signs the user out instead of leaving a key
  /// behind for an account the database no longer knows about.
  final String directory;

  static final _log = LoggerService.instance;

  static const String _fileName = 'credentials.enc';
  static const String _deviceKeyFileName = 'credentials.key';
  static const int _formatVersion = 1;
  static const int _saltLength = 16;
  static const int _nonceLength = 12;
  static const int _macBits = 128;
  static const int _keyLength = 32;
  static const int _deviceKeyLength = 32;

  static final Uint8List _hkdfInfo = Uint8List.fromList(
    utf8.encode('neostation-credential-store-v1'),
  );

  final Random _random = Random.secure();

  File get _file => File(path.join(directory, _fileName));
  File get _deviceKeyFile => File(path.join(directory, _deviceKeyFileName));

  /// Returns the stored value for [key], or null when nothing is stored.
  ///
  /// Throws when the file cannot be read right now (an I/O error), so the
  /// caller can tell "no credential" from "could not look" and a transient
  /// failure is not treated as a sign-out. A file that can never be read again
  /// is set aside instead; see [_quarantine].
  @override
  Future<String?> read(String key) async {
    final entries = await _readAll();
    final value = entries[key];
    return (value is String && value.isNotEmpty) ? value : null;
  }

  @override
  Future<void> write(String key, String value) async {
    final entries = await _readAll();
    entries[key] = value;
    await _writeAll(entries);
  }

  @override
  Future<void> delete(String key) async {
    final entries = await _readAll();
    if (!entries.containsKey(key)) return;
    entries.remove(key);
    await _writeAll(entries);
  }

  Future<Map<String, dynamic>> _readAll() async {
    final file = _file;
    if (!await file.exists()) return <String, dynamic>{};

    // Bytes, not readAsString: invalid UTF-8 is a damaged file, and
    // readAsString would report it as an I/O error.
    final bytes = await file.readAsBytes();
    try {
      final envelope = jsonDecode(utf8.decode(bytes));
      if (envelope is! Map || envelope['v'] != _formatVersion) {
        throw const FormatException('Unrecognised credential file format');
      }

      final salt = base64Decode(envelope['salt'] as String);
      final nonce = base64Decode(envelope['nonce'] as String);
      final payload = base64Decode(envelope['data'] as String);

      final plaintext = _cipher(
        forEncryption: false,
        key: await _deriveKey(salt),
        nonce: nonce,
      ).process(payload);
      final decoded = jsonDecode(utf8.decode(plaintext));
      if (decoded is! Map) {
        throw const FormatException('Invalid credential payload');
      }
      return Map<String, dynamic>.from(decoded);
    } on FileSystemException {
      // The key file could not be read right now; that is not a verdict on
      // the credentials.
      rethrow;
    } catch (e) {
      // Damaged, tampered, written by a newer build, or encrypted with key
      // material that is gone (a reinstalled OS changes /etc/machine-id).
      // None of these become readable by retrying, and failing every read,
      // write and delete would leave the user unable to sign in again. Set
      // the file aside and carry on with an empty store.
      await _quarantine(e);
      return <String, dynamic>{};
    }
  }

  /// Moves the unreadable credential file, and its key, to timestamped
  /// `.bak` names. Nothing is deleted: a file from a newer build is readable
  /// again after an upgrade, and the user can restore it by hand.
  Future<void> _quarantine(Object reason) async {
    final stamp = DateTime.now().toUtc().toIso8601String().replaceAll(
      RegExp(r'[^0-9]'),
      '',
    );
    _log.w(
      'CredentialFileStore: credential file is unreadable ($reason); '
      'setting it aside as $_fileName.$stamp.bak and starting a new one',
    );
    for (final file in [_file, _deviceKeyFile]) {
      if (await file.exists()) {
        await file.rename('${file.path}.$stamp.bak');
      }
    }
  }

  Future<void> _writeAll(Map<String, dynamic> entries) async {
    await Directory(directory).create(recursive: true);

    final salt = _randomBytes(_saltLength);
    final nonce = _randomBytes(_nonceLength);
    final payload = _cipher(
      forEncryption: true,
      key: await _deriveKey(salt),
      nonce: nonce,
    ).process(Uint8List.fromList(utf8.encode(jsonEncode(entries))));

    final envelope = jsonEncode({
      'v': _formatVersion,
      'salt': base64Encode(salt),
      'nonce': base64Encode(nonce),
      'data': base64Encode(payload),
    });

    // Write-then-rename so a crash mid-write cannot leave a half-written file
    // that reads as "no credentials" and silently signs the user out.
    final temp = File('${_file.path}.tmp');
    await temp.writeAsString(envelope, flush: true);
    await _restrictToOwner(temp);
    await temp.rename(_file.path);
  }

  GCMBlockCipher _cipher({
    required bool forEncryption,
    required Uint8List key,
    required Uint8List nonce,
  }) {
    return GCMBlockCipher(AESEngine())..init(
      forEncryption,
      AEADParameters(KeyParameter(key), _macBits, nonce, Uint8List(0)),
    );
  }

  /// Derives the file key from a per-install random secret plus, on Linux, the
  /// machine's own id. The machine id is what makes a copied user-data folder
  /// useless on another machine; the random secret is what stops the key being
  /// guessable from the machine id alone.
  Future<Uint8List> _deriveKey(Uint8List salt) async {
    final material = <int>[...await _deviceSecret()];
    final machineId = _machineId();
    if (machineId != null) {
      material.addAll(utf8.encode(machineId));
    }

    final derivator = HKDFKeyDerivator(SHA256Digest())
      ..init(
        HkdfParameters(
          Uint8List.fromList(material),
          _keyLength,
          salt,
          _hkdfInfo,
        ),
      );

    final key = Uint8List(_keyLength);
    derivator.deriveKey(Uint8List(0), 0, key, 0);
    return key;
  }

  Future<Uint8List> _deviceSecret() async {
    final file = _deviceKeyFile;
    if (await file.exists()) {
      final existing = await file.readAsBytes();
      if (existing.length == _deviceKeyLength) return existing;
      throw const FormatException('Credential device key is malformed');
    }

    if (await _file.exists()) {
      throw StateError('Device key missing for existing encrypted credentials');
    }
    final secret = _randomBytes(_deviceKeyLength);
    await Directory(directory).create(recursive: true);
    await file.writeAsBytes(secret, flush: true);
    await _restrictToOwner(file);
    return secret;
  }

  /// The host's stable machine id, or null where the platform has none.
  String? _machineId() {
    if (!Platform.isLinux) return null;
    for (final candidate in const [
      '/etc/machine-id',
      '/var/lib/dbus/machine-id',
    ]) {
      try {
        final file = File(candidate);
        if (!file.existsSync()) continue;
        final id = file.readAsStringSync().trim();
        if (id.isNotEmpty) return id;
      } catch (_) {
        // An unreadable machine id only costs the machine binding, so fall
        // through to the next candidate rather than failing the whole read.
      }
    }
    return null;
  }

  Future<void> _restrictToOwner(File file) async {
    if (Platform.isWindows) return;
    try {
      await Process.run('chmod', ['600', file.path]);
    } catch (e) {
      _log.w('CredentialFileStore: could not restrict ${file.path}: $e');
    }
  }

  Uint8List _randomBytes(int length) {
    return Uint8List.fromList(
      List<int>.generate(length, (_) => _random.nextInt(256)),
    );
  }
}
