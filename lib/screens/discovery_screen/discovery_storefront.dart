import 'package:flutter/material.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:neostation/constants/recent_card_sizes.dart';
import 'package:neostation/models/config_model.dart';
import 'package:neostation/models/database_game_model.dart';
import 'package:neostation/models/discovery_models.dart';
import 'package:neostation/models/my_systems.dart';
import 'package:neostation/providers/file_provider.dart';
import 'package:neostation/providers/sqlite_config_provider.dart';
import 'package:neostation/responsive.dart';
import 'package:neostation/screens/systems_screen/my_systems_section/my_systems_carousel.dart';
import 'package:neostation/screens/systems_screen/my_systems_section/my_systems_grid.dart';
import 'package:provider/provider.dart';

import 'discovery_mosaic.dart';
import 'widgets/discovery_grid_footer.dart';
import 'widgets/discovery_tile.dart';

/// Navigation-layer id the Discovery grid registers under.
const String kDiscoveryGridNavLayerId = 'discovery_grid';

/// Navigation-layer id the Discovery carousel registers under.
const String kDiscoveryCarouselNavLayerId = 'discovery_carousel';

/// The Discovery board: the systems grid or carousel, filled with Discovery
/// cards.
class DiscoveryStorefront extends StatelessWidget {
  const DiscoveryStorefront({
    super.key,
    required this.tiles,
    required this.selectedIndex,
    required this.crossAxisCount,
    required this.viewMode,
    required this.fileProvider,
    required this.onCardTapped,
    required this.onEnterPressed,
    required this.onRerollPressed,
    required this.onBackPressed,
    required this.onOptionsPressed,
    this.shuffleSlotId,
    this.shuffleGame,
  });

  final List<DiscoveryTile> tiles;
  final int selectedIndex;
  final int crossAxisCount;
  final String viewMode;
  final FileProvider fileProvider;

  final void Function(int index) onCardTapped;
  final VoidCallback onEnterPressed;
  final VoidCallback onRerollPressed;
  final VoidCallback onBackPressed;
  final VoidCallback onOptionsPressed;

  final String? shuffleSlotId;
  final DatabaseGameModel? shuffleGame;

  @override
  Widget build(BuildContext context) {
    final cards = _cardsFor(context);
    final config = context.read<SqliteConfigProvider>().config;
    final index = selectedIndex.clamp(0, tiles.length - 1);
    final selectedTile = tiles[index];
    final selectedEntry = selectedTile.entry;
    final gameName =
        selectedEntry?.game.realName ??
        selectedEntry?.game.filename ??
        selectedTile.noticeKey?.getString(context) ??
        selectedTile.labelKey.getString(context);
    final systemShortName =
        selectedEntry?.game.systemShortName ??
        selectedEntry?.game.systemRealName ??
        selectedEntry?.game.systemFolderName ??
        '';

    return Column(
      children: [
        Expanded(
          child: Padding(
            padding: viewMode == 'carousel'
                ? EdgeInsets.only(top: 56.0.r)
                : EdgeInsets.only(left: 6.0.r, right: 6.0.r, top: 46.0.r),
            child: viewMode == 'carousel'
                ? _buildCarousel(context, cards)
                : _buildGrid(context, config, cards),
          ),
        ),
        DiscoveryGridFooter(
          gameName: gameName,
          systemShortName: systemShortName,
          onEnter: onEnterPressed,
          onOptions: onOptionsPressed,
        ),
      ],
    );
  }

  Widget _buildGrid(
    BuildContext context,
    ConfigModel config,
    List<SystemInfo> cards,
  ) {
    return SystemCardGridView(
      crossAxisCount: crossAxisCount,
      // The same 0.8 card shape the systems grid uses with its logo footer.
      childAspectRatio: 0.80,
      // Game of the Week spans two columns like the compact recent card.
      recentCardSize: RecentCardSizes.twoByOne,
      selectedIndex: selectedIndex,
      systems: cards,
      navLayerId: kDiscoveryGridNavLayerId,
      onCardTapped: onCardTapped,
      onEnterPressed: onEnterPressed,
      onEscapePressed: onOptionsPressed,
      onXPressed: onRerollPressed,
      onBackPressed: onBackPressed,
      bindYButton: false,
      // Discovery is part of the tab strip, so bumpers keep cycling tabs.
      enableTabBumpers: true,
      // The grid's host owns the secondary display for Discovery.
      enableSecondaryDisplay: false,
      enableThemeAssets: false,
      enablePullToRescan: false,
      // Pinch cycles the same sizes as the systems grid and persists them
      // separately from the systems grid's own column count.
      enablePinchResize: true,
      pinchSize: config.discoveryGridColumns,
      onPinchSizeChanged: (size) =>
          context.read<SqliteConfigProvider>().updateDiscoveryGridColumns(size),
      crossAxisCountForSize: Responsive.getDiscoveryCrossAxisCountFromSize,
      cardOverrideBuilder: (context, index, info, isSelected, onTap) =>
          _buildCard(
            context,
            index,
            info,
            isSelected,
            onTap,
            heroFooterUsesHalfWidth: true,
          ),
    );
  }

  Widget _buildCarousel(BuildContext context, List<SystemInfo> cards) {
    return MySystemsCarousel(
      selectedIndex: selectedIndex,
      items: cards,
      onCardTapped: onCardTapped,
      onActivate: (_) => onEnterPressed(),
      onOptions: (_) => onOptionsPressed(),
      onBackPressed: onBackPressed,
      onXPressed: onRerollPressed,
      bindYButton: false,
      navLayerId: kDiscoveryCarouselNavLayerId,
      cardOverrideBuilder: (context, index, info, isSelected, onTap) =>
          _buildCard(
            context,
            index,
            info,
            isSelected,
            onTap,
            heroFooterUsesHalfWidth: false,
          ),
      enableTabBumpers: true,
      enablePullToRescan: false,
      enableSecondaryDisplay: false,
      enableThemeAssets: false,
      enableDynamicBackground: false,
      showCardCounts: false,
      hideSystemLogos: false,
    );
  }

  Widget _buildCard(
    BuildContext context,
    int index,
    SystemInfo info,
    bool isSelected,
    VoidCallback onTap, {
    required bool heroFooterUsesHalfWidth,
  }) {
    return DiscoveryCard(
      tile: _present(tiles[index]),
      isSelected: isSelected,
      fileProvider: fileProvider,
      onTap: onTap,
      heroFooterUsesHalfWidth: heroFooterUsesHalfWidth,
    );
  }

  /// One [SystemInfo] per tile, only so the systems grid can pack the spans and
  /// keep its keys stable. The visible card is always [DiscoveryCard].
  List<SystemInfo> _cardsFor(BuildContext context) {
    return [
      for (final tile in tiles)
        SystemInfo(
          title:
              tile.entry?.game.realName ??
              tile.entry?.game.filename ??
              tile.labelKey.getString(context),
          folderName: tile.entry?.game.systemFolderName,
          primaryFolderName: tile.entry?.game.systemFolderName,
          isGame: tile.kind == DiscoveryTileKind.hero,
        ),
    ];
  }

  /// The tile as it should be drawn this frame.
  ///
  /// Everything but the game itself comes from the real tile; only a slot in
  /// the middle of a re-roll shows something else.
  DiscoveryTile _present(DiscoveryTile tile) {
    final game = shuffleGame;
    final slotId = shuffleSlotId;
    final entry = tile.entry;
    if (game == null || slotId == null || entry == null) return tile;
    if (entry.pick.slotId != slotId) return tile;
    return tile.withEntry(DiscoveryBoardEntry(pick: entry.pick, game: game));
  }
}
