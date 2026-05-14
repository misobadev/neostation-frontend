import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:neostation/l10n/app_locale.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:neostation/services/sfx_service.dart';
import 'dart:async';
import 'dart:math';
import 'dart:io';
import '../../../models/game_model.dart';
import '../../../providers/file_provider.dart';
import '../../../utils/game_utils.dart';
import '../../../utils/gamepad_nav.dart';

/// A modal dialog that facilitates random game selection with a slot-machine style animation.
///
/// Features tactile SFX feedback and gamepad-friendly navigation for 'Re-roll'
/// and 'Play' actions, providing an engaging discovery experience for large libraries.
class RandomGameDialog extends StatefulWidget {
  final List<GameModel> games;
  final String systemFolderName;
  final String? systemRealName;
  final FileProvider fileProvider;
  final Function(GameModel) onPlayGame;

  const RandomGameDialog({
    super.key,
    required this.games,
    required this.systemFolderName,
    this.systemRealName,
    required this.fileProvider,
    required this.onPlayGame,
  });

  @override
  State<RandomGameDialog> createState() => _RandomGameDialogState();
}

class _RandomGameDialogState extends State<RandomGameDialog>
    with TickerProviderStateMixin {
  Timer? _cycleTimer;
  int _currentIndex = 0;
  GameModel? _selectedGame;
  int? _finalSelectedIndex;
  bool _isAnimating = true;
  bool _showPlayButton = false;

  late AnimationController _fadeController;
  late Animation<double> _fadeAnimation;

  late AnimationController _revealController;
  late Animation<double> _revealScale;
  late Animation<double> _revealOpacity;

  // Slot-machine configuration: handles timing and rhythmic SFX ticks.
  int _cycleCount = 0;
  static const int _totalCycles = 18;
  static const int _baseDurationMs = 80;
  int _sfxTickCount = 0;

  final Random _random = Random();
  GamepadNavigation? _gamepadNav;

  @override
  void initState() {
    super.initState();

    _fadeController = AnimationController(
      duration: const Duration(milliseconds: 180),
      vsync: this,
    );
    _fadeAnimation = CurvedAnimation(
      parent: _fadeController,
      curve: Curves.easeOut,
    );
    _fadeController.forward();

    _revealController = AnimationController(
      duration: const Duration(milliseconds: 320),
      vsync: this,
    );
    _revealScale = Tween<double>(begin: 0.88, end: 1.0).animate(
      CurvedAnimation(parent: _revealController, curve: Curves.easeOutBack),
    );
    _revealOpacity = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(parent: _revealController, curve: Curves.easeOut),
    );

    _initializeGamepad();
    _startRandomCycle();
  }

  /// Configures the gamepad layer for selection and re-roll protocols.
  void _initializeGamepad() {
    _gamepadNav = GamepadNavigation(
      onBack: () => Navigator.of(context).pop(),
      // Gamepad A: Execute launching sequence for the chosen title.
      onSelectItem: () {
        if (!_isAnimating && _showPlayButton && _selectedGame != null) {
          SfxService().playEnterSound();
          Navigator.of(context).pop();
          widget.onPlayGame(_selectedGame!);
        }
      },
      // Gamepad SELECT (View): Restart the randomization process.
      onSelectButton: () {
        if (!_isAnimating && _showPlayButton) {
          _reroll();
        }
      },
    );
    _gamepadNav?.initialize();
    _gamepadNav?.activate();
  }

  /// Resets the randomization state and initiates a new visual cycle.
  void _reroll() {
    _cycleTimer?.cancel();
    _revealController.reset();
    setState(() {
      _cycleCount = 0;
      _sfxTickCount = 0;
      _isAnimating = true;
      _showPlayButton = false;
    });
    _startRandomCycle();
  }

  @override
  void dispose() {
    _cycleTimer?.cancel();
    _fadeController.dispose();
    _revealController.dispose();
    _gamepadNav?.dispose();
    super.dispose();
  }

  /// Manages the visual 'shuffling' logic, progressively slowing down until the target is reached.
  void _startRandomCycle() {
    if (widget.games.isEmpty) {
      setState(() {
        _isAnimating = false;
        _showPlayButton = true;
      });
      return;
    }

    _finalSelectedIndex = _random.nextInt(widget.games.length);
    _selectedGame = widget.games[_finalSelectedIndex!];
    _currentIndex = _random.nextInt(widget.games.length);

    _cycleTimer = Timer.periodic(const Duration(milliseconds: _baseDurationMs), (
      timer,
    ) {
      if (_cycleCount >= _totalCycles) {
        timer.cancel();
        setState(() {
          _currentIndex = _finalSelectedIndex!;
          _isAnimating = false;
          _showPlayButton = true;
        });
        SfxService().playEnterSound();
        _revealController.forward();
        return;
      }

      // Throttled SFX: play navigation sound every 2 ticks to maintain acoustic clarity.
      _sfxTickCount++;
      if (_sfxTickCount % 2 == 0) {
        SfxService().playNavSound();
      }

      setState(() {
        if (_cycleCount >= _totalCycles - 4) {
          // Slow-motion convergence: target-oriented selection in the final frames.
          final dist = (_finalSelectedIndex! - _currentIndex).abs();
          if (dist > 1) {
            _currentIndex = _finalSelectedIndex! > _currentIndex
                ? (_currentIndex + 1) % widget.games.length
                : (_currentIndex - 1 + widget.games.length) %
                      widget.games.length;
          } else {
            _currentIndex = _finalSelectedIndex!;
          }
        } else {
          // Rapid randomization: broad selection across the full library.
          _currentIndex = _random.nextInt(widget.games.length);
        }
        _cycleCount++;
      });
    });
  }

  /// Resolves the filesystem path for game artwork, supporting 'All Systems' global views.
  String _getImagePath(GameModel game, String imageType) {
    final systemFolder =
        widget.systemFolderName == 'all' && game.systemFolderName != null
        ? game.systemFolderName!
        : widget.systemFolderName;
    return game.getImagePath(systemFolder, imageType, widget.fileProvider);
  }

  @override
  Widget build(BuildContext context) {
    if (widget.games.isEmpty) return _buildEmptyDialog();

    final theme = Theme.of(context);
    final currentGame = widget.games[_currentIndex];

    return Dialog(
      backgroundColor: Colors.transparent,
      elevation: 0,
      insetPadding: EdgeInsets.symmetric(horizontal: 40.r, vertical: 30.r),
      child: FadeTransition(
        opacity: _fadeAnimation,
        child: Container(
          constraints: BoxConstraints(maxWidth: 320.r, maxHeight: 180.r),
          decoration: BoxDecoration(
            color: theme.colorScheme.surface,
            borderRadius: BorderRadius.circular(10.r),
            border: Border.all(
              color: _isAnimating
                  ? theme.colorScheme.primary.withValues(alpha: 0.35)
                  : theme.colorScheme.secondary.withValues(alpha: 0.4),
              width: 1.r,
            ),
            boxShadow: [
              BoxShadow(
                color:
                    (_isAnimating
                            ? theme.colorScheme.primary
                            : theme.colorScheme.secondary)
                        .withValues(alpha: 0.12),
                blurRadius: 18.r,
                spreadRadius: 1.r,
              ),
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.3),
                blurRadius: 8.r,
                offset: Offset(0, 3.r),
              ),
            ],
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(10.r),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _buildHeader(theme),
                Expanded(child: _buildBody(theme, currentGame)),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// Renders the top status bar with dynamic icons based on animation state.
  Widget _buildHeader(ThemeData theme) {
    return Container(
      padding: EdgeInsets.symmetric(horizontal: 10.r, vertical: 5.r),
      decoration: BoxDecoration(
        color: _isAnimating
            ? theme.colorScheme.primary.withValues(alpha: 0.08)
            : theme.colorScheme.secondary.withValues(alpha: 0.08),
        border: Border(
          bottom: BorderSide(
            color: _isAnimating
                ? theme.colorScheme.primary.withValues(alpha: 0.12)
                : theme.colorScheme.secondary.withValues(alpha: 0.12),
            width: 1.r,
          ),
        ),
      ),
      child: Row(
        children: [
          Icon(
            _isAnimating ? Symbols.casino_rounded : Symbols.stars_rounded,
            size: 13.r,
            color: _isAnimating
                ? theme.colorScheme.primary
                : theme.colorScheme.secondary,
          ),
          SizedBox(width: 5.r),
          Text(
            _isAnimating
                ? AppLocale.randomGame.getString(context)
                : AppLocale.selected.getString(context),
            style: TextStyle(
              fontSize: 11.r,
              fontWeight: FontWeight.w700,
              color: theme.colorScheme.onSurface.withValues(alpha: 0.85),
              letterSpacing: 0.5,
            ),
          ),
          const Spacer(),
          // Prompt for 'Re-roll' action.
          if (!_isAnimating) ...[
            GestureDetector(
              onTap: _reroll,
              child: Container(
                padding: EdgeInsets.symmetric(horizontal: 8.r, vertical: 6.r),
                decoration: BoxDecoration(
                  color: theme.colorScheme.surface,
                  borderRadius: BorderRadius.circular(6.r),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.25),
                      blurRadius: 2.r,
                      offset: Offset(2.r, 2.r),
                    ),
                  ],
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    ColorFiltered(
                      colorFilter: ColorFilter.mode(
                        theme.colorScheme.tertiary,
                        BlendMode.srcIn,
                      ),
                      child: Image.asset(
                        'assets/images/gamepad/Xbox_View_button.png',
                        width: 14.r,
                        height: 14.r,
                        errorBuilder: (context, e, s) => Icon(
                          Symbols.casino_rounded,
                          size: 14.r,
                          color: theme.colorScheme.tertiary,
                        ),
                      ),
                    ),
                    SizedBox(width: 2.r),
                    Text(
                      AppLocale.random.getString(context).toUpperCase(),
                      style: TextStyle(
                        fontSize: 10.r,
                        fontWeight: FontWeight.bold,
                        letterSpacing: 0.8,
                        color: theme.colorScheme.tertiary,
                      ),
                    ),
                    SizedBox(width: 2.r),
                  ],
                ),
              ),
            ),
            SizedBox(width: 6.r),
          ],
          // Prompt for 'Back' action (Dismissal).
          GestureDetector(
            onTap: () {
              SfxService().playBackSound();
              Navigator.of(context).pop();
            },
            child: Container(
              padding: EdgeInsets.symmetric(horizontal: 8.r, vertical: 6.r),
              decoration: BoxDecoration(
                color: theme.colorScheme.error,
                borderRadius: BorderRadius.circular(6.r),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.25),
                    blurRadius: 2.r,
                    offset: Offset(2.r, 2.r),
                  ),
                ],
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  ColorFiltered(
                    colorFilter: ColorFilter.mode(
                      theme.colorScheme.onError,
                      BlendMode.srcIn,
                    ),
                    child: Image.asset(
                      'assets/images/gamepad/Xbox_B_button.png',
                      width: 14.r,
                      height: 14.r,
                      errorBuilder: (context, e, s) =>
                          Icon(Symbols.close_rounded, size: 14.r, color: Colors.white),
                    ),
                  ),
                  SizedBox(width: 2.r),
                  Text(
                    AppLocale.back.getString(context).toUpperCase(),
                    style: TextStyle(
                      fontSize: 10.r,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 0.8,
                      color: theme.colorScheme.onError,
                    ),
                  ),
                  SizedBox(width: 2.r),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Core UI layout: Features a gradient-masked screenshot background and meta-info overlay.
  Widget _buildBody(ThemeData theme, GameModel currentGame) {
    final screenshotPath = _getImagePath(currentGame, 'screenshots');
    final screenshotFile = File(screenshotPath);

    return Stack(
      fit: StackFit.expand,
      children: [
        // Background layer: Dynamic screenshot with horizontal opacity mask.
        AnimatedSwitcher(
          duration: const Duration(milliseconds: 60),
          child: _buildScreenshotGradient(theme, screenshotFile, currentGame),
        ),
        // Foreground layer: Metadata and launch controls.
        Align(
          alignment: Alignment.centerRight,
          child: SizedBox(
            width: 180.r,
            child: Padding(
              padding: EdgeInsets.symmetric(horizontal: 8.r, vertical: 8.r),
              child: _buildGameInfo(theme, currentGame),
            ),
          ),
        ),
      ],
    );
  }

  /// Applies a complex linear gradient mask to the background screenshot for high-contrast text overlay.
  Widget _buildScreenshotGradient(ThemeData theme, File file, GameModel game) {
    Widget imageWidget = file.existsSync()
        ? Image.file(
            file,
            key: ValueKey(game.romname),
            fit: BoxFit.cover,
            width: double.infinity,
            height: double.infinity,
            errorBuilder: (context, e, s) => _screenshotFallback(theme),
          )
        : SizedBox(key: ValueKey(game.romname));

    return ShaderMask(
      shaderCallback: (bounds) => LinearGradient(
        begin: Alignment.centerLeft,
        end: Alignment.centerRight,
        stops: const [0.0, 0.45, 0.75, 1.0],
        colors: [
          Colors.white,
          Colors.white.withValues(alpha: 0.15),
          Colors.white.withValues(alpha: 0.35),
          Colors.transparent,
        ],
      ).createShader(bounds),
      blendMode: BlendMode.dstIn,
      child: imageWidget,
    );
  }

  Widget _screenshotFallback(ThemeData theme) {
    return Center(
      child: Icon(
        Symbols.image_not_supported_rounded,
        color: theme.colorScheme.onSurface.withValues(alpha: 0.2),
        size: 28.r,
      ),
    );
  }

  /// Renders game identifiers (Wheel logo, name, system) and the primary 'Play' CTA.
  Widget _buildGameInfo(ThemeData theme, GameModel game) {
    final wheelPath = _getImagePath(game, 'wheels');
    final wheelFile = File(wheelPath);

    String systemName;
    if (widget.systemFolderName == 'all') {
      systemName = game.systemRealName ?? game.systemFolderName ?? '';
    } else {
      systemName = widget.systemRealName ?? widget.systemFolderName;
    }

    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        // Visual branding: Wheels logo or generic controller icon.
        if (wheelFile.existsSync())
          Image.file(
            wheelFile,
            height: 36.r,
            fit: BoxFit.contain,
            errorBuilder: (context, e, s) => Icon(
              Symbols.videogame_asset_rounded,
              size: 28.r,
              color: theme.colorScheme.onSurface.withValues(alpha: 0.4),
            ),
          )
        else
          Icon(
            Symbols.videogame_asset_rounded,
            size: 28.r,
            color: theme.colorScheme.onSurface.withValues(alpha: 0.35),
          ),

        SizedBox(height: 6.r),

        // Primary title display with animation-state font sizing.
        AnimatedSwitcher(
          duration: const Duration(milliseconds: 55),
          child: Text(
            key: ValueKey(game.romname),
            GameUtils.formatGameName(game.name),
            style: TextStyle(
              fontSize: _isAnimating ? 11.r : 13.r,
              fontWeight: FontWeight.w700,
              color: _isAnimating
                  ? theme.colorScheme.onSurface.withValues(alpha: 0.75)
                  : theme.colorScheme.onSurface,
              letterSpacing: 0.2,
            ),
            textAlign: TextAlign.center,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
        ),

        SizedBox(height: 3.r),

        // System identifier badge.
        if (systemName.isNotEmpty)
          Container(
            padding: EdgeInsets.symmetric(horizontal: 6.r, vertical: 2.r),
            decoration: BoxDecoration(
              color: theme.colorScheme.primary,
              borderRadius: BorderRadius.circular(4.r),
            ),
            child: Text(
              systemName,
              style: TextStyle(
                fontSize: 8.r,
                fontWeight: FontWeight.w600,
                color: theme.colorScheme.onPrimary.withValues(alpha: 0.8),
                letterSpacing: 0.3,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),

        SizedBox(height: 10.r),

        // Post-selection call to action (Play button).
        if (_showPlayButton)
          ScaleTransition(
            scale: _revealScale,
            child: FadeTransition(
              opacity: _revealOpacity,
              child: GestureDetector(
                onTap: _selectedGame != null
                    ? () {
                        SfxService().playEnterSound();
                        Navigator.of(context).pop();
                        widget.onPlayGame(_selectedGame!);
                      }
                    : null,
                child: Container(
                  padding: EdgeInsets.symmetric(
                    horizontal: 20.r,
                    vertical: 8.r,
                  ),
                  decoration: BoxDecoration(
                    gradient: const LinearGradient(
                      colors: [Color(0xFF2ECC71), Color(0xFF1E8449)],
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                    ),
                    borderRadius: BorderRadius.circular(7.r),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.25),
                        blurRadius: 2.r,
                        offset: Offset(2.r, 2.r),
                      ),
                    ],
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Image.asset(
                        'assets/images/gamepad/Xbox_A_button.png',
                        width: 14.r,
                        height: 14.r,
                        color: Colors.white,
                        errorBuilder: (context, e, s) => Icon(
                          Symbols.play_arrow_rounded,
                          size: 14.r,
                          color: Colors.white,
                        ),
                      ),
                      SizedBox(width: 6.r),
                      Text(
                        AppLocale.playButton.getString(context),
                        style: TextStyle(
                          fontSize: 11.r,
                          fontWeight: FontWeight.w900,
                          letterSpacing: 1.5,
                          color: Colors.white,
                          shadows: [
                            Shadow(
                              color: Colors.black.withValues(alpha: 0.3),
                              offset: const Offset(0, 1),
                              blurRadius: 2,
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          )
        else
          // Shuffling indicator.
          SizedBox(
            width: 16.r,
            height: 16.r,
            child: CircularProgressIndicator(
              strokeWidth: 1.5.r,
              color: theme.colorScheme.primary.withValues(alpha: 0.5),
            ),
          ),
      ],
    );
  }

  /// Placeholder for empty list scenarios.
  Widget _buildEmptyDialog() {
    final theme = Theme.of(context);
    return Dialog(
      backgroundColor: Colors.transparent,
      elevation: 0,
      child: Container(
        width: 260.r,
        padding: EdgeInsets.all(16.r),
        decoration: BoxDecoration(
          color: theme.colorScheme.surface,
          borderRadius: BorderRadius.circular(10.r),
          border: Border.all(
            color: theme.colorScheme.error.withValues(alpha: 0.25),
            width: 1.r,
          ),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Symbols.casino_rounded,
              color: theme.colorScheme.onSurface.withValues(alpha: 0.3),
              size: 28.r,
            ),
            SizedBox(height: 8.r),
            Text(
              AppLocale.noGamesAvailable.getString(context),
              style: TextStyle(
                fontSize: 12.r,
                fontWeight: FontWeight.w700,
                color: theme.colorScheme.onSurface,
              ),
            ),
            SizedBox(height: 12.r),
            SizedBox(
              width: double.infinity,
              height: 24.r,
              child: FilledButton(
                onPressed: () => Navigator.of(context).pop(),
                style: FilledButton.styleFrom(
                  backgroundColor: theme.colorScheme.surfaceContainerHighest,
                  foregroundColor: theme.colorScheme.onSurface,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(6.r),
                  ),
                  padding: EdgeInsets.zero,
                ),
                child: Text(
                  AppLocale.close.getString(context),
                  style: TextStyle(fontSize: 11.r),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
