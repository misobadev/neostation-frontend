import 'package:flutter/material.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:neostation/constants/system_folder_names.dart';
import 'package:neostation/l10n/app_locale.dart';
import 'package:neostation/models/game_model.dart';
import 'package:neostation/models/my_systems.dart';
import 'package:neostation/models/system_model.dart';
import 'package:neostation/providers/file_provider.dart';
import 'package:neostation/providers/sqlite_config_provider.dart';
import 'package:neostation/providers/sqlite_database_provider.dart';

SystemModel createFavoritesSystem(
  BuildContext context,
  List<dynamic> detectedSystems,
) {
  final existingFavorites = detectedSystems.cast<SystemModel?>().firstWhere(
    (s) => s?.folderName == SystemFolderNames.favorites,
    orElse: () => null,
  );

  return SystemModel(
    id: existingFavorites?.id ?? SystemFolderNames.favorites,
    folderName: SystemFolderNames.favorites,
    realName: existingFavorites?.realName ?? AppLocale.favorite.getString(context),
    iconImage: existingFavorites?.iconImage ?? 'assets/images/icons/heart-bulk.png',
    color: existingFavorites?.color ?? '#ff006a',
    customBackgroundPath: existingFavorites?.customBackgroundPath,
    customLogoPath: existingFavorites?.customLogoPath,
    hideLogo: existingFavorites?.hideLogo ?? false,
    imageVersion: existingFavorites?.imageVersion ?? 0,
    romCount: existingFavorites?.romCount ?? 0,
    detected: true,
    isVirtual: true,
  );
}

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
  final showFavorites =
      totalFavorites > 0 &&
      !hiddenFolders.contains(SystemFolderNames.favorites);

  final favoritesSystem = showFavorites
      ? [
          SystemInfo.fromSystemMetadata(
            createFavoritesSystem(context, configProvider.detectedSystems),
          ).copyWith(
            numOfRoms: totalFavorites,
            totalStorage: AppLocale.gamesCount
                .getString(context)
                .replaceFirst('{count}', totalFavorites.toString()),
          ),
        ]
      : <SystemInfo>[];

  final detectedSystems = configProvider.detectedSystems
      .where((s) => !hiddenFolders.contains(s.folderName))
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
        }
        return info;
      });

  return [...recentGames, ...favoritesSystem, ...detectedSystems];
}
