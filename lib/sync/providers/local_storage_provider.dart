/// Local / NAS sync provider (community skeleton).
///
/// Copies saves to any path accessible from the OS filesystem:
/// a local folder, a USB drive, or a mounted network share (Synology,
/// TrueNAS, Samba, etc.).
///
/// No account, no internet connection required.
///
/// ## Register in main.dart
/// ```dart
/// SyncManager.instance.register(
///   LocalStorageProvider(targetPath: config.localSyncPath),
/// );
/// ```
library;

import 'dart:io';

import 'package:path/path.dart' as p;

import '../i_sync_provider.dart';

class LocalStorageProvider extends ISyncProvider {
  static const String kProviderId = 'local_storage';

  /// Absolute path where saves are copied to/from.
  final String? _targetPath;

  SyncProviderStatus _status = SyncProviderStatus.disconnected;
  String? _lastError;

  LocalStorageProvider({this._targetPath});

  bool get _isConfigured {
    final path = _targetPath;
    return path != null && path.isNotEmpty;
  }

  // ── Identity ───────────────────────────────────────────────────────────────

  @override
  String get providerId => kProviderId;

  @override
  SyncProviderMeta get meta => const SyncProviderMeta(
    id: kProviderId,
    name: 'Local / NAS',
    description:
        'Copy saves to a local folder, USB drive, or mounted '
        'network share. No account required.',
    author: 'Community',
  );

  @override
  SyncProviderStatus get status => _status;

  @override
  bool get isAuthenticated => _isConfigured;

  @override
  String? get lastError => _lastError;

  // ── Lifecycle ──────────────────────────────────────────────────────────────

  @override
  Future<void> initialize() async {
    if (!_isConfigured) return;
    final dir = Directory(_targetPath!);
    if (await dir.exists()) {
      _status = SyncProviderStatus.connected;
    } else {
      _status = SyncProviderStatus.error;
      _lastError = 'Target path does not exist: $_targetPath';
    }
  }

  @override
  void dispose() {}

  // ── Authentication ─────────────────────────────────────────────────────────

  @override
  Future<SyncResult> login() async {
    if (!_isConfigured) {
      return SyncResult.fail(
        SyncError.configInvalid,
        message: 'Set a target path in Settings → Sync → Local',
      );
    }
    final dir = Directory(_targetPath!);
    if (!await dir.exists()) {
      try {
        await dir.create(recursive: true);
      } catch (e) {
        _status = SyncProviderStatus.error;
        _lastError = e.toString();
        return SyncResult.fail(SyncError.configInvalid, message: e.toString());
      }
    }
    _status = SyncProviderStatus.connected;
    return SyncResult.ok(message: 'Local path ready: $_targetPath');
  }

  @override
  Future<void> logout() async {
    _status = SyncProviderStatus.disconnected;
  }

  // ── Core Sync Operations ───────────────────────────────────────────────────

  @override
  Future<SyncResult> uploadSave(
    String gameId,
    File file, {
    String? customFileName,
  }) async {
    if (!_isConfigured) {
      return SyncResult.fail(SyncError.configInvalid);
    }
    try {
      final destDir = Directory(p.join(_targetPath!, gameId));
      if (!await destDir.exists()) await destDir.create(recursive: true);
      final fileName = customFileName ?? p.basename(file.path);
      final destPath = p.join(destDir.path, fileName);
      await file.copy(destPath);
      return SyncResult.ok(message: 'Saved to $destPath');
    } catch (e) {
      return SyncResult.fail(SyncError.unknown, message: e.toString());
    }
  }

  @override
  Future<SyncResult> downloadSave(String gameId, String fileId) async {
    // fileId is the relative path within [gameId] folder (e.g. "save.srm").
    if (!_isConfigured) {
      return SyncResult.fail(SyncError.configInvalid);
    }
    final src = File(p.join(_targetPath!, gameId, fileId));
    if (!await src.exists()) {
      return SyncResult.fail(
        SyncError.fileNotFound,
        message: 'File not found: ${src.path}',
      );
    }
    return SyncResult.ok(data: src);
  }

  @override
  Future<List<SyncFile>> listSaves({String? gameId}) async {
    if (!_isConfigured) return [];
    final basePath = _targetPath as String;
    final searchPath = gameId != null ? p.join(basePath, gameId) : basePath;
    final dir = Directory(searchPath);
    if (!await dir.exists()) return [];

    final files = await dir
        .list(recursive: gameId == null)
        .where((e) => e is File)
        .cast<File>()
        .toList();
    return files.map((f) {
      final stat = f.statSync();
      return SyncFile(
        id: p.relative(f.path, from: basePath),
        fileName: p.basename(f.path),
        fileSize: stat.size,
        uploadedAt: stat.modified,
        modifiedAt: stat.modified,
      );
    }).toList();
  }

  @override
  Future<SyncResult> fullSync() async {
    // Local sync is inherently one-way (NeoStation is the source of truth).
    // Use uploadSave() for each save file discovered by the sync scanner.
    return SyncResult.ok(
      message: 'Call uploadSave() per file to copy saves to $_targetPath',
    );
  }

  @override
  Future<SyncQuota?> getQuota() async => null;

  @override
  Future<SyncResult> deleteRemote(String fileId) async {
    if (!_isConfigured) return SyncResult.fail(SyncError.configInvalid);
    try {
      final f = File(p.join(_targetPath!, fileId));
      if (!await f.exists()) {
        return SyncResult.fail(SyncError.fileNotFound);
      }
      await f.delete();
      return SyncResult.ok();
    } catch (e) {
      return SyncResult.fail(SyncError.unknown, message: e.toString());
    }
  }
}
