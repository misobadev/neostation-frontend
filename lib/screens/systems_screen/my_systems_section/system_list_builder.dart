import 'package:flutter/material.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:neostation/constants/system_folder_names.dart';
import 'package:neostation/l10n/app_locale.dart';
import 'package:neostation/models/game_model.dart';
import 'package:neostation/models/my_systems.dart';
import 'package:neostation/providers/collections_provider.dart';
import 'package:neostation/providers/file_provider.dart';
import 'package:neostation/providers/sqlite_config_provider.dart';
import 'package:neostation/providers/sqlite_database_provider.dart';
import 'package:provider/provider.dart';

/// Builds the systems carousel/grid model.
///
/// [collectionsProvider] is optional only so the existing call sites keep
/// compiling: when it is omitted the provider is resolved from [context]
/// without listening, which is what the carousel needs (it calls this from
/// event handlers, where a listening read throws). A host that wants the
/// Collections card's count to repaint the instant a collection is created
/// should watch [CollectionsProvider] itself and pass it in.
List<SystemInfo> buildSystemsList({
  required BuildContext context,
  required SqliteConfigProvider configProvider,
  required SqliteDatabaseProvider dbProvider,
  required FileProvider fileProvider,
  CollectionsProvider? collectionsProvider,
}) {
  final collections =
      collectionsProvider ??
      Provider.of<CollectionsProvider>(context, listen: false);
  final collectionGames = collections.totalGameCount;
  const recentCount = 1;
  final hideRecent = configProvider.config.hideRecentCard;
  final recentDbGames = hideRecent
      ? dbProvider.getRecentlyPlayedGames(0)
      : dbProvider.getRecentlyPlayedGames(recentCount);

  final recentGames = recentDbGames
      .map((dbGame) => GameModel.fromDatabaseModel(dbGame))
      .map((game) => SystemInfo.fromGameModel(game, fileProvider))
      .toList();

  final hiddenFolders = configProvider.hiddenSystemFolders;
  final totalFavorites = dbProvider.totalFavorites;

  final detectedSystems = configProvider.detectedSystems
      .where((s) => !hiddenFolders.contains(s.folderName))
      .where(
        (s) =>
            !(s.folderName == SystemFolderNames.favorites &&
                totalFavorites == 0),
      )
      .map((system) {
        final info = SystemInfo.fromSystemMetadata(system);

        if (system.folderName == 'all') {
          return info.copyWith(
            numOfRoms: configProvider.totalGames,
            totalStorage: AppLocale.gamesCount
                .getString(context)
                .replaceFirst('{count}', configProvider.totalGames.toString()),
          );
        } else if (system.folderName == 'android') {
          return info.copyWith(
            totalStorage: AppLocale.appsCount
                .getString(context)
                .replaceFirst('{count}', system.romCount.toString()),
          );
        } else if (system.folderName == SystemFolderNames.favorites) {
          return info.copyWith(
            numOfRoms: totalFavorites,
            totalStorage: AppLocale.gamesCount
                .getString(context)
                .replaceFirst('{count}', totalFavorites.toString()),
          );
        } else if (system.folderName == SystemFolderNames.collections) {
          // The count is of the games the collections hold, not of the
          // collections themselves. The card sits in a row of system cards
          // that all answer "how many games are in here", and it is the only
          // one whose own contents are a level further down, so counting the
          // containers would make it the odd one out. It sums the
          // per-collection counts rather than counting distinct games, so it
          // agrees with the numbers the browser lists one level down — see
          // CollectionsProvider.totalGameCount, which carries the tradeoff.
          return info.copyWith(numOfRoms: collectionGames);
        }
        return info;
      });

  final systems = configProvider.config.hideSearchCard
      ? detectedSystems
      : withSearchCard(
          detectedSystems.toList(),
          _searchCard(context, configProvider.totalGames),
        );

  return [...recentGames, ...systems];
}

/// [systems] with [searchCard] placed right after All Games, the list it
/// searches. With no All Games card (a library of apps or music only) it leads
/// the systems instead. Not gated on a game count: search also reaches the
/// RomM library.
@visibleForTesting
List<SystemInfo> withSearchCard(
  List<SystemInfo> systems,
  SystemInfo searchCard,
) {
  final allIndex = systems.indexWhere(
    (s) => s.folderName == SystemFolderNames.all,
  );
  return [...systems]..insert(allIndex + 1, searchCard);
}

/// The Search card, which opens `SearchScreen` rather than a games list.
///
/// It carries the whole library's game count, since that is what it searches.
/// Its logo is the bundled `assets/images/logos/search.webp`, resolved from the
/// folder name like every other card's, and a theme can give it a background
/// by shipping one for `search`.
SystemInfo _searchCard(BuildContext context, int totalGames) {
  final title = AppLocale.searchTitle.getString(context);
  return SystemInfo(
    title: title,
    shortName: title,
    folderName: SystemFolderNames.search,
    numOfRoms: totalGames,
    color1: '#26A69A',
    color2: '#B0BEC5',
    percentage: 0,
  );
}
