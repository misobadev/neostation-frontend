import 'dart:io';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:neostation/l10n/app_locale.dart';
import 'package:path/path.dart' as path;
import 'package:flutter/services.dart';
import 'package:flutter/material.dart';
import 'package:neostation/services/logger_service.dart';
import '../../models/game_model.dart';
import '../../models/system_model.dart';
import '../../models/emulator_model.dart';
import '../../models/core_emulator_model.dart';
import '../../repositories/emulator_repository.dart';
import '../../utils/emulator_loader.dart';
import '../config_service.dart';
import '../android_service.dart';
import '../launcher_service.dart';
import '../linux_emulator_discovery.dart';
import '../linux_host_process.dart';
import '../macos_application_service.dart';
import 'emulator_launch_diagnostics.dart';
import 'favorites_service.dart';
import 'game_session_manager.dart';
import '../gamepad/gamepad_navigation_manager.dart';

/// Represents the result of a game launch attempt.
/// Represents the result of a game launch attempt.
class GameLaunchResult {
  /// Whether the launch was successful.
  final bool success;

  /// Human-readable error message.
  final String? errorMessage;

  /// Technical details or raw error information for debugging.
  final String? errorDetails;

  GameLaunchResult.success()
    : success = true,
      errorMessage = null,
      errorDetails = null;

  GameLaunchResult.failure(this.errorMessage, [this.errorDetails])
    : success = false;
}

/// Executes game launches across all supported platforms and monitors the
/// launched emulator/game process.
///
/// Owns the platform-specific launch logic (RetroArch cores + standalone
/// emulators, Android + desktop), emulator/core resolution, RetroArch variant
/// resolution, and the process-liveness checks. Extracted verbatim from
/// [GameService], which now delegates its launch API here. Registers each
/// session via [GameSessionManager] and records plays via [FavoritesService].
class GameLaunchService {
  GameLaunchService._();

  static final _log = LoggerService.instance;

  /// Core logic for launching a game session across all supported platforms.
  ///
  /// Performs pre-launch validations (ROM existence, system config), resolves the
  /// optimal emulator/player, and initiates the execution process.
  static Future<GameLaunchResult> launchGame(
    BuildContext context,
    SystemModel system,
    GameModel game,
  ) async {
    try {
      if (Platform.isAndroid && (system.folderName == 'android')) {
        if (game.romPath == null) {
          return GameLaunchResult.failure(
            AppLocale.packageNameMissing.getString(context),
          );
        }

        GameSessionManager.registerGameLaunch(system, game, 'android_app');
        await FavoritesService.recordGamePlayed(game);

        final success = await AndroidService.launchPackage(game.romPath!);
        if (!context.mounted) return GameLaunchResult.failure('', '');
        if (success) {
          return GameLaunchResult.success();
        } else {
          return GameLaunchResult.failure(
            AppLocale.failedToLaunchAndroidApp.getString(context),
            game.romPath,
          );
        }
      }

      bool romExists = false;
      if (game.romPath != null) {
        if (Platform.isAndroid && game.romPath!.startsWith('content://')) {
          romExists = true;
        } else {
          romExists = await File(game.romPath!).exists();
        }
      }
      if (!context.mounted) return GameLaunchResult.failure('', '');

      if (!romExists) {
        return GameLaunchResult.failure(
          AppLocale.romFileNotFound.getString(context),
          game.romPath ?? AppLocale.noData.getString(context),
        );
      }

      final configFileName = '${system.folderName}.json';
      final bool configLoaded = await LauncherService.instance.loadSystemConfig(
        configFileName,
      );

      // Resolved once and threaded through every fallback below. `isExplicit`
      // distinguishes a choice the user actually made (a per-game override, or a
      // system default they set) from one we guessed for them — only the former
      // is worth failing the launch over.
      String? preferredPlayerId = game.emulatorName;
      bool isExplicitChoice = preferredPlayerId != null;
      String source = isExplicitChoice ? 'per-game override' : 'none';

      if (preferredPlayerId == null && system.id != null) {
        final userDefault =
            await EmulatorRepository.getUserDefaultEmulatorForSystem(
              system.id!,
            );
        if (userDefault != null) {
          preferredPlayerId = userDefault.uniqueId;
          isExplicitChoice = true;
          source = 'system default (user-selected)';
        } else {
          final defaultEmu = await _resolveDefaultInstalledEmulator(system);
          if (defaultEmu != null) {
            preferredPlayerId = defaultEmu.uniqueId;
            source = 'auto-resolved default';
          }
        }
      }

      // Emulator selection has been the source of repeated, hard-to-reproduce
      // reports ("I picked melonDS, RetroArch launched"). One tagged line per
      // launch makes the decision auditable from a user's logcat without any
      // debug build or flag.
      _log.i(
        '[EmuSel] ${system.folderName}/${game.romname}: '
        'emulator=${preferredPlayerId ?? "<none>"} source=$source '
        'explicit=$isExplicitChoice configLoaded=$configLoaded',
      );
      if (system.id != null) {
        await _logSystemEmulatorState(system);
      }

      if (configLoaded) {
        final launchCmd = LauncherService.instance.getLaunchCommand(
          system,
          game,
          preferredPlayerId,
        );

        if (launchCmd.isNotEmpty) {
          if (Platform.isAndroid &&
              launchCmd.containsKey('package') &&
              launchCmd.containsKey('activity')) {
            const platform = MethodChannel('com.neogamelab.neostation/game');

            // Cleanup + real failure surfaced to the user. A failure in this
            // branch means the user's *chosen* emulator (resolved from its JSON
            // config) was actually attempted and could not launch — surface it
            // instead of falling through to the generic standalone fallback
            // below, which would launch a *different* emulator and mask the
            // misconfiguration.
            Future<GameLaunchResult> failLaunch() async {
              GamepadNavigationManager.reactivate();
              await platform.invokeMethod('setGamepadBlock', {'block': false});
              if (!context.mounted) return GameLaunchResult.failure('', '');
              return GameLaunchResult.failure(
                AppLocale.launchFailed.getString(context),
                AppLocale.error.getString(context),
              );
            }

            try {
              await LauncherService.instance.resolveAndroidLaunchFiles(
                launchCmd,
                game,
              );
              GamepadNavigationManager.reactivate();
              await platform.invokeMethod('setGamepadBlock', {'block': true});

              final activityName = launchCmd['activity'];
              final action = launchCmd['action'];
              final category = launchCmd['category'];
              final data = launchCmd['data'];
              final type = launchCmd['type'];

              final List<Map<String, dynamic>> extrasList = [];

              if (launchCmd.containsKey('extras') &&
                  launchCmd['extras'] is List) {
                for (final item in launchCmd['extras'] as List) {
                  if (item is Map) {
                    extrasList.add(Map<String, dynamic>.from(item));
                  }
                }
              } else {
                final argsStr = launchCmd['args']?.toString() ?? '';
                if (argsStr.isNotEmpty) {
                  final extrasMap = _parseArgsToExtras(argsStr);
                  extrasMap.forEach((k, v) {
                    String type = 'string';
                    if (v is int) type = 'int';
                    if (v is bool) type = 'bool';
                    extrasList.add({'key': k, 'value': v, 'type': type});
                  });
                }
              }

              final packageName = await _resolveRetroArchVariant(
                launchCmd['package'].toString(),
                extrasList,
                system,
              );

              final result = await platform
                  .invokeMethod('launchGenericIntent', {
                    'package': packageName,
                    'activity': activityName,
                    'action': action,
                    'category': category,
                    'data': data,
                    'type': type,
                    'extras': extrasList,
                    'activity_flags': launchCmd['activity_flags'] != null
                        ? List<String>.from(launchCmd['activity_flags'] as List)
                        : <String>[],
                    'keep_saf_uri': launchCmd['keep_saf_uri'] == true,
                  });

              if (result == true) {
                GameSessionManager.registerGameLaunch(system, game);
                await FavoritesService.recordGamePlayed(game);
                return GameLaunchResult.success();
              }
              return await failLaunch();
            } catch (e) {
              _log.e('JSON Launch Error: $e');
              return await failLaunch();
            }
          }

          if ((Platform.isWindows || Platform.isLinux || Platform.isMacOS) &&
              launchCmd.containsKey('executable')) {
            if (!context.mounted) return GameLaunchResult.failure('', '');
            return await _launchGameDesktopFromConfig(
              context,
              launchCmd,
              system,
              game,
            );
          }
        }
      }

      _log.i(
        '[EmuSel] JSON launch path did not handle '
        '${preferredPlayerId ?? "<none>"}; trying standalone fallback',
      );

      final standaloneEmulator = await _getStandaloneEmulatorForSystem(
        system,
        preferredUniqueId: preferredPlayerId,
      );
      if (!context.mounted) return GameLaunchResult.failure('', '');

      if (standaloneEmulator != null) {
        _log.i(
          '[EmuSel] route=standalone '
          'emulator=${standaloneEmulator['unique_identifier']} '
          '(${standaloneEmulator['name']})',
        );
        if (Platform.isAndroid) {
          return await _launchStandaloneAndroid(
            context,
            system,
            game,
            standaloneEmulator,
          );
        } else if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
          return await _launchStandaloneDesktop(
            context,
            system,
            game,
            standaloneEmulator,
          );
        } else {
          return GameLaunchResult.failure(
            AppLocale.platformNotSupported.getString(context),
            Platform.operatingSystem,
          );
        }
      }

      final coreName = await _getCoreForSystem(
        system,
        preferredUniqueId: preferredPlayerId,
      );
      if (!context.mounted) return GameLaunchResult.failure('', '');

      if (coreName == null) {
        return GameLaunchResult.failure(
          AppLocale.coreNotConfigured.getString(context),
          'No core found for system ${system.folderName}',
        );
      }

      // Every route above declined to launch the emulator the user actually
      // picked, and the only thing left is a core we chose for them. Launching
      // it would silently substitute a *different* emulator — the exact failure
      // that made a deliberate melonDS/standalone selection boot a RetroArch
      // core. Surface the misconfiguration by name instead.
      _log.i('[EmuSel] route=core core=$coreName');

      final bool substitutesUserChoice =
          isExplicitChoice &&
          preferredPlayerId != null &&
          !await _emulatorProvidesCore(system, preferredPlayerId, coreName);
      if (!context.mounted) return GameLaunchResult.failure('', '');

      if (substitutesUserChoice) {
        _log.e(
          'Refusing to substitute a fallback core for the user-selected '
          'emulator "$preferredPlayerId" on ${system.folderName}',
        );
        return GameLaunchResult.failure(
          AppLocale.emulatorNotConfigured.getString(context),
          'The selected emulator "$preferredPlayerId" could not be launched '
          'for ${system.folderName}. Re-select it in the system or per-game '
          'emulator settings, or check that it is installed.',
        );
      }

      if (Platform.isAndroid) {
        return await _launchGameAndroid(context, system, game, coreName);
      } else if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
        return await _launchGameDesktop(context, system, game, coreName);
      } else {
        _log.e('Platform not supported: ${Platform.operatingSystem}');
        return GameLaunchResult.failure(
          AppLocale.platformNotSupported.getString(context),
          Platform.operatingSystem,
        );
      }
    } catch (e) {
      _log.e('Error launching the game: $e');
      GamepadNavigationManager.reactivate();
      if (Platform.isAndroid) {
        const platform = MethodChannel('com.neogamelab.neostation/game');
        await platform.invokeMethod('setGamepadBlock', {'block': false});
      }
      if (!context.mounted) return GameLaunchResult.failure('', '');
      return GameLaunchResult.failure(
        AppLocale.anErrorOccurred.getString(context),
        e.toString(),
      );
    }
  }

  /// Internal logic for launching RetroArch cores on Android.
  static Future<GameLaunchResult> _launchGameAndroid(
    BuildContext context,
    SystemModel system,
    GameModel game,
    String coreName,
  ) async {
    try {
      // Installed variants only. The database lists every RetroArch package
      // that exists (com.retroarch, .ra32, .aarch64), so taking `.first` of the
      // raw list addressed the intent to whichever one the seed happened to
      // return — routinely one the user does not have, which fails with no
      // explanation the user can act on.
      final packages =
          await EmulatorRepository.getInstalledAndroidRetroArchPackages();

      if (packages.isNotEmpty) {
        try {
          final defaultEmu =
              await EmulatorRepository.getDefaultEmulatorForSystem(system.id!);
          final specificPackage = defaultEmu?.androidPackageName;
          if (specificPackage != null && specificPackage.isNotEmpty) {
            // Promote the configured variant only if it is really present.
            // `is_default` is stale whenever variant alignment has been skipped,
            // and an absent package must never outrank an installed one.
            if (packages.contains(specificPackage)) {
              _log.i(
                'Android: Using configured RetroArch package: $specificPackage',
              );
              packages.remove(specificPackage);
              packages.insert(0, specificPackage);
            } else {
              _log.w(
                'Android: Configured RetroArch package "$specificPackage" is '
                'not installed; falling back to ${packages.first}',
              );
            }
          }
        } catch (e) {
          _log.e('Error getting default emulator package: $e');
        }
      }

      const platform = MethodChannel('com.neogamelab.neostation/game');
      GamepadNavigationManager.reactivate();
      await platform.invokeMethod('setGamepadBlock', {'block': true});

      String packageName = 'com.retroarch.aarch64';
      if (packages.isNotEmpty) {
        packageName = packages.first;
      }

      final activityName =
          'com.retroarch.browser.retroactivity.RetroActivityFuture';

      final result = await platform.invokeMethod('launchGenericIntent', {
        'package': packageName,
        'activity': activityName,
        'action': 'android.intent.action.MAIN',
        'category': 'android.intent.category.LAUNCHER',
        'extras': [
          {
            'key': 'ROM',
            'value': (game.romPath?.startsWith('content://') == true)
                ? 'neostation-realpath:${game.romPath}'
                : game.romPath ?? '',
            'type': 'string',
          },
          {'key': 'LIBRETRO', 'value': coreName, 'type': 'string'},
        ],
      });

      if (result == true) {
        await FavoritesService.recordGamePlayed(game);
        GameSessionManager.registerGameLaunch(system, game);
        return GameLaunchResult.success();
      } else {
        GamepadNavigationManager.reactivate();
        const platform = MethodChannel('com.neogamelab.neostation/game');
        await platform.invokeMethod('setGamepadBlock', {'block': false});
        if (!context.mounted) return GameLaunchResult.failure('', '');
        return GameLaunchResult.failure(
          AppLocale.launchFailed.getString(context),
          'RetroArch returned false',
        );
      }
    } catch (e) {
      GamepadNavigationManager.reactivate();
      const platform = MethodChannel('com.neogamelab.neostation/game');
      await platform.invokeMethod('setGamepadBlock', {'block': false});
      if (!context.mounted) return GameLaunchResult.failure('', '');

      if (e is PlatformException) {
        if (e.code == "CORE_NOT_FOUND") {
          return GameLaunchResult.failure(
            AppLocale.coreNotInstalled
                .getString(context)
                .replaceFirst('{name}', coreName),
            'Please install the core from RetroArch\'s Online Updater',
          );
        } else {
          return GameLaunchResult.failure(
            e.message ?? AppLocale.error.getString(context),
            e.details?.toString(),
          );
        }
      } else {
        _log.e('Error en MethodChannel: $e');
        return GameLaunchResult.failure(
          AppLocale.launchFailed.getString(context),
          e.toString(),
        );
      }
    }
  }

  /// Internal logic for launching RetroArch cores on Desktop.
  static Future<GameLaunchResult> _launchGameDesktop(
    BuildContext context,
    SystemModel system,
    GameModel game,
    String coreName,
  ) async {
    try {
      final detectedEmulators =
          await EmulatorRepository.getUserDetectedEmulators();
      var retroArch = detectedEmulators['RetroArch'];

      // On Linux a database entry is not required to find RetroArch: it ships
      // as a Flatpak or behind an EmuDeck launcher script, both of which live
      // at well-known paths. Discovery runs when there is no configured path or
      // the configured one has gone stale, so a working install is not reported
      // as "not detected" just because the user never opened the file picker.
      if (Platform.isLinux &&
          (retroArch == null || !await File(retroArch.path).exists())) {
        final discovered = await LinuxEmulatorDiscovery.resolveExecutable(
          executable: 'retroarch',
          flatpakId: 'org.libretro.RetroArch',
          emudeckLauncher: 'retroarch.sh',
        );
        if (discovered != null) {
          _log.i('Discovered RetroArch on Linux at $discovered');
          retroArch =
              (retroArch ??
                      const EmulatorModel(
                        name: 'RetroArch',
                        path: '',
                        detected: false,
                      ))
                  .copyWith(path: discovered, detected: true);
        }
      }

      if (!context.mounted) return GameLaunchResult.failure('', '');
      if (retroArch == null) {
        return GameLaunchResult.failure(
          AppLocale.retroArchNotFound.getString(context),
          'RetroArch is not detected on your system. Please install RetroArch.',
        );
      }

      bool raExists = false;
      if (Platform.isMacOS && retroArch.path.endsWith('.app')) {
        raExists = await Directory(retroArch.path).exists();
      } else {
        raExists = await File(retroArch.path).exists();
      }
      if (!context.mounted) return GameLaunchResult.failure('', '');

      if (!raExists) {
        _log.e(
          'RetroArch does not exist at the specified path: ${retroArch.path}',
        );
        return GameLaunchResult.failure(
          AppLocale.retroArchExecutableNotFound.getString(context),
          'Path: ${retroArch.path}',
        );
      }

      final coresPath = await _getRetroArchCoresDirectory(retroArch);
      final coresDirectory = Directory(coresPath);
      if (!await coresDirectory.exists()) {
        if (!context.mounted) return GameLaunchResult.failure('', '');
        _log.e('The cores directory does not exist: $coresPath');
        return GameLaunchResult.failure(
          AppLocale.coresDirectoryNotFound.getString(context),
          'Path: $coresPath',
        );
      }

      final coreFullPath = await _getCoreFullPath(coreName);
      if (!context.mounted) return GameLaunchResult.failure('', '');
      if (coreFullPath == null) {
        return GameLaunchResult.failure(
          AppLocale.coreNotFound.getString(context),
          'Could not locate core: $coreName',
        );
      }

      final coreFile = File(coreFullPath);
      if (!await coreFile.exists()) {
        if (!context.mounted) return GameLaunchResult.failure('', '');
        return GameLaunchResult.failure(
          AppLocale.coreFileNotFound.getString(context),
          'Path: $coreFullPath',
        );
      }

      Process process;
      String executable = retroArch.path;
      List<String> args;

      if (Platform.isMacOS) {
        if (executable.endsWith('.app')) {
          executable = path.join(executable, 'Contents', 'MacOS', 'RetroArch');
        }

        args = ['-L', coreFullPath, game.romPath!];
        final env = Map<String, String>.from(Platform.environment);
        env['HOME'] = ConfigService.getRealHomePath();

        process = await Process.start(executable, args, environment: env);
      } else {
        args = ['-f', '-L', coreFullPath, game.romPath!];

        process = await LinuxHostProcess.start(executable, args);
      }

      final diagnostics = EmulatorLaunchDiagnostics.attach(
        process,
        executable,
        args,
      );

      GamepadNavigationManager.deactivateAll();

      process.exitCode
          .then((exitCode) async {
            _log.i('RetroArch exited with code: $exitCode');
            diagnostics.reportExit(exitCode);
            await Future.delayed(Duration(seconds: 2));
            bool stillRunning = await _isDefaultEmulatorRunning();

            if (!stillRunning &&
                (Platform.isWindows || Platform.isLinux || Platform.isMacOS)) {
              GameSessionManager.endGameSession();
            }
          })
          .catchError((error) {
            _log.e('Error monitoring RetroArch: $error');
            if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
              GameSessionManager.endGameSession();
            }
          });

      await FavoritesService.recordGamePlayed(game);
      GameSessionManager.registerGameLaunch(system, game);

      return GameLaunchResult.success();
    } catch (e) {
      _log.e('Error launching game on ${Platform.operatingSystem}: $e');
      GamepadNavigationManager.reactivate();
      if (!context.mounted) return GameLaunchResult.failure('', '');
      return GameLaunchResult.failure(
        AppLocale.failedToLaunchRetroArch.getString(context),
        e.toString(),
      );
    }
  }

  /// Internal logic for launching games using a custom JSON configuration profile.
  static Future<GameLaunchResult> _launchGameDesktopFromConfig(
    BuildContext context,
    Map<String, dynamic> launchCmd,
    SystemModel system,
    GameModel game,
  ) async {
    try {
      String executable = launchCmd['executable'].toString();

      if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
        final detected = await EmulatorRepository.getUserDetectedEmulators();

        if (executable.toLowerCase().contains('retroarch')) {
          final ra = detected['RetroArch'];
          if (ra != null && ra.path.isNotEmpty) {
            if (executable != ra.path) {
              _log.i(
                'Resolving RetroArch executable from "$executable" to user-configured path: ${ra.path}',
              );
            }
            executable = ra.path;
          }
        } else if (!await File(executable).exists()) {
          String? resolvedPath;
          final uniqueId = launchCmd['unique_id']?.toString();
          if (uniqueId != null) {
            for (final emu in detected.values) {
              if (emu.uniqueId == uniqueId &&
                  emu.detected &&
                  emu.path.isNotEmpty) {
                resolvedPath = emu.path;
                break;
              }
            }
          }

          if (resolvedPath == null) {
            final playerName = launchCmd['player_name']?.toString();
            if (playerName != null) {
              final emu = detected[playerName];
              if (emu != null && emu.detected && emu.path.isNotEmpty) {
                resolvedPath = emu.path;
              }
            }
          }

          if (resolvedPath != null) {
            executable = resolvedPath;
          }
        }

        if (Platform.isMacOS) {
          final resolvedExecutable =
              await MacOsApplicationService.resolveExecutable(
                executable,
                applicationName: launchCmd['player_name']?.toString(),
                bundleIdentifierHint: launchCmd['unique_id']?.toString(),
                homePath: ConfigService.getRealHomePath(),
              );
          if (resolvedExecutable != null && resolvedExecutable != executable) {
            _log.i(
              'Resolving macOS application "$executable" to executable: '
              '$resolvedExecutable',
            );
            executable = resolvedExecutable;
          }
        }
      }

      // Last resort on Linux: nothing the database knows about resolved to a
      // real file. Emulators there are Flatpaks, EmuDeck launcher scripts or
      // AppImages rather than binaries sitting next to the frontend, so the
      // bare `executable` from the systems JSON ("retroarch", "dolphin") never
      // exists as written and every launch failed until the user hunted the
      // real path down in a file picker. Only runs when the configured path is
      // already broken, so an explicit user choice is never overridden.
      if (Platform.isLinux && !await File(executable).exists()) {
        final discovered = await LinuxEmulatorDiscovery.resolveExecutable(
          executable: executable,
          flatpakId: launchCmd['flatpak']?.toString(),
          emudeckLauncher: launchCmd['emudeck_launcher']?.toString(),
        );
        if (discovered != null) {
          _log.i(
            'Resolved "$executable" to $discovered via Linux emulator discovery',
          );
          executable = discovered;
        }
      }

      if ((Platform.isWindows || Platform.isLinux || Platform.isMacOS) &&
          !await File(executable).exists()) {
        if (!context.mounted) return GameLaunchResult.failure('', '');
        _log.e('Final check failed: $executable not found');
        return GameLaunchResult.failure(
          AppLocale.executableNotFound.getString(context),
          'Could not find the emulator or game executable at:\n$executable\n\nPlease check your System Settings or Emulator Configuration.',
        );
      }

      final argsStr = launchCmd['args']?.toString() ?? '';
      var args = LauncherService.splitArgs(argsStr);
      var processExecutable = executable;
      var launchedViaOpen = false;

      // The systems JSON names cores by filename alone (`-L snes9x_libretro.so`),
      // which RetroArch resolves against the working directory — ours, not its
      // own. macOS already rewrote these to absolute paths; Linux did not, and
      // there the cores are further away than anywhere a relative lookup could
      // reach (a Flatpak keeps them under ~/.var, a distro under /usr/lib).
      if (Platform.isLinux &&
          executable.toLowerCase().contains('retroarch') &&
          args.contains('-L')) {
        final coresDir = await LinuxEmulatorDiscovery.resolveRetroArchCoresDir(
          executable,
        );
        if (coresDir != null) {
          args = await _absolutizeRetroArchCore(args, coresDir);
        } else {
          _log.w(
            'No RetroArch cores directory found for $executable; passing the '
            'core name through unchanged',
          );
        }
      }

      final env = Map<String, String>.from(Platform.environment);
      if (Platform.isMacOS) {
        env['HOME'] = ConfigService.getRealHomePath();

        // A sandboxed Flutter process passes its sandbox to binaries it starts
        // directly. Ryubing can then read its explicitly selected data folder
        // but cannot open the ROM as a normal macOS application would. Launch
        // it through Launch Services so Ryubing runs with its own app context.
        if (launchCmd['launch_via_open'] == true) {
          final bundlePath = MacOsApplicationService.bundlePathForExecutable(
            executable,
          );
          if (bundlePath != null) {
            processExecutable = '/usr/bin/open';
            args = ['-n', '-a', bundlePath, '--args', ...args];
            launchedViaOpen = true;
          } else {
            _log.w(
              'Could not find the macOS application bundle for $executable; '
              'launching its executable directly',
            );
          }
        }
      }

      final process = await LinuxHostProcess.start(
        processExecutable,
        args,
        environment: env,
      );

      GamepadNavigationManager.deactivateAll();

      // `open` detaches: it exits as soon as Launch Services has started the
      // app, so its exit code says nothing about Ryubing. Skip the exit monitor
      // and the crash diagnostics (which would otherwise attach to `open`); the
      // GameLaunchManager poll ends the session when Ryubing actually exits.
      if (!launchedViaOpen) {
        final diagnostics = EmulatorLaunchDiagnostics.attach(
          process,
          processExecutable,
          args,
        );

        process.exitCode
            .then((exitCode) async {
              _log.i('Process exited with code: $exitCode');
              diagnostics.reportExit(exitCode);
              await Future.delayed(Duration(seconds: 2));
              bool stillRunning = false;
              if (GameSessionManager.launchedEmulatorExe != null) {
                stillRunning = await _isProcessRunning(
                  GameSessionManager.launchedEmulatorExe!,
                );
              }

              if (!stillRunning &&
                  (Platform.isWindows ||
                      Platform.isLinux ||
                      Platform.isMacOS)) {
                GameSessionManager.endGameSession();
              }
            })
            .catchError((err) {
              if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
                GameSessionManager.endGameSession();
              }
            });
      }

      await FavoritesService.recordGamePlayed(game);

      String? launchedExeName;
      if (!executable.toLowerCase().contains('retroarch')) {
        launchedExeName = path.basename(executable);
      }

      GameSessionManager.registerGameLaunch(system, game, launchedExeName);

      return GameLaunchResult.success();
    } catch (e) {
      _log.e('Error launching via config: $e');
      GamepadNavigationManager.reactivate();
      if (!context.mounted) return GameLaunchResult.failure('', '');
      return GameLaunchResult.failure(
        AppLocale.launchFailed.getString(context),
        e.toString(),
      );
    }
  }

  /// Resolves which emulator to auto-select when a game has no per-game
  /// override.
  ///
  /// [EmulatorRepository.getDefaultEmulatorForSystem] returns the *configured*
  /// default, which for many systems is a RetroArch core flagged `is_default`.
  /// That core is frequently not actually installed (the RetroArch app is
  /// present but the specific libretro core isn't), so auto-selecting it yields
  /// a generic "Launch error" on a normal launch (issue #192). We therefore
  /// prefer an installed standalone emulator over a RetroArch-core auto-default
  /// so normal launches work out of the box — matching the manual workaround
  /// users otherwise perform on every game.
  ///
  /// Precedence:
  ///   1. An explicit user default (`is_user_default`) is always honored,
  ///      installed or not — it's a deliberate choice.
  ///   2. Otherwise prefer any positively-installed standalone for the system.
  ///   3. Otherwise the configured default if it looks installed, else any
  ///      installed emulator, else the configured default unchanged (so behavior
  ///      is identical to before when nothing is installed).
  ///
  /// Known, irreducible limitation: a RetroArch core's real install state
  /// cannot be verified on a stock device. Its `.so` lives in RetroArch's
  /// private `0700` data dir, unreadable from our sandbox, and neostation must
  /// never assume/require root — so `isCoreInstalled` fails OPEN (unknown →
  /// treated as installed). Consequently, on a system that has ONLY an
  /// uninstalled RetroArch core and no installed standalone, step 3 can still
  /// return that core and the launch will fail. Step 2 (prefer an installed
  /// standalone) minimizes this but cannot eliminate it without root or an
  /// install-state API RetroArch does not expose.
  static Future<CoreEmulatorModel?> _resolveDefaultInstalledEmulator(
    SystemModel system,
  ) async {
    // 1. Explicit user choice wins outright.
    final userDefault =
        await EmulatorRepository.getUserDefaultEmulatorForSystem(system.id!);
    if (userDefault != null) return userDefault;

    final configured = await EmulatorRepository.getDefaultEmulatorForSystem(
      system.id!,
    );

    List<CoreEmulatorModel> all;
    try {
      all = await loadEmulatorsForSystem(system);
    } catch (_) {
      // Enumeration failed → preserve prior behavior.
      return configured;
    }

    bool isInstalledUid(String? uid) {
      if (uid == null) return false;
      for (final e in all) {
        if (e.uniqueId == uid && e.isInstalled) return true;
      }
      return false;
    }

    // 2. Prefer a genuinely-installed standalone. This is what fixes the
    //    non-rooted case: even when a RetroArch core is (falsely) reported
    //    installed, a real standalone is the reliable choice.
    for (final e in all) {
      if (e.isInstalled && e.isStandalone) return e;
    }

    // 3. Fall back through installed configured default → any installed → raw.
    if (isInstalledUid(configured?.uniqueId)) return configured;
    for (final e in all) {
      if (e.isInstalled) return e;
    }
    return configured;
  }

  /// Logs the raw default-emulator state for [system] under the `[EmuSel]` tag.
  ///
  /// The bugs in this area were all *state* bugs — two emulators flagged as the
  /// system default, or an app default contradicting the user's pick — and they
  /// are invisible in a launch trace that only reports the winner. This prints
  /// the underlying rows so a log alone is enough to diagnose a report.
  static Future<void> _logSystemEmulatorState(SystemModel system) async {
    try {
      // Deliberately `loadEmulatorsForSystem`, the same probe the resolver uses,
      // NOT getEmulatorsForSystemCurrentOs: the latter cannot answer the install
      // question from a database row at all and leaves `isInstalled` false,
      // which would make this dump actively misleading.
      final all = await loadEmulatorsForSystem(system);
      final userDefault =
          await EmulatorRepository.getUserDefaultEmulatorForSystem(system.id!);
      final appDefaults = all.where((e) => e.isDefault).toList();

      _log.i(
        '[EmuSel]   available=${all.length} '
        'userDefault=${userDefault?.uniqueId ?? "<none>"} '
        'appDefaults=${appDefaults.map((e) => e.uniqueId).join(",")}',
      );
      if (appDefaults.length > 1) {
        _log.w(
          '[EmuSel]   anomaly - ${appDefaults.length} app defaults flagged for '
          '${system.folderName}',
        );
      }
      for (final e in all) {
        _log.i(
          '[EmuSel]     - ${e.uniqueId} name="${e.name}" '
          'standalone=${e.isStandalone} installed=${e.isInstalled} '
          'isDefault=${e.isDefault} core=${e.coreFilename ?? "-"} '
          'pkg=${e.androidPackageName ?? "-"}',
        );
      }
    } catch (e) {
      _log.w('[EmuSel] Could not dump emulator state: $e');
    }
  }

  /// Whether [uniqueId] is the emulator that supplies [coreName] for [system].
  ///
  /// Used to tell "we fell back to a core, but it happens to be the very core
  /// the user picked" (fine) from "we fell back to somebody else's core" (a
  /// silent substitution of the user's choice).
  static Future<bool> _emulatorProvidesCore(
    SystemModel system,
    String uniqueId,
    String coreName,
  ) async {
    if (system.id == null) return false;
    try {
      final all = await EmulatorRepository.getEmulatorsForSystemCurrentOs(
        system.id!,
      );
      for (final e in all) {
        if (e.uniqueId != uniqueId) continue;
        final file = e.coreFilename;
        if (file == null || file.isEmpty) return false;
        return file == coreName || _stripLibraryExtension(file) == coreName;
      }
    } catch (e) {
      // Enumeration failed — don't block a launch on a diagnostic check.
      _log.w('Could not verify emulator/core correspondence: $e');
      return true;
    }
    return false;
  }

  /// Strips a platform dynamic-library extension from a core filename.
  static String _stripLibraryExtension(String coreFilename) {
    if (coreFilename.endsWith('.dll')) {
      return coreFilename.substring(0, coreFilename.length - 4);
    }
    if (coreFilename.endsWith('.so')) {
      return coreFilename.substring(0, coreFilename.length - 3);
    }
    return coreFilename;
  }

  /// Resolves the identifier for the core assigned to the given system.
  ///
  /// When [preferredUniqueId] names an emulator that is itself a core, that core
  /// wins: the caller already resolved the user's choice and re-deriving the
  /// system default here would discard it.
  static Future<String?> _getCoreForSystem(
    SystemModel system, {
    String? preferredUniqueId,
  }) async {
    if (preferredUniqueId != null && system.id != null) {
      try {
        final all = await EmulatorRepository.getEmulatorsForSystemCurrentOs(
          system.id!,
        );
        for (final e in all) {
          if (e.uniqueId != preferredUniqueId) continue;
          final file = e.coreFilename;
          if (file == null || file.isEmpty) break;
          return Platform.isAndroid ? file : _stripLibraryExtension(file);
        }
      } catch (e) {
        _log.w('Could not resolve preferred core "$preferredUniqueId": $e');
      }
    }

    final emulator = await EmulatorRepository.getDefaultEmulatorForSystem(
      system.id!,
    );

    if (emulator != null) {
      // `?.` matters: a SQL NULL arrives as Dart null, and `null.toString()`
      // launders it into the string "null", which passes every null check
      // downstream and reaches RetroArch as LIBRETRO="null" — a blank screen
      // with nothing in the log to explain it. Emulators that supply no core of
      // their own (a standalone, a malformed config entry) can hold the system
      // default, so this is a reachable state, not a defensive one.
      final coreFilename = emulator['core_filename']?.toString();

      if (coreFilename == null || coreFilename.isEmpty) {
        _log.e(
          'Default emulator "${emulator['unique_identifier']}" for system '
          '${system.folderName} has no core filename',
        );
        return null;
      }

      return Platform.isAndroid
          ? coreFilename
          : _stripLibraryExtension(coreFilename);
    }

    _log.e('No default emulator found for system ${system.folderName}');
    return null;
  }

  /// Retrieves the user-assigned standalone emulator for a system if applicable.
  ///
  /// [preferredUniqueId] is the emulator the caller already resolved for this
  /// launch (a per-game override or the system default). If it names one of this
  /// system's standalones, it wins outright — re-deriving the default here is
  /// what used to drop the user's choice on the floor when the JSON launch path
  /// declined to handle it.
  static Future<Map<String, dynamic>?> _getStandaloneEmulatorForSystem(
    SystemModel system, {
    String? preferredUniqueId,
  }) async {
    if (system.id == null) return null;

    try {
      final standalones =
          await EmulatorRepository.getStandaloneEmulatorsBySystemId(system.id!);

      if (standalones.isEmpty) {
        return null;
      }

      Map<String, dynamic>? userDefault;
      if (preferredUniqueId != null) {
        for (final standalone in standalones) {
          if (standalone['unique_identifier']?.toString() ==
              preferredUniqueId) {
            userDefault = standalone;
            break;
          }
        }
      }

      if (userDefault == null) {
        for (final standalone in standalones) {
          if (standalone['is_user_default'] == 1) {
            userDefault = standalone;
            break;
          }
        }
      }

      if (userDefault == null) {
        return null;
      }

      if (!Platform.isAndroid) {
        final path = userDefault['emulator_path']?.toString();
        if (path == null || path.isEmpty) {
          return null;
        }

        final file = File(path);
        if (!await file.exists()) {
          return null;
        }
      }

      return userDefault;
    } catch (e) {
      _log.e('Error getting standalone emulator: $e');
      return null;
    }
  }

  /// Internal logic for launching standalone emulators on Android.
  static Future<GameLaunchResult> _launchStandaloneAndroid(
    BuildContext context,
    SystemModel system,
    GameModel game,
    Map<String, dynamic> emulator,
  ) async {
    try {
      final packageName = emulator['android_package_name']?.toString();
      final activityName = emulator['android_activity_name']?.toString();

      if (packageName == null || packageName.isEmpty) {
        _log.e('Missing Android package for standalone emulator');
        return GameLaunchResult.failure(
          AppLocale.emulatorNotConfigured.getString(context),
          'Missing Android package name for ${emulator['name']}',
        );
      }

      if (activityName == null || activityName.isEmpty) {
        _log.w(
          'Standalone emulator ${emulator['name']} has no activity; falling back to package launcher',
        );
      }

      const platform = MethodChannel('com.neogamelab.neostation/game');
      GamepadNavigationManager.reactivate();
      await platform.invokeMethod('setGamepadBlock', {'block': true});

      final romPath = game.romPath!;
      final dataUri =
          romPath.startsWith('content://') || romPath.startsWith('file://')
          ? romPath
          : Uri.file(romPath).toString();

      final result = await platform.invokeMethod('launchGenericIntent', {
        'package': packageName,
        'activity': activityName,
        'action': 'android.intent.action.VIEW',
        'data': dataUri,
        'activity_flags': <String>[],
        'keep_saf_uri': false,
      });

      if (result == true) {
        await FavoritesService.recordGamePlayed(game);
        GameSessionManager.registerGameLaunch(system, game);
        return GameLaunchResult.success();
      } else {
        _log.e('Failed to launch standalone emulator on Android');
        GamepadNavigationManager.reactivate();
        await platform.invokeMethod('setGamepadBlock', {'block': false});
        if (!context.mounted) return GameLaunchResult.failure('', '');
        return GameLaunchResult.failure(
          AppLocale.failedToLaunchStandalone
              .getString(context)
              .replaceFirst('{name}', emulator['name']),
          'The emulator may not be installed or the app is not responding',
        );
      }
    } catch (e) {
      _log.e('Error launching standalone emulator on Android: $e');
      GamepadNavigationManager.reactivate();
      const platform = MethodChannel('com.neogamelab.neostation/game');
      await platform.invokeMethod('setGamepadBlock', {'block': false});
      if (!context.mounted) return GameLaunchResult.failure('', '');

      if (e is PlatformException) {
        return GameLaunchResult.failure(
          e.message ?? 'Platform error',
          'Code: ${e.code}\nDetails: ${e.details}',
        );
      }
      return GameLaunchResult.failure(
        AppLocale.launchFailed.getString(context),
        e.toString(),
      );
    }
  }

  /// Internal logic for launching standalone emulators on Desktop.
  static Future<GameLaunchResult> _launchStandaloneDesktop(
    BuildContext context,
    SystemModel system,
    GameModel game,
    Map<String, dynamic> emulator,
  ) async {
    try {
      final emulatorPath = emulator['emulator_path']?.toString();
      final launchArgs =
          emulator['launch_arguments']?.toString() ?? '"{rom_path}"';

      if (emulatorPath == null || emulatorPath.isEmpty) {
        _log.e('Emulator path not configured');
        return GameLaunchResult.failure(
          AppLocale.emulatorNotConfigured.getString(context),
          'Path not set for ${emulator['name']}',
        );
      }

      final emulatorFile = File(emulatorPath);
      if (!await emulatorFile.exists()) {
        if (!context.mounted) return GameLaunchResult.failure('', '');
        _log.e('Emulator not found: $emulatorPath');
        return GameLaunchResult.failure(
          AppLocale.executableNotFound.getString(context),
          'Path: $emulatorPath',
        );
      }

      final romPath = game.romPath!;
      final args = launchArgs
          .replaceAll('{rom_path}', romPath)
          .replaceAll('{emulator_path}', emulatorPath);

      final argList = _parseCommandArguments(args);
      final process = await LinuxHostProcess.start(emulatorPath, argList);

      final diagnostics = EmulatorLaunchDiagnostics.attach(
        process,
        emulatorPath,
        argList,
      );

      GamepadNavigationManager.deactivateAll();

      process.exitCode
          .then((exitCode) async {
            _log.i('Standalone emulator exited with code: $exitCode');
            diagnostics.reportExit(exitCode);
            await Future.delayed(Duration(seconds: 2));
            bool stillRunning = false;
            if (GameSessionManager.launchedEmulatorExe != null) {
              stillRunning = await _isProcessRunning(
                GameSessionManager.launchedEmulatorExe!,
              );
            }

            if (!stillRunning &&
                (Platform.isWindows || Platform.isLinux || Platform.isMacOS)) {
              GameSessionManager.endGameSession();
            }
          })
          .catchError((error) {
            _log.e('Error monitoring standalone emulator: $error');
            if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
              GameSessionManager.endGameSession();
            }
          });

      final exeName = path.basename(emulatorPath);
      GameSessionManager.registerGameLaunch(system, game, exeName);
      await FavoritesService.recordGamePlayed(game);

      return GameLaunchResult.success();
    } catch (e) {
      _log.e('Error launching standalone emulator: $e');
      GamepadNavigationManager.reactivate();
      if (!context.mounted) return GameLaunchResult.failure('', '');
      return GameLaunchResult.failure(
        AppLocale.failedToLaunchStandalone
            .getString(context)
            .replaceFirst('{name}', emulator['name']),
        e.toString(),
      );
    }
  }

  /// Parses a command-line argument string into an Android Intent extras map.
  /// Resolves the concrete RetroArch package variant for a JSON launch.
  ///
  /// The system JSON hardcodes the base `com.retroarch` package, but the user
  /// may have a different variant installed (e.g. `com.retroarch.aarch64`),
  /// stored on their default emulator record. All RetroArch variants share the
  /// same launch activity, so only the package and the `CONFIGFILE` extra's
  /// path need patching — substituting a *standalone* emulator's package here
  /// would instead produce an unresolvable intent (standalone package +
  /// RetroArch activity → ActivityNotFound), so the substitution is gated on
  /// the default emulator itself being a RetroArch variant.
  ///
  /// Returns the package to launch and mutates [extras] in place. For non-
  /// RetroArch intents it returns [package] unchanged and leaves [extras] alone.
  static Future<String> _resolveRetroArchVariant(
    String package,
    List<Map<String, dynamic>> extras,
    SystemModel system,
  ) async {
    if (!package.startsWith(CoreEmulatorModel.retroArchPackagePrefix)) {
      return package;
    }

    var resolved = package;
    try {
      final defaultEmu = await EmulatorRepository.getDefaultEmulatorForSystem(
        system.id!,
      );
      if (defaultEmu != null && defaultEmu.isRetroArch) {
        final candidate = defaultEmu.androidPackageName!;
        // Substitute only a variant that is actually installed. `is_default`
        // records which variant was *configured*, not which one exists, and
        // trusting it blindly is how a launch gets addressed to a RetroArch
        // build the user never had.
        if (await EmulatorRepository.isRetroArchVariantInstalled(candidate)) {
          resolved = candidate;
        } else {
          _log.w(
            'Android: Configured RetroArch variant "$candidate" is not '
            'installed; keeping "$package"',
          );
        }
      }
    } catch (e) {
      _log.e('Error resolving RetroArch package variant: $e');
    }

    // Point the RetroArch CONFIGFILE extra at the resolved variant's config
    // directory (only the non-base variants live under their own package dir).
    if (resolved != CoreEmulatorModel.retroArchPackagePrefix) {
      for (final extra in extras) {
        if (extra['key'] == 'CONFIGFILE') {
          final currentPath = extra['value'].toString();
          if (currentPath.contains('/com.retroarch/')) {
            extra['value'] = currentPath.replaceAll(
              '/com.retroarch/',
              '/$resolved/',
            );
          }
        }
      }
    }

    return resolved;
  }

  static Map<String, dynamic> _parseArgsToExtras(String argsStr) {
    if (argsStr.isEmpty) return {};

    final extras = <String, dynamic>{};
    final args = _parseCommandArguments(argsStr);

    for (int i = 0; i < args.length; i++) {
      final arg = args[i];
      if (arg == '-e' || arg == '--es') {
        if (i + 2 < args.length) {
          extras[args[i + 1]] = args[i + 2];
          i += 2;
        }
      } else if (arg == '--ez') {
        if (i + 2 < args.length) {
          extras[args[i + 1]] = args[i + 2] == 'true' || args[i + 2] == '1';
          i += 2;
        }
      } else if (arg == '--ei') {
        if (i + 2 < args.length) {
          extras[args[i + 1]] = int.tryParse(args[i + 2]) ?? 0;
          i += 2;
        }
      } else if (arg == '--esa') {
        if (i + 2 < args.length) {
          extras[args[i + 1]] = args[i + 2]
              .split(',')
              .map((e) => e.trim())
              .toList();
          i += 2;
        }
      }
    }
    return extras;
  }

  /// Tokenizes a command string into discrete arguments, respecting double quotes.
  static List<String> _parseCommandArguments(String args) {
    final List<String> result = [];
    final buffer = StringBuffer();
    bool inQuotes = false;

    for (int i = 0; i < args.length; i++) {
      final char = args[i];

      if (char == '"') {
        inQuotes = !inQuotes;
      } else if (char == ' ' && !inQuotes) {
        if (buffer.isNotEmpty) {
          result.add(buffer.toString());
          buffer.clear();
        }
      } else {
        buffer.write(char);
      }
    }

    if (buffer.isNotEmpty) {
      result.add(buffer.toString());
    }

    return result;
  }

  /// Rewrites a relative `-L <core>` argument to an absolute path in [coresDir].
  ///
  /// Leaves the value alone when it is already absolute, and when the file is
  /// not actually in [coresDir] — a wrong absolute path turns RetroArch's own
  /// "core not found" message into a silent black screen, so an unresolvable
  /// name is better left for RetroArch to report.
  @visibleForTesting
  static Future<List<String>> absolutizeRetroArchCore(
    List<String> args,
    String coresDir,
  ) => _absolutizeRetroArchCore(args, coresDir);

  static Future<List<String>> _absolutizeRetroArchCore(
    List<String> args,
    String coresDir,
  ) async {
    final out = List<String>.from(args);
    for (var i = 0; i < out.length - 1; i++) {
      if (out[i] != '-L') continue;

      final core = out[i + 1];
      if (core.isEmpty || path.isAbsolute(core)) continue;

      // Some entries write `cores/foo_libretro.so`; only the filename is ours
      // to relocate.
      final resolved = path.join(coresDir, path.basename(core));
      if (await File(resolved).exists()) {
        out[i + 1] = resolved;
      } else {
        _log.w('RetroArch core "$core" not found in $coresDir');
      }
    }
    return out;
  }

  /// Resolves the absolute path for a specific RetroArch core library.
  static Future<String?> _getCoreFullPath(String coreName) async {
    try {
      final detectedEmulators =
          await EmulatorRepository.getUserDetectedEmulators();
      final retroArch = detectedEmulators['RetroArch'];
      if (retroArch == null) return null;

      final coresDir = await _getRetroArchCoresDirectory(retroArch);

      String fullCoreName;
      if (Platform.isWindows) {
        if (coreName.endsWith('.dll')) {
          fullCoreName = coreName;
        } else if (coreName.endsWith('_libretro')) {
          fullCoreName = '$coreName.dll';
        } else {
          fullCoreName = '${coreName}_libretro.dll';
        }
      } else if (Platform.isMacOS) {
        if (coreName.endsWith('.dylib')) {
          fullCoreName = coreName;
        } else if (coreName.endsWith('_libretro')) {
          fullCoreName = '$coreName.dylib';
        } else {
          fullCoreName = '${coreName}_libretro.dylib';
        }
      } else if (Platform.isAndroid) {
        if (coreName.endsWith('.so')) {
          fullCoreName = coreName;
        } else {
          if (coreName.contains('_android')) {
            fullCoreName = '$coreName.so';
          } else if (coreName.endsWith('_libretro')) {
            fullCoreName = '${coreName}_android.so';
          } else {
            fullCoreName = '${coreName}_libretro_android.so';
          }
        }
      } else {
        if (coreName.endsWith('.so')) {
          fullCoreName = coreName;
        } else if (coreName.endsWith('_libretro')) {
          fullCoreName = '$coreName.so';
        } else {
          fullCoreName = '${coreName}_libretro.so';
        }
      }

      final corePath = path.join(coresDir, fullCoreName);

      if (await File(corePath).exists()) {
        return corePath;
      } else {
        return null;
      }
    } catch (e) {
      _log.e('Error getting core path: $e');
      return null;
    }
  }

  /// Resolves the optimal directory for RetroArch cores based on the platform and installation type.
  ///
  /// Supports Flatpak, AppImage, and standard installation discovery on Linux.
  static Future<String> _getRetroArchCoresDirectory(
    EmulatorModel retroArch,
  ) async {
    final retroArchDir = path.dirname(retroArch.path);

    if (Platform.isLinux) {
      // Cores are almost never beside the executable here, and the install type
      // is not readable from the path: an EmuDeck launcher script is a
      // `flatpak run` wrapper but looks like a plain shell script, so the old
      // `path.contains('flatpak')` test missed it and sent the launch at a
      // cores directory that does not exist. Probe the known layouts instead.
      final resolved = await LinuxEmulatorDiscovery.resolveRetroArchCoresDir(
        retroArch.path,
      );
      if (resolved != null) return resolved;

      // Nothing exists yet; hand back the most likely location so the caller's
      // "cores directory not found" message names somewhere actionable.
      return LinuxEmulatorDiscovery.retroArchCoresDirCandidates(
        retroArch.path,
      ).first;
    } else if (Platform.isMacOS) {
      final homeDir = ConfigService.getRealHomePath();
      return path.join(homeDir, 'Library/Application Support/RetroArch/cores');
    } else {
      return path.join(retroArchDir, 'cores');
    }
  }

  /// Checks if the default emulator (RetroArch) is currently running on the host system.
  static Future<bool> _isDefaultEmulatorRunning() async {
    if (Platform.isWindows) return await _isProcessRunning('retroarch.exe');
    if (Platform.isLinux || Platform.isMacOS) {
      return await _isProcessRunningUnix('retroarch');
    }
    return false;
  }

  /// Checks for a running process on Windows using the tasklist command.
  ///
  /// CSV output is not cosmetic. `tasklist`'s default table format renders the
  /// image name in a fixed 25-character column and silently truncates anything
  /// longer, so reading the full name back out of it is impossible. DuckStation
  /// ships as `duckstation-qt-x64-ReleaseLTCG.exe` (34 characters) and tasklist
  /// printed it as `duckstation-qt-x64-Releas`: the filter matched and the row
  /// came back, but the substring test against the full name did not, so a
  /// running emulator was reported as gone. [GameLaunchManager]'s poll then
  /// declared the session over ~2s after launch, which closed the launch dialog
  /// and handed the controller back to the UI while the game was still on
  /// screen — every D-pad press navigated NeoStation behind the emulator and
  /// every A press launched another game. `/FO CSV` quotes the name in full.
  static Future<bool> _isProcessRunning(String processName) async {
    if (!Platform.isWindows) return false;

    try {
      final result = await Process.run('tasklist', [
        '/FI',
        'IMAGENAME eq $processName',
        '/NH',
        '/FO',
        'CSV',
      ]);
      return csvListsProcess(result.stdout.toString(), processName);
    } catch (e) {
      _log.e('Error checking if $processName is running: $e');
      return false;
    }
  }

  /// Whether [output] from `tasklist /FO CSV` lists [processName] as running.
  ///
  /// Only the first CSV field — the image name — is compared, and it must match
  /// in full. Searching the whole line would match a name appearing in another
  /// column, and would also match the `INFO: No tasks are running which match
  /// the specified criteria.` notice that tasklist prints on stdout whenever
  /// the filter selects nothing (that notice echoes no name today, but reading
  /// only the field we mean costs nothing and cannot be surprised).
  @visibleForTesting
  static bool csvListsProcess(String output, String processName) {
    final target = processName.toLowerCase();

    for (final line in output.split(RegExp(r'\r?\n'))) {
      final row = line.trim();
      // Every data row is quoted; anything else is a notice, not a process.
      if (!row.startsWith('"')) continue;

      final closingQuote = row.indexOf('"', 1);
      if (closingQuote <= 1) continue;

      if (row.substring(1, closingQuote).toLowerCase() == target) return true;
    }

    return false;
  }

  /// Checks for a running process on Unix-like systems using the pgrep command.
  static Future<bool> _isProcessRunningUnix(String processName) async {
    if (!Platform.isLinux && !Platform.isMacOS) return false;

    try {
      // On the host, because a sandbox has its own PID namespace and would see
      // none of the emulators it started.
      final result = await LinuxHostProcess.run('pgrep', [
        '-i',
        '-f',
        processName,
      ]);
      return result.exitCode == 0;
    } catch (e) {
      _log.e('Error checking if $processName is running (unix): $e');
      return false;
    }
  }

  /// Handles application re-entry (foregrounding) to detect session termination.
  static Future<void> handleAppResumed() async {
    if (GameSessionManager.isGameLaunched) {
      if (Platform.isLinux) return;

      final isDesktop =
          Platform.isWindows || Platform.isLinux || Platform.isMacOS;
      final gracePeriod = isDesktop ? 10 : 2;
      final timeSinceLaunch = DateTime.now().difference(
        GameSessionManager.gameLaunchTime!,
      );

      if (timeSinceLaunch.inSeconds > gracePeriod) {
        bool emulatorStillRunning = false;

        if (GameSessionManager.launchedEmulatorExe != null) {
          emulatorStillRunning = await _isProcessRunning(
            GameSessionManager.launchedEmulatorExe!,
          );
        } else {
          emulatorStillRunning = await _isDefaultEmulatorRunning();
        }

        if (!emulatorStillRunning) {
          _log.i(
            'GameService: Emulator process not detected after grace period. Ending session.',
          );
          await GameSessionManager.endGameSession();
        }
      }
    } else {
      GamepadNavigationManager.reactivate();
    }
  }

  /// High-level emulator status check.
  static Future<bool> isEmulatorRunning([String? processName]) async {
    if (processName != null) return await isProcessRunning(processName);
    return await _isDefaultEmulatorRunning();
  }

  /// Verifies if a process is running on desktop platforms.
  static Future<bool> isProcessRunning(String processName) async {
    if (Platform.isWindows) return await _isProcessRunning(processName);
    if (Platform.isLinux || Platform.isMacOS) {
      final unixName = processName.replaceAll(
        RegExp(r'\.exe$', caseSensitive: false),
        '',
      );
      return await _isProcessRunningUnix(unixName);
    }
    return false;
  }
}
