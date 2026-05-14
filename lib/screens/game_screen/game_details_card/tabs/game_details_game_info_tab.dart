import 'dart:io';
import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:neostation/l10n/app_locale.dart';
import 'package:provider/provider.dart';
import 'package:video_player/video_player.dart';
import '../../../../models/system_model.dart';
import '../../../../models/game_model.dart';
import '../../../../providers/file_provider.dart';
import '../../../../providers/sqlite_config_provider.dart';
import '../../../../services/screenscraper_service.dart';
import '../../../../services/sfx_service.dart';
import '../../../../utils/game_utils.dart';
import '../widgets/scrolling_description_text.dart';

/// A tab component that renders comprehensive game metadata, descriptions, and media previews.
///
/// Handles media arbitration (prioritizing video over screenshots), dynamic aspect ratio
/// calculation for non-standard artwork, and real-time scraping progress visualization.
class GameDetailsGameInfoTab extends StatefulWidget {
  final SystemModel system;
  final GameModel game;
  final FileProvider fileProvider;
  final String description;
  final String screenshotPath;
  final bool isScrapingGame;
  final double scrapeProgress;
  final String scrapeStatus;
  final bool isSecondaryScreenActive;
  final bool isVideoDelayActive;
  final VideoPlayerController? videoController;
  final int imageVersion;
  final VoidCallback onToggleVideoMute;
  final VoidCallback onScrapeGame;

  const GameDetailsGameInfoTab({
    super.key,
    required this.system,
    required this.game,
    required this.fileProvider,
    required this.description,
    required this.screenshotPath,
    required this.isScrapingGame,
    required this.scrapeProgress,
    required this.scrapeStatus,
    required this.isSecondaryScreenActive,
    required this.isVideoDelayActive,
    this.videoController,
    required this.imageVersion,
    required this.onToggleVideoMute,
    required this.onScrapeGame,
  });

  @override
  State<GameDetailsGameInfoTab> createState() => _GameDetailsGameInfoTabState();
}

class _GameDetailsGameInfoTabState extends State<GameDetailsGameInfoTab> {
  /// Local cache for resolved image aspect ratios to prevent jitter during layout.
  final Map<String, double> _imageAspectRatios = {};

  ImageStream? _currentImageStream;
  ImageStreamListener? _currentImageListener;

  /// Asynchronously resolves the intrinsic aspect ratio of a local image file.
  void _loadImageAspectRatio(String path) {
    if (_imageAspectRatios.containsKey(path) || path.isEmpty) return;

    final File file = File(path);
    if (!file.existsSync()) return;

    // Remove any pending listener from a previous path to avoid leaks.
    _removeImageListener();

    final Image image = Image.file(file);
    final ImageStream stream = image.image.resolve(const ImageConfiguration());

    final listener = ImageStreamListener((
      ImageInfo info,
      bool synchronousCall,
    ) {
      if (mounted) {
        final double aspectRatio = info.image.width / info.image.height;
        if (aspectRatio > 0 && (_imageAspectRatios[path] != aspectRatio)) {
          setState(() {
            _imageAspectRatios[path] = aspectRatio;
          });
        }
      }
    });

    stream.addListener(listener);
    _currentImageStream = stream;
    _currentImageListener = listener;
  }

  void _removeImageListener() {
    if (_currentImageStream != null && _currentImageListener != null) {
      _currentImageStream!.removeListener(_currentImageListener!);
      _currentImageStream = null;
      _currentImageListener = null;
    }
  }

  @override
  void dispose() {
    _removeImageListener();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final description = widget.description;
    final screenshotPath = widget.screenshotPath;

    // Check if the metadata is functionally empty to determine the initial view state.
    final bool showScrapeView =
        description.isEmpty ||
        description == AppLocale.noDescription.getString(context) ||
        description.trim().isEmpty;

    return Positioned(
      left: 12.r,
      right: 12.r,
      top: 55.r,
      bottom: 98.r,
      child: Container(
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
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header Section: Title and metadata summary pills.
            Padding(
              padding: EdgeInsets.fromLTRB(8.r, 8.r, 8.r, 0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(
                        Symbols.info_rounded,
                        color: Theme.of(context).colorScheme.onSurface,
                        size: 13.r,
                      ),
                      SizedBox(width: 6.r),
                      Text(
                        AppLocale.gameInfo.getString(context),
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.onSurface,
                          fontSize: 12.r,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const Spacer(),
                      if (!showScrapeView &&
                          !widget.isScrapingGame &&
                          (widget.game.developer.isNotEmpty ||
                              widget.game.players.isNotEmpty ||
                              widget.game.year.isNotEmpty))
                        Row(
                          children: [
                            if (widget.game.developer.isNotEmpty)
                              _InfoPill(
                                icon: Symbols.business_rounded,
                                text: widget.game.developer,
                              ),
                            if (widget.game.players.isNotEmpty)
                              _InfoPill(
                                icon: Symbols.people_rounded,
                                text: widget.game.players,
                              ),
                            if (widget.game.year.isNotEmpty)
                              _InfoPill(
                                icon: Symbols.calendar_today_rounded,
                                text:
                                    RegExp(
                                      r'\d{4}',
                                    ).stringMatch(widget.game.year) ??
                                    widget.game.year,
                              ),
                          ],
                        ),
                    ],
                  ),
                  Divider(
                    color: Theme.of(
                      context,
                    ).colorScheme.onSurface.withValues(alpha: 0.1),
                    height: 10.r,
                  ),
                ],
              ),
            ),

            // Content Section: Dynamic switching between scraping, missing, and resolved states.
            Expanded(
              child: Padding(
                padding: EdgeInsets.all(8.r),
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    if (widget.isScrapingGame &&
                        !widget.isSecondaryScreenActive) {
                      return _buildScrapingProgressView();
                    }

                    return showScrapeView
                        ? _buildNonScrapedView()
                        : _buildScrapedView(description, screenshotPath);
                  },
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Renders a deterministic progress visualization for active scraping operations.
  Widget _buildScrapingProgressView() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            padding: EdgeInsets.all(16.r),
            decoration: BoxDecoration(
              color: Theme.of(
                context,
              ).colorScheme.primary.withValues(alpha: 0.1),
              shape: BoxShape.circle,
            ),
            child: SizedBox(
              width: 24.r,
              height: 24.r,
              child: CircularProgressIndicator(
                strokeWidth: 3,
                color: Theme.of(context).colorScheme.primary,
              ),
            ),
          ),
          SizedBox(height: 24.r),
          Text(
            AppLocale.scrapingGameData.getString(context),
            style: TextStyle(
              color: Theme.of(context).colorScheme.onSurface,
              fontSize: 18.r,
              fontWeight: FontWeight.bold,
            ),
          ),
          SizedBox(height: 12.r),
          SizedBox(
            width: 250.r,
            child: Column(
              children: [
                LinearProgressIndicator(
                  value: widget.scrapeProgress,
                  backgroundColor: Colors.white10,
                  color: Theme.of(context).colorScheme.primary,
                  borderRadius: BorderRadius.circular(4.r),
                ),
                SizedBox(height: 8.r),
                Text(
                  widget.scrapeStatus,
                  style: TextStyle(
                    color: Theme.of(
                      context,
                    ).colorScheme.onSurface.withValues(alpha: 0.6),
                    fontSize: 10.r,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// Renders a placeholder view for games missing local metadata assets.
  Widget _buildNonScrapedView() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            AppLocale.incompleteMetadata.getString(context),
            style: TextStyle(
              color: Theme.of(context).colorScheme.onSurface,
              fontSize: 20.r,
              fontWeight: FontWeight.bold,
            ),
          ),
          SizedBox(height: 12.r),
          SizedBox(
            width: 300.r,
            child: Text(
              AppLocale.scrapeToDownload.getString(context),
              textAlign: TextAlign.center,
              style: TextStyle(
                color: Theme.of(
                  context,
                ).colorScheme.onSurface.withValues(alpha: 0.7),
                fontSize: 12.r,
                height: 1.5,
              ),
            ),
          ),
          SizedBox(height: 32.r),
          FutureBuilder<bool>(
            future: ScreenScraperService.hasSavedCredentials(),
            builder: (context, snapshot) {
              if (widget.system.folderName == 'android-apps') {
                return Text(
                  AppLocale.scrapingUnavailableAndroid.getString(context),
                  style: TextStyle(fontSize: 10.r, color: Colors.grey),
                );
              }
              final hasCredentials = snapshot.data ?? false;
              if (!hasCredentials) {
                return Text(
                  AppLocale.loginToScrape.getString(context),
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.error,
                    fontSize: 10.r,
                    fontStyle: FontStyle.italic,
                  ),
                );
              }

              return const SizedBox.shrink();
            },
          ),
        ],
      ),
    );
  }

  /// Main metadata view containing descriptions and media previews.
  Widget _buildScrapedView(String description, String screenshotPath) {
    return Column(
      children: [
        Expanded(
          child: Padding(
            padding: EdgeInsets.symmetric(horizontal: 12.r),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                  flex: 2,
                  child: ScrollingDescriptionText(
                    text: GameUtils.cleanupDescription(description),
                    style: TextStyle(
                      color: Theme.of(
                        context,
                      ).colorScheme.onSurface.withValues(alpha: 0.8),
                      fontSize: 11.r,
                      height: 1.6,
                    ),
                  ),
                ),
                SizedBox(width: 16.r),
                Expanded(flex: 3, child: _buildMediaPreview(screenshotPath)),
              ],
            ),
          ),
        ),
        SizedBox(height: 8.r),
      ],
    );
  }

  /// Manages media arbitration and rendering for screenshots or video previews.
  Widget _buildMediaPreview(String screenshotPath) {
    final bool hasVideo =
        widget.videoController != null &&
        widget.videoController!.value.isInitialized;

    if (screenshotPath.isNotEmpty) {
      _loadImageAspectRatio(screenshotPath);
    }

    double mediaAspectRatio = 16 / 9;

    // Prioritize video aspect ratio if active; fall back to resolved image ratio.
    if (!widget.isVideoDelayActive && hasVideo) {
      mediaAspectRatio = widget.videoController!.value.aspectRatio;
    } else if (_imageAspectRatios.containsKey(screenshotPath)) {
      mediaAspectRatio = _imageAspectRatios[screenshotPath]!;
    }

    // Defensive check to avoid layout breaks.
    if (mediaAspectRatio <= 0 || mediaAspectRatio.isNaN) {
      mediaAspectRatio = 16 / 9;
    }

    return Center(
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(6.r),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.25),
              blurRadius: 2.r,
              offset: Offset(2.0.r, 2.0.r),
            ),
          ],
          color: Colors.transparent,
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(6.r),
          clipBehavior: Clip.antiAlias,
          child: AspectRatio(
            aspectRatio: mediaAspectRatio,
            child: Stack(
              fit: StackFit.expand,
              children: [
                // Render Video Layer.
                if (!widget.isVideoDelayActive &&
                    hasVideo &&
                    widget.videoController!.value.isInitialized &&
                    widget.videoController!.value.size.width > 0 &&
                    widget.videoController!.value.size.height > 0) ...[
                  Consumer<SqliteConfigProvider>(
                    builder: (context, config, child) {
                      return VideoPlayer(widget.videoController!);
                    },
                  ),
                ] else if (File(screenshotPath).existsSync()) ...[
                  // Fallback: Render Screenshot Layer.
                  Image.file(
                    File(screenshotPath),
                    height: double.infinity,
                    cacheHeight: 720,
                    filterQuality: FilterQuality.medium,
                    isAntiAlias: true,
                    key: ValueKey(
                      '${screenshotPath}_fg_${widget.imageVersion}',
                    ),
                    fit: BoxFit.cover,
                    errorBuilder: (_, _, _) => const SizedBox.shrink(),
                  ),
                ] else
                  Center(
                    child: Icon(
                      Symbols.videogame_asset_rounded,
                      size: 48.r,
                      color: Colors.white24,
                    ),
                  ),

                // Audio Status Indicator (Floating Overlay).
                if (!widget.isVideoDelayActive && hasVideo)
                  Positioned(
                    bottom: 8.r,
                    right: 8.r,
                    child: ExcludeFocus(
                      child: Material(
                        color: Colors.black54,
                        borderRadius: BorderRadius.circular(6.r),
                        child: InkWell(
                          onTap: () {
                            SfxService().playNavSound();
                            widget.onToggleVideoMute();
                          },
                          canRequestFocus: false,
                          focusColor: Colors.transparent,
                          hoverColor: Colors.transparent,
                          highlightColor: Colors.transparent,
                          splashColor: Colors.transparent,
                          borderRadius: BorderRadius.circular(12.r),
                          child: Padding(
                            padding: EdgeInsets.symmetric(
                              horizontal: 8.r,
                              vertical: 4.r,
                            ),
                            child: Consumer<SqliteConfigProvider>(
                              builder: (context, configProvider, child) {
                                final isMuted =
                                    !configProvider.config.videoSound;
                                return Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Image.asset(
                                      'assets/images/gamepad/Xbox_Menu_button.png',
                                      width: 14.r,
                                      height: 14.r,
                                      color: Colors.white,
                                    ),
                                    SizedBox(width: 4.r),
                                    Icon(
                                      isMuted
                                          ? Symbols.volume_off_rounded
                                          : Symbols.volume_up_rounded,
                                      size: 12.r,
                                      color: Colors.white,
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
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// A compact metadata indicator styled as a pill badge.
class _InfoPill extends StatelessWidget {
  final IconData icon;
  final String text;

  const _InfoPill({required this.icon, required this.text});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: 4.r),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            icon,
            size: 10.r,
            color: Theme.of(
              context,
            ).colorScheme.onSurface.withValues(alpha: 0.6),
          ),
          SizedBox(width: 4.r),
          Text(
            text,
            style: TextStyle(
              fontSize: 9.r,
              color: Theme.of(
                context,
              ).colorScheme.onSurface.withValues(alpha: 0.6),
            ),
          ),
        ],
      ),
    );
  }
}
