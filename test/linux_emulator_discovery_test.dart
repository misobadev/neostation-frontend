import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/services/game/game_launch_service.dart';
import 'package:neostation/services/linux_emulator_discovery.dart';
import 'package:path/path.dart' as p;

/// Linux emulators are never where the systems JSON says they are.
///
/// The JSON names them the way the launch command does — `retroarch`,
/// `dolphin` — but on a real Linux or SteamOS install those resolve to a
/// Flatpak wrapper, an EmuDeck launcher script, or a versioned AppImage. Until
/// discovery existed the launch just failed and the user had to hunt the path
/// down in a file picker, so these tests pin the resolution order against a
/// fixture tree shaped like the real thing.
void main() {
  late Directory home;

  /// Creates an executable file, and the directories leading to it.
  File exe(String relativePath, [String contents = '#!/bin/bash\n']) {
    final file = File(p.join(home.path, relativePath));
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(contents);
    Process.runSync('chmod', ['+x', file.path]);
    return file;
  }

  setUp(() {
    home = Directory.systemTemp.createTempSync('neostation_linux_discovery');
    LinuxEmulatorDiscovery.homeOverride = home.path;
    // Discovery is Linux-only in production; force it on so the resolution
    // order is exercised on any host, macOS included.
    LinuxEmulatorDiscovery.linuxOverride = true;
    // Point the removable-media scan at an empty fixture path by default, so a
    // test never depends on whether the host running it has an SD card mounted.
    LinuxEmulatorDiscovery.removableMediaRoot = p.join(home.path, 'no-media');
    LinuxEmulatorDiscovery.invalidateCache();
  });

  tearDown(() {
    LinuxEmulatorDiscovery.homeOverride = null;
    LinuxEmulatorDiscovery.linuxOverride = false;
    LinuxEmulatorDiscovery.removableMediaRoot = '/run/media';
    LinuxEmulatorDiscovery.invalidateCache();
    if (home.existsSync()) home.deleteSync(recursive: true);
  });

  group('executable resolution', () {
    test('finds the EmuDeck launcher script at the default Emulation root', () {
      final script = exe('Emulation/tools/launchers/retroarch.sh');

      return expectLater(
        LinuxEmulatorDiscovery.resolveExecutable(
          executable: 'retroarch',
          flatpakId: 'org.libretro.RetroArch',
          emudeckLauncher: 'retroarch.sh',
        ),
        completion(script.path),
      );
    });

    test(
      'follows the Emulation root EmuDeck recorded in settings.sh',
      () async {
        // The Deck's Emulation folder is routinely on the SD card, so the
        // recorded path has to win over the in-$HOME default.
        final sd = Directory(p.join(home.path, 'sdcard'))
          ..createSync(recursive: true);
        final script = exe('sdcard/Emulation/tools/launchers/dolphin-emu.sh');
        exe('Emulation/tools/launchers/dolphin-emu.sh'); // decoy at the default

        File(p.join(home.path, '.config/EmuDeck/settings.sh'))
          ..parent.createSync(recursive: true)
          ..writeAsStringSync(
            '#!/bin/bash\n'
            'emulationPath="${sd.path}/Emulation"\n'
            'toolsPath="${sd.path}/Emulation/tools"\n',
          );

        expect(
          await LinuxEmulatorDiscovery.resolveExecutable(
            executable: 'dolphin',
            flatpakId: 'org.DolphinEmu.dolphin-emu',
            emudeckLauncher: 'dolphin-emu.sh',
          ),
          script.path,
        );
      },
    );

    test('reads the mid-value quoting a real Deck writes', () async {
      // Verified on a Steam Deck (SteamOS 3.x, EmuDeck): only the install root
      // is quoted and the rest is concatenated onto it —
      // `toolsPath="/run/media/deck/Deck"/Emulation/tools`. Treating that as a
      // wrapped value leaves the quotes inside the path, so the recorded root
      // is silently ignored and discovery falls through to the defaults.
      final sd = Directory(p.join(home.path, 'sdcard'))
        ..createSync(recursive: true);
      final script = exe('sdcard/Emulation/tools/launchers/retroarch.sh');

      File(p.join(home.path, '.config/EmuDeck/settings.sh'))
        ..parent.createSync(recursive: true)
        ..writeAsStringSync(
          '#!/bin/bash\n'
          'emulationPath="${sd.path}"/Emulation\n'
          'toolsPath="${sd.path}"/Emulation/tools\n',
        );

      expect(
        await LinuxEmulatorDiscovery.resolveExecutable(
          executable: 'retroarch',
          flatpakId: 'org.libretro.RetroArch',
          emudeckLauncher: 'retroarch.sh',
        ),
        script.path,
      );
    });

    test('expands the \$HOME form EmuDeck writes into settings.sh', () async {
      final script = exe('Emulation/tools/launchers/pcsx2-qt.sh');

      File(p.join(home.path, '.config/EmuDeck/settings.sh'))
        ..parent.createSync(recursive: true)
        ..writeAsStringSync('toolsPath="\$HOME/Emulation/tools"\n');

      expect(
        await LinuxEmulatorDiscovery.resolveExecutable(
          executable: 'pcsx2',
          emudeckLauncher: 'pcsx2-qt.sh',
        ),
        script.path,
      );
    });

    test('finds an Emulation root nested under a removable mount', () async {
      // SteamOS mounts the SD card as /run/media/<user>/<label>, so the
      // launchers land two levels below the media root rather than one.
      final script = exe('media/deck/Deck/Emulation/tools/launchers/mame.sh');
      LinuxEmulatorDiscovery.removableMediaRoot = p.join(home.path, 'media');

      expect(
        await LinuxEmulatorDiscovery.resolveExecutable(
          executable: 'mame',
          emudeckLauncher: 'mame.sh',
        ),
        script.path,
      );
    });

    test('survives a mount it is not allowed to read', () async {
      // Reproduces a launch failure seen on a real Steam Deck: /run/media/root
      // is mode 700 and owned by another user, and Directory.exists() *throws*
      // PathAccessException there rather than returning false. Discovery is
      // called from the launch path, so that escaping exception aborted the
      // launch outright — a denied directory has to read as "not here".
      final media = Directory(p.join(home.path, 'media'))
        ..createSync(recursive: true);
      final denied = Directory(p.join(media.path, 'root'))
        ..createSync(recursive: true);
      LinuxEmulatorDiscovery.removableMediaRoot = media.path;
      final wrapper = exe(
        '.local/share/flatpak/exports/bin/org.libretro.RetroArch',
      );
      addTearDown(() => Process.runSync('chmod', ['700', denied.path]));
      Process.runSync('chmod', ['000', denied.path]);

      expect(
        await LinuxEmulatorDiscovery.resolveExecutable(
          executable: 'retroarch',
          flatpakId: 'org.libretro.RetroArch',
          emudeckLauncher: 'retroarch.sh',
        ),
        wrapper.path,
      );
    });

    test('falls back to the Flatpak export wrapper', () async {
      final wrapper = exe(
        '.local/share/flatpak/exports/bin/org.libretro.RetroArch',
      );

      expect(
        await LinuxEmulatorDiscovery.resolveExecutable(
          executable: 'retroarch',
          flatpakId: 'org.libretro.RetroArch',
          emudeckLauncher: 'retroarch.sh',
        ),
        wrapper.path,
      );
    });

    test('matches a versioned AppImage by prefix, newest last', () async {
      exe('Applications/Azahar-2100.AppImage');
      final newest = exe('Applications/Azahar-2120.AppImage');

      expect(
        await LinuxEmulatorDiscovery.resolveExecutable(
          executable: 'azahar.AppImage',
          flatpakId: 'org.azahar_emu.Azahar',
          emudeckLauncher: 'azahar.sh',
        ),
        newest.path,
      );
    });

    test('ignores a match that is not executable', () async {
      // A leftover non-executable file is not something to hand to
      // Process.start; the launch should keep looking.
      final script = File(
        p.join(home.path, 'Emulation/tools/launchers/rpcs3.sh'),
      )..parent.createSync(recursive: true);
      script.writeAsStringSync('#!/bin/bash\n');
      Process.runSync('chmod', ['-x', script.path]);

      final wrapper = exe('.local/share/flatpak/exports/bin/net.rpcs3.RPCS3');

      expect(
        await LinuxEmulatorDiscovery.resolveExecutable(
          executable: 'rpcs3',
          flatpakId: 'net.rpcs3.RPCS3',
          emudeckLauncher: 'rpcs3.sh',
        ),
        wrapper.path,
      );
    });

    test('returns null rather than guessing when nothing is installed', () async {
      expect(
        await LinuxEmulatorDiscovery.resolveExecutable(
          // A name no distro ships, so a stray PATH hit cannot mask the result.
          executable: 'neostation-nonexistent-emulator',
          flatpakId: 'com.example.NotInstalled',
          emudeckLauncher: 'not-installed.sh',
        ),
        isNull,
      );
    });
  });

  group('RetroArch core arguments', () {
    test('rewrites a bare core filename to an absolute path', () async {
      final cores = Directory(p.join(home.path, 'cores'))
        ..createSync(recursive: true);
      File(p.join(cores.path, 'snes9x_libretro.so')).writeAsStringSync('');

      expect(
        await GameLaunchService.absolutizeRetroArchCore([
          '-L',
          'snes9x_libretro.so',
          '/roms/snes/game.sfc',
        ], cores.path),
        ['-L', p.join(cores.path, 'snes9x_libretro.so'), '/roms/snes/game.sfc'],
      );
    });

    test('strips a "cores/" prefix before relocating', () async {
      final cores = Directory(p.join(home.path, 'cores'))
        ..createSync(recursive: true);
      File(
        p.join(cores.path, 'genesis_plus_gx_libretro.so'),
      ).writeAsStringSync('');

      expect(
        await GameLaunchService.absolutizeRetroArchCore([
          '-L',
          'cores/genesis_plus_gx_libretro.so',
          '/roms/md/game.md',
        ], cores.path),
        [
          '-L',
          p.join(cores.path, 'genesis_plus_gx_libretro.so'),
          '/roms/md/game.md',
        ],
      );
    });

    test('leaves an already-absolute core path untouched', () async {
      final cores = Directory(p.join(home.path, 'cores'))
        ..createSync(recursive: true);

      expect(
        await GameLaunchService.absolutizeRetroArchCore([
          '-L',
          '/opt/retroarch/cores/mgba_libretro.so',
          '/roms/gba/game.gba',
        ], cores.path),
        ['-L', '/opt/retroarch/cores/mgba_libretro.so', '/roms/gba/game.gba'],
      );
    });

    test(
      'leaves a core that is not in the directory for RetroArch to report',
      () async {
        // Pointing at a path that does not exist turns RetroArch's own
        // "core not found" error into a silent black screen.
        final cores = Directory(p.join(home.path, 'cores'))
          ..createSync(recursive: true);

        expect(
          await GameLaunchService.absolutizeRetroArchCore([
            '-L',
            'not_installed_libretro.so',
            '/roms/nes/game.nes',
          ], cores.path),
          ['-L', 'not_installed_libretro.so', '/roms/nes/game.nes'],
        );
      },
    );

    test('ignores a trailing -L with no value', () async {
      expect(
        await GameLaunchService.absolutizeRetroArchCore(['-L'], home.path),
        ['-L'],
      );
    });
  });

  group('RetroArch cores directory', () {
    test('prefers the Flatpak config tree over a sibling cores dir', () async {
      final flatpakCores = Directory(
        p.join(
          home.path,
          '.var/app/org.libretro.RetroArch/config/retroarch/cores',
        ),
      )..createSync(recursive: true);
      // A launcher script has a sibling directory that is *not* the cores dir.
      Directory(
        p.join(home.path, 'Emulation/tools/launchers/cores'),
      ).createSync(recursive: true);

      expect(
        await LinuxEmulatorDiscovery.resolveRetroArchCoresDir(
          p.join(home.path, 'Emulation/tools/launchers/retroarch.sh'),
        ),
        flatpakCores.path,
      );
    });

    test('finds a native install cores dir next to the binary', () async {
      final cores = Directory(p.join(home.path, 'bin/cores'))
        ..createSync(recursive: true);

      expect(
        await LinuxEmulatorDiscovery.resolveRetroArchCoresDir(
          p.join(home.path, 'bin/retroarch'),
        ),
        cores.path,
      );
    });

    test('reports null when no cores directory exists at all', () async {
      expect(
        await LinuxEmulatorDiscovery.resolveRetroArchCoresDir(
          p.join(home.path, 'nowhere/retroarch'),
        ),
        isNull,
      );
    });
  });
}
