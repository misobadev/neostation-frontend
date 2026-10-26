import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/models/core_emulator_model.dart';
import 'package:neostation/models/system_configuration.dart';
import 'package:neostation/repositories/system_repository.dart';

void main() {
  Map<String, dynamic> loadSystem(String name) {
    final file = File('assets/systems/$name.json');
    return jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
  }

  List<EmulatorDefinition> emulatorsOf(Map<String, dynamic> json) {
    return (json['emulators'] as List)
        .map(
          (entry) => EmulatorDefinition.fromJson(
            Map<String, dynamic>.from(entry as Map),
          ),
        )
        .toList();
  }

  group('bundled extension metadata', () {
    for (final system in ['ps3', 'ports', 'windows']) {
      test('$system has unique ids and parseable formats', () {
        final emulators = emulatorsOf(loadSystem(system));
        final ids = <String>{};
        for (final emulator in emulators) {
          expect(emulator.uniqueId, isNotEmpty);
          expect(ids.add(emulator.uniqueId), isTrue);
        }
      });
    }

    test('PS3 covers folders, packages and serial descriptors', () {
      final emulators = emulatorsOf(loadSystem('ps3'));
      final byId = {
        for (final emulator in emulators) emulator.uniqueId: emulator,
      };

      expect(
        byId['ps3.aenu.aps3e']!.extensions,
        containsAll(['iso', 'folder']),
      );
      expect(
        byId['ps3.aenu.aps3e']!
            .platforms['android']['directory_launch_arguments'],
        contains('game_dir'),
      );
      expect(byId['ps3.com.armsx3.pkg']!.extensions, contains('pkg'));
      expect(byId['ps3.com.armsx3.serial']!.extensions, contains('ps3'));
      expect(
        byId['ps3.com.armsx3.serial']!.platforms['android']['launch_arguments'],
        contains('{file.content}'),
      );
      expect(byId['ps3.rpcs3']!.extensions, contains('folder'));
    });

    test('ports are desktop-only desktop launchers', () {
      final emulators = emulatorsOf(loadSystem('ports'));
      for (final emulator in emulators) {
        expect(emulator.platforms.containsKey('android'), isFalse);
      }
      final executable = emulators.firstWhere(
        (emulator) => emulator.uniqueId == 'ports.native.executable',
      );
      expect(
        executable.platforms['windows']['working_directory'],
        '{file.dir}',
      );
      expect(executable.platforms['windows']['executable'], '{file.path}');
    });

    test('Windows shortcuts resolve on every desktop platform', () {
      final emulators = emulatorsOf(loadSystem('windows'));
      final shortcut = emulators.firstWhere(
        (emulator) => emulator.uniqueId == 'windows.desktop.shortcut',
      );
      final executable = emulators.firstWhere(
        (emulator) => emulator.uniqueId == 'windows.desktop.executable',
      );
      expect(shortcut.extensions, containsAll(['lnk', 'desktop', 'app']));
      expect(executable.extensions, containsAll(['exe', 'appimage', 'sh']));
      for (final platform in ['windows', 'linux', 'macos']) {
        expect(shortcut.platforms[platform]['launch_mode'], 'shortcut');
        expect(shortcut.platforms[platform]['executable'], '{file.path}');
        expect(shortcut.platforms.containsKey('android'), isFalse);
      }
    });
  });

  test('native ports stay hidden on Android', () {
    expect(
      SystemRepository.isSystemAvailableOnPlatform('ports', android: true),
      isFalse,
    );
    expect(
      SystemRepository.isSystemAvailableOnPlatform('ports', android: false),
      isTrue,
    );
    expect(
      SystemRepository.isSystemAvailableOnPlatform('android', android: false),
      isFalse,
    );
    expect(
      SystemRepository.isSystemAvailableOnPlatform('ps3', android: true),
      isTrue,
    );
  });

  test('CoreEmulatorModel parses supported_extensions from a row', () {
    final model = CoreEmulatorModel.fromMap({
      'unique_identifier': 'ps3.com.armsx3.pkg',
      'os_id': 1,
      'system_id': 'ps3',
      'name': 'ARMSX3 PKG',
      'is_standalone': 1,
      'is_default': 0,
      'is_ra_compatible': 0,
      'supported_extensions': '["pkg","ps3"]',
    });

    expect(model.supportedExtensions, {'pkg', 'ps3'});
  });
}
