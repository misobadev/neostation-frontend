import 'dart:io';

import 'package:flutter/services.dart';
import 'package:neostation/models/core_emulator_model.dart';
import 'package:neostation/models/system_model.dart';
import 'package:neostation/repositories/emulator_repository.dart';
import 'package:neostation/services/launcher_service.dart';
import 'package:neostation/services/linux_emulator_discovery.dart';
import 'package:neostation/services/logger_service.dart';

/// Hydrates the list of supported emulators for [system], verifying package
/// presence on Android hosts and RetroArch core availability on desktop.
///
/// Shared by the game details settings tab and the game settings dialog so
/// both enumerate identical emulator options.
Future<List<CoreEmulatorModel>> loadEmulatorsForSystem(
  SystemModel system,
) async {
  final log = LoggerService.instance;
  final systemId = system.id;
  if (systemId == null) return [];
  try {
    var emulators = await EmulatorRepository.getEmulatorsForSystemCurrentOs(
      systemId,
    );
    if (Platform.isAndroid) {
      // Verification Protocol: Check native package presence via platform channel.
      final updated = <CoreEmulatorModel>[];
      for (final e in emulators) {
        if (e.androidPackageName != null && e.androidPackageName!.isNotEmpty) {
          try {
            const ch = MethodChannel('com.neogamelab.neostation/game');
            var installed =
                await ch.invokeMethod<bool>('isPackageInstalled', {
                  'packageName': e.androidPackageName,
                }) ??
                false;

            // A RetroArch entry reports its *app* as installed even when the
            // specific libretro core (.so) isn't present, which made uninstalled
            // cores show "Ready" and get auto-selected → "Launch error" (#192).
            // Verify the core file. Tri-state: null means we couldn't determine
            // (RetroArch's cores dir is private and no root) → fail OPEN and leave
            // the package-based result untouched.
            if (installed &&
                e.isRetroArch &&
                e.coreFilename != null &&
                e.coreFilename!.isNotEmpty) {
              final coreInstalled = await ch.invokeMethod<bool>(
                'isCoreInstalled',
                {
                  'packageName': e.androidPackageName,
                  'coreFilename': e.coreFilename,
                },
              );
              if (coreInstalled != null) installed = coreInstalled;
            }
            updated.add(e.copyWith(isInstalled: installed));
          } catch (_) {
            updated.add(e);
          }
        } else {
          updated.add(e);
        }
      }
      emulators = updated;
    } else {
      // Desktop: a RetroArch core is only usable when its libretro core file
      // actually exists — having the RetroArch executable configured is not
      // enough (#192). Probe the cores dir next to the executable. If we can't
      // locate a readable cores dir (layout varies by platform/install), fail
      // OPEN and keep the executable-based assumption rather than hide a
      // genuinely-installed core.
      var retroArchPath = await EmulatorRepository.getRetroArchExecutablePath();

      // Linux ships RetroArch as a Flatpak or behind an EmuDeck launcher
      // script, so the database holds no path for it until the user points a
      // file picker at one — which this feature exists to avoid. Without
      // discovery here the probe below is skipped entirely and every core is
      // reported uninstalled on a machine that has all of them installed.
      if (Platform.isLinux &&
          (retroArchPath == null || retroArchPath.isEmpty)) {
        retroArchPath = await LinuxEmulatorDiscovery.resolveExecutable(
          executable: 'retroarch',
          flatpakId: 'org.libretro.RetroArch',
          emudeckLauncher: 'retroarch.sh',
        );
      }

      // Baseline: on desktop a configured executable path is the only evidence
      // the database holds, so it stands in as the install verdict for anything
      // the core probe below does not refine. Without this, emulators would be
      // reported uninstalled whenever RetroArch itself is unconfigured.
      emulators = emulators
          .map((e) => e.copyWith(isInstalled: e.hasConfiguredPath))
          .toList();

      // Linux: nothing configures a path on a Deck — emulators arrive as
      // Flatpaks and EmuDeck launcher scripts — so the baseline above reports
      // every standalone as uninstalled. Selection then cannot see that a
      // working standalone exists and falls back to the JSON default, which for
      // several systems is a RetroArch core the user never installed: RetroArch
      // rejects the missing core at parse time, exits 0, and the game "launches"
      // and instantly closes (verified on a Steam Deck with GameCube, where
      // Standalone Dolphin was installed and discoverable the whole time).
      //
      // Ask discovery instead. A resolvable executable is the same evidence a
      // configured path is, just gathered rather than typed in.
      if (Platform.isLinux) {
        await LauncherService.instance.loadSystemConfig(
          '${system.folderName}.json',
        );
        final updated = <CoreEmulatorModel>[];
        for (final e in emulators) {
          if (e.isInstalled || !e.isStandalone) {
            updated.add(e);
            continue;
          }
          final hints = LauncherService.instance.getLinuxDiscoveryHints(
            system.folderName,
            e.uniqueId,
          );
          if (hints == null) {
            updated.add(e);
            continue;
          }
          final resolved = await LinuxEmulatorDiscovery.resolveExecutable(
            executable: hints['executable']!,
            flatpakId: hints['flatpak'],
            emudeckLauncher: hints['emudeck_launcher'],
          );
          updated.add(e.copyWith(isInstalled: resolved != null));
        }
        emulators = updated;
      }

      if (retroArchPath != null && retroArchPath.isNotEmpty) {
        // Linux keeps cores away from the executable (Flatpak's ~/.var tree,
        // or a distro's /usr/lib/libretro), so assuming a sibling `cores/`
        // marks every genuinely-installed core as missing. Ask the discovery
        // service, which probes the layouts that actually occur.
        final coresDir = Platform.isLinux
            ? await LinuxEmulatorDiscovery.resolveRetroArchCoresDir(
                retroArchPath,
              )
            : '${File(retroArchPath).parent.path}'
                  '${Platform.pathSeparator}cores';
        final coresDirReadable =
            coresDir != null && await Directory(coresDir).exists();
        final updated = <CoreEmulatorModel>[];
        for (final e in emulators) {
          final uid = e.uniqueId;
          final isRaCore =
              uid.contains('.ra.') ||
              uid.contains('.ra32.') ||
              uid.contains('.ra64.');
          if (isRaCore && !e.hasConfiguredPath) {
            var installed = true; // fail-open default
            if (coresDirReadable &&
                e.coreFilename != null &&
                e.coreFilename!.isNotEmpty) {
              installed = await _desktopCoreExists(coresDir, e.coreFilename!);
            }
            updated.add(e.copyWith(isInstalled: installed));
          } else {
            updated.add(e); // keeps the baseline set above
          }
        }
        emulators = updated;
      }
    }
    return emulators;
  } catch (e) {
    log.e('Emulator enumeration failed: $e');
    return [];
  }
}

/// Saves Linux-discovered paths for this system without changing its default.
///
/// Discovery checks the configured EmuDeck location, Flatpak exports, PATH
/// (including `/usr/bin`), and known AppImage folders in that order. Existing
/// paths are left alone because they are an explicit user choice.
Future<void> autoConfigureLinuxEmulatorsForSystem(SystemModel system) async {
  if (!Platform.isLinux || system.id == null) return;

  try {
    final launcher = LauncherService.instance;
    if (!await launcher.loadSystemConfig('${system.folderName}.json')) return;

    final retroArchPath = await EmulatorRepository.getRetroArchExecutablePath();
    if (retroArchPath == null || retroArchPath.isEmpty) {
      final discovered = await LinuxEmulatorDiscovery.resolveExecutable(
        executable: 'retroarch',
        flatpakId: 'org.libretro.RetroArch',
        emudeckLauncher: 'retroarch.sh',
      );
      if (discovered != null) {
        await EmulatorRepository.saveDetectedEmulatorPath(
          emulatorName: 'RetroArch',
          emulatorPath: discovered,
        );
      }
    }

    final emulators = await EmulatorRepository.getEmulatorsForSystemCurrentOs(
      system.id!,
    );
    for (final emulator in emulators) {
      if (!emulator.isStandalone || emulator.hasConfiguredPath) continue;
      final hints = launcher.getLinuxDiscoveryHints(
        system.folderName,
        emulator.uniqueId,
      );
      if (hints == null) continue;

      final discovered = await LinuxEmulatorDiscovery.resolveExecutable(
        executable: hints['executable'],
        flatpakId: hints['flatpak'],
        emudeckLauncher: hints['emudeck_launcher'],
      );
      if (discovered != null) {
        await EmulatorRepository.setStandaloneEmulatorPath(
          emulator.uniqueId,
          discovered,
          setAsDefault: false,
        );
      }
    }
  } catch (e) {
    LoggerService.instance.w('Linux emulator auto-configuration failed: $e');
  }
}

/// Returns whether a libretro core exists in [coresDir] on a desktop host.
///
/// The DB [coreFilename] may carry the Android-style name (e.g.
/// `ppsspp_libretro_android.so`), whereas desktop cores are named
/// `<base>_libretro.{dll,so,dylib}`. We therefore strip the known libretro
/// suffixes down to the base and probe each desktop extension, so a correct
/// core install isn't missed due to a platform naming mismatch.
Future<bool> _desktopCoreExists(String coresDir, String coreFilename) async {
  const suffixes = [
    '_libretro_android.so',
    '_libretro.so',
    '_libretro.dll',
    '_libretro.dylib',
  ];
  var base = coreFilename;
  for (final s in suffixes) {
    if (base.endsWith(s)) {
      base = base.substring(0, base.length - s.length);
      break;
    }
  }
  for (final ext in const [
    '_libretro.dll',
    '_libretro.so',
    '_libretro.dylib',
  ]) {
    if (await File('$coresDir${Platform.pathSeparator}$base$ext').exists()) {
      return true;
    }
  }
  return false;
}
