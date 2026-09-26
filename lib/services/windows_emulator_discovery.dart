import 'dart:io';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:path/path.dart' as path;

import 'logger_service.dart';

/// Locates supported emulators installed at common Windows package locations.
///
/// This is deliberately a read-only probe. A manually configured executable
/// always wins; these paths are only a fallback when no configured path exists
/// (or it has gone stale).
class WindowsEmulatorDiscovery {
  WindowsEmulatorDiscovery._();

  static final _log = LoggerService.instance;

  /// Returns the known install locations for [executable], or no candidates
  /// when it is not an emulator with a stable Windows installer layout.
  @visibleForTesting
  static List<String> executableCandidates(
    String executable, {
    Map<String, String>? environment,
  }) {
    final env = environment ?? Platform.environment;
    final systemDrive = env['SystemDrive'] ?? 'C:';
    final programFiles =
        env['ProgramFiles'] ?? path.join(systemDrive, 'Program Files');
    final programFilesX86 =
        env['ProgramFiles(x86)'] ??
        path.join(systemDrive, 'Program Files (x86)');
    final localAppData = env['LOCALAPPDATA'];
    final userProfile = env['USERPROFILE'];
    final programData =
        env['ProgramData'] ?? path.join(systemDrive, 'ProgramData');

    List<String> installed(String folder, List<String> executables) => [
      for (final name in executables) path.join(programFiles, folder, name),
      for (final name in executables) path.join(programFilesX86, folder, name),
      if (localAppData != null && localAppData.isNotEmpty)
        for (final name in executables)
          path.join(localAppData, 'Programs', folder, name),
      if (userProfile != null && userProfile.isNotEmpty)
        for (final name in executables)
          path.join(
            userProfile,
            'scoop',
            'apps',
            folder.toLowerCase(),
            'current',
            name,
          ),
    ];

    switch (executable.toLowerCase()) {
      case 'retroarch.exe':
        return [
          ...installed('RetroArch', ['retroarch.exe']),
          path.join(
            programData,
            'chocolatey',
            'lib',
            'retroarch',
            'tools',
            'retroarch.exe',
          ),
        ];
      case 'duckstation.exe':
        return installed('DuckStation', [
          'duckstation.exe',
          'duckstation-qt-x64-ReleaseLTCG.exe',
          'duckstation-qt-x64-Release.exe',
        ]);
      case 'pcsx2.exe':
      case 'pcsx2-qt.exe':
        return installed('PCSX2', ['pcsx2-qt.exe', 'pcsx2.exe']);
      case 'epsxe.exe':
        return installed('ePSXe', ['ePSXe.exe', 'epsxe.exe']);
      default:
        return const [];
    }
  }

  /// Resolves the first existing installation of [executable], or `null`.
  static Future<String?> resolveExecutable(String executable) async {
    if (!Platform.isWindows) return null;
    return resolveCandidates(executable, executableCandidates(executable));
  }

  @visibleForTesting
  static Future<String?> resolveCandidates(
    String executable,
    Iterable<String> candidates,
  ) async {
    for (final candidate in candidates) {
      if (await File(candidate).exists()) {
        _log.i('WindowsEmulatorDiscovery: found $executable at $candidate');
        return candidate;
      }
    }
    return null;
  }
}
