import 'package:flutter/material.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:provider/provider.dart';

import 'package:neostation/l10n/app_locale.dart';
import 'package:neostation/models/game_model.dart';
import 'package:neostation/models/romm_rom.dart';
import 'package:neostation/models/system_model.dart';
import 'package:neostation/providers/romm_provider.dart';
import 'package:neostation/repositories/romm_save_map_repository.dart';
import 'package:neostation/screens/game_screen/game_settings_dialog/romm_match_picker_controller.dart';
import 'package:neostation/services/gamepad/gamepad_navigation_manager.dart';
import 'package:neostation/services/sfx_service.dart';
import 'package:neostation/sync/providers/romm_provider.dart';
import 'package:neostation/sync/sync_manager.dart';
import 'package:neostation/utils/gamepad_nav.dart';
import 'package:neostation/utils/romm_link_state.dart';
import 'package:neostation/widgets/custom_notification.dart';

/// Lets the user link one local game to a RomM ROM by hand.
///
/// Filename linking cannot reach a file renamed locally or one that matches
/// several server entries. This searches the connected server by name, scoped
/// to the RomM platforms that map to the game's system (or every platform when
/// none does), and writes the chosen ROM as a `manual` row that the download
/// path and the automatic passes never replace. Structure follows
/// `RaMatchPickerDialog`: its own gamepad layer, a text field the D-pad can
/// enter and B can leave, and a result list under it.
///
/// Pops `true` when a link was written, `false` when the user backed out.
class RommMatchPickerDialog extends StatefulWidget {
  final GameModel game;
  final SystemModel system;

  /// A remote ROM to pin at the top of the results and pre-select — the
  /// search screen's entry point already knows which one the user means.
  final RommRom? preselectedRom;

  const RommMatchPickerDialog({
    super.key,
    required this.game,
    required this.system,
    this.preselectedRom,
  });

  static Future<bool?> show(
    BuildContext context,
    GameModel game,
    SystemModel system, {
    RommRom? preselectedRom,
  }) {
    return showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => RommMatchPickerDialog(
        game: game,
        system: system,
        preselectedRom: preselectedRom,
      ),
    );
  }

  @override
  State<RommMatchPickerDialog> createState() => _RommMatchPickerDialogState();
}

class _RommMatchPickerDialogState extends State<RommMatchPickerDialog> {
  static const String _layerId = 'romm_match_picker_dialog';
  static final double _rowHeight = 48.r;

  late final GamepadNavigation _gamepadNav;
  late final RommMatchPickerController _controller;
  final TextEditingController _queryController = TextEditingController();
  final FocusNode _queryFocus = FocusNode();
  final ScrollController _scrollController = ScrollController();

  bool _isFieldFocused = false;
  bool _isConfirming = false;
  int _selectedIndex = 0;

  // Index 0 is the search field; the rows after it are either the results or
  // the single retry row shown while the last search is in an error state.
  bool get _showRetryRow => _controller.status == RommMatchPickerStatus.error;
  int get _itemCount => 1 + (_showRetryRow ? 1 : _controller.results.length);

  @override
  void initState() {
    super.initState();

    final rommProvider = context.read<RommProvider>();
    final service = rommProvider.service;
    _controller = RommMatchPickerController(
      linkKey: rommLinkKeyFor(
        romPath: widget.game.romPath,
        romname: widget.game.romname,
      ),
      syncKey: widget.game.romname,
      systemFolder: widget.system.folderName,
      systemRealName: widget.system.realName,
      searchRoms:
          ({
            required String search,
            required List<int> platformIds,
            required int limit,
          }) => service.getRomsPage(
            search: search,
            platformIds: platformIds,
            limit: limit,
          ),
      platformIdsFor: rommProvider.platformIdsForSystemName,
      readMapping: () => RommSaveMapRepository.getMapping(
        widget.game.romname,
        widget.system.folderName,
      ),
      writeMapping: RommSaveMapRepository.putManualMapping,
      invalidateSyncState: _invalidateSyncState,
      preselected: widget.preselectedRom,
    )..addListener(_onControllerChanged);

    _queryController.text = _initialQuery();
    _queryFocus.addListener(() {
      if (!mounted) return;
      setState(() => _isFieldFocused = _queryFocus.hasFocus);
    });

    _gamepadNav = GamepadNavigation(
      onNavigateUp: _moveUp,
      onNavigateDown: _moveDown,
      onSelectItem: _activateSelection,
      onBack: _handleBack,
      isTextFieldFocused: () => _queryFocus.hasFocus,
    );

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _gamepadNav.initialize();
      GamepadNavigationManager.pushLayer(
        _layerId,
        onActivate: () => _gamepadNav.activate(),
        onDeactivate: () => _gamepadNav.deactivate(),
      );
    });

    _controller.init(_queryController.text).then((_) {
      if (!mounted) return;
      final pinned = _controller.preselectedIndex;
      if (pinned >= 0) {
        setState(() => _selectedIndex = pinned + 1);
        _scrollToSelection();
      }
    });
  }

  @override
  void dispose() {
    GamepadNavigationManager.popLayer(_layerId);
    _gamepadNav.dispose();
    _controller
      ..removeListener(_onControllerChanged)
      ..dispose();
    _queryController.dispose();
    _queryFocus.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  /// Drops the RomM sync provider's cached status for the game so the cloud
  /// badge re-asks now that the row changed. Reached by id rather than
  /// through [SyncManager.active], as the browse screen does: the cache lives
  /// on the RomM provider whether or not it is the one doing the saves.
  void _invalidateSyncState(String romname) {
    final sync = SyncManager.instance.provider(RomMSyncProvider.kProviderId);
    if (sync is RomMSyncProvider) sync.invalidateGameSyncState(romname);
  }

  void _onControllerChanged() {
    if (!mounted) return;
    setState(() {
      _selectedIndex = _selectedIndex.clamp(0, _itemCount - 1);
    });
  }

  /// The game's extension-stripped filename, or the preselected ROM's name
  /// when the caller already knows which entry it means.
  ///
  /// `GameModel.romname` is already extension-stripped, so nothing is stripped
  /// here: a second pass at a trailing dot-and-letters cuts a title at its own
  /// dot and prefills "Mr.Do" as "Mr".
  String _initialQuery() {
    final pinned = widget.preselectedRom;
    if (pinned != null && pinned.name.isNotEmpty) return pinned.name;
    return widget.game.romname.trim();
  }

  // ── Gamepad ───────────────────────────────────────────────────────────────

  void _moveUp() {
    if (_queryFocus.hasFocus) return;
    if (_selectedIndex == 0) return;
    setState(() => _selectedIndex--);
    _scrollToSelection();
  }

  void _moveDown() {
    if (_queryFocus.hasFocus) return;
    if (_selectedIndex >= _itemCount - 1) return;
    setState(() => _selectedIndex++);
    _scrollToSelection();
  }

  void _activateSelection() {
    if (_queryFocus.hasFocus) {
      // Enter/A while typing commits the search and returns to list navigation.
      _queryFocus.unfocus();
      _controller.searchNow(_queryController.text);
      return;
    }

    if (_selectedIndex == 0) {
      _queryFocus.requestFocus();
      return;
    }

    if (_showRetryRow) {
      _retry();
      return;
    }

    final rom = _controller.results.elementAtOrNull(_selectedIndex - 1);
    if (rom != null) _confirm(rom);
  }

  /// B leaves the text field first, and only closes the dialog once the field
  /// is no longer focused — the app-wide way out of text entry.
  void _handleBack() {
    if (_queryFocus.hasFocus) {
      _queryFocus.unfocus();
      return;
    }
    if (mounted) Navigator.of(context).pop(false);
  }

  void _scrollToSelection() {
    if (!_scrollController.hasClients) return;
    // Rows are a fixed height, so the offset can be computed directly rather
    // than measured.
    final target = ((_selectedIndex - 1) * _rowHeight).clamp(
      0.0,
      _scrollController.position.maxScrollExtent,
    );
    _scrollController.animateTo(
      target,
      duration: const Duration(milliseconds: 150),
      curve: Curves.easeOut,
    );
  }

  // ── Actions ───────────────────────────────────────────────────────────────

  void _retry() {
    SfxService().playNavSound();
    _controller.searchNow(_queryController.text);
  }

  Future<void> _confirm(RommRom rom) async {
    if (_isConfirming) return;
    SfxService().playNavSound();
    setState(() => _isConfirming = true);
    final linked = await _controller.confirm(rom);
    if (!mounted) return;
    if (linked) {
      Navigator.of(context).pop(true);
      return;
    }
    setState(() => _isConfirming = false);
    AppNotification.showNotification(
      context,
      AppLocale.rommLinkFailed.getString(context),
      type: NotificationType.error,
    );
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final size = MediaQuery.of(context).size;
    final platformNames = {
      for (final platform in context.read<RommProvider>().platforms)
        platform.id: platform.name,
    };
    return Dialog(
      backgroundColor: theme.cardColor,
      insetPadding: EdgeInsets.symmetric(horizontal: 24.r, vertical: 24.r),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12.r),
        side: BorderSide(
          color: theme.colorScheme.primary.withValues(alpha: 0.3),
        ),
      ),
      child: Container(
        width: size.width * 0.6,
        constraints: BoxConstraints(maxHeight: size.height * 0.7),
        padding: EdgeInsets.all(12.r),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildTitle(theme),
            SizedBox(height: 10.r),
            _buildSearchField(theme),
            SizedBox(height: 8.r),
            Flexible(child: _buildResults(theme, platformNames)),
          ],
        ),
      ),
    );
  }

  Widget _buildTitle(ThemeData theme) {
    return Row(
      children: [
        Icon(
          Symbols.link_rounded,
          color: theme.colorScheme.primary,
          size: 18.r,
        ),
        SizedBox(width: 8.r),
        Expanded(
          child: Text(
            AppLocale.rommLinkPickerTitle.getString(context),
            style: theme.textTheme.titleMedium?.copyWith(
              fontSize: 13.r,
              color: theme.colorScheme.primary,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        Text(
          widget.system.realName,
          style: TextStyle(
            fontSize: 10.r,
            color: theme.colorScheme.onSurface.withValues(alpha: 0.5),
          ),
        ),
      ],
    );
  }

  Widget _buildSearchField(ThemeData theme) {
    final selected = _selectedIndex == 0;
    final searching = _controller.status == RommMatchPickerStatus.loading;
    return Container(
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(6.r),
        border: Border.all(
          color: selected || _isFieldFocused
              ? theme.colorScheme.primary
              : theme.colorScheme.outline.withValues(alpha: 0.4),
          width: selected || _isFieldFocused ? 2.r : 1.r,
        ),
      ),
      padding: EdgeInsets.symmetric(horizontal: 8.r),
      child: Row(
        children: [
          Icon(
            Symbols.search_rounded,
            size: 14.r,
            color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
          ),
          SizedBox(width: 6.r),
          Expanded(
            child: TextField(
              controller: _queryController,
              focusNode: _queryFocus,
              onChanged: _controller.onQueryChanged,
              onTap: () => setState(() => _selectedIndex = 0),
              style: TextStyle(
                fontSize: 12.r,
                color: theme.colorScheme.onSurface,
              ),
              decoration: InputDecoration(
                border: InputBorder.none,
                isDense: true,
                contentPadding: EdgeInsets.symmetric(vertical: 10.r),
                hintText: AppLocale.rommLinkPickerSearchHint.getString(context),
                hintStyle: TextStyle(
                  fontSize: 12.r,
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.4),
                ),
              ),
            ),
          ),
          if (searching || _isConfirming)
            SizedBox(
              width: 12.r,
              height: 12.r,
              child: CircularProgressIndicator(strokeWidth: 1.5.r),
            ),
        ],
      ),
    );
  }

  Widget _buildResults(ThemeData theme, Map<int, String> platformNames) {
    final status = _controller.status;
    final results = _controller.results;

    if (status == RommMatchPickerStatus.error) {
      return _RommRetryRow(selected: _selectedIndex == 1, onTap: _retry);
    }

    if (results.isEmpty) {
      // A system the server has no platform for searches nothing at all, so
      // "no matching ROMs" would blame the query for it.
      final String message;
      if (_controller.scope == RommMatchPickerScope.unsupported) {
        message = AppLocale.rommLinkPickerUnscoped.getString(context);
      } else {
        message = status == RommMatchPickerStatus.ready
            ? AppLocale.rommLinkPickerNoResults.getString(context)
            : AppLocale.rommLinkPickerLoading.getString(context);
      }
      return Padding(
        padding: EdgeInsets.symmetric(vertical: 20.r),
        child: Center(
          child: Text(
            message,
            style: TextStyle(
              fontSize: 11.r,
              color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
            ),
          ),
        ),
      );
    }

    return ListView.builder(
      controller: _scrollController,
      shrinkWrap: true,
      physics: const ClampingScrollPhysics(),
      itemCount: results.length,
      itemBuilder: (context, i) {
        final rom = results[i];
        return _RommMatchRow(
          rom: rom,
          platformName: platformNames[rom.platformId] ?? rom.platformSlug,
          selected: _selectedIndex == i + 1,
          isCurrent: rom.id == _controller.currentRomId,
          onTap: () {
            setState(() => _selectedIndex = i + 1);
            _confirm(rom);
          },
        );
      },
    );
  }
}

/// A single remote ROM: name on the first line, platform and on-server
/// filename on the second so same-named entries can be told apart.
class _RommMatchRow extends StatelessWidget {
  final RommRom rom;
  final String platformName;
  final bool selected;
  final bool isCurrent;
  final VoidCallback onTap;

  const _RommMatchRow({
    required this.rom,
    required this.platformName,
    required this.selected,
    required this.isCurrent,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final detail = platformName.isEmpty
        ? rom.fsName
        : '$platformName · ${rom.fsName}';

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(6.r),
      child: Container(
        height: _RommMatchPickerDialogState._rowHeight,
        padding: EdgeInsets.symmetric(horizontal: 8.r),
        decoration: BoxDecoration(
          color: selected
              ? theme.colorScheme.primary.withValues(alpha: 0.15)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(6.r),
          border: Border.all(
            color: selected ? theme.colorScheme.primary : Colors.transparent,
            width: 2.r,
          ),
        ),
        child: Row(
          children: [
            if (isCurrent) ...[
              Icon(
                Symbols.check_circle_rounded,
                size: 14.r,
                color: theme.colorScheme.primary,
              ),
              SizedBox(width: 6.r),
            ],
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    rom.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 11.r,
                      color: theme.colorScheme.onSurface,
                      fontWeight: selected
                          ? FontWeight.w600
                          : FontWeight.normal,
                    ),
                  ),
                  SizedBox(height: 2.r),
                  Text(
                    detail,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 9.r,
                      color: theme.colorScheme.onSurface.withValues(alpha: 0.5),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The one row shown when the last search failed: selecting it runs the same
/// query again, so the dialog stays usable without retyping.
class _RommRetryRow extends StatelessWidget {
  final bool selected;
  final VoidCallback onTap;

  const _RommRetryRow({required this.selected, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(6.r),
      child: Container(
        height: _RommMatchPickerDialogState._rowHeight,
        padding: EdgeInsets.symmetric(horizontal: 8.r),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(6.r),
          border: Border.all(
            color: selected ? theme.colorScheme.primary : Colors.transparent,
            width: 2.r,
          ),
        ),
        child: Row(
          children: [
            Icon(
              Symbols.error_rounded,
              size: 14.r,
              color: theme.colorScheme.error,
            ),
            SizedBox(width: 6.r),
            Expanded(
              child: Text(
                AppLocale.rommLinkPickerError.getString(context),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 11.r,
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.8),
                ),
              ),
            ),
            SizedBox(width: 6.r),
            Icon(
              Symbols.refresh_rounded,
              size: 14.r,
              color: theme.colorScheme.onSurface.withValues(alpha: 0.7),
            ),
          ],
        ),
      ),
    );
  }
}
