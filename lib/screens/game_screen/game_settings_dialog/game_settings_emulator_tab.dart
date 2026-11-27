import 'package:flutter/material.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:neostation/l10n/app_locale.dart';
import 'package:neostation/models/core_emulator_model.dart';
import 'package:neostation/models/game_model.dart';
import 'package:neostation/models/system_model.dart';
import 'package:neostation/repositories/game_repository.dart';
import 'package:neostation/services/launch_display_service.dart';
import 'package:neostation/services/logger_service.dart';
import 'package:neostation/services/sfx_service.dart';
import 'package:neostation/utils/emulator_loader.dart';
import 'package:neostation/widgets/settings_rows.dart';

/// Per-game emulator override tab for [GameSettingsDialog].
///
/// Lists 'System Default' plus every emulator available for the game's
/// system, mirroring the behavior of the list view's settings tab. On a device
/// with a second screen it adds a Screen section below (system default, main
/// screen, secondary screen) that picks where this game opens.
class GameSettingsEmulatorTab extends StatefulWidget {
  final GameModel game;
  final SystemModel system;
  final bool isAllMode;
  final VoidCallback? onGameUpdated;

  const GameSettingsEmulatorTab({
    super.key,
    required this.game,
    required this.system,
    required this.isAllMode,
    this.onGameUpdated,
  });

  @override
  State<GameSettingsEmulatorTab> createState() =>
      GameSettingsEmulatorTabState();
}

class GameSettingsEmulatorTabState extends State<GameSettingsEmulatorTab> {
  static final _log = LoggerService.instance;

  List<CoreEmulatorModel> _availableEmulators = [];
  int _selectedIndex = 0;

  /// Tracks the active emulator override. Uses a sentinel to differentiate
  /// between 'not yet loaded' and 'explicit null' (system default).
  Object? _activeEmulatorId = _sentinel;
  static const Object _sentinel = Object();

  final ScrollController _scrollController = ScrollController();
  final Map<int, GlobalKey> _itemKeys = {};

  GlobalKey _itemKey(int navIndex) =>
      _itemKeys.putIfAbsent(navIndex, () => GlobalKey());

  String? get _resolvedEmulatorId => identical(_activeEmulatorId, _sentinel)
      ? widget.game.emulatorName
      : _activeEmulatorId as String?;

  /// Whether a second screen exists, so the Screen section is shown.
  bool _hasSecondaryDisplay = false;

  /// This game's own launch screen; null follows the system.
  LaunchDisplay? _launchDisplay;

  /// Options of the Screen section, in row order. null = system default.
  static const List<LaunchDisplay?> _screenOptions = [
    null,
    LaunchDisplay.primary,
    LaunchDisplay.secondary,
  ];

  int get _emulatorItems =>
      _availableEmulators.isEmpty ? 0 : 1 + _availableEmulators.length;

  /// The Screen section only makes sense next to a launchable game.
  bool get _showsScreenSection =>
      _hasSecondaryDisplay && _emulatorItems > 0 && _romPath != null;

  String? get _romPath {
    final path = widget.game.romPath;
    return path == null || path.isEmpty ? null : path;
  }

  /// Emulator rows first (0.._emulatorItems-1), then the Screen rows.
  int get _totalItems =>
      _emulatorItems + (_showsScreenSection ? _screenOptions.length : 0);

  @override
  void initState() {
    super.initState();
    _loadEmulators();
    _loadLaunchDisplay();
  }

  Future<void> _loadLaunchDisplay() async {
    final romPath = _romPath;
    if (romPath == null) return;
    if (!await LaunchDisplayService.hasSecondaryDisplay()) return;
    final display = await LaunchDisplayService.getForGame(romPath);
    if (!mounted) return;
    setState(() {
      _hasSecondaryDisplay = true;
      _launchDisplay = display;
    });
  }

  Future<void> _setLaunchDisplay(LaunchDisplay? display) async {
    final romPath = _romPath;
    if (romPath == null) return;
    final previous = _launchDisplay;
    if (mounted) setState(() => _launchDisplay = display);
    try {
      await LaunchDisplayService.setForGame(romPath, display);
    } catch (e) {
      _log.e('Launch screen persistence failed: $e');
      if (mounted) setState(() => _launchDisplay = previous);
    }
  }

  String _screenLabel(BuildContext context, LaunchDisplay? display) =>
      switch (display) {
        null => AppLocale.systemDefault.getString(context),
        LaunchDisplay.primary => AppLocale.mainScreen.getString(context),
        LaunchDisplay.secondary => AppLocale.secondaryDisplay.getString(
          context,
        ),
      };

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _loadEmulators() async {
    final emulators = await loadEmulatorsForSystem(widget.system);
    if (mounted) setState(() => _availableEmulators = emulators);
  }

  void moveUp() {
    if (_totalItems == 0) return;
    setState(
      () => _selectedIndex = (_selectedIndex - 1).clamp(0, _totalItems - 1),
    );
    _scrollToSelectedItem();
  }

  void moveDown() {
    if (_totalItems == 0) return;
    setState(
      () => _selectedIndex = (_selectedIndex + 1).clamp(0, _totalItems - 1),
    );
    _scrollToSelectedItem();
  }

  void trigger() {
    if (_totalItems == 0) return;
    if (_selectedIndex >= _emulatorItems) {
      _setLaunchDisplay(_screenOptions[_selectedIndex - _emulatorItems]);
      return;
    }
    if (_selectedIndex == 0) {
      _setEmulatorOverride(null);
      return;
    }
    final emulator = _availableEmulators[_selectedIndex - 1];
    if (!emulator.isInstalled) return;
    _setEmulatorOverride(emulator);
  }

  void _scrollToSelectedItem() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final key = _itemKeys[_selectedIndex];
      if (key?.currentContext != null) {
        Scrollable.ensureVisible(
          key!.currentContext!,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
          alignment: 0.5,
        );
      }
    });
  }

  /// Persists a manual emulator override for this specific game.
  Future<void> _setEmulatorOverride(CoreEmulatorModel? emulator) async {
    // Optimistic update: reflect changes in UI immediately.
    if (mounted) setState(() => _activeEmulatorId = emulator?.uniqueId);
    try {
      final targetSystemFolder =
          widget.isAllMode && widget.game.systemFolderName != null
          ? widget.game.systemFolderName!
          : widget.system.folderName;
      await GameRepository.setEmulatorOverride(
        targetSystemFolder,
        widget.game.romname,
        emulator?.uniqueId,
        emulator?.osId,
      );
      widget.onGameUpdated?.call();
    } catch (e) {
      _log.e('Emulator override persistence failed: $e');
      // Rollback: revert UI state on failure.
      if (mounted) {
        setState(() => _activeEmulatorId = widget.game.emulatorName);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_availableEmulators.isEmpty) {
      return Center(
        child: Text(
          AppLocale.noEmulator.getString(context),
          style: TextStyle(
            fontSize: 12.r,
            color: Theme.of(context).colorScheme.onSurface
                .withValues(alpha: 0.6),
          ),
        ),
      );
    }

    return SingleChildScrollView(
      controller: _scrollController,
      padding: EdgeInsets.all(12.r),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _sectionHeader(
            context,
            Symbols.sports_esports_rounded,
            AppLocale.emulator.getString(context),
          ),
          // Global System Default Option.
          EmulatorRow(
            key: _itemKey(0),
            isSelected: _selectedIndex == 0,
            label: AppLocale.systemDefault.getString(context),
            isActive:
                _resolvedEmulatorId == null ||
                !_availableEmulators.any(
                  (e) => e.uniqueId == _resolvedEmulatorId,
                ),
            onTap: () {
              SfxService().playNavSound();
              setState(() => _selectedIndex = 0);
              _setEmulatorOverride(null);
            },
          ),
          // Individual Emulator Options.
          ..._availableEmulators.asMap().entries.map((entry) {
            final i = entry.key;
            final e = entry.value;
            return EmulatorRow(
              key: _itemKey(i + 1),
              isSelected: _selectedIndex == i + 1,
              label: e.name,
              isActive: _resolvedEmulatorId == e.uniqueId,
              onTap: () {
                SfxService().playNavSound();
                setState(() => _selectedIndex = i + 1);
                _setEmulatorOverride(e);
              },
              emulator: e,
            );
          }),
          if (_showsScreenSection) ...[
            SizedBox(height: 8.r),
            _sectionHeader(
              context,
              Symbols.screenshot_monitor_rounded,
              AppLocale.launchScreen.getString(context),
            ),
            ..._screenOptions.asMap().entries.map((entry) {
              final navIndex = _emulatorItems + entry.key;
              final option = entry.value;
              return EmulatorRow(
                key: _itemKey(navIndex),
                isSelected: _selectedIndex == navIndex,
                label: _screenLabel(context, option),
                isActive: _launchDisplay == option,
                onTap: () {
                  SfxService().playNavSound();
                  setState(() => _selectedIndex = navIndex);
                  _setLaunchDisplay(option);
                },
              );
            }),
          ],
        ],
      ),
    );
  }

  Widget _sectionHeader(BuildContext context, IconData icon, String label) {
    final color = Theme.of(context).colorScheme.onSurface
        .withValues(alpha: 0.6);
    return Padding(
      padding: EdgeInsets.only(left: 4.r, bottom: 4.r),
      child: Row(
        children: [
          Icon(icon, size: 12.r, color: color),
          SizedBox(width: 4.r),
          Text(
            label,
            style: TextStyle(
              fontSize: 11.r,
              fontWeight: FontWeight.w600,
              color: color,
            ),
          ),
        ],
      ),
    );
  }
}
