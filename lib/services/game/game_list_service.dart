import 'package:path/path.dart' as path;
import 'package:neostation/services/logger_service.dart';

import '../../models/game_model.dart';
import '../../models/database_game_model.dart';
import '../../models/system_model.dart';
import '../../repositories/game_repository.dart';
import '../collections/smart_collections_service.dart';
import '../../repositories/system_repository.dart';
import '../../constants/system_folder_names.dart';

/// Loads game lists/details and resolves their display names.
///
/// Owns the read side of the game catalogue: pulling [DatabaseGameModel]s from
/// the repositories, applying per-system naming preferences (extension/tag
/// stripping, scraped-title coalescing) via [_resolveListDisplayName], and
/// mapping them to UI [GameModel]s. Also the small pure list utilities
/// ([groupGamesByGenre]/[getFavoriteGames]/[getRecentlyPlayedGames]). Extracted
/// verbatim from [GameService], which now delegates its list/detail methods
/// here. Stateless aside from the shared logger and the name-cleanup regexes.
class GameListService {
  GameListService._();

  static final _log = LoggerService.instance;

  static final RegExp _parenthesesRegex = RegExp(r'\([^)]*\)');
  static final RegExp _bracketsRegex = RegExp(r'\[[^\]]*\]');
  static final RegExp _whitespaceRegex = RegExp(r'\s+');

  /// Sanitizes a filename for display in the UI based on user preferences.
  ///
  /// Optionally strips extensions, regional tags (parentheses), and technical
  /// tags (brackets).
  static String _formatListNameFromFilename(
    String filename,
    Set<String> validExtensionsSet, {
    required bool hideExtension,
    required bool hideParentheses,
    required bool hideBrackets,
  }) {
    String name = filename;
    while (hideExtension) {
      final extension = path.extension(name);
      if (extension.isEmpty ||
          !validExtensionsSet.contains(extension.substring(1).toLowerCase())) {
        break;
      }
      name = name.substring(0, name.length - extension.length);
    }
    if (hideParentheses) {
      name = name.replaceAll(_parenthesesRegex, '');
    }
    if (hideBrackets) {
      name = name.replaceAll(_bracketsRegex, '');
    }
    name = name.replaceAll(_whitespaceRegex, ' ').trim();
    return hideExtension ? name : _trimSpaceBeforeExtension(name);
  }

  static String _trimSpaceBeforeExtension(String name) =>
      name.replaceAll(RegExp(r'\s+(?=\.[^.]+$)'), '');

  static bool _isSwitchFilenameTitle(DatabaseGameModel game, String title) {
    if (game.appSystemId != 'switch' && game.appSystemId != 'nintendo-switch') {
      return false;
    }
    final extension = path.extension(game.filename.trim()).toLowerCase();
    // The Switch scanner stores a filename-derived title, not embedded metadata.
    // Match its legacy slash split and case-sensitive extension replacement.
    return (extension == '.xci' || extension == '.nsp') &&
        title == game.romPath.split('/').last.replaceAll(extension, '').trim();
  }

  /// The name the game lists show for [dbGame] under a system's naming
  /// [settings] (a `user_system_settings` row) and lower-case [extensions].
  ///
  /// Pure, so smart-collection title rules can apply it in a worker isolate
  /// and match what the user actually sees.
  static String listDisplayName(
    DatabaseGameModel dbGame,
    Map<String, Object?> settings,
    Set<String> extensions,
  ) => _resolveListDisplayName(dbGame, settings, extensions).name;

  /// Resolves the optimal display name for a game considering scraped metadata
  /// and user-defined naming conventions.
  static ({
    String name,
    bool showRomFileNameSubtitle,
    bool showRomFileNameInInfo,
  })
  _resolveListDisplayName(
    DatabaseGameModel dbGame,
    Map<String, Object?> settings,
    Set<String> validExtensionsSet,
  ) {
    final filename = dbGame.filename;
    final preferFileName = settings['prefer_file_name'] == 1;
    final showRomFileName = settings['hide_rom_file_name_subtitle'] != 1;

    if (!preferFileName) {
      // realName also contains SQL's filename fallback. Read the source fields.
      final scrapedTitle = dbGame.screenscraperRealName?.trim() ?? '';
      final title = scrapedTitle.isNotEmpty
          ? scrapedTitle
          : dbGame.titleName?.trim() ?? '';
      if (title.isNotEmpty &&
          (scrapedTitle.isNotEmpty || !_isSwitchFilenameTitle(dbGame, title))) {
        final String name;
        if (dbGame.screenscraperRealName == filename) {
          name = filename;
        } else if (scrapedTitle.isNotEmpty) {
          name = _trimSpaceBeforeExtension(
            title.replaceAll(_whitespaceRegex, ' '),
          );
        } else {
          name = title;
        }
        return (
          name: name,
          showRomFileNameSubtitle:
              showRomFileName &&
              name != filename &&
              !SystemFolderNames.isAndroidApps(dbGame.systemFolderName),
          showRomFileNameInInfo: showRomFileName,
        );
      }
    }
    final name = _formatListNameFromFilename(
      filename,
      validExtensionsSet,
      hideExtension: (settings['hide_extension'] ?? 1) == 1,
      hideParentheses: (settings['hide_parentheses'] ?? 1) == 1,
      hideBrackets: (settings['hide_brackets'] ?? 1) == 1,
    );
    return (
      name: name.isEmpty ? filename : name,
      showRomFileNameSubtitle: false,
      showRomFileNameInInfo: showRomFileName,
    );
  }

  /// Retrieves a list of games for a specific system, applying metadata formatting.
  ///
  /// If the 'all' system is requested, it aggregates games across all supported
  /// emulation systems (excluding Android and Music).
  ///
  /// For a smart collection, [smartPaths] are its already-evaluated matches
  /// (see [loadGamesForCollection]). Collection load failures propagate so
  /// the list can show an error instead of an empty collection.
  static Future<List<GameModel>> loadGamesForSystem(
    SystemModel system, {
    Set<String>? smartPaths,
  }) async {
    final collectionId = SystemFolderNames.collectionIdOf(system.folderName);
    if (collectionId != null) {
      return loadGamesForCollection(collectionId, smartPaths: smartPaths);
    }
    try {
      if (system.folderName == SystemFolderNames.favorites) {
        return await _loadFavoriteGames();
      }

      if (system.folderName == SystemFolderNames.all) {
        final databaseGames = (await GameRepository.getAllGames())
            .where(
              (dbGame) =>
                  !dbGame.isHidden &&
                  !SystemFolderNames.isAndroidApps(dbGame.systemFolderName) &&
                  dbGame.systemFolderName != 'music',
            )
            .toList();

        return await _mapAggregateGames(databaseGames);
      }

      if (system.id == null) {
        return [];
      }

      final databaseGames = (await GameRepository.getGamesBySystem(system.id!))
          .where((dbGame) => !dbGame.isHidden)
          .toList();
      final validExtensions = await SystemRepository.getExtensionsForSystem(
        system.id!,
      );

      final settings = await SystemRepository.getSystemSettings(system.id!);

      final validExtensionsSet = validExtensions
          .map((e) => e.toLowerCase())
          .toSet();

      return [
        for (final game in databaseGames)
          _toListGame(game, settings, validExtensionsSet, system: system),
      ];
    } catch (e) {
      _log.e('Error loading games for ${system.realName}: $e');
      return [];
    }
  }

  static Future<List<GameModel>> _loadFavoriteGames() async {
    final databaseGames = (await GameRepository.getFavoriteGames())
        .where((dbGame) => !dbGame.isHidden)
        .toList();

    return _mapAggregateGames(databaseGames);
  }

  /// Loads the games of one collection, in the same display-ready shape as the
  /// favourites list.
  ///
  /// The repository query already joins `app_systems`, so every game carries
  /// its `systemFolderName`/`systemRealName` — the aggregate-view code path
  /// (launch, details card, secondary display) branches on those being present.
  /// Hidden ROMs are filtered here rather than in SQL, exactly as
  /// [_loadFavoriteGames] does. A smart collection given [smartPaths] reads
  /// only those rows rather than re-evaluating its rules.
  ///
  /// Throws on a database failure: an empty list would read as "no games
  /// match", which is a different thing to tell the user.
  static Future<List<GameModel>> loadGamesForCollection(
    String collectionId, {
    Set<String>? smartPaths,
  }) async {
    try {
      final databaseGames = (await SmartCollectionsService.gamesFor(
        collectionId,
        smartPaths: smartPaths,
      )).where((dbGame) => !dbGame.isHidden).toList();

      return await _mapAggregateGames(databaseGames);
    } catch (e) {
      _log.e('Error loading games for collection $collectionId: $e');
      rethrow;
    }
  }

  /// Maps games drawn from several systems at once into display-ready
  /// [GameModel]s.
  ///
  /// Shared by the `all` view, favourites and collections: each of those pulls
  /// rows spanning many systems, so the per-system naming settings and valid
  /// extensions are prefetched once per distinct system rather than once per
  /// game. Callers filter hidden ROMs before handing the list over.
  static Future<List<GameModel>> _mapAggregateGames(
    List<DatabaseGameModel> databaseGames,
  ) async {
    final (:settingsBySystem, :extensionsBySystem) = await _namingBySystem(
      databaseGames,
    );

    return databaseGames.map((dbGame) {
      final sid = dbGame.appSystemId ?? '';

      return _toListGame(
        dbGame,
        settingsBySystem[sid] ?? const {},
        extensionsBySystem[sid] ?? const {},
      );
    }).toList();
  }

  static GameModel _toListGame(
    DatabaseGameModel dbGame,
    Map<String, Object?> settings,
    Set<String> extensions, {
    SystemModel? system,
  }) {
    final resolved = _resolveListDisplayName(dbGame, settings, extensions);
    return GameModel(
      romname: dbGame.filename,
      realname: dbGame.realName ?? dbGame.filename,
      name: resolved.name,
      showRomFileNameSubtitle: resolved.showRomFileNameSubtitle,
      showRomFileNameInInfo: resolved.showRomFileNameInInfo,
      descriptions: dbGame.descriptions,
      videoUrl: dbGame.videoUrl,
      year: dbGame.year ?? '',
      developer: dbGame.developer ?? '',
      publisher: dbGame.publisher ?? '',
      genre: dbGame.genre ?? '',
      players: dbGame.players ?? '',
      rating: dbGame.rating ?? 0.0,
      isFavorite: dbGame.isFavorite,
      lastPlayed: dbGame.lastPlayed,
      playTime: dbGame.playTime,
      romPath: dbGame.romPath,
      emulatorName: dbGame.emulatorName,
      coreName: dbGame.coreName,
      raHash: dbGame.raHash,
      idRa: dbGame.idRa,
      systemRaId: dbGame.systemRaId,
      raNumAchievements: dbGame.raNumAchievements,
      systemId: dbGame.appSystemId,
      systemFolderName: system?.folderName ?? dbGame.systemFolderName,
      systemRealName: system == null ? dbGame.systemRealName : null,
      cloudSyncEnabled: dbGame.cloudSyncEnabled,
      titleId: dbGame.titleId,
      titleName: dbGame.titleName,
    );
  }

  /// The name each of [databaseGames] shows in a list, by `rom_path`, under
  /// its own system's naming settings.
  static Future<Map<String, String>> listDisplayNames(
    List<DatabaseGameModel> databaseGames,
  ) async {
    final (:settingsBySystem, :extensionsBySystem) = await _namingBySystem(
      databaseGames,
    );
    return {
      for (final dbGame in databaseGames)
        dbGame.romPath: listDisplayName(
          dbGame,
          settingsBySystem[dbGame.appSystemId ?? ''] ?? const {},
          extensionsBySystem[dbGame.appSystemId ?? ''] ?? const {},
        ),
    };
  }

  /// Naming settings and lower-cased valid extensions, read once per distinct
  /// system among [databaseGames].
  static Future<
    ({
      Map<String, Map<String, dynamic>> settingsBySystem,
      Map<String, Set<String>> extensionsBySystem,
    })
  >
  _namingBySystem(List<DatabaseGameModel> databaseGames) async {
    final systemIds = databaseGames
        .map((g) => g.appSystemId)
        .whereType<String>()
        .toSet();

    final settingsBySystem = await SystemRepository.getSystemSettingsMap(
      systemIds,
    );
    final extensionsBySystem =
        await SystemRepository.getExtensionsMapForSystems(systemIds);
    return (
      settingsBySystem: settingsBySystem,
      extensionsBySystem: extensionsBySystem,
    );
  }

  /// Fetches detailed metadata for a specific game instance.
  static Future<GameModel?> getGameDetails(
    SystemModel system,
    String romName,
  ) async {
    try {
      if (system.id == null) return null;

      final dbGame = await GameRepository.getSingleGame(system.id!, romName);
      if (dbGame == null) return null;

      final settings = await SystemRepository.getSystemSettings(system.id!);
      final validExtensions = await SystemRepository.getExtensionsForSystem(
        system.id!,
      );
      final validExtensionsSet = validExtensions
          .map((e) => e.toLowerCase())
          .toSet();

      return _toListGame(dbGame, settings, validExtensionsSet, system: system);
    } catch (e) {
      _log.e('Error loading game details for $romName: $e');
      return null;
    }
  }

  /// Groups a list of games by their genre metadata.
  static Map<String, List<GameModel>> groupGamesByGenre(List<GameModel> games) {
    Map<String, List<GameModel>> grouped = {};

    for (var game in games) {
      final genre = game.genre.isEmpty ? 'Unknown' : game.genre;
      if (!grouped.containsKey(genre)) {
        grouped[genre] = [];
      }
      grouped[genre]!.add(game);
    }

    return grouped;
  }

  /// Filters a list of games to return only those marked as favorites.
  static List<GameModel> getFavoriteGames(List<GameModel> games) {
    return games.where((game) => game.isFavorite ?? false).toList();
  }

  /// Filters and sorts a list of games to return the 10 most recently played instances.
  static List<GameModel> getRecentlyPlayedGames(List<GameModel> games) {
    final playedGames = games.where((game) => game.lastPlayed != null).toList();
    playedGames.sort((a, b) => b.lastPlayed!.compareTo(a.lastPlayed!));
    return playedGames.take(10).toList();
  }
}
