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

/// Dialog that lets the user pick a system + emulator and select a folder.
///
/// The configured-folder list lives in the full-screen view, not here. Folder
/// selection and sync run in the parent view so they survive Android
/// backgrounding; the dialog closes with the B button or the footer Close
/// control.
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
  late GamepadNavigation _gamepadNav;

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

  @override
  void initState() {
    super.initState();
    _gamepadNav = GamepadNavigation(
      onBack: () {
        if (mounted) Navigator.of(context).pop();
      },
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
    super.dispose();
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
      if (mounted) setState(() => _emulators = standalone);
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

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isBusy = widget.isSyncing || _pickingFolder;

    final selectDecoration = InputDecoration(
      isDense: true,
      contentPadding: EdgeInsets.symmetric(horizontal: 10.r, vertical: 8.r),
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(8.r)),
    );
    final selectStyle = TextStyle(fontSize: 12.r);

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
              ),
            ),
          ),
        ],
      ),
      content: SingleChildScrollView(
        child: SizedBox(
          width: 340.r,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              DropdownButtonFormField<String>(
                initialValue: _selectedSystem,
                decoration: selectDecoration,
                style: selectStyle,
                hint: Text(
                  AppLocale.customSaveFolderPickSystem.getString(context),
                  style: selectStyle,
                ),
                items: widget.systems
                    .map(
                      (s) => DropdownMenuItem(
                        value: s.folderName,
                        child: Text(
                          '${s.realName} (${s.folderName})',
                          overflow: TextOverflow.ellipsis,
                          style: selectStyle,
                        ),
                      ),
                    )
                    .toList(),
                onChanged: _onSystemSelected,
              ),
              SizedBox(height: 8.r),
              DropdownButtonFormField<String>(
                initialValue: _selectedEmulatorUniqueId,
                decoration: selectDecoration,
                style: selectStyle,
                hint: Text(
                  AppLocale.customSaveFolderPickEmulator.getString(context),
                  style: selectStyle,
                ),
                items: _emulators
                    .map(
                      (e) => DropdownMenuItem(
                        value: e.uniqueId,
                        child: Text(
                          e.name,
                          overflow: TextOverflow.ellipsis,
                          style: selectStyle,
                        ),
                      ),
                    )
                    .toList(),
                onChanged: (v) => setState(() => _selectedEmulatorUniqueId = v),
              ),
              SizedBox(height: 10.r),
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: isBusy || _selectedEmulatorUniqueId == null
                      ? null
                      : _selectFolder,
                  icon: _pickingFolder
                      ? SizedBox(
                          width: 14.r,
                          height: 14.r,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : Icon(Symbols.folder_open_rounded, size: 14.r),
                  label: Text(
                    AppLocale.customSaveFolderSelect.getString(context),
                    style: TextStyle(fontSize: 11.r),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
      actionsPadding: EdgeInsets.fromLTRB(16.r, 8.r, 16.r, 12.r),
      actions: [
        Align(
          alignment: Alignment.centerRight,
          child: GamepadControl(
            label: AppLocale.close.getString(context),
            iconPath: 'assets/images/gamepad/Xbox_B_button.png',
            onTap: () => Navigator.of(context).pop(),
            textColor: theme.colorScheme.onTertiary,
            backgroundColor: theme.colorScheme.tertiary,
          ),
        ),
      ],
    );
  }
}
