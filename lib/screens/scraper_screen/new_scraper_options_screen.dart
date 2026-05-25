import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:neostation/l10n/app_locale.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:neostation/services/screenscraper_service.dart';
import 'package:neostation/services/sfx_service.dart';
import 'package:neostation/widgets/custom_notification.dart';
import 'package:neostation/services/logger_service.dart';
import 'package:neostation/repositories/scraper_repository.dart';
import 'scraper_contents/account_content.dart';
import 'scraper_contents/language_content.dart';
import 'scraper_contents/region_content.dart';
import 'scraper_contents/scrape_mode_content.dart';
import 'scraper_contents/scraping_content.dart';
import 'scraper_contents/systems_content.dart';
import 'scraper_contents/media_content.dart';

/// New scraper options screen with left menu and right content panel
class NewScraperOptionsScreen extends StatefulWidget {
  final VoidCallback? onLogout;

  const NewScraperOptionsScreen({super.key, this.onLogout});

  @override
  State<NewScraperOptionsScreen> createState() =>
      _NewScraperOptionsScreenState();

  // Static methods for delegation
  static void navigateUp() => _currentInstance?._navigateUp();
  static void navigateDown() => _currentInstance?._navigateDown();
  static void navigateLeft() => _currentInstance?._navigateLeft();
  static void navigateRight() => _currentInstance?._navigateRight();
  static void selectCurrent() => _currentInstance?._selectItem();
  static void backCurrent() => _currentInstance?._navigateBack();

  static _NewScraperOptionsScreenState? _currentInstance;
}

class _NewScraperOptionsScreenState extends State<NewScraperOptionsScreen> {
  int _selectedMenuIndex = 0;
  int _selectedContentIndex = 0;
  bool _focusOnMenu = true; // true = menu, false = content

  static final _log = LoggerService.instance;

  final List<ScraperMenuItem> _menuItems = [];

  // GlobalKeys for content widgets
  final GlobalKey<ScrapingContentState> _scrapingKey =
      GlobalKey<ScrapingContentState>();
  final GlobalKey<ScrapeModeContentState> _scrapeModeKey =
      GlobalKey<ScrapeModeContentState>();
  final GlobalKey<RegionContentState> _regionKey =
      GlobalKey<RegionContentState>();
  final GlobalKey<LanguageContentState> _languageKey =
      GlobalKey<LanguageContentState>();
  final GlobalKey<SystemsContentState> _systemsKey =
      GlobalKey<SystemsContentState>();
  final GlobalKey<MediaContentState> _mediaKey = GlobalKey<MediaContentState>();

  Map<String, String>? _userInfo;
  String? _currentScrapeMode;
  String? _currentLanguage;
  List<String> _currentEnabledMediaTypes = [];
  List<String> _currentRegionPriority = [];

  @override
  void initState() {
    super.initState();
    NewScraperOptionsScreen._currentInstance = this;
    _initializeMenuItems();
    _loadCredentials();
    _loadCurrentScrapeMode();
    _loadCurrentLanguage();
    _loadCurrentMediaConfig();
    _loadCurrentRegionPriority();
  }

  @override
  void dispose() {
    NewScraperOptionsScreen._currentInstance = null;
    super.dispose();
  }

  void _initializeMenuItems() {
    _menuItems.clear();
    _menuItems.add(
      ScraperMenuItem(
        title: AppLocale.account.getString(context),
        localeKey: AppLocale.account,
        icon: Symbols.person_rounded,
        isVisible: true,
      ),
    );
    _menuItems.add(
      ScraperMenuItem(
        title: AppLocale.scraping.getString(context),
        localeKey: AppLocale.scraping,
        icon: Symbols.download_rounded,
        isVisible: true,
      ),
    );
    _menuItems.add(
      ScraperMenuItem(
        title: AppLocale.scrapeMode.getString(context),
        localeKey: AppLocale.scrapeMode,
        icon: Symbols.filter_list_rounded,
        isVisible: true,
      ),
    );
    _menuItems.add(
      ScraperMenuItem(
        title: AppLocale.media.getString(context),
        localeKey: AppLocale.media,
        icon: Symbols.perm_media_rounded,
        isVisible: true,
      ),
    );
    _menuItems.add(
      ScraperMenuItem(
        title: AppLocale.region.getString(context),
        localeKey: AppLocale.region,
        icon: Symbols.public_rounded,
        isVisible: true,
      ),
    );
    _menuItems.add(
      ScraperMenuItem(
        title: AppLocale.language.getString(context),
        localeKey: AppLocale.language,
        icon: Symbols.language_rounded,
        isVisible: true,
      ),
    );
    _menuItems.add(
      ScraperMenuItem(
        title: AppLocale.systems.getString(context),
        localeKey: AppLocale.systems,
        icon: Symbols.videogame_asset_rounded,
        isVisible: true,
      ),
    );
  }

  Future<void> _loadCredentials() async {
    final credentials = await ScreenScraperService.getSavedCredentials();
    if (mounted) {
      setState(() {
        _userInfo = credentials;
      });
    }
  }

  Future<void> _refreshAccountInfo() async {
    // Si no hay credenciales, no intentar refrescar
    if (_userInfo == null) return;

    await ScreenScraperService.refreshCredentials();
    if (mounted) {
      await _loadCredentials();
    }
  }

  Future<void> _loadCurrentScrapeMode() async {
    try {
      final config = await ScreenScraperService.getScraperConfig();
      if (mounted) {
        setState(() {
          _currentScrapeMode = config['scrape_mode']?.toString();
        });
      }
    } catch (e) {
      _log.e('Error loading scrape mode: $e');
    }
  }

  Future<void> _loadCurrentLanguage() async {
    try {
      final credentials = await ScreenScraperService.getSavedCredentials();
      if (mounted) {
        setState(() {
          _currentLanguage = credentials?['preferred_language'] ?? 'en';
        });
      }
    } catch (e) {
      _log.e('Error loading language: $e');
    }
  }

  Future<void> _loadCurrentMediaConfig() async {
    try {
      final types = await ScraperRepository.getEnabledMediaTypes();
      if (mounted) {
        setState(() {
          _currentEnabledMediaTypes = types;
        });
      }
    } catch (e) {
      _log.e('Error loading media config: $e');
    }
  }

  Future<void> _loadCurrentRegionPriority() async {
    try {
      final regions = await ScraperRepository.getRegionPriority();
      if (mounted) {
        setState(() {
          _currentRegionPriority = regions;
        });
      }
    } catch (e) {
      _log.e('Error loading region priority: $e');
    }
  }

  void _onMenuItemSelected(int index) {
    setState(() {
      _selectedMenuIndex = index;
      _focusOnMenu = true;
      _selectedContentIndex = 0;
    });
  }

  // Navigation methods for gamepad
  void _navigateUp() {
    if (_focusOnMenu) {
      setState(() {
        _selectedMenuIndex =
            (_selectedMenuIndex - 1 + _menuItems.length) % _menuItems.length;
      });
    } else {
      final selectedKey = _menuItems[_selectedMenuIndex].localeKey;
      if (selectedKey == AppLocale.systems) {
        _systemsKey.currentState?.navigateUp();
      } else if (selectedKey == AppLocale.region) {
        _regionKey.currentState?.navigateUp();
      } else {
        setState(() {
          _selectedContentIndex = (_selectedContentIndex - 1).clamp(
            0,
            _getContentItemCount() - 1,
          );
        });
        // Asegurar scroll para Language
        if (selectedKey == AppLocale.language) {
          _languageKey.currentState?.ensureVisible(_selectedContentIndex);
        }
      }
    }
  }

  void _navigateDown() {
    if (_focusOnMenu) {
      setState(() {
        _selectedMenuIndex = (_selectedMenuIndex + 1) % _menuItems.length;
      });
    } else {
      // Delegar navegación a Systems/Region si está seleccionado
      final selectedKey = _menuItems[_selectedMenuIndex].localeKey;
      if (selectedKey == AppLocale.systems) {
        _systemsKey.currentState?.navigateDown();
      } else if (selectedKey == AppLocale.region) {
        _regionKey.currentState?.navigateDown();
      } else {
        setState(() {
          _selectedContentIndex = (_selectedContentIndex + 1).clamp(
            0,
            _getContentItemCount() - 1,
          );
        });
        // Asegurar scroll para Language
        if (selectedKey == AppLocale.language) {
          _languageKey.currentState?.ensureVisible(_selectedContentIndex);
        }
      }
    }
  }

  void _navigateLeft() {
    if (!_focusOnMenu) {
      final selectedKey = _menuItems[_selectedMenuIndex].localeKey;
      if (selectedKey == AppLocale.systems) {
        final shouldReturnToMenu =
            _systemsKey.currentState?.navigateLeft() ?? true;
        if (shouldReturnToMenu) {
          setState(() {
            _focusOnMenu = true;
            _selectedContentIndex = 0;
          });
        }
      } else if (selectedKey == AppLocale.region) {
        final shouldReturnToMenu =
            _regionKey.currentState?.navigateLeft() ?? true;
        if (shouldReturnToMenu) {
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
  }

  void _navigateRight() {
    if (_focusOnMenu && _getContentItemCount() > 0) {
      setState(() {
        _focusOnMenu = false;
        _selectedContentIndex = 0;
      });
    } else if (!_focusOnMenu) {
      final selectedKey = _menuItems[_selectedMenuIndex].localeKey;
      if (selectedKey == AppLocale.systems) {
        _systemsKey.currentState?.navigateRight();
      } else if (selectedKey == AppLocale.region) {
        _regionKey.currentState?.navigateRight();
      }
    }
  }

  void _selectItem() {
    if (_focusOnMenu) {
      _onMenuItemSelected(_selectedMenuIndex);
    } else {
      _selectContentItem();
    }
  }

  void _navigateBack() {
    if (!_focusOnMenu) {
      final selectedKey = _menuItems[_selectedMenuIndex].localeKey;
      if (selectedKey == AppLocale.region) {
        _regionKey.currentState?.navigateBack();
        return;
      }
    }
  }

  int _getContentItemCount() {
    final selectedKey = _menuItems[_selectedMenuIndex].localeKey;
    if (selectedKey == AppLocale.scraping) return 1;
    if (selectedKey == AppLocale.scrapeMode) return 2;
    if (selectedKey == AppLocale.media) return 5;
    if (selectedKey == AppLocale.region) {
      return _regionKey.currentState?.getItemCount ?? 0;
    }
    if (selectedKey == AppLocale.language) return 6;
    if (selectedKey == AppLocale.systems) {
      return _systemsKey.currentState?.getItemCount() ?? 0;
    }
    if (selectedKey == AppLocale.account) return 1;
    return 0;
  }

  void _selectContentItem() {
    final selectedKey = _menuItems[_selectedMenuIndex].localeKey;
    if (selectedKey == AppLocale.scraping) {
      _scrapingKey.currentState?.selectItem(_selectedContentIndex);
    } else if (selectedKey == AppLocale.scrapeMode) {
      _scrapeModeKey.currentState?.selectItem(_selectedContentIndex);
    } else if (selectedKey == AppLocale.media) {
      _mediaKey.currentState?.selectItem(_selectedContentIndex);
    } else if (selectedKey == AppLocale.region) {
      _regionKey.currentState?.selectItem();
    } else if (selectedKey == AppLocale.language) {
      _languageKey.currentState?.selectItem(_selectedContentIndex);
    } else if (selectedKey == AppLocale.systems) {
      _systemsKey.currentState?.selectItem();
    } else if (selectedKey == AppLocale.account) {
      if (_selectedContentIndex == 0) {
        _handleLogout();
      }
    }
  }

  Future<void> _handleLogout() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(AppLocale.logoutConfirm.getString(context)),
        content: Text(AppLocale.logoutConfirmationDesc.getString(context)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(AppLocale.cancel.getString(context)),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            style: TextButton.styleFrom(
              foregroundColor: Theme.of(context).colorScheme.error,
            ),
            child: Text(AppLocale.logout.getString(context)),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      final success = await ScreenScraperService.clearCredentials();
      if (mounted) {
        if (success) {
          AppNotification.showNotification(
            context,
            AppLocale.logoutSuccess.getString(context),
            type: NotificationType.success,
          );
          widget.onLogout?.call();
        } else {
          AppNotification.showNotification(
            context,
            AppLocale.logoutError.getString(context),
            type: NotificationType.error,
          );
        }
      }
    }
  }

  Future<void> _handleScrapeModeChange(String newMode) async {
    final success = await ScreenScraperService.saveScraperConfig({
      'scrape_mode': newMode,
    });
    if (mounted) {
      if (success) {
        await _loadCurrentScrapeMode();
        if (!mounted) return;
        final modeName = newMode == 'new_only'
            ? AppLocale.newContentOnly.getString(context)
            : AppLocale.allContent.getString(context);
        AppNotification.showNotification(
          context,
          '${AppLocale.scrapeModeUpdated.getString(context)} $modeName',
          type: NotificationType.success,
        );
      } else {
        AppNotification.showNotification(
          context,
          AppLocale.scrapeModeError.getString(context),
          type: NotificationType.error,
        );
      }
    }
  }

  Future<void> _handleLanguageChange(String newLanguage) async {
    if (_userInfo == null) return;

    final success = await ScreenScraperService.saveCredentials(
      _userInfo!['username']!,
      _userInfo!['password']!,
      _userInfo,
      newLanguage, // Pasar como cuarto parámetro
    );

    if (mounted) {
      if (success) {
        await _loadCredentials();
        await _loadCurrentLanguage();
        if (!mounted) return;
        AppNotification.showNotification(
          context,
          AppLocale.languageUpdated.getString(context),
          type: NotificationType.success,
        );
      } else {
        AppNotification.showNotification(
          context,
          AppLocale.languageError.getString(context),
          type: NotificationType.error,
        );
      }
    }
  }

  Future<void> _handleMediaConfigChange(List<String> enabledTypes) async {
    final success = await ScraperRepository.saveEnabledMediaTypes(enabledTypes);
    if (mounted && success) {
      setState(() {
        _currentEnabledMediaTypes = List<String>.from(enabledTypes);
      });
    }
  }

  Future<void> _handleRegionPriorityChange(List<String> newPriority) async {
    setState(() {
      _currentRegionPriority = newPriority;
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Container(
      color: Colors
          .transparent, // Transparent to show the shared background shader
      padding: EdgeInsets.only(top: 46.r),
      child: Row(
        children: [
          // Left menu - 25% width
          _buildLeftMenu(theme),

          // Right content - 75% width
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
                        item.title,
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
        color: Colors
            .transparent, // Transparent to show the shared background shader
        padding: EdgeInsets.all(16.r),
        alignment: Alignment.topLeft,
        child: _buildContentForSelectedMenu(theme),
      ),
    );
  }

  Widget _buildContentForSelectedMenu(ThemeData theme) {
    final selectedKey = _menuItems[_selectedMenuIndex].localeKey;

    if (selectedKey == AppLocale.scraping) {
      return ScrapingContent(
        key: _scrapingKey,
        isContentFocused: !_focusOnMenu,
        selectedContentIndex: _selectedContentIndex,
        onScrapingFinished: _refreshAccountInfo,
      );
    } else if (selectedKey == AppLocale.scrapeMode) {
      return ScrapeModeContent(
        key: _scrapeModeKey,
        isContentFocused: !_focusOnMenu,
        selectedContentIndex: _selectedContentIndex,
        currentMode: _currentScrapeMode ?? 'new_only',
        onModeChanged: _handleScrapeModeChange,
      );
    } else if (selectedKey == AppLocale.media) {
      return MediaContent(
        key: _mediaKey,
        isContentFocused: !_focusOnMenu,
        selectedContentIndex: _selectedContentIndex,
        enabledTypes: _currentEnabledMediaTypes,
        onEnabledTypesChanged: _handleMediaConfigChange,
      );
    } else if (selectedKey == AppLocale.region) {
      return RegionContent(
        key: _regionKey,
        isContentFocused: !_focusOnMenu,
        selectedContentIndex: _selectedContentIndex,
        onRegionPriorityChanged: _handleRegionPriorityChange,
      );
    } else if (selectedKey == AppLocale.language) {
      return LanguageContent(
        key: _languageKey,
        isContentFocused: !_focusOnMenu,
        selectedContentIndex: _selectedContentIndex,
        currentLanguage: _currentLanguage ?? 'en',
        onLanguageChanged: _handleLanguageChange,
      );
    } else if (selectedKey == AppLocale.systems) {
      return SystemsContent(
        key: _systemsKey,
        isContentFocused: !_focusOnMenu,
        selectedContentIndex: _selectedContentIndex,
      );
    } else if (selectedKey == AppLocale.account) {
      return AccountContent(
        isContentFocused: !_focusOnMenu,
        selectedContentIndex: _selectedContentIndex,
        userInfo: _userInfo,
        onLogout: _handleLogout,
      );
    } else {
      return Center(
        child: Text(
          '${AppLocale.noData.getString(context)} ${_menuItems[_selectedMenuIndex].title}',
          style: theme.textTheme.titleLarge,
        ),
      );
    }
  }
}

/// Model for menu items
class ScraperMenuItem {
  final String title;
  final String localeKey;
  final IconData icon;
  final bool isVisible;

  ScraperMenuItem({
    required this.title,
    required this.localeKey,
    required this.icon,
    this.isVisible = true,
  });
}
