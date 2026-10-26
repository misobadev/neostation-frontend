import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/models/core_emulator_model.dart';
import 'package:neostation/services/game/game_launch_service.dart';

void main() {
  CoreEmulatorModel emulator(
    String id, {
    Set<String> extensions = const {},
    bool installed = false,
  }) => CoreEmulatorModel(
    uniqueId: id,
    osId: 1,
    systemId: 'ps3',
    name: id,
    isStandalone: true,
    isDefault: false,
    isretroAchievementsCompatible: false,
    isInstalled: installed,
    supportedExtensions: extensions,
  );

  test('keeps legacy wildcard behaviour when no emulator declares formats', () {
    final result = GameLaunchService.selectEmulatorForExtension(
      extension: 'iso',
      emulators: [emulator('a'), emulator('b')],
      preferredId: 'a',
      explicitChoice: false,
    );

    expect(result.uniqueId, 'a');
    expect(result.unsupported, isFalse);
    expect(result.explicitMismatch, isFalse);
  });

  test('uses the preferred emulator when it supports the format', () {
    final result = GameLaunchService.selectEmulatorForExtension(
      extension: 'iso',
      emulators: [
        emulator('iso-only', extensions: {'iso'}),
        emulator('pkg', extensions: {'pkg'}),
      ],
      preferredId: 'iso-only',
      explicitChoice: true,
    );

    expect(result.uniqueId, 'iso-only');
    expect(result.explicitMismatch, isFalse);
  });

  test('refuses an explicit choice that cannot launch the format', () {
    final result = GameLaunchService.selectEmulatorForExtension(
      extension: 'pkg',
      emulators: [
        emulator('iso-only', extensions: {'iso'}),
        emulator('pkg', extensions: {'pkg'}),
      ],
      preferredId: 'iso-only',
      explicitChoice: true,
    );

    expect(result.explicitMismatch, isTrue);
    expect(result.uniqueId, 'iso-only');
  });

  test('falls through to a matching emulator for an automatic choice', () {
    final result = GameLaunchService.selectEmulatorForExtension(
      extension: 'pkg',
      emulators: [
        emulator('iso-only', extensions: {'iso'}),
        emulator('pkg-installed', extensions: {'pkg'}, installed: true),
      ],
      preferredId: 'iso-only',
      explicitChoice: false,
    );

    expect(result.uniqueId, 'pkg-installed');
    expect(result.explicitMismatch, isFalse);
  });

  test('reports unsupported when no emulator declares the format', () {
    final result = GameLaunchService.selectEmulatorForExtension(
      extension: 'pkg',
      emulators: [
        emulator('iso-only', extensions: {'iso'}),
      ],
      preferredId: null,
      explicitChoice: false,
    );

    expect(result.unsupported, isTrue);
    expect(result.uniqueId, isNull);
  });

  test('empty declarations are wildcards, not exclusions', () {
    final result = GameLaunchService.selectEmulatorForExtension(
      extension: 'folder',
      emulators: [
        emulator('legacy'),
        emulator('iso-only', extensions: {'iso'}),
      ],
      preferredId: null,
      explicitChoice: false,
    );

    expect(result.uniqueId, 'legacy');
    expect(result.unsupported, isFalse);
  });

  test('prefers an installed match over an uninstalled one', () {
    final result = GameLaunchService.selectEmulatorForExtension(
      extension: 'iso',
      emulators: [
        emulator('first', extensions: {'iso'}),
        emulator('installed', extensions: {'iso'}, installed: true),
      ],
      preferredId: null,
      explicitChoice: false,
    );

    expect(result.uniqueId, 'installed');
  });
}
