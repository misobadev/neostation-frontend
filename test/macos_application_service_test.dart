import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/services/macos_application_service.dart';
import 'package:path/path.dart' as path;

void main() {
  late Directory temporaryDirectory;
  late Directory applicationsDirectory;
  late String duckStationBundle;
  late String duckStationExecutable;

  setUp(() async {
    temporaryDirectory = await Directory.systemTemp.createTemp(
      'neostation_macos_apps_',
    );
    applicationsDirectory = await Directory(
      path.join(temporaryDirectory.path, 'Applications'),
    ).create();
    duckStationBundle = path.join(
      applicationsDirectory.path,
      'DuckStation.app',
    );
    final contentsDirectory = await Directory(
      path.join(duckStationBundle, 'Contents'),
    ).create(recursive: true);
    final macOsDirectory = await Directory(
      path.join(contentsDirectory.path, 'MacOS'),
    ).create();
    duckStationExecutable = path.join(macOsDirectory.path, 'DuckStation');
    await File(duckStationExecutable).writeAsString('executable');
    await File(path.join(contentsDirectory.path, 'Info.plist')).writeAsString(
      '''
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>DuckStation</string>
  <key>CFBundleIdentifier</key>
  <string>com.github.stenzek.duckstation</string>
</dict>
</plist>
''',
    );
  });

  tearDown(() async {
    await temporaryDirectory.delete(recursive: true);
  });

  test('resolves a selected app bundle to its executable', () async {
    final result = await MacOsApplicationService.resolveExecutable(
      duckStationBundle,
    );

    expect(result, duckStationExecutable);
  });

  test('finds an installed app from a standalone emulator name', () async {
    final result = await MacOsApplicationService.findInstalledApplication(
      applicationNames: ['DuckStation Standalone'],
      applicationRoots: [applicationsDirectory.path],
    );

    expect(result, duckStationExecutable);
  });

  test('finds an installed app from its bundle identifier', () async {
    final result = await MacOsApplicationService.findInstalledApplication(
      applicationNames: ['Unexpected database name'],
      bundleIdentifierHint: 'ps1.com.github.stenzek.duckstation',
      applicationRoots: [applicationsDirectory.path],
    );

    expect(result, duckStationExecutable);
  });

  test('resolves a configured command name through Applications', () async {
    final result = await MacOsApplicationService.resolveExecutable(
      'duckstation',
      applicationName: 'Standalone Duckstation',
      applicationRoots: [applicationsDirectory.path],
    );

    expect(result, duckStationExecutable);
  });

  test('does not reinterpret a missing absolute path as an app name', () async {
    final result = await MacOsApplicationService.resolveExecutable(
      path.join(temporaryDirectory.path, 'missing', 'duckstation'),
      applicationRoots: [applicationsDirectory.path],
    );

    expect(result, isNull);
  });

  test('finds the bundle containing its resolved executable', () {
    expect(
      MacOsApplicationService.bundlePathForExecutable(duckStationExecutable),
      duckStationBundle,
    );
  });
}
