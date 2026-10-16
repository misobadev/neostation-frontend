import '../constants/system_folder_names.dart';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
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

      // Asked once rather than per system: it is a property of the cache as a
      // whole, and it costs a database read.
      final preferBundledPolicy =
          !await SystemsUpdateService.cacheIsNewerThanBundle();

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

            // The hashing policy names algorithms implemented in this binary,
            // so it is resolved separately from the rest of the definition —
            // see [resolveRaHashPolicy].
            final raHash = resolveRaHashPolicy(
              cached: systemData['ra_hash'],
              bundled: cachedPath != null && bundledFileNames.contains(fileName)
                  ? await bundledRaHash(fileName)
                  : null,
              preferBundled: preferBundledPolicy,
            );

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
              'raHashAlgo': raHash?['algo'],
              'raHashMode': raHash?['mode'],
              'iconImage':
                  'assets/images/systems/${SystemFolderNames.artFolderName(systemData['id'].toString())}-icon.png',
              'backgroundImage':
                  'assets/images/systems/${SystemFolderNames.artFolderName(systemData['id'].toString())}-bg.jpg',
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
              'multidisc': systemData['multidisc'] ?? false,
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

  /// Decides which copy of a system's `ra_hash` block to believe.
  ///
  /// Every other field describes the system — its folders, extensions, launch
  /// arguments — and a downloaded definition is the newer statement about
  /// those. The hashing policy is different: it names algorithms implemented in
  /// this binary, so the copy that shipped with the binary is the one that
  /// agrees with it.
  ///
  /// Hence the rule: the newer generation wins, and a tie goes to the bundle.
  /// A tie is the steady state — after any systems update, the cached version
  /// equals the version the next app release bundles, because the remote
  /// manifest *is* the bundled one — so preferring the cache there would mean a
  /// corrected algorithm never reached anyone who had ever taken an update.
  /// That is not hypothetical: it is how the disc policies failed to arrive on
  /// a device that already had a cache.
  ///
  /// A genuinely newer cache still wins, which is what keeps a policy fix
  /// shippable as data rather than as a release.
  @visibleForTesting
  static Map<String, dynamic>? resolveRaHashPolicy({
    required Object? cached,
    required Map<String, dynamic>? bundled,
    required bool preferBundled,
  }) {
    final cachedPolicy = cached is Map<String, dynamic> ? cached : null;
    return preferBundled
        ? (bundled ?? cachedPolicy)
        : (cachedPolicy ?? bundled);
  }

  /// Reads just the `ra_hash` block from the *bundled* copy of [fileName].
  ///
  /// Used when a cached definition predates the hashing policy. Returns null if
  /// the bundled copy has none either, in which case the system genuinely
  /// declares no policy and gets the permissive default.
  @visibleForTesting
  Future<Map<String, dynamic>?> bundledRaHash(String fileName) async {
    try {
      final content = await rootBundle.loadString('assets/systems/$fileName');
      final jsonMap = json.decode(content) as Map<String, dynamic>;
      final raHash = (jsonMap['system'] as Map?)?['ra_hash'];
      return raHash is Map<String, dynamic> ? raHash : null;
    } catch (e) {
      _log.w('Could not read bundled ra_hash for $fileName: $e');
      return null;
    }
  }

  int _generateId(String id) => id.hashCode;
}
