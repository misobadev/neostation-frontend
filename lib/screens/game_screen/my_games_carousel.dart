import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:provider/provider.dart';
import 'package:neostation/models/game_model.dart';
import 'package:neostation/models/system_model.dart';
import 'package:neostation/providers/file_provider.dart';
import 'package:neostation/providers/sqlite_config_provider.dart';
import 'package:neostation/providers/system_background_provider.dart';
import 'package:neostation/services/game_service.dart';
import 'package:neostation/services/sfx_service.dart';
import 'package:neostation/utils/gamepad_nav.dart';
import 'package:neostation/screens/app_screen.dart';
import 'package:neostation/widgets/game_view_mode_dropdown.dart';
import 'package:neostation/widgets/native_carousel.dart';
import 'package:neostation/widgets/game_view_footer.dart';
import 'package:neostation/constants/system_folder_names.dart';

class GamesCarousel extends StatefulWidget {
  final SystemModel system;
  final List<GameModel> games;
  final int selectedIndex;
  final FileProvider fileProvider;
  final Function(GameModel) onGameSelected;
  final VoidCallback onBack;
  final VoidCallback onPlay;
  final VoidCallback? onFavorite;
  final VoidCallback? onRandom;
  final VoidCallback? onSettings;
  final VoidCallback? onScrape;
  final Set<String> scrapingGameRomnames;
  final Map<String, double> scrapeProgress;

  const GamesCarousel({
    super.key,
    required this.system,
    required this.games,
    required this.selectedIndex,
    required this.fileProvider,
    required this.onGameSelected,
    required this.onBack,
    required this.onPlay,
    this.onFavorite,
    this.onRandom,
    this.onSettings,
    this.onScrape,
    this.scrapingGameRomnames = const {},
    this.scrapeProgress = const {},
  });

  @override
  State<GamesCarousel> createState() => _GamesCarouselState();
}

class _GamesCarouselState extends State<GamesCarousel> {
  final GlobalKey<NativeCarouselState> _carouselKey = GlobalKey();
  final ScrollController _letterBarController = ScrollController();

  int _currentIndex = 0;
  late GamepadNavigation _gamepadNav;
  final Map<String, double> _letterWidthCache = {};
  final Map<String, bool> _fileExistsCache = {};
  int _lastBgIndex = -1;

  static final Map<String, Size?> _imgSizeCache = {};

  static Size? _readImageSize(String path) {
    if (_imgSizeCache.containsKey(path)) return _imgSizeCache[path];
    try {
      final file = File(path);
      if (!file.existsSync()) return null;
      final raf = file.openSync();
      try {
        final header = Uint8List(24);
        raf.readIntoSync(header);
        if (header[0] == 0x89 &&
            header[1] == 0x50 &&
            header[2] == 0x4E &&
            header[3] == 0x47) {
          final w = _readInt32BE(header, 16);
          final h = _readInt32BE(header, 20);
          if (w > 0 && h > 0 && w < 10000 && h < 10000) {
            final r = Size(w.toDouble(), h.toDouble());
            _imgSizeCache[path] = r;
            return r;
          }
        }
        if (header[0] == 0xFF && header[1] == 0xD8) {
          raf.setPositionSync(0);
          final len = raf.lengthSync().clamp(0, 65536).toInt();
          final buf = Uint8List(len);
          raf.readIntoSync(buf);
          int i = 2;
          while (i < buf.length - 9) {
            if (buf[i] != 0xFF) {
              i++;
              continue;
            }
            if (buf[i + 1] == 0xC0 || buf[i + 1] == 0xC2) {
              final h = (buf[i + 5] << 8) | buf[i + 6];
              final w = (buf[i + 7] << 8) | buf[i + 8];
              if (w > 0 && h > 0 && w < 10000 && h < 10000) {
                final r = Size(w.toDouble(), h.toDouble());
                _imgSizeCache[path] = r;
                return r;
              }
            }
            i += ((buf[i + 2] << 8) | buf[i + 3]) + 2;
          }
        }
      } finally {
        raf.closeSync();
      }
    } catch (_) {}
    return null;
  }

  static int _readInt32BE(List<int> bytes, int offset) =>
      (bytes[offset] << 24) |
      (bytes[offset + 1] << 16) |
      (bytes[offset + 2] << 8) |
      bytes[offset + 3];

  double? _boxAspectRatio(GameModel game) {
    if (game.box2dAspectRatio != null && game.box2dAspectRatio!.isNotEmpty) {
      final parts = game.box2dAspectRatio!.split('/');
      if (parts.length == 2) {
        final w = double.tryParse(parts[0]);
        final h = double.tryParse(parts[1]);
        if (w != null && h != null && w > 0 && h > 0) return w / h;
      }
    }
    final boxPath = _resolveImagePath(game, 'box2d');
    if (boxPath.isNotEmpty) {
      final size = _readImageSize(boxPath);
      if (size != null && size.width > 0 && size.height > 0) {
        return size.width / size.height;
      }
    }
    return null;
  }

  static const String _favoritesLabel = '★';

  bool get _hasFavoriteGames => widget.games.any((g) => g.isFavorite == true);

  List<String> get _uniqueLetters {
    final letters = <String>[];
    if (_hasFavoriteGames) {
      letters.add(_favoritesLabel);
    }
    for (final game in widget.games) {
      if (game.isFavorite == true) continue;

      final displayName = game.name.isNotEmpty ? game.name : game.realname;
      final letter = displayName.isNotEmpty
          ? displayName[0].toUpperCase()
          : '#';
      if (letters.isEmpty || letters.last != letter) {
        letters.add(letter);
      }
    }
    return letters;
  }

  String _getLetterForGame(GameModel game) {
    if (game.isFavorite == true) return _favoritesLabel;

    final displayName = game.name.isNotEmpty ? game.name : game.realname;
    return displayName.isNotEmpty ? displayName[0].toUpperCase() : '#';
  }

  int _getFirstGameIndexForLetter(String letter) {
    if (letter == _favoritesLabel) {
      for (int i = 0; i < widget.games.length; i++) {
        if (widget.games[i].isFavorite == true) return i;
      }
      return 0;
    }

    for (int i = 0; i < widget.games.length; i++) {
      if (widget.games[i].isFavorite == true) continue;
      if (_getLetterForGame(widget.games[i]) == letter) return i;
    }
    return 0;
  }

  int get _gamesLength => widget.games.isEmpty ? 1 : widget.games.length;

  @override
  void initState() {
    super.initState();
    _currentIndex = widget.selectedIndex.clamp(0, _gamesLength - 1);
    _initializeGamepad();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scrollToCurrentLetter();
      _updateBackground();
    });
  }

  @override
  void didUpdateWidget(GamesCarousel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.selectedIndex != oldWidget.selectedIndex &&
        widget.selectedIndex != _currentIndex) {
      setState(() {
        _currentIndex = widget.selectedIndex.clamp(0, _gamesLength - 1);
      });
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _carouselKey.currentState?.jumpToPage(_currentIndex);
        _scrollToCurrentLetter();
        _updateBackground();
      });
    }
    if (widget.games != oldWidget.games) {
      _letterWidthCache.clear();
      if (_currentIndex >= widget.games.length) {
        _currentIndex = 0;
      }
    }
  }

  @override
  void dispose() {
    _cleanupGamepad();
    _letterBarController.dispose();
    super.dispose();
  }

  void _initializeGamepad() {
    _gamepadNav = GamepadNavigation(
      onNavigateLeft: () {
        SfxService().playNavSound();
        _carouselKey.currentState?.previousPage();
      },
      onNavigateRight: () {
        SfxService().playNavSound();
        _carouselKey.currentState?.nextPage();
      },
      onSelectItem: () {
        if (_currentIndex >= 0 && _currentIndex < widget.games.length) {
          widget.onPlay();
        }
      },
      onBack: widget.onBack,
      onFavorite: widget.onFavorite,
      onXButton: () {
        try {
          GameViewModeDropdown.globalKey.currentState?.showDropdown();
        } catch (_) {}
      },
      onLeftTrigger: widget.onRandom,
      onSelectButton: widget.onScrape,
      onSettings: widget.onSettings,
      onPreviousTab: AppNavigation.previousTab,
      onNextTab: AppNavigation.nextTab,
      onLeftBumper: AppNavigation.previousTab,
      onRightBumper: AppNavigation.nextTab,
    );

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _gamepadNav.initialize();
      GamepadNavigationManager.pushLayer(
        'games_carousel',
        onActivate: () => _gamepadNav.activate(),
        onDeactivate: () => _gamepadNav.deactivate(),
      );
    });
  }

  void _cleanupGamepad() {
    GamepadNavigationManager.popLayer('games_carousel');
    _gamepadNav.dispose();
  }

  void _onPageChanged(int index, CarouselPageChangeReason reason) {
    if (reason == CarouselPageChangeReason.manual) {
      SfxService().playNavSound();
    }
    setState(() {
      _currentIndex = index;
    });
    if (index < widget.games.length) {
      widget.onGameSelected(widget.games[index]);
    }
    _scrollToCurrentLetter();
    _updateBackground();
  }

  void _updateBackground() {
    if (!mounted || widget.games.isEmpty) return;
    if (_currentIndex < 0 || _currentIndex >= widget.games.length) return;
    if (_lastBgIndex == _currentIndex) return;
    _lastBgIndex = _currentIndex;

    final game = widget.games[_currentIndex];
    final folder = _folderForGame(game);

    String imagePath = game.getImagePath(
      folder,
      'fanarts',
      widget.fileProvider,
    );
    bool exists = _fileExistsCache.putIfAbsent(
      imagePath,
      () => File(imagePath).existsSync(),
    );

    if (!exists) {
      imagePath = game.getScreenshotPath(folder, widget.fileProvider);
      exists = _fileExistsCache.putIfAbsent(
        imagePath,
        () => File(imagePath).existsSync(),
      );
    }

    final ImageProvider imageProvider;
    if (exists) {
      imageProvider = FileImage(File(imagePath));
    } else {
      final sysId = widget.system.id;
      final path = 'assets/images/systems/logos/$sysId.webp';
      imageProvider = AssetImage(path);
      imagePath = path;
    }

    context.read<SystemBackgroundProvider>().updateImage(
      imageProvider,
      imagePath: imagePath,
    );
  }

  void _scrollToCurrentLetter() {
    if (!_letterBarController.hasClients || widget.games.isEmpty) return;

    final currentLetter = _getLetterForGame(widget.games[_currentIndex]);
    final letters = _uniqueLetters;
    final letterIndex = letters.indexOf(currentLetter);
    if (letterIndex < 0) return;

    final textStyle = TextStyle(fontSize: 11.r, fontWeight: FontWeight.bold);
    final selectedTextStyle = textStyle.copyWith(fontWeight: FontWeight.w800);
    double offset = 0;
    for (int i = 0; i < letterIndex; i++) {
      offset += _calculateLetterWidth(letters[i], selectedTextStyle) + 6.r;
    }
    final letterWidth = _calculateLetterWidth(currentLetter, selectedTextStyle);
    final screenWidth = MediaQuery.of(context).size.width;
    double targetOffset = offset - (screenWidth / 2) + (letterWidth / 2);
    targetOffset = targetOffset.clamp(
      0.0,
      _letterBarController.position.maxScrollExtent,
    );

    _letterBarController.animateTo(
      targetOffset,
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeOutCubic,
    );
  }

  double _calculateLetterWidth(String letter, TextStyle style) {
    final cacheKey = '$letter|${style.fontSize}|${style.fontWeight?.value}';
    return _letterWidthCache.putIfAbsent(cacheKey, () {
      final textPainter = TextPainter(
        text: TextSpan(text: letter, style: style),
        textAlign: TextAlign.center,
        maxLines: 1,
        textDirection: TextDirection.ltr,
      )..layout();
      return textPainter.width + 20.r;
    });
  }

  double _getLetterBarOffset(
    String targetLetter,
    List<String> letters,
    TextStyle style,
  ) {
    double offset = 0;
    for (final letter in letters) {
      if (letter == targetLetter) break;
      offset += _calculateLetterWidth(letter, style) + 6.r;
    }
    return offset;
  }

  String _folderForGame(GameModel game) {
    if ((widget.system.folderName == SystemFolderNames.all ||
            widget.system.folderName == SystemFolderNames.favorites) &&
        game.systemFolderName != null) {
      return game.systemFolderName!;
    }
    return widget.system.primaryFolderName;
  }

  String _resolveImagePath(GameModel game, String imageType) {
    final path = game.getImagePath(
      _folderForGame(game),
      imageType,
      widget.fileProvider,
    );
    if (File(path).existsSync()) return path;
    return '';
  }

  Widget _buildGridHeader() {
    final dropdownState = GameViewModeDropdown.globalKey.currentState;
    final viewModeKey = GlobalKey();
    final shortName =
        (widget.system.shortName != null && widget.system.shortName!.isNotEmpty)
        ? widget.system.shortName!
        : widget.system.realName;
    return Container(
      padding: EdgeInsets.only(left: 8.r, right: 8.r, top: 8.r, bottom: 4.r),
      color: Scaffold.of(context).widget.backgroundColor,
      child: Row(
        children: [
          _buildIconButton(
            iconPath: 'assets/images/gamepad/Xbox_B_button.png',
            symbol: Symbols.arrow_back_rounded,
            color: Theme.of(context).colorScheme.error,
            foregroundColor: Theme.of(context).colorScheme.onError,
            onTap: widget.onBack,
          ),
          SizedBox(width: 6.r),
          _buildIconButton(
            key: viewModeKey,
            iconPath: 'assets/images/gamepad/Xbox_X_button.png',
            symbol: Symbols.view_carousel_rounded,
            color: Theme.of(context).colorScheme.tertiary,
            foregroundColor: Theme.of(context).colorScheme.onPrimary,
            onTap: () {
              SfxService().playNavSound();
              dropdownState?.showDropdownFrom(viewModeKey);
            },
          ),
          SizedBox(width: 6.r),
          _buildIconButton(
            iconPath: 'assets/images/gamepad/Left Stick Click.png',
            symbol: Symbols.casino_rounded,
            color: Theme.of(context).colorScheme.tertiary,
            foregroundColor: Theme.of(context).colorScheme.onPrimary,
            onTap: widget.onRandom,
          ),
          SizedBox(width: 6.r),
          _buildIconButton(
            iconPath: 'assets/images/gamepad/Xbox_View_button.png',
            symbol: Symbols.search_rounded,
            color: Theme.of(context).colorScheme.tertiary,
            foregroundColor: Theme.of(context).colorScheme.onPrimary,
            onTap: widget.onScrape,
          ),
          SizedBox(width: 6.r),
          _buildIconButton(
            iconPath: 'assets/images/gamepad/Xbox_Y_button.png',
            symbol: Symbols.favorite_rounded,
            color: Theme.of(context).colorScheme.tertiary,
            foregroundColor: Theme.of(context).colorScheme.onPrimary,
            onTap: widget.onFavorite,
          ),
          SizedBox(width: 10.r),
          Container(
            padding: EdgeInsets.symmetric(horizontal: 8.r, vertical: 4.r),
            decoration: BoxDecoration(
              color: Theme.of(
                context,
              ).colorScheme.primary.withValues(alpha: 0.2),
              borderRadius: BorderRadius.circular(12.r),
              border: Border.all(
                color: Theme.of(
                  context,
                ).colorScheme.primary.withValues(alpha: 0.4),
                width: 1.r,
              ),
            ),
            child: Text(
              shortName,
              style: TextStyle(
                fontSize: 12.r,
                fontWeight: FontWeight.w700,
                color: Theme.of(context).colorScheme.primary,
                letterSpacing: 0.5.r,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildIconButton({
    Key? key,
    required String iconPath,
    required IconData symbol,
    required Color color,
    Color? foregroundColor,
    required VoidCallback? onTap,
  }) {
    final fg = foregroundColor ?? Colors.white;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        key: key,
        onTap: onTap,
        borderRadius: BorderRadius.circular(6.r),
        child: Container(
          padding: EdgeInsets.symmetric(horizontal: 5.r, vertical: 4.r),
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.85),
            borderRadius: BorderRadius.circular(6.r),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.3),
                blurRadius: 2.r,
                offset: Offset(1.r, 1.r),
              ),
            ],
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Image.asset(
                iconPath,
                width: 16.r,
                height: 16.r,
                color: fg,
                colorBlendMode: BlendMode.srcIn,
              ),
              SizedBox(width: 4.r),
              Icon(symbol, size: 16.r, color: fg),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildFanartCard(GameModel game, bool isSelected) {
    final theme = Theme.of(context);
    final folder = _folderForGame(game);
    final screenshotPath = game.getScreenshotPath(folder, widget.fileProvider);
    final hasScreenshot = File(screenshotPath).existsSync();
    final fanartPath = game.getImagePath(
      folder,
      'fanarts',
      widget.fileProvider,
    );
    final hasFanart = File(fanartPath).existsSync();
    final bgPath = hasFanart
        ? fanartPath
        : (hasScreenshot ? screenshotPath : '');

    return Container(
      clipBehavior: Clip.antiAlias,
      margin: EdgeInsets.all(5.r),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(24.r),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.5),
            blurRadius: 8.r,
            offset: Offset(2.r, 2.r),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(24.r),
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (bgPath.isNotEmpty)
              Image.file(
                File(bgPath),
                key: ValueKey(bgPath),
                fit: BoxFit.cover,
                cacheWidth: 1024,
                errorBuilder: (ctx, e, s) => _buildFallbackCard(game, theme),
              )
            else
              _buildFallbackCard(game, theme),
            if (bgPath.isNotEmpty)
              Container(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      Colors.transparent,
                      Colors.transparent,
                      Colors.black.withValues(alpha: 0.6),
                      Colors.black.withValues(alpha: 0.9),
                    ],
                    stops: const [0.0, 0.4, 0.7, 1.0],
                  ),
                ),
              ),
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: _buildWheelOverlay(game),
            ),
            if (game.isFavorite == true)
              Positioned(
                top: 8.r,
                right: 8.r,
                child: Container(
                  width: 32.r,
                  height: 32.r,
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.45),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(
                    Symbols.favorite_rounded,
                    size: 18.r,
                    color: Colors.redAccent,
                  ),
                ),
              ),
            if (widget.scrapingGameRomnames.contains(game.romname))
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: _buildScrapeProgress(game),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildScrapeProgress(GameModel game) {
    final progress = widget.scrapeProgress[game.romname] ?? 0.0;
    return Container(
      height: 24.r,
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.7),
        borderRadius: BorderRadius.vertical(bottom: Radius.circular(24.r)),
      ),
      padding: EdgeInsets.symmetric(horizontal: 12.r),
      child: Row(
        children: [
          Icon(Symbols.search_rounded, size: 14.r, color: Colors.white70),
          SizedBox(width: 6.r),
          Expanded(
            child: LinearProgressIndicator(
              value: progress,
              backgroundColor: Colors.white24,
              valueColor: AlwaysStoppedAnimation<Color>(
                Theme.of(context).colorScheme.primary,
              ),
            ),
          ),
          SizedBox(width: 6.r),
          Text(
            '${(progress * 100).toInt()}%',
            style: TextStyle(
              color: Colors.white70,
              fontSize: 11.r,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFallbackCard(GameModel game, ThemeData theme) {
    return Container(
      color: theme.colorScheme.surfaceContainerHighest,
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Symbols.videogame_asset_rounded,
              size: 64.r,
              color: theme.colorScheme.onSurface.withValues(alpha: 0.3),
            ),
            SizedBox(height: 12.r),
            Padding(
              padding: EdgeInsets.symmetric(horizontal: 16.r),
              child: Text(
                game.name.isNotEmpty ? game.name : game.realname,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
                  fontSize: 14.r,
                  fontWeight: FontWeight.w600,
                ),
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildWheelOverlay(GameModel game) {
    final wheelPath = _resolveImagePath(game, 'wheels');
    if (wheelPath.isNotEmpty) {
      return Container(
        padding: EdgeInsets.fromLTRB(48.r, 4.r, 48.r, 8.r),
        child: Image.file(
          File(wheelPath),
          key: ValueKey(wheelPath),
          fit: BoxFit.contain,
          filterQuality: FilterQuality.medium,
          cacheWidth: 512,
          errorBuilder: (ctx, e, s) => const SizedBox.shrink(),
        ),
      );
    }
    return const SizedBox.shrink();
  }

  Widget _buildBoxCard(GameModel game, bool isSelected) {
    final theme = Theme.of(context);
    final boxPath = _resolveImagePath(game, 'box2d');
    final hasBox = boxPath.isNotEmpty;
    final ratio = _boxAspectRatio(game) ?? 1.0;

    if (!hasBox) {
      return Center(
        child: Stack(
          children: [
            _buildBoxFallback(game, theme),
            if (game.isFavorite == true)
              Positioned(
                top: 8.r,
                right: 8.r,
                child: Container(
                  width: 32.r,
                  height: 32.r,
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.45),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(
                    Symbols.favorite_rounded,
                    size: 18.r,
                    color: Colors.redAccent,
                  ),
                ),
              ),
            if (widget.scrapingGameRomnames.contains(game.romname))
              _buildScrapeProgress(game),
          ],
        ),
      );
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final maxW = constraints.maxWidth;
        final maxH = constraints.maxHeight;

        double cardW, cardH;
        if (maxW / ratio <= maxH) {
          cardW = maxW;
          cardH = maxW / ratio;
        } else {
          cardH = maxH;
          cardW = maxH * ratio;
        }

        return Center(
          child: Container(
            width: cardW,
            height: cardH,
            clipBehavior: Clip.antiAlias,
            margin: EdgeInsets.all(5.r),
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(8.r),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: isSelected ? 0.6 : 0.3),
                  blurRadius: isSelected ? 12.r : 6.r,
                  offset: Offset(2.r, 2.r),
                ),
              ],
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(8.r),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  Image.file(
                    File(boxPath),
                    key: ValueKey(boxPath),
                    fit: BoxFit.cover,
                    cacheWidth: 1024,
                    errorBuilder: (ctx, e, s) => _buildBoxFallback(game, theme),
                  ),
                  if (game.isFavorite == true)
                    Positioned(
                      top: 8.r,
                      right: 8.r,
                      child: Container(
                        width: 32.r,
                        height: 32.r,
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.45),
                          shape: BoxShape.circle,
                        ),
                        child: Icon(
                          Symbols.favorite_rounded,
                          size: 18.r,
                          color: Colors.redAccent,
                        ),
                      ),
                    ),
                  if (widget.scrapingGameRomnames.contains(game.romname))
                    Positioned(
                      left: 0,
                      right: 0,
                      bottom: 0,
                      child: _buildScrapeProgress(game),
                    ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildBoxFallback(GameModel game, ThemeData theme) {
    return _buildFallbackCard(game, theme);
  }

  @override
  Widget build(BuildContext context) {
    if (widget.games.isEmpty) {
      return Center(
        child: Text(
          'No games',
          style: TextStyle(color: Theme.of(context).colorScheme.onSurface),
        ),
      );
    }

    final config = context.watch<SqliteConfigProvider>().config;
    final isFanart = config.gameCarouselCardStyle != 'box';
    final theme = Theme.of(context);
    final currentGame =
        widget.games[_currentIndex.clamp(0, widget.games.length - 1)];
    final letters = _uniqueLetters;
    final currentLetter = _getLetterForGame(currentGame);

    final textStyle = TextStyle(
      color: theme.colorScheme.onSurface,
      fontSize: 11.r,
      fontWeight: FontWeight.normal,
    );
    final selectedTextStyle = textStyle.copyWith(
      color: theme.colorScheme.onPrimary,
      fontWeight: FontWeight.w800,
    );

    return Stack(
      children: [
        Column(
          children: [
            SizedBox(height: 36.r),
            Expanded(
              child: NativeCarousel(
                key: _carouselKey,
                itemCount: widget.games.length,
                initialIndex: _currentIndex.clamp(0, widget.games.length - 1),
                itemBuilder: (context, index) {
                  final game = widget.games[index];
                  return KeyedSubtree(
                    key: ValueKey(game.romname),
                    child: isFanart
                        ? _buildFanartCard(game, index == _currentIndex)
                        : _buildBoxCard(game, index == _currentIndex),
                  );
                },
                onPageChanged: _onPageChanged,
              ),
            ),
            SizedBox(
              height: 36.r,
              child: SingleChildScrollView(
                controller: _letterBarController,
                scrollDirection: Axis.horizontal,
                padding: EdgeInsets.symmetric(horizontal: 4.r, vertical: 2.r),
                child: Stack(
                  children: [
                    AnimatedPositioned(
                      duration: const Duration(milliseconds: 120),
                      curve: Curves.easeInOut,
                      left: _getLetterBarOffset(
                        currentLetter,
                        letters,
                        selectedTextStyle,
                      ),
                      top: 0,
                      bottom: 0,
                      width: _calculateLetterWidth(
                        currentLetter,
                        selectedTextStyle,
                      ),
                      child: Container(
                        decoration: BoxDecoration(
                          color: theme.colorScheme.secondary,
                          borderRadius: BorderRadius.circular(12.r),
                        ),
                      ),
                    ),
                    Row(
                      children: letters.map((letter) {
                        final isSelected = letter == currentLetter;
                        final w = _calculateLetterWidth(
                          letter,
                          selectedTextStyle,
                        );
                        return GestureDetector(
                          onTap: () {
                            SfxService().playNavSound();
                            final gi = _getFirstGameIndexForLetter(letter);
                            _carouselKey.currentState?.animateToPage(gi);
                          },
                          child: Container(
                            width: w,
                            height: 30.r,
                            margin: EdgeInsets.only(right: 6.r),
                            alignment: Alignment.center,
                            decoration: BoxDecoration(
                              color: theme.colorScheme.primary.withValues(
                                alpha: 0.1,
                              ),
                              borderRadius: BorderRadius.circular(12.r),
                            ),
                            child: Text(
                              letter,
                              textAlign: TextAlign.center,
                              maxLines: 1,
                              style: isSelected ? selectedTextStyle : textStyle,
                            ),
                          ),
                        );
                      }).toList(),
                    ),
                  ],
                ),
              ),
            ),
            GameViewFooter(game: currentGame, onPlay: widget.onPlay),
            SizedBox(height: 8.r),
          ],
        ),
        Positioned(top: 0, left: 0, right: 0, child: _buildGridHeader()),
      ],
    );
  }
}
