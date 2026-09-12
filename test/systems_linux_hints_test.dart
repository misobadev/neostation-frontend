import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Guards the Linux discovery hints in `assets/systems/*.json`.
///
/// `flatpak` and `emudeck_launcher` are how the launcher finds an emulator that
/// the user installed through Flathub or EmuDeck instead of pointing a file
/// picker at it. A typo in either is invisible — discovery simply finds nothing
/// and the launch fails the way it did before the hints existed — so the values
/// are pinned here rather than left to review.
void main() {
  /// Launcher scripts shipped in dragoonDorise/EmuDeck `tools/launchers`.
  const emuDeckLaunchers = {
    'ares-emu.sh',
    'azahar.sh',
    'bigpemu.sh',
    'cemu-native.sh',
    'cemu.sh',
    'citra.sh',
    'citron.sh',
    'dolphin-emu.sh',
    'duckstation.sh',
    'eden.sh',
    'flycast.sh',
    'lime3ds.sh',
    'mame.sh',
    'melonds.sh',
    'mgba.sh',
    'model-2-emulator.sh',
    'pcsx2-qt.sh',
    'ppsspp.sh',
    'primehack.sh',
    'retroarch.sh',
    'rosaliesmupengui.sh',
    'rpcs3.sh',
    'ryujinx.sh',
    'scummvm.sh',
    'shadps4.sh',
    'supermodel.sh',
    'suyu.sh',
    'vita3k.sh',
    'xemu-emu.sh',
    'xenia.sh',
    'yuzu.sh',
  };

  /// App ids confirmed present on Flathub.
  const knownFlatpakIds = {
    'org.libretro.RetroArch',
    'org.DolphinEmu.dolphin-emu',
    'net.pcsx2.PCSX2',
    'net.rpcs3.RPCS3',
    'org.duckstation.DuckStation',
    'org.ppsspp.PPSSPP',
    'org.azahar_emu.Azahar',
    'net.kuribo64.melonDS',
    'info.cemu.Cemu',
    'io.github.gopher64.gopher64',
    'io.github.stella_emu.Stella',
  };

  late List<({String file, String uniqueId, Map<String, dynamic> linux})>
  linuxBlocks;

  setUpAll(() {
    final dir = Directory('assets/systems');
    expect(
      dir.existsSync(),
      isTrue,
      reason: 'run from the project root so assets/systems is visible',
    );

    linuxBlocks = [];
    for (final entity in dir.listSync()) {
      if (entity is! File || !entity.path.endsWith('.json')) continue;
      final json =
          jsonDecode(entity.readAsStringSync()) as Map<String, dynamic>;
      final emulators = (json['emulators'] ?? json['players'] ?? []) as List;
      for (final emulator in emulators) {
        final platforms = (emulator as Map)['platforms'];
        if (platforms is! Map) continue;
        final linux = platforms['linux'];
        if (linux is! Map) continue;
        linuxBlocks.add((
          file: entity.uri.pathSegments.last,
          uniqueId: (emulator['unique_id'] ?? '?').toString(),
          linux: Map<String, dynamic>.from(linux),
        ));
      }
    }
    expect(linuxBlocks, isNotEmpty);
  });

  test('every emudeck_launcher names a real EmuDeck launcher script', () {
    for (final block in linuxBlocks) {
      final launcher = block.linux['emudeck_launcher'];
      if (launcher == null) continue;
      expect(
        emuDeckLaunchers,
        contains(launcher),
        reason: '${block.file} / ${block.uniqueId}',
      );
    }
  });

  test('every flatpak hint is an app id known to exist on Flathub', () {
    for (final block in linuxBlocks) {
      final id = block.linux['flatpak'];
      if (id == null) continue;
      expect(
        knownFlatpakIds,
        contains(id),
        reason: '${block.file} / ${block.uniqueId}',
      );
    }
  });

  test('one executable always maps to the same hints', () {
    // The same emulator appears in dozens of system files; a hint corrected in
    // one and missed in the others is the failure this catches.
    final seen = <String, Map<String, dynamic>>{};
    for (final block in linuxBlocks) {
      final executable = block.linux['executable']?.toString();
      if (executable == null) continue;
      final hints = {
        'flatpak': block.linux['flatpak'],
        'emudeck_launcher': block.linux['emudeck_launcher'],
      };
      final first = seen[executable];
      if (first == null) {
        seen[executable] = hints;
      } else {
        expect(
          hints,
          first,
          reason:
              '$executable is annotated inconsistently '
              '(${block.file} / ${block.uniqueId})',
        );
      }
    }
  });

  test('desktop blocks use "args", never Android\'s "launch_arguments"', () {
    // LauncherService only reads `args` off a desktop platform block. An entry
    // carrying `launch_arguments` instead launches the emulator with no ROM at
    // all, which is how Dolphin ended up opening its own game list on Linux.
    final dir = Directory('assets/systems');
    for (final entity in dir.listSync()) {
      if (entity is! File || !entity.path.endsWith('.json')) continue;
      final json =
          jsonDecode(entity.readAsStringSync()) as Map<String, dynamic>;
      final emulators = (json['emulators'] ?? json['players'] ?? []) as List;
      for (final emulator in emulators) {
        final platforms = (emulator as Map)['platforms'];
        if (platforms is! Map) continue;
        for (final entry in platforms.entries) {
          if (entry.key == 'android') continue;
          final config = entry.value;
          if (config is! Map) continue;
          expect(
            config.containsKey('launch_arguments'),
            isFalse,
            reason:
                '${entity.uri.pathSegments.last} / ${emulator['unique_id']} '
                '(${entry.key}) uses launch_arguments; desktop reads args',
          );
        }
      }
    }
  });
}
