import 'dart:convert';
import 'dart:io';
import 'package:flutter/services.dart';
import '../models/system_model.dart';
import '../models/game_model.dart';
import 'logger_service.dart';
import 'config_service.dart';
import 'systems_update_service.dart';

/// Service responsible for mapping system and game metadata to platform-specific
/// launch commands and intent arguments.
///
/// Leverages external JSON configuration files to support a wide variety of
/// emulators and native applications across Android, Windows, Linux, and macOS.
class LauncherService {
  static final LauncherService _instance = LauncherService._internal();
  static LauncherService get instance => _instance;

  /// Cached system configurations keyed by system folder name.
  final Map<String, Map<String, dynamic>> _configs = {};

  LauncherService._internal();

  /// Loads a system-specific JSON configuration from the application assets.
  ///
  /// Returns true if the configuration was successfully loaded and cached.
  Future<bool> loadSystemConfig(String jsonFileName) async {
    try {
      // Prefer locally cached version downloaded from GitHub (newer than bundled).
      String jsonString;
      final cachedPath = await SystemsUpdateService.getCachedSystemPath(jsonFileName);
      if (cachedPath != null) {
        jsonString = await File(cachedPath).readAsString();
      } else {
        jsonString = await rootBundle.loadString('assets/systems/$jsonFileName');
      }
      final config = jsonDecode(jsonString) as Map<String, dynamic>;

      final systemId = config['system']['id'].toString();
      _configs[systemId] = config;

      LoggerService.instance.log(
        'Loaded configuration for $systemId',
        level: LogLevel.debug,
      );
      return true;
    } catch (e) {
      LoggerService.instance.log(
        'Could not load config $jsonFileName (might not exist)',
        level: LogLevel.debug,
        error: e,
      );
      return false;
    }
  }

  /// Retrieves the detailed configuration for a specific player (emulator)
  /// within a system.
  Map<String, dynamic>? getPlayerConfig(String systemId, String uniqueId) {
    final config = _configs[systemId];
    if (config == null) return null;

    final List players =
        (config['emulators'] ?? config['players'] ?? []) as List;
    return players.firstWhere(
      (p) => p['unique_id'] == uniqueId,
      orElse: () => null,
    );
  }

  /// Generates a comprehensive launch command or intent specification for a game.
  ///
  /// Resolves placeholders, platform-specific arguments, and Android intent
  /// extras based on the preferred player (emulator).
  ///
  /// Returns a map containing keys such as 'executable', 'args', 'package',
  /// 'activity', 'data', and 'extras'.
  Map<String, dynamic> getLaunchCommand(
    SystemModel system,
    GameModel game,
    String? preferredPlayerId,
  ) {
    Map<String, dynamic>? config = _configs[system.folderName];

    if (config == null) {
      for (final c in _configs.values) {
        if (c['system']['id'] == system.folderName) {
          config = c;
          break;
        }
      }
    }

    if (config == null) {
      LoggerService.instance.log(
        'No configuration loaded for ${system.folderName}',
        level: LogLevel.warning,
      );
      return {};
    }

    final List players =
        (config['emulators'] ?? config['players'] ?? []) as List;
    if (players.isEmpty) return {};

    Map<String, dynamic>? player;
    if (preferredPlayerId != null) {
      player = players.firstWhere(
        (p) => p['unique_id'] == preferredPlayerId,
        orElse: () => null,
      );

      player ??= players.firstWhere(
        (p) => p['name'] == preferredPlayerId,
        orElse: () => null,
      );
    }

    player ??= players.first;

    final platforms = player!['platforms'] as Map<String, dynamic>?;
    if (platforms == null) return {};

    Map<String, dynamic>? platformConfig;
    if (Platform.isAndroid) {
      platformConfig = platforms['android'];
    } else if (Platform.isWindows) {
      platformConfig = platforms['windows'];
    } else if (Platform.isMacOS) {
      platformConfig = platforms['macos'];
    } else if (Platform.isLinux) {
      platformConfig = platforms['linux'];
    }

    if (platformConfig == null) {
      LoggerService.instance.log(
        'No config for this platform in player ${player['name']}',
        level: LogLevel.warning,
      );
      return {};
    }

    final result = <String, dynamic>{'player_name': player['name']};

    if (Platform.isAndroid) {
      if (platformConfig.containsKey('launch_arguments')) {
        final args = platformConfig['launch_arguments'].toString();
        final parsed = _parseLaunchArguments(args);

        result.addAll(parsed);

        if (result.containsKey('data')) {
          result['data'] = resolvePlaceholdersAndroid(result['data'], game);
        }

        if (result.containsKey('extras')) {
          final extras = result['extras'] as List;
          for (var i = 0; i < extras.length; i++) {
            final extra = extras[i] as Map<String, dynamic>;
            final rawValue = extra['value'].toString();
            final resolvedValue = resolvePlaceholdersAndroid(rawValue, game);

            extra['value'] = resolvedValue;
          }
        }
      } else {
        result['package'] = platformConfig['package'];
        if (platformConfig.containsKey('activity')) {
          result['activity'] = platformConfig['activity'];
        }
        if (platformConfig.containsKey('action')) {
          result['action'] = platformConfig['action'];
        }
        if (platformConfig.containsKey('category')) {
          result['category'] = platformConfig['category'];
        }
        if (platformConfig.containsKey('type')) {
          result['type'] = platformConfig['type'];
        }

        if (platformConfig.containsKey('data')) {
          result['data'] = resolvePlaceholdersAndroid(
            platformConfig['data'],
            game,
          );
        }

        if (platformConfig.containsKey('extras')) {
          final extrasObj = platformConfig['extras'];
          if (extrasObj is List) {
            final resolvedExtras = extrasObj.map((e) {
              final map = e as Map<String, dynamic>;
              final val = map['value'].toString();
              return {
                'key': map['key'],
                'value': resolvePlaceholdersAndroid(val, game),
                'type': map['type'] ?? 'string',
              };
            }).toList();
            result['extras'] = resolvedExtras;
          }
        }
      }
    } else {
      if (platformConfig.containsKey('executable')) {
        result['executable'] = platformConfig['executable'];
      }

      if (player.containsKey('unique_id')) {
        result['unique_id'] = player['unique_id'];
      }

      final rawArgs = platformConfig['args']?.toString() ?? '';
      var resolvedArgs = resolvePlaceholdersDesktop(rawArgs, game);

      if (Platform.isMacOS &&
          (result['executable']?.toString())?.toLowerCase().contains(
                'retroarch',
              ) ==
              true) {
        final home = ConfigService.getRealHomePath();

        if (home.isNotEmpty) {
          final corePath = '$home/Library/Application Support/RetroArch/cores/';
          final coreRegex = RegExp(r'-L\s+(?:cores[\\/])?([\w\-\.]+\.dylib)');

          if (coreRegex.hasMatch(resolvedArgs)) {
            resolvedArgs = resolvedArgs.replaceAllMapped(
              coreRegex,
              (match) => '-L "$corePath${match.group(1)}"',
            );
          }
        }
      }

      result['args'] = resolvedArgs;
    }

    return result;
  }

  /// Tokenizes a command line argument string into an Android Intent extras map.
  ///
  /// Supports common flags used in frontend launchers like `-n`, `-a`, `-d`,
  /// and type-specific extras (`--es`, `--ez`, `--ei`, etc.).
  Map<String, dynamic> _parseLaunchArguments(String args) {
    final result = <String, dynamic>{'extras': <Map<String, dynamic>>[]};
    final parts = splitArgs(args);

    for (int i = 0; i < parts.length; i++) {
      final part = parts[i];

      if (part == '-n' && i + 1 < parts.length) {
        final component = parts[++i];
        final split = component.split('/');
        result['package'] = split[0];
        if (split.length > 1) {
          var activity = split[1];
          if (activity.startsWith('.')) {
            activity = '${split[0]}$activity';
          }
          result['activity'] = activity;
        }
      } else if (part == '-a' && i + 1 < parts.length) {
        result['action'] = parts[++i];
      } else if (part == '-d' && i + 1 < parts.length) {
        result['data'] = parts[++i];
      } else if (part == '-t' && i + 1 < parts.length) {
        result['type'] = parts[++i];
      } else if (part == '-c' && i + 1 < parts.length) {
        result['category'] = parts[++i];
      } else if ((part == '--es' || part == '-e') && i + 2 < parts.length) {
        (result['extras'] as List).add({
          'key': parts[++i],
          'value': parts[++i],
          'type': 'string',
        });
      } else if (part == '--ez' && i + 2 < parts.length) {
        (result['extras'] as List).add({
          'key': parts[++i],
          'value': parts[++i],
          'type': 'bool',
        });
      } else if (part == '--ei' && i + 2 < parts.length) {
        (result['extras'] as List).add({
          'key': parts[++i],
          'value': parts[++i],
          'type': 'int',
        });
      } else if (part == '--el' && i + 2 < parts.length) {
        (result['extras'] as List).add({
          'key': parts[++i],
          'value': parts[++i],
          'type': 'long',
        });
      } else if (part == '--ef' && i + 2 < parts.length) {
        (result['extras'] as List).add({
          'key': parts[++i],
          'value': parts[++i],
          'type': 'float',
        });
      } else if (part == '--esa' && i + 2 < parts.length) {
        (result['extras'] as List).add({
          'key': parts[++i],
          'value': parts[++i],
          'type': 'string_array',
        });
      } else if (part.startsWith('--activity-')) {
        final flagName = part.substring('--activity-'.length);
        if (result['activity_flags'] == null) {
          result['activity_flags'] = <String>[];
        }
        (result['activity_flags'] as List<String>).add(flagName);
      }
    }
    return result;
  }

  /// Splits a command line string into a list of discrete arguments, respecting
  /// double quotes.
  static List<String> splitArgs(String args) {
    final List<String> result = [];
    final regex = RegExp(r'[^\s"]+|"([^"]*)"');
    final matches = regex.allMatches(args);
    for (final match in matches) {
      if (match.group(1) != null) {
        result.add(match.group(1)!);
      } else {
        result.add(match.group(0)!);
      }
    }
    return result;
  }

  /// Replaces placeholders in Android-specific launch templates with game data.
  ///
  /// Supported placeholders: `{file.path}`, `{file.uri}`, and specialized tags
  /// like `{tags.steamappid}`.
  String resolvePlaceholdersAndroid(String template, GameModel game) {
    if (template.isEmpty) return template;

    String result = template;
    if (game.romPath != null) {
      final String romPath = game.romPath!;
      result = result.replaceAll('{file.path}', romPath);

      // SAF content:// URIs and file:// URIs pass through as-is.
      // Only convert bare filesystem paths to file:// scheme.
      final String uri =
          (romPath.startsWith('content://') || romPath.startsWith('file://'))
              ? romPath
              : Uri.file(romPath).toString();
      result = result.replaceAll('{file.uri}', uri);

      if (game.titleId != null) {
        result = result.replaceAll('{tags.steamappid}', game.titleId!);
        result = result.replaceAll('{tags.localgameid}', game.titleId!);
        result = result.replaceAll('{tags.vita_game_id}', game.titleId!);
      }
    }
    return result;
  }

  /// Replaces placeholders in desktop launch templates with game data.
  ///
  /// Automatically applies quotes to paths containing spaces unless they are
  /// already quoted in the template.
  String resolvePlaceholdersDesktop(String template, GameModel game) {
    if (template.isEmpty) return template;

    String result = template;
    if (game.romPath != null) {
      if (game.romPath!.contains(' ') && !template.contains('"{file.path}"')) {
        result = result.replaceAll('{file.path}', '"${game.romPath!}"');
      } else {
        result = result.replaceAll('{file.path}', game.romPath!);
      }

      final uri = Uri.file(game.romPath!).toString();
      result = result.replaceAll('{file.uri}', uri);

      if (game.titleId != null) {
        result = result.replaceAll('{tags.vita_game_id}', game.titleId!);
      }
    }
    return result;
  }
}
