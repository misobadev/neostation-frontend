import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:neostation/l10n/app_locale.dart';
import 'package:neostation/services/sfx_service.dart';
import '../../../../models/system_model.dart';
import '../../../../models/game_model.dart';
import '../../../../models/retro_achievements_game_info.dart';
import '../../../../models/neo_sync_models.dart';
import '../../../../sync/i_sync_provider.dart';
import '../../../../utils/game_utils.dart';
import '../../../../widgets/marquee_text.dart';
import '../../music/music_player.dart';
import 'glass_button.dart';

/// A sticky footer component for the game details card that provides actionable controls and status summaries.
///
/// Manages high-level game interactions (Play, Favorite, Scrape), summarizes cloud synchronization
/// health, and provides quick access to trophy progress. Dynamically adjusts for specialized
/// systems like the Music Player.
class GameDetailsFooter extends StatelessWidget {
  final SystemModel system;
  final GameModel game;
  final bool isMusicSystem;
  final bool hasScreenScraper;
  final bool isScrapingGame;
  final String? localizedDescription;
  final bool isSecondaryScreenActive;
  final bool isFavorite;
  final bool cloudSyncEnabled;
  final ISyncProvider syncProvider;
  final AnimationController? syncIconController;
  final VoidCallback onPlayGame;
  final VoidCallback onToggleFavorite;
  final VoidCallback onScrapeGame;
  final VoidCallback onShowAchievements;
  final bool hasRetroAchievements;
  final bool isLoadingAchievements;
  final GameInfoAndUserProgress? currentGameInfo;

  const GameDetailsFooter({
    super.key,
    required this.system,
    required this.game,
    required this.isMusicSystem,
    required this.hasScreenScraper,
    required this.isScrapingGame,
    this.localizedDescription,
    required this.isSecondaryScreenActive,
    required this.isFavorite,
    required this.cloudSyncEnabled,
    required this.syncProvider,
    this.syncIconController,
    required this.onPlayGame,
    required this.onToggleFavorite,
    required this.onScrapeGame,
    required this.onShowAchievements,
    required this.hasRetroAchievements,
    required this.isLoadingAchievements,
    this.currentGameInfo,
  });

  @override
  Widget build(BuildContext context) {
    // Scenario 1: Specialized Music Player UI.
    if (isMusicSystem) {
      return Positioned(
        bottom: -0.5.r,
        left: -0.5.r,
        right: -0.5.r,
        child: MusicPlayer(systemColor: system.colorAsColor),
      );
    }

    // Scenario 2: Standard Game Metadata UI.
    return Positioned(
      bottom: -0.5.r,
      left: -0.5.r,
      right: -0.5.r,
      height: 98.r,
      child: ClipRRect(
        child: RepaintBoundary(
          child: Container(
            padding: EdgeInsets.symmetric(horizontal: 12.r),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Identity Section: Title, Rating, and ROM Filename.
                Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    if (game.rating > 0) ...[
                      _SteamStyleRating(game: game),
                      SizedBox(width: 8.r),
                    ],
                    Expanded(
                      child: RepaintBoundary(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            MarqueeText(
                              text: GameUtils.formatGameName(game.name),
                              isActive: true,
                              style: TextStyle(
                                color: Colors.white,
                                fontSize: 20.r,
                                fontWeight: FontWeight.bold,
                                shadows: [
                                  Shadow(
                                    blurRadius: 2.r,
                                    color: Colors.black,
                                    offset: const Offset(0, 0),
                                  ),
                                ],
                              ),
                            ),
                            if (game.showRomFileNameSubtitle) ...[
                              Text(
                                game.romname,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: Colors.white.withValues(alpha: 0.72),
                                  fontSize: 12.r,
                                  fontWeight: FontWeight.w400,
                                  height: 1.15,
                                  shadows: [
                                    Shadow(
                                      blurRadius: 2.r,
                                      color: Colors.black.withValues(
                                        alpha: 0.45,
                                      ),
                                      offset: const Offset(2, 2),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
                SizedBox(height: 8.r),

                // Actionable Section: Compact status indicators and primary Play button.
                ExcludeFocus(
                  child: Row(
                    children: [
                      ...(() {
                        final List<Widget> leftSide = [];

                        // Cloud Sync Status.
                        final neoSync = _buildCompactNeoSyncIndicator(context);
                        if (neoSync is! SizedBox ||
                            (neoSync.width != null && neoSync.width! > 0)) {
                          leftSide.add(Expanded(flex: 1, child: neoSync));
                        }

                        // RetroAchievements Progress.
                        final ach = _buildCompactAchievementsIndicator(context);
                        if (ach is! SizedBox ||
                            (ach.width != null && ach.width! > 0)) {
                          if (leftSide.isNotEmpty) {
                            leftSide.add(SizedBox(width: 8.r));
                          }
                          leftSide.add(Expanded(flex: 1, child: ach));
                        }

                        // Metadata Scraping Control.
                        final scrape = _buildScrapeButtonCompact(context);
                        if (scrape is! SizedBox) {
                          if (leftSide.isNotEmpty) {
                            leftSide.add(SizedBox(width: 8.r));
                          }
                          leftSide.add(Expanded(flex: 1, child: scrape));
                        }

                        // Library Favorite Toggle.
                        final fav = _buildFavoriteButtonCompact(context);
                        if (fav is! SizedBox) {
                          if (leftSide.isNotEmpty) {
                            leftSide.add(SizedBox(width: 8.r));
                          }
                          leftSide.add(Expanded(flex: 1, child: fav));
                        }

                        return leftSide;
                      })(),

                      const Spacer(),
                      SizedBox(width: 8.r),

                      // Primary Launch Control.
                      Expanded(
                        flex: 2,
                        child: _buildPlayButtonCompact(context),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// Specialized button for toggling the game's favorite status in the library.
  Widget _buildFavoriteButtonCompact(BuildContext context) {
    final isFav = game.isFavorite ?? false;
    return GlassButton(
      onTap: () {
        SfxService().playNavSound();
        onToggleFavorite();
      },
      iconPath: 'assets/images/gamepad/Xbox_Y_button.png',
      iconData: isFav
          ? Symbols.favorite_rounded
          : Symbols.favorite_border_rounded,
      iconColor: isFav
          ? Colors.redAccent
          : Theme.of(context).colorScheme.onSurface,
      label: isFav
          ? AppLocale.favorite.getString(context)
          : AppLocale.addFav.getString(context),
      isActive: isFav,
    );
  }

  /// High-contrast primary button for launching the emulator.
  ///
  /// Includes visual feedback for gamepad focus and displays accumulated play-time statistics.
  Widget _buildPlayButtonCompact(BuildContext context) {
    final playTimeText = GameUtils.formatPlayTime(game.playTime ?? 0);
    return Builder(
      builder: (context) {
        final isFocused = Focus.of(context).hasFocus;
        return AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          height: 40.r,
          decoration: BoxDecoration(
            color: isFocused
                ? const Color(0xFF36F184)
                : const Color(0xFF2ECC71),
            borderRadius: BorderRadius.circular(8.r),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.25),
                blurRadius: 2.r,
                offset: Offset(2.0.r, 2.0.r),
              ),
            ],
          ),
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              canRequestFocus: false,
              focusColor: Colors.transparent,
              hoverColor: Colors.transparent,
              highlightColor: Colors.transparent,
              splashColor: Colors.white.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(12.r),
              onTap: () {
                SfxService().playEnterSound();
                onPlayGame();
              },
              child: Padding(
                padding: EdgeInsets.symmetric(horizontal: 12.r),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Image.asset(
                      'assets/images/gamepad/Xbox_A_button.png',
                      width: 22.r,
                      height: 22.r,
                      color: Theme.of(context).colorScheme.onPrimary,
                    ),
                    SizedBox(width: 8.r),
                    Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          AppLocale.playButton.getString(context),
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.onPrimary,
                            fontWeight: FontWeight.w900,
                            fontSize: 14.r,
                            letterSpacing: 1.5,
                            height: 1.0,
                          ),
                        ),
                        if (playTimeText.isNotEmpty && playTimeText != '0s')
                          Text(
                            playTimeText.toUpperCase(),
                            style: TextStyle(
                              color: Theme.of(
                                context,
                              ).colorScheme.onPrimary.withValues(alpha: 0.8),
                              fontSize: 8.r,
                              fontWeight: FontWeight.bold,
                              height: 1.2,
                            ),
                          ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  /// Metadata fetching control that contextually switches between 'Scrape' and 'Rescrape'.
  Widget _buildScrapeButtonCompact(BuildContext context) {
    if (!hasScreenScraper) return const SizedBox.shrink();
    final description =
        localizedDescription ??
        (game.getDescriptionForLanguage('en').isEmpty
            ? AppLocale.noDescription.getString(context)
            : game.getDescriptionForLanguage('en'));

    final bool isDescriptionMissing =
        description.isEmpty ||
        description == AppLocale.noDescription.getString(context) ||
        description.trim().isEmpty;

    return GlassButton(
      onTap: () {
        SfxService().playNavSound();
        onScrapeGame();
      },
      iconPath: 'assets/images/gamepad/Xbox_View_button.png',
      iconData: isDescriptionMissing
          ? Symbols.search_rounded
          : Symbols.refresh_rounded,
      label: isDescriptionMissing
          ? AppLocale.scrape.getString(context)
          : AppLocale.rescrape.getString(context),
      isLoading: isScrapingGame,
    );
  }

  /// Resolves the current cloud synchronization state into a compact visual badge.
  ///
  /// Handles transition states (syncing), error states (quota, network), and
  /// arbitration states (conflict detected).
  Widget _buildCompactNeoSyncIndicator(BuildContext context) {
    if (!system.neosync.sync) return const SizedBox.shrink();
    if (system.folderName == 'android') return const SizedBox.shrink();

    final isNeoSyncConnected = syncProvider.isAuthenticated;
    if (!isNeoSyncConnected) return const SizedBox.shrink();
    if (system.screenscraperId == null || system.screenscraperId == 0) {
      return const SizedBox.shrink();
    }

    final gameState = syncProvider.getGameSyncState(game.romname);
    final isSyncing = syncProvider.status == SyncProviderStatus.syncing;
    final isCloudSyncDisabled = cloudSyncEnabled == false;

    Color statusColor;
    IconData statusIcon;
    String statusText;

    if (isCloudSyncDisabled) {
      statusColor = Theme.of(context).colorScheme.onSurface;
      statusIcon = Symbols.cloud_off_rounded;
      statusText = AppLocale.cloudSyncDisabled.getString(context);
    } else if (isSyncing) {
      statusColor = Colors.lightBlue;
      statusIcon = Symbols.sync_rounded;
      statusText = AppLocale.syncing.getString(context);
    } else if (syncProvider.lastError != null) {
      statusColor = const Color(0xFFE53E3E);
      statusIcon = Symbols.error_outline_rounded;
      statusText = AppLocale.error.getString(context);
    } else if (gameState != null) {
      switch (gameState.status) {
        case GameSyncStatus.upToDate:
          statusColor = const Color(0xFF79AA41);
          statusIcon = Symbols.check_circle_outline_rounded;
          statusText = AppLocale.synced.getString(context);
          break;
        case GameSyncStatus.localOnly:
          statusColor = Colors.orange;
          statusIcon = Symbols.cloud_upload_rounded;
          statusText = AppLocale.upload.getString(context);
          break;
        case GameSyncStatus.cloudOnly:
          statusColor = Colors.lightBlue;
          statusIcon = Symbols.cloud_download_rounded;
          statusText = AppLocale.download.getString(context);
          break;
        case GameSyncStatus.syncing:
          statusColor = Colors.lightBlue;
          statusIcon = Symbols.sync_rounded;
          statusText = AppLocale.syncing.getString(context);
          break;
        case GameSyncStatus.disabled:
          if (!isCloudSyncDisabled) {
            statusColor = Colors.lightBlue;
            statusIcon = Symbols.sync_rounded;
            statusText = AppLocale.ready.getString(context);
          } else {
            statusColor = Colors.grey;
            statusIcon = Symbols.cloud_off_rounded;
            statusText = AppLocale.cloudSyncDisabled.getString(context);
          }
          break;
        case GameSyncStatus.quotaExceeded:
          statusColor = Colors.redAccent;
          statusIcon = Symbols.storage_rounded;
          statusText = AppLocale.quota.getString(context);
          break;
        case GameSyncStatus.noSaveFound:
          statusColor = Colors.grey;
          statusIcon = Symbols.save_alt_rounded;
          statusText = AppLocale.noSave.getString(context);
          break;
        case GameSyncStatus.missingEmulator:
          statusColor = Colors.orange;
          statusIcon = Symbols.videogame_asset_off_rounded;
          statusText = AppLocale.noEmulator.getString(context);
          break;
        case GameSyncStatus.error:
          statusColor = Colors.red;
          statusIcon = Symbols.error_outline_rounded;
          statusText = AppLocale.error.getString(context);
          break;
      }
    } else {
      statusColor = Colors.lightBlue;
      statusIcon = Symbols.sync_rounded;
      statusText = AppLocale.ready.getString(context);
    }

    Widget neoSyncContent = AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      height: 40.r,
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: BorderRadius.circular(8.r),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.25),
            blurRadius: 2.r,
            offset: Offset(2.0.r, 2.0.r),
          ),
        ],
      ),
      child: Padding(
        padding: EdgeInsets.symmetric(horizontal: 6.r),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Row(
              mainAxisSize: MainAxisSize.min,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                // Render a rotating sync icon during active I/O.
                statusIcon == Symbols.sync_rounded && syncIconController != null
                    ? AnimatedBuilder(
                        animation: syncIconController!,
                        builder: (context, child) {
                          return Transform.rotate(
                            angle: syncIconController!.value * 2 * 3.14159,
                            child: Icon(
                              statusIcon,
                              color: statusColor,
                              size: 16.r,
                            ),
                          );
                        },
                      )
                    : Icon(statusIcon, color: statusColor, size: 16.r),
                if (gameState?.status == GameSyncStatus.error) ...[
                  SizedBox(width: 4.r),
                  Image.asset(
                    'assets/images/gamepad/Xbox_L-click.png',
                    width: 16.r,
                    height: 16.r,
                    color: Theme.of(context).colorScheme.onSurface,
                    errorBuilder: (context, error, stackTrace) => Icon(
                      Symbols.radio_button_checked_rounded,
                      color: Theme.of(context).colorScheme.onSurface,
                      size: 16.r,
                    ),
                  ),
                ],
              ],
            ),
            SizedBox(height: 2.r),
            Text(
              statusText.toUpperCase(),
              style: TextStyle(
                color: Theme.of(context).colorScheme.onSurface,
                fontSize: 8.r,
                fontWeight: FontWeight.bold,
                letterSpacing: 0.5,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
      ),
    );

    return neoSyncContent;
  }

  /// Resolves the current RetroAchievements progress into a compact visual badge.
  Widget _buildCompactAchievementsIndicator(BuildContext context) {
    if (!hasRetroAchievements) return const SizedBox.shrink();

    final bool noAchievements =
        !isLoadingAchievements &&
        (currentGameInfo == null || currentGameInfo!.numAchievements == 0);

    final String progressText = isLoadingAchievements
        ? AppLocale.loading.getString(context)
        : (noAchievements
              ? AppLocale.noAchievements.getString(context)
              : '${currentGameInfo!.numAwardedToUser}/${currentGameInfo!.numAchievements}');

    final theme = Theme.of(context);
    final Color statusColor = noAchievements
        ? theme.colorScheme.onSurface
        : Colors.orange;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () {
          SfxService().playNavSound();
          onShowAchievements();
        },
        canRequestFocus: false,
        focusColor: Colors.transparent,
        hoverColor: Colors.transparent,
        highlightColor: Colors.transparent,
        splashColor: theme.colorScheme.onSurface.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(8.r),
        child: Container(
          height: 40.r,
          decoration: BoxDecoration(
            color: theme.colorScheme.surface,
            borderRadius: BorderRadius.circular(8.r),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.25),
                blurRadius: 2.r,
                offset: Offset(2.0.r, 2.0.r),
              ),
            ],
          ),
          child: Padding(
            padding: EdgeInsets.symmetric(horizontal: 6.r),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                if (isLoadingAchievements)
                  SizedBox(
                    width: 16.r,
                    height: 16.r,
                    child: CircularProgressIndicator(
                      strokeWidth: 2.5,
                      color: theme.colorScheme.onSurface,
                    ),
                  )
                else
                  Icon(
                    Symbols.emoji_events_rounded,
                    color: statusColor,
                    size: 16.r,
                  ),
                SizedBox(height: 2.r),
                Text(
                  progressText.toUpperCase(),
                  style: TextStyle(
                    color: theme.colorScheme.onSurface,
                    fontSize: 8.r,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 0.5,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// A Steam-inspired rating badge that interpolates color based on the score intensity.
class _SteamStyleRating extends StatelessWidget {
  final GameModel game;

  const _SteamStyleRating({required this.game});

  @override
  Widget build(BuildContext context) {
    // Normalizes a 0-20 score to a 0.0-10.0 scale for color interpolation.
    final ratingValue = (game.rating / 2).clamp(0.0, 10.0);
    final colorRatio = (ratingValue - 1) / 9;
    final ratingColor = Color.lerp(
      Colors.redAccent,
      Colors.lightGreenAccent,
      colorRatio,
    )!;

    return Container(
      padding: EdgeInsets.symmetric(horizontal: 10.r, vertical: 6.r),
      decoration: BoxDecoration(
        color: Colors.black87,
        borderRadius: BorderRadius.circular(6.r),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.25),
            blurRadius: 2.r,
            offset: Offset(2.0.r, 2.0.r),
          ),
        ],
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Symbols.star_rounded, color: ratingColor, size: 24.r),
          SizedBox(width: 6.r),
          Text(
            ratingValue.toStringAsFixed(1),
            style: TextStyle(
              color: Colors.white,
              fontSize: 20.r,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}
