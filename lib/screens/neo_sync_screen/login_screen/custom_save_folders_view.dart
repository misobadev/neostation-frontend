import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:path/path.dart' as path;
import 'package:provider/provider.dart';
import 'package:neostation/l10n/app_locale.dart';
import 'package:neostation/providers/neo_sync_provider.dart';
import 'package:neostation/utils/gamepad_nav.dart';
import 'package:neostation/models/system_model.dart';
import 'package:neostation/repositories/neosync_save_folder_repository.dart';
import 'package:neostation/repositories/system_repository.dart';
import 'package:neostation/services/permission_service.dart';
import 'package:neostation/services/user_data_location_service.dart';
import 'package:neostation/widgets/custom_notification.dart' as custom;
import 'package:neostation/widgets/tv_directory_picker.dart';
import 'package:neostation/widgets/core_footer.dart';
import 'package:neostation/widgets/confirm_action_dialog.dart';
import 'package:neostation/services/logger_service.dart';
import 'package:neostation/services/gamepad/gamepad_navigation_manager.dart';
import '../../app_screen.dart';
import 'custom_save_folders_panel.dart';
import 'neo_sync_shared.dart';

/// Full-screen Custom Save Folders view.
///
/// Lets the user configure per-emulator custom save folders (ARMSX2, DuckStation,
/// ...). Folder selection runs on this view (which survives Android
/// backgrounding while the SAF picker is open), and each configured folder can
/// be re-synced or removed. Replaces the inline panel with its own navigation
/// layer.
class CustomSaveFoldersView extends StatefulWidget {
  final VoidCallback onBack;

  const CustomSaveFoldersView({super.key, required this.onBack});

  @override
  State<CustomSaveFoldersView> createState() => _CustomSaveFoldersViewState();
}

class _CustomSaveFoldersViewState extends State<CustomSaveFoldersView> {
  static final _log = LoggerService.instance;

  late GamepadNavigation _gamepadNav;

  List<SystemModel> _systems = [];
  List<(String, String, String)> _configured = [];
  bool _syncing = false;
  int _selectedFolderIndex = 0;

  @override
  void initState() {
    super.initState();
    _load();
    _initializeGamepad();
  }

  @override
  void dispose() {
    GamepadNavigationManager.popLayer('neo_sync_custom_folders');
    _gamepadNav.dispose();
    super.dispose();
  }

  void _initializeGamepad() {
    _gamepadNav = GamepadNavigation(
      onNavigateUp: (isRepeat) => _navigateFolders(-1),
      onNavigateDown: (isRepeat) => _navigateFolders(1),
      onPreviousTab: () => AppNavigation.previousTab(),
      onNextTab: () => AppNavigation.nextTab(),
      onBack: () {
        if (mounted) widget.onBack();
      },
      onSelectItem: _openConfigDialog,
      onSelectButton: _handleSelectFolder,
      onFavorite: _openConfigDialog,
      onSettings: () {},
    );

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _gamepadNav.initialize();
      GamepadNavigationManager.pushLayer(
        'neo_sync_custom_folders',
        onActivate: () => _gamepadNav.activate(),
        onDeactivate: () => _gamepadNav.deactivate(),
      );
    });
  }

  void _navigateFolders(int delta) {
    if (_configured.isEmpty) return;
    final newIndex =
        (_selectedFolderIndex + delta + _configured.length) %
        _configured.length;
    if (mounted) setState(() => _selectedFolderIndex = newIndex);
  }

  /// Select (View) asks for confirmation, then deletes the focused configured
  /// folder; the list is empty-only so it becomes a no-op when there is nothing
  /// configured.
  Future<void> _handleSelectFolder() async {
    if (_configured.isEmpty) {
      _openConfigDialog();
      return;
    }
    final (system, slug, _) = _configured[_selectedFolderIndex];

    _gamepadNav.deactivate();
    final confirmed = await ConfirmActionDialog.show(
      context,
      title: AppLocale.removeCustomFolder.getString(context),
      body: AppLocale.removeCustomFolderConfirm.getString(context),
      confirmLabel: AppLocale.removeCustomFolder.getString(context),
      cancelLabel: AppLocale.cancel.getString(context),
      icon: Symbols.delete_forever_rounded,
    );
    _gamepadNav.activate();

    if (confirmed != true) return;
    await _removeFolder(system, slug);
  }

  Future<void> _load() async {
    try {
      final systems = await SystemRepository.getAllSystems();
      final withEmulators = systems
          .where((s) => s.neosync.sync || s.folderName.isNotEmpty)
          .toList();
      if (mounted) setState(() => _systems = withEmulators);
    } catch (e) {
      // Non-fatal.
    }
    await _loadConfigured();
  }

  Future<void> _loadConfigured() async {
    try {
      final configured = await NeoSyncSaveFolderRepository.getAllEntries();
      if (mounted) {
        setState(() {
          _configured = configured;
          if (_selectedFolderIndex >= configured.length) {
            _selectedFolderIndex = configured.isEmpty
                ? 0
                : configured.length - 1;
          }
        });
      }
    } catch (e) {
      // ignore
    }
  }

  Future<void> _selectFolderFor(String system, String emulatorSlug) async {
    _log.i('CustomSaveFolder: picker start for $system / $emulatorSlug');
    try {
      String? selected;
      if (Platform.isAndroid) {
        final isTV = await PermissionService.isTelevision();
        if (!mounted) return;

        if (isTV) {
          selected = await TvDirectoryPicker.show(context);
        } else {
          final uri = await PermissionService.requestFolderAccess();
          if (uri != null) {
            final hasFiles = await PermissionService.hasAllFilesAccess();
            selected =
                await UserDataLocationService.resolveAndroidUserDataPath(
                  uri.toString(),
                  hasAllFilesAccess: hasFiles,
                ) ??
                UserDataLocationService.safUriToRealPath(uri.toString());
          }
        }
      } else {
        // Desktop: the SAF picker above is Android-only and returns null
        // elsewhere, which closed the dialog without opening anything (#609).
        // pickDirectory falls back to the in-app browser where no XDG portal
        // exists (SteamOS Game Mode).
        selected = await TvDirectoryPicker.pickDirectory(
          context,
          dialogTitle: AppLocale.selectFolder.getString(context),
        );
      }

      if (selected == null || !mounted) return;
      selected = selected.replaceFirst(RegExp(r'[\\/]+$'), '');
      final String folderPath = selected;
      if (!Directory(folderPath).existsSync()) {
        if (mounted) {
          custom.AppNotification.showNotification(
            context,
            AppLocale.customSaveFolderInvalid.getString(context),
            type: custom.NotificationType.error,
          );
        }
        return;
      }

      await NeoSyncSaveFolderRepository.saveFolder(
        system,
        emulatorSlug,
        folderPath,
      );
      await _loadConfigured();

      if (!mounted) return;
      final provider = context.read<NeoSyncProvider>();
      if (mounted) setState(() => _syncing = true);

      // Surface the upload progress in the app's global notification center
      // (header bell), updating the same notification in place as it runs.
      const notificationId = 'custom_save_folder_upload';
      final folderLabel = path.basename(folderPath);
      custom.AppNotification.showNotification(
        context,
        AppLocale.uploadingCustomFolder
            .getString(context)
            .replaceFirst('{folder}', folderLabel),
        type: custom.NotificationType.info,
        notificationId: notificationId,
        progress: 0,
        ongoing: true,
      );

      try {
        void listener() {
          if (!mounted) return;
          custom.AppNotification.showNotification(
            context,
            AppLocale.uploadingCustomFolder
                .getString(context)
                .replaceFirst('{folder}', folderLabel),
            type: custom.NotificationType.info,
            notificationId: notificationId,
            progress: provider.syncProgress,
            ongoing: true,
          );
        }

        provider.addListener(listener);
        try {
          await provider.syncCustomSaveFolder(system, emulatorSlug);
        } finally {
          provider.removeListener(listener);
        }

        if (!mounted) return;
        custom.AppNotification.showNotification(
          context,
          AppLocale.customFolderUploadComplete
              .getString(context)
              .replaceFirst('{uploaded}', '${provider.uploadedFiles}')
              .replaceFirst('{skipped}', '${provider.skippedFiles}'),
          type: custom.NotificationType.success,
          notificationId: notificationId,
          progress: 1,
        );
      } finally {
        if (mounted) setState(() => _syncing = false);
      }
    } catch (e, st) {
      _log.e(
        'CustomSaveFolder: error in _selectFolderFor',
        error: e,
        stackTrace: st,
      );
      if (mounted) {
        custom.AppNotification.showNotification(
          context,
          AppLocale.customFolderUploadFailed.getString(context),
          type: custom.NotificationType.error,
        );
      }
    }
  }

  Future<void> _removeFolder(String system, String emulatorSlug) async {
    await NeoSyncSaveFolderRepository.removeFolder(system, emulatorSlug);
    await _loadConfigured();
  }

  Future<void> _openConfigDialog() async {
    _gamepadNav.deactivate();
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => CustomSaveFoldersDialog(
        systems: _systems,
        isSyncing: _syncing,
        onSelectFolder: (system, slug) => _selectFolderFor(system, slug),
      ),
    );
    _gamepadNav.activate();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final busy = _syncing;

    return Padding(
      padding: EdgeInsets.only(top: 52.r, left: 8.r, right: 8.r, bottom: 8.r),
      child: Column(
        children: [
          NeoSyncSectionHeader(
            icon: Symbols.folder_special_rounded,
            title: AppLocale.customSaveFoldersTitle.getString(context),
            subtitle: AppLocale.customFoldersSubtitle.getString(context),
            trailing: Container(
              padding: EdgeInsets.symmetric(horizontal: 6.r, vertical: 2.r),
              decoration: BoxDecoration(
                color: theme.colorScheme.secondary,
                borderRadius: BorderRadius.circular(6.r),
              ),
              child: Text(
                AppLocale.foldersConfigured
                    .getString(context)
                    .replaceFirst('{count}', '${_configured.length}'),
                style: TextStyle(
                  fontSize: 8.r,
                  fontWeight: FontWeight.bold,
                  color: theme.colorScheme.onSecondary,
                ),
              ),
            ),
          ),
          SizedBox(height: 8.r),
          Expanded(
            child: Container(
              padding: EdgeInsets.all(12.r),
              decoration: BoxDecoration(
                color: theme.cardColor.withValues(alpha: 0.25),
                borderRadius: BorderRadius.circular(12.r),
                border: Border.all(
                  color: theme.colorScheme.primary.withValues(alpha: 0.15),
                  width: 1.r,
                ),
              ),
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(height: 8.r),
                    Text(
                      AppLocale.customSaveFolderConfiguredList.getString(
                        context,
                      ),
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.bold,
                        fontSize: 11.r,
                      ),
                    ),
                    SizedBox(height: 6.r),
                    if (_configured.isEmpty)
                      Padding(
                        padding: EdgeInsets.all(12.r),
                        child: Center(
                          child: Column(
                            children: [
                              Icon(
                                Symbols.folder_special_rounded,
                                size: 40.r,
                                color: theme.colorScheme.onSurface.withValues(
                                  alpha: 0.4,
                                ),
                              ),
                              SizedBox(height: 8.r),
                              Text(
                                AppLocale.noCustomFoldersConfigured.getString(
                                  context,
                                ),
                                style: TextStyle(
                                  fontSize: 12.r,
                                  color: theme.colorScheme.onSurface.withValues(
                                    alpha: 0.6,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      )
                    else
                      for (var i = 0; i < _configured.length; i++) ...[
                        Padding(
                          padding: EdgeInsets.only(bottom: 6.r),
                          child: Container(
                            padding: EdgeInsets.all(8.r),
                            decoration: BoxDecoration(
                              color: i == _selectedFolderIndex
                                  ? theme.colorScheme.secondary.withValues(
                                      alpha: 0.12,
                                    )
                                  : theme.colorScheme.primary.withValues(
                                      alpha: 0.05,
                                    ),
                              borderRadius: BorderRadius.circular(8.r),
                              border: Border.all(
                                color: i == _selectedFolderIndex
                                    ? theme.colorScheme.secondary.withValues(
                                        alpha: 0.6,
                                      )
                                    : theme.colorScheme.primary.withValues(
                                        alpha: 0.15,
                                      ),
                                width: i == _selectedFolderIndex ? 2.r : 1.r,
                              ),
                            ),
                            child: Row(
                              children: [
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        '${_configured[i].$1} / ${_configured[i].$2}',
                                        style: theme.textTheme.bodySmall
                                            ?.copyWith(
                                              fontWeight: FontWeight.bold,
                                              fontSize: 10.r,
                                            ),
                                      ),
                                      SizedBox(height: 2.r),
                                      Text(
                                        _configured[i].$3,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: theme.textTheme.bodySmall
                                            ?.copyWith(
                                              fontSize: 9.r,
                                              fontFamily: 'monospace',
                                              color: theme.colorScheme.onSurface
                                                  .withValues(alpha: 0.7),
                                            ),
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ],
                  ],
                ),
              ),
            ),
          ),
          SizedBox(height: 6.r),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              GamepadControl(
                label: AppLocale.customSaveFolderConfigure.getString(context),
                iconPath: 'assets/images/gamepad/Xbox_Y_button.png',
                onTap: busy ? null : _openConfigDialog,
                textColor: theme.colorScheme.onTertiaryFixed,
                backgroundColor: theme.colorScheme.tertiaryFixed,
              ),
              SizedBox(width: 8.r),
              GamepadControl(
                label: AppLocale.delete.getString(context),
                iconPath: 'assets/images/gamepad/Xbox_View_button.png',
                onTap: busy ? null : () => _handleSelectFolder(),
                textColor: theme.colorScheme.onError,
                backgroundColor: theme.colorScheme.error,
              ),
              SizedBox(width: 8.r),
              NeoSyncBackButton(onTap: () => widget.onBack()),
            ],
          ),
        ],
      ),
    );
  }
}
