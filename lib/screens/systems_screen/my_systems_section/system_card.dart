import 'package:flutter/material.dart';
import 'package:neostation/l10n/app_locale.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:neostation/constants/system_folder_names.dart';
import 'package:neostation/models/my_systems.dart';
import 'package:neostation/providers/neo_assets_provider.dart';
import 'package:neostation/services/music_player_service.dart';
import 'package:neostation/services/sfx_service.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:provider/provider.dart';
import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import '../../../themes/corner_radii.dart';
import '../../../widgets/shaders/shader_gif_widget.dart';
import '../../../widgets/shaders/music_card_shader_background.dart';
import '../../../utils/image_utils.dart';
import '../../../widgets/cover_mosaic.dart';
import '../../../widgets/system_logo_fallback.dart';
import '../../../utils/game_utils.dart';
import '../../../utils/count_label.dart';

/// Replaces the card the systems grid/carousel would otherwise build for one
/// entry.
///
/// Returning null falls through to the ordinary [SystemCard], so a caller only
/// describes the entries that are not systems and every other card is still
/// rendered by the systems widgets themselves. The collections browser uses it
/// for exactly one entry — the trailing "New collection" card, which is an icon
/// and a label rather than artwork plus a logo.
typedef SystemCardOverrideBuilder =
    Widget? Function(
      BuildContext context,
      int index,
      SystemInfo info,
      bool isSelected,
      VoidCallback onTap,
    );

/// A premium card component representing a system or a 'Recent Game' entry.
///
/// Supports dynamic background effects (GIFs, Shaders, Music Covers), localized
/// metadata display, and specialized layouts for 'Recent Games'.
class SystemCard extends StatefulWidget {
  const SystemCard({
    super.key,
    required this.info,
    this.onTap,
    this.onLongPress,
    this.isSelected = false,
    this.backgroundCacheWidth = 512,
    this.showCount = false,
  });

  /// The system or game metadata resolved for this card.
  final SystemInfo info;

  /// Interaction callback for pointer/controller selection.
  final VoidCallback? onTap;

  /// Touch route to the card's context menu, i.e. what Y does on a pad.
  ///
  /// Null leaves the card without a long-press gesture at all rather than
  /// giving it an inert one, so a host that has no menu costs nothing.
  final VoidCallback? onLongPress;

  /// Whether this card currently has visual focus in the grid.
  final bool isSelected;

  /// Whether the card names its own count in a pill over its artwork.
  ///
  /// Off by default because it only pays for itself on a large card, where
  /// the pill has artwork to sit on without crowding it. The systems carousel
  /// turns it on; the grid puts the count in its footer instead, and the
  /// collections browser has a footer of its own that already carries it.
  ///
  /// The pill floats over the artwork rather than taking a row under the
  /// logo. That row is what the logo scales into: on the carousel the strip
  /// is only ~60px tall, so a count row inside it left the logo smaller than
  /// the word beneath it, and reserving the row's height on the card instead
  /// only moved the cost onto the artwork. Floating it costs neither.
  final bool showCount;

  /// Decode width for the card's background image. Defaults to 512 (grid
  /// cards); the carousel passes 1024 since its cards are much larger.
  final int backgroundCacheWidth;

  @override
  State<SystemCard> createState() => _SystemCardState();
}

class _SystemCardState extends State<SystemCard> {
  late final FocusNode _focusNode;
  late final GlobalKey _contentStackKey;
  final MusicPlayerService _musicPlayerService = MusicPlayerService();

  /// In-memory cache for resolved ID3v2 album art.
  Uint8List? _resolvedMusicCoverBytes;
  bool _isResolvingMusicCover = false;
  String? _coverResolutionPath;
  String? _lastActiveTrackPath;

  String? _themeBackgroundPath;
  String _lastThemeFolder = '';

  /// Cached wheel file and existence check — computed once, not on every build.
  File? _cachedWheelFile;
  bool _cachedHasWheelFile = false;

  /// Hierarchy for music cover resolution:
  /// Active Instance Art > Cached Resolved Art > Last Known Picture.
  Uint8List? get _musicCoverBytes =>
      _musicPlayerService.activePicture ??
      _resolvedMusicCoverBytes ??
      _musicPlayerService.currentPicture;

  @override
  void initState() {
    super.initState();
    _focusNode = FocusNode(skipTraversal: true);
    _contentStackKey = GlobalKey(
      debugLabel: 'system_card_${widget.info.title}',
    );
    _musicPlayerService.addListener(_handleMusicStateChanged);
    _handleMusicStateChanged();
    _resolveWheelFile();
  }

  void _resolveWheelFile() {
    final customWheelPath = widget.info.customWheelImage;
    if (widget.info.isGame &&
        customWheelPath != null &&
        customWheelPath.isNotEmpty) {
      _cachedWheelFile = File(customWheelPath);
      _cachedHasWheelFile = _cachedWheelFile!.existsSync();
    } else {
      _cachedWheelFile = null;
      _cachedHasWheelFile = false;
    }
  }

  @override
  void didUpdateWidget(SystemCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    final folderChanged =
        oldWidget.info.folderName != widget.info.folderName ||
        oldWidget.info.primaryFolderName != widget.info.primaryFolderName;
    if (folderChanged) {
      _themeBackgroundPath = null;
      _lastThemeFolder = '';
    }
    if (oldWidget.info.customWheelImage != widget.info.customWheelImage ||
        folderChanged) {
      _resolveWheelFile();
    }
  }

  @override
  void dispose() {
    _musicPlayerService.removeListener(_handleMusicStateChanged);
    _focusNode.dispose();
    super.dispose();
  }

  /// Synchronizes the card visual state with the global music player state.
  void _handleMusicStateChanged() {
    if (!mounted || widget.info.folderName != 'music') return;

    final activePath = _musicPlayerService.activeTrack?.romPath;
    if (activePath != _lastActiveTrackPath) {
      _lastActiveTrackPath = activePath;
      _coverResolutionPath = null;
      if (_resolvedMusicCoverBytes != null) {
        setState(() {
          _resolvedMusicCoverBytes = null;
        });
      }
    }

    final immediateCover =
        _musicPlayerService.activePicture ?? _musicPlayerService.currentPicture;
    if (immediateCover != null) {
      if (!listEquals(immediateCover, _resolvedMusicCoverBytes)) {
        setState(() {
          _resolvedMusicCoverBytes = immediateCover;
        });
      }
      return;
    }

    if (_musicPlayerService.isPlaying) {
      _tryResolveMusicCover();
      return;
    }

    if (_resolvedMusicCoverBytes != null) {
      setState(() {
        _resolvedMusicCoverBytes = null;
      });
    }
  }

  /// Attempts to extract album art from the filesystem for the current track.
  Future<void> _tryResolveMusicCover() async {
    if (_isResolvingMusicCover) return;

    final path =
        _musicPlayerService.activeTrack?.romPath ??
        _musicPlayerService.currentTrack?.romPath;
    if (path == null || path.isEmpty) return;

    _isResolvingMusicCover = true;
    _coverResolutionPath = path;
    try {
      final bytes = await _musicPlayerService.extractPicture(path);
      if (!mounted) return;
      if (_coverResolutionPath != path) return;
      if (bytes == null) return;
      setState(() {
        _resolvedMusicCoverBytes = bytes;
      });
    } finally {
      _isResolvingMusicCover = false;
    }
  }

  /// Logic check for rendering the specialized music playback background shader.
  bool get _shouldShowMusicPlaybackBackground =>
      widget.info.folderName == 'music' &&
      _musicPlayerService.isPlaying &&
      _musicCoverBytes != null;

  @override
  Widget build(BuildContext context) {
    // Subscribe to theme folder changes — only re-resolve assets when theme actually changes.
    final themeFolder = context.select<NeoAssetsProvider, String>(
      (p) => p.activeThemeFolder,
    );

    if (!widget.info.isGame && themeFolder != _lastThemeFolder) {
      _lastThemeFolder = themeFolder;
      final neoAssets = context.read<NeoAssetsProvider>();
      final folderName =
          widget.info.primaryFolderName ?? widget.info.folderName ?? '';

      _themeBackgroundPath =
          widget.info.customBackgroundPath?.isNotEmpty == true
          ? null
          : neoAssets.getBackgroundForSystemSync(folderName);
    }

    return Padding(
      padding: EdgeInsets.all(2.r),
      child: MouseRegion(
        cursor: SystemMouseCursors.basic,
        child: Container(
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surface,
            borderRadius:
                Theme.of(context).extension<CornerRadii>()?.radiusExternal ??
                BorderRadius.circular(14.r),
            border: Border.all(
              color: Theme.of(context).colorScheme.outline,
              width: 1.r,
            ),
            boxShadow: [
              BoxShadow(
                color: Theme.of(
                  context,
                ).colorScheme.shadow.withValues(alpha: 0.1),
                blurRadius: 4.r,
                offset: Offset(2.0.r, 2.0.r),
              ),
            ],
          ),
          child: ClipRRect(
            borderRadius:
                Theme.of(context).extension<CornerRadii>()?.radiusInternal ??
                BorderRadius.circular(9.r),
            child: InkWell(
              focusNode: _focusNode,
              onTap: () {
                // A tap on the already-selected card confirms it rather than
                // moving the selection (touch users have no A button), so it
                // earns the enter sound instead of the nav sound.
                if (widget.isSelected) {
                  SfxService().playEnterSound();
                } else {
                  SfxService().playNavSound();
                }
                widget.onTap?.call();
              },
              // No sound here: every host opens a menu from this callback and
              // plays its own, so playing one too would double it.
              onLongPress: widget.onLongPress,
              canRequestFocus: false,
              focusColor: Colors.transparent,
              hoverColor: Colors.transparent,
              highlightColor: Colors.transparent,
              splashColor: Colors.transparent,
              child: Padding(
                padding: EdgeInsets.only(
                  top: 4.r,
                  bottom: 0.r,
                  left: 4.r,
                  right: 4.r,
                ),
                child: widget.info.isGame
                    ? Column(
                        children: [
                          Expanded(
                            child: Stack(
                              key: _contentStackKey,
                              children: [
                                _buildSystemBackground(),
                                _buildGameMainContent(context),
                              ],
                            ),
                          ),
                          _buildGameFooter(context),
                        ],
                      )
                    : Column(
                        children: [
                          AspectRatio(
                            aspectRatio: 1,
                            child: Stack(
                              key: _contentStackKey,
                              children: [
                                _buildSystemBackground(),
                                if (widget.showCount) _buildCountPill(context),
                              ],
                            ),
                          ),
                          _buildSystemFooter(context),
                        ],
                      ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// Orchestrates background rendering, selecting between static images,
  /// music cover shaders, or GIF animators.
  Widget _buildSystemBackground() {
    if (widget.info.folderName == 'music') {
      return AnimatedBuilder(
        animation: _musicPlayerService,
        builder: (context, child) {
          if (_shouldShowMusicPlaybackBackground) {
            return Positioned.fill(
              child: MusicCardShaderBackground(
                key: ValueKey(
                  _musicPlayerService.activeTrack?.romPath ??
                      _musicPlayerService.currentTrack?.romPath,
                ),
                coverBytes: _musicCoverBytes!,
                tintColor:
                    widget.info.color1AsColor ??
                    Theme.of(context).colorScheme.primary,
                borderRadius:
                    Theme.of(
                      context,
                    ).extension<CornerRadii>()?.radiusInternalRadius ??
                    12.r,
                opacity: 1.0,
              ),
            );
          }

          return _buildDefaultSystemBackground();
        },
      );
    }

    return _buildDefaultSystemBackground();
  }

  /// Standard background resolution logic for all system cards.
  Widget _buildDefaultSystemBackground() {
    final customBgPath = widget.info.customBackgroundPath;
    final hasCustomBg = customBgPath != null && customBgPath.isNotEmpty;

    // SCENARIO A: Animated GIF (custom or theme-provided).
    if (hasCustomBg && ImageUtils.isGif(customBgPath)) {
      return Positioned.fill(
        child: ClipRRect(
          borderRadius:
              Theme.of(context).extension<CornerRadii>()?.radiusInternal ??
              BorderRadius.circular(9.r),
          child: Container(
            color: Theme.of(context).colorScheme.surface,
            child: ShaderGifWidget(
              imagePath: customBgPath,
              key: ValueKey('${customBgPath}_${widget.info.imageVersion}'),
            ),
          ),
        ),
      );
    }

    // SCENARIO B: Animated GIF from theme.
    if (!hasCustomBg && ImageUtils.isGif(_themeBackgroundPath)) {
      return Positioned.fill(
        child: ClipRRect(
          borderRadius:
              Theme.of(context).extension<CornerRadii>()?.radiusInternal ??
              BorderRadius.circular(9.r),
          child: Container(
            color: Theme.of(context).colorScheme.surface,
            child: ShaderGifWidget(
              imagePath: _themeBackgroundPath!,
              key: ValueKey(
                '${_themeBackgroundPath}_${widget.info.imageVersion}',
              ),
            ),
          ),
        ),
      );
    }

    // SCENARIO C: Static image (Custom or Theme-provided).
    //
    // A mosaic outranks the theme path. `resolveBackgroundPathSync` answers
    // with the `<folder>.webp` path whether or not that file exists, so a
    // collection card — whose folder name is `collection:<uuid>`, which no
    // theme will ever carry — otherwise reads as "has a background", tries to
    // decode a file that is not there, and lands in the error fallback. Only a
    // card with no artwork of its own is ever given a mosaic, so this can never
    // hide a picture the user chose.
    final activeBgPath = hasCustomBg ? customBgPath : _themeBackgroundPath;
    final hasActiveBg =
        activeBgPath != null &&
        activeBgPath.isNotEmpty &&
        (hasCustomBg || widget.info.mosaicPaths.isEmpty);

    return Positioned.fill(
      child: ClipRRect(
        borderRadius:
            Theme.of(context).extension<CornerRadii>()?.radiusInternal ??
            BorderRadius.circular(9.r),
        child: hasActiveBg
            ? Image.file(
                File(activeBgPath),
                key: ValueKey('${activeBgPath}_${widget.info.imageVersion}'),
                fit: BoxFit.cover,
                cacheWidth: widget.backgroundCacheWidth,
                errorBuilder: (context, error, stackTrace) =>
                    _buildArtlessBackground(),
              )
            : _buildArtlessBackground(),
      ),
    );
  }

  /// The background for a card with no artwork at all.
  ///
  /// A collection carries no theme background — there is no `collections/<id>`
  /// entry in any theme — so instead of a flat tint it previews the games it
  /// holds, the same way a subfolder card previews its contents. Falls back to
  /// the tint when the collection is empty or none of its games have art.
  Widget _buildArtlessBackground() {
    final mosaicPaths = widget.info.mosaicPaths;
    final tint = Stack(
      children: [
        Container(color: Theme.of(context).colorScheme.surface),
        Container(color: widget.info.color1AsColor?.withValues(alpha: 0.4)),
      ],
    );

    // The Search card carries the magnifier the Search tab used to show, drawn
    // rather than bundled so it takes the theme's colours. It only stands in
    // for missing art: a theme that ships a `search` background still wins.
    if (widget.info.folderName == SystemFolderNames.search) {
      return Stack(
        fit: StackFit.expand,
        children: [
          tint,
          LayoutBuilder(
            builder: (context, box) => Center(
              child: Icon(
                Symbols.search_rounded,
                size: box.biggest.shortestSide * 0.55,
                weight: 600,
                color: Theme.of(
                  context,
                ).colorScheme.onSurface.withValues(alpha: 0.9),
              ),
            ),
          ),
        ],
      );
    }

    if (mosaicPaths.isEmpty) return tint;

    return Stack(
      fit: StackFit.expand,
      children: [
        tint,
        CoverMosaic(
          key: ValueKey('mosaic_${mosaicPaths.join('|')}'),
          covers: [for (final path in mosaicPaths) File(path)],
          gutter: 2.r,
        ),
      ],
    );
  }

  /// Helper for localized play time formatting.
  String _formatPlayTimeLocalized(int seconds) {
    return GameUtils.formatPlayTime(
      seconds,
      fullWords: true,
      hourLabel: AppLocale.hour.getString(context),
      hoursLabel: AppLocale.hours.getString(context),
      minuteLabel: AppLocale.minute.getString(context),
      minutesLabel: AppLocale.minutes.getString(context),
      secondLabel: AppLocale.second.getString(context),
      secondsLabel: AppLocale.seconds.getString(context),
    );
  }

  /// Renders the system brand logo with fallback support.
  ///
  /// The white-transparent logo is tinted with [color] (falls back to theme
  /// text). The tint is applied through `frameBuilder`, so it wraps the loaded
  /// image and *not* the error path: a `srcIn` filter repaints every
  /// non-transparent pixel it covers, and over the name fallback that includes
  /// the text's black drop shadow, which comes out as a light halo that reads
  /// as a blurred title. The fallback takes the colour directly instead.
  Widget _buildSystemLogo(
    String assetLogoPath, {
    double? height,
    Color? color,
  }) {
    final customLogoPath = widget.info.customLogoPath;
    final hasCustomLogo = customLogoPath != null && customLogoPath.isNotEmpty;
    final resolvedHeight = height ?? 32.r;

    Widget tint(Widget image) {
      if (color == null) return image;
      return ColorFiltered(
        colorFilter: ColorFilter.mode(color, BlendMode.srcIn),
        child: image,
      );
    }

    Widget assetLogo() => Image.asset(
      assetLogoPath,
      height: resolvedHeight,
      cacheWidth: 256,
      fit: BoxFit.contain,
      frameBuilder: (context, child, frame, wasSynchronouslyLoaded) =>
          tint(child),
      errorBuilder: (context, error, stackTrace) =>
          _buildLogoFallback(height: resolvedHeight, color: color),
    );

    if (hasCustomLogo) {
      return Image.file(
        File(customLogoPath),
        key: ValueKey('${customLogoPath}_${widget.info.imageVersion}'),
        height: resolvedHeight,
        cacheWidth: 256,
        fit: BoxFit.contain,
        frameBuilder: (context, child, frame, wasSynchronouslyLoaded) =>
            tint(child),
        errorBuilder: (context, error, stackTrace) => assetLogo(),
      );
    }

    return assetLogo();
  }

  /// The name-as-logo fallback, already in its final colour.
  ///
  /// It must not go through [buildLogo]'s `srcIn` filter. That filter repaints
  /// every non-transparent pixel in the requested colour *including the text's
  /// black drop shadow*, which turns the shadow into a light halo and makes
  /// the name look blurred — the state collection titles were in, since a
  /// collection never has a logo asset to load.
  Widget _buildLogoFallback({required double height, Color? color}) {
    return SystemLogoFallback(
      title: widget.info.title,
      shortName: widget.info.shortName,
      height: height,
      color: color,
    );
  }

  /// Builds the foreground content for game cards, including the RECENT badge
  /// and the game wheel/logo.
  Widget _buildGameMainContent(BuildContext context) {
    return Stack(
      children: [
        // RECENT badge.
        Positioned(
          top: 6.r,
          right: 6.r,
          child: Container(
            padding: EdgeInsets.symmetric(horizontal: 8.r, vertical: 4.r),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.secondary,
              borderRadius:
                  Theme.of(context).extension<CornerRadii>()?.radiusInternal ??
                  BorderRadius.circular(9.r),
            ),
            child: Text(
              AppLocale.recentBadge.getString(context),
              style: TextStyle(
                color: Theme.of(context).colorScheme.onSecondary,
                fontSize: 8.r,
                fontWeight: FontWeight.w900,
                letterSpacing: 1.2,
              ),
            ),
          ),
        ),

        // Central game wheel/logo. The inset that lets the wheel breathe on the
        // 3x2 card would eat most of a 2x1 one, so it scales with the box and
        // only reaches its full value on cards tall enough to spare it.
        Center(
          child: !_cachedHasWheelFile
              ? const SizedBox.shrink()
              : LayoutBuilder(
                  builder: (context, constraints) {
                    final shortestSide = constraints.biggest.shortestSide;
                    final inset = shortestSide.isFinite
                        ? math.min(48.r, shortestSide * 0.15)
                        : 48.r;

                    return Padding(
                      padding: EdgeInsets.all(inset),
                      child: Image.file(
                        _cachedWheelFile!,
                        height: 256.r,
                        fit: BoxFit.contain,
                        cacheWidth: 512,
                        errorBuilder: (context, error, stackTrace) =>
                            const SizedBox.shrink(),
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }

  /// Renders a footer for game cards, matching the system card footer style.
  Widget _buildGameFooter(BuildContext context) {
    return Container(
      height: 32.r,
      alignment: Alignment.center,
      padding: EdgeInsets.symmetric(horizontal: 8.r),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Text(
            AppLocale.timePlayedLabel
                .getString(context)
                .replaceFirst(
                  '{time}',
                  _formatPlayTimeLocalized(
                    widget.info.gameModel?.playTime ?? 0,
                  ),
                )
                .toUpperCase(),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: Theme.of(context).colorScheme.onSurface,
              fontSize: 10.r,
              fontWeight: FontWeight.w800,
              letterSpacing: 1.0,
            ),
          ),
        ],
      ),
    );
  }

  /// Renders a bottom footer with the system logo for non-game system cards.
  ///
  /// The footer expands to fill the remaining space below the square artwork,
  /// and the logo is auto-sized to fit while keeping its aspect ratio — the
  /// whole strip is the logo's, which is the point of floating the count over
  /// the artwork instead (see [_buildCountPill]).
  Widget _buildSystemFooter(BuildContext context) {
    final assetLogoPath = _resolveSystemLogoPath();

    return Expanded(
      child: Container(
        padding: EdgeInsets.only(top: 1.r, bottom: 1.r, left: 2.r, right: 2.r),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Expanded(
              child: FittedBox(
                fit: BoxFit.contain,
                child: _buildSystemLogo(
                  assetLogoPath,
                  height: 128.r,
                  color: Theme.of(context).colorScheme.onSurface,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// The card's count, e.g. "12 GAMES", "1 APP", "48 TRACKS", as a pill
  /// floating over the bottom left of the artwork.
  ///
  /// Bottom left rather than centred: the artwork's centre is where system art
  /// usually puts its subject, and the card's own logo sits on the centre line
  /// directly below, so a centred pill stacks two centred things. The fill is
  /// opaque enough to stay legible over any background art.
  Widget _buildCountPill(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Positioned(
      left: 8.r,
      bottom: 8.r,
      child: Container(
        padding: EdgeInsets.symmetric(horizontal: 10.r, vertical: 4.r),
        decoration: BoxDecoration(
          color: colorScheme.surface.withValues(alpha: 0.82),
          borderRadius: BorderRadius.circular(100.r),
          border: Border.all(
            color: colorScheme.outline.withValues(alpha: 0.6),
            width: 1.r,
          ),
        ),
        child: Text(
          systemCountLabel(context, widget.info).toUpperCase(),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            color: colorScheme.onSurface,
            fontSize: 10.r,
            fontWeight: FontWeight.w800,
            letterSpacing: 1.0,
          ),
        ),
      ),
    );
  }

  /// Resolves the logo asset path for this system.
  String _resolveSystemLogoPath() {
    final resolvedLogoFolder = widget.info.primaryFolderName?.isNotEmpty == true
        ? widget.info.primaryFolderName!
        : (widget.info.folderName?.isNotEmpty == true
              ? widget.info.folderName!
              : 'all');
    return 'assets/images/logos/$resolvedLogoFolder.webp';
  }
}

/// A utilitarian linear progress indicator.
class ProgressLine extends StatelessWidget {
  const ProgressLine({super.key, this.color, required this.percentage});

  final Color? color;
  final int? percentage;

  @override
  Widget build(BuildContext context) {
    final progressColor = color ?? Theme.of(context).colorScheme.primary;

    return Stack(
      children: [
        Container(
          width: double.infinity,
          height: 5.r,
          decoration: BoxDecoration(
            color: progressColor.withValues(alpha: 0.1),
          ),
        ),
        LayoutBuilder(
          builder: (context, constraints) => Container(
            width: constraints.maxWidth * (percentage! / 100),
            height: 5.r,
            decoration: BoxDecoration(color: progressColor),
          ),
        ),
      ],
    );
  }
}
