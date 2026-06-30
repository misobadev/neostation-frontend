import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:flutter/services.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:neostation/services/sfx_service.dart';
import 'package:video_player/video_player.dart';
import '../../models/secondary_display_state.dart';
import '../../widgets/shaders/shader_gif_widget.dart';
import '../../utils/image_utils.dart' as image_utils;

class SecondaryScreen extends StatefulWidget {
  const SecondaryScreen({super.key});

  @override
  State<SecondaryScreen> createState() => _SecondaryScreenState();
}

class _SecondaryScreenState extends State<SecondaryScreen> {
  SecondaryDisplayState? _secondaryDisplayState;
  VideoPlayerController? _videoController;
  Timer? _videoTimer;
  bool _showVideo = false;
  String? _currentVideoPath;
  int _lastMediaRevision = 0;

  @override
  void initState() {
    super.initState();
    if (Platform.isAndroid) {
      _secondaryDisplayState = SecondaryDisplayState();

      // Signal that secondary screen is now active
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _secondaryDisplayState?.updateState(isSecondaryActive: true);
      });

      _secondaryDisplayState!.addListener(_onStateChanged);
    }
  }

  void _onStateChanged() {
    final state = _secondaryDisplayState?.value;
    if (state == null) return;

    // A re-scrape rewrites the art at the same path, so this engine's image
    // cache still holds the old bitmap. When the producer bumps mediaRevision,
    // clear the cache so the rebuild (its ValueKey also carries the revision)
    // re-decodes the fresh bytes from disk. The secondary engine only ever
    // shows one game's art, so a full clear is cheap — and it correctly drops
    // the wheel's ResizeImage-wrapped entries, which a bare FileImage.evict
    // would miss.
    if (state.mediaRevision != _lastMediaRevision) {
      _lastMediaRevision = state.mediaRevision;
      final imageCache = PaintingBinding.instance.imageCache;
      imageCache.clear();
      imageCache.clearLiveImages();
    }

    if (state.isGameLaunching) {
      _stopVideo();
      return;
    }

    if (state.gameVideo != _currentVideoPath) {
      _currentVideoPath = state.gameVideo;
      _stopVideo();
      if (state.isGameSelected && state.gameVideo != null) {
        _startVideoTimer(state.gameVideo!);
      }
    } else if (!state.isGameSelected) {
      _stopVideo();
    } else {
      // Game selected, same video, but maybe mute changed
      if (_videoController != null && _videoController!.value.isInitialized) {
        _videoController!.setVolume(state.isVideoMuted ? 0.0 : 1.0);
      }
    }
  }

  void _startVideoTimer(String path) {
    _videoTimer?.cancel();
    _videoTimer = Timer(const Duration(milliseconds: 500), () {
      _initializeVideo(path);
    });
  }

  Future<void> _initializeVideo(String path) async {
    if (!mounted) return;

    try {
      final controller = VideoPlayerController.file(File(path));
      await controller.initialize();
      if (!mounted) {
        await controller.dispose();
        return;
      }

      // IMPORTANT: Set volume BEFORE playing to ensure sync and avoid audio burst
      final isMuted = _secondaryDisplayState?.value?.isVideoMuted ?? true;
      await controller.setVolume(isMuted ? 0.0 : 1.0);

      await controller.setLooping(true);
      await controller.play();

      if (!mounted) {
        await controller.dispose();
        return;
      }

      setState(() {
        _videoController = controller;
        _showVideo = true;
      });
    } catch (e) {
      debugPrint('SecondaryScreen: Error initializing video: $e');
    }
  }

  void _stopVideo() {
    _videoTimer?.cancel();
    _videoTimer = null;
    if (_videoController != null) {
      final controller = _videoController!;
      _videoController = null;
      try {
        controller.dispose();
      } catch (e) {
        debugPrint('SecondaryScreen: Error disposing video: $e');
      }
    }
    if (mounted) {
      setState(() {
        _showVideo = false;
      });
    }
  }

  @override
  void dispose() {
    _secondaryDisplayState?.removeListener(_onStateChanged);
    _secondaryDisplayState?.dispose();
    _stopVideo();
    super.dispose();
  }

  void _toggleMute() {
    final state = _secondaryDisplayState?.value;
    if (state != null) {
      _secondaryDisplayState?.updateState(
        isVideoMuted: !state.isVideoMuted,
        muteToggleTrigger: state.muteToggleTrigger + 1,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return ScreenUtilInit(
      designSize: const Size(640, 480),
      minTextAdapt: true,
      splitScreenMode: true,
      builder: (_, child) => ValueListenableBuilder<SecondaryDisplayStateData?>(
        valueListenable: _secondaryDisplayState ?? ValueNotifier(null),
        builder: (context, value, child) {
          return MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: ThemeData(
              scaffoldBackgroundColor: value?.backgroundColor != null
                  ? Color(value!.backgroundColor!)
                  : Colors.black,
            ),
            home: Scaffold(
              backgroundColor: value?.backgroundColor != null
                  ? Color(value!.backgroundColor!)
                  : Colors.black,
              body: value == null
                  ? _buildDefaultStaticUI()
                  : Stack(
                      fit: StackFit.expand,
                      children: [
                        // Base layer: Shader/App background (Conditional)
                        AnimatedSwitcher(
                          duration: const Duration(milliseconds: 256),
                          child: SizedBox.expand(
                            key: ValueKey(
                              'secondary_bg_${value.isGameSelected}_${value.systemName}_${value.backgroundColor}_${value.isOled}',
                            ),
                            child:
                                (value.isGameSelected || value.useFluidShader)
                                ? _buildUnifiedAppBackground(value)
                                : _buildSystemBackground(value),
                          ),
                          transitionBuilder: (child, animation) =>
                              FadeTransition(opacity: animation, child: child),
                        ),

                        // Game Layer: Screenshot/Video (on top of shader)
                        if (value.isGameSelected)
                          Stack(
                            fit: StackFit.expand,
                            children: [
                              AnimatedSwitcher(
                                duration: const Duration(milliseconds: 256),
                                transitionBuilder: (child, animation) =>
                                    FadeTransition(
                                      opacity: animation,
                                      child: child,
                                    ),
                                child: Stack(
                                  key: ValueKey(
                                    'game_content_${value.systemName}_${value.gameId}_${value.gameScreenshot ?? 'none'}_${value.gameFanart ?? 'none'}_${value.gameWheel ?? 'none'}_${value.gameImageBytes != null ? value.gameImageBytes.hashCode : 'none'}_${value.mediaRevision}',
                                  ),
                                  fit: StackFit.expand,
                                  children: [
                                    // Only show background images IF video is NOT showing (user request: "quitando del fondo el screenshot")
                                    if (!_showVideo) ...[
                                      if (value.isGameLaunching) ...[
                                        if (value.gameImageBytes != null)
                                          _buildBackgroundBytes(
                                            value.gameImageBytes!,
                                            fit: BoxFit
                                                .contain, // "se debe ver completo"
                                          )
                                        else if (value.gameScreenshot != null)
                                          _buildBackground(
                                            value.gameScreenshot!,
                                            fit: BoxFit
                                                .contain, // "se debe ver completo"
                                          )
                                        else if (value.gameFanart != null ||
                                            value.gameWheel != null)
                                          _buildFanartWithLogo(value),
                                      ] else ...[
                                        if (value.gameImageBytes != null)
                                          _buildBackgroundBytes(
                                            value.gameImageBytes!,
                                            fit: BoxFit
                                                .contain, // "se debe ver completo"
                                          )
                                        else if (value.gameScreenshot != null)
                                          _buildBackground(
                                            value.gameScreenshot!,
                                            fit: BoxFit
                                                .contain, // "se debe ver completo"
                                          )
                                        else if (value.gameFanart != null ||
                                            value.gameWheel != null)
                                          _buildFanartWithLogo(value),
                                      ],
                                    ],
                                  ],
                                ),
                              ),
                              if (_showVideo && _videoController != null)
                                SizedBox.expand(
                                  child: FittedBox(
                                    fit: BoxFit.contain,
                                    child: SizedBox(
                                      width: _videoController!.value.size.width,
                                      height:
                                          _videoController!.value.size.height,
                                      child: VideoPlayer(_videoController!),
                                    ),
                                  ),
                                ),
                            ],
                          ),

                        // Center Content
                        if (!value.isGameSelected)
                          _buildCenterContent(
                            value,
                            isTab: value.useFluidShader,
                          ),

                        if (value.isGameSelected && _showVideo)
                          Positioned(
                            bottom: 24.r,
                            right: 24.r,
                            child: GestureDetector(
                              onTap: () {
                                SfxService().playNavSound();
                                _toggleMute();
                              },
                              child: Container(
                                padding: EdgeInsets.symmetric(
                                  horizontal: 16.r,
                                  vertical: 10.r,
                                ),
                                decoration: BoxDecoration(
                                  color: Colors.black.withValues(alpha: 0.7),
                                  borderRadius: BorderRadius.circular(12.r),
                                  border: Border.all(
                                    color: Colors.white.withValues(alpha: 0.1),
                                    width: 1.r,
                                  ),
                                ),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Image.asset(
                                      'assets/images/gamepad/Xbox_Menu_button.png',
                                      width: 32.r,
                                      height: 32.r,
                                      color: Colors.white,
                                    ),
                                    SizedBox(width: 12.r),
                                    Icon(
                                      value.isVideoMuted
                                          ? Symbols.volume_off_rounded
                                          : Symbols.volume_up_rounded,
                                      color: Colors.white,
                                      size: 24.r,
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),

                        // Scraping Overlay
                        _buildScrapingOverlay(value),
                      ],
                    ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildBackgroundBytes(Uint8List bytes, {BoxFit fit = BoxFit.contain}) {
    return Image.memory(
      bytes,
      fit: fit,
      errorBuilder: (context, error, stackTrace) => _buildDefaultBackground(),
    );
  }

  Widget _buildBackground(String path, {BoxFit fit = BoxFit.contain}) {
    final file = File(path);
    if (file.existsSync()) {
      if (image_utils.ImageUtils.isGif(path)) {
        return ShaderGifWidget(
          imagePath: path,
          key: ValueKey('secondary_bg_$path'),
          fit: fit,
        );
      }
      return Image.file(file, fit: fit);
    }
    return _buildDefaultBackground();
  }

  Widget _buildDefaultBackground() {
    return const SizedBox.shrink();
  }

  /// Mirrors the main screen's game art as a fallback when no screenshot or
  /// video is available: fanart filling the screen (cover) with the game's
  /// wheel/logo centered on top. Either asset is optional — a logo-only game
  /// shows just the centered logo over the app background, and a fanart-only
  /// game shows just the fanart.
  Widget _buildFanartWithLogo(SecondaryDisplayStateData value) {
    return Stack(
      fit: StackFit.expand,
      children: [
        if (value.gameFanart != null)
          _buildBackground(value.gameFanart!, fit: BoxFit.cover),
        if (value.gameWheel != null)
          Center(
            child: Padding(
              padding: EdgeInsets.all(48.r),
              child: Stack(
                alignment: Alignment.center,
                children: [
                  // Drop shadow: black-tinted copy offset behind the logo,
                  // mirroring the main screen's wheel shadow treatment.
                  Transform.translate(
                    offset: Offset(4.r, 4.r),
                    child: Image.file(
                      File(value.gameWheel!),
                      fit: BoxFit.contain,
                      width: 600.r,
                      filterQuality: FilterQuality.low,
                      cacheWidth: 32,
                      color: Colors.black.withValues(alpha: 0.7),
                      errorBuilder: (context, error, stackTrace) =>
                          const SizedBox.shrink(),
                    ),
                  ),
                  Image.file(
                    File(value.gameWheel!),
                    fit: BoxFit.contain,
                    width: 600.r,
                    cacheWidth: 640,
                    errorBuilder: (context, error, stackTrace) =>
                        const SizedBox.shrink(),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildUnifiedAppBackground(SecondaryDisplayStateData value) {
    if (value.isOled) {
      return Container(
        color: value.backgroundColor != null
            ? Color(value.backgroundColor!)
            : Colors.black,
      );
    }

    return Builder(
      builder: (context) {
        final bg = Theme.of(context).scaffoldBackgroundColor;
        return Container(decoration: BoxDecoration(color: bg));
      },
    );
  }

  Widget _buildSystemBackground(SecondaryDisplayStateData value) {
    // Note: OLED is intentionally NOT short-circuited here. For a highlighted
    // system the console artwork IS the background, so blacking it out would
    // leave only the console name on screen. The black/background-color
    // fallback below (via _buildShaderFallback) still applies when no system
    // image is available, preserving the OLED look in the empty case.
    final bgPath = value.systemBackground;
    final hasBg = bgPath != null && bgPath.isNotEmpty;

    if (hasBg) {
      final isGif = image_utils.ImageUtils.isGif(bgPath);

      if (value.isBackgroundAsset) {
        if (isGif) {
          return ShaderGifWidget(
            imagePath: bgPath,
            key: ValueKey('secondary_system_bg_$bgPath'),
          );
        }
        return Image.asset(
          bgPath,
          fit: BoxFit.cover,
          errorBuilder: (context, error, stackTrace) =>
              _buildShaderFallback(value),
        );
      } else {
        final file = File(bgPath);
        if (file.existsSync()) {
          if (isGif) {
            return ShaderGifWidget(
              imagePath: bgPath,
              key: ValueKey('secondary_system_bg_$bgPath'),
            );
          }
          return Image.file(
            file,
            fit: BoxFit.cover,
            errorBuilder: (context, error, stackTrace) =>
                _buildShaderFallback(value),
          );
        }
      }
    }

    return _buildShaderFallback(value);
  }

  Widget _buildShaderFallback(SecondaryDisplayStateData value) {
    return Container(
      color: value.backgroundColor != null
          ? Color(value.backgroundColor!)
          : Colors.black,
    );
  }

  Widget _buildDefaultLogo() {
    return Image.asset(
      'assets/images/logo_transparent.png',
      width: 200.r,
      height: 200.r,
      fit: BoxFit.contain,
    );
  }

  Widget _buildSystemLogo(SecondaryDisplayStateData value) {
    if (value.systemLogo == null) return _buildDefaultLogo();

    final double logoSize = 300.r;

    if (value.isLogoAsset) {
      return Image.asset(
        value.systemLogo!,
        width: logoSize,
        height: logoSize,
        fit: BoxFit.contain,
        errorBuilder: (context, error, stackTrace) => _buildDefaultLogo(),
      );
    } else {
      final file = File(value.systemLogo!);
      if (file.existsSync()) {
        return Image.file(
          file,
          width: logoSize,
          height: logoSize,
          fit: BoxFit.contain,
          errorBuilder: (context, error, stackTrace) => _buildDefaultLogo(),
        );
      }
    }
    return _buildDefaultLogo();
  }

  Widget _buildDefaultStaticUI() {
    return Stack(
      fit: StackFit.expand,
      children: [
        _buildDefaultBackground(),
        Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              _buildDefaultLogo(),
              SizedBox(height: 40.r),
              _buildSystemNameContainer('WELCOME'),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildCenterContent(
    SecondaryDisplayStateData value, {
    bool isTab = false,
  }) {
    return Center(
      child: AnimatedSwitcher(
        duration: const Duration(milliseconds: 256),
        child: Column(
          key: ValueKey(
            'system_center_${value.systemName}_${value.systemLogo}_$isTab',
          ),
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            if (!isTab) ...[
              _buildSystemLogo(value),
              if (value.systemLogo == null) ...[
                SizedBox(height: 40.r),
                _buildSystemNameContainer(
                  value.systemName.isEmpty ? 'WELCOME' : value.systemName,
                ),
              ],
            ] else ...[
              _buildDefaultLogo(),
              SizedBox(height: 8.r),
              _buildSystemNameContainer(value.systemName.toUpperCase()),
            ],
          ],
        ),
        transitionBuilder: (child, animation) {
          return FadeTransition(
            opacity: animation,
            child: SlideTransition(
              position: Tween<Offset>(
                begin: const Offset(0.0, 0.1),
                end: Offset.zero,
              ).animate(animation),
              child: child,
            ),
          );
        },
      ),
    );
  }

  Widget _buildSystemNameContainer(String name) {
    return Container(
      padding: EdgeInsets.symmetric(horizontal: 24.r, vertical: 12.r),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.5),
        border: Border.all(color: Colors.white24, width: 2.r),
        borderRadius: BorderRadius.circular(12.r),
      ),
      child: Text(
        name.toUpperCase(),
        style: TextStyle(
          color: Colors.white70,
          fontSize: 18.r,
          letterSpacing: 6.r,
          fontWeight: FontWeight.w500,
          fontFamily: 'Anta',
        ),
      ),
    );
  }

  Widget _buildScrapingOverlay(SecondaryDisplayStateData value) {
    if (value.isGameLaunching) return const SizedBox.shrink();

    return Positioned(
      bottom: 24.r,
      left: 24.r,
      right: 24.r,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Scraping Progress
          if (value.isScraping)
            Container(
              padding: EdgeInsets.all(16.r),
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.85),
                borderRadius: BorderRadius.circular(16.r),
                border: Border.all(color: Colors.white.withValues(alpha: 0.15)),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black45,
                    blurRadius: 20.r,
                    offset: Offset(0, 8.r),
                  ),
                ],
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      SizedBox(
                        width: 20.r,
                        height: 20.r,
                        child: const CircularProgressIndicator(
                          strokeWidth: 2,
                          valueColor: AlwaysStoppedAnimation<Color>(
                            Colors.blue,
                          ),
                        ),
                      ),
                      SizedBox(width: 12.r),
                      Expanded(
                        child: Text(
                          value.scrapeStatus ?? 'Scrapeando...',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 16.r,
                            fontWeight: FontWeight.bold,
                            fontFamily: 'Anta',
                          ),
                        ),
                      ),
                      if (value.scrapeProgress != null)
                        Text(
                          '${(value.scrapeProgress! * 100).toInt()}%',
                          style: TextStyle(
                            color: Colors.blueAccent,
                            fontSize: 16.r,
                            fontWeight: FontWeight.bold,
                            fontFamily: 'Anta',
                          ),
                        ),
                    ],
                  ),
                  SizedBox(height: 12.r),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(4.r),
                    child: LinearProgressIndicator(
                      value: value.scrapeProgress,
                      minHeight: 6.r,
                      backgroundColor: Colors.white10,
                      valueColor: const AlwaysStoppedAnimation<Color>(
                        Colors.blueAccent,
                      ),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
