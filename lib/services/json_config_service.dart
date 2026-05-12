import 'dart:convert';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:neostation/services/logger_service.dart';
import 'package:neostation/services/systems_update_service.dart';
import 'package:path/path.dart' as p;
import '../models/system_model.dart';
import '../models/system_configuration.dart';

/// Service responsible for loading and parsing system configuration JSON files.
///
/// Prefers locally cached files downloaded via [SystemsUpdateService] over
/// the bundled assets, and merges any new systems introduced by updates.
class JsonConfigService {
  static final JsonConfigService _instance = JsonConfigService._internal();
  static JsonConfigService get instance => _instance;
  JsonConfigService._internal();

  static final _log = LoggerService.instance;

  /// Loads all system configurations, preferring cached (updated) versions
  /// over bundled assets. Also picks up new systems added by remote updates.
  Future<List<SystemConfiguration>> loadSystems() async {
    try {
      final manifest = await AssetManifest.loadFromAssetBundle(rootBundle);

      final bundledFiles = manifest
          .listAssets()
          .where(
            (key) => key.startsWith('assets/systems/') && key.endsWith('.json'),
          )
          .toList();

      final bundledFileNames = bundledFiles.map((f) => p.basename(f)).toSet();

      // Discover extra files in the cache not present in the bundle.
      final cachedOnlyFileNames = <String>{};
      try {
        final cacheDir = Directory(await SystemsUpdateService.getCacheDir());
        if (await cacheDir.exists()) {
          await for (final entity in cacheDir.list()) {
            if (entity is File && entity.path.endsWith('.json')) {
              final name = p.basename(entity.path);
              if (!bundledFileNames.contains(name)) {
                cachedOnlyFileNames.add(name);
              }
            }
          }
        }
      } catch (e) {
        _log.w('JsonConfigService: error scanning cache dir: $e');
      }

      final allFileNames = {...bundledFileNames, ...cachedOnlyFileNames};
      final List<SystemConfiguration> systems = [];

      for (final fileName in allFileNames) {
        try {
          final String content;
          final cachedPath = await SystemsUpdateService.getCachedSystemPath(
            fileName,
          );
          if (cachedPath != null) {
            content = await File(cachedPath).readAsString();
          } else {
            content = await rootBundle.loadString('assets/systems/$fileName');
          }

          final Map<String, dynamic> jsonMap = json.decode(content);

          if (jsonMap.containsKey('system')) {
            final systemData = jsonMap['system'];

            final flatMap = <String, dynamic>{
              'id': _generateId(systemData['id']),
              'folderName': systemData['id'],
              'realName': systemData['name'],
              'shortName': systemData['short_name'],
              'launchDate': systemData['details']?['release_date'],
              'description': systemData['details']?['description'],
              'manufacturer': systemData['details']?['manufacturer'],
              'type': systemData['details']?['type'],
              'screenscraperId': systemData['ids']?['screenscraper'],
              'raId': systemData['ids']?['retroachievements'],
              'iconImage': 'assets/images/systems/${systemData['id']}-icon.png',
              'backgroundImage':
                  'assets/images/systems/${systemData['id']}-bg.jpg',
              'color1':
                  (systemData['colors'] is List &&
                      (systemData['colors'] as List).isNotEmpty)
                  ? systemData['colors'][0].toString()
                  : null,
              'color2':
                  (systemData['colors'] is List &&
                      (systemData['colors'] as List).length > 1)
                  ? systemData['colors'][1].toString()
                  : null,
              'extensions': systemData['extensions'] ?? [],
              'folders': systemData['folders'] ?? [],
              'neosync': jsonMap['neosync'],
            };

            final systemModel = SystemModel.fromJson(flatMap);

            List<EmulatorDefinition> emulators = [];
            final emulatorsKey = jsonMap.containsKey('emulators')
                ? 'emulators'
                : (jsonMap.containsKey('players') ? 'players' : null);

            if (emulatorsKey != null) {
              final playersList = jsonMap[emulatorsKey] as List;
              emulators = playersList
                  .map((e) => EmulatorDefinition.fromJson(e))
                  .toList();
            }

            systems.add(
              SystemConfiguration(system: systemModel, emulators: emulators),
            );
          }
        } catch (e) {
          _log.e('Error parsing system JSON $fileName: $e');
        }
      }

      return systems;
    } catch (e) {
      _log.e('Error loading system configurations: $e');
      return [];
    }
  }

  int _generateId(String id) => id.hashCode;
}
