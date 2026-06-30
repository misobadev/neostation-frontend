import 'dart:io';
import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:neostation/l10n/app_locale.dart';
import 'package:neostation/services/sfx_service.dart';
import 'new_settings_options/general_settings_content.dart';
import 'new_settings_options/secondary_settings_content.dart';
import 'new_settings_options/directories_settings_content.dart';
import 'new_settings_options/systems_settings_content.dart';
import 'new_settings_options/launcher_settings_content.dart';
import 'new_settings_options/about_settings_content.dart';
import 'new_settings_options/exit_settings_content.dart';
import 'new_settings_options/palette_settings_content.dart';
import 'new_settings_options/themes_settings_content.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:neostation/services/logger_service.dart';
import '../../providers/sqlite_config_provider.dart';

/// A unified Settings dashboard featuring a master-detail layout with category navigation and contextual content panels.
///
/// Implements a static delegation pattern to allow global input managers (e.g., GamepadNavigationManager)
/// to trigger navigation events across the menu and content sub-trees.
class NewSettingsScreen extends StatefulWidget {
  const NewSettingsScreen({super.key});

  @override
  State<NewSettingsScreen> createState() => _NewSettingsScreenState();

  // Static Bridge: Provides delegation targets for external input managers.
  static void navigateUp() => _currentInstance?._navigateUp();
  static void navigateDown() => _currentInstance?._navigateDown();
  static void navigateLeft() => _currentInstance?._navigateLeft();
  static void navigateRight() => _currentInstance?._navigateRight();
  static void selectCurrent() => _currentInstance?._selectItem();

  static _NewSettingsScreenState? _currentInstance;
}

class _NewSettingsScreenState extends State<NewSettingsScreen> {
  int _selectedMenuIndex = 0;
  int _selectedContentIndex = 0;

  /// Focus State: [true] indicates navigation within the category menu; [false] indicates content interaction.
  bool _focusOnMenu = true;

  static final _log = LoggerService.instance;

  final List<SettingsMenuItem> _menuItems = [];

  // Content Keys: Used for cross-component communication and scrolling orchestration.
  final GlobalKey<GeneralSettingsContentState> _generalSettingsKey =
      GlobalKey<GeneralSettingsContentState>();
  final GlobalKey<SecondarySettingsContentState> _secondarySettingsKey =
      GlobalKey<SecondarySettingsContentState>();
  final GlobalKey<PaletteSettingsContentState> _paletteSettingsKey =
      GlobalKey<PaletteSettingsContentState>();
  final GlobalKey<ThemesSettingsContentState> _themesSettingsKey =
      GlobalKey<ThemesSettingsContentState>();
  final GlobalKey<DirectoriesSettingsContentState> _directoriesSettingsKey =
      GlobalKey<DirectoriesSettingsContentState>();
  final GlobalKey<SystemsSettingsContentState> _systemsSettingsKey =
      GlobalKey<SystemsSettingsContentState>();
  final GlobalKey<AboutSettingsContentState> _aboutSettingsKey =
      GlobalKey<AboutSettingsContentState>();
  final GlobalKey<ExitSettingsContentState> _exitSettingsKey =
      GlobalKey<ExitSettingsContentState>();

  @override
  void initState() {
    super.initState();
    NewSettingsScreen._currentInstance = this;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _initializeMenuItems();
  }

  @override
  void dispose() {
    NewSettingsScreen._currentInstance = null;
    super.dispose();
  }

  /// Tracks whether the menu currently includes the Secondary Display category,
  /// so [build] can rebuild the menu when the secondary connection changes.
  bool _menuIncludesSecondary = false;

  /// Populates the configuration categories for the side menu. The Secondary
  /// Display category is included only while a secondary display is active.
  void _initializeMenuItems() {
    _menuItems.clear();
    _menuIncludesSecondary = context.read<SqliteConfigProvider>().isSecondaryActive;

    _menuItems.add(
      SettingsMenuItem(
        title: '',
        localeKey: AppLocale.general,
        icon: Symbols.settings_rounded,
        isVisible: true,
      ),
    );

    _menuItems.add(
      SettingsMenuItem(
        title: '',
        localeKey: AppLocale.directories,
        icon: Symbols.folder_rounded,
        isVisible: true,
      ),
    );

    if (_menuIncludesSecondary) {
      _menuItems.add(
        SettingsMenuItem(
          title: '',
          localeKey: AppLocale.secondaryDisplay,
          icon: Symbols.cast_rounded,
          isVisible: true,
        ),
      );
    }

    _menuItems.add(
      SettingsMenuItem(
        title: '',
        localeKey: AppLocale.systemsSettings,
        icon: Symbols.sports_esports_rounded,
        isVisible: true,
      ),
    );

    _menuItems.add(
      SettingsMenuItem(
        title: '',
        localeKey: AppLocale.palettes,
        icon: Symbols.palette_rounded,
        isVisible: true,
      ),
    );

    _menuItems.add(
      SettingsMenuItem(
        title: '',
        localeKey: AppLocale.neoThemes,
        icon: Symbols.image_rounded,
        isVisible: true,
      ),
    );

    _menuItems.add(
      SettingsMenuItem(
        title: '',
        localeKey: AppLocale.about,
        icon: Symbols.info_rounded,
        isVisible: true,
      ),
    );

    _menuItems.add(
      SettingsMenuItem(
        title: '',
        localeKey: AppLocale.exit,
        icon: Symbols.exit_to_app_rounded,
        isVisible: true,
      ),
    );
  }

  /// Switches the active settings category and resets the content-level focus.
  void _onMenuItemSelected(int index) {
    setState(() {
      _selectedMenuIndex = index;
      _focusOnMenu = true;
      _selectedContentIndex = 0;
    });

    // Auto-focus content for immediate termination confirmation if Exit is selected.
    if (_menuItems[index].localeKey == AppLocale.exit) {
      _focusOnMenu = false;
      _selectedContentIndex = 0;
    }
  }

  /// Vertical Navigation Protocol: Handles wrap-around menu scrolling and content list progression.
  void _navigateUp() {
    if (_focusOnMenu) {
      setState(() {
        _selectedMenuIndex =
            (_selectedMenuIndex - 1 + _menuItems.length) % _menuItems.length;
      });
      return;
    }

    // Content-Specific Navigation Overrides.
    final selectedKey = _menuItems[_selectedMenuIndex].localeKey;
    if (selectedKey == AppLocale.palettes) {
      _paletteSettingsKey.currentState?.navigateUp();
      return;
    }
    if (selectedKey == AppLocale.neoThemes) {
      _themesSettingsKey.currentState?.navigateUp();
      return;
    }

    // Generic linear navigation within content lists.
    setState(() {
      _selectedContentIndex = (_selectedContentIndex - 1).clamp(
        0,
        _getContentItemCount() - 1,
      );
    });
    _triggerContentScroll();
  }

  /// Orchestrates visual alignment in content views to maintain visibility of the focused item.
  void _triggerContentScroll() {
    final selectedKey = _menuItems[_selectedMenuIndex].localeKey;
    if (selectedKey == AppLocale.general) {
      _generalSettingsKey.currentState?.scrollToIndex(_selectedContentIndex);
    } else if (selectedKey == AppLocale.secondaryDisplay) {
      _secondarySettingsKey.currentState?.scrollToIndex(_selectedContentIndex);
    } else if (selectedKey == AppLocale.directories) {
      _directoriesSettingsKey.currentState?.scrollToIndex(
        _selectedContentIndex,
      );
    } else if (selectedKey == AppLocale.systemsSettings) {
      _systemsSettingsKey.currentState?.scrollToIndex(_selectedContentIndex);
    } else if (selectedKey == AppLocale.about) {
      _aboutSettingsKey.currentState?.scrollToIndex(_selectedContentIndex);
    }
  }

  void _navigateDown() {
    if (_focusOnMenu) {
      setState(() {
        _selectedMenuIndex = (_selectedMenuIndex + 1) % _menuItems.length;
      });
      return;
    }

    final selectedKey = _menuItems[_selectedMenuIndex].localeKey;
    if (selectedKey == AppLocale.palettes) {
      _paletteSettingsKey.currentState?.navigateDown();
      return;
    }
    if (selectedKey == AppLocale.neoThemes) {
      _themesSettingsKey.currentState?.navigateDown();
      return;
    }

    setState(() {
      _selectedContentIndex = (_selectedContentIndex + 1).clamp(
        0,
        _getContentItemCount() - 1,
      );
    });
    _triggerContentScroll();
  }

  /// Leftward Navigation Protocol: Returns focus to the master menu from the detail panel.
  void _navigateLeft() {
    if (_focusOnMenu) return;

    final selectedKey = _menuItems[_selectedMenuIndex].localeKey;
    if (selectedKey == AppLocale.palettes) {
      final returnToMenu =
          _paletteSettingsKey.currentState?.navigateLeft() ?? true;
      if (returnToMenu) {
        setState(() {
          _focusOnMenu = true;
          _selectedContentIndex = 0;
        });
      }
    } else if (selectedKey == AppLocale.neoThemes) {
      final returnToMenu =
          _themesSettingsKey.currentState?.navigateLeft() ?? true;
      if (returnToMenu) {
        setState(() {
          _focusOnMenu = true;
          _selectedContentIndex = 0;
        });
      }
    } else {
      setState(() {
        _focusOnMenu = true;
        _selectedContentIndex = 0;
      });
    }
  }

  /// Rightward Navigation Protocol: Moves focus into the detail panel from the master menu.
  void _navigateRight() {
    if (_focusOnMenu && _getContentItemCount() > 0) {
      setState(() {
        _focusOnMenu = false;
        _selectedContentIndex = 0;
      });
      _triggerContentScroll();
      return;
    }

    final selectedKey = _menuItems[_selectedMenuIndex].localeKey;
    if (selectedKey == AppLocale.palettes) {
      _paletteSettingsKey.currentState?.navigateRight();
    } else if (selectedKey == AppLocale.neoThemes) {
      _themesSettingsKey.currentState?.navigateRight();
    }
  }

  /// Execution Protocol: Triggers the action associated with the current focus point.
  void _selectItem() {
    if (_focusOnMenu) {
      _onMenuItemSelected(_selectedMenuIndex);
    } else {
      _selectContentItem();
    }
  }

  /// Resolves the total item count for the currently active category.
  int _getContentItemCount() {
    final selectedKey = _menuItems[_selectedMenuIndex].localeKey;
    if (selectedKey == AppLocale.general) {
      return _generalSettingsKey.currentState?.getItemCount() ?? 0;
    } else if (selectedKey == AppLocale.secondaryDisplay) {
      return _secondarySettingsKey.currentState?.getItemCount() ?? 0;
    } else if (selectedKey == AppLocale.palettes) {
      return _paletteSettingsKey.currentState?.getItemCount(context) ?? 0;
    } else if (selectedKey == AppLocale.neoThemes) {
      return _themesSettingsKey.currentState?.getItemCount() ?? 0;
    } else if (selectedKey == AppLocale.directories) {
      return _directoriesSettingsKey.currentState?.getItemCount() ?? 0;
    } else if (selectedKey == AppLocale.systemsSettings) {
      final provider = context.read<SqliteConfigProvider>();
      return _systemsSettingsKey.currentState?.getItemCount(provider) ?? 0;
    } else if (selectedKey == AppLocale.about) {
      return _aboutSettingsKey.currentState?.getItemCount() ?? 0;
    } else if (selectedKey == AppLocale.exit) {
      return 1;
    } else {
      return 0;
    }
  }

  /// Dispatches selection events to the specialized content controllers.
  void _selectContentItem() {
    final selectedKey = _menuItems[_selectedMenuIndex].localeKey;
    if (selectedKey == AppLocale.general) {
      _generalSettingsKey.currentState?.selectItem(_selectedContentIndex);
    } else if (selectedKey == AppLocale.palettes) {
      _paletteSettingsKey.currentState?.selectItem(_selectedContentIndex);
    } else if (selectedKey == AppLocale.neoThemes) {
      _themesSettingsKey.currentState?.selectItem(_selectedContentIndex);
    } else if (selectedKey == AppLocale.directories) {
      _directoriesSettingsKey.currentState?.selectItem(_selectedContentIndex);
    } else if (selectedKey == AppLocale.secondaryDisplay) {
      _secondarySettingsKey.currentState?.selectItem(_selectedContentIndex);
    } else if (selectedKey == AppLocale.systemsSettings) {
      final provider = context.read<SqliteConfigProvider>();
      _systemsSettingsKey.currentState?.selectItem(
        _selectedContentIndex,
        provider,
      );
    } else if (selectedKey == AppLocale.about) {
      _aboutSettingsKey.currentState?.selectItem(_selectedContentIndex);
    } else if (selectedKey == AppLocale.exit) {
      _executeExit();
    }
  }

  /// Multi-tier Termination Protocol: Handles platform-specific exits and OS-level shutdown requests.
  void _executeExit() {
    final config = context.read<SqliteConfigProvider>().config;
    final bool shouldShutdown = config.bartopExitPoweroff;

    if (Platform.isAndroid) {
      SystemNavigator.pop();
    } else {
      if (shouldShutdown) {
        try {
          if (Platform.isWindows) {
            Process.runSync('shutdown', ['/s', '/t', '0']);
          } else if (Platform.isLinux) {
            Process.runSync('shutdown', ['-h', 'now']);
          }
        } catch (e) {
          _log.e('OS-level shutdown attempt failed: $e');
        }
      }
      exit(0);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    // Rebuild the side menu when the secondary connection changes so the
    // Secondary Display category appears/disappears with it. Clamp the menu
    // cursor in case the list shrank under it.
    final secondaryActive = context
        .watch<SqliteConfigProvider>()
        .isSecondaryActive;
    if (secondaryActive != _menuIncludesSecondary) {
      _initializeMenuItems();
      _selectedMenuIndex = _selectedMenuIndex.clamp(0, _menuItems.length - 1);
    }

    return Container(
      color: Colors.transparent,
      padding: EdgeInsets.only(top: 46.r),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Left Navigation Master List (25% Width).
          _buildLeftMenu(theme),

          // Right Detail Panel (75% Width).
          _buildRightContent(theme),
        ],
      ),
    );
  }

  Widget _buildLeftMenu(ThemeData theme) {
    return Container(
      width: MediaQuery.of(context).size.width * 0.25,
      decoration: BoxDecoration(
        color: theme.cardColor.withValues(alpha: 0.25),
        border: Border(
          right: BorderSide(
            color: theme.colorScheme.primary.withValues(alpha: 0.1),
            width: 1.r,
          ),
        ),
      ),
      child: ListView.builder(
        itemCount: _menuItems.length,
        itemBuilder: (context, index) {
          final item = _menuItems[index];
          if (!item.isVisible) return const SizedBox.shrink();

          final isSelected = _selectedMenuIndex == index;

          return Material(
            color: Colors.transparent,
            child: InkWell(
              onTap: () {
                SfxService().playNavSound();
                _onMenuItemSelected(index);
              },
              canRequestFocus: false,
              focusColor: Colors.transparent,
              hoverColor: Colors.transparent,
              highlightColor: Colors.transparent,
              splashColor: Colors.transparent,
              child: Container(
                padding: EdgeInsets.symmetric(horizontal: 12.r, vertical: 12.r),
                decoration: BoxDecoration(
                  color: isSelected
                      ? theme.colorScheme.primary.withValues(alpha: 0.15)
                      : Colors.transparent,
                  border: Border(
                    left: BorderSide(
                      color: isSelected && _focusOnMenu
                          ? theme.colorScheme.primary
                          : Colors.transparent,
                      width: 3.r,
                    ),
                  ),
                ),
                child: Row(
                  children: [
                    Icon(
                      item.icon,
                      color: isSelected && _focusOnMenu
                          ? theme.colorScheme.primary
                          : theme.colorScheme.onSurface,
                      size: 20.r,
                    ),
                    SizedBox(width: 12.r),
                    Expanded(
                      child: Text(
                        item.localeKey.getString(context),
                        style: theme.textTheme.bodyLarge?.copyWith(
                          color: isSelected && _focusOnMenu
                              ? theme.colorScheme.primary
                              : theme.colorScheme.onSurface,
                          fontWeight: isSelected
                              ? FontWeight.w600
                              : FontWeight.normal,
                          fontSize: 14.r,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildRightContent(ThemeData theme) {
    return Expanded(
      child: Container(
        color: Colors.transparent,
        padding: EdgeInsets.all(16.r),
        child: _buildContentForSelectedMenu(theme),
      ),
    );
  }

  /// Resolution Engine: Instantiates the appropriate detail content based on the master menu selection.
  Widget _buildContentForSelectedMenu(ThemeData theme) {
    final selectedKey = _menuItems[_selectedMenuIndex].localeKey;

    if (selectedKey == AppLocale.general) {
      return GeneralSettingsContent(
        key: _generalSettingsKey,
        isContentFocused: !_focusOnMenu,
        selectedContentIndex: _selectedContentIndex,
        onFullscreenToggle: (value) {},
      );
    } else if (selectedKey == AppLocale.directories) {
      return DirectoriesSettingsContent(
        key: _directoriesSettingsKey,
        isContentFocused: !_focusOnMenu,
        selectedContentIndex: _selectedContentIndex,
      );
    } else if (selectedKey == AppLocale.secondaryDisplay) {
      return SecondarySettingsContent(
        key: _secondarySettingsKey,
        isContentFocused: !_focusOnMenu,
        selectedContentIndex: _selectedContentIndex,
      );
    } else if (selectedKey == AppLocale.systemsSettings) {
      return SystemsSettingsContent(
        key: _systemsSettingsKey,
        isContentFocused: !_focusOnMenu,
        selectedContentIndex: _selectedContentIndex,
      );
    } else if (selectedKey == AppLocale.palettes) {
      return PaletteSettingsContent(
        key: _paletteSettingsKey,
        isContentFocused: !_focusOnMenu,
        selectedContentIndex: _selectedContentIndex,
        onSelectionChanged: (newIndex) {
          setState(() {
            _selectedContentIndex = newIndex;
          });
        },
      );
    } else if (selectedKey == AppLocale.neoThemes) {
      return ThemesSettingsContent(
        key: _themesSettingsKey,
        isContentFocused: !_focusOnMenu,
        selectedContentIndex: _selectedContentIndex,
        onSelectionChanged: (newIndex) {
          setState(() {
            _selectedContentIndex = newIndex;
          });
        },
      );
    } else if (selectedKey == AppLocale.launcher) {
      return LauncherSettingsContent(
        isContentFocused: !_focusOnMenu,
        selectedContentIndex: _selectedContentIndex,
      );
    } else if (selectedKey == AppLocale.about) {
      return AboutSettingsContent(
        key: _aboutSettingsKey,
        isContentFocused: !_focusOnMenu,
        selectedContentIndex: _selectedContentIndex,
      );
    } else if (selectedKey == AppLocale.exit) {
      return ExitSettingsContent(
        key: _exitSettingsKey,
        isContentFocused: !_focusOnMenu,
        selectedContentIndex: _selectedContentIndex,
        onExitPressed: _executeExit,
        onCancel: () {
          setState(() {
            _focusOnMenu = true;
            _selectedContentIndex = 0;
          });
        },
      );
    } else {
      return Center(
        child: Text(
          'Category: ${_menuItems[_selectedMenuIndex].title}',
          style: theme.textTheme.titleLarge,
        ),
      );
    }
  }
}

/// Metadata model for configuration categories.
class SettingsMenuItem {
  final String title;
  final String localeKey;
  final IconData icon;
  final bool isVisible;

  SettingsMenuItem({
    required this.title,
    required this.localeKey,
    required this.icon,
    this.isVisible = true,
  });
}
