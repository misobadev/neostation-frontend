import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:neostation/l10n/app_locale.dart';
import 'package:neostation/models/system_model.dart';
import 'package:neostation/data/datasources/sqlite_service.dart';
import 'package:neostation/models/core_emulator_model.dart';
import 'package:neostation/services/gamepad/gamepad_navigation_manager.dart';
import 'package:neostation/utils/cloud_path_builder.dart';
import 'package:neostation/utils/gamepad_nav.dart';
import 'package:neostation/widgets/core_footer.dart';

/// Which selector an in-dialog option list is choosing a value for.
enum _Picking { system, emulator }

/// Dialog that lets the user pick a system + emulator and select a folder.
///
/// The configured-folder list lives in the full-screen view, not here. Folder
/// selection and sync run in the parent view so they survive Android
/// backgrounding; the dialog closes with the B button or the footer Close
/// control.
///
/// Fully controller-driven: Up/Down moves between the system row, the emulator
/// row and the Select folder button; A on a row opens its options as an
/// in-dialog list (Up/Down, A to choose, B to return). Material dropdowns are
/// not used because their menu route is invisible to [GamepadNavigation].
class CustomSaveFoldersDialog extends StatefulWidget {
  final List<SystemModel> systems;
  final bool isSyncing;
  final Future<void> Function(String system, String emulatorSlug)
  onSelectFolder;

  const CustomSaveFoldersDialog({
    super.key,
    required this.systems,
    required this.isSyncing,
    required this.onSelectFolder,
  });

  @override
  State<CustomSaveFoldersDialog> createState() =>
      _CustomSaveFoldersDialogState();
}

class _CustomSaveFoldersDialogState extends State<CustomSaveFoldersDialog> {
  static const _rowSystem = 0;
  static const _rowEmulator = 1;
  static const _rowSelect = 2;

  late GamepadNavigation _gamepadNav;
  final ScrollController _listScroll = ScrollController();

  /// The dialogue's own navigation layer. Without one, a resume (or a modal
  /// closing just before this opened) woke the screen underneath, and one A or
  /// B press drove both. Modal, so a screen that mounts behind it can't take
  /// the controller back; per instance, as [GamepadNavigationManager.popLayer]
  /// removes the first layer with a matching id.
  late final String _layerId =
      'neo_sync_custom_folders_dialog#${identityHashCode(this)}';

  String? _selectedSystem;
  List<CoreEmulatorModel> _emulators = [];
  String? _selectedEmulatorUniqueId;
  bool _pickingFolder = false;

  int _focusedRow = _rowSystem;
  _Picking? _picking;
  int _listIndex = 0;

  @override
  void initState() {
    super.initState();
    _gamepadNav = GamepadNavigation(
      onNavigateUp: (isRepeat) => _move(-1),
      onNavigateDown: (isRepeat) => _move(1),
      onSelectItem: _activate,
      onBack: _back,
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _gamepadNav.initialize();
      GamepadNavigationManager.pushLayer(
        _layerId,
        onActivate: _gamepadNav.activate,
        onDeactivate: _gamepadNav.deactivate,
        modal: true,
      );
    });
  }

  @override
  void dispose() {
    GamepadNavigationManager.popLayer(_layerId);
    _gamepadNav.dispose();
    _listScroll.dispose();
    super.dispose();
  }

  double get _listItemExtent => 30.r;

  int get _listLength => switch (_picking) {
    _Picking.system => widget.systems.length,
    _Picking.emulator => _emulators.length,
    null => 0,
  };

  bool get _canSelectFolder =>
      !widget.isSyncing && !_pickingFolder && _selectedEmulatorUniqueId != null;

  void _move(int delta) {
    if (_picking != null) {
      final length = _listLength;
      if (length == 0) return;
      setState(() => _listIndex = (_listIndex + delta + length) % length);
      _scrollListToIndex();
      return;
    }
    setState(() => _focusedRow = (_focusedRow + delta + 3) % 3);
  }

  void _activate() {
    if (_picking != null) {
      _chooseListItem(_listIndex);
      return;
    }
    switch (_focusedRow) {
      case _rowSystem:
        _openList(_Picking.system);
      case _rowEmulator:
        _openList(_Picking.emulator);
      case _rowSelect:
        if (_canSelectFolder) _selectFolder();
    }
  }

  void _back() {
    if (!mounted) return;
    if (_picking != null) {
      setState(() => _picking = null);
      return;
    }
    Navigator.of(context).pop();
  }

  void _openList(_Picking picking) {
    final int current;
    switch (picking) {
      case _Picking.system:
        if (widget.systems.isEmpty) return;
        current = widget.systems.indexWhere(
          (s) => s.folderName == _selectedSystem,
        );
      case _Picking.emulator:
        if (_emulators.isEmpty) return;
        current = _emulators.indexWhere(
          (e) => e.uniqueId == _selectedEmulatorUniqueId,
        );
    }
    setState(() {
      _focusedRow = picking == _Picking.system ? _rowSystem : _rowEmulator;
      _picking = picking;
      _listIndex = current < 0 ? 0 : current;
    });
    // The list is built this frame; jump once it has a scroll position.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_listScroll.hasClients) {
        _listScroll.jumpTo(_clampedOffsetFor(_listIndex));
      }
    });
  }

  Future<void> _chooseListItem(int index) async {
    final picking = _picking;
    if (picking == null || index < 0 || index >= _listLength) return;
    switch (picking) {
      case _Picking.system:
        setState(() {
          _picking = null;
          _focusedRow = _rowEmulator;
        });
        await _onSystemSelected(widget.systems[index].folderName);
      case _Picking.emulator:
        setState(() {
          _selectedEmulatorUniqueId = _emulators[index].uniqueId;
          _picking = null;
          _focusedRow = _rowSelect;
        });
    }
  }

  double _clampedOffsetFor(int index) {
    final position = _listScroll.position;
    final viewport = position.viewportDimension;
    final target = index * _listItemExtent - (viewport - _listItemExtent) / 2;
    return target.clamp(0.0, position.maxScrollExtent);
  }

  void _scrollListToIndex() {
    if (!_listScroll.hasClients) return;
    _listScroll.animateTo(
      _clampedOffsetFor(_listIndex),
      duration: const Duration(milliseconds: 120),
      curve: Curves.easeOut,
    );
  }

  Future<void> _onSystemSelected(String? folderName) async {
    setState(() {
      _selectedSystem = folderName;
      _emulators = [];
      _selectedEmulatorUniqueId = null;
    });
    if (folderName == null) return;

    try {
      final system = widget.systems.firstWhere(
        (s) => s.folderName == folderName,
        orElse: () => widget.systems.first,
      );
      final emulators = await SqliteService.getEmulatorsForSystemCurrentOs(
        system.id ?? system.folderName,
      );
      // Standalone folders target standalone emulators (ARMSX2, DuckStation, ...).
      // RetroArch cores are discovered automatically from their saves dir, so
      // they must never be offered here — even if a core is mis-flagged as
      // standalone, its `retroarch.*` slug is the reliable tell.
      final standalone = emulators.where((e) {
        if (!e.isStandalone) return false;
        final slug = CloudPathBuilder.slugFromEmulatorUniqueId(e.uniqueId);
        return !slug.startsWith('retroarch.');
      }).toList();
      if (mounted) {
        setState(() {
          _emulators = standalone;
          // A single candidate needs no extra pick.
          if (standalone.length == 1) {
            _selectedEmulatorUniqueId = standalone.first.uniqueId;
            _focusedRow = _rowSelect;
          }
        });
      }
    } catch (e) {
      // ignore
    }
  }

  Future<void> _selectFolder() async {
    final system = _selectedSystem;
    final emulatorUniqueId = _selectedEmulatorUniqueId;
    if (system == null || emulatorUniqueId == null || _pickingFolder) return;

    setState(() => _pickingFolder = true);
    // Closing the dialog before opening the SAF picker avoids the dialog being
    // disposed mid-flight on Android resume; the parent view completes the
    // operation and refreshes the list.
    if (mounted) Navigator.of(context).pop();
    await widget.onSelectFolder(system, emulatorUniqueId);
  }

  String? get _systemLabel {
    final folder = _selectedSystem;
    if (folder == null) return null;
    for (final s in widget.systems) {
      if (s.folderName == folder) return '${s.realName} (${s.folderName})';
    }
    return folder;
  }

  String? get _emulatorLabel {
    final id = _selectedEmulatorUniqueId;
    if (id == null) return null;
    for (final e in _emulators) {
      if (e.uniqueId == id) return e.name;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final picking = _picking;

    return AlertDialog(
      title: Row(
        children: [
          Icon(
            Symbols.folder_special_rounded,
            size: 18.r,
            color: theme.colorScheme.primary,
          ),
          SizedBox(width: 8.r),
          Expanded(
            child: Text(
              AppLocale.customSaveFoldersTitle.getString(context),
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.bold,
                fontSize: 13.r,
                color: theme.colorScheme.onSurface,
              ),
            ),
          ),
        ],
      ),
      content: SizedBox(
        width: 340.r,
        child: picking == null
            ? _buildRows(theme)
            : _buildOptionList(theme, picking),
      ),
      actionsPadding: EdgeInsets.fromLTRB(16.r, 8.r, 16.r, 12.r),
      actions: [
        Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            GamepadControl(
              label: AppLocale.select.getString(context),
              iconPath: 'assets/images/gamepad/Xbox_A_button.png',
              onTap: _activate,
              textColor: theme.colorScheme.onPrimary,
              backgroundColor: theme.colorScheme.primary,
            ),
            SizedBox(width: 8.r),
            GamepadControl(
              label: picking == null
                  ? AppLocale.close.getString(context)
                  : AppLocale.back.getString(context),
              iconPath: 'assets/images/gamepad/Xbox_B_button.png',
              onTap: _back,
              textColor: theme.colorScheme.onTertiary,
              backgroundColor: theme.colorScheme.tertiary,
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildRows(ThemeData theme) {
    final selectFocused = _focusedRow == _rowSelect;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _SelectorRow(
          value: _systemLabel,
          hint: AppLocale.customSaveFolderPickSystem.getString(context),
          focused: _focusedRow == _rowSystem,
          enabled: widget.systems.isNotEmpty,
          onTap: () => _openList(_Picking.system),
        ),
        SizedBox(height: 8.r),
        _SelectorRow(
          value: _emulatorLabel,
          hint: AppLocale.customSaveFolderPickEmulator.getString(context),
          focused: _focusedRow == _rowEmulator,
          enabled: _emulators.isNotEmpty,
          onTap: () => _openList(_Picking.emulator),
        ),
        SizedBox(height: 10.r),
        AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          width: double.infinity,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(22.r),
            border: Border.all(
              color: selectFocused
                  ? theme.colorScheme.onSurface
                  : Colors.transparent,
              width: 2.r,
            ),
          ),
          child: FilledButton.icon(
            onPressed: _canSelectFolder ? _selectFolder : null,
            icon: _pickingFolder
                ? SizedBox(
                    width: 14.r,
                    height: 14.r,
                    child: const CircularProgressIndicator(strokeWidth: 2),
                  )
                : Icon(Symbols.folder_open_rounded, size: 14.r),
            label: Text(
              AppLocale.customSaveFolderSelect.getString(context),
              style: TextStyle(fontSize: 11.r),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildOptionList(ThemeData theme, _Picking picking) {
    final labels = picking == _Picking.system
        ? widget.systems.map((s) => '${s.realName} (${s.folderName})').toList()
        : _emulators.map((e) => e.name).toList();
    final selectedIndex = picking == _Picking.system
        ? widget.systems.indexWhere((s) => s.folderName == _selectedSystem)
        : _emulators.indexWhere((e) => e.uniqueId == _selectedEmulatorUniqueId);

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: EdgeInsets.only(left: 4.r, bottom: 6.r),
          child: Text(
            picking == _Picking.system
                ? AppLocale.customSaveFolderPickSystem.getString(context)
                : AppLocale.customSaveFolderPickEmulator.getString(context),
            style: TextStyle(
              fontSize: 11.r,
              fontWeight: FontWeight.w600,
              color: theme.colorScheme.onSurface.withValues(alpha: 0.7),
            ),
          ),
        ),
        SizedBox(
          height: (_listItemExtent * labels.length).clamp(
            _listItemExtent,
            _listItemExtent * 7,
          ),
          child: ListView.builder(
            controller: _listScroll,
            itemExtent: _listItemExtent,
            itemCount: labels.length,
            itemBuilder: (context, index) {
              final focused = index == _listIndex;
              final selected = index == selectedIndex;
              return InkWell(
                borderRadius: BorderRadius.circular(6.r),
                onTap: () => _chooseListItem(index),
                child: Container(
                  padding: EdgeInsets.symmetric(horizontal: 10.r),
                  alignment: Alignment.centerLeft,
                  decoration: BoxDecoration(
                    color: focused
                        ? theme.colorScheme.primary.withValues(alpha: 0.18)
                        : Colors.transparent,
                    borderRadius: BorderRadius.circular(6.r),
                    border: Border.all(
                      color: focused
                          ? theme.colorScheme.primary
                          : Colors.transparent,
                      width: 1.5.r,
                    ),
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          labels[index],
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 12.r,
                            fontWeight: focused
                                ? FontWeight.w600
                                : FontWeight.normal,
                            color: theme.colorScheme.onSurface,
                          ),
                        ),
                      ),
                      if (selected)
                        Icon(
                          Symbols.check_rounded,
                          size: 14.r,
                          color: theme.colorScheme.primary,
                        ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}

/// A dropdown-style row showing the chosen value (or a hint), highlighted when
/// it has controller focus. Tapping or pressing A opens its option list.
class _SelectorRow extends StatelessWidget {
  final String? value;
  final String hint;
  final bool focused;
  final bool enabled;
  final VoidCallback onTap;

  const _SelectorRow({
    required this.value,
    required this.hint,
    required this.focused,
    required this.enabled,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final onSurface = theme.colorScheme.onSurface;
    final textColor = !enabled
        ? onSurface.withValues(alpha: 0.38)
        : value == null
        ? onSurface.withValues(alpha: 0.6)
        : onSurface;

    return InkWell(
      borderRadius: BorderRadius.circular(8.r),
      onTap: enabled ? onTap : null,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 120),
        padding: EdgeInsets.symmetric(horizontal: 10.r, vertical: 8.r),
        decoration: BoxDecoration(
          color: focused
              ? theme.colorScheme.primary.withValues(alpha: 0.12)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(8.r),
          border: Border.all(
            color: focused
                ? theme.colorScheme.primary
                : onSurface.withValues(alpha: 0.3),
            width: focused ? 2.r : 1.r,
          ),
        ),
        child: Row(
          children: [
            Expanded(
              child: Text(
                value ?? hint,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 12.r, color: textColor),
              ),
            ),
            Icon(Symbols.arrow_drop_down_rounded, size: 18.r, color: textColor),
          ],
        ),
      ),
    );
  }
}
