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

  static bool _hasScreenscraperRealName(DatabaseGameModel dbGame) {
    final t = dbGame.screenscraperRealName?.trim();
    return t != null && t.isNotEmpty;
  }

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
    if (hideExtension) {
      final extWithDot = path.extension(name).toLowerCase();
      if (extWithDot.isNotEmpty) {
        final ext = extWithDot.substring(1);
        if (validExtensionsSet.contains(ext)) {
          name = name.substring(0, name.length - extWithDot.length);
        }
      }
    }
    if (hideParentheses) {
      name = name.replaceAll(_parenthesesRegex, '');
    }
    if (hideBrackets) {
      name = name.replaceAll(_bracketsRegex, '');
    }
    name = name.replaceAll(_whitespaceRegex, ' ').trim();
    if (!hideExtension) {
      name = name.replaceAll(RegExp(r'\s+(?=\.[^.]+$)'), '');
    }
    return name;
  }

  static String _formatListNameFromScrapedTitle(String rawTitle) {
    String name = rawTitle.trim();
    name = name.replaceAll(_whitespaceRegex, ' ').trim();
    name = name.replaceAll(RegExp(r'\s+(?=\.[^.]+$)'), '');
    return name;
  }

  /// Resolves the optimal display name for a game considering scraped metadata
  /// and user-defined naming conventions.
  static ({String name, bool showRomFileNameSubtitle}) _resolveListDisplayName({
    required DatabaseGameModel dbGame,
    required bool preferFileName,
    required bool hideExtension,
    required bool hideParentheses,
    required bool hideBrackets,
    required Set<String> validExtensionsSet,
  }) {
    final filename = dbGame.filename;
    final scraped = _hasScreenscraperRealName(dbGame);
    final coalesced = dbGame.realName ?? dbGame.titleName ?? filename;

    if (preferFileName) {
      return (
        name: _formatListNameFromFilename(
          filename,
          validExtensionsSet,
          hideExtension: hideExtension,
          hideParentheses: hideParentheses,
          hideBrackets: hideBrackets,
        ),
        showRomFileNameSubtitle: false,
      );
    }
    if (scraped) {
      return (
        name: _formatListNameFromScrapedTitle(coalesced),
        showRomFileNameSubtitle: true,
      );
    }
    if (coalesced != filename) {
      return (name: coalesced, showRomFileNameSubtitle: false);
    }
    return (
      name: _formatListNameFromFilename(
        filename,
        validExtensionsSet,
        hideExtension: hideExtension,
        hideParentheses: hideParentheses,
        hideBrackets: hideBrackets,
      ),
      showRomFileNameSubtitle: false,
    );
  }

  /// Retrieves a list of games for a specific system, applying metadata formatting.
  ///
  /// If the 'all' system is requested, it aggregates games across all supported
  /// emulation systems (excluding Android and Music).
  static Future<List<GameModel>> loadGamesForSystem(SystemModel system) async {
    try {
      final collectionId = SystemFolderNames.collectionIdOf(system.folderName);
      if (collectionId != null) {
        return await loadGamesForCollection(collectionId);
      }

      if (system.folderName == SystemFolderNames.favorites) {
        return await _loadFavoriteGames();
      }

      if (system.folderName == SystemFolderNames.all) {
        final databaseGames = (await GameRepository.getAllGames())
            .where(
              (dbGame) =>
                  !dbGame.isHidden &&
                  dbGame.systemFolderName != 'android' &&
                  dbGame.systemFolderName != 'music',
            )
            .toList();

        return await _mapAggregateGames(databaseGames);
      }

      if (system.id == null) {
        return [];
      }

      final databaseGames = (await GameRepository.getGamesBySystem(
        system.id!,
      )).where((dbGame) => !dbGame.isHidden).toList();
      final validExtensions = await SystemRepository.getExtensionsForSystem(
        system.id!,
      );

      final settings = await SystemRepository.getSystemSettings(system.id!);
      final preferFileName = (settings['prefer_file_name'] ?? 0) == 1;
      final hideExtension = (settings['hide_extension'] ?? 1) == 1;
      final hideParentheses = (settings['hide_parentheses'] ?? 1) == 1;
      final hideBrackets = (settings['hide_brackets'] ?? 1) == 1;

      final validExtensionsSet = validExtensions
          .map((e) => e.toLowerCase())
          .toSet();

      final games = databaseGames.map((dbGame) {
        final resolved = _resolveListDisplayName(
          dbGame: dbGame,
          preferFileName: preferFileName,
          hideExtension: hideExtension,
          hideParentheses: hideParentheses,
          hideBrackets: hideBrackets,
          validExtensionsSet: validExtensionsSet,
        );

        return GameModel(
          romname: dbGame.filename,
          realname: dbGame.realName ?? dbGame.filename,
          name: resolved.name,
          showRomFileNameSubtitle: resolved.showRomFileNameSubtitle,
          descriptions: dbGame.descriptions,
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
          systemFolderName: system.folderName,
          cloudSyncEnabled: dbGame.cloudSyncEnabled,
          titleId: dbGame.titleId,
          titleName: dbGame.titleName,
        );
      }).toList();

      return games;
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
  /// [_loadFavoriteGames] does.
  static Future<List<GameModel>> loadGamesForCollection(
    String collectionId,
  ) async {
    try {
      final databaseGames = (await SmartCollectionsService.gamesFor(
        collectionId,
      )).where((dbGame) => !dbGame.isHidden).toList();

      return await _mapAggregateGames(databaseGames);
    } catch (e) {
      _log.e('Error loading games for collection $collectionId: $e');
      return [];
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
    final systemIds = databaseGames
        .map((g) => g.appSystemId)
        .whereType<String>()
        .toSet();

    final settingsBySystem = <String, Map<String, dynamic>>{};
    final extensionsBySystem = <String, Set<String>>{};
    for (final sid in systemIds) {
      settingsBySystem[sid] = await SystemRepository.getSystemSettings(sid);
      final exts = await SystemRepository.getExtensionsForSystem(sid);
      extensionsBySystem[sid] = exts.map((e) => e.toLowerCase()).toSet();
    }

    return databaseGames.map((dbGame) {
      final sid = dbGame.appSystemId ?? '';
      final settings = settingsBySystem[sid] ?? {};
      final preferFileName = (settings['prefer_file_name'] ?? 0) == 1;
      final hideExtension = (settings['hide_extension'] ?? 1) == 1;
      final hideParentheses = (settings['hide_parentheses'] ?? 1) == 1;
      final hideBrackets = (settings['hide_brackets'] ?? 1) == 1;
      final extSet = extensionsBySystem[sid] ?? {};

      final resolved = _resolveListDisplayName(
        dbGame: dbGame,
        preferFileName: preferFileName,
        hideExtension: hideExtension,
        hideParentheses: hideParentheses,
        hideBrackets: hideBrackets,
        validExtensionsSet: extSet,
      );

      return GameModel(
        romname: dbGame.filename,
        realname: dbGame.realName ?? dbGame.filename,
        name: resolved.name,
        showRomFileNameSubtitle: resolved.showRomFileNameSubtitle,
        descriptions: dbGame.descriptions,
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
        systemFolderName: dbGame.systemFolderName,
        systemRealName: dbGame.systemRealName,
        cloudSyncEnabled: dbGame.cloudSyncEnabled,
        titleId: dbGame.titleId,
        titleName: dbGame.titleName,
      );
    }).toList();
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
      final preferFileName = (settings['prefer_file_name'] ?? 0) == 1;
      final hideExtension = (settings['hide_extension'] ?? 1) == 1;
      final hideParentheses = (settings['hide_parentheses'] ?? 1) == 1;
      final hideBrackets = (settings['hide_brackets'] ?? 1) == 1;
      final validExtensions = await SystemRepository.getExtensionsForSystem(
        system.id!,
      );
      final validExtensionsSet = validExtensions
          .map((e) => e.toLowerCase())
          .toSet();

      final resolved = _resolveListDisplayName(
        dbGame: dbGame,
        preferFileName: preferFileName,
        hideExtension: hideExtension,
        hideParentheses: hideParentheses,
        hideBrackets: hideBrackets,
        validExtensionsSet: validExtensionsSet,
      );

      return GameModel(
        romname: dbGame.filename,
        realname: dbGame.realName ?? dbGame.filename,
        name: resolved.name,
        showRomFileNameSubtitle: resolved.showRomFileNameSubtitle,
        descriptions: dbGame.descriptions,
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
        systemFolderName: system.folderName,
        cloudSyncEnabled: dbGame.cloudSyncEnabled,
        titleId: dbGame.titleId,
        titleName: dbGame.titleName,
      );
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
