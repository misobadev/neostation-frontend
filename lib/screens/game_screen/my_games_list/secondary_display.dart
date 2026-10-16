part of '../my_games_list.dart';

/// Secondary-display, video preview, background and music-ducking logic for
/// the system games list.
///
/// Pushes selection metadata/artwork to the secondary hardware display,
/// drives the primary/secondary video previews, updates the ambient
/// background, and ducks background music while a video plays. All state
/// lives on the host [State]; this extension only moves the methods out of
/// the monolith — behaviour is unchanged. `setState` calls route through the
/// host [rebuild] bridge and the host static `_log` is qualified as
/// `_SystemGamesListState._log` (both required from an extension).
extension _SecondaryDisplay on _SystemGamesListState {
  /// Hard reset of the video preview system.
  void _resetVideoState() {
    _videoTimer?.cancel();
    _videoTimer = null;

    if (_videoController != null) {
      final controller = _videoController!;
      _videoController = null;
      try {
        controller.dispose();
      } catch (e) {
        _SystemGamesListState._log.w(
          'Error disposing video controller in reset: $e',
        );
      }
    }

    if (mounted) {
      rebuild(() {
        _showVideo = false;
        _isVideoLoading = false;
      });
    }
  }

  /// Graceful termination of video resources with state synchronization.
  void _stopVideoAndCleanup() {
    _videoTimer?.cancel();
    _videoTimer = null;

    if (_videoController != null) {
      final controller = _videoController!;
      _videoController = null;
      try {
        controller.dispose();
      } catch (e) {
        _SystemGamesListState._log.w('Error disposing video controller: $e');
      }
    }

    if (mounted) {
      rebuild(() {
        _showVideo = false;
        _isVideoLoading = false;
      });
    }
    _updateMusicDucking();
  }

  /// Orchestrates background tasks triggered by game selection changes.
  void _performBackgroundOperationsForSelectedGame({bool force = false}) {
    if (_selectedGame == null || !mounted) return;

    // Folder rows have no media/preview to resolve. Clear the primary preview
    // AND the secondary display, otherwise the second screen keeps showing the
    // art/video of the game that was hovered before backing out into the folder.
    if (_isFolderEntry(_selectedGame)) {
      _resetVideoState();
      _clearSecondaryDisplayForFolder();
      return;
    }

    // Suppress expensive operations (video, isolates) during rapid scrolling.
    if (_isNavigatingFast && !force) {
      _updateBackground(_selectedGame!);
      _updateSecondaryDisplay(_selectedGame!);
      return;
    }

    _detectGameSavesForSelectedGame();
    _loadLocalizedDescription();
    _startVideoTimer();
    _updateBackground(_selectedGame!);
    _updateSecondaryDisplay(_selectedGame!);
    _updateMusicDucking();
  }

  /// Clears the secondary display's game media when a folder row is focused, so
  /// the second screen drops back to the system/idle view instead of holding
  /// the previously-hovered game's art and video. No-op when nothing game-like
  /// is currently shown, to avoid redundant pushes while scrolling folders.
  void _clearSecondaryDisplayForFolder() {
    final state = _secondaryDisplayState;
    if (state == null) return;
    final current = state.value;
    if (current != null &&
        !current.isGameSelected &&
        current.gameId == null &&
        current.gameVideo == null) {
      return;
    }
    // ignore: unawaited_futures
    state.updateState(
      isGameSelected: false,
      clearGameId: true,
      clearVideo: true,
      clearFanart: true,
      clearScreenshot: true,
      clearWheel: true,
      clearImageBytes: true,
    );
  }

  /// Synchronizes selection metadata and assets with secondary hardware displays.
  ///
  /// [forceMediaRefresh] forces a push even when every media path is unchanged
  /// and bumps [SecondaryDisplayStateData.mediaRevision]. Use it after a
  /// re-scrape (forceOverwrite) rewrites the art in place: the paths stay the
  /// same, so the dedup below would otherwise skip the update and the secondary
  /// engine would keep showing the stale cached bitmap.
  Future<void> _updateSecondaryDisplay(
    GameModel game, {
    bool forceMediaRefresh = false,
  }) async {
    if (_secondaryDisplayState == null || _isNavigatingBack) return;

    // Folder placeholders carry no real media — never push them as a game, or
    // the second screen would show the stale art of the last hovered game.
    if (_isFolderEntry(game)) {
      _clearSecondaryDisplayForFolder();
      return;
    }

    final systemFolderName =
        SystemFolderNames.isAggregate(widget.system.folderName) &&
            game.systemFolderName != null
        ? game.systemFolderName!
        : widget.system.primaryFolderName;

    // Media resolution hierarchy.
    final screenshotPath = game.getScreenshotPath(
      systemFolderName,
      _fileProvider,
    );

    final fanartPath = game.getImagePath(
      systemFolderName,
      'fanarts',
      _fileProvider,
    );

    final wheelPath = game.getImagePath(
      systemFolderName,
      'wheels',
      _fileProvider,
    );

    final videoPath = _getVideoPath(game);
    final videoExists = await _fileProvider.fileExists(videoPath);

    final configProvider = mounted
        ? context.read<SqliteConfigProvider>()
        : null;
    final isVideoMuted = !configProvider!.config.videoSound;
    final isScraperLoggedIn = await ScreenScraperService.hasSavedCredentials();

    final isMusicSystem = widget.system.folderName == 'music';

    // State optimization: Skip updates if metadata remains identical. A forced
    // media refresh (post re-scrape) always pushes — the paths are unchanged
    // but their bytes are not, so the secondary engine must be told to re-decode.
    final currentState = _secondaryDisplayState?.value;
    final bool shouldUpdate =
        forceMediaRefresh ||
        currentState == null ||
        currentState.systemName != widget.system.realName ||
        currentState.gameId !=
            (isMusicSystem
                ? MusicPlayerService().activeTrack?.romPath
                : game.romPath) ||
        currentState.gameFanart !=
            (isMusicSystem
                ? null
                : (File(fanartPath).existsSync() ? fanartPath : null)) ||
        currentState.gameScreenshot !=
            (isMusicSystem
                ? null
                : (File(screenshotPath).existsSync()
                      ? screenshotPath
                      : null)) ||
        currentState.gameVideo !=
            (isMusicSystem ? null : (videoExists ? videoPath : null)) ||
        currentState.gameWheel !=
            (isMusicSystem
                ? null
                : (File(wheelPath).existsSync() ? wheelPath : null)) ||
        currentState.isVideoMuted != isVideoMuted ||
        currentState.isGameLaunching != _isGameLaunching;

    if (shouldUpdate && !_isNavigatingBack) {
      final bool hasFanart = !isMusicSystem && File(fanartPath).existsSync();
      final bool hasScreenshot =
          !isMusicSystem && File(screenshotPath).existsSync();
      final bool hasWheel = !isMusicSystem && File(wheelPath).existsSync();

      // ignore: unawaited_futures
      _secondaryDisplayState?.updateState(
        systemName: widget.system.realName,
        gameFanart: hasFanart ? fanartPath : null,
        gameScreenshot: hasScreenshot ? screenshotPath : null,
        clearFanart: !hasFanart,
        clearScreenshot: !hasScreenshot,
        gameWheel: hasWheel ? wheelPath : null,
        clearWheel: !hasWheel,
        gameVideo: null, // Reset video state during active scrolling.
        clearVideo: true,
        gameImageBytes: null,
        clearImageBytes: isMusicSystem
            ? (MusicPlayerService().activeTrack == null)
            : true,
        isGameSelected: true,
        isVideoMuted: isVideoMuted,
        backgroundColor: mounted
            ? Theme.of(context).scaffoldBackgroundColor.toARGB32()
            : null,
        isGameLaunching: _isGameLaunching,
        gameId: isMusicSystem
            ? MusicPlayerService().activeTrack?.romPath
            : game.romPath,
        isScraperLoggedIn: isScraperLoggedIn,
        // Bump the revision on a forced refresh so the secondary engine evicts
        // its now-stale cached bitmaps and re-decodes the same paths from disk.
        mediaRevision: forceMediaRefresh
            ? (currentState?.mediaRevision ?? 0) + 1
            : null,
        // Panel is shown only by the launch push / live poll; browsing and
        // returning from a game hide it (it fades out on the secondary screen).
        showAchievementPanel: false,
      );
    }

    _updateMusicDucking();

    // Special handling for cover art extraction in Music mode.
    if (isMusicSystem) {
      final musicService = MusicPlayerService();
      final activeTrack = musicService.activeTrack;

      if (activeTrack != null) {
        final String? activeRomPath = activeTrack.romPath;

        if (activeRomPath != null) {
          final currentBytes = _secondaryDisplayState?.value?.gameImageBytes;
          final activeBytes = musicService.activePicture;

          if (activeBytes != null &&
              !listEquals(activeBytes, currentBytes) &&
              !_isNavigatingBack) {
            // ignore: unawaited_futures
            _secondaryDisplayState?.updateState(
              gameImageBytes: activeBytes,
              gameId: activeRomPath,
            );
          } else if (activeBytes == null) {
            _musicExtractionTimer?.cancel();
            _musicExtractionTimer = Timer(
              const Duration(milliseconds: 250),
              () {
                musicService.extractPicture(activeRomPath).then((
                  Uint8List? bytes,
                ) {
                  if (bytes != null && mounted) {
                    final latestBytes =
                        _secondaryDisplayState?.value?.gameImageBytes;
                    if (!listEquals(bytes, latestBytes) && !_isNavigatingBack) {
                      _secondaryDisplayState?.updateState(
                        gameImageBytes: bytes,
                        gameId: activeRomPath,
                      );
                    }
                  }
                });
              },
            );
          }
        }
      } else {
        _secondaryDisplayState?.updateState(
          gameImageBytes: null,
          clearImageBytes: true,
        );
      }
    }
  }

  /// Pushes specific video path updates to the secondary screen.
  Future<void> _updateSecondaryDisplayVideo(GameModel game) async {
    if (_secondaryDisplayState == null ||
        _isNavigatingBack ||
        _selectedGame != game) {
      return;
    }

    final videoPath = _getVideoPath(game);
    final videoExists = await _fileProvider.fileExists(videoPath);

    if (videoExists && !_isNavigatingBack && _selectedGame == game) {
      // ignore: unawaited_futures
      _secondaryDisplayState?.updateState(gameVideo: videoPath);
      _updateMusicDucking();
    }
  }

  /// Dynamically adjusts background music volume to prevent audio conflicts with video previews.
  void _updateMusicDucking() {
    if (!mounted) return;

    final config = context.read<SqliteConfigProvider>().config;

    // Suppress ducking within the Music Player system itself.
    if (widget.system.folderName == 'music') return;

    if (!config.videoSound) {
      MusicPlayerService().setDucked(false);
      return;
    }

    // Condition 2: Video is actually playing on primary
    bool primaryIsPlaying = _showVideo && !_isGameLaunching;

    // Condition 3: Secondary screen is active and actually playing a video
    final secondaryState = _secondaryDisplayState?.value;
    bool secondaryIsPlaying =
        (secondaryState?.isSecondaryActive ?? false) &&
        (secondaryState?.gameVideo != null);

    final shouldDuck = primaryIsPlaying || secondaryIsPlaying;
    MusicPlayerService().setDucked(shouldDuck);
  }

  void _updateBackground(GameModel game) {
    // Aggregate views keep their own backdrop: the list's folder name is not a
    // hardware system, so there is no per-system art to swap in.
    if (!mounted || SystemFolderNames.isAggregate(widget.system.folderName)) {
      return;
    }

    final systemFolderName = widget.system.primaryFolderName;

    // Resolve game background: Prioritize high-resolution fanart, fallback to screenshot, then system default.
    String imagePath = game.getImagePath(
      systemFolderName,
      'fanarts',
      _fileProvider,
    );
    bool exists = File(imagePath).existsSync();

    if (!exists) {
      imagePath = game.getScreenshotPath(systemFolderName, _fileProvider);
      exists = File(imagePath).existsSync();
    }

    final ImageProvider imageProvider;
    if (exists) {
      imageProvider = FileImage(File(imagePath));
    } else {
      // Hardware-specific fallback if no game-specific art is resolved.
      final sysId =
          SystemFolderNames.isAggregate(widget.system.folderName) &&
              game.systemFolderName != null
          ? game.systemFolderName!
          : widget.system.id;
      final path =
          'assets/images/logos/${SystemFolderNames.artFolderName(sysId.toString())}.webp'; // Correcting to logo fallback for grid consistency.
      imageProvider = AssetImage(path);
      imagePath = path;
    }

    context.read<SystemBackgroundProvider>().updateImage(
      imageProvider,
      imagePath: imagePath,
    );
  }

  /// Initiates the media preview sequence for the primary and secondary displays.
  void _startVideoTimer() {
    _videoTimer?.cancel();
    if (!mounted || _isGameLaunching) return;

    _videoTimer = Timer(_SystemGamesListState._videoDelay, () async {
      if (!mounted) return;
      if (mounted && _selectedGame != null) {
        // Always attempt secondary display video update.
        await _updateSecondaryDisplayVideo(_selectedGame!);
        if (!mounted) return;

        // Primary display video is conditional based on user preference for 'Game Info'.
        final showGameInfo = context
            .read<SqliteConfigProvider>()
            .config
            .showGameInfo;
        if (showGameInfo) {
          await _initializeVideo(_selectedGame!);
        }
      }
    });
  }

  /// Initializes the video player for the primary UI, including volume and loop management.
  Future<void> _initializeVideo(GameModel game) async {
    if (!mounted ||
        _selectedGame == null ||
        _selectedGame != game ||
        _isVideoLoading) {
      return;
    }

    final showGameInfo = context
        .read<SqliteConfigProvider>()
        .config
        .showGameInfo;
    if (!showGameInfo) {
      return;
    }

    if (_isGameLaunching) {
      return;
    }

    rebuild(() => _isVideoLoading = true);

    final videoPath = _getVideoPath(game);
    final file = File(videoPath);
    final fileExists = _fileProvider.isInitialized
        ? await _fileProvider.fileExists(videoPath)
        : file.existsSync();

    if (!mounted || _selectedGame != game) {
      if (mounted) {
        rebuild(() {
          _isVideoLoading = false;
        });
      }
      return;
    }

    if (!fileExists) {
      if (mounted) {
        rebuild(() {
          _showVideo = false;
          _isVideoLoading = false;
        });
      }
      return;
    }

    try {
      if (!mounted || _selectedGame != game) {
        return;
      }

      // CRITICAL: Ensure previously active controllers are disposed to prevent resource leaks.
      if (_videoController != null) {
        try {
          _videoController!.pause();
          _videoController!.dispose();
        } catch (e) {
          _SystemGamesListState._log.w('Error disposing old controller: $e');
        }
        _videoController = null;
      }

      final mainController = VideoPlayerController.file(
        file,
        videoPlayerOptions: VideoPlayerOptions(mixWithOthers: false),
      );

      await mainController.initialize();

      if (mounted && _selectedGame == game && _selectedGame != null) {
        rebuild(() {
          _videoController = mainController;
          _showVideo = true;
          _isVideoLoading = false;
        });

        // Guard each await: navigation can dispose _videoController between calls.
        await mainController.setVolume(0.0);
        if (!mounted || _videoController != mainController) return;
        await mainController.setLooping(true);
        if (!mounted || _videoController != mainController) return;
        await mainController.play();
        if (!mounted || _videoController != mainController) return;

        _updateMusicDucking();
      } else {
        mainController.dispose();
        if (mounted) {
          rebuild(() {
            _isVideoLoading = false;
          });
        }
      }
    } catch (error) {
      _SystemGamesListState._log.e(
        'Error initializing video in LIST view: $error',
      );
      if (mounted) {
        rebuild(() {
          _showVideo = false;
          _isVideoLoading = false;
        });
      }
    }
  }

  /// Resolves the absolute filesystem path for the targeted game video.
  String _getVideoPath(GameModel game) {
    final systemFolderName =
        SystemFolderNames.isAggregate(widget.system.folderName) &&
            game.systemFolderName != null
        ? game.systemFolderName!
        : widget.system.primaryFolderName;

    return game.getVideoPath(systemFolderName, _fileProvider);
  }
}
