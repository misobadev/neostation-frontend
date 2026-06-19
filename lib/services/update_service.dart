import 'dart:io';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as path;
import 'package:archive/archive_io.dart';
import 'package:neostation/services/logger_service.dart';

import 'package:neostation/services/permission_service.dart';

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

  /// Queries the remote repository to check for available software updates.
  ///
  /// Returns an [UpdateInfo] object if a newer version is detected and compatible
  /// with the current host platform. Returns `null` if the application is
  /// up-to-date or running in an unsupported environment (e.g., Web).
  static Future<UpdateInfo?> checkForUpdates() async {
    // OTA updates are disabled for web-targeted builds.
    if (kIsWeb) return null;

    try {
      // 1. Resolve local versioning from the application manifest.
      final currentVersion = await _getAppVersion();

      // 2. Poll GitHub API for the latest release metadata.
      final response = await http.get(Uri.parse(_githubApiUrl));

      if (response.statusCode != 200) {
        _log.e('UpdateService: API failure (Status: ${response.statusCode})');
        return null;
      }

      final releaseData = json.decode(response.body) as Map<String, dynamic>;

      // Standardize version tag by removing 'v' prefix and build metadata.
      final latestVersion = releaseData['tag_name']
          .toString()
          .replaceFirst('v', '')
          .split('+')[0];

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
  static bool _isNewerVersion(String current, String latest) {
    try {
      final currentParts = current.split('.').map(int.parse).toList();
      final latestParts = latest.split('.').map(int.parse).toList();

      for (int i = 0; i < 3; i++) {
        if (latestParts[i] > currentParts[i]) return true;
        if (latestParts[i] < currentParts[i]) return false;
      }

      return false; // Versions are identical or current is newer.
    } catch (e) {
      _log.e('UpdateService: Version comparison failure', error: e);
      return false;
    }
  }

  /// Identifies the correct release asset based on the current execution environment.
  static Future<Map<String, dynamic>?> _findPlatformAsset(
    List<dynamic> assets,
  ) async {
    String platformPattern;

    if (Platform.isAndroid) {
      platformPattern = '-android-arm64-v8a-';
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
  static Future<bool> downloadAndInstall(
    UpdateInfo updateInfo,
    void Function(double progress)? onProgress,
  ) async {
    try {
      // 1. Localize the update binary to a temporary directory.
      final downloadedFile = await _downloadFile(
        updateInfo.downloadUrl,
        updateInfo.fileName,
        onProgress,
      );

      if (downloadedFile == null) {
        _log.e('UpdateService: Download operation failed');
        return false;
      }

      // 2. Delegate to platform-specific installation logic.
      if (Platform.isWindows) {
        return await _installWindows(downloadedFile);
      } else if (Platform.isLinux) {
        return await _installLinux(downloadedFile);
      } else if (Platform.isMacOS) {
        return await _installMacOS(downloadedFile);
      } else if (Platform.isAndroid) {
        return await _installAndroid(downloadedFile);
      }

      return false;
    } catch (e, stackTrace) {
      _log.e(
        'UpdateService: Installation sequence failed',
        error: e,
        stackTrace: stackTrace,
      );
      return false;
    }
  }

  /// Downloads a file from a URL with real-time progress tracking.
  static Future<File?> _downloadFile(
    String url,
    String fileName,
    void Function(double progress)? onProgress,
  ) async {
    try {
      final request = http.Request('GET', Uri.parse(url));
      final response = await request.send();

      if (response.statusCode != 200) {
        return null;
      }

      final tempDir = await getTemporaryDirectory();
      final file = File(path.join(tempDir.path, fileName));

      final contentLength = response.contentLength ?? 0;
      var downloadedBytes = 0;

      final sink = file.openWrite();

      await for (final chunk in response.stream) {
        sink.add(chunk);
        downloadedBytes += chunk.length;

        if (contentLength > 0 && onProgress != null) {
          final progress = downloadedBytes / contentLength;
          onProgress(progress);
        }
      }

      await sink.close();
      return file;
    } catch (e) {
      _log.e('UpdateService: File download failed', error: e);
      return null;
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
      final appImagePath = Platform.environment['APPIMAGE'];

      if (appImagePath == null) {
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

  /// Installs an APK on Android via a native MethodChannel integration.
  static Future<bool> _installAndroid(File apkFile) async {
    try {
      _log.i('UpdateService: Verifying Android installation permissions...');

      // Verify and request 'REQUEST_INSTALL_PACKAGES' permission if necessary.
      if (!await PermissionService.hasInstallPermission()) {
        final granted = await PermissionService.requestInstallPermission();

        if (!granted) {
          _log.w('UpdateService: Android installation permission denied');
          return false;
        }
      }

      _log.i('UpdateService: Executing APK installation...');

      // Invoke platform-specific logic in MainActivity.kt
      final platform = const MethodChannel('com.neogamelab.neostation/game');
      await platform.invokeMethod('installApk', {'filePath': apkFile.path});

      return true;
    } catch (e) {
      _log.e('UpdateService: Android installation failure', error: e);
      return false;
    }
  }
}

/// Metadata container for a resolved software update.
class UpdateInfo {
  final String currentVersion;
  final String latestVersion;
  final String downloadUrl;
  final String fileName;
  final int fileSize;
  final String? releaseNotes;

  UpdateInfo({
    required this.currentVersion,
    required this.latestVersion,
    required this.downloadUrl,
    required this.fileName,
    required this.fileSize,
    this.releaseNotes,
  });

  /// Formats the file size to a human-readable Megabyte string.
  String get fileSizeMB => (fileSize / (1024 * 1024)).toStringAsFixed(2);
}
