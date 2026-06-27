import 'package:flutter/material.dart';
import 'package:neostation/l10n/app_locale.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:neostation/models/my_systems.dart';
import 'package:neostation/providers/neo_assets_provider.dart';
import 'package:neostation/services/music_player_service.dart';
import 'package:neostation/services/sfx_service.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:provider/provider.dart';
import 'dart:io';
import 'package:flutter/foundation.dart';
import '../../../widgets/marquee_text.dart';
import '../../../widgets/shaders/shader_gif_widget.dart';
import '../../../widgets/shaders/music_card_shader_background.dart';
import '../../../utils/image_utils.dart';
import '../../../widgets/system_logo_fallback.dart';
import '../../../utils/game_utils.dart';

/// A premium card component representing a system or a 'Recent Game' entry.
///
/// Supports dynamic background effects (GIFs, Shaders, Music Covers), localized
/// metadata display, and specialized layouts for 'Recent Games'.
class SystemCard extends StatefulWidget {
  const SystemCard({
    super.key,
    required this.info,
    this.onTap,
    this.isSelected = false,
  });

  /// The system or game metadata resolved for this card.
  final SystemInfo info;

  /// Interaction callback for pointer/controller selection.
  final VoidCallback? onTap;

  /// Whether this card currently has visual focus in the grid.
  final bool isSelected;

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
  String? _themeLogoPath;
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
      _themeLogoPath = null;
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

      // Asset hierarchy: Custom > Theme-specific > Null (fallback to color).
      _themeBackgroundPath =
          widget.info.customBackgroundPath?.isNotEmpty == true
          ? null
          : neoAssets.getBackgroundForSystemSync(folderName);
      _themeLogoPath = widget.info.customLogoPath?.isNotEmpty == true
          ? null
          : neoAssets.getLogoForSystemSync(folderName);
    }

    return MouseRegion(
      cursor: SystemMouseCursors.basic,
      child: Container(
        margin: EdgeInsets.all(2.r),
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12.r),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.25),
              blurRadius: 2.r,
              offset: Offset(2.0.r, 2.0.r),
            ),
          ],
        ),
        child: InkWell(
          focusNode: _focusNode,
          onTap: () {
            SfxService().playNavSound();
            widget.onTap?.call();
          },
          canRequestFocus: false,
          focusColor: Colors.transparent,
          hoverColor: Colors.transparent,
          highlightColor: Colors.transparent,
          splashColor: Colors.transparent,
          child: Stack(
            key: _contentStackKey,
            children: [
              _buildSystemBackground(),
              _buildMainBodyContent(context, true),
              if (widget.info.isGame) _buildRecentFooter(context),
            ],
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
                borderRadius: 12.r,
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
          borderRadius: BorderRadius.circular(12.r),
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
          borderRadius: BorderRadius.circular(12.r),
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
    final activeBgPath = hasCustomBg ? customBgPath : _themeBackgroundPath;
    final hasActiveBg = activeBgPath != null && activeBgPath.isNotEmpty;

    return Positioned.fill(
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12.r),
        child: hasActiveBg
            ? Image.file(
                File(activeBgPath),
                key: ValueKey('${activeBgPath}_${widget.info.imageVersion}'),
                fit: BoxFit.cover,
                cacheWidth: widget.info.isGame ? 1024 : 256,
                errorBuilder: (context, error, stackTrace) => Stack(
                  children: [
                    Container(color: Theme.of(context).colorScheme.surface),
                    Container(
                      color: widget.info.color1AsColor?.withValues(alpha: 0.4),
                    ),
                  ],
                ),
              )
            : Stack(
                children: [
                  Container(color: Theme.of(context).colorScheme.surface),
                  Container(
                    color: widget.info.color1AsColor?.withValues(alpha: 0.4),
                  ),
                ],
              ),
      ),
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
  Widget _buildSystemLogo(String assetLogoPath) {
    final customLogoPath = widget.info.customLogoPath;
    final hasCustomLogo = customLogoPath != null && customLogoPath.isNotEmpty;

    if (hasCustomLogo) {
      return Image.file(
        File(customLogoPath),
        key: ValueKey('${customLogoPath}_${widget.info.imageVersion}'),
        height: 128.r,
        cacheWidth: 384,
        fit: BoxFit.contain,
        errorBuilder: (context, error, stackTrace) => Image.asset(
          assetLogoPath,
          height: 128.r,
          cacheWidth: 384,
          fit: BoxFit.contain,
          errorBuilder: (context, error, stackTrace) => SystemLogoFallback(
            title: widget.info.title,
            shortName: widget.info.shortName,
            height: 24.r,
          ),
        ),
      );
    }

    final themeLogoPath = _themeLogoPath;
    if (themeLogoPath != null && themeLogoPath.isNotEmpty) {
      return Image.file(
        File(themeLogoPath),
        key: ValueKey(themeLogoPath),
        height: 128.r,
        cacheWidth: 384,
        fit: BoxFit.contain,
        errorBuilder: (context, error, stackTrace) => Image.asset(
          assetLogoPath,
          height: 128.r,
          cacheWidth: 384,
          fit: BoxFit.contain,
          errorBuilder: (context, error2, stackTrace2) => SystemLogoFallback(
            title: widget.info.title,
            shortName: widget.info.shortName,
            height: 24.r,
          ),
        ),
      );
    }

    return Image.asset(
      assetLogoPath,
      height: 128.r,
      cacheWidth: 384,
      fit: BoxFit.contain,
      errorBuilder: (context, error, stackTrace) => SystemLogoFallback(
        title: widget.info.title,
        shortName: widget.info.shortName,
        height: 24.r,
      ),
    );
  }

  /// Builds the foreground content, including badges and specialized layouts for 'Recent Games'.
  Widget _buildMainBodyContent(BuildContext context, bool includeInnerCard) {
    final isGame = widget.info.isGame;
    final resolvedLogoFolder = widget.info.primaryFolderName?.isNotEmpty == true
        ? widget.info.primaryFolderName!
        : (widget.info.folderName?.isNotEmpty == true
              ? widget.info.folderName!
              : 'all');

    final assetLogoPath =
        'assets/images/systems/logos/$resolvedLogoFolder.webp';

    return Stack(
      children: [
        if (isGame) ...[
          // Premium 'RECENT' badge.
          Positioned(
            top: 10.r,
            right: 10.r,
            child: Container(
              padding: EdgeInsets.symmetric(horizontal: 8.r, vertical: 4.r),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.primary,
                borderRadius: BorderRadius.circular(4.r),
              ),
              child: Text(
                AppLocale.recentBadge.getString(context),
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onPrimary,
                  fontSize: 10.r,
                  fontWeight: FontWeight.w900,
                  letterSpacing: 1.2,
                ),
              ),
            ),
          ),

          // Central game identification asset (Wheel/Logo).
          Positioned(
            top: 20.r,
            left: 60.r,
            right: 60.r,
            bottom: 45.r,
            child: Center(
              child: !_cachedHasWheelFile
                  ? const SizedBox.shrink()
                  : Image.file(
                      _cachedWheelFile!,
                      height: 128.r,
                      fit: BoxFit.contain,
                      cacheWidth: 512,
                      errorBuilder: (context, error, stackTrace) =>
                          const SizedBox.shrink(),
                    ),
            ),
          ),
        ] else ...[
          // Centered branding for standard system cards.
          Center(
            child: widget.info.hideLogo
                ? const SizedBox.shrink()
                : _buildSystemLogo(assetLogoPath),
          ),
        ],
      ],
    );
  }

  /// Renders a descriptive footer overlay for game-specific cards.
  Widget _buildRecentFooter(BuildContext context) {
    return Positioned(
      bottom: 0,
      left: 0,
      right: 0,
      height: 42.r,
      child: ClipRRect(
        borderRadius: BorderRadius.only(
          bottomLeft: Radius.circular(12.r),
          bottomRight: Radius.circular(12.r),
        ),
        child: Container(
          padding: EdgeInsets.symmetric(horizontal: 12.r),
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.6),
            borderRadius: BorderRadius.only(
              bottomLeft: Radius.circular(12.r),
              bottomRight: Radius.circular(12.r),
            ),
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              MarqueeText(
                text:
                    widget.info.title?.toUpperCase() ??
                    AppLocale.unknownGame.getString(context),
                isActive: widget.isSelected,
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 13.r,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 0.5,
                  shadows: const <Shadow>[
                    Shadow(
                      offset: Offset(2.0, 2.0),
                      blurRadius: 2.0,
                      color: Colors.black,
                    ),
                  ],
                ),
              ),
              Text(
                widget.info.isGame
                    ? AppLocale.timePlayedLabel
                          .getString(context)
                          .replaceFirst(
                            '{time}',
                            _formatPlayTimeLocalized(
                              widget.info.gameModel?.playTime ?? 0,
                            ),
                          )
                          .toUpperCase()
                    : (widget.info.folderName == 'android'
                          ? AppLocale.appsCount
                                .getString(context)
                                .replaceFirst(
                                  '{count}',
                                  widget.info.numOfRoms.toString(),
                                )
                                .toUpperCase()
                          : (widget.info.folderName == 'music'
                                ? AppLocale.tracksCount
                                      .getString(context)
                                      .replaceFirst(
                                        '{count}',
                                        widget.info.numOfRoms.toString(),
                                      )
                                      .toUpperCase()
                                : AppLocale.gamesCount
                                      .getString(context)
                                      .replaceFirst(
                                        '{count}',
                                        widget.info.numOfRoms.toString(),
                                      )
                                      .toUpperCase())),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: Colors.white70,
                  fontSize: 8.r,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 1.0,
                  shadows: const <Shadow>[
                    Shadow(
                      offset: Offset(1.0, 1.0),
                      blurRadius: 1.0,
                      color: Colors.black,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
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
