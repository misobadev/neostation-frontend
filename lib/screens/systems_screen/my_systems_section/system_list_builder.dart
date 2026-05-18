import 'package:flutter/material.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:neostation/constants/system_folder_names.dart';
import 'package:neostation/l10n/app_locale.dart';
import 'package:neostation/models/game_model.dart';
import 'package:neostation/models/my_systems.dart';
import 'package:neostation/providers/file_provider.dart';
import 'package:neostation/providers/sqlite_config_provider.dart';
import 'package:neostation/providers/sqlite_database_provider.dart';

List<SystemInfo> buildSystemsList({
  required BuildContext context,
  required SqliteConfigProvider configProvider,
  required SqliteDatabaseProvider dbProvider,
  required FileProvider fileProvider,
}) {
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
        }
        return info;
      });

  return [...recentGames, ...detectedSystems];
}
