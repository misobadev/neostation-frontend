part of '../my_systems_grid.dart';

/// Theme/background asset loading and secondary-display sync for the systems grid.
///
/// The asset slice of [_SystemCardGridViewState] — reacting to secondary-display
/// activation, loading per-theme system backgrounds, precaching card art, and
/// pushing the current selection's logo/background to the secondary hardware
/// display — moved out of the monolith. Behaviour is unchanged. State lives on the
/// host [State] (extensions can't declare fields); `setState` calls route through
/// the host [rebuild] bridge (`State.setState` is `@protected` and can't be invoked
/// from an extension).
extension _ThemeBackground on _SystemCardGridViewState {
  // When secondary display signals it's active (startup or reconnect),
  // immediately push current system state so default logo never shows.
  void _onSecondaryStateChanged() {
    if (!mounted || !widget.enableSecondaryDisplay) return;
    final isActive = _secondaryDisplayState?.value?.isSecondaryActive ?? false;
    // Update the guard BEFORE pushing state. _updateSecondaryScreenName() calls
    // updateState(), which synchronously re-enters this listener via
    // notifyListeners(); if _prevIsSecondaryActive were still false the
    // edge-condition below would stay true and recurse until the stack
    // overflows (a CPU spike per tab switch on devices with a secondary screen).
    final wasActive = _prevIsSecondaryActive;
    _prevIsSecondaryActive = isActive;
    if (isActive && !wasActive) {
      _updateSecondaryScreenName();
    }
  }

  void _loadThemeAssetsForSystems() {
    if (!mounted || !widget.enableThemeAssets) return;

    final neoAssets = context.read<NeoAssetsProvider>();
    final themeFolder = neoAssets.activeThemeFolder;

    if (themeFolder == _lastThemeFolder) return;
    _lastThemeFolder = themeFolder;

    if (themeFolder.isEmpty) {
      if (_themeBackgrounds.isNotEmpty) {
        rebuild(() {
          _themeBackgrounds.clear();
        });
      }
      return;
    }

    final systems = widget.systems.map((s) {
      return s is SystemInfo ? s : SystemInfo.fromSystemMetadata(s);
    }).toList();

    final folderNames = systems
        .where((s) => !s.isGame)
        .map((s) => s.primaryFolderName ?? s.folderName ?? '')
        .where((f) => f.isNotEmpty)
        .toSet();

    final Map<String, String?> newBgs = {};

    for (final folder in folderNames) {
      newBgs[folder] = neoAssets.getBackgroundForSystemSync(folder);
    }

    rebuild(() {
      _themeBackgrounds
        ..clear()
        ..addAll(newBgs);
    });
  }

  void _precacheSystemBackgrounds() {
    if (!mounted || _performanceMode) return;
    final systems = _toSystemCards(widget.systems);
    for (final sys in systems) {
      if (sys.isGame) {
        final wheel = sys.customWheelImage;
        if (wheel != null && wheel.isNotEmpty) {
          final file = File(wheel);
          if (file.existsSync()) {
            precacheImage(ResizeImage(FileImage(file), width: 256), context);
          }
        }
        final customBg = sys.customBackgroundPath;
        if (customBg != null && customBg.isNotEmpty) {
          final file = File(customBg);
          if (file.existsSync()) {
            precacheImage(ResizeImage(FileImage(file), width: 1024), context);
          }
        }
      } else {
        final customBg = sys.customBackgroundPath;
        if (customBg != null && customBg.isNotEmpty) {
          final file = File(customBg);
          if (file.existsSync()) {
            precacheImage(ResizeImage(FileImage(file), width: 512), context);
          }
        } else {
          final folderName = sys.primaryFolderName ?? sys.folderName ?? '';
          final themeBg = _themeBackgrounds[folderName];
          if (themeBg != null && themeBg.isNotEmpty) {
            final file = File(themeBg);
            if (file.existsSync()) {
              precacheImage(ResizeImage(FileImage(file), width: 512), context);
            }
          }
        }

        final customLogo = sys.customLogoPath;
        if (customLogo != null && customLogo.isNotEmpty) {
          final file = File(customLogo);
          if (file.existsSync()) {
            precacheImage(ResizeImage(FileImage(file), width: 512), context);
          }
        }
      }
    }
  }

  /// Synchronizes the current selection with the secondary hardware display.
  void _updateSecondaryScreenName() {
    if (!Platform.isAndroid) return;
    if (!widget.enableSecondaryDisplay) return;
    if (_secondaryDisplayState == null) return;
    if (widget.selectedIndex < 0 ||
        widget.selectedIndex >= widget.systems.length) {
      return;
    }

    final system = widget.systems[widget.selectedIndex];
    final info = system is SystemInfo
        ? system
        : SystemInfo.fromSystemMetadata(system);
    final folder = info.primaryFolderName ?? info.folderName ?? 'all';

    final String? customLogo = info.customLogoPath?.isNotEmpty == true
        ? info.customLogoPath
        : null;
    final String? systemLogo = info.isGame
        ? info.customWheelImage
        : (customLogo ?? 'assets/images/logos/$folder.webp');
    final bool isLogoAsset = !info.isGame && customLogo == null;

    final String? customBg = info.customBackgroundPath;
    final bool hasCustomBg = customBg != null && customBg.isNotEmpty;
    final String? themeBg = hasCustomBg ? null : _themeBackgrounds[folder];
    final String? systemBackground = hasCustomBg ? customBg : themeBg;

    final themeProvider = Provider.of<ThemeProvider>(context, listen: false);
    final isOled = themeProvider.isOled;

    // Recent game cards drive the secondary with the game's own art (fanart +
    // wheel) through the game-selected path, matching the game-view browse
    // experience so the fanart-dim setting applies here too. Pushing the fanart
    // as a plain systemBackground (the else branch below) renders it via
    // _buildSystemBackground, which has no dim scrim.
    if (info.isGame && info.gameModel != null) {
      final game = info.gameModel!;
      final gameFolder = game.systemFolderName ?? folder;
      final fileProvider = Provider.of<FileProvider>(context, listen: false);
      final fanartPath = game.getImagePath(gameFolder, 'fanarts', fileProvider);
      final wheelPath = game.getImagePath(gameFolder, 'wheels', fileProvider);
      final hasFanart = fanartPath.isNotEmpty && File(fanartPath).existsSync();
      final hasWheel = wheelPath.isNotEmpty && File(wheelPath).existsSync();

      _secondaryDisplayState?.updateState(
        systemName: (info.shortName ?? info.title ?? 'NEOSTATION')
            .toUpperCase(),
        backgroundColor: Theme.of(context).scaffoldBackgroundColor.toARGB32(),
        isGameSelected: true,
        gameFanart: hasFanart ? fanartPath : null,
        clearFanart: !hasFanart,
        gameWheel: hasWheel ? wheelPath : null,
        clearWheel: !hasWheel,
        gameScreenshot: null,
        clearScreenshot: true,
        gameVideo: null,
        clearVideo: true,
        gameImageBytes: null,
        clearImageBytes: true,
        gameId: game.romPath,
        useShader: false,
        useFluidShader: false,
        isOled: isOled,
      );
      return;
    }

    _secondaryDisplayState?.updateState(
      systemName: (info.shortName ?? info.title ?? "NEOSTATION").toUpperCase(),
      backgroundColor: Theme.of(context).scaffoldBackgroundColor.toARGB32(),
      systemLogo: systemLogo,
      isLogoAsset: isLogoAsset,
      systemBackground: systemBackground,
      clearSystemBackground: systemBackground == null,
      isBackgroundAsset: false,
      useShader: systemBackground == null,
      shaderColor1: info.color1AsColor?.toARGB32(),
      shaderColor2: info.color2AsColor?.toARGB32(),
      isGameSelected: false,
      clearFanart: true,
      clearScreenshot: true,
      clearWheel: true,
      clearVideo: true,
      clearImageBytes: true,
      clearGameId: true,
      useFluidShader: false,
      isOled: isOled,
    );
  }
}
