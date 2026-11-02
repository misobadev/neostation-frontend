import 'dart:async';
import 'dart:ffi' show Abi;
import 'dart:io';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as path;
import 'package:archive/archive_io.dart';
import 'package:crypto/crypto.dart' as crypto;
import 'package:neostation/services/logger_service.dart';

import 'package:neostation/services/permission_service.dart';
import 'package:neostation/utils/chunked_file_writer.dart';
import 'package:neostation/utils/version_compare.dart';

/// Service responsible for orchestrating the over-the-air (OTA) update lifecycle.
///
/// Handles version checking via the GitHub Releases API, asset resolution based on
/// host architecture/OS, secure downloading, and platform-specific installation
/// procedures (including multi-stage self-replacement on Desktop).
class UpdateService {
  /// GitHub Releases API endpoint for the latest production build.
  static const String _githubApiUrl =
      'https://api.github.com/repos/misobadev/neostation-frontend/releases/latest';

  static final _log = LoggerService.instance;

  static http.Client? _httpClientOverride;

  /// Routes the release check through [client] (a `MockClient`, typically);
  /// pass null to restore the default.
  @visibleForTesting
  static void debugUseHttpClient(http.Client? client) {
    _httpClientOverride = client;
  }

  /// The process environment, replaceable so a test can run without
  /// `APPIMAGE`.
  @visibleForTesting
  static Map<String, String> Function() environment = () =>
      Platform.environment;

  /// Queries the remote repository to check for available software updates.
  ///
  /// Returns an [UpdateInfo] object if a newer version is detected and compatible
  /// with the current host platform. Returns `null` if the application is
  /// up-to-date or running in an unsupported environment (e.g., Web).
  static Future<UpdateInfo?> checkForUpdates() async {
    // OTA updates are disabled for web-targeted builds.
    if (kIsWeb) return null;

    // Linux installs an update by replacing the AppImage it runs from. Without
    // one (Flatpak, an extracted AppImage, a build run in place) the download
    // could only fail to install, so no update is offered.
    if (Platform.isLinux && (environment()['APPIMAGE'] ?? '').isEmpty) {
      _log.i('UpdateService: Not running from an AppImage; no app update');
      return null;
    }

    try {
      // 1. Resolve local versioning from the application manifest.
      final currentVersion = await _getAppVersion();

      // 2. Poll GitHub API for the latest release metadata. A bounded timeout
      // keeps an offline/unreachable network from stalling the startup
      // sequence, which defers the ROM scan until the update checks finish.
      final response =
          await (_httpClientOverride?.get(Uri.parse(_githubApiUrl)) ??
                  http.get(Uri.parse(_githubApiUrl)))
              .timeout(const Duration(seconds: 10));

      if (response.statusCode != 200) {
        _log.e('UpdateService: API failure (Status: ${response.statusCode})');
        return null;
      }

      final releaseData = json.decode(response.body) as Map<String, dynamic>;

      // Standardize the tag for display: strip a leading 'v' and the build
      // metadata. replaceFirst('v', '') would have removed a 'v' anywhere in
      // the string, so only a genuine prefix is dropped here. The comparison
      // below normalizes independently and tolerates either form.
      final rawTag = releaseData['tag_name'].toString().trim();
      final latestVersion =
          (rawTag.startsWith('v') || rawTag.startsWith('V')
                  ? rawTag.substring(1)
                  : rawTag)
              .split('+')
              .first;

      // 3. Perform semantic version comparison.
      if (_isNewerVersion(currentVersion, latestVersion)) {
        // Resolve the specific binary asset compatible with the host OS and architecture.
        final assets = releaseData['assets'] as List<dynamic>;
        final platformAsset = await _findPlatformAsset(assets);

        if (platformAsset != null) {
          return UpdateInfo(
            currentVersion: currentVersion,
            latestVersion: latestVersion,
            downloadUrl: platformAsset['browser_download_url'].toString(),
            fileName: platformAsset['name'].toString(),
            fileSize:
                int.tryParse(platformAsset['size']?.toString() ?? '0') ?? 0,
            sha256: sha256FromDigest(platformAsset['digest']),
            releaseNotes: releaseData['body']?.toString(),
          );
        }
      }

      return null;
    } catch (e, stackTrace) {
      _log.e(
        'UpdateService: Unexpected error during update check',
        error: e,
        stackTrace: stackTrace,
      );
      return null;
    }
  }

  /// The SHA-256 in a GitHub asset's `digest` (`sha256:<hex>`), in lower case,
  /// or null when there is none.
  @visibleForTesting
  static String? sha256FromDigest(Object? digest) {
    const prefix = 'sha256:';
    if (digest is! String || !digest.startsWith(prefix)) return null;
    final hex = digest.substring(prefix.length).toLowerCase();
    return RegExp(r'^[0-9a-f]{64}$').hasMatch(hex) ? hex : null;
  }

  /// Extracts the application version string from the platform package info.
  static Future<String> _getAppVersion() async {
    try {
      final packageInfo = await PackageInfo.fromPlatform();
      return packageInfo.version;
    } catch (e) {
      _log.e('UpdateService: Failed to read app version', error: e);
      return '0.0.0';
    }
  }

  /// Performs a semantic comparison between two version strings.
  ///
  /// Both sides carry decoration that plain integer parsing chokes on: the
  /// Android dev and feature-test flavors add a `-dev` / `-feature`
  /// versionNameSuffix, and release tags carry `v` and `+build` metadata.
  static bool _isNewerVersion(String current, String latest) {
    if (parseVersion(current) == null || parseVersion(latest) == null) {
      _log.w(
        'UpdateService: unparseable version (current="$current", '
        'latest="$latest"); skipping update check',
      );
      return false;
    }
    return isNewerVersion(current, latest);
  }

  /// Identifies the correct release asset based on the current execution environment.
  static Future<Map<String, dynamic>?> _findPlatformAsset(
    List<dynamic> assets,
  ) async {
    String platformPattern;

    if (Platform.isAndroid) {
      // Match the ABI this build was compiled for, not the ones the device
      // supports: the installer rejects an update whose native libs differ
      // from the installed package.
      platformPattern = Abi.current() == Abi.androidArm
          ? '-android-armeabi-v7a-'
          : '-android-arm64-v8a-';
    } else if (Platform.isWindows) {
      platformPattern = '-windows-x64-';
    } else if (Platform.isLinux) {
      // Differentiate between ARM and x86_64 architectures on Linux.
      try {
        final result = await Process.run('uname', ['-m']);
        final arch = result.stdout.toString().trim();
        if (arch == 'aarch64' || arch == 'arm64') {
          platformPattern = '-linux-arm64-';
        } else {
          platformPattern = '-linux-x86_64-';
        }
      } catch (e) {
        _log.w(
          'UpdateService: Arch detection failed, falling back to x86_64, error: $e',
        );
        platformPattern = '-linux-x86_64-';
      }
    } else if (Platform.isMacOS) {
      platformPattern = '-macos-';
    } else {
      return null; // Platform not targeted for OTA updates.
    }

    for (final asset in assets) {
      final name = asset['name'].toString();
      if (name.contains(platformPattern)) {
        return asset as Map<String, dynamic>;
      }
    }

    return null;
  }

  /// Downloads the update payload and executes the platform-specific installer.
  ///
  /// [shouldCancel] is asked while the download runs; returning true stops it
  /// and the result is [UpdateOutcome.cancelled].
  static Future<UpdateOutcome> downloadAndInstall(
    UpdateInfo updateInfo,
    void Function(double progress)? onProgress, {
    bool Function()? shouldCancel,
  }) async {
    bool cancelled() => shouldCancel?.call() ?? false;
    File? downloadedFile;
    try {
      // 1. Localize the update binary to a temporary directory.
      downloadedFile = await downloadUpdateFile(
        updateInfo.downloadUrl,
        updateInfo.fileName,
        onProgress,
        shouldCancel: shouldCancel,
        expectedSize: updateInfo.fileSize,
        expectedSha256: updateInfo.sha256,
      );

      if (downloadedFile == null) {
        if (cancelled()) return UpdateOutcome.cancelled;
        _log.e('UpdateService: Download operation failed');
        return UpdateOutcome.downloadFailed;
      }
      if (cancelled()) {
        await _removeDownload(downloadedFile);
        return UpdateOutcome.cancelled;
      }

      // 2. Delegate to platform-specific installation logic.
      final outcome = await _install(downloadedFile);
      // An update that couldn't be installed is downloaded again next time;
      // a started one is left for its installer and cleaned up on a later
      // start.
      if (outcome != UpdateOutcome.installing) {
        await _removeDownload(downloadedFile);
      }
      return outcome;
    } catch (e, stackTrace) {
      _log.e(
        'UpdateService: Installation sequence failed',
        error: e,
        stackTrace: stackTrace,
      );
      if (downloadedFile != null) await _removeDownload(downloadedFile);
      return UpdateOutcome.installFailed;
    }
  }

  static Future<UpdateOutcome> _install(File downloadedFile) async {
    if (Platform.isAndroid) return installAndroid(downloadedFile);
    final bool started;
    if (Platform.isWindows) {
      started = await _installWindows(downloadedFile);
    } else if (Platform.isLinux) {
      started = await _installLinux(downloadedFile);
    } else if (Platform.isMacOS) {
      started = await _installMacOS(downloadedFile);
    } else {
      started = false;
    }
    return started ? UpdateOutcome.installing : UpdateOutcome.installFailed;
  }

  /// Removes [file] and the folder [downloadUpdateFile] saved it in.
  static Future<void> _removeDownload(File file) {
    final folder = file.parent;
    // Never the temporary folder itself, should a file come from elsewhere.
    return path.basename(folder.path).startsWith(_downloadFolderPrefix)
        ? _deleteQuietly(folder)
        : _deleteQuietly(file);
  }

  static Future<void> _deleteQuietly(FileSystemEntity entity) async {
    try {
      if (await entity.exists()) await entity.delete(recursive: true);
    } catch (e) {
      _log.w('UpdateService: Could not remove ${entity.path}: $e');
    }
  }

  /// How long [downloadUpdateFile] waits for the response headers.
  @visibleForTesting
  static const downloadRequestTimeout = Duration(seconds: 60);

  /// How long [downloadUpdateFile] waits for the next chunk of the body. There
  /// is no limit on the whole download: a slow connection is fine, as long as
  /// the update keeps arriving.
  @visibleForTesting
  static const downloadStallTimeout = Duration(seconds: 60);

  /// Makes the download's folder private to this user, returning false if it
  /// couldn't. Replaceable so a test can fail it.
  @visibleForTesting
  static Future<bool> Function(Directory folder) makePrivate =
      defaultMakePrivate;

  /// Removes everyone else's access to [folder] on Linux and macOS. Windows'
  /// and Android's temporary folders are already the user's or the app's own.
  @visibleForTesting
  static Future<bool> defaultMakePrivate(Directory folder) async {
    if (!Platform.isLinux && !Platform.isMacOS) return true;
    final result = await Process.run('chmod', ['700', folder.path]);
    return result.exitCode == 0;
  }

  /// The start of the name of the folder each download is saved in.
  static const _downloadFolderPrefix = 'neostation-update-';

  /// How often [downloadUpdateFile] asks its `shouldCancel`, so a cancel also
  /// reaches a download that has stopped arriving.
  static const _cancelPollInterval = Duration(milliseconds: 250);

  /// Downloads a file from a URL, reporting progress as bytes are written.
  ///
  /// The headers must arrive within [requestTimeout] and each chunk of the
  /// body within [stallTimeout] of the last. [shouldCancel] returning true
  /// stops the download. The file must be [expectedSize] bytes when that is
  /// known (non-zero) and hash to [expectedSha256] when given; progress uses
  /// [expectedSize] when the server sends no length. The file is saved in a
  /// new folder of its own under the temporary folder. Returns null on any
  /// failure, mismatch or cancel, with that folder removed and the connection
  /// closed.
  @visibleForTesting
  static Future<File?> downloadUpdateFile(
    String url,
    String fileName,
    void Function(double progress)? onProgress, {
    bool Function()? shouldCancel,
    Duration requestTimeout = downloadRequestTimeout,
    Duration stallTimeout = downloadStallTimeout,
    int expectedSize = 0,
    String? expectedSha256,
  }) async {
    // Completing [abort] drops the request and its connection on a cancel;
    // closing [client] drops it on every other way out of this method, and on
    // a cancel while still connecting, which the abort doesn't reach.
    final client = http.Client();
    final abort = Completer<void>();
    void fireAbort() {
      if (!abort.isCompleted) abort.complete();
    }

    final cancelPoll = shouldCancel == null
        ? null
        : Timer.periodic(_cancelPollInterval, (_) {
            if (shouldCancel()) {
              fireAbort();
              client.close();
            }
          });
    Directory? folder;
    try {
      final response = await client
          .send(
            http.AbortableRequest(
              'GET',
              Uri.parse(url),
              abortTrigger: abort.future,
            ),
          )
          .timeout(requestTimeout);

      if (response.statusCode != 200) {
        _log.e('UpdateService: Download refused (HTTP ${response.statusCode})');
        return null;
      }

      final contentLength = response.contentLength ?? 0;
      if (contentLength > 0 &&
          expectedSize > 0 &&
          contentLength != expectedSize) {
        _log.e(
          'UpdateService: Download is $contentLength bytes, the release '
          'lists $expectedSize',
        );
        return null;
      }

      // A folder made for this download and closed to other users. On Linux
      // the temporary folder is the shared /tmp, where anything another user
      // puts at the release's file name first would stop the update.
      final tempDir = await getTemporaryDirectory();
      folder = await tempDir.createTemp(_downloadFolderPrefix);
      if (!await makePrivate(folder)) {
        _log.e('UpdateService: Could not make ${folder.path} private');
        await _deleteQuietly(folder);
        return null;
      }
      final file = File(path.join(folder.path, fileName));
      // Made here, so that nothing put in the folder before it was private is
      // written to: an existing name, even a link, fails this.
      await file.create(exclusive: true);

      final totalBytes = contentLength > 0 ? contentLength : expectedSize;
      var downloadedBytes = 0;
      final digest = _DigestSink();
      final hasher = crypto.sha256.startChunkedConversion(digest);

      // Each chunk is written before the next is read, so a full disk stops
      // the download; the partial file is removed. The hash is taken as it
      // goes, so checking it costs no second read.
      Stream<List<int>> written() async* {
        await for (final chunk in response.stream.timeout(stallTimeout)) {
          // Without a length from the server, more than the release lists is
          // the wrong file: stop rather than run the progress past 100%.
          if (expectedSize > 0 &&
              downloadedBytes + chunk.length > expectedSize) {
            throw StateError('more than the $expectedSize bytes listed');
          }
          yield chunk;
          hasher.add(chunk);
          downloadedBytes += chunk.length;
          if (totalBytes > 0 && onProgress != null) {
            onProgress(downloadedBytes / totalBytes);
          }
        }
      }

      await writeChunksToFile(file, written());
      hasher.close();

      // A captive portal's page, a proxy's error or a damaged download isn't
      // the release's file, and mustn't reach the installer.
      final String? mismatch;
      if (expectedSize > 0 && downloadedBytes != expectedSize) {
        mismatch = '$downloadedBytes bytes, expected $expectedSize';
      } else if (expectedSha256 != null &&
          digest.value.toString() != expectedSha256) {
        mismatch = 'SHA-256 ${digest.value}, expected $expectedSha256';
      } else {
        mismatch = null;
      }
      if (mismatch != null) {
        _log.e('UpdateService: Download doesn\'t match the release: $mismatch');
        await _deleteQuietly(folder);
        return null;
      }
      return file;
    } catch (e) {
      _log.e('UpdateService: File download failed', error: e);
      if (folder != null) await _deleteQuietly(folder);
      return null;
    } finally {
      cancelPoll?.cancel();
      client.close();
    }
  }

  /// Installs a ZIP-packaged update on Windows using a multi-stage batch script.
  ///
  /// This process is necessary to bypass file locks on the running executable.
  /// It extracts the update, generates a recovery script, and performs a
  /// self-replacement before restarting the application.
  static Future<bool> _installWindows(File zipFile) async {
    try {
      _log.i('UpdateService: Initiating Windows ZIP extraction...');

      // Resolve application deployment directory.
      final exePath = Platform.resolvedExecutable;
      final appDir = Directory(path.dirname(exePath));

      // 1. Extract payload to a temporary staging area.
      final tempDir = await getTemporaryDirectory();
      final extractDir = Directory(
        path.join(tempDir.path, 'neostation_update'),
      );
      if (await extractDir.exists()) {
        await extractDir.delete(recursive: true);
      }
      await extractDir.create(recursive: true);

      final bytes = await zipFile.readAsBytes();
      final archive = ZipDecoder().decodeBytes(bytes);

      for (final file in archive) {
        final filename = path.join(extractDir.path, file.name);
        if (file.isFile) {
          final outFile = File(filename);
          await outFile.create(recursive: true);
          await outFile.writeAsBytes(file.content as List<int>);
        } else {
          await Directory(filename).create(recursive: true);
        }
      }

      // 2. Locate the primary executable within the extracted archive.
      String? neostationExePath;
      await for (final entity in extractDir.list(
        recursive: true,
        followLinks: false,
      )) {
        if (entity is File && entity.path.endsWith('neostation.exe')) {
          neostationExePath = entity.path;
          break;
        }
      }

      if (neostationExePath == null) {
        throw Exception('neostation.exe missing from update payload');
      }

      final extractedExeDir = path.dirname(neostationExePath);

      // 3. Deploy multi-stage synchronization script.
      // Stage 2: Synchronizes files and restarts the application.
      // Uses a retry loop to handle potential OS file locks during termination.
      final stage1Path = path.join(tempDir.path, 'update_stage1.bat');
      final stage2Path = path.join(tempDir.path, 'update_stage2.bat');
      final xcopyLogPath = path.join(tempDir.path, 'update_xcopy.log');

      final stage2Script =
          '''
@echo off
setlocal enabledelayedexpansion
set RETRY_COUNT=0
set MAX_RETRIES=5

echo Starting update copy... > "${xcopyLogPath.replaceAll('/', '\\')}"

:RETRY
timeout /t 2 /nobreak >nul
echo Attempt %RETRY_COUNT%... >> "${xcopyLogPath.replaceAll('/', '\\')}"
xcopy /E /I /Y /Q "${extractedExeDir.replaceAll('/', '\\')}" "${appDir.path.replaceAll('/', '\\')}" >> "${xcopyLogPath.replaceAll('/', '\\')}" 2>&1

if errorlevel 1 (
    set /a RETRY_COUNT+=1
    if !RETRY_COUNT! LSS %MAX_RETRIES% (
        echo Copy failed, retrying in 2 seconds... >> "${xcopyLogPath.replaceAll('/', '\\')}"
        goto RETRY
    )
    echo CRITICAL ERROR: Update synchronization failed after %MAX_RETRIES% attempts. >> "${xcopyLogPath.replaceAll('/', '\\')}"
    echo Please verify that no instances of neostation.exe are currently active. >> "${xcopyLogPath.replaceAll('/', '\\')}"
    start notepad "${xcopyLogPath.replaceAll('/', '\\')}"
    exit
)

echo Update successfully applied. >> "${xcopyLogPath.replaceAll('/', '\\')}"
start "" "${appDir.path.replaceAll('/', '\\')}\\neostation.exe"
del /F /Q "${stage1Path.replaceAll('/', '\\')}" >nul 2>&1
(goto) 2>nul & del "%~f0"
''';

      // Stage 1: Disassociates from the parent process to allow self-replacement.
      final stage1Script =
          '''
@echo off
start /min cmd /c "${stage2Path.replaceAll('/', '\\')}"
''';

      await File(stage2Path).writeAsString(stage2Script);
      await File(stage1Path).writeAsString(stage1Script);

      _log.i('UpdateService: Launching update orchestrator. Shutting down...');

      await Process.start(
        stage1Path,
        [],
        mode: ProcessStartMode.detached,
        runInShell: false,
      );

      // Graceful termination to allow the batch script to take control.
      await Future.delayed(const Duration(milliseconds: 500));
      exit(0);
    } catch (e, stackTrace) {
      _log.e(
        'UpdateService: Windows installation failure',
        error: e,
        stackTrace: stackTrace,
      );
      return false;
    }
  }

  /// Installs an AppImage on Linux via a temporary side-loading script.
  static Future<bool> _installLinux(File appImageFile) async {
    try {
      _log.i('UpdateService: Deploying Linux AppImage update...');

      // Verify the application was launched from an AppImage container.
      final appImagePath = environment()['APPIMAGE'];

      if (appImagePath == null || appImagePath.isEmpty) {
        _log.w(
          'UpdateService: Not running from AppImage. Update logic suspended in development mode.',
        );
        return false;
      }

      final currentAppImage = File(appImagePath);
      final appImageDir = currentAppImage.parent;
      final tempUpdatePath = path.join(
        appImageDir.path,
        '.neostation-update.AppImage',
      );

      // Set executable bit for the new payload.
      final chmodResult = await Process.run('chmod', ['+x', appImageFile.path]);
      if (chmodResult.exitCode != 0) {
        _log.e('UpdateService: Failed to set executable bit on AppImage');
        return false;
      }

      await appImageFile.copy(tempUpdatePath);

      // Generate a shell script to perform the hot-swap after process termination.
      final scriptPath = path.join(appImageDir.path, '.neostation-update.sh');
      final updateScript =
          '''#!/bin/bash
sleep 2
mv -f "$tempUpdatePath" "$appImagePath"
chmod +x "$appImagePath"
"$appImagePath" &
rm -f "$scriptPath"
''';

      await File(scriptPath).writeAsString(updateScript);
      await Process.run('chmod', ['+x', scriptPath]);

      await Process.start(scriptPath, [], mode: ProcessStartMode.detached);

      await Future.delayed(const Duration(milliseconds: 500));
      exit(0);
    } catch (e, stackTrace) {
      _log.e(
        'UpdateService: Linux installation failure',
        error: e,
        stackTrace: stackTrace,
      );
      return false;
    }
  }

  /// Removes app updates downloaded by an earlier run (each in its own folder,
  /// or loose in the temporary folder from older versions), and Windows'
  /// extracted copy of one, from the temporary folder.
  static Future<void> cleanUpDownloads() async {
    try {
      final tempDir = await getTemporaryDirectory();
      await for (final entity in tempDir.list(followLinks: false)) {
        final name = path.basename(entity.path);
        try {
          if (entity is File &&
              name.toLowerCase().startsWith('neostation-') &&
              _assetPlatformMarkers.any(name.contains)) {
            await entity.delete();
          } else if (entity is Directory &&
              name.startsWith(_downloadFolderPrefix)) {
            await _removeDownloadFolder(entity);
          } else if (Platform.isWindows &&
              entity is Directory &&
              name == 'neostation_update') {
            // Only Windows' installer makes it, in a temporary folder of the
            // user's own.
            await entity.delete(recursive: true);
          }
        } catch (e) {
          _log.w('UpdateService: Could not remove old update $name: $e');
        }
      }
    } catch (e) {
      _log.w('UpdateService: Could not clean up old updates: $e');
    }
  }

  /// Removes a folder left by an earlier download. In a shared temporary
  /// folder another user can make one by that name, holding links or folders
  /// they can swap for links, so nothing in it is followed: its files and
  /// links are removed, and a folder inside keeps it from being removed.
  static Future<void> _removeDownloadFolder(Directory folder) async {
    await for (final entity in folder.list(followLinks: false)) {
      if (entity is! Directory) await entity.delete();
    }
    await folder.delete();
  }

  /// The parts of a release asset's name that say which platform it is for,
  /// as [_findPlatformAsset] matches them. Linux's temporary folder is shared,
  /// so only names like these are ever removed from it.
  static const _assetPlatformMarkers = [
    '-android-armeabi-v7a-',
    '-android-arm64-v8a-',
    '-windows-x64-',
    '-linux-arm64-',
    '-linux-x86_64-',
    '-macos-',
  ];

  /// Handles updates on macOS by invoking the system handler for the downloaded payload.
  static Future<bool> _installMacOS(File file) async {
    try {
      _log.i(
        'UpdateService: Delegating macOS installation to system handler...',
      );

      // macOS handles DMG/PKG/ZIP payloads natively via the 'open' command.
      await Process.run('open', [file.path]);

      await Future.delayed(const Duration(milliseconds: 500));
      exit(0);
    } catch (e) {
      _log.e('UpdateService: macOS installation failure', error: e);
      return false;
    }
  }

  /// Whether NeoStation may install an APK, asking for the permission to
  /// install unknown apps when it may not yet.
  @visibleForTesting
  static Future<bool> Function() ensureInstallPermission = () async {
    if (await PermissionService.hasInstallPermission()) return true;
    return PermissionService.requestInstallPermission();
  };

  /// Installs an APK on Android via a native MethodChannel integration.
  @visibleForTesting
  static Future<UpdateOutcome> installAndroid(File apkFile) async {
    try {
      _log.i('UpdateService: Verifying Android installation permissions...');

      // Verify and request 'REQUEST_INSTALL_PACKAGES' permission if necessary.
      if (!await ensureInstallPermission()) {
        _log.w('UpdateService: Android installation permission denied');
        return UpdateOutcome.installPermissionDenied;
      }

      _log.i('UpdateService: Executing APK installation...');

      // Invoke platform-specific logic in MainActivity.kt
      final platform = const MethodChannel('com.neogamelab.neostation/game');
      await platform.invokeMethod('installApk', {'filePath': apkFile.path});

      return UpdateOutcome.installing;
    } on PlatformException catch (e) {
      _log.e('UpdateService: Android installation failure', error: e);
      // The permission is missing, or its settings screen couldn't be opened.
      return e.code == 'PERMISSION_DENIED' || e.code == 'INTENT_ERROR'
          ? UpdateOutcome.installPermissionDenied
          : UpdateOutcome.installFailed;
    } catch (e) {
      _log.e('UpdateService: Android installation failure', error: e);
      return UpdateOutcome.installFailed;
    }
  }
}

/// What became of an update the user chose to install.
enum UpdateOutcome {
  /// The installer took over.
  installing,

  /// The user cancelled the download.
  cancelled,

  /// The download failed, stalled or was refused.
  downloadFailed,

  /// Android: the permission to install unknown apps wasn't granted.
  installPermissionDenied,

  /// The installer couldn't be started.
  installFailed,
}

/// Metadata container for a resolved software update.
class UpdateInfo {
  final String currentVersion;
  final String latestVersion;
  final String downloadUrl;
  final String fileName;
  final int fileSize;

  /// The release asset's SHA-256, in lower-case hex, when GitHub gives one.
  final String? sha256;
  final String? releaseNotes;

  UpdateInfo({
    required this.currentVersion,
    required this.latestVersion,
    required this.downloadUrl,
    required this.fileName,
    required this.fileSize,
    this.sha256,
    this.releaseNotes,
  });

  /// Formats the file size to a human-readable Megabyte string.
  String get fileSizeMB => (fileSize / (1024 * 1024)).toStringAsFixed(2);
}

/// Captures the single [crypto.Digest] a chunked conversion emits on close.
class _DigestSink implements Sink<crypto.Digest> {
  late final crypto.Digest value;

  @override
  void add(crypto.Digest digest) => value = digest;

  @override
  void close() {}
}
