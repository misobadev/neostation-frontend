import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:flutter/services.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:neostation/services/sfx_service.dart';
import 'package:neostation/services/secondary_apps_service.dart';
import 'package:video_player/video_player.dart';
import '../../models/config_model.dart';
import '../../models/secondary_achievement_item.dart';
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

  /// Auto-clearing timer for the "newly earned this session" celebration.
  Timer? _celebrationTimer;
  bool _celebrate = false;
  String? _celebrationKey;

  /// Whether the achievement panel renders the list view (vs the badge grid).
  /// Toggled by touch on the secondary screen; local to this engine.
  bool _achievementListView = false;

  /// Which page of the in-game container is showing: 0 = Now Playing,
  /// 1 = RetroAchievements. Local to this engine, flipped by the edge chevrons;
  /// resets to 0 on each new launch.
  int _inGamePanelPage = 0;
  bool _wasNowPlayingActive = false;
  String? _panelGameId;

  /// Ticks once a second while a game is active so the Now Playing "PLAY TIME"
  /// stat counts up live. [_sessionWatch] measures the current session, which is
  /// added to the DB-supplied total at render time.
  Timer? _playTimeTicker;
  final Stopwatch _sessionWatch = Stopwatch();

  /// Dims the in-game container after a spell of no activity, to cut glare and
  /// burn-in while playing. Any activity — launch, page flip, a new unlock, or a
  /// touch — wakes it to full brightness and restarts the countdown.
  Timer? _dimTimer;
  bool _inGameDimmed = false;

  /// Dock slot index currently being assigned via the app picker, or null when
  /// the picker is closed.
  int? _pickerSlot;

  /// Installed-app list backing the picker; null until first loaded.
  List<Map<String, dynamic>>? _pickerApps;
  bool _loadingPickerApps = false;

  @override
  void initState() {
    super.initState();
    if (Platform.isAndroid) {
      _secondaryDisplayState = SecondaryDisplayState();
      _secondaryDisplayState!.addListener(_onStateChanged);
      // Signal that the secondary screen is active — but only after the initial
      // state sync. Pushing it while the synced value is still null makes
      // updateState fall back to the WELCOME default and clobber the real
      // retained display state, which then shows until the next push.
      _signalSecondaryActiveWhenSynced();
    }
  }

  /// Marks the secondary display active once [SecondaryDisplayState] has pulled
  /// its initial value, so the flag layers onto the real state rather than the
  /// WELCOME placeholder.
  Future<void> _signalSecondaryActiveWhenSynced() async {
    final state = _secondaryDisplayState;
    if (state == null) return;
    // A null value means no cached state was restored synchronously; in that
    // case initialSync is assigned and safe to await. A non-null value means the
    // state is already in hand.
    if (state.value == null) {
      await state.initialSync;
    }
    if (!mounted) return;
    state.updateState(isSecondaryActive: true);
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
    _maybeResetInGamePage(state);
    _applySessionPower(state);
    _maybeStartCelebration(state);

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

  /// Triggers (or refreshes) the celebration banner when a new set of
  /// session-earned achievements arrives, auto-clearing it after a few seconds.
  void _maybeStartCelebration(SecondaryDisplayStateData state) {
    final ids = state.newlyEarnedIds;
    final key = (ids == null || ids.isEmpty)
        ? null
        : (List<int>.from(ids)..sort()).join(',');

    if (key == _celebrationKey) return;
    _celebrationKey = key;
    _celebrationTimer?.cancel();

    if (key == null) {
      if (_celebrate && mounted) setState(() => _celebrate = false);
      return;
    }

    // Surface the unlock: Now Playing is the default page, so jump to the
    // achievements page (when present) where the celebration is visible.
    final raAvailable =
        state.showAchievementPanel && state.achievements != null;
    if (mounted) {
      setState(() {
        _celebrate = true;
        if (raAvailable) _inGamePanelPage = 1;
      });
    }
    _wakeInGamePanel();
    _celebrationTimer = Timer(const Duration(seconds: 8), () {
      if (mounted) setState(() => _celebrate = false);
    });
  }

  /// Resets the in-game container to the Now Playing page (0) on each new
  /// launch — detected by the session activating, or the game id changing while
  /// it stays active.
  void _maybeResetInGamePage(SecondaryDisplayStateData state) {
    final freshLaunch =
        state.nowPlayingActive &&
        (!_wasNowPlayingActive || state.gameId != _panelGameId);
    final exited = _wasNowPlayingActive && !state.nowPlayingActive;
    _wasNowPlayingActive = state.nowPlayingActive;
    _panelGameId = state.gameId;

    if (freshLaunch) {
      _startPlayTimeTicker();
      _wakeInGamePanel();
    } else if (exited) {
      _stopPlayTimeTicker();
      _cancelDim();
    }

    if (freshLaunch && _inGamePanelPage != 0 && mounted) {
      setState(() => _inGamePanelPage = 0);
    }
  }

  /// Restarts the session stopwatch and the per-second repaint so the live
  /// PLAY TIME counts up from zero for this launch.
  void _startPlayTimeTicker() {
    _sessionWatch
      ..reset()
      ..start();
    _armPlayTimeTicker();
  }

  /// (Re)creates the per-second repaint timer without touching the stopwatch, so
  /// it can be reused both for a fresh launch and for resuming after sleep.
  void _armPlayTimeTicker() {
    _playTimeTicker?.cancel();
    _playTimeTicker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  void _stopPlayTimeTicker() {
    _playTimeTicker?.cancel();
    _playTimeTicker = null;
    _sessionWatch
      ..stop()
      ..reset();
  }

  /// Freezes the live session clock while the device screen is off, resuming it
  /// on wake. This engine never receives Android lifecycle callbacks (it runs in
  /// a separate FlutterEngine behind the sub_screen Presentation), and a play
  /// session runs the game in a separate app — so the only reliable "device is
  /// asleep" signal is [SecondaryDisplayStateData.deviceScreenOn], bridged from a
  /// native ACTION_SCREEN_ON/OFF receiver. Without this the [Stopwatch] keeps
  /// accruing wall-clock time while the device sleeps.
  void _applySessionPower(SecondaryDisplayStateData state) {
    if (!state.deviceScreenOn) {
      // Screen off: freeze the counter where it is.
      if (_sessionWatch.isRunning) {
        _playTimeTicker?.cancel();
        _playTimeTicker = null;
        _sessionWatch.stop();
      }
    } else if (_wasNowPlayingActive && !_sessionWatch.isRunning) {
      // Screen back on mid-session: resume from the frozen elapsed time.
      _sessionWatch.start();
      _armPlayTimeTicker();
      if (mounted) setState(() {});
    }
  }

  /// Wakes the in-game container to full brightness and (re)arms the idle dim
  /// countdown. Called on every activity event.
  void _wakeInGamePanel() {
    _dimTimer?.cancel();
    if (_inGameDimmed && mounted) {
      setState(() => _inGameDimmed = false);
    }
    // User setting: 0 seconds means "never dim", so leave the panel lit.
    final delaySeconds = _secondaryDisplayState?.value?.nowPlayingDimDelay ?? 5;
    if (delaySeconds <= 0) return;
    _dimTimer = Timer(Duration(seconds: delaySeconds), () {
      if (mounted) setState(() => _inGameDimmed = true);
    });
  }

  void _cancelDim() {
    _dimTimer?.cancel();
    _dimTimer = null;
    _inGameDimmed = false;
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
    _celebrationTimer?.cancel();
    _playTimeTicker?.cancel();
    _dimTimer?.cancel();
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

  /// Asks the main engine to take a system screenshot of the main screen by
  /// bumping the shared trigger; the main engine watches for the increment.
  void _requestScreenshot() {
    final state = _secondaryDisplayState?.value;
    if (state != null) {
      _wakeInGamePanel();
      _secondaryDisplayState?.updateState(
        screenshotTrigger: state.screenshotTrigger + 1,
      );
    }
  }

  /// Current dock slot assignments, always [ConfigModel.dockMaxSlots] long.
  List<String> get _dockApps {
    final apps = _secondaryDisplayState?.value?.dockApps;
    return ConfigModel.normalizeDock(apps);
  }

  /// Writes a new dock layout to shared state and bumps the edit trigger so the
  /// main engine persists it.
  void _commitDock(List<String> next) {
    final state = _secondaryDisplayState?.value;
    if (state == null) return;
    _secondaryDisplayState?.updateState(
      dockApps: next,
      dockEditTrigger: state.dockEditTrigger + 1,
    );
  }

  /// Opens the app picker for [slot], lazily loading the installed-app list.
  Future<void> _openAppPicker(int slot) async {
    _wakeInGamePanel();
    SfxService().playNavSound();
    setState(() => _pickerSlot = slot);
    if (_pickerApps == null && !_loadingPickerApps) {
      setState(() => _loadingPickerApps = true);
      final apps = await SecondaryAppsService.getInstalledApps();
      if (!mounted) return;
      setState(() {
        _pickerApps = apps;
        _loadingPickerApps = false;
      });
    }
  }

  void _closeAppPicker() {
    setState(() => _pickerSlot = null);
  }

  /// Assigns [package] to the pending picker slot and closes the picker.
  void _assignSlot(String package) {
    final slot = _pickerSlot;
    if (slot == null) return;
    final next = List<String>.from(_dockApps);
    if (slot >= 0 && slot < next.length) {
      next[slot] = package;
      _commitDock(next);
    }
    _closeAppPicker();
  }

  /// Empties dock [slot] (long-press on a filled slot).
  void _clearSlot(int slot) {
    _wakeInGamePanel();
    SfxService().playNavSound();
    final next = List<String>.from(_dockApps);
    if (slot >= 0 && slot < next.length) {
      next[slot] = '';
      _commitDock(next);
    }
  }

  /// Launches a docked app, preferring the bottom display.
  void _launchDockApp(String package) {
    _wakeInGamePanel();
    SfxService().playNavSound();
    SecondaryAppsService.launchAppOnSecondary(package);
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

                        // In-game paged container: Now Playing (page 0) and,
                        // when the game has a RetroAchievements set, the
                        // achievements panel (page 1). Touch-paged via edge
                        // chevrons; covers the game art, fading in on launch
                        // and out on return.
                        Positioned.fill(
                          child: IgnorePointer(
                            ignoring: !value.nowPlayingActive,
                            child: AnimatedSwitcher(
                              duration: const Duration(milliseconds: 400),
                              child: value.nowPlayingActive
                                  ? KeyedSubtree(
                                      key: const ValueKey('in-game-panel'),
                                      child: _buildInGamePanel(value),
                                    )
                                  : const SizedBox.shrink(
                                      key: ValueKey('in-game-panel-empty'),
                                    ),
                            ),
                          ),
                        ),

                        // Center Content (system/recent-game logo). Suppressed
                        // while the in-game container is up so the logo doesn't
                        // draw on top of it (recent-game launches push state
                        // with isGameSelected: false + the wheel as systemLogo).
                        if (!value.isGameSelected && !value.nowPlayingActive)
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
        // Optional scrim over the fanart only (below the logo) so a busy
        // background doesn't clash with the logo. The logo, drawn next, stays
        // at full brightness.
        if (value.gameFanart != null && value.fanartDimLevel > 0)
          Positioned.fill(
            child: ColoredBox(
              color: Colors.black.withValues(
                alpha: value.fanartDimLevel.clamp(0, 100) / 100.0,
              ),
            ),
          ),
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

  /// The in-game container body: shows the Now Playing page or the
  /// achievements page, with edge chevrons to flip between them when the game
  /// has a RetroAchievements set. The page index is clamped so the RA page is
  /// only shown when it actually exists.
  Widget _buildInGamePanel(SecondaryDisplayStateData value) {
    final raAvailable =
        value.showAchievementPanel && value.achievements != null;
    final page = (_inGamePanelPage == 1 && raAvailable) ? 1 : 0;

    // Idle-dim wrapper: any touch wakes the panel (translucent so it never
    // swallows chevron taps). Once the idle countdown elapses a full-bleed black
    // scrim fades in over everything — panel and background art alike — so the
    // display goes to near-black regardless of the current palette.
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: (_) => _wakeInGamePanel(),
      child: Stack(
        fit: StackFit.expand,
        children: [
          _buildInGamePanelBody(value, raAvailable, page),
          Positioned.fill(
            // While dimmed, the opaque scrim swallows touches so buttons
            // underneath don't fire — the outer Listener still wakes the panel,
            // so the first touch only wakes (no accidental presses). When awake,
            // ignore the scrim entirely so touches reach the buttons.
            child: IgnorePointer(
              ignoring: !_inGameDimmed,
              child: AnimatedOpacity(
                duration: const Duration(milliseconds: 500),
                opacity: _inGameDimmed
                    ? value.nowPlayingDimLevel.clamp(0, 100) / 100.0
                    : 0.0,
                child: const ColoredBox(color: Colors.black),
              ),
            ),
          ),
          // App picker overlay sits above the dim scrim so opening it (which
          // also wakes the panel) is always visible.
          if (_pickerSlot != null) _buildAppPickerOverlay(),
        ],
      ),
    );
  }

  Widget _buildInGamePanelBody(
    SecondaryDisplayStateData value,
    bool raAvailable,
    int page,
  ) {
    return Stack(
      children: [
        // Opaque backdrop: while the two pages cross-fade they are both
        // briefly translucent, so without this the game-art layer underneath
        // the container would bleed through during the transition.
        Positioned.fill(
          child: ColoredBox(
            color: value.backgroundColor != null
                ? Color(value.backgroundColor!)
                : Colors.black,
          ),
        ),
        Positioned.fill(
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 300),
            transitionBuilder: (child, animation) =>
                FadeTransition(opacity: animation, child: child),
            child: KeyedSubtree(
              key: ValueKey('in-game-page-$page'),
              child: page == 1
                  ? _buildAchievementPanel(value)
                  : _buildNowPlayingPanel(value),
            ),
          ),
        ),
        // Edge chevrons: only meaningful when there are two pages. The chevron
        // points toward the page it reveals (right on Now Playing, left on RA).
        if (raAvailable && page == 0) _buildPageChevron(left: false),
        if (raAvailable && page == 1) _buildPageChevron(left: true),
      ],
    );
  }

  /// A translucent circular chevron pinned to the left/right edge that flips
  /// the in-game page. Styled like the mute toggle.
  Widget _buildPageChevron({required bool left}) {
    return Positioned(
      left: left ? 12.r : null,
      right: left ? null : 12.r,
      top: 0,
      bottom: 0,
      child: Center(
        child: GestureDetector(
          onTap: () {
            SfxService().playNavSound();
            _wakeInGamePanel();
            setState(() => _inGamePanelPage = left ? 0 : 1);
          },
          child: Container(
            padding: EdgeInsets.all(8.r),
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.55),
              shape: BoxShape.circle,
              border: Border.all(
                color: Colors.white.withValues(alpha: 0.15),
                width: 1.r,
              ),
            ),
            child: Icon(
              left
                  ? Symbols.chevron_left_rounded
                  : Symbols.chevron_right_rounded,
              color: Colors.white,
              size: 30.r,
            ),
          ),
        ),
      ),
    );
  }

  /// Renders the "Now Playing" page: boxart, title, system, total play time
  /// and last-played. Shown for every launched game (page 0). View-only.
  Widget _buildNowPlayingPanel(SecondaryDisplayStateData value) {
    final title = (value.gameTitle != null && value.gameTitle!.isNotEmpty)
        ? value.gameTitle!
        : value.systemName;

    return Container(
      width: double.infinity,
      height: double.infinity,
      color: value.backgroundColor != null
          ? Color(value.backgroundColor!)
          : Colors.black,
      child: Stack(
        children: [
          Padding(
            padding: EdgeInsets.fromLTRB(44.r, 32.r, 44.r, 96.r),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
          _buildNowPlayingBoxart(value.gameBoxart),
          SizedBox(width: 32.r),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  'NOW PLAYING',
                  style: TextStyle(
                    color: const Color(0xFFFFC107),
                    fontSize: 14.r,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 3.r,
                  ),
                ),
                SizedBox(height: 12.r),
                Text(
                  title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 30.r,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                SizedBox(height: 8.r),
                Text(
                  value.systemName.toUpperCase(),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: Colors.white70,
                    fontSize: 16.r,
                    letterSpacing: 1.5.r,
                  ),
                ),
                SizedBox(height: 26.r),
                _buildNowPlayingStat(
                  icon: Symbols.schedule_rounded,
                  label: 'PLAY TIME',
                  text: _formatPlayTime(value.playTimeSeconds),
                ),
                if (_sessionWatch.isRunning) ...[
                  SizedBox(height: 12.r),
                  _buildNowPlayingStat(
                    icon: Symbols.timer_rounded,
                    label: 'SESSION',
                    text: _formatSessionTime(),
                  ),
                ],
                SizedBox(height: 12.r),
                _buildNowPlayingStat(
                  icon: Symbols.history_rounded,
                  label: 'LAST PLAYED',
                  text: _formatLastPlayed(value.lastPlayedMillis),
                ),
                if (value.screenshotAccessEnabled) ...[
                  SizedBox(height: 28.r),
                  _buildScreenshotButton(),
                ],
              ],
            ),
          ),
              ],
            ),
          ),
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: _buildAppDock(value),
          ),
        ],
      ),
    );
  }

  /// Tappable pill that asks the main engine to capture a system screenshot of
  /// the main screen.
  Widget _buildScreenshotButton() {
    return GestureDetector(
      onTap: _requestScreenshot,
      child: Container(
        padding: EdgeInsets.symmetric(horizontal: 20.r, vertical: 12.r),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(12.r),
          border: Border.all(color: Colors.white.withValues(alpha: 0.18)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Symbols.photo_camera_rounded,
              color: Colors.white,
              size: 22.r,
            ),
            SizedBox(width: 12.r),
            Text(
              'SCREENSHOT',
              style: TextStyle(
                color: Colors.white,
                fontSize: 14.r,
                fontWeight: FontWeight.w600,
                letterSpacing: 2.r,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// The app dock pinned to the bottom of the Now Playing page: a centered row
  /// of [SecondaryDisplayStateData.dockSlotCount] slots (user setting). Tap a
  /// filled slot to launch it, tap an empty slot to pick an app, long-press a
  /// filled slot to clear it. Hidden entirely when the dock is disabled.
  Widget _buildAppDock(SecondaryDisplayStateData value) {
    if (!value.dockEnabled) return const SizedBox.shrink();
    final apps = ConfigModel.normalizeDock(value.dockApps);
    final visibleSlots = value.dockSlotCount.clamp(
      ConfigModel.dockMinSlotCount,
      ConfigModel.dockMaxSlotCount,
    );
    return Container(
      padding: EdgeInsets.symmetric(horizontal: 16.r, vertical: 12.r),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.bottomCenter,
          end: Alignment.topCenter,
          colors: [
            Colors.black.withValues(alpha: 0.55),
            Colors.black.withValues(alpha: 0.0),
          ],
        ),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          for (var i = 0; i < visibleSlots; i++) ...[
            if (i > 0) SizedBox(width: 14.r),
            _buildDockSlot(i, apps[i]),
          ],
        ],
      ),
    );
  }

  /// A single dock slot. [package] empty = free slot.
  Widget _buildDockSlot(int index, String package) {
    final filled = package.isNotEmpty;
    return GestureDetector(
      onTap: () => filled ? _launchDockApp(package) : _openAppPicker(index),
      onLongPress: filled ? () => _clearSlot(index) : null,
      child: Container(
        width: 56.r,
        height: 56.r,
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: filled ? 0.10 : 0.05),
          borderRadius: BorderRadius.circular(14.r),
          border: Border.all(
            color: Colors.white.withValues(alpha: filled ? 0.22 : 0.14),
          ),
        ),
        child: filled
            ? Padding(
                padding: EdgeInsets.all(8.r),
                child: _buildDockIcon(package),
              )
            : Icon(
                Symbols.add_rounded,
                color: Colors.white.withValues(alpha: 0.45),
                size: 26.r,
              ),
      ),
    );
  }

  /// Lazily loads and renders a docked app's launcher icon (cached in
  /// [SecondaryAppsService]).
  Widget _buildDockIcon(String package) {
    return FutureBuilder<Uint8List?>(
      future: SecondaryAppsService.getAppIcon(package),
      builder: (context, snapshot) {
        final bytes = snapshot.data;
        if (bytes != null) {
          return Image.memory(bytes, fit: BoxFit.contain, gaplessPlayback: true);
        }
        return Icon(
          Symbols.android_rounded,
          color: Colors.white.withValues(alpha: 0.6),
          size: 24.r,
        );
      },
    );
  }

  /// Full-panel overlay for choosing an app for the pending dock slot. Tapping
  /// the backdrop cancels; tapping an app assigns it.
  Widget _buildAppPickerOverlay() {
    return Positioned.fill(
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: _closeAppPicker,
        child: ColoredBox(
          // Fully opaque so the Now Playing screen behind is not visible while
          // choosing an app for a dock slot.
          color: Colors.black,
          child: SafeArea(
            child: Padding(
              padding: EdgeInsets.all(20.r),
              child: Column(
                children: [
                  Row(
                    children: [
                      Text(
                        'CHOOSE AN APP',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 16.r,
                          fontWeight: FontWeight.w600,
                          letterSpacing: 2.r,
                        ),
                      ),
                      const Spacer(),
                      GestureDetector(
                        onTap: _closeAppPicker,
                        child: Icon(
                          Symbols.close_rounded,
                          color: Colors.white,
                          size: 26.r,
                        ),
                      ),
                    ],
                  ),
                  SizedBox(height: 16.r),
                  Expanded(child: _buildAppPickerGrid()),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildAppPickerGrid() {
    if (_loadingPickerApps || _pickerApps == null) {
      return const Center(
        child: CircularProgressIndicator(color: Colors.white),
      );
    }
    final apps = _pickerApps!;
    if (apps.isEmpty) {
      return Center(
        child: Text(
          'No apps found',
          style: TextStyle(color: Colors.white70, fontSize: 14.r),
        ),
      );
    }
    // Swallow taps inside the grid so they don't hit the dismiss backdrop.
    return GestureDetector(
      onTap: () {},
      child: GridView.builder(
        gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
          maxCrossAxisExtent: 128.r,
          mainAxisSpacing: 20.r,
          crossAxisSpacing: 20.r,
          childAspectRatio: 0.82,
        ),
        itemCount: apps.length,
        itemBuilder: (context, i) {
          final app = apps[i];
          final package = (app['package'] ?? '').toString();
          final name = (app['name'] ?? package).toString();
          return _buildPickerTile(package, name);
        },
      ),
    );
  }

  Widget _buildPickerTile(String package, String name) {
    return GestureDetector(
      onTap: package.isEmpty ? null : () => _assignSlot(package),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 84.r,
            height: 84.r,
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(18.r),
            ),
            padding: EdgeInsets.all(12.r),
            child: _buildDockIcon(package),
          ),
          SizedBox(height: 8.r),
          Text(
            name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.white70, fontSize: 10.r),
          ),
        ],
      ),
    );
  }

  Widget _buildNowPlayingBoxart(String? path) {
    Widget placeholder() => Container(
      width: 184.r,
      height: 264.r,
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(12.r),
        border: Border.all(color: Colors.white.withValues(alpha: 0.12)),
      ),
      child: Icon(
        Symbols.videogame_asset_rounded,
        color: Colors.white24,
        size: 64.r,
      ),
    );

    if (path == null) return placeholder();
    final file = File(path);
    if (!file.existsSync()) return placeholder();

    return ClipRRect(
      borderRadius: BorderRadius.circular(12.r),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: 360.r, maxWidth: 200.r),
        child: Image.file(
          file,
          fit: BoxFit.contain,
          errorBuilder: (context, error, stackTrace) => placeholder(),
        ),
      ),
    );
  }

  Widget _buildNowPlayingStat({
    required IconData icon,
    required String label,
    required String text,
  }) {
    return Row(
      children: [
        Icon(icon, color: Colors.white54, size: 20.r),
        SizedBox(width: 10.r),
        Text(
          '$label  ',
          style: TextStyle(
            color: Colors.white54,
            fontSize: 14.r,
            letterSpacing: 1.r,
          ),
        ),
        Text(
          text,
          style: TextStyle(
            color: Colors.white,
            fontSize: 16.r,
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    );
  }

  String _formatPlayTime(int? seconds) {
    if (seconds == null || seconds <= 0) return '—';
    final h = seconds ~/ 3600;
    final m = (seconds % 3600) ~/ 60;
    if (h > 0) return '${h}h ${m}m';
    if (m > 0) return '${m}m';
    return '<1m';
  }

  /// The running session length, formatted down to the second so the per-second
  /// tick is visible. Shown alongside the (static) total PLAY TIME while a game
  /// is active.
  String _formatSessionTime() {
    final total = _sessionWatch.elapsed.inSeconds;
    final h = total ~/ 3600;
    final m = (total % 3600) ~/ 60;
    final s = total % 60;
    if (h > 0) {
      return '${h}h ${m.toString().padLeft(2, '0')}m '
          '${s.toString().padLeft(2, '0')}s';
    }
    return '${m}m ${s.toString().padLeft(2, '0')}s';
  }

  String _formatLastPlayed(int? millis) {
    if (millis == null) return 'Never';
    final then = DateTime.fromMillisecondsSinceEpoch(millis);
    final diff = DateTime.now().difference(then);
    if (diff.inDays >= 1) {
      final d = diff.inDays;
      return d == 1 ? 'Yesterday' : '$d days ago';
    }
    if (diff.inHours >= 1) return '${diff.inHours}h ago';
    if (diff.inMinutes >= 1) return '${diff.inMinutes}m ago';
    return 'Just now';
  }

  /// Renders the in-game RetroAchievements panel: a progress header plus an
  /// unlocked-first grid of achievement badges. View-only (no gamepad input
  /// reaches the secondary engine), so there is no selection/scroll affordance.
  Widget _buildAchievementPanel(SecondaryDisplayStateData value) {
    final achievements =
        List<SecondaryAchievementItem>.from(value.achievements!)..sort((a, b) {
          if (a.earned != b.earned) return a.earned ? -1 : 1;
          return a.displayOrder.compareTo(b.displayOrder);
        });

    final newlyEarned = value.newlyEarnedIds?.toSet() ?? const <int>{};
    final progress = value.raTotal > 0 ? value.raEarned / value.raTotal : 0.0;
    final title = (value.raGameTitle != null && value.raGameTitle!.isNotEmpty)
        ? value.raGameTitle!
        : value.systemName;

    return Container(
      width: double.infinity,
      height: double.infinity,
      // Opaque background so the underlying game screenshot doesn't bleed
      // through; matches the secondary display's themed background color.
      color: value.backgroundColor != null
          ? Color(value.backgroundColor!)
          : Colors.black,
      padding: EdgeInsets.symmetric(horizontal: 24.r, vertical: 20.r),
      child: Stack(
        children: [
          Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Header: title + earned/total + points.
              Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Icon(
                    Symbols.trophy_rounded,
                    color: const Color(0xFFFFC107),
                    size: 26.r,
                  ),
                  SizedBox(width: 10.r),
                  Expanded(
                    child: Text(
                      title.toUpperCase(),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 18.r,
                        fontWeight: FontWeight.w600,
                        letterSpacing: 1.5.r,
                        fontFamily: 'Anta',
                      ),
                    ),
                  ),
                  SizedBox(width: 12.r),
                  Text(
                    '${value.raEarned}/${value.raTotal}',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 18.r,
                      fontWeight: FontWeight.bold,
                      fontFamily: 'Anta',
                    ),
                  ),
                  SizedBox(width: 12.r),
                  Text(
                    '${value.raPoints}/${value.raPointsTotal}p',
                    style: TextStyle(
                      color: const Color(0xFFFFC107),
                      fontSize: 16.r,
                      fontWeight: FontWeight.bold,
                      fontFamily: 'Anta',
                    ),
                  ),
                  SizedBox(width: 14.r),
                  // Touch toggle: grid <-> list. Shows the icon of the view
                  // you'll switch to. The bottom screen is touch-only since
                  // the gamepad is driving the game on the main screen.
                  GestureDetector(
                    onTap: () {
                      SfxService().playNavSound();
                      setState(
                        () => _achievementListView = !_achievementListView,
                      );
                    },
                    child: Container(
                      padding: EdgeInsets.all(8.r),
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(10.r),
                        border: Border.all(
                          color: Colors.white.withValues(alpha: 0.2),
                        ),
                      ),
                      child: Icon(
                        _achievementListView
                            ? Symbols.grid_view_rounded
                            : Symbols.view_list_rounded,
                        color: Colors.white,
                        size: 22.r,
                      ),
                    ),
                  ),
                ],
              ),
              SizedBox(height: 12.r),
              ClipRRect(
                borderRadius: BorderRadius.circular(4.r),
                child: LinearProgressIndicator(
                  value: progress.clamp(0.0, 1.0),
                  minHeight: 6.r,
                  backgroundColor: Colors.white10,
                  valueColor: const AlwaysStoppedAnimation<Color>(
                    Color(0xFFFFC107),
                  ),
                ),
              ),
              SizedBox(height: 16.r),
              // Content: badge grid or list, both touch-scrollable. Unlocked
              // achievements are sorted first.
              Expanded(
                child: _achievementListView
                    ? _buildAchievementListView(achievements, newlyEarned)
                    : SingleChildScrollView(
                        child: Wrap(
                          spacing: 8.r,
                          runSpacing: 8.r,
                          children: [
                            for (final a in achievements)
                              _buildAchievementBadge(
                                a,
                                isNew: newlyEarned.contains(a.id),
                              ),
                          ],
                        ),
                      ),
              ),
            ],
          ),

          // Celebration banner for freshly-earned achievements.
          if (_celebrate && newlyEarned.isNotEmpty)
            Align(
              alignment: Alignment.topCenter,
              child: Container(
                margin: EdgeInsets.only(top: 2.r),
                padding: EdgeInsets.symmetric(horizontal: 20.r, vertical: 10.r),
                decoration: BoxDecoration(
                  color: const Color(0xFFFFC107),
                  borderRadius: BorderRadius.circular(20.r),
                  boxShadow: [
                    BoxShadow(
                      color: const Color(0xFFFFC107).withValues(alpha: 0.5),
                      blurRadius: 24.r,
                    ),
                  ],
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Symbols.celebration_rounded,
                      color: Colors.black,
                      size: 22.r,
                    ),
                    SizedBox(width: 8.r),
                    Text(
                      '+${newlyEarned.length} this session',
                      style: TextStyle(
                        color: Colors.black,
                        fontSize: 16.r,
                        fontWeight: FontWeight.bold,
                        fontFamily: 'Anta',
                      ),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }

  /// Touch-scrollable list of achievements: badge + title + description, with
  /// points and an earned/locked indicator. Shows detail the grid can't.
  Widget _buildAchievementListView(
    List<SecondaryAchievementItem> achievements,
    Set<int> newlyEarned,
  ) {
    return ListView.separated(
      padding: EdgeInsets.only(bottom: 8.r),
      itemCount: achievements.length,
      separatorBuilder: (_, _) => SizedBox(height: 8.r),
      itemBuilder: (context, i) {
        final a = achievements[i];
        final isNew = newlyEarned.contains(a.id);
        return Container(
          padding: EdgeInsets.all(8.r),
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: a.earned ? 0.08 : 0.03),
            borderRadius: BorderRadius.circular(10.r),
            border: isNew
                ? Border.all(color: const Color(0xFFFFC107), width: 1.5.r)
                : null,
          ),
          child: Row(
            children: [
              _buildAchievementBadge(a, isNew: false),
              SizedBox(width: 12.r),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      a.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 15.r,
                        fontWeight: FontWeight.w600,
                        fontFamily: 'Anta',
                      ),
                    ),
                    if (a.description.isNotEmpty) ...[
                      SizedBox(height: 2.r),
                      Text(
                        a.description,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: Colors.white60, fontSize: 12.r),
                      ),
                    ],
                  ],
                ),
              ),
              SizedBox(width: 10.r),
              Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    '${a.points}p',
                    style: TextStyle(
                      color: const Color(0xFFFFC107),
                      fontSize: 13.r,
                      fontWeight: FontWeight.bold,
                      fontFamily: 'Anta',
                    ),
                  ),
                  SizedBox(height: 4.r),
                  Icon(
                    a.earned
                        ? Symbols.check_circle_rounded
                        : Symbols.lock_rounded,
                    color: a.earned ? const Color(0xFF66BB6A) : Colors.white24,
                    size: 18.r,
                  ),
                ],
              ),
            ],
          ),
        );
      },
    );
  }

  /// A single achievement badge: full-color when earned, dimmed locked icon
  /// otherwise, with a gold glow when earned during the current session.
  Widget _buildAchievementBadge(
    SecondaryAchievementItem a, {
    required bool isNew,
  }) {
    final double size = 46.r;
    final url = a.earned
        ? 'https://media.retroachievements.org/Badge/${a.badgeName}.png'
        : 'https://media.retroachievements.org/Badge/${a.badgeName}_lock.png';

    Widget badge = ClipRRect(
      borderRadius: BorderRadius.circular(8.r),
      child: Image.network(
        url,
        width: size,
        height: size,
        fit: BoxFit.cover,
        gaplessPlayback: true,
        errorBuilder: (context, error, stackTrace) => Container(
          width: size,
          height: size,
          color: Colors.white10,
          child: Icon(
            Symbols.trophy_rounded,
            color: Colors.white24,
            size: 24.r,
          ),
        ),
      ),
    );

    if (!a.earned) {
      badge = Opacity(opacity: 0.45, child: badge);
    }

    return Container(
      decoration: isNew
          ? BoxDecoration(
              borderRadius: BorderRadius.circular(10.r),
              border: Border.all(color: const Color(0xFFFFC107), width: 2.r),
              boxShadow: [
                BoxShadow(
                  color: const Color(0xFFFFC107).withValues(alpha: 0.6),
                  blurRadius: 12.r,
                ),
              ],
            )
          : null,
      padding: EdgeInsets.all(isNew ? 2.r : 0),
      child: badge,
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
