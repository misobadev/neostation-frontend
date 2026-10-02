import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/services/windows_emulator_discovery.dart';
import 'package:path/path.dart' as path;

void main() {
  const environment = {
    'SystemDrive': 'D:',
    'ProgramFiles': r'D:\Apps',
    'ProgramFiles(x86)': r'D:\Apps (x86)',
    'LOCALAPPDATA': r'D:\Users\alex\AppData\Local',
    'ProgramData': r'D:\ProgramData',
    'USERPROFILE': r'D:\Users\alex',
  };

  group('WindowsEmulatorDiscovery.executableCandidates', () {
    test(
      'covers RetroArch installer, package-manager, and per-user locations',
      () {
        expect(
          WindowsEmulatorDiscovery.executableCandidates(
            'retroarch.exe',
            environment: environment,
          ),
          containsAll([
            path.join(r'D:\Apps', 'RetroArch', 'retroarch.exe'),
            path.join(r'D:\Apps (x86)', 'RetroArch', 'retroarch.exe'),
            path.join(
              r'D:\Users\alex\AppData\Local',
              'Programs',
              'RetroArch',
              'retroarch.exe',
            ),
            path.join(
              r'D:\ProgramData',
              'chocolatey',
              'lib',
              'retroarch',
              'tools',
              'retroarch.exe',
            ),
            path.join(
              r'D:\Users\alex',
              'scoop',
              'apps',
              'retroarch',
              'current',
              'retroarch.exe',
            ),
          ]),
        );
      },
    );

    test('covers the common DuckStation, PCSX2, and ePSXe locations', () {
      expect(
        WindowsEmulatorDiscovery.executableCandidates(
          'duckstation.exe',
          environment: environment,
        ),
        contains(path.join(r'D:\Apps', 'DuckStation', 'duckstation.exe')),
      );
      expect(
        WindowsEmulatorDiscovery.executableCandidates(
          'pcsx2.exe',
          environment: environment,
        ),
        contains(path.join(r'D:\Apps', 'PCSX2', 'pcsx2-qt.exe')),
      );
      expect(
        WindowsEmulatorDiscovery.executableCandidates(
          'epsxe.exe',
          environment: environment,
        ),
        contains(path.join(r'D:\Apps (x86)', 'ePSXe', 'ePSXe.exe')),
      );
    });
  });

  test('returns the first existing candidate', () async {
    final temp = await Directory.systemTemp.createTemp('emulator_discovery');
    addTearDown(() => temp.delete(recursive: true));
    final executable = File(path.join(temp.path, 'retroarch.exe'));
    await executable.writeAsString('placeholder');

    expect(
      await WindowsEmulatorDiscovery.resolveCandidates('retroarch.exe', [
        path.join(temp.path, 'missing.exe'),
        executable.path,
      ]),
      executable.path,
    );
  });
}
