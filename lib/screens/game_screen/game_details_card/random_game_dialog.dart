import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:neostation/l10n/app_locale.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:neostation/services/sfx_service.dart';
import 'dart:async';
import 'dart:math';
import 'dart:io';
import '../../../constants/system_folder_names.dart';
import '../../../models/game_model.dart';
import '../../../providers/file_provider.dart';
import '../../../utils/game_utils.dart';
import '../../../themes/corner_radii.dart';
import '../../../utils/gamepad_nav.dart';
import '../../../widgets/core_footer.dart';
import '../../../widgets/neo_glass.dart';

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

    _initializeGamepad();
    _startRandomCycle();
  }

  /// Configures the gamepad layer for selection and re-roll protocols.
  void _initializeGamepad() {
    _gamepadNav = GamepadNavigation(
      onBack: _close,
      // Gamepad A: Execute launching sequence for the chosen title.
      onSelectItem: _playSelected,
      // Gamepad X: Restart the randomization process.
      onXButton: () {
        if (!_isAnimating && _showPlayButton) {
          _reroll();
        }
      },
    );
    _gamepadNav?.initialize();
    _gamepadNav?.activate();
  }

  void _playSelected() {
    final game = _selectedGame;
    if (_isAnimating || !_showPlayButton || game == null) return;
    SfxService().playEnterSound();
    Navigator.of(context).pop();
    widget.onPlayGame(game);
  }

  void _close() {
    SfxService().playBackSound();
    Navigator.of(context).pop();
  }

  /// Resets the randomization state and initiates a new visual cycle.
  void _reroll() {
    _cycleTimer?.cancel();
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

  /// Resolves the filesystem path for game artwork, supporting the aggregate
  /// views (All Systems, Favorites, a collection) where each game's art lives
  /// under its own system's folder, not the list's.
  String _getImagePath(GameModel game, String imageType) {
    final systemFolder =
        SystemFolderNames.isAggregate(widget.systemFolderName) &&
            game.systemFolderName != null
        ? game.systemFolderName!
        : widget.systemFolderName;
    return game.getImagePath(systemFolder, imageType, widget.fileProvider);
  }

  /// Resolves the background image, preferring the screenshot and falling back
  /// to fanart when the game has no screenshot on disk.
  File _resolveBackgroundFile(GameModel game) {
    final screenshotFile = File(_getImagePath(game, 'screenshots'));
    if (screenshotFile.existsSync()) return screenshotFile;
    return File(_getImagePath(game, 'fanarts'));
  }

  @override
  Widget build(BuildContext context) {
    if (widget.games.isEmpty) return _buildEmptyDialog();

    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final radii = theme.extension<CornerRadii>() ?? CornerRadii.m();
    final currentGame = widget.games[_currentIndex];

    return Dialog(
      backgroundColor: Colors.transparent,
      elevation: 0,
      insetPadding: EdgeInsets.all(16.r),
      child: FadeTransition(
        opacity: _fadeAnimation,
        child: NeoGlassRim(
          cornerRadius: radii.radiusExternalRadius,
          child: Container(
            constraints: const BoxConstraints(
              maxWidth: 480.0,
              maxHeight: 280.0,
            ),
            decoration: BoxDecoration(
              color: scheme.surface,
              borderRadius: radii.radiusExternal,
              border: Border.all(color: scheme.outline.withValues(alpha: 0.15)),
              boxShadow: [
                BoxShadow(
                  color: scheme.shadow.withValues(alpha: 0.5),
                  blurRadius: 18.r,
                  offset: Offset(0, 8.r),
                ),
              ],
            ),
            child: ClipRRect(
              borderRadius: radii.radiusExternal,
              child: Column(
                children: [
                  _buildHeader(theme),
                  Expanded(child: _buildBody(theme, currentGame)),
                  _buildFooter(theme),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// NeoGlass-style header with the live selection state.
  Widget _buildHeader(ThemeData theme) {
    final scheme = theme.colorScheme;
    return Container(
      padding: EdgeInsets.fromLTRB(12.r, 8.r, 12.r, 8.r),
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(color: scheme.outline.withValues(alpha: 0.12)),
        ),
      ),
      child: Row(
        children: [
          Container(
            width: 26.r,
            height: 26.r,
            decoration: BoxDecoration(
              color: scheme.primary.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(8.r),
            ),
            child: Icon(
              _isAnimating ? Symbols.casino_rounded : Symbols.stars_rounded,
              size: 15.r,
              color: scheme.primary,
            ),
          ),
          SizedBox(width: 8.r),
          Expanded(
            child: Text(
              AppLocale.randomGame.getString(context),
              style: TextStyle(
                fontSize: 12.r,
                fontWeight: FontWeight.w700,
                color: scheme.onSurface,
              ),
            ),
          ),
          if (_isAnimating)
            SizedBox(
              width: 16.r,
              height: 16.r,
              child: CircularProgressIndicator(
                strokeWidth: 2.r,
                color: scheme.primary,
              ),
            ),
        ],
      ),
    );
  }

  /// Hero area: the game screenshot on the left, fading into a NeoGlass card
  /// with the wheel, title, system and metadata on the right.
  Widget _buildBody(ThemeData theme, GameModel currentGame) {
    final screenshotFile = _resolveBackgroundFile(currentGame);
    return Stack(
      fit: StackFit.expand,
      children: [
        AnimatedSwitcher(
          duration: const Duration(milliseconds: 60),
          child: _buildScreenshotGradient(theme, screenshotFile, currentGame),
        ),
        Align(
          alignment: Alignment.centerRight,
          child: Padding(
            padding: EdgeInsets.all(10.r),
            child: SizedBox(
              width: 230.0,
              child: _buildGameInfo(theme, currentGame),
            ),
          ),
        ),
      ],
    );
  }

  /// Fades the screenshot into the dialog surface so the info panel stays
  /// readable without hiding the artwork completely.
  Widget _buildScreenshotGradient(ThemeData theme, File file, GameModel game) {
    final scheme = theme.colorScheme;
    final imageWidget = file.existsSync()
        ? Image.file(
            file,
            key: ValueKey(game.romname),
            fit: BoxFit.cover,
            width: double.infinity,
            height: double.infinity,
            errorBuilder: (context, e, s) => _screenshotFallback(theme),
          )
        : _screenshotFallback(theme);

    return Stack(
      fit: StackFit.expand,
      children: [
        imageWidget,
        DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.centerLeft,
              end: Alignment.centerRight,
              stops: const [0.0, 0.42, 0.72, 1.0],
              colors: [
                scheme.surface.withValues(alpha: 0.08),
                scheme.surface.withValues(alpha: 0.32),
                scheme.surface.withValues(alpha: 0.86),
                scheme.surface,
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _screenshotFallback(ThemeData theme) {
    final scheme = theme.colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [scheme.primary.withValues(alpha: 0.16), scheme.surface],
        ),
      ),
      child: Center(
        child: Icon(
          Symbols.casino_rounded,
          color: scheme.primary.withValues(alpha: 0.25),
          size: 64.r,
        ),
      ),
    );
  }

  String _systemName(GameModel game) {
    if (SystemFolderNames.isAggregate(widget.systemFolderName)) {
      return game.systemRealName ?? game.systemFolderName ?? '';
    }
    return widget.systemRealName ?? widget.systemFolderName;
  }

  /// Shows only the year and month when [value] carries a full date.
  String _yearMonth(String value) {
    final raw = value.trim();
    if (raw.isEmpty) return raw;
    final separated = RegExp(r'^(\d{4})[-/.](\d{1,2})').firstMatch(raw);
    if (separated != null) {
      return '${separated.group(1)}-${separated.group(2)!.padLeft(2, '0')}';
    }
    final date = DateTime.tryParse(raw);
    if (date != null) {
      return '${date.year}-${date.month.toString().padLeft(2, '0')}';
    }
    return raw;
  }

  /// Wheel, title, system badge and metadata inside a rounded NeoGlass panel.
  Widget _buildGameInfo(ThemeData theme, GameModel game) {
    final scheme = theme.colorScheme;
    final radii = theme.extension<CornerRadii>() ?? CornerRadii.m();
    final wheelFile = File(_getImagePath(game, 'wheels'));
    final systemName = _systemName(game);
    final metadata = [
      _yearMonth(game.year),
      game.genre,
    ].where((value) => value.trim().isNotEmpty).join('  ·  ');

    return NeoGlassRim(
      cornerRadius: radii.radiusInternalRadius,
      child: Container(
        padding: EdgeInsets.all(10.r),
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHighest.withValues(alpha: 0.16),
          borderRadius: radii.radiusInternal,
        ),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              if (wheelFile.existsSync())
                Image.file(
                  wheelFile,
                  height: 42.r,
                  fit: BoxFit.contain,
                  errorBuilder: (context, e, s) => Icon(
                    Symbols.videogame_asset_rounded,
                    size: 26.r,
                    color: scheme.onSurface.withValues(alpha: 0.4),
                  ),
                )
              else
                Icon(
                  Symbols.videogame_asset_rounded,
                  size: 26.r,
                  color: scheme.onSurface.withValues(alpha: 0.3),
                ),
              SizedBox(height: 7.r),
              AnimatedSwitcher(
                duration: const Duration(milliseconds: 55),
                child: Text(
                  key: ValueKey(game.romname),
                  GameUtils.formatGameName(game.name),
                  style: TextStyle(
                    fontSize: _isAnimating ? 11.r : 14.r,
                    fontWeight: FontWeight.w700,
                    color: _isAnimating
                        ? scheme.onSurface.withValues(alpha: 0.75)
                        : scheme.onSurface,
                    height: 1.15,
                  ),
                  textAlign: TextAlign.center,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (systemName.isNotEmpty) ...[
                SizedBox(height: 4.r),
                Container(
                  padding: EdgeInsets.symmetric(horizontal: 8.r, vertical: 3.r),
                  decoration: BoxDecoration(
                    color: scheme.primary.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(999.r),
                    border: Border.all(
                      color: scheme.primary.withValues(alpha: 0.2),
                    ),
                  ),
                  child: Text(
                    systemName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 9.r,
                      fontWeight: FontWeight.w700,
                      color: scheme.primary,
                    ),
                  ),
                ),
              ],
              if (metadata.isNotEmpty) ...[
                SizedBox(height: 3.r),
                Text(
                  metadata,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 9.r,
                    color: scheme.onSurface.withValues(alpha: 0.55),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  /// NeoGlass-style action row: Play, Re-roll (once revealed), Back.
  Widget _buildFooter(ThemeData theme) {
    final scheme = theme.colorScheme;
    final canPlay = !_isAnimating && _showPlayButton && _selectedGame != null;
    return Container(
      padding: EdgeInsets.symmetric(horizontal: 10.r, vertical: 6.r),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.05),
        border: Border(
          top: BorderSide(color: scheme.outline.withValues(alpha: 0.12)),
        ),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Flexible(
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: GamepadControl(
                iconPath: 'assets/images/gamepad/Xbox_A_button.png',
                label: AppLocale.playButton.getString(context),
                onTap: canPlay ? _playSelected : null,
                busy: _isAnimating,
                backgroundColor: scheme.primary,
                textColor: scheme.onPrimary,
              ),
            ),
          ),
          if (!_isAnimating) ...[
            SizedBox(width: 6.r),
            Flexible(
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: GamepadControl(
                  iconPath: 'assets/images/gamepad/Xbox_X_button.png',
                  label: AppLocale.random.getString(context),
                  onTap: _reroll,
                  backgroundColor: scheme.tertiaryFixed,
                  textColor: scheme.onTertiaryFixed,
                ),
              ),
            ),
          ],
          SizedBox(width: 6.r),
          Flexible(
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: GamepadControl(
                iconPath: 'assets/images/gamepad/Xbox_B_button.png',
                label: AppLocale.back.getString(context),
                onTap: _close,
                backgroundColor: scheme.tertiary,
                textColor: scheme.onTertiary,
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Empty state in the same NeoGlass card language.
  Widget _buildEmptyDialog() {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final radii = theme.extension<CornerRadii>() ?? CornerRadii.m();
    return Dialog(
      backgroundColor: Colors.transparent,
      elevation: 0,
      insetPadding: EdgeInsets.all(16.r),
      child: NeoGlassRim(
        cornerRadius: radii.radiusExternalRadius,
        child: Container(
          constraints: const BoxConstraints(maxWidth: 480.0),
          decoration: BoxDecoration(
            color: scheme.surface,
            borderRadius: radii.radiusExternal,
            border: Border.all(color: scheme.outline.withValues(alpha: 0.15)),
            boxShadow: [
              BoxShadow(
                color: scheme.shadow.withValues(alpha: 0.5),
                blurRadius: 18.r,
                offset: Offset(0, 8.r),
              ),
            ],
          ),
          child: ClipRRect(
            borderRadius: radii.radiusExternal,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: double.infinity,
                  padding: EdgeInsets.all(16.r),
                  decoration: BoxDecoration(
                    border: Border(
                      bottom: BorderSide(
                        color: scheme.outline.withValues(alpha: 0.12),
                      ),
                    ),
                  ),
                  child: Column(
                    children: [
                      Icon(
                        Symbols.casino_rounded,
                        color: scheme.primary,
                        size: 34.r,
                      ),
                      SizedBox(height: 8.r),
                      Text(
                        AppLocale.noGamesAvailable.getString(context),
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 13.r,
                          fontWeight: FontWeight.w700,
                          color: scheme.onSurface,
                        ),
                      ),
                    ],
                  ),
                ),
                Padding(
                  padding: EdgeInsets.all(12.r),
                  child: GamepadControl(
                    iconPath: 'assets/images/gamepad/Xbox_B_button.png',
                    label: AppLocale.close.getString(context),
                    onTap: _close,
                    backgroundColor: scheme.tertiary,
                    textColor: scheme.onTertiary,
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
