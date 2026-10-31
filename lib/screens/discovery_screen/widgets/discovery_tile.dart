import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../../../models/game_model.dart';
import '../../../providers/file_provider.dart';
import '../../../services/sfx_service.dart';
import '../../../themes/corner_radii.dart';
import '../../../widgets/neo_glass.dart';
import '../../../utils/performance_mode.dart';
import '../discovery_mosaic.dart';

/// One card of the Discovery board, built from the same chrome as [SystemCard].
///
/// Artwork fills the card, with the game wheel over it. The footer strip —
/// where a system card puts its console logo — carries only the section name,
/// set large and bold. The game's own name lives in the screen footer.
class DiscoveryCard extends StatelessWidget {
  const DiscoveryCard({
    super.key,
    required this.tile,
    required this.isSelected,
    required this.fileProvider,
    this.onTap,
    this.heroFooterUsesHalfWidth = true,
  });

  final DiscoveryTile tile;
  final bool isSelected;
  final FileProvider fileProvider;
  final VoidCallback? onTap;

  /// Whether the headline spans two grid columns. It then uses half its width
  /// as the footer basis so its strip matches the cards beside it. In the
  /// carousel every page is one card wide, so this is false.
  final bool heroFooterUsesHalfWidth;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final radii = theme.extension<CornerRadii>();
    final outerRadius = radii?.radiusExternal ?? BorderRadius.circular(14.r);
    final outerRadiusPx = radii?.radiusExternalRadius ?? 14.r;
    final innerRadius = radii?.radiusInternal ?? BorderRadius.circular(9.r);
    const artworkInset = 4.0;
    final performanceMode = context.performanceMode;

    return Padding(
      padding: EdgeInsets.all(2.r),
      child: MouseRegion(
        cursor: SystemMouseCursors.basic,
        child: NeoGlassRim(
          cornerRadius: outerRadiusPx,
          child: Container(
            decoration: BoxDecoration(
              color: isSelected ? scheme.secondary : scheme.surface,
              borderRadius: outerRadius,
              boxShadow: performanceMode
                  ? null
                  : [
                      BoxShadow(
                        color: scheme.shadow.withValues(alpha: 0.1),
                        blurRadius: 4.r,
                        offset: Offset(2.0.r, 2.0.r),
                      ),
                    ],
            ),
            child: ClipRRect(
              borderRadius: innerRadius,
              child: InkWell(
                onTap: () {
                  // Touch users have no A button: tapping the selected card
                  // confirms it, so it earns the enter sound.
                  if (isSelected) {
                    SfxService().playEnterSound();
                  } else {
                    SfxService().playNavSound();
                  }
                  onTap?.call();
                },
                canRequestFocus: false,
                focusColor: Colors.transparent,
                hoverColor: Colors.transparent,
                highlightColor: Colors.transparent,
                splashColor: Colors.transparent,
                child: Padding(
                  padding: EdgeInsets.only(
                    top: artworkInset.r,
                    left: artworkInset.r,
                    right: artworkInset.r,
                  ),
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      // The headline spans two columns, so it uses half its
                      // width as the basis — otherwise its footer would be
                      // twice as tall as the one on the cards beside it.
                      final footerBasis =
                          tile.kind == DiscoveryTileKind.hero &&
                              heroFooterUsesHalfWidth
                          ? constraints.maxWidth / 2
                          : constraints.maxWidth;
                      final footerHeight = math
                          .max(32.r, footerBasis * 0.22)
                          .clamp(32.r, 52.r)
                          .toDouble();
                      return Column(
                        children: [
                          Expanded(
                            child: Stack(
                              fit: StackFit.expand,
                              children: [
                                ClipRRect(
                                  borderRadius: innerRadius,
                                  child: DiscoveryTileArt(
                                    tile: tile,
                                    fileProvider: fileProvider,
                                  ),
                                ),
                                _DiscoveryWheel(
                                  tile: tile,
                                  fileProvider: fileProvider,
                                ),
                                if (tile.achievementCount > 0)
                                  Positioned(
                                    right: 6.r,
                                    top: 6.r,
                                    child: _AchievementPill(
                                      count: tile.achievementCount,
                                    ),
                                  ),
                              ],
                            ),
                          ),
                          SizedBox(
                            height: footerHeight,
                            width: double.infinity,
                            child: _DiscoveryFooter(
                              tile: tile,
                              isSelected: isSelected,
                            ),
                          ),
                        ],
                      );
                    },
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The footer strip: the section name, scaled to read like a system logo.
class _DiscoveryFooter extends StatelessWidget {
  const _DiscoveryFooter({required this.tile, required this.isSelected});

  final DiscoveryTile tile;
  final bool isSelected;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final color = isSelected ? scheme.onSecondary : scheme.onSurface;

    return Padding(
      padding: EdgeInsets.symmetric(horizontal: 8.r, vertical: 4.r),
      child: FittedBox(
        fit: BoxFit.contain,
        child: Text(
          tile.labelKey.getString(context).toUpperCase(),
          maxLines: 1,
          softWrap: false,
          textAlign: TextAlign.center,
          style: TextStyle(
            color: color,
            fontSize: 18.r,
            fontWeight: FontWeight.w900,
            letterSpacing: 0.6.r,
          ),
        ),
      ),
    );
  }
}

/// The small trophy count shown on an achievement spotlight card.
class _AchievementPill extends StatelessWidget {
  const _AchievementPill({required this.count});

  final int count;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: EdgeInsets.symmetric(horizontal: 5.r, vertical: 2.r),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(999.r),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Symbols.trophy_rounded,
            size: 8.r,
            color: theme.colorScheme.primary,
          ),
          SizedBox(width: 3.r),
          Text(
            '$count',
            style: TextStyle(
              fontSize: 7.r,
              fontWeight: FontWeight.w700,
              color: Colors.white,
            ),
          ),
        ],
      ),
    );
  }
}

/// The game wheel over the Game of the Week art, matching the compact recent
/// card in Systems.
class _DiscoveryWheel extends StatelessWidget {
  const _DiscoveryWheel({required this.tile, required this.fileProvider});

  final DiscoveryTile tile;
  final FileProvider fileProvider;

  @override
  Widget build(BuildContext context) {
    final entry = tile.entry;
    final folder = entry?.game.systemFolderName ?? '';
    if (entry == null || folder.isEmpty) return const SizedBox.shrink();

    final path = discoveryFirstExistingImage([
      GameModel.fromDatabaseModel(
        entry.game,
      ).getImagePath(folder, 'wheels', fileProvider),
    ]);
    if (path == null) return const SizedBox.shrink();

    return LayoutBuilder(
      builder: (context, constraints) {
        if (tile.kind == DiscoveryTileKind.hero) {
          final shortestSide = constraints.biggest.shortestSide;
          // The headline is the compact two-column shape, so it uses the same
          // wheel inset the recent-game card does, opened up a little.
          final inset = shortestSide.isFinite
              ? math.min(28.r, shortestSide * 0.16)
              : 28.r;
          return Center(
            child: Padding(
              padding: EdgeInsets.all(inset),
              child: Image.file(
                File(path),
                height: 256.r,
                fit: BoxFit.contain,
                cacheWidth: performanceCacheWidth(
                  512,
                  performanceMode: context.performanceMode,
                ),
                errorBuilder: (_, _, _) => const SizedBox.shrink(),
              ),
            ),
          );
        }

        // Small cards use the game list's wheel strategy: the image is given the
        // card's width and left to keep its own ratio, so wheels with different
        // source dimensions still read at a consistent size.
        final wheelWidth = constraints.maxWidth.isFinite
            ? math.max(0.0, constraints.maxWidth - 16.r)
            : 120.r;
        return Align(
          alignment: Alignment.bottomCenter,
          child: Padding(
            padding: EdgeInsets.only(bottom: 4.r),
            child: SizedBox(
              width: wheelWidth,
              child: Image.file(
                File(path),
                fit: BoxFit.contain,
                cacheWidth: performanceCacheWidth(
                  388,
                  performanceMode: context.performanceMode,
                ),
                errorBuilder: (_, _, _) => const SizedBox.shrink(),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// The art behind a card.
///
/// Landscape art first, then box art, then a placeholder.
class DiscoveryTileArt extends StatelessWidget {
  const DiscoveryTileArt({
    super.key,
    required this.tile,
    required this.fileProvider,
  });

  final DiscoveryTile tile;
  final FileProvider fileProvider;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final entry = tile.entry;
    final folder = entry?.game.systemFolderName ?? '';
    // A notice stands for a section that has no pick, so it has no art and no
    // missing art either: the placeholder would read as a broken tile.
    if (entry == null) return const SizedBox.shrink();

    final path = folder.isEmpty
        ? null
        : discoveryFirstExistingImage([
            GameModel.fromDatabaseModel(
              entry.game,
            ).getImagePath(folder, 'fanarts', fileProvider),
            GameModel.fromDatabaseModel(
              entry.game,
            ).getImagePath(folder, 'screenshots', fileProvider),
            GameModel.fromDatabaseModel(
              entry.game,
            ).getImagePath(folder, 'box2d', fileProvider),
          ]);

    if (path == null) return _placeholder(theme);

    return LayoutBuilder(
      builder: (context, constraints) => Image.file(
        File(path),
        fit: BoxFit.cover,
        cacheWidth: performanceCacheWidth(
          constraints.maxWidth.isFinite
              ? (constraints.maxWidth * 2).round()
              : 640,
          performanceMode: context.performanceMode,
        ),
        errorBuilder: (_, _, _) => _placeholder(theme),
      ),
    );
  }

  Widget _placeholder(ThemeData theme) => ColoredBox(
    color: theme.cardColor.withValues(alpha: 0.45),
    child: Center(
      child: Icon(
        Symbols.videogame_asset_rounded,
        size: 18.r,
        color: theme.colorScheme.onSurface.withValues(alpha: 0.3),
      ),
    ),
  );
}

/// The first path that is actually on disk, or null.
String? discoveryFirstExistingImage(List<String> paths) {
  for (final path in paths) {
    if (path.isNotEmpty && File(path).existsSync()) return path;
  }
  return null;
}
