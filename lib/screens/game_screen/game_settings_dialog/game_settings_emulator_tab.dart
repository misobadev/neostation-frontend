import 'package:flutter/material.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:neostation/l10n/app_locale.dart';
import 'package:neostation/models/core_emulator_model.dart';
import 'package:neostation/models/game_model.dart';
import 'package:neostation/models/system_model.dart';
import 'package:neostation/repositories/game_repository.dart';
import 'package:neostation/services/logger_service.dart';
import 'package:neostation/services/sfx_service.dart';
import 'package:neostation/utils/emulator_loader.dart';
import 'package:neostation/widgets/settings_rows.dart';

/// Per-game emulator override tab for [GameSettingsDialog].
///
/// Lists 'System Default' plus every emulator available for the game's
/// system, mirroring the behavior of the list view's settings tab.
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

  int get _totalItems =>
      _availableEmulators.isEmpty ? 0 : 1 + _availableEmulators.length;

  @override
  void initState() {
    super.initState();
    _loadEmulators();
  }

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
          Padding(
            padding: EdgeInsets.only(left: 4.r, bottom: 4.r),
            child: Row(
              children: [
                Icon(
                  Symbols.sports_esports_rounded,
                  size: 12.r,
                  color: Theme.of(context).colorScheme.onSurface
                      .withValues(alpha: 0.6),
                ),
                SizedBox(width: 4.r),
                Text(
                  AppLocale.emulator.getString(context),
                  style: TextStyle(
                    fontSize: 11.r,
                    fontWeight: FontWeight.w600,
                    color: Theme.of(context).colorScheme.onSurface
                        .withValues(alpha: 0.6),
                  ),
                ),
              ],
            ),
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
        ],
      ),
    );
  }
}
