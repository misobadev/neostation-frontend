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
  /// Whether the user allows preview videos on either screen.
  bool get _videoPreviewsEnabled =>
      mounted &&
      context.read<SqliteConfigProvider>().config.videoPreviewDelay >= 0;

  int get _videoPreviewDelaySeconds =>
      context.read<SqliteConfigProvider>().config.videoPreviewDelay;

  /// Hard reset of the video preview system.
  void _resetVideoState() {
    _videoTimer?.cancel();
    _videoTimer = null;

    if (_videoController != null) {
      final controller = _videoController!;
      _videoController = null;
      _videoControllerGame = null;
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
      _updateMusicDucking();
    }
  }

  /// Graceful termination of video resources with state synchronization.
  void _stopVideoAndCleanup() {
    _videoTimer?.cancel();
    _videoTimer = null;

    if (_videoController != null) {
      final controller = _videoController!;
      _videoController = null;
      _videoControllerGame = null;
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

  /// Clears an already-playing secondary video without waiting for the
  /// media-dedup pass, which would otherwise skip an unchanged selection.
  void _clearSecondaryDisplayVideo() {
    final state = _secondaryDisplayState;
    if (state == null) return;
    // ignore: unawaited_futures
    state.updateState(
      gameVideo: null,
      clearVideo: true,
      videoPreviewDeadlineMillis: 0,
    );
    _updateMusicDucking();
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
        currentState.isGameLaunching != _isGameLaunching ||
        currentState.videoPreviewDelay !=
            configProvider.config.videoPreviewDelay ||
        currentState.videoPreviewDeadlineMillis !=
            (_videoPreviewDeadline?.millisecondsSinceEpoch ?? 0);

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
        videoPreviewDelay: configProvider.config.videoPreviewDelay,
        videoPreviewDeadlineMillis:
            _videoPreviewDeadline?.millisecondsSinceEpoch ?? 0,
        videoPreviewFileChecked: _videoPreviewFileChecked,
        videoPreviewFileExists: _videoPreviewFileExists,
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
    final secondary = _secondaryDisplayState?.value;
    if (secondary == null ||
        !secondary.isSecondaryActive ||
        _isNavigatingBack ||
        _selectedGame != game ||
        !_videoPreviewsEnabled) {
      return;
    }

    final videoPath = _getVideoPath(game);
    final videoExists = await _fileProvider.fileExists(videoPath);
    if (!mounted || !_videoPreviewsEnabled) return;

    if (mounted && _selectedGame == game) {
      rebuild(() {
        _videoPreviewFileChecked = true;
        _videoPreviewFileExists = videoExists;
      });
    }

    if (!_isNavigatingBack && _selectedGame == game) {
      // ignore: unawaited_futures
      _secondaryDisplayState?.updateState(
        gameVideo: videoExists ? videoPath : null,
        clearVideo: !videoExists,
        videoPreviewFileChecked: true,
        videoPreviewFileExists: videoExists,
      );
      if (videoExists) _updateMusicDucking();
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
    bool primaryIsPlaying =
        _videoController?.value.isPlaying == true && !_isGameLaunching;

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
          'assets/images/logos/$sysId.webp'; // Correcting to logo fallback for grid consistency.
      imageProvider = AssetImage(path);
      imagePath = path;
    }

    context.read<SystemBackgroundProvider>().updateImage(
      imageProvider,
      imagePath: imagePath,
    );
  }

  /// Checks whether the selected game has a preview file without creating a
  /// controller. The visual countdown must not run for a game that only has a
  /// screenshot.
  Future<void> _checkVideoPreviewFile(GameModel game) async {
    if (_videoPreviewFileChecked || _videoPreviewFileCheckGame == game) return;
    _videoPreviewFileCheckGame = game;
    try {
      final path = _getVideoPath(game);
      final exists = _fileProvider.isInitialized
          ? await _fileProvider.fileExists(path)
          : await File(path).exists();
      if (!mounted || _selectedGame != game) return;
      rebuild(() {
        _videoPreviewFileChecked = true;
        _videoPreviewFileExists = exists;
      });
      _secondaryDisplayState?.updateState(
        videoPreviewFileChecked: true,
        videoPreviewFileExists: exists,
      );
    } finally {
      if (_videoPreviewFileCheckGame == game) {
        _videoPreviewFileCheckGame = null;
      }
    }
  }

  /// Initiates the media preview sequence for the primary and secondary displays.
  void _startVideoTimer() {
    if (!mounted || _isGameLaunching || !_videoPreviewsEnabled) return;

    final viewMode = context.read<SqliteConfigProvider>().config.gameViewMode;
    final secondaryActive =
        _secondaryDisplayState?.value?.isSecondaryActive ?? false;
    if (viewMode != 'list' && !secondaryActive) {
      _videoPreviewDeadline = null;
      _resetVideoState();
      return;
    }

    // The selection path runs this once immediately and again when rapid
    // navigation settles. Reuse an already prepared controller, or let the
    // in-flight preparation finish, instead of disposing and recreating it.
    final game = _selectedGame;
    if (game != null &&
        _videoController?.value.isInitialized == true &&
        _videoControllerGame == game) {
      return;
    }
    if (_isVideoLoading) return;

    if (game != null) unawaited(_checkVideoPreviewFile(game));

    _videoTimer?.cancel();
    final delay = _videoPreviewDelaySeconds;
    _videoPreviewSelectedAt ??= DateTime.now();
    _videoPreviewDeadline ??= _videoPreviewSelectedAt!.add(
      Duration(seconds: delay),
    );

    final deadline = _videoPreviewDeadline;
    final wait = deadline?.difference(DateTime.now()) ?? Duration.zero;
    late final Timer timer;
    timer = Timer(wait.isNegative ? Duration.zero : wait, () async {
      if (identical(_videoTimer, timer)) _videoTimer = null;
      if (!mounted) return;
      final game = _selectedGame;
      if (game == null) return;

      final config = context.read<SqliteConfigProvider>().config;
      final secondaryActive =
          _secondaryDisplayState?.value?.isSecondaryActive ?? false;

      if (secondaryActive) {
        await _updateSecondaryDisplayVideo(game);
        if (!mounted) return;
      }

      // The primary preview only exists in the list view's media tab.
      if (config.gameViewMode == 'list' && config.showGameInfo) {
        await _initializeVideo(game);
      }
    });
    _videoTimer = timer;
  }

  /// Initializes the video player for the primary UI, including volume and loop management.
  Future<void> _initializeVideo(GameModel game) async {
    if (!mounted ||
        context.read<SqliteConfigProvider>().config.gameViewMode != 'list' ||
        _selectedGame == null ||
        _selectedGame != game ||
        _isVideoLoading ||
        !_videoPreviewsEnabled) {
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

    // A second timer may fire for the same selection (for example when the
    // fast-navigation settle timer asks for background work again). Reuse the
    // controller already ready for this game instead of disposing and starting
    // it again, which showed as a visible restart at 0 s.
    if (_videoController?.value.isInitialized == true &&
        _videoControllerGame == game) {
      return;
    }

    rebuild(() => _isVideoLoading = true);

    final videoPath = _getVideoPath(game);
    final file = File(videoPath);
    final fileExists = _fileProvider.isInitialized
        ? await _fileProvider.fileExists(videoPath)
        : await file.exists();

    if (!mounted || _selectedGame != game || !_videoPreviewsEnabled) {
      if (mounted) {
        rebuild(() {
          _showVideo = false;
          _isVideoLoading = false;
        });
      }
      return;
    }

    if (mounted && _selectedGame == game) {
      rebuild(() {
        _videoPreviewFileChecked = true;
        _videoPreviewFileExists = fileExists;
      });
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

      // The setting can be turned off while the decoder initializes.
      if (!mounted || _selectedGame != game || !_videoPreviewsEnabled) {
        mainController.dispose();
        if (mounted) {
          rebuild(() {
            _showVideo = false;
            _isVideoLoading = false;
          });
        }
        return;
      }

      if (mounted && _selectedGame == game && _selectedGame != null) {
        rebuild(() {
          _videoController = mainController;
          _videoControllerGame = game;
          _showVideo = true;
          _isVideoLoading = false;
        });

        // Guard each await: navigation can dispose _videoController between calls.
        await mainController.setVolume(0.0);
        if (!mounted || _videoController != mainController) return;
        await mainController.setLooping(true);
        if (!mounted || _videoController != mainController) return;
        // Playback starts from GameDetailsCardList once the selection deadline
        // has elapsed and the player is visible, so audio cannot lead the
        // screenshot.
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
