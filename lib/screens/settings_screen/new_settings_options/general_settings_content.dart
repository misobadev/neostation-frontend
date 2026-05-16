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
import 'package:neostation/services/sfx_service.dart';
import 'package:neostation/services/game_service.dart';
import 'package:neostation/utils/gamepad_nav.dart';
import '../../../providers/sqlite_config_provider.dart';
import '../../../widgets/custom_toggle_switch.dart';
import 'package:sub_screen/sub_screen.dart';
import 'settings_title.dart';
import '../../../services/permission_service.dart';

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

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _loadFullscreenState();
    _checkDefaultLauncher();
    _checkSecondDisplay();

    // Pre-allocate keys for maximum theoretical setting items.
    for (int i = 0; i < 14; i++) {
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

  bool _hasSecondDisplay = false;

  /// Platform: Android - Detects secondary display hardware for dual-screen devices (e.g. Retro consoles).
  Future<void> _checkSecondDisplay() async {
    if (Platform.isAndroid) {
      try {
        final displays = await SubScreenPlugin.getDisplays();
        if (mounted) {
          setState(() {
            _hasSecondDisplay = displays.length > 1;
          });
        }
      } catch (e) {
        _log.e('Secondary display detection failed: $e');
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

  /// Dynamic Item Resolution: Calculates the total setting items available for the current platform/configuration.
  int getItemCount() {
    int count = 0;
    count++; // Scan on Startup
    count++; // Auto-update App
    count++; // Auto-update Systems
    count++; // SFX Sounds
    count++; // Language
    if (!kIsWeb &&
        (Platform.isWindows || Platform.isLinux || Platform.isMacOS)) {
      count++; // Fullscreen
    }
    if (Platform.isAndroid) {
      count++; // All Files Access
      count++; // Launcher
      if (_hasSecondDisplay) {
        count++; // Secondary Display Suppression
      }
    }
    if (!kIsWeb && (Platform.isWindows || Platform.isLinux)) {
      count++; // BarTOP Power Management
    }
    return count;
  }

  /// Selection Dispatcher: Executes the action associated with the specified setting index.
  void selectItem(int index) {
    int currentItemIndex = 0;
    final configProvider = context.read<SqliteConfigProvider>();

    // Protocol: Background ROM Scanning.
    if (index == currentItemIndex) {
      final scanOnStartup = configProvider.config.scanOnStartup;
      configProvider.updateScanOnStartup(!scanOnStartup);
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

      if (_hasSecondDisplay) {
        if (index == currentItemIndex) {
          final hideBottomScreen = configProvider.config.hideBottomScreen;
          configProvider.updateHideBottomScreen(
            !hideBottomScreen,
            backgroundColor: Theme.of(
              context,
            ).scaffoldBackgroundColor.toARGB32(),
          );
          return;
        }
        currentItemIndex++;
      }
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

  /// Synchronizes the scroll viewport with the currently focused setting item.
  void scrollToIndex(int index) {
    if (index >= 0 && index < _itemKeys.length) {
      final context = _itemKeys[index].currentContext;
      if (context != null) {
        Scrollable.ensureVisible(
          context,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeInOut,
          alignment: 0.5,
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final provider = context.watch<SqliteConfigProvider>();
    final config = provider.config;
    int currentItemIdx = 0;

    return SingleChildScrollView(
      controller: _scrollController,
      physics: const ClampingScrollPhysics(),
      padding: EdgeInsets.only(bottom: 24.r),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SettingsTitle(title: AppLocale.generalSettings.getString(context)),
          SizedBox(height: 12.r),

          // Setting: Scan on Startup.
          () {
            final index = currentItemIdx++;
            return Container(
              key: _itemKeys[index],
              padding: EdgeInsets.only(
                left: 12.r,
                right: 12.r,
                top: 6.r,
                bottom: 6.r,
              ),
              decoration: BoxDecoration(
                color: theme.cardColor.withValues(alpha: 0.25),
                borderRadius: BorderRadius.circular(8.r),
                border: Border.all(
                  color:
                      widget.isContentFocused &&
                          widget.selectedContentIndex == index
                      ? theme.colorScheme.primary
                      : Colors.transparent,
                  width: 2,
                ),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          AppLocale.scanOnStartup.getString(context),
                          style: theme.textTheme.bodyLarge?.copyWith(
                            fontSize: 12.r,
                            fontWeight: FontWeight.w500,
                            color:
                                widget.isContentFocused &&
                                    widget.selectedContentIndex == index
                                ? theme.colorScheme.primary
                                : theme.colorScheme.onSurface,
                          ),
                        ),
                        SizedBox(height: 4.r),
                        Text(
                          AppLocale.scanOnStartupSubtitle.getString(context),
                          style: theme.textTheme.bodyMedium?.copyWith(
                            fontSize: 9.r,
                            color: theme.colorScheme.onSurface.withValues(
                              alpha: 0.6,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  CustomToggleSwitch(
                    value: config.scanOnStartup,
                    onChanged: (value) {
                      context.read<SqliteConfigProvider>().updateScanOnStartup(
                        value,
                      );
                    },
                    activeColor: theme.colorScheme.primary,
                  ),
                ],
              ),
            );
          }(),

          // Setting: Ignore hidden files in scan.
          SizedBox(height: 12.r),
          () {
            final index = currentItemIdx++;
            return Container(
              key: _itemKeys[index],
              padding: EdgeInsets.only(
                left: 12.r,
                right: 12.r,
                top: 6.r,
                bottom: 6.r,
              ),
              decoration: BoxDecoration(
                color: theme.cardColor.withValues(alpha: 0.25),
                borderRadius: BorderRadius.circular(8.r),
                border: Border.all(
                  color:
                      widget.isContentFocused &&
                          widget.selectedContentIndex == index
                      ? theme.colorScheme.primary
                      : Colors.transparent,
                  width: 2,
                ),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          AppLocale.ignoreHiddenFiles.getString(context),
                          style: theme.textTheme.bodyLarge?.copyWith(
                            fontSize: 12.r,
                            fontWeight: FontWeight.w500,
                            color:
                                widget.isContentFocused &&
                                    widget.selectedContentIndex == index
                                ? theme.colorScheme.primary
                                : theme.colorScheme.onSurface,
                          ),
                        ),
                        SizedBox(height: 4.r),
                        Text(
                          AppLocale.ignoreHiddenFilesSubtitle.getString(
                            context,
                          ),
                          style: theme.textTheme.bodyMedium?.copyWith(
                            fontSize: 9.r,
                            color: theme.colorScheme.onSurface.withValues(
                              alpha: 0.6,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  CustomToggleSwitch(
                    value: config.ignoreHiddenFiles,
                    onChanged: (value) {
                      context
                          .read<SqliteConfigProvider>()
                          .updateIgnoreHiddenFiles(value);
                    },
                    activeColor: theme.colorScheme.primary,
                  ),
                ],
              ),
            );
          }(),

          // Setting: Auto-update App.
          SizedBox(height: 12.r),
          () {
            final index = currentItemIdx++;
            return Container(
              key: _itemKeys[index],
              padding: EdgeInsets.only(
                left: 12.r,
                right: 12.r,
                top: 6.r,
                bottom: 6.r,
              ),
              decoration: BoxDecoration(
                color: theme.cardColor.withValues(alpha: 0.25),
                borderRadius: BorderRadius.circular(8.r),
                border: Border.all(
                  color:
                      widget.isContentFocused &&
                          widget.selectedContentIndex == index
                      ? theme.colorScheme.primary
                      : Colors.transparent,
                  width: 2,
                ),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          AppLocale.autoUpdateApp.getString(context),
                          style: theme.textTheme.bodyLarge?.copyWith(
                            fontSize: 12.r,
                            fontWeight: FontWeight.w500,
                            color:
                                widget.isContentFocused &&
                                    widget.selectedContentIndex == index
                                ? theme.colorScheme.primary
                                : theme.colorScheme.onSurface,
                          ),
                        ),
                        SizedBox(height: 4.r),
                        Text(
                          AppLocale.autoUpdateAppSubtitle.getString(context),
                          style: theme.textTheme.bodyMedium?.copyWith(
                            fontSize: 9.r,
                            color: theme.colorScheme.onSurface.withValues(
                              alpha: 0.6,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  CustomToggleSwitch(
                    value: config.autoUpdateApp,
                    onChanged: (value) {
                      context.read<SqliteConfigProvider>().updateAutoUpdateApp(
                        value,
                      );
                    },
                    activeColor: theme.colorScheme.primary,
                  ),
                ],
              ),
            );
          }(),

          // Setting: Auto-update Systems & Emulators.
          SizedBox(height: 12.r),
          () {
            final index = currentItemIdx++;
            return Container(
              key: _itemKeys[index],
              padding: EdgeInsets.only(
                left: 12.r,
                right: 12.r,
                top: 6.r,
                bottom: 6.r,
              ),
              decoration: BoxDecoration(
                color: theme.cardColor.withValues(alpha: 0.25),
                borderRadius: BorderRadius.circular(8.r),
                border: Border.all(
                  color:
                      widget.isContentFocused &&
                          widget.selectedContentIndex == index
                      ? theme.colorScheme.primary
                      : Colors.transparent,
                  width: 2,
                ),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          AppLocale.autoUpdateSystems.getString(context),
                          style: theme.textTheme.bodyLarge?.copyWith(
                            fontSize: 12.r,
                            fontWeight: FontWeight.w500,
                            color:
                                widget.isContentFocused &&
                                    widget.selectedContentIndex == index
                                ? theme.colorScheme.primary
                                : theme.colorScheme.onSurface,
                          ),
                        ),
                        SizedBox(height: 4.r),
                        Text(
                          AppLocale.autoUpdateSystemsSubtitle.getString(
                            context,
                          ),
                          style: theme.textTheme.bodyMedium?.copyWith(
                            fontSize: 9.r,
                            color: theme.colorScheme.onSurface.withValues(
                              alpha: 0.6,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  CustomToggleSwitch(
                    value: config.autoUpdateSystems,
                    onChanged: (value) {
                      context
                          .read<SqliteConfigProvider>()
                          .updateAutoUpdateSystems(value);
                    },
                    activeColor: theme.colorScheme.primary,
                  ),
                ],
              ),
            );
          }(),

          // Setting: SFX Feedback.
          SizedBox(height: 12.r),
          () {
            final index = currentItemIdx++;
            return Container(
              key: _itemKeys[index],
              padding: EdgeInsets.only(
                left: 12.r,
                right: 12.r,
                top: 6.r,
                bottom: 6.r,
              ),
              decoration: BoxDecoration(
                color: theme.cardColor.withValues(alpha: 0.25),
                borderRadius: BorderRadius.circular(8.r),
                border: Border.all(
                  color:
                      widget.isContentFocused &&
                          widget.selectedContentIndex == index
                      ? theme.colorScheme.primary
                      : Colors.transparent,
                  width: 2,
                ),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          AppLocale.sfxSounds.getString(context),
                          style: theme.textTheme.bodyLarge?.copyWith(
                            fontSize: 12.r,
                            fontWeight: FontWeight.w500,
                            color:
                                widget.isContentFocused &&
                                    widget.selectedContentIndex == index
                                ? theme.colorScheme.primary
                                : theme.colorScheme.onSurface,
                          ),
                        ),
                        SizedBox(height: 4.r),
                        Text(
                          AppLocale.sfxSoundsSubtitle.getString(context),
                          style: theme.textTheme.bodyMedium?.copyWith(
                            fontSize: 9.r,
                            color: theme.colorScheme.onSurface.withValues(
                              alpha: 0.6,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  CustomToggleSwitch(
                    value: config.sfxEnabled,
                    onChanged: (value) {
                      context.read<SqliteConfigProvider>().updateSfxEnabled(
                        value,
                      );
                    },
                    activeColor: theme.colorScheme.primary,
                  ),
                ],
              ),
            );
          }(),

          // Setting: Localization & Language.
          SizedBox(height: 12.r),
          () {
            final index = currentItemIdx++;
            return Container(
              key: _itemKeys[index],
              padding: EdgeInsets.only(
                left: 12.r,
                right: 12.r,
                top: 6.r,
                bottom: 6.r,
              ),
              decoration: BoxDecoration(
                color: theme.cardColor.withValues(alpha: 0.25),
                borderRadius: BorderRadius.circular(8.r),
                border: Border.all(
                  color:
                      widget.isContentFocused &&
                          widget.selectedContentIndex == index
                      ? theme.colorScheme.primary
                      : Colors.transparent,
                  width: 2,
                ),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          AppLocale.language.getString(context),
                          style: theme.textTheme.bodyLarge?.copyWith(
                            fontSize: 12.r,
                            fontWeight: FontWeight.w500,
                            color:
                                widget.isContentFocused &&
                                    widget.selectedContentIndex == index
                                ? theme.colorScheme.primary
                                : theme.colorScheme.onSurface,
                          ),
                        ),
                        SizedBox(height: 4.r),
                        Text(
                          AppLocale.languageSub.getString(context),
                          style: theme.textTheme.bodyMedium?.copyWith(
                            fontSize: 9.r,
                            color: theme.colorScheme.onSurface.withValues(
                              alpha: 0.6,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  GestureDetector(
                    onTap: () => _showLanguagePicker(context, _itemKeys[index]),
                    child: Container(
                      padding: EdgeInsets.symmetric(
                        horizontal: 10.r,
                        vertical: 6.r,
                      ),
                      decoration: BoxDecoration(
                        color: theme.colorScheme.primary.withValues(
                          alpha: 0.15,
                        ),
                        borderRadius: BorderRadius.circular(6.r),
                        border: Border.all(
                          color: theme.colorScheme.primary.withValues(
                            alpha: 0.4,
                          ),
                          width: 0.5.r,
                        ),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            AppLocale.supportedLanguages[config.appLanguage] ??
                                config.appLanguage,
                            style: theme.textTheme.bodyMedium?.copyWith(
                              fontSize: 9.r,
                              fontWeight: FontWeight.w400,
                              color: theme.colorScheme.primary,
                            ),
                          ),
                          SizedBox(width: 2.r),
                          Icon(
                            Symbols.arrow_drop_down_rounded,
                            size: 14.r,
                            color: theme.colorScheme.primary,
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            );
          }(),

          // Setting: Native Fullscreen (Desktop Platforms).
          if (!kIsWeb &&
              (Platform.isWindows || Platform.isLinux || Platform.isMacOS)) ...[
            SizedBox(height: 12.r),
            () {
              final index = currentItemIdx++;
              return Container(
                key: _itemKeys[index],
                padding: EdgeInsets.only(
                  left: 12.r,
                  right: 12.r,
                  top: 6.r,
                  bottom: 6.r,
                ),
                decoration: BoxDecoration(
                  color: theme.cardColor.withValues(alpha: 0.25),
                  borderRadius: BorderRadius.circular(8.r),
                  border: Border.all(
                    color:
                        widget.isContentFocused &&
                            widget.selectedContentIndex == index
                        ? theme.colorScheme.primary
                        : Colors.transparent,
                    width: 2,
                  ),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          AppLocale.fullscreenMode.getString(context),
                          style: theme.textTheme.bodyLarge?.copyWith(
                            fontSize: 12.r,
                            fontWeight: FontWeight.w500,
                            color:
                                widget.isContentFocused &&
                                    widget.selectedContentIndex == index
                                ? theme.colorScheme.primary
                                : theme.colorScheme.onSurface,
                          ),
                        ),
                        SizedBox(height: 4.r),
                        Text(
                          AppLocale.fullscreenModeSubtitle.getString(context),
                          style: theme.textTheme.bodyMedium?.copyWith(
                            fontSize: 9.r,
                            color: theme.colorScheme.onSurface.withValues(
                              alpha: 0.6,
                            ),
                          ),
                        ),
                      ],
                    ),
                    CustomToggleSwitch(
                      value: provider.isFullscreen,
                      onChanged: _toggleFullscreen,
                      activeColor: theme.colorScheme.primary,
                    ),
                  ],
                ),
              );
            }(),
          ],

          // Setting: Filesystem Access & Launcher (Android).
          if (Platform.isAndroid) ...[
            SizedBox(height: 12.r),
            () {
              final index = currentItemIdx++;
              return Container(
                key: _itemKeys[index],
                padding: EdgeInsets.only(
                  left: 12.r,
                  right: 12.r,
                  top: 6.r,
                  bottom: 6.r,
                ),
                decoration: BoxDecoration(
                  color: theme.cardColor.withValues(alpha: 0.25),
                  borderRadius: BorderRadius.circular(8.r),
                  border: Border.all(
                    color:
                        widget.isContentFocused &&
                            widget.selectedContentIndex == index
                        ? theme.colorScheme.primary
                        : Colors.transparent,
                    width: 2,
                  ),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            AppLocale.allFilesAccess.getString(context),
                            style: theme.textTheme.bodyLarge?.copyWith(
                              fontSize: 12.r,
                              fontWeight: FontWeight.w500,
                              color:
                                  widget.isContentFocused &&
                                      widget.selectedContentIndex == index
                                  ? theme.colorScheme.primary
                                  : theme.colorScheme.onSurface,
                            ),
                          ),
                          SizedBox(height: 4.r),
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
                    ),
                    CustomToggleSwitch(
                      value: provider.hasAllFilesAccess,
                      onChanged: (value) => _handlePermissionToggle(provider),
                      activeColor: theme.colorScheme.primary,
                    ),
                  ],
                ),
              );
            }(),
            SizedBox(height: 12.r),

            () {
              final index = currentItemIdx++;
              return Container(
                key: _itemKeys[index],
                padding: EdgeInsets.only(
                  left: 12.r,
                  right: 12.r,
                  top: 6.r,
                  bottom: 6.r,
                ),
                decoration: BoxDecoration(
                  color: theme.cardColor.withValues(alpha: 0.25),
                  borderRadius: BorderRadius.circular(8.r),
                  border: Border.all(
                    color:
                        widget.isContentFocused &&
                            widget.selectedContentIndex == index
                        ? theme.colorScheme.primary
                        : Colors.transparent,
                    width: 2,
                  ),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            AppLocale.defaultLauncher.getString(context),
                            style: theme.textTheme.bodyLarge?.copyWith(
                              fontSize: 12.r,
                              fontWeight: FontWeight.w500,
                              color:
                                  widget.isContentFocused &&
                                      widget.selectedContentIndex == index
                                  ? theme.colorScheme.primary
                                  : theme.colorScheme.onSurface,
                            ),
                          ),
                          SizedBox(height: 4.r),
                          Text(
                            _isDefaultLauncher
                                ? AppLocale.isDefaultLauncher.getString(context)
                                : AppLocale.setAsDefaultLauncher.getString(
                                    context,
                                  ),
                            style: theme.textTheme.bodyMedium?.copyWith(
                              fontSize: 9.r,
                              color: theme.colorScheme.onSurface.withValues(
                                alpha: 0.6,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    CustomToggleSwitch(
                      value: _isDefaultLauncher,
                      onChanged: _toggleLauncher,
                      activeColor: theme.colorScheme.primary,
                    ),
                  ],
                ),
              );
            }(),
            SizedBox(height: 12.r),
          ],

          // Setting: Secondary Display Suppression (Android Multi-Display).
          if (Platform.isAndroid && _hasSecondDisplay) ...[
            () {
              final index = currentItemIdx++;
              return Container(
                key: _itemKeys[index],
                padding: EdgeInsets.only(
                  left: 12.r,
                  right: 12.r,
                  top: 6.r,
                  bottom: 6.r,
                ),
                decoration: BoxDecoration(
                  color: theme.cardColor.withValues(alpha: 0.25),
                  borderRadius: BorderRadius.circular(8.r),
                  border: Border.all(
                    color:
                        widget.isContentFocused &&
                            widget.selectedContentIndex == index
                        ? theme.colorScheme.primary
                        : Colors.transparent,
                    width: 2,
                  ),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            AppLocale.disableSecondaryScreen.getString(context),
                            style: theme.textTheme.bodyLarge?.copyWith(
                              fontSize: 12.r,
                              fontWeight: FontWeight.w500,
                              color:
                                  widget.isContentFocused &&
                                      widget.selectedContentIndex == index
                                  ? theme.colorScheme.primary
                                  : theme.colorScheme.onSurface,
                            ),
                          ),
                          SizedBox(height: 4.r),
                          Text(
                            AppLocale.disableSecondaryScreenSub.getString(
                              context,
                            ),
                            style: theme.textTheme.bodyMedium?.copyWith(
                              fontSize: 9.r,
                              color: theme.colorScheme.onSurface.withValues(
                                alpha: 0.6,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    CustomToggleSwitch(
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
                  ],
                ),
              );
            }(),
          ],

          // Setting: BarTOP Shutdown (Windows/Linux Power Management).
          if (!kIsWeb && (Platform.isWindows || Platform.isLinux)) ...[
            SizedBox(height: 12.r),
            () {
              final index = currentItemIdx++;
              return Container(
                key: _itemKeys[index],
                padding: EdgeInsets.only(
                  left: 12.r,
                  right: 12.r,
                  top: 6.r,
                  bottom: 6.r,
                ),
                decoration: BoxDecoration(
                  color: theme.cardColor.withValues(alpha: 0.25),
                  borderRadius: BorderRadius.circular(8.r),
                  border: Border.all(
                    color:
                        widget.isContentFocused &&
                            widget.selectedContentIndex == index
                        ? theme.colorScheme.primary
                        : Colors.transparent,
                    width: 2,
                    strokeAlign: BorderSide.strokeAlignInside,
                  ),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            AppLocale.bartopShutdown.getString(context),
                            style: theme.textTheme.bodyLarge?.copyWith(
                              fontSize: 12.r,
                              fontWeight: FontWeight.w500,
                              color:
                                  widget.isContentFocused &&
                                      widget.selectedContentIndex == index
                                  ? theme.colorScheme.primary
                                  : theme.colorScheme.onSurface,
                            ),
                          ),
                          SizedBox(height: 4.r),
                          Text(
                            AppLocale.bartopShutdownSubtitle.getString(context),
                            style: theme.textTheme.bodyMedium?.copyWith(
                              fontSize: 9.r,
                              color: theme.colorScheme.onSurface.withValues(
                                alpha: 0.6,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    CustomToggleSwitch(
                      value: config.bartopExitPoweroff,
                      onChanged: (value) {
                        context
                            .read<SqliteConfigProvider>()
                            .updateBartopExitPoweroff(value);
                      },
                      activeColor: theme.colorScheme.primary,
                    ),
                  ],
                ),
              );
            }(),
          ],
        ],
      ),
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
          child: _LanguagePickerOverlay(
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

/// An autonomous gamepad-navigable overlay for language selection.
class _LanguagePickerOverlay extends StatefulWidget {
  final Offset anchorOffset;
  final String currentLang;

  const _LanguagePickerOverlay({
    required this.anchorOffset,
    required this.currentLang,
  });

  @override
  State<_LanguagePickerOverlay> createState() => _LanguagePickerOverlayState();
}

class _LanguagePickerOverlayState extends State<_LanguagePickerOverlay> {
  late GamepadNavigation _gamepadNav;
  int _selectedIndex = 0;

  static final _languages = AppLocale.supportedLanguages.entries
      .map((e) => (e.key, e.value))
      .toList();

  final List<GlobalKey> _itemKeys = List.generate(
    _languages.length,
    (_) => GlobalKey(),
  );
  final GlobalKey _colKey = GlobalKey();
  double _indicatorTop = -1;

  @override
  void initState() {
    super.initState();
    _selectedIndex = _languages.indexWhere((l) => l.$1 == widget.currentLang);
    if (_selectedIndex < 0) _selectedIndex = 0;

    _gamepadNav = GamepadNavigation(
      onNavigateUp: () {
        setState(() {
          _selectedIndex =
              (_selectedIndex - 1 + _languages.length) % _languages.length;
        });
        _updateIndicator();
        SfxService().playNavSound();
      },
      onNavigateDown: () {
        setState(() {
          _selectedIndex = (_selectedIndex + 1) % _languages.length;
        });
        _updateIndicator();
        SfxService().playNavSound();
      },
      onSelectItem: _handleSelection,
      onBack: () => Navigator.pop(context),
    );

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _gamepadNav.initialize();
      GamepadNavigationManager.pushLayer(
        'language_picker_overlay',
        onActivate: () => _gamepadNav.activate(),
        onDeactivate: () => _gamepadNav.deactivate(),
      );
      _updateIndicator();
    });
  }

  @override
  void dispose() {
    GamepadNavigationManager.popLayer('language_picker_overlay');
    _gamepadNav.dispose();
    super.dispose();
  }

  /// Calculates the visual position of the selection indicator.
  void _updateIndicator() {
    if (!mounted) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final key = _itemKeys[_selectedIndex];
      final RenderBox? box =
          key.currentContext?.findRenderObject() as RenderBox?;
      final RenderBox? colBox =
          _colKey.currentContext?.findRenderObject() as RenderBox?;
      if (box != null && colBox != null) {
        final pos = box.localToGlobal(Offset.zero, ancestor: colBox);
        setState(() => _indicatorTop = pos.dy);
      }
    });
  }

  void _handleSelection() {
    SfxService().playEnterSound();
    Navigator.pop(context, _languages[_selectedIndex].$1);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final screenSize = MediaQuery.of(context).size;
    final overlayWidth = 180.r;
    final itemHeight = 24;
    final overlayHeight = itemHeight * _languages.length + 16;

    // Anchor: Right-aligned relative to the trigger button, clamped to viewport boundaries.
    double left = widget.anchorOffset.dx - overlayWidth;
    double top = widget.anchorOffset.dy - overlayHeight.r / 1.5;
    left = left.clamp(8.0, screenSize.width - overlayWidth - 8);
    top = top.clamp(8.0, screenSize.height - overlayHeight - 8);

    return Stack(
      children: [
        Positioned(
          left: left,
          top: top,
          width: overlayWidth,
          child: Material(
            color: Colors.transparent,
            child: Container(
              padding: EdgeInsets.symmetric(vertical: 8.r),
              decoration: BoxDecoration(
                color: theme.colorScheme.surface,
                borderRadius: BorderRadius.circular(12.r),
                border: Border.all(
                  color: theme.colorScheme.primary.withValues(alpha: 0.2),
                  width: 1,
                ),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.25),
                    blurRadius: 15,
                    offset: const Offset(0, 5),
                  ),
                ],
              ),
              child: Stack(
                key: _colKey,
                children: [
                  if (_indicatorTop >= 0)
                    AnimatedPositioned(
                      duration: const Duration(milliseconds: 150),
                      curve: Curves.easeInOut,
                      top: _indicatorTop,
                      left: 6.r,
                      right: 4.r,
                      height: itemHeight.r,
                      child: Container(
                        decoration: BoxDecoration(
                          color: theme.colorScheme.primary.withValues(
                            alpha: 0.15,
                          ),
                          borderRadius: BorderRadius.circular(8.r),
                          border: Border.all(
                            color: theme.colorScheme.primary.withValues(
                              alpha: 0.3,
                            ),
                            width: 0.5.r,
                          ),
                        ),
                      ),
                    ),
                  Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: _languages.asMap().entries.map((entry) {
                      final i = entry.key;
                      final lang = entry.value;
                      final isSelected = lang.$1 == widget.currentLang;
                      return SizedBox(
                        key: _itemKeys[i],
                        height: itemHeight.r,
                        child: InkWell(
                          onTap: () {
                            setState(() => _selectedIndex = i);
                            _handleSelection();
                          },
                          onHover: (v) {
                            if (v) {
                              setState(() => _selectedIndex = i);
                              _updateIndicator();
                            }
                          },
                          focusColor: Colors.transparent,
                          hoverColor: Colors.transparent,
                          splashColor: Colors.transparent,
                          highlightColor: Colors.transparent,
                          borderRadius: BorderRadius.circular(8.r),
                          child: Padding(
                            padding: EdgeInsets.symmetric(horizontal: 12.r),
                            child: Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    lang.$2,
                                    style: TextStyle(
                                      fontSize: 10.r,
                                      color: isSelected
                                          ? theme.colorScheme.secondary
                                          : theme.colorScheme.onSurface,
                                      fontWeight: isSelected
                                          ? FontWeight.w600
                                          : FontWeight.w400,
                                    ),
                                  ),
                                ),
                                if (isSelected)
                                  Icon(
                                    Symbols.check_rounded,
                                    size: 12.r,
                                    color: theme.colorScheme.secondary,
                                  ),
                              ],
                            ),
                          ),
                        ),
                      );
                    }).toList(),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}
