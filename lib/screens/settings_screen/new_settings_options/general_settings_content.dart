import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:neostation/l10n/app_locale.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:provider/provider.dart';
import 'package:window_manager/window_manager.dart';
import 'package:fullscreen_window/fullscreen_window.dart';
import 'package:neostation/services/logger_service.dart';
import 'package:neostation/utils/adaptive_scroll.dart';
import 'package:neostation/utils/nav_tabs.dart';
import '../../../providers/sqlite_config_provider.dart';
import '../../../repositories/retro_achievements_repository.dart';
import '../../../repositories/system_repository.dart';
import '../../../widgets/info_dialog.dart';
import '../../../widgets/custom_toggle_switch.dart';
import 'settings_title.dart';
import 'widgets/setting_row.dart';
import 'widgets/setting_value_chip.dart';
import 'widgets/language_picker_overlay.dart';
import '../../../services/permission_service.dart';
import '../../../services/sfx_service.dart';

/// A specialized content panel for system-wide configuration, including platform-specific orchestration (Windows/Android/Linux).
///
/// Manages high-level preferences such as background scanning, SFX feedback,
/// localization, and native hardware features (Fullscreen, Launcher mode, Multi-display).
class GeneralSettingsContent extends StatefulWidget {
  final bool isContentFocused;
  final int selectedContentIndex;
  final Function(bool) onFullscreenToggle;

  const GeneralSettingsContent({
    super.key,
    required this.isContentFocused,
    required this.selectedContentIndex,
    required this.onFullscreenToggle,
  });

  @override
  State<GeneralSettingsContent> createState() => GeneralSettingsContentState();
}

class GeneralSettingsContentState extends State<GeneralSettingsContent>
    with WidgetsBindingObserver {
  bool _isDefaultLauncher = false;

  static final _log = LoggerService.instance;

  final ScrollController _scrollController = ScrollController();

  /// Keys for scroll-into-view orchestration during gamepad navigation.
  final List<GlobalKey> _itemKeys = [];

  /// Snaps during rapid D-pad navigation, animates on a single move.
  final AdaptiveScroller _scroller = AdaptiveScroller();

  /// The UI sound volume stops the SFX volume row cycles through, quietest
  /// first. The last entry is the level the app has always played at.
  static const List<double> _sfxVolumeCycle = [
    SfxService.maxVolume / 3,
    SfxService.maxVolume * 2 / 3,
    SfxService.maxVolume,
  ];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _loadFullscreenState();
    _checkDefaultLauncher();

    // Pre-allocate keys for maximum theoretical setting items (the fixed rows
    // plus one per navigation tab that can be toggled).
    for (int i = 0; i < 17 + NavTab.values.length; i++) {
      _itemKeys.add(GlobalKey());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _scrollController.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Platform: Android - Refresh critical permission and launcher states upon resume.
    if (state == AppLifecycleState.resumed && Platform.isAndroid) {
      Future.delayed(const Duration(milliseconds: 500), () {
        if (!mounted) return;
        _checkDefaultLauncher();
        context.read<SqliteConfigProvider>().refreshAllFilesAccess();
      });
    }
  }

  /// Sychronizes the native window state with persistent preferences.
  Future<void> _loadFullscreenState() async {
    if (!kIsWeb &&
        (Platform.isWindows || Platform.isLinux || Platform.isMacOS)) {
      try {
        final isFullscreen = context.read<SqliteConfigProvider>().isFullscreen;
        if (Platform.isMacOS) {
          await windowManager.setFullScreen(isFullscreen);
        } else {
          FullScreenWindow.setFullScreen(isFullscreen);
        }
      } catch (e) {
        _log.e('Failed to synchronize native fullscreen state: $e');
      }
    }
  }

  /// Toggles the native window display mode (Desktop Platforms).
  Future<void> _toggleFullscreen(bool value) async {
    if (!kIsWeb &&
        (Platform.isWindows || Platform.isLinux || Platform.isMacOS)) {
      try {
        await context.read<SqliteConfigProvider>().updateIsFullscreen(value);
        if (Platform.isMacOS) {
          await windowManager.setFullScreen(value);
        } else {
          FullScreenWindow.setFullScreen(value);
        }
        widget.onFullscreenToggle(value);
      } catch (e) {
        _log.e('Fullscreen state transition failed: $e');
      }
    }
  }

  /// Platform: Android - Verifies if the application is registered as the system-default launcher.
  Future<void> _checkDefaultLauncher() async {
    if (Platform.isAndroid) {
      try {
        const platform = MethodChannel('com.neogamelab.neostation/launcher');
        final isDefault =
            await platform.invokeMethod<bool>('isDefaultLauncher') ?? false;
        setState(() {
          _isDefaultLauncher = isDefault;
        });
      } catch (e) {
        _log.e('Launcher status check failed: $e');
        setState(() {
          _isDefaultLauncher = false;
        });
      }
    }
  }

  /// Platform: Android - Orchestrates the 'All Files Access' permission flow.
  Future<void> _handlePermissionToggle(SqliteConfigProvider provider) async {
    if (provider.hasAllFilesAccess) {
      // If access is already granted, navigate the user to system settings for manual revocation.
      await PermissionService.openAllFilesAccessSettings();
    } else {
      // Initiation of the platform-specific permission request flow.
      final success = await PermissionService.requestAllFilesAccess();
      if (success) {
        provider.refreshAllFilesAccess();
      }
    }
  }

  /// Platform: Android - Triggers the system-default launcher selection activity.
  Future<void> _toggleLauncher(bool value) async {
    if (Platform.isAndroid) {
      try {
        const platform = MethodChannel('com.neogamelab.neostation/launcher');
        await platform.invokeMethod('openLauncherSettings');
      } catch (e) {
        _log.e('Launcher settings activity could not be resolved: $e');
      }
    }
  }

  /// Platform: Android - Triggers the native system settings activity.
  Future<void> _openSystemSettings() async {
    if (Platform.isAndroid) {
      try {
        const platform = MethodChannel('com.neogamelab.neostation/launcher');
        await platform.invokeMethod('openSystemSettings');
      } catch (e) {
        _log.e('System settings activity could not be resolved: $e');
      }
    }
  }

  /// Dynamic Item Resolution: Calculates the total setting items available for the current platform/configuration.
  int getItemCount() {
    int count = 0;
    if (Platform.isAndroid) {
      count++; // System Settings
    }
    count++; // Scan on Startup
    count++; // Ignore hidden files in scan
    count++; // Auto-update App
    count++; // Auto-update Systems
    count++; // SFX Sounds
    count++; // SFX volume (dimmed, but still navigable, while SFX are off)
    count++; // 12-Hour Clock
    count++; // Show subfolders (every system)
    count++; // Cloud-save mark in the game views
    count++; // Achievement badges on game tiles
    count++; // Match RetroAchievements on startup
    if (Platform.isAndroid) {
      count++; // Android Apps layout
    }
    count += hidableNavTabs().length; // Navigation tab visibility
    count++; // Language
    if (!kIsWeb &&
        (Platform.isWindows || Platform.isLinux || Platform.isMacOS)) {
      count++; // Fullscreen
    }
    if (Platform.isAndroid) {
      count++; // All Files Access
      count++; // Launcher
      count++; // Secondary Display Suppression (always visible on Android)
    }
    if (!kIsWeb && (Platform.isWindows || Platform.isLinux)) {
      count++; // BarTOP Power Management
    }
    return count;
  }

  /// Selection Dispatcher: Executes the action associated with the specified setting index.
  /// ROMs left to hash before the startup pass is worth warning about.
  ///
  /// The pass runs at roughly 20-60 ROMs a second depending on how large the
  /// files are, so a few hundred is a few seconds and not worth interrupting
  /// anyone for. Thousands is minutes, and minutes of it is what the Tools
  /// matcher exists to do properly, with a progress bar and somebody watching.
  static const int _raBacklogWarnThreshold = 500;

  /// Writes the startup-match toggle, warning first when switching it on would
  /// leave a large backlog for the next launch.
  ///
  /// The toggle is for keeping an already-matched library up to date as ROMs
  /// are added. Enabling it on a library that has never been matched instead
  /// hands the next launch the whole job, so this points at the Tools matcher
  /// rather than letting people discover the cost on their next start. It is
  /// advice, not a gate: the setting is written either way.
  Future<void> _setRaMatchOnStartup(bool value) async {
    final configProvider = context.read<SqliteConfigProvider>();
    if (!value) {
      configProvider.updateRaMatchOnStartup(false);
      return;
    }

    final coverage = await RetroAchievementsRepository.getRaHashCoverage();
    final backlog = coverage.eligible - coverage.hashed;
    if (!mounted) return;
    configProvider.updateRaMatchOnStartup(true);

    if (backlog < _raBacklogWarnThreshold) return;
    await InfoDialog.show(
      context,
      title: AppLocale.raMatchOnStartup.getString(context),
      body: AppLocale.raMatchOnStartupBacklogWarning
          .getString(context)
          .replaceFirst('{count}', backlog.toString()),
      okLabel: AppLocale.ok.getString(context),
      icon: Symbols.trophy_rounded,
    );
  }

  /// Flips the global "Show Subfolders" switch and applies it to every system.
  ///
  /// Systems that carried a setting of their own are overwritten by the stamp,
  /// so they are counted first — after the write every system reads the same
  /// and the information is gone. Like the RetroAchievements toggle above this
  /// is advice, not a gate: the setting is written either way.
  Future<void> _setSubfolderViewAll(bool value) async {
    final configProvider = context.read<SqliteConfigProvider>();
    final overridden = await SystemRepository.countSubfolderViewOverrides(
      configProvider.config.subfolderViewAll,
    );
    if (!mounted) return;
    await configProvider.updateSubfolderViewAll(value);
    if (!mounted || overridden == 0) return;

    await InfoDialog.show(
      context,
      title: AppLocale.subfolderViewAll.getString(context),
      body: AppLocale.subfolderViewAllOverridesNotice
          .getString(context)
          .replaceFirst('{count}', overridden.toString()),
      okLabel: AppLocale.ok.getString(context),
      icon: Symbols.folder_rounded,
    );
  }

  void selectItem(int index) {
    SfxService().playNavSound();
    int currentItemIndex = 0;
    final configProvider = context.read<SqliteConfigProvider>();

    // Protocol: Native Android Settings.
    if (Platform.isAndroid) {
      if (index == currentItemIndex) {
        _openSystemSettings();
        return;
      }
      currentItemIndex++;
    }

    // Protocol: Background ROM Scanning.
    if (index == currentItemIndex) {
      final scanOnStartup = configProvider.config.scanOnStartup;
      configProvider.updateScanOnStartup(!scanOnStartup);
      return;
    }
    currentItemIndex++;

    // Protocol: Ignore hidden files in scan.
    if (index == currentItemIndex) {
      final ignoreHiddenFiles = configProvider.config.ignoreHiddenFiles;
      configProvider.updateIgnoreHiddenFiles(!ignoreHiddenFiles);
      return;
    }
    currentItemIndex++;

    // Protocol: Auto-update App.
    if (index == currentItemIndex) {
      configProvider.updateAutoUpdateApp(!configProvider.config.autoUpdateApp);
      return;
    }
    currentItemIndex++;

    // Protocol: Auto-update Systems.
    if (index == currentItemIndex) {
      configProvider.updateAutoUpdateSystems(
        !configProvider.config.autoUpdateSystems,
      );
      return;
    }
    currentItemIndex++;

    // Protocol: Interface Sound Effects.
    if (index == currentItemIndex) {
      final sfxEnabled = configProvider.config.sfxEnabled;
      configProvider.updateSfxEnabled(!sfxEnabled);
      return;
    }
    currentItemIndex++;

    // Protocol: Interface Sound Effects Volume. The row stays navigable while
    // SFX are off so the setting is still discoverable, but selecting it then
    // does nothing — there is no level to hear.
    if (index == currentItemIndex) {
      if (configProvider.config.sfxEnabled) {
        _cycleSfxVolume(configProvider);
      }
      return;
    }
    currentItemIndex++;

    // Protocol: 12-Hour Clock Format.
    if (index == currentItemIndex) {
      configProvider.updateUse12HourClock(
        !configProvider.config.use12HourClock,
      );
      return;
    }
    currentItemIndex++;

    // Protocol: Show subfolders, applied to every system.
    if (index == currentItemIndex) {
      _setSubfolderViewAll(!configProvider.config.subfolderViewAll);
      return;
    }
    currentItemIndex++;

    // Protocol: Cloud-save mark in the game views.
    if (index == currentItemIndex) {
      configProvider.updateShowCloudSyncIcon(
        !configProvider.config.showCloudSyncIcon,
      );
      return;
    }
    currentItemIndex++;

    // Protocol: Achievement badges on game tiles.
    if (index == currentItemIndex) {
      configProvider.updateShowAchievementsBadge(
        !configProvider.config.showAchievementsBadge,
      );
      return;
    }
    currentItemIndex++;

    // Protocol: Match RetroAchievements after the startup scan.
    if (index == currentItemIndex) {
      _setRaMatchOnStartup(!configProvider.config.raMatchOnStartup);
      return;
    }
    currentItemIndex++;

    // Protocol: Android apps appear as either a System card or a root tab.
    if (Platform.isAndroid) {
      if (index == currentItemIndex) {
        configProvider.updateAndroidAppsAsTab(
          !configProvider.config.androidAppsAsTab,
        );
        return;
      }
      currentItemIndex++;
    }

    // Protocol: Navigation Tab Visibility (one entry per hidable tab, in the
    // same order the rows are built below).
    for (final tab in hidableNavTabs()) {
      if (index == currentItemIndex) {
        final hidden =
            navTabSpec(tab).hidden?.call(configProvider.config) ?? false;
        configProvider.updateNavTabHidden(tab, !hidden);
        return;
      }
      currentItemIndex++;
    }

    // Protocol: Localization Selection.
    if (index == currentItemIndex) {
      _showLanguagePicker(context, _itemKeys[currentItemIndex]);
      return;
    }
    currentItemIndex++;

    // Protocol: Native Windowing (Desktop).
    if (!kIsWeb &&
        (Platform.isWindows || Platform.isLinux || Platform.isMacOS)) {
      if (index == currentItemIndex) {
        final isFullscreen = configProvider.isFullscreen;
        _toggleFullscreen(!isFullscreen);
        return;
      }
      currentItemIndex++;
    }

    // Protocol: Android Permissions & Launcher Lifecycle.
    if (Platform.isAndroid) {
      if (index == currentItemIndex) {
        _handlePermissionToggle(configProvider);
        return;
      }
      currentItemIndex++;

      if (index == currentItemIndex) {
        _toggleLauncher(!_isDefaultLauncher);
        return;
      }
      currentItemIndex++;

      if (index == currentItemIndex) {
        final hideBottomScreen = configProvider.config.hideBottomScreen;
        configProvider.updateHideBottomScreen(
          !hideBottomScreen,
          backgroundColor: Theme.of(context).scaffoldBackgroundColor.toARGB32(),
        );
        return;
      }
      currentItemIndex++;
    }

    // Protocol: BarTOP Power Management (System Shutdown).
    if (!kIsWeb && (Platform.isWindows || Platform.isLinux)) {
      if (index == currentItemIndex) {
        final bartopExitPoweroff = configProvider.config.bartopExitPoweroff;
        configProvider.updateBartopExitPoweroff(!bartopExitPoweroff);
        return;
      }
      currentItemIndex++;
    }
  }

  /// Advances the UI sound volume to the next stop and persists it, wrapping
  /// round at the loudest. If the stored value isn't on a stop — a database
  /// written by an older build, or one hand-edited — snaps to the nearest one
  /// first so the first press is never a silent no-op.
  void _cycleSfxVolume(SqliteConfigProvider provider) {
    final current = provider.config.sfxVolume;
    final index = _sfxVolumeCycle.indexWhere(
      (stop) => (stop - current).abs() < 0.001,
    );
    final next = index < 0
        ? _sfxVolumeCycle.reduce(
            (a, b) => (a - current).abs() <= (b - current).abs() ? a : b,
          )
        : _sfxVolumeCycle[(index + 1) % _sfxVolumeCycle.length];
    provider.updateSfxVolume(next);
  }

  /// The localized label for a UI sound volume stop.
  String _sfxVolumeLabel(BuildContext context, double volume) {
    final index = _sfxVolumeCycle.indexWhere(
      (stop) => (stop - volume).abs() < 0.001,
    );
    return switch (index) {
      0 => AppLocale.sfxVolumeLow.getString(context),
      1 => AppLocale.sfxVolumeMedium.getString(context),
      _ => AppLocale.sfxVolumeHigh.getString(context),
    };
  }

  /// Synchronizes the scroll viewport with the currently focused setting item.
  void scrollToIndex(int index) {
    _scroller.ensureVisibleIndex(
      index,
      keys: _itemKeys,
      controller: _scrollController,
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final provider = context.watch<SqliteConfigProvider>();
    final config = provider.config;
    int currentItemIdx = 0;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Pinned header — stays put while the settings list scrolls beneath it.
        SettingsTitle(title: AppLocale.generalSettings.getString(context)),
        SizedBox(height: 12.r),
        Expanded(
          child: SingleChildScrollView(
            controller: _scrollController,
            physics: const ClampingScrollPhysics(),
            padding: EdgeInsets.only(bottom: 24.r),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Setting: System Settings (Android only).
                if (Platform.isAndroid) ...[
                  () {
                    final index = currentItemIdx++;
                    return SettingRow(
                      key: _itemKeys[index],
                      onTap: () => selectItem(index),
                      focused:
                          widget.isContentFocused &&
                          widget.selectedContentIndex == index,
                      title: AppLocale.androidSystemSettings.getString(context),
                      subtitle: AppLocale.androidSystemSettingsSubtitle
                          .getString(context),
                      trailing: Icon(
                        Symbols.open_in_new_rounded,
                        size: 18.r,
                        color: theme.colorScheme.onSurface.withValues(
                          alpha: 0.7,
                        ),
                      ),
                    );
                  }(),
                  SizedBox(height: 12.r),
                ],

                // Setting: Scan on Startup.
                () {
                  final index = currentItemIdx++;
                  return SettingRow(
                    key: _itemKeys[index],
                    onTap: () => selectItem(index),
                    focused:
                        widget.isContentFocused &&
                        widget.selectedContentIndex == index,
                    title: AppLocale.scanOnStartup.getString(context),
                    subtitle: AppLocale.scanOnStartupSubtitle.getString(
                      context,
                    ),
                    trailing: CustomToggleSwitch(
                      value: config.scanOnStartup,
                      onChanged: (value) {
                        context
                            .read<SqliteConfigProvider>()
                            .updateScanOnStartup(value);
                      },
                      activeColor: theme.colorScheme.primary,
                    ),
                  );
                }(),

                // Setting: Ignore hidden files in scan.
                SizedBox(height: 12.r),
                () {
                  final index = currentItemIdx++;
                  return SettingRow(
                    key: _itemKeys[index],
                    onTap: () => selectItem(index),
                    focused:
                        widget.isContentFocused &&
                        widget.selectedContentIndex == index,
                    title: AppLocale.ignoreHiddenFiles.getString(context),
                    subtitle: AppLocale.ignoreHiddenFilesSubtitle.getString(
                      context,
                    ),
                    trailing: CustomToggleSwitch(
                      value: config.ignoreHiddenFiles,
                      onChanged: (value) {
                        context
                            .read<SqliteConfigProvider>()
                            .updateIgnoreHiddenFiles(value);
                      },
                      activeColor: theme.colorScheme.primary,
                    ),
                  );
                }(),

                // Setting: Auto-update App.
                SizedBox(height: 12.r),
                () {
                  final index = currentItemIdx++;
                  return SettingRow(
                    key: _itemKeys[index],
                    onTap: () => selectItem(index),
                    focused:
                        widget.isContentFocused &&
                        widget.selectedContentIndex == index,
                    title: AppLocale.autoUpdateApp.getString(context),
                    subtitle: AppLocale.autoUpdateAppSubtitle.getString(
                      context,
                    ),
                    trailing: CustomToggleSwitch(
                      value: config.autoUpdateApp,
                      onChanged: (value) {
                        context
                            .read<SqliteConfigProvider>()
                            .updateAutoUpdateApp(value);
                      },
                      activeColor: theme.colorScheme.primary,
                    ),
                  );
                }(),

                // Setting: Auto-update Systems & Emulators.
                SizedBox(height: 12.r),
                () {
                  final index = currentItemIdx++;
                  return SettingRow(
                    key: _itemKeys[index],
                    onTap: () => selectItem(index),
                    focused:
                        widget.isContentFocused &&
                        widget.selectedContentIndex == index,
                    title: AppLocale.autoUpdateSystems.getString(context),
                    subtitle: AppLocale.autoUpdateSystemsSubtitle.getString(
                      context,
                    ),
                    trailing: CustomToggleSwitch(
                      value: config.autoUpdateSystems,
                      onChanged: (value) {
                        context
                            .read<SqliteConfigProvider>()
                            .updateAutoUpdateSystems(value);
                      },
                      activeColor: theme.colorScheme.primary,
                    ),
                  );
                }(),

                // Setting: SFX Feedback.
                SizedBox(height: 12.r),
                () {
                  final index = currentItemIdx++;
                  return SettingRow(
                    key: _itemKeys[index],
                    onTap: () => selectItem(index),
                    focused:
                        widget.isContentFocused &&
                        widget.selectedContentIndex == index,
                    title: AppLocale.sfxSounds.getString(context),
                    subtitle: AppLocale.sfxSoundsSubtitle.getString(context),
                    trailing: CustomToggleSwitch(
                      value: config.sfxEnabled,
                      onChanged: (value) {
                        context.read<SqliteConfigProvider>().updateSfxEnabled(
                          value,
                        );
                      },
                      activeColor: theme.colorScheme.primary,
                    ),
                  );
                }(),

                // Setting: SFX Volume. Only meaningful when SFX are on, so it
                // greys out and ignores input while they are off — the same
                // treatment Secondary Screen gives its dependent value rows.
                SizedBox(height: 12.r),
                () {
                  final index = currentItemIdx++;
                  return Opacity(
                    opacity: config.sfxEnabled ? 1.0 : 0.4,
                    child: SettingRow(
                      key: _itemKeys[index],
                      onTap: () => selectItem(index),
                      focused:
                          widget.isContentFocused &&
                          widget.selectedContentIndex == index,
                      title: AppLocale.sfxVolume.getString(context),
                      subtitle: AppLocale.sfxVolumeSubtitle.getString(context),
                      trailing: SettingValueChip(
                        text: _sfxVolumeLabel(context, config.sfxVolume),
                      ),
                    ),
                  );
                }(),

                // Setting: 12-Hour Clock Format.
                SizedBox(height: 12.r),
                () {
                  final index = currentItemIdx++;
                  return SettingRow(
                    key: _itemKeys[index],
                    onTap: () => selectItem(index),
                    focused:
                        widget.isContentFocused &&
                        widget.selectedContentIndex == index,
                    title: AppLocale.use12HourClock.getString(context),
                    subtitle: AppLocale.use12HourClockSubtitle.getString(
                      context,
                    ),
                    trailing: CustomToggleSwitch(
                      value: config.use12HourClock,
                      onChanged: (value) {
                        context
                            .read<SqliteConfigProvider>()
                            .updateUse12HourClock(value);
                      },
                      activeColor: theme.colorScheme.primary,
                    ),
                  );
                }(),

                // Setting: Show subfolders, applied to every system. The
                // per-system toggle in a system's settings dialog stays
                // available; this stamps them all at once.
                SizedBox(height: 12.r),
                () {
                  final index = currentItemIdx++;
                  return SettingRow(
                    key: _itemKeys[index],
                    onTap: () => selectItem(index),
                    focused:
                        widget.isContentFocused &&
                        widget.selectedContentIndex == index,
                    title: AppLocale.subfolderViewAll.getString(context),
                    subtitle: AppLocale.subfolderViewAllSubtitle.getString(
                      context,
                    ),
                    trailing: CustomToggleSwitch(
                      value: config.subfolderViewAll,
                      onChanged: _setSubfolderViewAll,
                      activeColor: theme.colorScheme.primary,
                    ),
                  );
                }(),

                // Setting: Cloud-save mark in the game views.
                SizedBox(height: 12.r),
                () {
                  final index = currentItemIdx++;
                  return SettingRow(
                    key: _itemKeys[index],
                    onTap: () => selectItem(index),
                    focused:
                        widget.isContentFocused &&
                        widget.selectedContentIndex == index,
                    title: AppLocale.showCloudSyncIcon.getString(context),
                    subtitle: AppLocale.showCloudSyncIconSubtitle.getString(
                      context,
                    ),
                    trailing: CustomToggleSwitch(
                      value: config.showCloudSyncIcon,
                      onChanged: (value) {
                        context
                            .read<SqliteConfigProvider>()
                            .updateShowCloudSyncIcon(value);
                      },
                      activeColor: theme.colorScheme.primary,
                    ),
                  );
                }(),

                // Setting: Achievement badges on game tiles.
                SizedBox(height: 12.r),
                () {
                  final index = currentItemIdx++;
                  return SettingRow(
                    key: _itemKeys[index],
                    onTap: () => selectItem(index),
                    focused:
                        widget.isContentFocused &&
                        widget.selectedContentIndex == index,
                    title: AppLocale.showAchievementsBadge.getString(context),
                    subtitle: AppLocale.showAchievementsBadgeSubtitle.getString(
                      context,
                    ),
                    trailing: CustomToggleSwitch(
                      value: config.showAchievementsBadge,
                      onChanged: (value) {
                        context
                            .read<SqliteConfigProvider>()
                            .updateShowAchievementsBadge(value);
                      },
                      activeColor: theme.colorScheme.primary,
                    ),
                  );
                }(),

                // Setting: Match RetroAchievements after the startup scan.
                SizedBox(height: 12.r),
                () {
                  final index = currentItemIdx++;
                  return SettingRow(
                    key: _itemKeys[index],
                    onTap: () => selectItem(index),
                    focused:
                        widget.isContentFocused &&
                        widget.selectedContentIndex == index,
                    title: AppLocale.raMatchOnStartup.getString(context),
                    subtitle: AppLocale.raMatchOnStartupSubtitle.getString(
                      context,
                    ),
                    trailing: CustomToggleSwitch(
                      value: config.raMatchOnStartup,
                      onChanged: _setRaMatchOnStartup,
                      activeColor: theme.colorScheme.primary,
                    ),
                  );
                }(),

                // Setting: Android Apps location. This moves the existing
                // virtual system into a top-level tab without changing the
                // default Systems experience.
                if (Platform.isAndroid) ...[
                  SizedBox(height: 12.r),
                  () {
                    final index = currentItemIdx++;
                    return SettingRow(
                      key: _itemKeys[index],
                      onTap: () => selectItem(index),
                      focused:
                          widget.isContentFocused &&
                          widget.selectedContentIndex == index,
                      title: AppLocale.androidAppLayout.getString(context),
                      subtitle: AppLocale.androidAppLayoutSubtitle.getString(
                        context,
                      ),
                      trailing: SettingValueChip(
                        text:
                            (config.androidAppsAsTab
                                    ? AppLocale.androidAppLayoutTab
                                    : AppLocale.androidAppLayoutSystem)
                                .getString(context),
                      ),
                    );
                  }(),
                ],

                // Setting: Navigation Tab Visibility — one row per hidable tab,
                // so a future tab gets its toggle from its NavTabSpec alone.
                for (final tab in hidableNavTabs()) ...[
                  SizedBox(height: 12.r),
                  () {
                    final index = currentItemIdx++;
                    final spec = navTabSpec(tab);
                    final titleKey = spec.settingsTitleKey;
                    final hidden = spec.hidden?.call(config) ?? false;
                    return SettingRow(
                      key: _itemKeys[index],
                      onTap: () => selectItem(index),
                      focused:
                          widget.isContentFocused &&
                          widget.selectedContentIndex == index,
                      title: (titleKey ?? spec.labelKey).getString(context),
                      subtitle:
                          spec.settingsSubtitleKey?.getString(context) ?? '',
                      // The switch reads as "shown"; the config stores "hidden".
                      trailing: CustomToggleSwitch(
                        value: !hidden,
                        onChanged: (value) {
                          context
                              .read<SqliteConfigProvider>()
                              .updateNavTabHidden(tab, !value);
                        },
                        activeColor: theme.colorScheme.primary,
                      ),
                    );
                  }(),
                ],

                // Setting: Localization & Language.
                SizedBox(height: 12.r),
                () {
                  final index = currentItemIdx++;
                  return SettingRow(
                    key: _itemKeys[index],
                    onTap: () => selectItem(index),
                    focused:
                        widget.isContentFocused &&
                        widget.selectedContentIndex == index,
                    title: AppLocale.language.getString(context),
                    subtitle: AppLocale.languageSub.getString(context),
                    trailing: SettingValueChip(
                      text:
                          AppLocale.supportedLanguages[config.appLanguage] ??
                          config.appLanguage,
                      trailingIcon: Symbols.arrow_drop_down_rounded,
                    ),
                  );
                }(),

                // Setting: Native Fullscreen (Desktop Platforms).
                if (!kIsWeb &&
                    (Platform.isWindows ||
                        Platform.isLinux ||
                        Platform.isMacOS)) ...[
                  SizedBox(height: 12.r),
                  () {
                    final index = currentItemIdx++;
                    return SettingRow(
                      key: _itemKeys[index],
                      onTap: () => selectItem(index),
                      expandTitle: false,
                      focused:
                          widget.isContentFocused &&
                          widget.selectedContentIndex == index,
                      title: AppLocale.fullscreenMode.getString(context),
                      subtitle: AppLocale.fullscreenModeSubtitle.getString(
                        context,
                      ),
                      trailing: CustomToggleSwitch(
                        value: provider.isFullscreen,
                        onChanged: _toggleFullscreen,
                        activeColor: theme.colorScheme.primary,
                      ),
                    );
                  }(),
                ],

                // Setting: Filesystem Access & Launcher (Android).
                if (Platform.isAndroid) ...[
                  SizedBox(height: 12.r),
                  () {
                    final index = currentItemIdx++;
                    return SettingRow(
                      key: _itemKeys[index],
                      onTap: () => selectItem(index),
                      focused:
                          widget.isContentFocused &&
                          widget.selectedContentIndex == index,
                      title: AppLocale.allFilesAccess.getString(context),
                      subtitle: '',
                      subtitleWidget: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            provider.hasAllFilesAccess
                                ? AppLocale.permissionGranted.getString(context)
                                : AppLocale.permissionDisabled.getString(
                                    context,
                                  ),
                            style: theme.textTheme.bodyMedium?.copyWith(
                              fontSize: 9.r,
                              fontWeight: FontWeight.bold,
                              color: provider.hasAllFilesAccess
                                  ? Colors.green
                                  : Colors.red,
                            ),
                          ),
                          SizedBox(height: 2.r),
                          Text(
                            AppLocale.allFilesAccessSubtitle.getString(context),
                            style: theme.textTheme.bodyMedium?.copyWith(
                              fontSize: 8.r,
                              color: theme.colorScheme.onSurface.withValues(
                                alpha: 0.5,
                              ),
                            ),
                          ),
                        ],
                      ),
                      trailing: CustomToggleSwitch(
                        value: provider.hasAllFilesAccess,
                        onChanged: (value) => _handlePermissionToggle(provider),
                        activeColor: theme.colorScheme.primary,
                      ),
                    );
                  }(),
                  SizedBox(height: 12.r),

                  () {
                    final index = currentItemIdx++;
                    return SettingRow(
                      key: _itemKeys[index],
                      onTap: () => selectItem(index),
                      focused:
                          widget.isContentFocused &&
                          widget.selectedContentIndex == index,
                      title: AppLocale.defaultLauncher.getString(context),
                      subtitle: _isDefaultLauncher
                          ? AppLocale.isDefaultLauncher.getString(context)
                          : AppLocale.setAsDefaultLauncher.getString(context),
                      trailing: CustomToggleSwitch(
                        value: _isDefaultLauncher,
                        onChanged: _toggleLauncher,
                        activeColor: theme.colorScheme.primary,
                      ),
                    );
                  }(),
                  SizedBox(height: 12.r),
                ],

                // Setting: Secondary Display Suppression (Android Multi-Display).
                if (Platform.isAndroid) ...[
                  () {
                    final index = currentItemIdx++;
                    return SettingRow(
                      key: _itemKeys[index],
                      onTap: () => selectItem(index),
                      focused:
                          widget.isContentFocused &&
                          widget.selectedContentIndex == index,
                      title: AppLocale.disableSecondaryScreen.getString(
                        context,
                      ),
                      subtitle: AppLocale.disableSecondaryScreenSub.getString(
                        context,
                      ),
                      trailing: CustomToggleSwitch(
                        value: config.hideBottomScreen,
                        onChanged: (value) {
                          provider.updateHideBottomScreen(
                            value,
                            backgroundColor: theme.scaffoldBackgroundColor
                                .toARGB32(),
                          );
                        },
                        activeColor: theme.colorScheme.primary,
                      ),
                    );
                  }(),
                ],

                // Setting: BarTOP Shutdown (Windows/Linux Power Management).
                if (!kIsWeb && (Platform.isWindows || Platform.isLinux)) ...[
                  SizedBox(height: 12.r),
                  () {
                    final index = currentItemIdx++;
                    return SettingRow(
                      key: _itemKeys[index],
                      onTap: () => selectItem(index),
                      focused:
                          widget.isContentFocused &&
                          widget.selectedContentIndex == index,
                      title: AppLocale.bartopShutdown.getString(context),
                      subtitle: AppLocale.bartopShutdownSubtitle.getString(
                        context,
                      ),
                      trailing: CustomToggleSwitch(
                        value: config.bartopExitPoweroff,
                        onChanged: (value) {
                          context
                              .read<SqliteConfigProvider>()
                              .updateBartopExitPoweroff(value);
                        },
                        activeColor: theme.colorScheme.primary,
                      ),
                    );
                  }(),
                ],
              ],
            ),
          ),
        ),
      ],
    );
  }

  /// Displays an autonomous overlay for selecting the application language.
  void _showLanguagePicker(BuildContext ctx, GlobalKey rowKey) async {
    final RenderBox? box =
        rowKey.currentContext?.findRenderObject() as RenderBox?;
    final Offset offset = box?.localToGlobal(Offset.zero) ?? const Offset(0, 0);
    final Size size = box?.size ?? Size.zero;

    final configProvider = ctx.read<SqliteConfigProvider>();
    final currentLang = configProvider.config.appLanguage;

    final result = await showGeneralDialog<String>(
      context: ctx,
      barrierDismissible: true,
      barrierLabel: 'Language Picker',
      barrierColor: Colors.transparent,
      pageBuilder: (context, animation, _) {
        return FadeTransition(
          opacity: animation,
          child: LanguagePickerOverlay(
            anchorOffset: offset + Offset(size.width, size.height / 2),
            currentLang: currentLang,
          ),
        );
      },
    );

    if (result != null && mounted) {
      context.read<SqliteConfigProvider>().updateAppLanguage(result);
    }
  }
}
