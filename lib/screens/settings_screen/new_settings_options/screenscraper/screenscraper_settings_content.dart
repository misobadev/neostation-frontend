import 'package:flutter/material.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:provider/provider.dart';
import 'package:neostation/l10n/app_locale.dart';
import 'package:neostation/providers/scraping_provider.dart';
import 'package:neostation/repositories/scraper_repository.dart';
import 'package:neostation/services/logger_service.dart';
import 'package:neostation/services/screenscraper_service.dart';
import 'package:neostation/services/sfx_service.dart';
import 'package:neostation/utils/adaptive_scroll.dart';
import 'package:neostation/widgets/confirm_action_dialog.dart';
import 'package:neostation/widgets/custom_notification.dart';
import 'package:neostation/widgets/custom_toggle_switch.dart';
import '../settings_title.dart';
import '../widgets/setting_row.dart';
import '../widgets/setting_value_chip.dart';
import '../widgets/settings_section_header.dart';
import 'scrape_session.dart';
import 'scraping_progress_panel.dart';
import 'screenscraper_account_card.dart';
import 'screenscraper_login_dialog.dart';

/// The ScreenScraper settings category: account, scraping, and every scraper
/// option on one scrolling page.
///
/// Signed out, the page is a single sign-in row that opens
/// [ScreenScraperLoginDialog]. Signed in, it owns one gamepad cursor over the
/// account and scraping rows (start/stop, scrape mode, language), the
/// enable-all row and a grid of system tiles, then the media type and region
/// priority rows. The settings screen delegates D-pad, A and B here, like the Themes and System
/// Art categories.
class ScreenScraperSettingsContent extends StatefulWidget {
  final bool isContentFocused;

  const ScreenScraperSettingsContent({
    super.key,
    required this.isContentFocused,
  });

  @override
  State<ScreenScraperSettingsContent> createState() =>
      ScreenScraperSettingsContentState();
}

class ScreenScraperSettingsContentState
    extends State<ScreenScraperSettingsContent> {
  static final _log = LoggerService.instance;

  /// Scrape mode values, in the order A cycles through them.
  static const List<String> _scrapeModes = ['new_only', 'all'];

  /// Metadata languages ScreenScraper serves, in the order A cycles through
  /// them. Names are endonyms, so they read the same in every UI language.
  static const Map<String, String> _languages = {
    'en': 'English',
    'es': 'Español',
    'fr': 'Français',
    'de': 'Deutsch',
    'it': 'Italiano',
    'pt': 'Português',
  };

  static const List<String> _mediaTypes = [
    'fanart',
    'ss',
    'wheel',
    'box2D',
    'video',
  ];

  static const Map<String, String> _regionNames = {
    'wor': 'World',
    'us': 'USA',
    'eu': 'Europe',
    'fr': 'France',
    'sp': 'Spain',
    'it': 'Italy',
    'de': 'Germany',
    'jp': 'Japan',
    'kr': 'Korea',
    'cn': 'China',
  };

  static const int _gridColumns = 5;

  final ScrollController _scrollController = ScrollController();
  final AdaptiveScroller _scroller = AdaptiveScroller();
  final List<GlobalKey> _itemKeys = [];

  bool _isLoading = true;
  bool _signedIn = false;
  Map<String, String>? _userInfo;
  String _scrapeMode = 'new_only';
  String _language = 'en';
  List<String> _enabledMediaTypes = [];
  List<String> _regions = [];
  List<Map<String, dynamic>> _systems = [];
  Map<String, bool> _enabledSystems = {};

  /// Gamepad cursor over [getItemCount] slots (see the index getters below).
  int _cursor = 0;

  /// Whether the focused region has been picked up for reordering.
  bool _movingRegion = false;

  // Slot layout when signed in, in page order: account, the scraping rows,
  // enable-all, the systems grid, then the media and region rows. Signed out
  // there is a single slot: the sign-in row.
  static const int _accountSlot = 0;
  static const int _scrapeSlot = 1;
  static const int _scrapeModeSlot = 2;
  static const int _languageSlot = 3;
  static const int _toggleAllSlot = 4;
  static const int _gridStart = 5;
  int get _gridEnd => _gridStart + _systems.length;
  int get _mediaStart => _gridEnd;
  int get _regionStart => _mediaStart + _mediaTypes.length;

  bool _isRegionSlot(int slot) =>
      slot >= _regionStart && slot < _regionStart + _regions.length;
  bool _isGridSlot(int slot) => slot >= _gridStart && slot < _gridEnd;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant ScreenScraperSettingsContent oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Focus handed back to the category menu: reset the cursor and park the
    // page at the top, matching the other categories.
    if (oldWidget.isContentFocused && !widget.isContentFocused) {
      if (_movingRegion) _dropRegion();
      _cursor = 0;
      _scrollToCursor();
    }
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final signedIn = await ScreenScraperService.hasSavedCredentials();
    if (!signedIn) {
      if (mounted) {
        setState(() {
          _signedIn = false;
          _userInfo = null;
          _isLoading = false;
        });
      }
      return;
    }

    try {
      final results = await Future.wait([
        ScreenScraperService.getSavedCredentials(),
        ScreenScraperService.getScraperConfig(),
        ScraperRepository.getEnabledMediaTypes(),
        ScraperRepository.getRegionPriority(),
        ScraperRepository.getScraperSystems(),
        ScraperRepository.getSystemScraperConfig(),
      ]);
      if (!mounted) return;
      final credentials = results[0] as Map<String, String>?;
      final config = results[1] as Map<String, dynamic>;
      setState(() {
        _signedIn = true;
        _userInfo = credentials;
        _language = credentials?['preferred_language'] ?? 'en';
        _scrapeMode = config['scrape_mode']?.toString() ?? 'new_only';
        _enabledMediaTypes = List<String>.from(results[2] as List<String>);
        _regions = List<String>.from(results[3] as List<String>);
        _systems = results[4] as List<Map<String, dynamic>>;
        _enabledSystems = Map<String, bool>.from(
          results[5] as Map<String, bool>,
        );
        _isLoading = false;
      });
    } catch (e) {
      _log.e('Error loading ScreenScraper settings: $e');
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _reloadCredentials() async {
    final credentials = await ScreenScraperService.getSavedCredentials();
    if (mounted) setState(() => _userInfo = credentials);
  }

  // ==========================================
  // GAMEPAD NAVIGATION (driven by NewSettingsScreen)
  // ==========================================

  int getItemCount() {
    if (_isLoading) return 0;
    if (!_signedIn) return 1;
    return _regionStart + _regions.length;
  }

  /// Returns whether the cursor moved (drives the nav sound).
  bool navigateUp() {
    if (_movingRegion) return _moveRegion(-1);
    if (_cursor == 0) return false;
    int next;
    if (_isGridSlot(_cursor)) {
      final gridIndex = _cursor - _gridStart;
      next = gridIndex < _gridColumns ? _toggleAllSlot : _cursor - _gridColumns;
    } else {
      next = _cursor - 1;
    }
    _setCursor(next);
    return true;
  }

  /// Returns whether the cursor moved (drives the nav sound).
  bool navigateDown() {
    if (_movingRegion) return _moveRegion(1);
    final count = getItemCount();
    if (_cursor >= count - 1) return false;
    int next;
    if (_isGridSlot(_cursor)) {
      next = _cursor + _gridColumns;
      if (next >= _gridEnd) {
        final lastRowStart =
            _gridStart + ((_systems.length - 1) ~/ _gridColumns) * _gridColumns;
        // Last row leaves the grid for the media rows; the row above a
        // short last row lands on its final tile.
        next = _cursor >= lastRowStart ? _mediaStart : _gridEnd - 1;
      }
    } else {
      next = _cursor + 1;
    }
    _setCursor(next);
    return true;
  }

  /// Moves left within the systems grid. Returns true when focus should go
  /// back to the category menu instead.
  bool navigateLeft() {
    if (_movingRegion) {
      _dropRegion();
      return false;
    }
    if (_isGridSlot(_cursor) && (_cursor - _gridStart) % _gridColumns != 0) {
      _setCursor(_cursor - 1);
      return false;
    }
    return true;
  }

  void navigateRight() {
    if (_movingRegion || !_isGridSlot(_cursor)) return;
    final gridIndex = _cursor - _gridStart;
    if (gridIndex % _gridColumns == _gridColumns - 1) return;
    if (_cursor + 1 >= _gridEnd) return;
    _setCursor(_cursor + 1);
  }

  /// B: drops a picked-up region. Returns true when it was consumed, so the
  /// settings screen only returns to the menu when there was nothing to drop.
  bool navigateBack() {
    if (_movingRegion) {
      _dropRegion();
      return true;
    }
    return false;
  }

  void selectItem() {
    if (_isLoading) return;
    if (!_signedIn) {
      _signIn();
      return;
    }
    final slot = _cursor;
    if (slot == _accountSlot) {
      _logout();
    } else if (slot == _scrapeSlot) {
      _toggleScraping();
    } else if (slot == _scrapeModeSlot) {
      final next =
          _scrapeModes[(_scrapeModes.indexOf(_scrapeMode) + 1) %
              _scrapeModes.length];
      _setScrapeMode(next);
    } else if (slot == _languageSlot) {
      final codes = _languages.keys.toList();
      _setLanguage(codes[(codes.indexOf(_language) + 1) % codes.length]);
    } else if (slot >= _mediaStart && slot < _regionStart) {
      final type = _mediaTypes[slot - _mediaStart];
      _setMediaType(type, !_enabledMediaTypes.contains(type));
    } else if (_isRegionSlot(slot)) {
      if (_movingRegion) {
        _dropRegion();
      } else {
        setState(() => _movingRegion = true);
      }
    } else if (slot == _toggleAllSlot) {
      _toggleAllSystems();
    } else if (_isGridSlot(slot)) {
      _toggleSystem(_systems[slot - _gridStart]['id'].toString());
    }
  }

  void _setCursor(int slot) {
    setState(() => _cursor = slot);
    _scrollToCursor();
  }

  void _scrollToCursor() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (_cursor == 0 && _scrollController.hasClients) {
        _scrollController.jumpTo(0);
        return;
      }
      _scroller.ensureVisibleIndex(
        _cursor,
        keys: _itemKeys,
        controller: _scrollController,
      );
    });
  }

  /// Stable key for [slot], growing the pool as the page grows.
  GlobalKey _keyFor(int slot) {
    while (_itemKeys.length <= slot) {
      _itemKeys.add(GlobalKey());
    }
    return _itemKeys[slot];
  }

  bool _focused(int slot) => widget.isContentFocused && _cursor == slot;

  // ==========================================
  // ACTIONS
  // ==========================================

  Future<void> _signIn() async {
    final signedIn = await ScreenScraperLoginDialog.show(context);
    if (!signedIn || !mounted) return;
    setState(() {
      _isLoading = true;
      _cursor = 0;
    });
    await _load();
  }

  Future<void> _logout() async {
    final confirmed = await ConfirmActionDialog.show(
      context,
      title: AppLocale.logoutConfirm.getString(context),
      body: AppLocale.logoutConfirmationDesc.getString(context),
      confirmLabel: AppLocale.logout.getString(context),
      icon: Symbols.logout_rounded,
    );
    if (confirmed != true || !mounted) return;

    final success = await ScreenScraperService.clearCredentials();
    if (!mounted) return;
    if (success) {
      AppNotification.showNotification(
        context,
        AppLocale.logoutSuccess.getString(context),
        type: NotificationType.success,
      );
      setState(() {
        _signedIn = false;
        _userInfo = null;
        _cursor = 0;
        _movingRegion = false;
      });
      _scrollToCursor();
    } else {
      AppNotification.showNotification(
        context,
        AppLocale.logoutError.getString(context),
        type: NotificationType.error,
      );
    }
  }

  void _toggleScraping() {
    if (context.read<ScrapingProvider>().isScraping) {
      stopScrapeSession(context);
    } else {
      startScrapeSession(
        context,
        onFinished: () async {
          // Quota counters changed; refresh them if the page is still up.
          if (!mounted || _userInfo == null) return;
          await ScreenScraperService.refreshCredentials();
          await _reloadCredentials();
        },
      );
    }
  }

  Future<void> _setScrapeMode(String mode) async {
    final previous = _scrapeMode;
    setState(() => _scrapeMode = mode);
    final success = await ScreenScraperService.saveScraperConfig({
      'scrape_mode': mode,
    });
    if (!mounted || success) return;
    setState(() => _scrapeMode = previous);
    AppNotification.showNotification(
      context,
      AppLocale.scrapeModeError.getString(context),
      type: NotificationType.error,
    );
  }

  Future<void> _setLanguage(String language) async {
    final info = _userInfo;
    if (info == null) return;
    final previous = _language;
    setState(() => _language = language);
    final success = await ScreenScraperService.saveCredentials(
      info['username']!,
      info['password']!,
      info,
      language,
    );
    if (!mounted) return;
    if (success) {
      await _reloadCredentials();
    } else {
      setState(() => _language = previous);
      AppNotification.showNotification(
        context,
        AppLocale.languageError.getString(context),
        type: NotificationType.error,
      );
    }
  }

  Future<void> _setMediaType(String type, bool enabled) async {
    final types = List<String>.from(_enabledMediaTypes);
    if (enabled) {
      if (!types.contains(type)) types.add(type);
    } else {
      types.remove(type);
    }
    final success = await ScraperRepository.saveEnabledMediaTypes(types);
    if (mounted && success) setState(() => _enabledMediaTypes = types);
  }

  /// Moves the picked-up region one place. Returns whether it moved.
  bool _moveRegion(int direction) {
    final index = _cursor - _regionStart;
    final target = index + direction;
    if (target < 0 || target >= _regions.length) return false;
    setState(() {
      final region = _regions.removeAt(index);
      _regions.insert(target, region);
      _cursor = _regionStart + target;
    });
    _scrollToCursor();
    return true;
  }

  void _dropRegion() {
    setState(() => _movingRegion = false);
    ScraperRepository.saveRegionPriority(_regions);
  }

  void _onRegionReorder(int oldIndex, int newIndex) {
    SfxService().playNavSound();
    setState(() {
      final region = _regions.removeAt(oldIndex);
      _regions.insert(newIndex, region);
      _cursor = _regionStart + newIndex;
      _movingRegion = false;
    });
    ScraperRepository.saveRegionPriority(_regions);
  }

  Future<void> _toggleSystem(String systemId) async {
    final previous = _enabledSystems[systemId] ?? false;
    setState(() => _enabledSystems[systemId] = !previous);
    final success = await ScraperRepository.saveSystemConfig(
      systemId,
      !previous,
    );
    if (!mounted || success) return;
    setState(() => _enabledSystems[systemId] = previous);
    AppNotification.showNotification(
      context,
      AppLocale.updateError.getString(context),
      type: NotificationType.error,
    );
  }

  bool get _allSystemsEnabled =>
      _systems.every((s) => _enabledSystems[s['id'].toString()] == true);

  Future<void> _toggleAllSystems() async {
    final enable = !_allSystemsEnabled;
    final ids = _systems.map((s) => s['id'].toString()).toList();
    setState(() {
      for (final id in ids) {
        _enabledSystems[id] = enable;
      }
    });
    try {
      await ScraperRepository.saveAllSystemsConfig(ids, enable);
    } catch (e) {
      _log.e('Error toggling all systems: $e');
      final config = await ScraperRepository.getSystemScraperConfig();
      if (!mounted) return;
      setState(() => _enabledSystems = Map<String, bool>.from(config));
      AppNotification.showNotification(
        context,
        AppLocale.updateError.getString(context),
        type: NotificationType.error,
      );
    }
  }

  // ==========================================
  // BUILD
  // ==========================================

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SettingsTitle(title: AppLocale.screenScraperTitle.getString(context)),
        SizedBox(height: 12.r),
        Expanded(
          child: _isLoading
              ? const Center(child: CircularProgressIndicator())
              : SingleChildScrollView(
                  controller: _scrollController,
                  child: _signedIn
                      ? _buildSignedIn(context)
                      : _buildSignedOut(context),
                ),
        ),
      ],
    );
  }

  Widget _buildSignedOut(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SettingRow(
          key: _keyFor(0),
          title: AppLocale.screenScraperLogin.getString(context),
          subtitle: AppLocale.requiresFreeAccount.getString(context),
          focused: _focused(0),
          onTap: _signIn,
          trailing: Icon(
            Symbols.login_rounded,
            size: 20.r,
            color: theme.colorScheme.primary,
          ),
        ),
        SizedBox(height: 12.r),
        Text(
          AppLocale.screenScraperDescription.getString(context),
          style: theme.textTheme.bodyMedium?.copyWith(
            fontSize: 9.r,
            color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
          ),
        ),
      ],
    );
  }

  Widget _buildSignedIn(BuildContext context) {
    final gap = SizedBox(height: 6.r);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SettingsSectionHeader(label: AppLocale.account.getString(context)),
        KeyedSubtree(
          key: _keyFor(_accountSlot),
          child: ScreenScraperAccountCard(
            logoutFocused: _focused(_accountSlot),
            userInfo: _userInfo,
            onLogout: _logout,
          ),
        ),
        SizedBox(height: 16.r),

        SettingsSectionHeader(label: AppLocale.scraping.getString(context)),
        _buildScrapeRow(context),
        gap,
        SettingRow(
          key: _keyFor(_scrapeModeSlot),
          title: AppLocale.scrapeMode.getString(context),
          subtitle: _scrapeMode == 'all'
              ? AppLocale.allContentDesc.getString(context)
              : AppLocale.newContentOnlyDesc.getString(context),
          focused: _focused(_scrapeModeSlot),
          onTap: () {
            _cursor = _scrapeModeSlot;
            selectItem();
          },
          trailing: SettingValueChip(
            text: _scrapeMode == 'all'
                ? AppLocale.allContent.getString(context)
                : AppLocale.newContentOnly.getString(context),
          ),
        ),
        gap,
        SettingRow(
          key: _keyFor(_languageSlot),
          title: AppLocale.preferredLanguage.getString(context),
          subtitle: AppLocale.languageSub.getString(context),
          focused: _focused(_languageSlot),
          onTap: () {
            _cursor = _languageSlot;
            selectItem();
          },
          trailing: SettingValueChip(text: _languages[_language] ?? _language),
        ),
        SizedBox(height: 16.r),

        SettingsSectionHeader(label: AppLocale.systems.getString(context)),
        SettingRow(
          key: _keyFor(_toggleAllSlot),
          title: _allSystemsEnabled
              ? AppLocale.disableAll.getString(context)
              : AppLocale.enableAll.getString(context),
          subtitle: AppLocale.systemsSub.getString(context),
          focused: _focused(_toggleAllSlot),
          onTap: _toggleAllSystems,
          trailing: SettingValueChip(
            text:
                '${_enabledSystems.values.where((v) => v).length} / ${_systems.length}',
          ),
        ),
        SizedBox(height: 8.r),
        _buildSystemsGrid(context),
        SizedBox(height: 16.r),

        SettingsSectionHeader(label: AppLocale.media.getString(context)),
        for (var i = 0; i < _mediaTypes.length; i++) ...[
          _buildMediaRow(context, i),
          gap,
        ],
        SizedBox(height: 10.r),

        SettingsSectionHeader(
          label: AppLocale.regionPriority.getString(context),
        ),
        _buildHint(context, AppLocale.regionPrioritySub.getString(context)),
        _buildRegionList(context),
      ],
    );
  }

  Widget _buildHint(BuildContext context, String text) {
    final theme = Theme.of(context);
    return Padding(
      padding: EdgeInsets.only(bottom: 8.r, left: 2.r),
      child: Text(
        text,
        style: theme.textTheme.bodyMedium?.copyWith(
          fontSize: 9.r,
          color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
        ),
      ),
    );
  }

  Widget _buildScrapeRow(BuildContext context) {
    final theme = Theme.of(context);
    return Consumer<ScrapingProvider>(
      builder: (context, scraping, _) {
        return Column(
          key: _keyFor(_scrapeSlot),
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SettingRow(
              title: AppLocale.scraping.getString(context),
              subtitle: scraping.isScraping
                  ? '${AppLocale.scrapingInProgress.getString(context)} ${scraping.maxThreads} threads'
                  : AppLocale.scraperSubtitle.getString(context),
              focused: _focused(_scrapeSlot),
              onTap: _toggleScraping,
              trailing: ElevatedButton.icon(
                onPressed: _toggleScraping,
                icon: Icon(
                  scraping.isScraping
                      ? Symbols.stop_rounded
                      : Symbols.play_arrow_rounded,
                  size: 16.r,
                ),
                label: Text(
                  scraping.isScraping
                      ? AppLocale.stop.getString(context)
                      : AppLocale.start.getString(context),
                  style: TextStyle(fontSize: 10.r),
                ),
                style: ElevatedButton.styleFrom(
                  backgroundColor: scraping.isScraping
                      ? theme.colorScheme.error
                      : theme.colorScheme.primary,
                  foregroundColor: theme.colorScheme.onPrimary,
                  padding: EdgeInsets.symmetric(
                    horizontal: 16.r,
                    vertical: 6.r,
                  ),
                  minimumSize: Size(0, 32.r),
                ),
              ),
            ),
            if (scraping.isScraping) ...[
              SizedBox(height: 8.r),
              ScrapingProgressPanel(scrapingProvider: scraping),
            ],
          ],
        );
      },
    );
  }

  String _mediaTitle(BuildContext context, String type) => switch (type) {
    'fanart' => AppLocale.scrapeFanart.getString(context),
    'ss' => AppLocale.scrapeScreenshot.getString(context),
    'wheel' => AppLocale.scrapeWheel.getString(context),
    'box2D' => AppLocale.scrapeBox2D.getString(context),
    'video' => AppLocale.scrapeVideo.getString(context),
    _ => type,
  };

  String _mediaDescription(BuildContext context, String type) => switch (type) {
    'fanart' => AppLocale.scrapeFanartDesc.getString(context),
    'ss' => AppLocale.scrapeScreenshotDesc.getString(context),
    'wheel' => AppLocale.scrapeWheelDesc.getString(context),
    'box2D' => AppLocale.scrapeBox2DDesc.getString(context),
    'video' => AppLocale.scrapeVideoDesc.getString(context),
    _ => '',
  };

  Widget _buildMediaRow(BuildContext context, int index) {
    final slot = _mediaStart + index;
    final type = _mediaTypes[index];
    final enabled = _enabledMediaTypes.contains(type);
    return SettingRow(
      key: _keyFor(slot),
      title: _mediaTitle(context, type),
      subtitle: _mediaDescription(context, type),
      focused: _focused(slot),
      onTap: () => _setMediaType(type, !enabled),
      trailing: CustomToggleSwitch(
        value: enabled,
        onChanged: (value) => _setMediaType(type, value),
        activeColor: Theme.of(context).colorScheme.primary,
      ),
    );
  }

  Widget _buildRegionList(BuildContext context) {
    return ReorderableListView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      buildDefaultDragHandles: false,
      onReorderItem: _onRegionReorder,
      itemCount: _regions.length,
      proxyDecorator: (child, index, animation) => Material(
        color: Colors.transparent,
        elevation: 6,
        borderRadius: BorderRadius.circular(8.r),
        child: child,
      ),
      itemBuilder: (context, index) {
        final slot = _regionStart + index;
        return Padding(
          key: ValueKey('region_${_regions[index]}'),
          padding: EdgeInsets.only(bottom: 4.r),
          child: KeyedSubtree(
            key: _keyFor(slot),
            child: _buildRegionCard(
              context,
              index: index,
              focused: _focused(slot),
              moving: _movingRegion && _cursor == slot,
            ),
          ),
        );
      },
    );
  }

  Widget _buildRegionCard(
    BuildContext context, {
    required int index,
    required bool focused,
    required bool moving,
  }) {
    final theme = Theme.of(context);
    final code = _regions[index];
    final priority = index + 1;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        canRequestFocus: false,
        focusColor: Colors.transparent,
        hoverColor: Colors.transparent,
        highlightColor: Colors.transparent,
        splashColor: Colors.transparent,
        borderRadius: BorderRadius.circular(8.r),
        onTap: () {
          SfxService().playNavSound();
          final slot = _regionStart + index;
          if (_movingRegion && _cursor == slot) {
            _dropRegion();
          } else {
            setState(() {
              _cursor = slot;
              _movingRegion = true;
            });
          }
        },
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
          padding: EdgeInsets.symmetric(horizontal: 12.r, vertical: 6.r),
          decoration: BoxDecoration(
            color: moving
                ? theme.colorScheme.primary.withValues(alpha: 0.2)
                : theme.colorScheme.surface.withValues(alpha: 0.5),
            borderRadius: BorderRadius.circular(8.r),
            border: Border.all(
              color: moving || focused
                  ? theme.colorScheme.primary
                  : Colors.transparent,
              width: 2,
            ),
          ),
          child: Row(
            children: [
              Container(
                width: 24.r,
                height: 24.r,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: moving
                      ? theme.colorScheme.primary
                      : theme.colorScheme.onSurface.withValues(alpha: 0.1),
                ),
                child: Center(
                  child: Text(
                    '$priority',
                    style: theme.textTheme.labelSmall?.copyWith(
                      fontSize: 10.r,
                      fontWeight: FontWeight.bold,
                      color: moving
                          ? theme.colorScheme.onPrimary
                          : theme.colorScheme.onSurface.withValues(alpha: 0.6),
                    ),
                  ),
                ),
              ),
              SizedBox(width: 12.r),
              Expanded(
                child: Text(
                  _regionNames[code] ?? code.toUpperCase(),
                  style: theme.textTheme.bodyLarge?.copyWith(
                    fontWeight: FontWeight.w500,
                    fontSize: 12.r,
                    color: focused
                        ? theme.colorScheme.primary
                        : theme.colorScheme.onSurface,
                  ),
                ),
              ),
              Text(
                code.toUpperCase(),
                style: theme.textTheme.bodyMedium?.copyWith(
                  fontSize: 9.r,
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.4),
                ),
              ),
              SizedBox(width: 8.r),
              ReorderableDragStartListener(
                index: index,
                child: MouseRegion(
                  cursor: moving
                      ? SystemMouseCursors.grabbing
                      : SystemMouseCursors.grab,
                  child: Padding(
                    padding: EdgeInsets.all(4.r),
                    child: Icon(
                      moving
                          ? Symbols.swap_vert_rounded
                          : Symbols.drag_indicator_rounded,
                      size: 20.r,
                      color: moving
                          ? theme.colorScheme.primary
                          : theme.colorScheme.onSurface.withValues(
                              alpha: focused ? 0.5 : 0.2,
                            ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSystemsGrid(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final spacing = 6.r;
        final tileWidth =
            (constraints.maxWidth - spacing * (_gridColumns - 1)) /
            _gridColumns;
        return Wrap(
          spacing: spacing,
          runSpacing: spacing,
          children: [
            for (var i = 0; i < _systems.length; i++)
              SizedBox(
                key: _keyFor(_gridStart + i),
                width: tileWidth,
                child: _buildSystemTile(
                  context,
                  _systems[i],
                  _focused(_gridStart + i),
                ),
              ),
          ],
        );
      },
    );
  }

  Widget _buildSystemTile(
    BuildContext context,
    Map<String, dynamic> system,
    bool focused,
  ) {
    final theme = Theme.of(context);
    final id = system['id'].toString();
    final enabled = _enabledSystems[id] ?? false;

    return InkWell(
      canRequestFocus: false,
      focusColor: Colors.transparent,
      hoverColor: Colors.transparent,
      highlightColor: Colors.transparent,
      splashColor: Colors.transparent,
      onTap: () {
        SfxService().playNavSound();
        _toggleSystem(id);
      },
      borderRadius: BorderRadius.circular(8.r),
      child: Container(
        padding: EdgeInsets.all(4.r),
        decoration: BoxDecoration(
          color: enabled
              ? theme.cardColor.withValues(alpha: 0.6)
              : theme.cardColor.withValues(alpha: 0.3),
          borderRadius: BorderRadius.circular(8.r),
          border: Border.all(
            color: focused
                ? theme.colorScheme.primary
                : enabled
                ? Colors.greenAccent
                : theme.colorScheme.outline.withValues(alpha: 0.1),
            width: focused ? 2.r : 1.5.r,
          ),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 24.r,
              height: 24.r,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: enabled
                    ? Colors.greenAccent.withValues(alpha: 0.25)
                    : theme.cardColor.withValues(alpha: 0.25),
                border: Border.all(
                  color: enabled
                      ? Colors.greenAccent
                      : theme.colorScheme.outline.withValues(alpha: 0.4),
                  width: 1.5.r,
                ),
              ),
              child: Center(
                child: Icon(
                  enabled ? Symbols.check_rounded : Symbols.add_rounded,
                  color: enabled
                      ? Colors.greenAccent
                      : theme.colorScheme.onSurface.withValues(alpha: 0.5),
                  size: 14.r,
                ),
              ),
            ),
            SizedBox(height: 2.r),
            Text(
              system['name'].toString(),
              style: TextStyle(
                color: theme.colorScheme.onSurface.withValues(
                  alpha: enabled ? 0.9 : 0.5,
                ),
                fontSize: 9.r,
                fontWeight: enabled ? FontWeight.w600 : FontWeight.normal,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}
