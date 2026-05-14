import 'dart:io';
import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:neostation/services/sfx_service.dart';
import 'package:provider/provider.dart';
import '../../../models/game_model.dart';
import '../../../services/music_player_service.dart';
import '../../../utils/game_utils.dart';
import '../../../utils/centered_scroll_controller.dart';
import '../../../widgets/marquee_text.dart';
import '../../../models/system_model.dart';
import '../../../providers/neo_assets_provider.dart';
import '../../../widgets/system_logo_fallback.dart';

/// A specialized list view for the Music system, optimized for rapid track navigation and playback status.
///
/// Integrates with [MusicPlayerService] for synchronized metadata and [CenteredScrollController]
/// for consistent visual anchoring during gamepad navigation. Supports pulsating indicators
/// for active playback and dynamic logo resolution.
class MusicList extends StatefulWidget {
  final SystemModel system;
  final List<GameModel> tracks;
  final int selectedIndex;
  final Function(GameModel) onTrackSelected;
  final Color systemColor;
  final VoidCallback onBack;
  final VoidCallback onRandom;

  /// Indicates if the user is scrolling rapidly, triggering optimized animation durations.
  final bool isNavigatingFast;

  const MusicList({
    super.key,
    required this.system,
    required this.tracks,
    required this.selectedIndex,
    required this.onTrackSelected,
    required this.systemColor,
    required this.onBack,
    required this.onRandom,
    this.isNavigatingFast = false,
  });

  @override
  State<MusicList> createState() => _MusicListState();
}

class _MusicListState extends State<MusicList> with TickerProviderStateMixin {
  late final CenteredScrollController _centeredScrollController;
  late AnimationController _selectionController;
  late Animation<double> _selectionAnimation;

  static const double _itemHeightBase = 26.0;

  @override
  void initState() {
    super.initState();
    _centeredScrollController = CenteredScrollController(centerPosition: 0.5);
    _selectionController = AnimationController(
      duration: const Duration(milliseconds: 120),
      vsync: this,
    );
    _selectionAnimation = AlwaysStoppedAnimation(
      widget.selectedIndex.toDouble(),
    );

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _centeredScrollController.initialize(
          context: context,
          initialIndex: widget.selectedIndex,
          totalItems: widget.tracks.length,
        );
      }
    });

    // Sync the background service with the current view state.
    MusicPlayerService().setPlaylist(widget.tracks);
    if (widget.tracks.isNotEmpty) {
      MusicPlayerService().setIndex(widget.selectedIndex);
    }
  }

  @override
  void didUpdateWidget(MusicList oldWidget) {
    super.didUpdateWidget(oldWidget);

    // Handle structural playlist changes.
    if (oldWidget.tracks != widget.tracks) {
      _centeredScrollController.updateTotalItems(widget.tracks.length);
      MusicPlayerService().setPlaylist(widget.tracks);
    }

    // Handle index updates with dynamic animation duration arbitration.
    if (oldWidget.selectedIndex != widget.selectedIndex) {
      final animationDuration = widget.isNavigatingFast
          ? const Duration(milliseconds: 120)
          : const Duration(milliseconds: 250);

      final scrollDuration = widget.isNavigatingFast
          ? const Duration(milliseconds: 180)
          : const Duration(milliseconds: 360);

      const curve = Curves.easeOutQuart;

      final double begin = _selectionAnimation.value;
      final double end = widget.selectedIndex.toDouble();

      _selectionController.duration = animationDuration;
      _selectionAnimation = Tween<double>(
        begin: begin,
        end: end,
      ).animate(CurvedAnimation(parent: _selectionController, curve: curve));

      _selectionController.forward(from: 0);
      _centeredScrollController.updateSelectedIndex(widget.selectedIndex);
      _centeredScrollController.scrollToIndex(
        widget.selectedIndex,
        duration: scrollDuration,
        curve: curve,
      );

      // Refresh metadata in the background service (non-destructive to playback).
      MusicPlayerService().setIndex(widget.selectedIndex);
    }
  }

  @override
  void dispose() {
    _centeredScrollController.dispose();
    _selectionController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final itemHeight = _itemHeightBase.r;
    final totalItemHeight = itemHeight;

    return ListenableBuilder(
      listenable: MusicPlayerService(),
      builder: (context, _) {
        return Column(
          children: [
            _buildHeader(),
            Expanded(
              child: Stack(
                children: [
                  // Synchronized Selection Highlight: Moves fluidly behind the track labels.
                  AnimatedBuilder(
                    animation: Listenable.merge([
                      _selectionController,
                      _centeredScrollController.scrollController,
                    ]),
                    builder: (context, child) {
                      if (!_centeredScrollController
                          .scrollController
                          .hasClients) {
                        return const SizedBox.shrink();
                      }

                      final double scrollOffset =
                          _centeredScrollController.scrollController.offset;
                      final double currentSelection = _selectionAnimation.value;

                      final topPosition =
                          (currentSelection * totalItemHeight) +
                          2.r -
                          scrollOffset;

                      return Positioned(
                        top: topPosition,
                        left: 8.r,
                        right: 0.r,
                        height: itemHeight,
                        child: Container(
                          decoration: BoxDecoration(
                            color: theme.colorScheme.secondary,
                            borderRadius: BorderRadius.circular(8.r),
                          ),
                        ),
                      );
                    },
                  ),

                  // Primary Scrollable Track List.
                  ListView.builder(
                    controller: _centeredScrollController.scrollController,
                    padding: EdgeInsets.symmetric(
                      vertical: 2.r,
                      horizontal: 8.r,
                    ),
                    itemCount: widget.tracks.length,
                    itemBuilder: (context, index) {
                      final track = widget.tracks[index];
                      final isSelected = index == widget.selectedIndex;
                      final isPlaying =
                          MusicPlayerService().isPlaying &&
                          MusicPlayerService().activeTrack?.romPath ==
                              track.romPath;
                      final isLooping = MusicPlayerService().isLoopingFor(
                        track.romPath,
                      );

                      return GestureDetector(
                        onTap: () {
                          SfxService().playNavSound();
                          widget.onTrackSelected(track);
                        },
                        child: Container(
                          height: totalItemHeight,
                          color: Colors.transparent,
                          child: Container(
                            padding: EdgeInsets.symmetric(
                              horizontal: 8.r,
                              vertical: 2.r,
                            ),
                            alignment: Alignment.centerLeft,
                            child: Row(
                              children: [
                                if (isPlaying) ...[
                                  const _PulsatingIndicator(),
                                  SizedBox(width: 6.r),
                                ],
                                if (isLooping) ...[
                                  Icon(
                                    Symbols.repeat_one_rounded,
                                    size: 11.r,
                                    color: Colors.white.withValues(alpha: 0.8),
                                  ),
                                  SizedBox(width: 6.r),
                                ],
                                if (track.isFavorite == true) ...[
                                  Icon(
                                    Symbols.favorite_rounded,
                                    size: 10.r,
                                    color: Colors.redAccent.withValues(
                                      alpha: 0.9,
                                    ),
                                  ),
                                  SizedBox(width: 6.r),
                                ],
                                Expanded(
                                  child: AnimatedDefaultTextStyle(
                                    duration: const Duration(milliseconds: 200),
                                    curve: Curves.easeOut,
                                    style: TextStyle(
                                      color: isSelected
                                          ? Colors.white
                                          : theme.colorScheme.onSurface,
                                      fontSize: 11.r,
                                      fontWeight: isSelected
                                          ? FontWeight.bold
                                          : FontWeight.normal,
                                      fontFamily: theme
                                          .textTheme
                                          .bodyMedium
                                          ?.fontFamily,
                                    ),
                                    child: MarqueeText(
                                      text: GameUtils.formatGameName(
                                        track.name,
                                      ),
                                      isActive: isSelected,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }

  /// Builds the system identity header with multi-tiered logo resolution logic.
  Widget _buildHeader() {
    context.select<NeoAssetsProvider, String>((p) => p.activeThemeFolder);

    final folderName = widget.system.primaryFolderName;
    final assetLogoPath = 'assets/images/systems/logos/$folderName.webp';
    final customLogoPath = widget.system.customLogoPath;
    final hasCustomLogo = customLogoPath != null && customLogoPath.isNotEmpty;
    final neoAssets = context.read<NeoAssetsProvider>();
    final themeLogoPath = hasCustomLogo
        ? null
        : neoAssets.getLogoForSystemSync(folderName);

    Widget fallback() => Center(
      child: SystemLogoFallback(
        title: widget.system.realName,
        shortName: widget.system.shortName,
        height: 32.r,
      ),
    );

    Widget logoWidget;
    // Resolution Priority: User-defined Custom Logo > Theme-specific Logo > Built-in Asset Logo > Text Fallback.
    if (customLogoPath != null && customLogoPath.isNotEmpty) {
      logoWidget = Image.file(
        File(customLogoPath),
        key: ValueKey('${customLogoPath}_${widget.system.imageVersion}'),
        fit: BoxFit.contain,
        filterQuality: FilterQuality.medium,
        isAntiAlias: true,
        cacheWidth: 256,
        errorBuilder: (context, error, stackTrace) => Image.asset(
          assetLogoPath,
          fit: BoxFit.contain,
          filterQuality: FilterQuality.medium,
          isAntiAlias: true,
          cacheWidth: 256,
          errorBuilder: (context, error, stackTrace) => fallback(),
        ),
      );
    } else if (themeLogoPath != null && themeLogoPath.isNotEmpty) {
      logoWidget = Image.file(
        File(themeLogoPath),
        key: ValueKey(themeLogoPath),
        fit: BoxFit.contain,
        filterQuality: FilterQuality.medium,
        isAntiAlias: true,
        cacheWidth: 256,
        errorBuilder: (context, error, stackTrace) => Image.asset(
          assetLogoPath,
          fit: BoxFit.contain,
          filterQuality: FilterQuality.medium,
          isAntiAlias: true,
          cacheWidth: 256,
          errorBuilder: (context, error, stackTrace) => fallback(),
        ),
      );
    } else {
      logoWidget = Image.asset(
        assetLogoPath,
        fit: BoxFit.contain,
        filterQuality: FilterQuality.medium,
        isAntiAlias: true,
        cacheWidth: 256,
        errorBuilder: (context, error, stackTrace) => fallback(),
      );
    }

    return Container(
      height: 60.r,
      margin: EdgeInsets.only(left: 8.r, right: 0.r, top: 8.r, bottom: 4.r),
      child: Stack(
        children: [
          Positioned.fill(
            child: Center(
              child: SizedBox(height: 60.r, child: logoWidget),
            ),
          ),
        ],
      ),
    );
  }
}

/// A subtle pulsating headphone icon indicating active audio playback.
class _PulsatingIndicator extends StatefulWidget {
  const _PulsatingIndicator();

  @override
  State<_PulsatingIndicator> createState() => _PulsatingIndicatorState();
}

class _PulsatingIndicatorState extends State<_PulsatingIndicator>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _animation;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      duration: const Duration(milliseconds: 1000),
      vsync: this,
    )..repeat(reverse: true);
    _animation = Tween<double>(
      begin: 0.6,
      end: 1.0,
    ).animate(CurvedAnimation(parent: _controller, curve: Curves.easeInOut));
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _animation,
      builder: (context, child) {
        return Transform.scale(
          scale: _animation.value,
          child: Opacity(
            opacity: _animation.value,
            child: Icon(Symbols.headphones_rounded, size: 14.r, color: Colors.white),
          ),
        );
      },
    );
  }
}
