import 'package:flutter/material.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:neostation/l10n/app_locale.dart';
import 'package:neostation/models/game_model.dart';
import 'package:neostation/models/retro_achievements_game_info.dart';
import 'package:neostation/models/system_model.dart';
import 'package:neostation/providers/retro_achievements_provider.dart';
import 'package:neostation/repositories/retro_achievements_repository.dart';
import 'package:neostation/services/retro_achievements_helper.dart';
import 'package:neostation/services/sfx_service.dart';
import 'package:neostation/services/gamepad/gamepad_navigation_manager.dart';
import 'package:neostation/themes/corner_radii.dart';
import 'package:neostation/utils/gamepad_nav.dart';

import '../tabs/game_details_achievements_tab.dart';
import '../widgets/header_action_button.dart';
import 'ra_match_picker_dialog.dart';

/// A full-screen dialog that displays RetroAchievements progress for a single game.
///
/// Loads its own metadata, supports pull-to-refresh style updates via the
/// embedded achievements tab, and closes on touch back-button or gamepad B.
///
/// The embedded panel is driven by the D-pad the moment its set has loaded: the
/// dialog holds nothing else, so it hands the panel the D-pad rather than
/// waiting for the A gate the details card needs.
class GameAchievementsDialog extends StatefulWidget {
  final GameModel game;
  final SystemModel system;
  final RetroAchievementsProvider retroAchievementsProvider;

  const GameAchievementsDialog({
    super.key,
    required this.game,
    required this.system,
    required this.retroAchievementsProvider,
  });

  @override
  State<GameAchievementsDialog> createState() => _GameAchievementsDialogState();
}

class _GameAchievementsDialogState extends State<GameAchievementsDialog> {
  GameInfoAndUserProgress? _gameInfo;
  bool _isLoading = false;
  GamepadNavigation? _gamepadNav;
  bool _isManualMatch = false;

  /// The achievements panel this dialog wraps, so the D-pad can drive it.
  ///
  /// The panel owns its own cursor and exposes it through its state; without
  /// this key the dialog had no way to reach it, which is why A and the D-pad
  /// did nothing in here while touch walked the badges fine.
  final GlobalKey<GameDetailsAchievementsTabState> _tabKey =
      GlobalKey<GameDetailsAchievementsTabState>();

  @override
  void initState() {
    super.initState();
    _initializeGamepad();
    _loadAchievements();
    _loadMatchSource();
  }

  /// Whether the shown match was chosen by hand, which decides if the picker
  /// offers a way back to automatic matching.
  Future<void> _loadMatchSource() async {
    final romPath = widget.game.romPath;
    if (romPath == null || romPath.isEmpty) return;
    final source = await RetroAchievementsRepository.getRomRaMatchSource(
      romPath,
    );
    if (!mounted) return;
    setState(() {
      _isManualMatch = source == RetroAchievementsRepository.raMatchManual;
    });
  }

  /// Opens the manual match picker, and reloads the achievements when the user
  /// picked a different game so the dialog reflects the new set immediately.
  Future<void> _openMatchPicker() async {
    SfxService().playNavSound();
    final changed = await RaMatchPickerDialog.show(
      context,
      game: widget.game,
      system: widget.system,
      currentGameId: _gameInfo?.id,
      isManualMatch: _isManualMatch,
    );
    if (!changed || !mounted) return;

    // The match moved, so anything cached for the old game id is now wrong.
    RetroAchievementsHelper.evictBadgeCache(_gameInfo);
    widget.retroAchievementsProvider.gameInfoCache.clear();
    await _loadMatchSource();
    if (mounted) await _loadAchievements(forceRefresh: true);
  }

  @override
  void dispose() {
    GamepadNavigationManager.popLayer('game_achievements_dialog');
    _gamepadNav?.dispose();
    super.dispose();
  }

  void _initializeGamepad() {
    _gamepadNav = GamepadNavigation(
      onNavigateUp: () => _tabKey.currentState?.moveUp(),
      onNavigateDown: () => _tabKey.currentState?.moveDown(),
      onNavigateLeft: () => _tabKey.currentState?.moveLeft(),
      onNavigateRight: () => _tabKey.currentState?.moveRight(),
      onSelectItem: _activatePanel,
      // B leaves the dialog outright rather than stepping out of the panel
      // first: the panel is the whole dialog, so an inactive panel here is a
      // dead end and the header chip promises B is the way back.
      onBack: () {
        if (mounted) Navigator.of(context).pop();
      },
    );
    _gamepadNav?.initialize();
    GamepadNavigationManager.pushLayer(
      'game_achievements_dialog',
      onActivate: () => _gamepadNav?.activate(),
      onDeactivate: () => _gamepadNav?.deactivate(),
    );
  }

  /// Gamepad A: takes the D-pad if the panel is not holding it yet, otherwise
  /// runs whichever header action (REFRESH / FIX MATCH) has the cursor.
  void _activatePanel() {
    final state = _tabKey.currentState;
    if (state == null) return;
    if (state.isPanelActive) {
      state.activateFocused();
      return;
    }
    if (state.enterPanel()) SfxService().playNavSound();
  }

  /// Hands the D-pad to the panel once its content has settled.
  ///
  /// This dialog is nothing but the panel, so making the user press A first
  /// would only add a step. It runs after the frame because loading a set
  /// changes the panel's game id, and that reset drops the panel's D-pad claim.
  /// A stays the gate for the case where the panel refuses (no badges and no
  /// header action to land on).
  void _enterPanelWhenReady() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _tabKey.currentState?.enterPanel();
    });
  }

  Future<void> _loadAchievements({bool forceRefresh = false}) async {
    if (!mounted) return;
    setState(() => _isLoading = true);

    try {
      final info = await RetroAchievementsHelper.loadGameInfo(
        game: widget.game,
        provider: widget.retroAchievementsProvider,
        effectiveSystem: widget.system,
        isAllMode: false,
        forceRefresh: forceRefresh,
      );

      if (forceRefresh && info != null) {
        RetroAchievementsHelper.evictBadgeCache(_gameInfo);
      }

      if (mounted) {
        setState(() {
          _gameInfo = info;
          _isLoading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _gameInfo = null;
          _isLoading = false;
        });
      }
    }

    if (mounted) _enterPanelWhenReady();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final size = MediaQuery.of(context).size;
    final radii = Theme.of(context).extension<CornerRadii>() ?? CornerRadii.m();

    return Dialog(
      backgroundColor: Colors.transparent,
      elevation: 0,
      insetPadding: EdgeInsets.symmetric(horizontal: 24.r, vertical: 24.r),
      child: Container(
        constraints: BoxConstraints(
          maxWidth: size.width * 0.7,
          maxHeight: size.height * 0.7,
        ),
        width: double.infinity,
        height: double.infinity,
        decoration: BoxDecoration(
          color: theme.colorScheme.surface,
          borderRadius: radii.radiusExternal,
          border: Border.all(
            color: theme.colorScheme.outline.withValues(alpha: 0.5),
            width: 1.r,
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.35),
              blurRadius: 12.r,
              offset: Offset(0, 4.r),
            ),
          ],
        ),
        child: ClipRRect(
          borderRadius: radii.radiusExternal,
          child: Stack(
            fit: StackFit.expand,
            children: [
              // Achievements content: the tab widget is designed for a Stack
              // with fixed offsets, so we place it directly in this Stack.
              GameDetailsAchievementsTab(
                key: _tabKey,
                gameInfo: _gameInfo,
                isLoading: _isLoading,
                topOffset: 0,
                bottomOffset: 0,
                leftOffset: 0,
                rightOffset: 0,
                headerAction: HeaderActionButton(
                  icon: Image.asset(
                    'assets/images/gamepad/Xbox_B_button.png',
                    width: 12.r,
                    height: 12.r,
                    color: theme.colorScheme.onPrimary,
                  ),
                  label: AppLocale.back.getString(context).toUpperCase(),
                  onTap: () => Navigator.of(context).pop(),
                  backgroundColor: theme.colorScheme.primary,
                  foregroundColor: theme.colorScheme.onPrimary,
                ),
                onFixMatch: _openMatchPicker,
                onRefresh: () {
                  SfxService().playNavSound();
                  _loadAchievements(forceRefresh: true);
                },
              ),
            ],
          ),
        ),
      ),
    );
  }
}
