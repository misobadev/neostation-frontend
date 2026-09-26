import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:provider/provider.dart';
import 'package:neostation/l10n/app_locale.dart';
import 'package:neostation/models/game_model.dart';
import 'package:neostation/models/system_model.dart';
import 'package:neostation/providers/file_provider.dart';
import 'package:neostation/providers/sqlite_config_provider.dart';
import 'package:neostation/services/game_service.dart';
import 'package:neostation/services/sfx_service.dart';
import 'package:neostation/sync/i_sync_provider.dart';
import 'package:neostation/utils/effective_system.dart';
import 'package:neostation/utils/gamepad_nav.dart';
import 'package:neostation/widgets/core_footer.dart';

import 'game_settings_emulator_tab.dart';
import 'game_settings_manage_tab.dart';
import 'game_settings_scrapping_tab.dart';

/// Steam-style settings dialog for a single game, reachable from the game
/// grid, carousel, and list side action bar (or gamepad START).
///
/// Mirrors the [SystemEmulatorSettingsDialog] chrome: a header, an LB/RB
/// tab strip, a content area, and a gamepad-hint footer. Tabs:
///  * Emulator  — per-game emulator override.
///  * Scrapping — force rescrape plus manual metadata/artwork editing.
///  * Manage    — view mode, play-time reset, hiding, and game deletion.
class GameSettingsDialog extends StatefulWidget {
  final GameModel game;
  final SystemModel system;
  final FileProvider fileProvider;

  /// Active cloud-sync provider; when authenticated, the Manage tab shows
  /// the per-game cloud sync toggle.
  final ISyncProvider? syncProvider;

  /// True when the parent list is a virtual system ('all' / 'favorites'), so
  /// per-game paths resolve against the game's real system folder.
  final bool isAllMode;

  /// Called after any persisted change (metadata, emulator, play time,
  /// artwork) so the parent can refetch the game.
  final VoidCallback? onGameUpdated;

  /// Called after the game is permanently deleted; the dialog closes itself
  /// right after invoking this.
  final void Function(String romname)? onGameDeleted;

  /// Called after the game is hidden from the game lists; the dialog closes
  /// itself right after invoking this, exactly like [onGameDeleted]. The row
  /// stays in the database — only the lists stop showing it.
  final void Function(String romname)? onGameHidden;

  const GameSettingsDialog({
    super.key,
    required this.game,
    required this.system,
    required this.fileProvider,
    this.syncProvider,
    this.isAllMode = false,
    this.onGameUpdated,
    this.onGameDeleted,
    this.onGameHidden,
  });

  @override
  State<GameSettingsDialog> createState() => _GameSettingsDialogState();
}

class _GameSettingsDialogState extends State<GameSettingsDialog> {
  int _currentTab = 0;
  late final GamepadNavigation _gamepadNav;

  final _emulatorTabKey = GlobalKey<GameSettingsEmulatorTabState>();
  final _scrappingTabKey = GlobalKey<GameSettingsScrappingTabState>();
  final _manageTabKey = GlobalKey<GameSettingsManageTabState>();

  static const _tabCount = 3;

  @override
  void initState() {
    super.initState();
    _gamepadNav = GamepadNavigation(
      onNavigateUp: _moveUp,
      onNavigateDown: _moveDown,
      onNavigateLeft: _moveLeft,
      onNavigateRight: _moveRight,
      onSelectItem: _trigger,
      onBack: _handleBack,
      onPreviousTab: () => _switchTab(-1),
      onNextTab: () => _switchTab(1),
      isTextFieldFocused: () => _activeTabIsEditingText,
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _gamepadNav.initialize();
      GamepadNavigationManager.pushLayer(
        'game_settings_dialog',
        onActivate: () => _gamepadNav.activate(),
        onDeactivate: () => _gamepadNav.deactivate(),
      );
    });
  }

  @override
  void dispose() {
    GamepadNavigationManager.popLayer('game_settings_dialog');
    _gamepadNav.dispose();
    super.dispose();
  }

  void _switchTab(int delta) {
    SfxService().playNavSound();
    setState(() {
      _currentTab = (_currentTab + delta) % _tabCount;
      if (_currentTab < 0) _currentTab += _tabCount;
    });
  }

  void _moveUp() {
    switch (_currentTab) {
      case 0:
        _emulatorTabKey.currentState?.moveUp();
      case 1:
        _scrappingTabKey.currentState?.moveUp();
      case 2:
        _manageTabKey.currentState?.moveUp();
    }
  }

  void _moveDown() {
    switch (_currentTab) {
      case 0:
        _emulatorTabKey.currentState?.moveDown();
      case 1:
        _scrappingTabKey.currentState?.moveDown();
      case 2:
        _manageTabKey.currentState?.moveDown();
    }
  }

  void _moveLeft() {
    // Only the Scrapping tab has internal sub-tabs (Data / Media).
    if (_currentTab == 1) {
      _scrappingTabKey.currentState?.moveLeft();
    }
  }

  void _moveRight() {
    // Only the Scrapping tab has internal sub-tabs (Data / Media).
    if (_currentTab == 1) {
      _scrappingTabKey.currentState?.moveRight();
    }
  }

  void _trigger() {
    switch (_currentTab) {
      case 0:
        _emulatorTabKey.currentState?.trigger();
      case 1:
        _scrappingTabKey.currentState?.trigger();
      case 2:
        _manageTabKey.currentState?.trigger();
    }
  }

  bool get _activeTabIsEditingText =>
      _currentTab == 1 &&
      (_scrappingTabKey.currentState?.isEditingText ?? false);

  void _handleBack() {
    // While a metadata text field is being edited, B steps out of the field
    // instead of closing the dialog.
    if (_activeTabIsEditingText) {
      _scrappingTabKey.currentState?.cancelEdit();
      return;
    }
    SfxService().playBackSound();
    Navigator.of(context).pop();
  }

  void _handleGameDeleted(String romname) {
    widget.onGameDeleted?.call(romname);
    if (mounted) Navigator.of(context).pop();
  }

  void _handleGameHidden(String romname) {
    widget.onGameHidden?.call(romname);
    if (mounted) Navigator.of(context).pop();
  }

  /// The system the *selected game* belongs to.
  ///
  /// In an aggregate view [widget.system] is the synthesized placeholder for
  /// the view itself ('all' / 'favorites' / `collection:<uuid>`), and a
  /// collection's id has no `app_systems` row at all — so the tabs get the
  /// game's own system instead. Without this the Emulator tab enumerated
  /// emulators for the placeholder and came up empty in every aggregate view,
  /// leaving the user unable to assign an emulator from one. Every aggregate
  /// view shares one resolver now — the games grid, carousel and details card
  /// all call [resolveEffectiveSystem] too.
  SystemModel get _effectiveSystem {
    if (!widget.isAllMode) return widget.system;
    try {
      return resolveEffectiveSystem(
        listSystem: widget.system,
        game: widget.game,
        detectedSystems: context.read<SqliteConfigProvider>().detectedSystems,
      );
    } catch (e) {
      // No provider in scope (or nothing detected yet): the placeholder is the
      // only answer available, exactly as before.
      return widget.system;
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // In landscape the software keyboard can consume over half the display.
    // Keeping the dialog chrome in that small remaining area leaves no useful
    // room for the scrolling metadata editor, so hide it temporarily while
    // the keyboard is open. The editor then owns the resized viewport and can
    // keep its focused field comfortably above the IME.
    final isKeyboardVisible = MediaQuery.viewInsetsOf(context).bottom > 0;
    final displayName = widget.game.name.isNotEmpty
        ? widget.game.name
        : widget.game.romname;
    // Resolved once per build so all three tabs agree on the system.
    final effectiveSystem = _effectiveSystem;

    return Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: EdgeInsets.symmetric(horizontal: 16.r, vertical: 16.r),
      child: Container(
        constraints: BoxConstraints(maxWidth: 640.r, maxHeight: 480.r),
        decoration: BoxDecoration(
          color: theme.colorScheme.surface,
          borderRadius: BorderRadius.circular(12.r),
          border: Border.all(
            color: theme.colorScheme.outline.withValues(alpha: 0.1),
          ),
          boxShadow: [
            BoxShadow(
              color: theme.colorScheme.shadow.withValues(alpha: 0.5),
              blurRadius: 10.r,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (!isKeyboardVisible) ...[
              _buildHeader(theme, displayName),
              _buildTabsHeader(theme),
            ],
            Expanded(
              child: IndexedStack(
                index: _currentTab,
                children: [
                  GameSettingsEmulatorTab(
                    key: _emulatorTabKey,
                    game: widget.game,
                    system: effectiveSystem,
                    isAllMode: widget.isAllMode,
                    onGameUpdated: widget.onGameUpdated,
                  ),
                  GameSettingsScrappingTab(
                    key: _scrappingTabKey,
                    game: widget.game,
                    system: effectiveSystem,
                    fileProvider: widget.fileProvider,
                    isAllMode: widget.isAllMode,
                    onGameUpdated: widget.onGameUpdated,
                  ),
                  GameSettingsManageTab(
                    key: _manageTabKey,
                    game: widget.game,
                    system: effectiveSystem,
                    fileProvider: widget.fileProvider,
                    syncProvider: widget.syncProvider,
                    isAllMode: widget.isAllMode,
                    onGameUpdated: widget.onGameUpdated,
                    onGameDeleted: _handleGameDeleted,
                    onGameHidden: _handleGameHidden,
                  ),
                ],
              ),
            ),
            if (!isKeyboardVisible) _buildFooter(theme),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader(ThemeData theme, String displayName) {
    return Container(
      padding: EdgeInsets.symmetric(horizontal: 12.r, vertical: 8.r),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  AppLocale.gameSettings.getString(context),
                  style: TextStyle(
                    fontSize: 12.r,
                    fontWeight: FontWeight.bold,
                    color: theme.colorScheme.onSurface,
                  ),
                ),
                SizedBox(height: 1.r),
                Text(
                  displayName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 10.r,
                    fontWeight: FontWeight.w500,
                    color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
                  ),
                ),
              ],
            ),
          ),
          Material(
            color: Colors.transparent,
            child: InkWell(
              canRequestFocus: false,
              focusColor: Colors.transparent,
              hoverColor: Colors.transparent,
              highlightColor: Colors.transparent,
              splashColor: Colors.transparent,
              borderRadius: BorderRadius.circular(8.r),
              onTap: () {
                SfxService().playBackSound();
                Navigator.of(context).pop();
              },
              child: Container(
                padding: EdgeInsets.all(6.r),
                child: Icon(
                  Symbols.close_rounded,
                  size: 18.r,
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.5),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTabsHeader(ThemeData theme) {
    return Container(
      padding: EdgeInsets.symmetric(horizontal: 12.r),
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(
            color: theme.colorScheme.outline.withValues(alpha: 0.1),
          ),
        ),
      ),
      child: Row(
        children: [
          Padding(
            padding: EdgeInsets.only(right: 8.r),
            child: Image.asset(
              'assets/images/gamepad/Xbox_LB_bumper.png',
              height: 24.r,
              color: theme.colorScheme.onSurface.withValues(alpha: 0.5),
              colorBlendMode: BlendMode.srcIn,
            ),
          ),
          _buildTabItem(theme, 0, AppLocale.emulator.getString(context)),
          SizedBox(width: 16.r),
          _buildTabItem(theme, 1, AppLocale.scraping.getString(context)),
          SizedBox(width: 16.r),
          _buildTabItem(theme, 2, AppLocale.manage.getString(context)),
          const Spacer(),
          Padding(
            padding: EdgeInsets.only(left: 8.r),
            child: Image.asset(
              'assets/images/gamepad/Xbox_RB_bumper.png',
              height: 24.r,
              color: theme.colorScheme.onSurface.withValues(alpha: 0.5),
              colorBlendMode: BlendMode.srcIn,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTabItem(ThemeData theme, int index, String label) {
    final bool isSelected = _currentTab == index;
    return InkWell(
      canRequestFocus: false,
      focusColor: Colors.transparent,
      hoverColor: Colors.transparent,
      highlightColor: Colors.transparent,
      splashColor: Colors.transparent,
      onTap: () {
        SfxService().playNavSound();
        setState(() => _currentTab = index);
      },
      child: Container(
        padding: EdgeInsets.symmetric(vertical: 8.r),
        decoration: BoxDecoration(
          border: Border(
            bottom: BorderSide(
              color: isSelected
                  ? theme.colorScheme.secondary
                  : Colors.transparent,
              width: 2.r,
            ),
          ),
        ),
        child: Text(
          label.toUpperCase(),
          style: TextStyle(
            fontSize: 10.r,
            fontWeight: isSelected ? FontWeight.bold : FontWeight.w500,
            color: isSelected
                ? theme.colorScheme.secondary
                : theme.colorScheme.onSurface.withValues(alpha: 0.5),
            letterSpacing: 0.5.r,
          ),
        ),
      ),
    );
  }

  Widget _buildFooter(ThemeData theme) {
    return Container(
      padding: EdgeInsets.all(8.r),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(
          alpha: 0.05,
        ),
        borderRadius: BorderRadius.only(
          bottomLeft: Radius.circular(12.r),
          bottomRight: Radius.circular(12.r),
        ),
      ),
      child: Row(
        children: [
          Expanded(
            child: Row(
              children: [
                GamepadControl(
                  iconPath: 'assets/images/gamepad/Xbox_D-pad_ALL.png',
                  label: AppLocale.navigate.getString(context),
                  backgroundColor: theme.colorScheme.tertiary,
                  textColor: theme.colorScheme.onPrimary,
                ),
              ],
            ),
          ),
          SizedBox(width: 8.r),
          GamepadControl(
            iconPath: 'assets/images/gamepad/Xbox_B_button.png',
            label: AppLocale.close.getString(context),
            backgroundColor: theme.colorScheme.error,
            textColor: theme.colorScheme.onError,
            onTap: () {
              SfxService().playBackSound();
              Navigator.of(context).pop();
            },
          ),
        ],
      ),
    );
  }
}
