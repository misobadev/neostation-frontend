import 'package:flutter/material.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:provider/provider.dart';
import 'package:neostation/l10n/app_locale.dart';
import 'package:neostation/models/neoassets_scrape_models.dart';
import 'package:neostation/providers/scraping_provider.dart';
import 'package:neostation/repositories/neoassets_settings_repository.dart';
import 'package:neostation/services/logger_service.dart';
import 'package:neostation/services/neoassets_scraper/neoassets_scrape_service.dart';
import 'package:neostation/services/sfx_service.dart';
import 'package:neostation/utils/adaptive_scroll.dart';
import 'package:neostation/widgets/custom_notification.dart';

import '../widgets/scraping_progress_panel.dart';
import '../widgets/setting_row.dart';
import '../widgets/setting_value_chip.dart';
import '../widgets/settings_section_header.dart';
import 'neoassets_brand.dart';
import 'neoassets_login_dialog.dart';
import 'neoassets_scrape_session.dart';

/// The NeoAssets half of Settings → Metadata, shown while the user is signed
/// in to NeoAssets.
///
/// Deliberately small: NeoAssets returns every
/// language and picks media server-side, so there is no language or region
/// list to manage. One gamepad cursor walks, in page order: the account card
/// (its button switches provider; a guest also gets Login, Left/Right between
/// the two), Scrape, Scrape mode, the media chips (a
/// single row, Left/Right between them), Enable all, and the systems grid.
class NeoAssetsSettingsContent extends StatefulWidget {
  final bool isContentFocused;

  /// Called after the user signed out, to show the provider chooser again.
  final VoidCallback onSignedOut;

  const NeoAssetsSettingsContent({
    super.key,
    required this.isContentFocused,
    required this.onSignedOut,
  });

  @override
  State<NeoAssetsSettingsContent> createState() =>
      NeoAssetsSettingsContentState();
}

class NeoAssetsSettingsContentState extends State<NeoAssetsSettingsContent> {
  static final _log = LoggerService.instance;

  static const List<String> _mediaTypes = [
    'box2D',
    'ss',
    'wheel',
    'fanart',
    'video',
  ];

  static const int _gridColumns = 6;

  static const int _accountSlot = 0;
  static const int _scrapeSlot = 1;
  static const int _modeSlot = 2;
  static const int _mediaStart = 3;
  static int get _mediaEnd => _mediaStart + _mediaTypes.length;
  static int get _toggleAllSlot => _mediaEnd;
  static int get _gridStart => _toggleAllSlot + 1;
  int get _gridEnd => _gridStart + _systems.length;

  final ScrollController _scrollController = ScrollController();
  final AdaptiveScroller _scroller = AdaptiveScroller();
  final List<GlobalKey> _itemKeys = [];

  bool _isLoading = true;
  NeoAssetsAccount? _account;
  bool _guest = false;

  /// The account card's button under the cursor for a guest: 0 Login, 1
  /// Switch. A signed-in user has only Switch.
  int _accountButton = 0;
  String _scrapeMode = 'new_only';
  List<String> _enabledMedia = [];
  List<Map<String, dynamic>> _systems = [];
  Map<String, bool> _enabledSystems = {};
  int _cursor = 0;

  bool _isMediaSlot(int slot) => slot >= _mediaStart && slot < _mediaEnd;
  bool _isGridSlot(int slot) => slot >= _gridStart && slot < _gridEnd;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant NeoAssetsSettingsContent oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.isContentFocused && !widget.isContentFocused) {
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
    try {
      final cached = await NeoAssetsScrapeService.cachedAccount();
      final guest = await NeoAssetsScrapeService.isGuest();
      final scrapeMode = await NeoAssetsSettingsRepository.getScrapeMode();
      final media = await NeoAssetsSettingsRepository.getMediaTypes();
      final systems = await NeoAssetsScrapeService.getSystems();
      final enabled = await NeoAssetsScrapeService.getEnabledSystems(systems);
      if (!mounted) return;
      setState(() {
        _account = cached;
        _guest = guest;
        _scrapeMode = scrapeMode;
        _enabledMedia = List<String>.from(media);
        _systems = systems;
        _enabledSystems = enabled;
        _isLoading = false;
      });
      _refreshAccount();
    } catch (e) {
      _log.e('Error loading NeoAssets settings: $e');
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _refreshAccount() async {
    final account = await NeoAssetsScrapeService.refreshAccount();
    if (mounted && account != null) setState(() => _account = account);
  }

  // ==========================================
  // GAMEPAD NAVIGATION (driven by the Metadata page)
  // ==========================================

  int getItemCount() => _isLoading ? 0 : _gridEnd;

  bool navigateUp() {
    if (_cursor == 0) return false;
    int next;
    if (_isGridSlot(_cursor)) {
      final i = _cursor - _gridStart;
      next = i < _gridColumns ? _toggleAllSlot : _cursor - _gridColumns;
    } else if (_isMediaSlot(_cursor)) {
      next = _modeSlot;
    } else if (_cursor == _toggleAllSlot) {
      next = _mediaStart;
    } else {
      next = _cursor - 1;
    }
    _setCursor(next);
    return true;
  }

  bool navigateDown() {
    final count = getItemCount();
    if (_cursor >= count - 1) return false;
    int next;
    if (_isGridSlot(_cursor)) {
      next = _cursor + _gridColumns;
      if (next >= _gridEnd) {
        final lastRowStart =
            _gridStart + ((_systems.length - 1) ~/ _gridColumns) * _gridColumns;
        if (_cursor >= lastRowStart) return false;
        next = _gridEnd - 1;
      }
    } else if (_isMediaSlot(_cursor)) {
      next = _toggleAllSlot;
    } else {
      next = _cursor + 1;
    }
    _setCursor(next);
    return true;
  }

  /// Returns true when focus should go back to the category menu.
  bool navigateLeft() {
    if (_cursor == _accountSlot && _guest && _accountButton == 1) {
      setState(() => _accountButton = 0);
      return false;
    }
    if (_isMediaSlot(_cursor) && _cursor > _mediaStart) {
      _setCursor(_cursor - 1);
      return false;
    }
    if (_isGridSlot(_cursor) && (_cursor - _gridStart) % _gridColumns != 0) {
      _setCursor(_cursor - 1);
      return false;
    }
    return true;
  }

  void navigateRight() {
    if (_cursor == _accountSlot && _guest && _accountButton == 0) {
      setState(() => _accountButton = 1);
      return;
    }
    if (_isMediaSlot(_cursor)) {
      if (_cursor + 1 < _mediaEnd) _setCursor(_cursor + 1);
      return;
    }
    if (!_isGridSlot(_cursor)) return;
    final i = _cursor - _gridStart;
    if (i % _gridColumns == _gridColumns - 1 || _cursor + 1 >= _gridEnd) {
      return;
    }
    _setCursor(_cursor + 1);
  }

  bool navigateBack() => false;

  void selectItem() {
    if (_isLoading) return;
    final slot = _cursor;
    if (slot == _accountSlot) {
      if (_guest && _accountButton == 0) {
        _signInWithKey();
      } else {
        _switchProvider();
      }
    } else if (slot == _scrapeSlot) {
      _toggleScraping();
    } else if (slot == _modeSlot) {
      _setScrapeMode(_scrapeMode == 'all' ? 'new_only' : 'all');
    } else if (_isMediaSlot(slot)) {
      final type = _mediaTypes[slot - _mediaStart];
      _setMedia(type, !_enabledMedia.contains(type));
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

  /// Refuses, with a notice, while a session is scraping.
  bool _refuseWhileScraping() {
    if (!context.read<ScrapingProvider>().isScraping) return false;
    AppNotification.showNotification(
      context,
      AppLocale.scrapingInProgress.getString(context),
      type: NotificationType.info,
    );
    return true;
  }

  void _switchProvider() {
    if (_refuseWhileScraping()) return;
    widget.onSignedOut();
  }

  /// Upgrades a guest to their own account with a personal key.
  Future<void> _signInWithKey() async {
    if (_refuseWhileScraping()) return;
    final ok = await NeoAssetsLoginDialog.show(context, allowGuest: false);
    if (!ok || !mounted) return;
    final account = await NeoAssetsScrapeService.cachedAccount();
    if (!mounted) return;
    setState(() {
      _guest = false;
      _accountButton = 0;
      _account = account;
    });
  }

  void _toggleScraping() {
    if (context.read<ScrapingProvider>().isScraping) {
      stopNeoAssetsScrapeSession(context);
    } else {
      startNeoAssetsScrapeSession(
        context,
        onFinished: () async {
          if (!mounted) return;
          final account = await NeoAssetsScrapeService.cachedAccount();
          if (mounted && account != null) setState(() => _account = account);
        },
      );
    }
  }

  Future<void> _setScrapeMode(String mode) async {
    final previous = _scrapeMode;
    setState(() => _scrapeMode = mode);
    final ok = await NeoAssetsSettingsRepository.saveScrapeMode(mode);
    if (!mounted || ok) return;
    setState(() => _scrapeMode = previous);
    AppNotification.showNotification(
      context,
      AppLocale.scrapeModeError.getString(context),
      type: NotificationType.error,
    );
  }

  Future<void> _setMedia(String type, bool enabled) async {
    final types = List<String>.from(_enabledMedia);
    if (enabled) {
      if (!types.contains(type)) types.add(type);
    } else {
      types.remove(type);
    }
    final ok = await NeoAssetsSettingsRepository.saveMediaTypes(types);
    if (mounted && ok) setState(() => _enabledMedia = types);
  }

  Future<void> _toggleSystem(String id) async {
    final previous = _enabledSystems[id] ?? true;
    setState(() => _enabledSystems[id] = !previous);
    final ok = await NeoAssetsSettingsRepository.saveSystems({id: !previous});
    if (!mounted || ok) return;
    setState(() => _enabledSystems[id] = previous);
  }

  bool get _allEnabled =>
      _systems.every((s) => _enabledSystems[s['id'].toString()] == true);

  Future<void> _toggleAllSystems() async {
    final enable = !_allEnabled;
    final ids = _systems.map((s) => s['id'].toString()).toList();
    setState(() {
      for (final id in ids) {
        _enabledSystems[id] = enable;
      }
    });
    await NeoAssetsSettingsRepository.saveSystems({
      for (final id in ids) id: enable,
    });
  }

  // ==========================================
  // BUILD
  // ==========================================

  @override
  Widget build(BuildContext context) {
    if (_isLoading) return const Center(child: CircularProgressIndicator());
    return SingleChildScrollView(
      controller: _scrollController,
      padding: EdgeInsets.only(top: 6.r, bottom: 12.r),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          KeyedSubtree(
            key: _keyFor(_accountSlot),
            child: _NeoAssetsAccountCard(
              account: _account,
              focusedButton: _focused(_accountSlot)
                  ? (_guest ? _accountButton : 1)
                  : null,
              onSignIn: _guest ? _signInWithKey : null,
              onSwitch: _switchProvider,
            ),
          ),
          SizedBox(height: 14.r),
          SettingsSectionHeader(label: AppLocale.scraping.getString(context)),
          _buildScrapeRow(context),
          SizedBox(height: 8.r),
          SettingRow(
            key: _keyFor(_modeSlot),
            title: AppLocale.scrapeMode.getString(context),
            subtitle: _scrapeMode == 'all'
                ? AppLocale.allContentDesc.getString(context)
                : AppLocale.newContentOnlyDesc.getString(context),
            focused: _focused(_modeSlot),
            onTap: () =>
                _setScrapeMode(_scrapeMode == 'all' ? 'new_only' : 'all'),
            trailing: SettingValueChip(
              text: _scrapeMode == 'all'
                  ? AppLocale.allContent.getString(context)
                  : AppLocale.newContentOnly.getString(context),
            ),
          ),
          SizedBox(height: 14.r),
          SettingsSectionHeader(label: AppLocale.media.getString(context)),
          _buildMediaChips(context),
          SizedBox(height: 14.r),
          SettingsSectionHeader(label: AppLocale.systems.getString(context)),
          SettingRow(
            key: _keyFor(_toggleAllSlot),
            title: _allEnabled
                ? AppLocale.disableAll.getString(context)
                : AppLocale.enableAll.getString(context),
            subtitle: AppLocale.neoAssetsSystemsSub.getString(context),
            focused: _focused(_toggleAllSlot),
            onTap: _toggleAllSystems,
            trailing: SettingValueChip(
              text:
                  '${_systems.where((s) => _enabledSystems[s['id'].toString()] == true).length} / ${_systems.length}',
            ),
          ),
          SizedBox(height: 8.r),
          _buildSystemsGrid(context),
        ],
      ),
    );
  }

  Widget _buildScrapeRow(BuildContext context) {
    return Consumer<ScrapingProvider>(
      builder: (context, scraping, _) {
        final focused = _focused(_scrapeSlot);
        final theme = Theme.of(context);
        return Column(
          key: _keyFor(_scrapeSlot),
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SettingRow(
              title: AppLocale.scraping.getString(context),
              subtitle: scraping.isScraping
                  ? '${AppLocale.scrapingInProgress.getString(context)} ${AppLocale.neoAssetsThreads.getString(context).replaceFirst('{count}', '${scraping.maxThreads}')}'
                  : AppLocale.neoAssetsScrapeSub.getString(context),
              focused: focused,
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
                  elevation: 0,
                  backgroundColor: focused
                      ? theme.colorScheme.surface
                      : (scraping.isScraping
                            ? theme.colorScheme.error
                            : NeoAssetsBrand.accent(context)),
                  foregroundColor: focused
                      ? theme.colorScheme.onSurface
                      : (scraping.isScraping
                            ? theme.colorScheme.onError
                            : NeoAssetsBrand.onAccent(context)),
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

  (String, IconData) _mediaLabel(BuildContext context, String type) =>
      switch (type) {
        'box2D' => (
          AppLocale.scrapeBox2D.getString(context),
          Symbols.book_2_rounded,
        ),
        'ss' => (
          AppLocale.scrapeScreenshot.getString(context),
          Symbols.photo_rounded,
        ),
        'wheel' => (
          AppLocale.scrapeWheel.getString(context),
          Symbols.title_rounded,
        ),
        'fanart' => (
          AppLocale.scrapeFanart.getString(context),
          Symbols.wallpaper_rounded,
        ),
        'video' => (
          AppLocale.scrapeVideo.getString(context),
          Symbols.movie_rounded,
        ),
        _ => (type, Symbols.image_rounded),
      };

  Widget _buildMediaChips(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      children: [
        for (var i = 0; i < _mediaTypes.length; i++) ...[
          if (i > 0) SizedBox(width: 6.r),
          Expanded(
            child: KeyedSubtree(
              key: _keyFor(_mediaStart + i),
              child: _buildMediaChip(theme, _mediaTypes[i], _mediaStart + i),
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildMediaChip(ThemeData theme, String type, int slot) {
    final enabled = _enabledMedia.contains(type);
    final focused = _focused(slot);
    final (label, icon) = _mediaLabel(context, type);
    final fg = focused
        ? theme.colorScheme.surface
        : (enabled
              ? NeoAssetsBrand.ink(context)
              : theme.colorScheme.onSurface.withValues(alpha: 0.5));
    return InkWell(
      canRequestFocus: false,
      borderRadius: BorderRadius.circular(10.r),
      onTap: () {
        SfxService().playNavSound();
        setState(() => _cursor = slot);
        _setMedia(type, !enabled);
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: EdgeInsets.symmetric(vertical: 8.r, horizontal: 4.r),
        decoration: BoxDecoration(
          color: focused
              ? theme.colorScheme.onSurface
              : (enabled
                    ? NeoAssetsBrand.accent(context).withValues(alpha: 0.12)
                    : theme.cardColor.withValues(alpha: 0.3)),
          borderRadius: BorderRadius.circular(10.r),
          border: Border.all(
            color: focused
                ? Colors.transparent
                : (enabled
                      ? NeoAssetsBrand.accent(context).withValues(alpha: 0.6)
                      : theme.colorScheme.outline.withValues(alpha: 0.15)),
            width: 1.2.r,
          ),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Stack(
              clipBehavior: Clip.none,
              children: [
                Icon(icon, size: 18.r, color: fg),
                Positioned(
                  right: -8.r,
                  top: -4.r,
                  child: Icon(
                    enabled
                        ? Symbols.check_circle_rounded
                        : Symbols.circle_rounded,
                    size: 9.r,
                    fill: enabled ? 1 : 0,
                    color: fg,
                  ),
                ),
              ],
            ),
            SizedBox(height: 4.r),
            Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 8.r,
                fontWeight: enabled ? FontWeight.w700 : FontWeight.w500,
                color: fg,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSystemsGrid(BuildContext context) {
    final theme = Theme.of(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        final spacing = 5.r;
        final width =
            (constraints.maxWidth - spacing * (_gridColumns - 1)) /
            _gridColumns;
        return Wrap(
          spacing: spacing,
          runSpacing: spacing,
          children: [
            for (var i = 0; i < _systems.length; i++)
              SizedBox(
                key: _keyFor(_gridStart + i),
                width: width,
                child: _buildSystemChip(theme, _systems[i], _gridStart + i),
              ),
          ],
        );
      },
    );
  }

  Widget _buildSystemChip(
    ThemeData theme,
    Map<String, dynamic> system,
    int slot,
  ) {
    final id = system['id'].toString();
    final enabled = _enabledSystems[id] ?? true;
    final focused = _focused(slot);
    final fg = focused
        ? theme.colorScheme.surface
        : theme.colorScheme.onSurface.withValues(alpha: enabled ? 0.95 : 0.45);
    return InkWell(
      canRequestFocus: false,
      borderRadius: BorderRadius.circular(8.r),
      onTap: () {
        SfxService().playNavSound();
        setState(() => _cursor = slot);
        _toggleSystem(id);
      },
      child: Container(
        padding: EdgeInsets.symmetric(horizontal: 6.r, vertical: 6.r),
        decoration: BoxDecoration(
          color: focused
              ? theme.colorScheme.onSurface
              : (enabled
                    ? NeoAssetsBrand.accent(context).withValues(alpha: 0.08)
                    : theme.cardColor.withValues(alpha: 0.25)),
          borderRadius: BorderRadius.circular(8.r),
          border: Border.all(
            color: focused
                ? Colors.transparent
                : (enabled
                      ? NeoAssetsBrand.accent(context).withValues(alpha: 0.45)
                      : theme.colorScheme.outline.withValues(alpha: 0.1)),
            width: 1.r,
          ),
        ),
        child: Row(
          children: [
            Icon(
              enabled ? Symbols.check_rounded : Symbols.add_rounded,
              size: 11.r,
              color: focused
                  ? fg
                  : (enabled ? NeoAssetsBrand.ink(context) : fg),
            ),
            SizedBox(width: 4.r),
            Expanded(
              child: Text(
                system['name'].toString(),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 8.r,
                  color: fg,
                  fontWeight: enabled ? FontWeight.w600 : FontWeight.normal,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The NeoAssets session: name (or Guest), threads and rate, today's lookups
/// (against the daily cap, on older servers that still have one) and the
/// provider switch; a guest also gets Login and a hint of what it adds.
class _NeoAssetsAccountCard extends StatelessWidget {
  final NeoAssetsAccount? account;

  /// The button under the gamepad cursor: 0 Login, 1 Switch, null none.
  final int? focusedButton;

  /// Set for a guest: opens the key sign-in.
  final VoidCallback? onSignIn;
  final VoidCallback onSwitch;

  const _NeoAssetsAccountCard({
    required this.account,
    required this.focusedButton,
    required this.onSignIn,
    required this.onSwitch,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final account = this.account;
    final used = account?.used ?? 0;
    final unlimited = account?.hasNoDailyLimit ?? true;
    final limit = unlimited ? 0 : account!.dailyLimit!;
    final progress = limit > 0 ? (used / limit).clamp(0.0, 1.0) : 0.0;
    final rate = account?.ratePerMinute ?? 0;

    return Container(
      padding: EdgeInsets.all(12.r),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(14.r),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            NeoAssetsBrand.accent(context).withValues(alpha: 0.16),
            NeoAssetsBrand.secondary(context).withValues(alpha: 0.08),
          ],
        ),
        border: Border.all(
          color: NeoAssetsBrand.accent(context).withValues(alpha: 0.3),
          width: 1.r,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const NeoAssetsBadge(size: 40),
              SizedBox(width: 12.r),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'NeoAssets',
                      style: TextStyle(
                        fontSize: 8.r,
                        letterSpacing: 1.2,
                        fontWeight: FontWeight.w700,
                        color: NeoAssetsBrand.ink(context),
                      ),
                    ),
                    Text(
                      onSignIn != null
                          ? AppLocale.neoAssetsGuest.getString(context)
                          : account?.username.isNotEmpty == true
                          ? account!.username
                          : AppLocale.unknownUser.getString(context),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.bold,
                        fontSize: 14.r,
                      ),
                    ),
                    SizedBox(height: 4.r),
                    Wrap(
                      spacing: 6.r,
                      runSpacing: 4.r,
                      children: [
                        _pill(
                          context,
                          Symbols.lan_rounded,
                          AppLocale.neoAssetsThreads
                              .getString(context)
                              .replaceFirst(
                                '{count}',
                                '${account?.threads ?? 1}',
                              ),
                        ),
                        if (rate > 0)
                          _pill(
                            context,
                            Symbols.speed_rounded,
                            AppLocale.neoAssetsRatePerMinute
                                .getString(context)
                                .replaceFirst('{count}', _format(rate)),
                          ),
                        _pill(
                          context,
                          Symbols.bolt_rounded,
                          unlimited
                              ? AppLocale.neoAssetsUnlimited.getString(context)
                              : AppLocale.neoAssetsDailyGames
                                    .getString(context)
                                    .replaceFirst('{count}', _format(limit)),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              SizedBox(width: 8.r),
              if (onSignIn != null) ...[
                _button(
                  context,
                  theme,
                  icon: Symbols.login_rounded,
                  label: AppLocale.login.getString(context),
                  focused: focusedButton == 0,
                  onTap: onSignIn!,
                  primary: true,
                ),
                SizedBox(width: 6.r),
              ],
              _button(
                context,
                theme,
                icon: Symbols.swap_horiz_rounded,
                label: AppLocale.switchProvider.getString(context),
                focused: focusedButton == 1,
                onTap: onSwitch,
              ),
            ],
          ),
          if (onSignIn != null) ...[
            SizedBox(height: 8.r),
            Text(
              AppLocale.neoAssetsGuestHint.getString(context),
              style: TextStyle(
                fontSize: 8.r,
                color: theme.colorScheme.onSurface.withValues(alpha: 0.65),
              ),
            ),
          ],
          SizedBox(height: 10.r),
          Row(
            children: [
              Text(
                AppLocale.neoAssetsUsedToday.getString(context),
                style: TextStyle(
                  fontSize: 9.r,
                  fontWeight: FontWeight.w600,
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.75),
                ),
              ),
              const Spacer(),
              Text(
                unlimited
                    ? _format(used)
                    : '${_format(used)} / ${_format(limit)}',
                style: TextStyle(
                  fontSize: 9.r,
                  fontWeight: FontWeight.bold,
                  color: NeoAssetsBrand.ink(context),
                ),
              ),
            ],
          ),
          if (!unlimited) ...[
            SizedBox(height: 5.r),
            ClipRRect(
              borderRadius: BorderRadius.circular(4.r),
              child: LinearProgressIndicator(
                value: progress,
                minHeight: 5.r,
                backgroundColor: NeoAssetsBrand.accent(context)
                    .withValues(alpha: 0.1),
                valueColor: AlwaysStoppedAnimation(
                  NeoAssetsBrand.accent(context),
                ),
              ),
            ),
          ],
          if (!unlimited && account?.resetsAt != null) ...[
            SizedBox(height: 4.r),
            Text(
              AppLocale.neoAssetsResetsIn
                  .getString(context)
                  .replaceFirst('{time}', _untilReset(account!.resetsAt!)),
              style: TextStyle(
                fontSize: 8.r,
                color: theme.colorScheme.onSurface.withValues(alpha: 0.5),
              ),
            ),
          ],
        ],
      ),
    );
  }

  /// A card button. [primary] fills it with the accent at rest, so Login
  /// stands out for a guest.
  Widget _button(
    BuildContext context,
    ThemeData theme, {
    required IconData icon,
    required String label,
    required bool focused,
    required VoidCallback onTap,
    bool primary = false,
  }) {
    final scheme = theme.colorScheme;
    final Color fill;
    final Color ink;
    if (focused) {
      fill = scheme.onSurface;
      ink = scheme.surface;
    } else if (primary) {
      fill = NeoAssetsBrand.accent(context);
      ink = NeoAssetsBrand.onAccent(context);
    } else {
      fill = scheme.onSurface.withValues(alpha: 0.06);
      ink = scheme.onSurface;
    }
    return InkWell(
      canRequestFocus: false,
      borderRadius: BorderRadius.circular(8.r),
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: EdgeInsets.symmetric(horizontal: 10.r, vertical: 7.r),
        decoration: BoxDecoration(
          color: fill,
          borderRadius: BorderRadius.circular(8.r),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 14.r, color: ink),
            SizedBox(width: 4.r),
            Text(
              label,
              style: TextStyle(
                fontSize: 9.r,
                fontWeight: FontWeight.w600,
                color: ink,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _pill(BuildContext context, IconData icon, String label) => Container(
    padding: EdgeInsets.symmetric(horizontal: 7.r, vertical: 3.r),
    decoration: BoxDecoration(
      color: NeoAssetsBrand.accent(context).withValues(alpha: 0.12),
      borderRadius: BorderRadius.circular(999.r),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 10.r, color: NeoAssetsBrand.ink(context)),
        SizedBox(width: 3.r),
        Text(
          label,
          style: TextStyle(
            fontSize: 8.r,
            fontWeight: FontWeight.w700,
            color: NeoAssetsBrand.ink(context),
          ),
        ),
      ],
    ),
  );

  static String _format(int n) {
    final s = n.toString();
    final buf = StringBuffer();
    for (var i = 0; i < s.length; i++) {
      if (i > 0 && (s.length - i) % 3 == 0) buf.write(',');
      buf.write(s[i]);
    }
    return buf.toString();
  }

  static String _untilReset(DateTime resetsAt) {
    final left = resetsAt.difference(DateTime.now().toUtc());
    if (left.isNegative) return '0m';
    final h = left.inHours;
    final m = left.inMinutes % 60;
    return h > 0 ? '${h}h ${m}m' : '${m}m';
  }
}
