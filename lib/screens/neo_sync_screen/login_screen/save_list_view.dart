import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';
import 'package:neostation/l10n/app_locale.dart';
import 'package:neostation/models/neo_sync_models.dart';
import 'package:neostation/providers/neo_sync_provider.dart';
import 'package:neostation/repositories/game_repository.dart';
import 'package:neostation/services/neosync/auth_service.dart';
import 'package:neostation/services/sfx_service.dart';
import 'package:neostation/utils/centered_scroll_controller.dart';
import 'package:neostation/utils/gamepad_nav.dart';
import 'package:neostation/services/gamepad/gamepad_navigation_manager.dart';
import 'package:neostation/widgets/custom_notification.dart' as custom;
import 'package:neostation/widgets/core_footer.dart';
import '../../app_screen.dart';
import 'neo_sync_dialogs.dart';

/// Region the gamepad focus currently lives in, mirroring the search tab.
enum _SaveRegion { search, filters, results, menu }

/// Full-screen Save List view.
///
/// Shows the user's online cloud saves with a gamepad-navigable search field,
/// filter chips (scope/system/emulator/sort) and a centered results list —
/// following the same region-based navigation as the game search tab. Replaces
/// the previous inline saves column with its own navigation layer.
class SaveListView extends StatefulWidget {
  final VoidCallback onBack;

  const SaveListView({super.key, required this.onBack});

  @override
  State<SaveListView> createState() => _SaveListViewState();
}

class _SaveListViewState extends State<SaveListView> {
  bool _isRefreshingOnlineFiles = false;
  bool _refreshCompleted = false;
  int _selectedSaveIndex = 0;
  bool _isNavigatingFast = false;
  late GamepadNavigation _savesGamepadNav;
  final GlobalKey<OnlineSavesListViewState> _onlineSavesListKey =
      GlobalKey<OnlineSavesListViewState>();

  final TextEditingController _onlineSearchController = TextEditingController();
  final FocusNode _onlineSearchFocus = FocusNode();
  Timer? _onlineSearchDebounce;

  DateTime? _lastSelectTime;
  static const int _selectThrottleMs = 500;

  /// Set while the delete prompt is open. Closing it pops its layer, which
  /// re-activates this list's layer; that activation must keep the highlighted
  /// save (and the clamp a delete applied) rather than jump back to the first.
  /// The reset would also land mid-teardown of the prompt, where its setState
  /// can't rebuild the list.
  bool _keepSelectionOnActivate = false;

  DateTime? _lastRefreshTime;

  // ── Region-based focus (mirrors the search tab) ─────────────────────────
  _SaveRegion _region = _SaveRegion.search;
  bool _filtersExpanded = true;
  int _searchIndex = 0;
  int _barIndex = 0;
  String? _menuKey;
  int _menuIndex = 0;

  // Chip row horizontal scroll (keeps the focused chip visible).
  final ScrollController _chipScroll = ScrollController();
  final Map<int, GlobalKey> _chipKeys = {};
  final ScrollController _menuScroll = ScrollController();
  static const double _menuExtent = 44;

  @override
  void initState() {
    super.initState();
    _initializeGamepad();
  }

  @override
  void dispose() {
    GamepadNavigationManager.popLayer('neo_sync_save_list');
    _onlineSearchDebounce?.cancel();
    _onlineSearchController.dispose();
    _onlineSearchFocus.dispose();
    _savesGamepadNav.dispose();
    _chipScroll.dispose();
    _menuScroll.dispose();
    super.dispose();
  }

  void _initializeGamepad() {
    _savesGamepadNav = GamepadNavigation(
      onNavigateUp: (isRepeat) {
        if (_isNavigatingFast != isRepeat) {
          setState(() => _isNavigatingFast = isRepeat);
        }
        _navigateUp();
      },
      onNavigateDown: (isRepeat) {
        if (_isNavigatingFast != isRepeat) {
          setState(() => _isNavigatingFast = isRepeat);
        }
        _navigateDown();
      },
      onNavigateLeft: (isRepeat) => _navigateLeft(),
      onNavigateRight: (isRepeat) => _navigateRight(),
      onSelectItem: _handleSelect,
      onPreviousTab: () => AppNavigation.previousTab(),
      onNextTab: () => AppNavigation.nextTab(),
      onBack: _handleBack,
      onFavorite: () {
        if (mounted) widget.onBack();
      },
      onXButton: () {
        // X button refreshes the online saves.
        if (!_isRefreshingOnlineFiles && !_refreshCompleted) {
          _refreshOnlineFiles();
        }
      },
      onSelectButton: _selectSaveItem,
      onSettings: () {},
    );

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _savesGamepadNav.initialize();
      GamepadNavigationManager.pushLayer(
        'neo_sync_save_list',
        onActivate: () {
          _savesGamepadNav.activate();
          if (_keepSelectionOnActivate) {
            _keepSelectionOnActivate = false;
          } else {
            _resetSelection();
          }
        },
        onDeactivate: () => _savesGamepadNav.deactivate(),
      );
    });
  }

  // ── Region helpers ──────────────────────────────────────────────────────

  /// Focusable items in the search band, left to right.
  List<String> get _searchItems => [
    'field',
    if (_onlineSearchController.text.isNotEmpty) 'clearQuery',
    'filters',
  ];

  int get _lastSearchIndex => _searchItems.length - 1;

  String get _focusedSearchItem =>
      _searchItems[_searchIndex.clamp(0, _lastSearchIndex)];

  bool _searchFocused(String key) =>
      _region == _SaveRegion.search && _focusedSearchItem == key;

  /// Focusable filter chips, left to right.
  List<String> get _barItems => ['scope', 'system', 'emulator', 'sort'];

  void _toggleFilters() {
    setState(() {
      _onlineSearchFocus.unfocus();
      _filtersExpanded = !_filtersExpanded;
      if (_filtersExpanded) {
        _region = _SaveRegion.filters;
        _barIndex = 0;
      } else {
        _region = _SaveRegion.search;
        _searchIndex = _searchItems.indexOf('filters');
      }
    });
    SfxService().playNavSound();
  }

  void _clearQuery() {
    setState(() {
      _onlineSearchController.clear();
      _region = _SaveRegion.search;
      _searchIndex = 0;
    });
    _onOnlineSearchChanged('');
    SfxService().playNavSound();
  }

  void _focusNameField() {
    if (_region == _SaveRegion.search && _searchIndex == 0) return;
    setState(() {
      _region = _SaveRegion.search;
      _searchIndex = 0;
    });
    SfxService().playNavSound();
  }

  void _jumpToSearchItem(String item) {
    final index = _searchItems.indexOf(item);
    if (index < 0) return;
    setState(() {
      _region = _SaveRegion.search;
      _searchIndex = index;
    });
    SfxService().playNavSound();
  }

  void _navigateLeft() {
    switch (_region) {
      case _SaveRegion.menu:
        _moveMenuSelection(-1);
      case _SaveRegion.search:
        setState(
          () => _searchIndex = (_searchIndex - 1).clamp(0, _lastSearchIndex),
        );
        SfxService().playNavSound();
      case _SaveRegion.filters:
        setState(
          () =>
              _barIndex = (_barIndex - 1 + _barItems.length) % _barItems.length,
        );
        _scrollChipIntoView();
        SfxService().playNavSound();
      case _SaveRegion.results:
        _jumpToSearchItem('field');
    }
  }

  void _navigateRight() {
    switch (_region) {
      case _SaveRegion.menu:
        _moveMenuSelection(1);
      case _SaveRegion.search:
        setState(
          () => _searchIndex = (_searchIndex + 1).clamp(0, _lastSearchIndex),
        );
        SfxService().playNavSound();
      case _SaveRegion.filters:
        setState(() => _barIndex = (_barIndex + 1) % _barItems.length);
        _scrollChipIntoView();
        SfxService().playNavSound();
      case _SaveRegion.results:
        _jumpToSearchItem('filters');
    }
  }

  void _navigateUp() {
    switch (_region) {
      case _SaveRegion.menu:
        _moveMenuSelection(-1);
      case _SaveRegion.results:
        if (_selectedSaveIndex == 0) {
          setState(() {
            _region = _filtersExpanded
                ? _SaveRegion.filters
                : _SaveRegion.search;
          });
        } else {
          _navigateSavesUp();
        }
      case _SaveRegion.filters:
        setState(() => _region = _SaveRegion.search);
      case _SaveRegion.search:
        break; // already at the top
    }
    SfxService().playNavSound();
  }

  void _navigateDown() {
    switch (_region) {
      case _SaveRegion.menu:
        _moveMenuSelection(1);
      case _SaveRegion.search:
        _onlineSearchFocus.unfocus();
        setState(() {
          _region = _filtersExpanded
              ? _SaveRegion.filters
              : _SaveRegion.results;
          if (_filtersExpanded) _barIndex = 0;
        });
      case _SaveRegion.filters:
        _enterResults();
      case _SaveRegion.results:
        _navigateSavesDown();
    }
    SfxService().playNavSound();
  }

  void _enterResults() {
    final neoSyncProvider = Provider.of<NeoSyncProvider>(
      context,
      listen: false,
    );
    if (neoSyncProvider.onlineFiles.isEmpty) return;
    setState(() {
      _onlineSearchFocus.unfocus();
      _region = _SaveRegion.results;
      _selectedSaveIndex = _selectedSaveIndex.clamp(
        0,
        neoSyncProvider.onlineFiles.length - 1,
      );
    });
  }

  void _handleSelect() {
    switch (_region) {
      case _SaveRegion.menu:
        _applyMenuIndex();
      case _SaveRegion.search:
        switch (_focusedSearchItem) {
          case 'clearQuery':
            _clearQuery();
          case 'filters':
            _toggleFilters();
          default:
            _onlineSearchFocus.requestFocus();
        }
      case _SaveRegion.filters:
        _openFilterMenu(_barItems[_barIndex]);
      case _SaveRegion.results:
        _selectSaveItem();
    }
  }

  void _handleBack() {
    if (_onlineSearchFocus.hasFocus) {
      _onlineSearchFocus.unfocus();
      return;
    }
    switch (_region) {
      case _SaveRegion.menu:
        _cancelMenu();
      case _SaveRegion.results:
        setState(() {
          _region = _filtersExpanded ? _SaveRegion.filters : _SaveRegion.search;
          if (!_filtersExpanded) _searchIndex = 0;
        });
      case _SaveRegion.filters:
        setState(() => _region = _SaveRegion.search);
      case _SaveRegion.search:
        // Top of the save list: go back to the dashboard.
        widget.onBack();
    }
  }

  // ── Filter value menu (mirrors the search tab) ──────────────────────────

  void _openFilterMenu(String key) {
    setState(() {
      _onlineSearchFocus.unfocus();
      _menuKey = key;
      _menuIndex = _menuSelectedIndex(key);
      _region = _SaveRegion.menu;
    });
    _scrollMenuIntoView();
    SfxService().playNavSound();
  }

  void _cancelMenu() {
    setState(() {
      _menuKey = null;
      _region = _SaveRegion.filters;
    });
  }

  void _moveMenuSelection(int delta) {
    final count = _menuOptions(_menuKey ?? '').length;
    if (count == 0) return;
    setState(() => _menuIndex = (_menuIndex + delta + count) % count);
    _scrollMenuIntoView();
  }

  void _applyMenuIndex() {
    final key = _menuKey;
    if (key == null) return;
    final options = _menuOptions(key);
    if (_menuIndex >= options.length) {
      _cancelMenu();
      return;
    }
    final option = options[_menuIndex];
    final neoSyncProvider = Provider.of<NeoSyncProvider>(
      context,
      listen: false,
    );
    final filter = neoSyncProvider.onlineFilter;
    switch (key) {
      case 'scope':
        _applyOnlineFilter(
          neoSyncProvider,
          filter.copyWith(scope: option.value),
        );
      case 'system':
        _applyOnlineFilter(
          neoSyncProvider,
          filter.copyWith(system: option.value),
        );
      case 'emulator':
        _applyOnlineFilter(
          neoSyncProvider,
          filter.copyWith(emulator: option.value),
        );
      case 'sort':
        if (option.value != null) {
          final parts = option.value!.split('_');
          _applyOnlineFilter(
            neoSyncProvider,
            filter.copyWith(sort: parts[0], dir: parts[1]),
          );
        }
    }
    setState(() => _menuKey = null);
    _region = _SaveRegion.filters;
    SfxService().playNavSound();
  }

  int _menuSelectedIndex(String key) {
    final neoSyncProvider = Provider.of<NeoSyncProvider>(
      context,
      listen: false,
    );
    final filter = neoSyncProvider.onlineFilter;
    final options = _menuOptions(key);
    final String? current = switch (key) {
      'scope' => filter.scope,
      'system' => filter.system,
      'emulator' => filter.emulator,
      'sort' => '${filter.sort ?? 'modified'}_${filter.dir ?? 'desc'}',
      _ => null,
    };
    final i = options.indexWhere((o) => o.value == current);
    return i < 0 ? 0 : i;
  }

  List<_FilterOption> _menuOptions(String key) {
    final neoSyncProvider = Provider.of<NeoSyncProvider>(
      context,
      listen: false,
    );
    switch (key) {
      case 'scope':
        return [
          _FilterOption(
            label: AppLocale.filterAll.getString(context),
            value: null,
          ),
          _FilterOption(
            label: AppLocale.filterPerGameSaves.getString(context),
            value: 'game',
          ),
          _FilterOption(
            label: AppLocale.filterMemoryCards.getString(context),
            value: 'shared',
          ),
        ];
      case 'system':
        return [
          _FilterOption(
            label: AppLocale.filterAll.getString(context),
            value: null,
          ),
          ...neoSyncProvider.onlineSystems.map(
            (s) => _FilterOption(label: s, value: s),
          ),
        ];
      case 'emulator':
        return [
          _FilterOption(
            label: AppLocale.filterAll.getString(context),
            value: null,
          ),
          ...neoSyncProvider.onlineEmulators.map(
            (e) => _FilterOption(label: e, value: e),
          ),
        ];
      case 'sort':
        return [
          _FilterOption(
            label: AppLocale.sortNewest.getString(context),
            value: 'modified_desc',
          ),
          _FilterOption(
            label: AppLocale.sortOldest.getString(context),
            value: 'modified_asc',
          ),
          _FilterOption(
            label: AppLocale.sortNameAsc.getString(context),
            value: 'name_asc',
          ),
          _FilterOption(
            label: AppLocale.sortNameDesc.getString(context),
            value: 'name_desc',
          ),
        ];
      default:
        return const [];
    }
  }

  String _barLabel(String key) {
    final neoSyncProvider = Provider.of<NeoSyncProvider>(
      context,
      listen: false,
    );
    final filter = neoSyncProvider.onlineFilter;
    final String label = switch (key) {
      'scope' => AppLocale.filterScope.getString(context),
      'system' => AppLocale.filterSystem.getString(context),
      'emulator' => AppLocale.filterEmulator.getString(context),
      'sort' => AppLocale.filterSort.getString(context),
      _ => '',
    };
    final String? value = switch (key) {
      'scope' =>
        filter.scope == 'game'
            ? AppLocale.scopePerGame.getString(context)
            : filter.scope == 'shared'
            ? AppLocale.scopeMemCards.getString(context)
            : null,
      'system' => filter.system,
      'emulator' => filter.emulator,
      'sort' => '${filter.sort ?? 'modified'} ${filter.dir ?? 'desc'}',
      _ => null,
    };
    return '$label: ${value ?? AppLocale.filterAll.getString(context)}';
  }

  void _scrollChipIntoView() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final chipContext = _chipKeys[_barIndex]?.currentContext;
      if (chipContext == null) return;
      Scrollable.ensureVisible(
        chipContext,
        alignment: 0.5,
        duration: const Duration(milliseconds: 140),
        curve: Curves.easeOut,
      );
    });
  }

  void _scrollMenuIntoView() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_menuScroll.hasClients) return;
      final pos = _menuScroll.position;
      final target =
          (_menuIndex * _menuExtent.r) -
          (pos.viewportDimension - _menuExtent.r) / 2;
      pos.animateTo(
        target.clamp(pos.minScrollExtent, pos.maxScrollExtent),
        duration: const Duration(milliseconds: 140),
        curve: Curves.easeOut,
      );
    });
  }

  // ── Existing save list logic ────────────────────────────────────────────

  void _resetSelection() {
    if (!mounted) return;
    setState(() => _selectedSaveIndex = 0);
  }

  void _navigateSavesUp() {
    final neoSyncProvider = Provider.of<NeoSyncProvider>(
      context,
      listen: false,
    );
    if (neoSyncProvider.onlineFiles.isNotEmpty) {
      final newIndex = _selectedSaveIndex > 0
          ? _selectedSaveIndex - 1
          : neoSyncProvider.onlineFiles.length - 1;
      _updateSelectionIndex(newIndex);
    }
  }

  void _navigateSavesDown() {
    final neoSyncProvider = Provider.of<NeoSyncProvider>(
      context,
      listen: false,
    );
    if (neoSyncProvider.onlineFiles.isNotEmpty) {
      final newIndex =
          (_selectedSaveIndex + 1) % neoSyncProvider.onlineFiles.length;
      _updateSelectionIndex(newIndex);
    }
  }

  void _updateSelectionIndex(int newIndex) {
    if (_selectedSaveIndex == newIndex) return;
    setState(() => _selectedSaveIndex = newIndex);
  }

  Future<void> _selectSaveItem() async {
    final now = DateTime.now();
    if (_lastSelectTime != null &&
        now.difference(_lastSelectTime!).inMilliseconds < _selectThrottleMs) {
      return;
    }
    _lastSelectTime = now;

    final neoSyncProvider = Provider.of<NeoSyncProvider>(
      context,
      listen: false,
    );
    if (neoSyncProvider.onlineFiles.isNotEmpty &&
        _selectedSaveIndex < neoSyncProvider.onlineFiles.length) {
      final selectedFile = neoSyncProvider.onlineFiles[_selectedSaveIndex];

      bool disableNeoSync = false;
      final confirmed = await _showDeleteDialog(selectedFile, (value) {
        disableNeoSync = value;
      });

      if (confirmed == true) {
        if (disableNeoSync) {
          try {
            final systemFolderName =
                await GameRepository.getSystemFolderForGame(
                  selectedFile.gameName,
                );
            if (systemFolderName != null) {
              await GameRepository.updateCloudSyncEnabled(
                systemFolderName,
                selectedFile.gameName,
                false,
              );
            }
          } catch (e) {
            if (!mounted) return;
            custom.AppNotification.showNotification(
              context,
              AppLocale.failedToDisableNeoSync.getString(context),
              type: custom.NotificationType.error,
            );
          }
        }

        final success = await neoSyncProvider.deleteOnlineFile(selectedFile.id);
        if (success) {
          final remainingFiles = neoSyncProvider.onlineFiles.length - 1;
          if (_selectedSaveIndex >= remainingFiles && remainingFiles > 0) {
            setState(() => _selectedSaveIndex = remainingFiles - 1);
          } else if (remainingFiles == 0) {
            setState(() => _selectedSaveIndex = 0);
          }
          await neoSyncProvider.loadQuota();
          if (!mounted) return;
          custom.AppNotification.showNotification(
            context,
            AppLocale.saveFileDeleted.getString(context),
            type: custom.NotificationType.success,
          );
        } else {
          if (!mounted) return;
          custom.AppNotification.showNotification(
            context,
            AppLocale.failedToDeleteSave.getString(context),
            type: custom.NotificationType.error,
          );
        }
      }
    }
  }

  Future<bool?> _showDeleteDialog(
    NeoSyncFile file,
    Function(bool) onDisableNeoSyncChanged,
  ) async {
    // The prompt's own layer takes the controller from this list and hands it
    // back when it closes; the list keeps the save the user chose. The layer is
    // pushed after the prompt's first frame, so let go of the controller now
    // rather than share that frame's presses with it.
    _keepSelectionOnActivate = true;
    _savesGamepadNav.deactivate();
    return showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (BuildContext context) {
        return DeleteCloudSaveDialog(
          file: file,
          onDisableNeoSyncChanged: onDisableNeoSyncChanged,
        );
      },
    );
  }

  Future<void> _refreshOnlineFiles() async {
    if (_isRefreshingOnlineFiles || _refreshCompleted) return;
    final now = DateTime.now();
    if (_lastRefreshTime != null &&
        now.difference(_lastRefreshTime!).inSeconds < 3) {
      return;
    }

    setState(() {
      _isRefreshingOnlineFiles = true;
      _refreshCompleted = false;
      _lastRefreshTime = now;
    });

    try {
      final authService = Provider.of<AuthService>(context, listen: false);
      final neoSyncProvider = Provider.of<NeoSyncProvider>(
        context,
        listen: false,
      );

      await authService.getProfile();
      await neoSyncProvider.loadQuota();
      await neoSyncProvider.loadOnlineFiles();

      if (!mounted) return;
      _resetSelection();
      setState(() {
        _isRefreshingOnlineFiles = false;
        _refreshCompleted = true;
      });

      Future.delayed(Duration(seconds: 3), () {
        if (!mounted) return;
        setState(() => _refreshCompleted = false);
      });

      custom.AppNotification.showNotification(
        context,
        AppLocale.cloudStorageRefreshed.getString(context),
        type: custom.NotificationType.info,
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isRefreshingOnlineFiles = false;
        _refreshCompleted = false;
      });
      custom.AppNotification.showNotification(
        context,
        AppLocale.failedToRefreshCloud.getString(context),
        type: custom.NotificationType.error,
      );
    }
  }

  void _onOnlineSearchChanged(String value) {
    _onlineSearchDebounce?.cancel();
    _onlineSearchDebounce = Timer(const Duration(milliseconds: 400), () {
      if (!mounted) return;
      final provider = Provider.of<NeoSyncProvider>(context, listen: false);
      final query = value.trim();
      provider.setOnlineFilter(
        provider.onlineFilter.copyWith(query: query.isEmpty ? null : query),
      );
      _resetSelection();
    });
  }

  void _applyOnlineFilter(NeoSyncProvider provider, NeoSyncFileFilter filter) {
    provider.setOnlineFilter(filter);
    _resetSelection();
  }

  // ── Build ───────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Stack(
      children: [
        Padding(
          padding: EdgeInsets.only(
            top: 52.r,
            left: 8.r,
            right: 8.r,
            bottom: 8.r,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _buildSearchRow(theme),
              if (_filtersExpanded) ...[
                SizedBox(height: 6.r),
                _buildFilterChips(theme),
              ],
              SizedBox(height: 8.r),
              Expanded(
                child: Consumer<NeoSyncProvider>(
                  builder: (context, neoSyncProvider, child) {
                    return Container(
                      padding: EdgeInsets.all(6.r),
                      decoration: BoxDecoration(
                        color: theme.cardColor.withValues(alpha: 0.25),
                        borderRadius: BorderRadius.circular(12.r),
                        border: Border.all(
                          color: theme.colorScheme.primary.withValues(
                            alpha: 0.15,
                          ),
                          width: 1.r,
                        ),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(
                            child: neoSyncProvider.isLoadingOnlineFiles
                                ? const Center(
                                    child: CircularProgressIndicator(),
                                  )
                                : neoSyncProvider.onlineFiles.isEmpty
                                ? _buildEmptyState(context, neoSyncProvider)
                                : OnlineSavesListView(
                                    key: _onlineSavesListKey,
                                    files: neoSyncProvider.onlineFiles,
                                    selectedIndex: _selectedSaveIndex,
                                    isNavigatingFast: _isNavigatingFast,
                                    onSelectionChanged: (index) {
                                      _updateSelectionIndex(index);
                                    },
                                  ),
                          ),
                          _buildPagination(context, neoSyncProvider),
                        ],
                      ),
                    );
                  },
                ),
              ),
              SizedBox(height: 6.r),
              _buildFooter(context),
            ],
          ),
        ),
        if (_region == _SaveRegion.menu && _menuKey != null)
          _buildFilterMenu(theme, _menuKey!),
      ],
    );
  }

  Widget _buildSearchRow(ThemeData theme) {
    return Row(
      children: [
        Expanded(child: _buildNameField(theme, _searchFocused('field'))),
        SizedBox(width: 10.r),
        _buildAdvancedToggle(theme, _searchFocused('filters')),
      ],
    );
  }

  Widget _buildAdvancedToggle(ThemeData theme, bool focused) {
    final scheme = theme.colorScheme;
    return GestureDetector(
      onTap: _toggleFilters,
      child: Container(
        padding: EdgeInsets.symmetric(horizontal: 12.r, vertical: 9.r),
        decoration: BoxDecoration(
          color: focused
              ? scheme.primary.withValues(alpha: 0.18)
              : scheme.surface.withValues(alpha: 0.5),
          borderRadius: BorderRadius.circular(12.r),
          border: Border.all(
            color: focused ? scheme.primary : Colors.transparent,
            width: 2.r,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Symbols.tune_rounded,
              size: 18.r,
              color: focused ? scheme.primary : scheme.onSurface,
            ),
            SizedBox(width: 6.r),
            Text(
              AppLocale.searchFilters.getString(context),
              style: TextStyle(
                fontSize: 13.r,
                fontWeight: FontWeight.w700,
                color: focused ? scheme.primary : scheme.onSurface,
              ),
            ),
            SizedBox(width: 4.r),
            Icon(
              _filtersExpanded
                  ? Symbols.expand_less_rounded
                  : Symbols.expand_more_rounded,
              size: 16.r,
              color: scheme.onSurface.withValues(alpha: focused ? 0.9 : 0.5),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildNameField(ThemeData theme, bool focused) {
    final scheme = theme.colorScheme;
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12.r),
        border: Border.all(
          color: focused ? scheme.primary : Colors.transparent,
          width: 2.r,
        ),
      ),
      child: TextField(
        controller: _onlineSearchController,
        focusNode: _onlineSearchFocus,
        textInputAction: TextInputAction.done,
        onTap: _focusNameField,
        onChanged: (value) {
          setState(() {}); // refresh the clear/filters band items
          _onOnlineSearchChanged(value);
        },
        onSubmitted: (_) => _onlineSearchFocus.unfocus(),
        style: TextStyle(fontSize: 13.r, color: scheme.onSurface),
        decoration: InputDecoration(
          hintText: AppLocale.searchSavesHint.getString(context),
          hintStyle: TextStyle(
            fontSize: 13.r,
            color: scheme.onSurface.withValues(alpha: 0.5),
          ),
          prefixIcon: Icon(Symbols.search_rounded, size: 18.r),
          suffixIcon: _onlineSearchController.text.isEmpty
              ? null
              : _buildClearQueryButton(theme, _searchFocused('clearQuery')),
          isDense: true,
          contentPadding: EdgeInsets.symmetric(
            horizontal: 12.r,
            vertical: 10.r,
          ),
          filled: true,
          fillColor: scheme.surfaceContainerHighest.withValues(alpha: 0.5),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12.r),
            borderSide: BorderSide.none,
          ),
        ),
      ),
    );
  }

  Widget _buildClearQueryButton(ThemeData theme, bool focused) {
    final scheme = theme.colorScheme;
    return GestureDetector(
      onTap: _clearQuery,
      child: Container(
        margin: EdgeInsets.symmetric(horizontal: 6.r, vertical: 4.r),
        padding: EdgeInsets.all(4.r),
        decoration: BoxDecoration(
          color: focused
              ? scheme.primary.withValues(alpha: 0.18)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(10.r),
          border: Border.all(
            color: focused ? scheme.primary : Colors.transparent,
            width: 2.r,
          ),
        ),
        child: Icon(
          Symbols.close_rounded,
          size: 18.r,
          color: focused
              ? scheme.primary
              : scheme.onSurface.withValues(alpha: 0.6),
        ),
      ),
    );
  }

  Widget _buildFilterChips(ThemeData theme) {
    final inFilters = _region == _SaveRegion.filters;
    final items = _barItems;
    return SingleChildScrollView(
      controller: _chipScroll,
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          for (var i = 0; i < items.length; i++)
            KeyedSubtree(
              key: _chipKeys.putIfAbsent(i, () => GlobalKey()),
              child: _buildFilterChip(
                theme,
                items[i],
                inFilters && _barIndex == i,
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildFilterChip(ThemeData theme, String key, bool isFocused) {
    final scheme = theme.colorScheme;
    final neoSyncProvider = Provider.of<NeoSyncProvider>(
      context,
      listen: false,
    );
    final filter = neoSyncProvider.onlineFilter;
    final bool active = switch (key) {
      'scope' => filter.scope != null,
      'system' => filter.system != null,
      'emulator' => filter.emulator != null,
      _ =>
        (filter.sort ?? 'modified') != 'modified' ||
            (filter.dir ?? 'desc') != 'desc',
    };

    return GestureDetector(
      onTap: () {
        setState(() {
          _onlineSearchFocus.unfocus();
          _region = _SaveRegion.filters;
          _barIndex = _barItems.indexOf(key);
        });
        _openFilterMenu(key);
      },
      child: Container(
        margin: EdgeInsets.only(right: 8.r),
        padding: EdgeInsets.symmetric(horizontal: 12.r, vertical: 8.r),
        decoration: BoxDecoration(
          color: isFocused
              ? scheme.primary.withValues(alpha: 0.18)
              : (active
                    ? scheme.primary.withValues(alpha: 0.10)
                    : scheme.surface.withValues(alpha: 0.5)),
          borderRadius: BorderRadius.circular(12.r),
          border: Border.all(
            color: isFocused
                ? scheme.primary
                : (active
                      ? scheme.primary.withValues(alpha: 0.5)
                      : Colors.transparent),
            width: 2.r,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              _barLabel(key),
              style: TextStyle(
                fontSize: 13.r,
                fontWeight: FontWeight.w600,
                color: (active || isFocused)
                    ? scheme.primary
                    : scheme.onSurface,
              ),
            ),
            SizedBox(width: 4.r),
            Icon(
              Symbols.expand_more_rounded,
              size: 16.r,
              color: scheme.onSurface.withValues(alpha: isFocused ? 0.9 : 0.4),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildFilterMenu(ThemeData theme, String key) {
    final scheme = theme.colorScheme;
    final options = _menuOptions(key);
    return Positioned.fill(
      child: GestureDetector(
        onTap: _cancelMenu,
        child: ColoredBox(
          color: Colors.black.withValues(alpha: 0.6),
          child: Center(
            child: GestureDetector(
              onTap: () {},
              child: Container(
                width: 340.r,
                decoration: BoxDecoration(
                  color: scheme.surface,
                  borderRadius: BorderRadius.circular(16.r),
                  border: Border.all(
                    color: scheme.primary.withValues(alpha: 0.4),
                    width: 1.r,
                  ),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Padding(
                      padding: EdgeInsets.all(12.r),
                      child: Text(
                        key.toUpperCase(),
                        style: TextStyle(
                          fontSize: 13.r,
                          fontWeight: FontWeight.w700,
                          color: scheme.onSurface,
                        ),
                      ),
                    ),
                    Divider(height: 1.r),
                    SizedBox(
                      height: 260.r,
                      child: ListView.builder(
                        controller: _menuScroll,
                        itemExtent: _menuExtent.r,
                        itemCount: options.length,
                        itemBuilder: (context, index) {
                          final option = options[index];
                          final isSelected = index == _menuIndex;
                          return GestureDetector(
                            onTap: () {
                              setState(() => _menuIndex = index);
                              _applyMenuIndex();
                            },
                            child: Container(
                              padding: EdgeInsets.symmetric(
                                horizontal: 16.r,
                                vertical: 8.r,
                              ),
                              decoration: BoxDecoration(
                                color: isSelected
                                    ? scheme.primary.withValues(alpha: 0.18)
                                    : Colors.transparent,
                                border: Border(
                                  bottom: BorderSide(
                                    color: scheme.outline.withValues(
                                      alpha: 0.1,
                                    ),
                                    width: 0.5.r,
                                  ),
                                ),
                              ),
                              child: Row(
                                children: [
                                  Expanded(
                                    child: Text(
                                      option.label,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        fontSize: 13.r,
                                        fontWeight: isSelected
                                            ? FontWeight.w700
                                            : FontWeight.w500,
                                        color: isSelected
                                            ? scheme.primary
                                            : scheme.onSurface,
                                      ),
                                    ),
                                  ),
                                  if (isSelected)
                                    Icon(
                                      Symbols.check_rounded,
                                      size: 16.r,
                                      color: scheme.primary,
                                    ),
                                ],
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildFooter(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      mainAxisAlignment: MainAxisAlignment.end,
      children: [
        GamepadControl(
          label: _isRefreshingOnlineFiles
              ? AppLocale.refreshing.getString(context)
              : _refreshCompleted
              ? AppLocale.refreshed.getString(context)
              : AppLocale.refresh.getString(context),
          iconPath: 'assets/images/gamepad/Xbox_X_button.png',
          onTap: (_isRefreshingOnlineFiles || _refreshCompleted)
              ? null
              : () => _refreshOnlineFiles(),
          textColor: theme.colorScheme.onTertiaryFixed,
          backgroundColor: theme.colorScheme.tertiaryFixed,
        ),
        SizedBox(width: 8.r),
        GamepadControl(
          label: AppLocale.delete.getString(context),
          iconPath: 'assets/images/gamepad/Xbox_View_button.png',
          onTap: _selectSaveItem,
          textColor: theme.colorScheme.onError,
          backgroundColor: theme.colorScheme.error,
        ),
        SizedBox(width: 8.r),
        GamepadControl(
          label: AppLocale.back.getString(context),
          iconPath: 'assets/images/gamepad/Xbox_B_button.png',
          onTap: () => widget.onBack(),
          textColor: theme.colorScheme.onTertiary,
          backgroundColor: theme.colorScheme.tertiary,
        ),
      ],
    );
  }

  Widget _buildPagination(BuildContext context, NeoSyncProvider provider) {
    if (provider.onlineTotalPages <= 1) return const SizedBox.shrink();
    final theme = Theme.of(context);
    return Padding(
      padding: EdgeInsets.only(top: 2.r),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          IconButton(
            onPressed: provider.hasOnlinePrevious
                ? () {
                    provider.previousOnlinePage();
                    _resetSelection();
                  }
                : null,
            icon: Icon(Symbols.chevron_left_rounded, size: 16.r),
            visualDensity: VisualDensity.compact,
            color: theme.colorScheme.onSurface,
          ),
          Text(
            AppLocale.pageOf
                .getString(context)
                .replaceFirst('{current}', '${provider.onlinePage}')
                .replaceFirst('{total}', '${provider.onlineTotalPages}'),
            style: TextStyle(
              fontSize: 10.r,
              color: theme.colorScheme.onSurface.withValues(alpha: 0.7),
            ),
          ),
          IconButton(
            onPressed: provider.hasOnlineNext
                ? () {
                    provider.nextOnlinePage();
                    _resetSelection();
                  }
                : null,
            icon: Icon(Symbols.chevron_right_rounded, size: 16.r),
            visualDensity: VisualDensity.compact,
            color: theme.colorScheme.onSurface,
          ),
        ],
      ),
    );
  }

  Widget _buildEmptyState(BuildContext context, NeoSyncProvider provider) {
    return Center(
      child: Padding(
        padding: EdgeInsets.all(12.r),
        child: Column(
          children: [
            Icon(
              Symbols.cloud_off_rounded,
              size: 48.sp,
              color: Theme.of(
                context,
              ).colorScheme.onSurface.withValues(alpha: 0.5),
            ),
            SizedBox(height: 8.r),
            Text(
              provider.onlineTotal > 0
                  ? AppLocale.noSavesMatchFilters.getString(context)
                  : AppLocale.noOnlineSavesFound.getString(context),
              style: TextStyle(
                fontSize: 16.r,
                color: Theme.of(
                  context,
                ).colorScheme.onSurface.withValues(alpha: 0.7),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A single selectable entry in a filter chip's value menu.
class _FilterOption {
  final String label;
  final String? value;

  const _FilterOption({required this.label, this.value});
}

/// Gamepad-navigable, centered list of online saves.
class OnlineSavesListView extends StatefulWidget {
  final List<NeoSyncFile> files;
  final int selectedIndex;
  final Function(int) onSelectionChanged;
  final bool isNavigatingFast;

  const OnlineSavesListView({
    super.key,
    required this.files,
    required this.selectedIndex,
    required this.onSelectionChanged,
    this.isNavigatingFast = false,
  });

  @override
  State<OnlineSavesListView> createState() => OnlineSavesListViewState();
}

class OnlineSavesListViewState extends State<OnlineSavesListView>
    with TickerProviderStateMixin {
  late final CenteredScrollController _centeredScrollController;
  late AnimationController _selectionController;
  late Animation<double> _selectionAnimation;

  @override
  void initState() {
    super.initState();

    _centeredScrollController = CenteredScrollController(centerPosition: 0.5);

    _selectionController = AnimationController(
      duration: const Duration(milliseconds: 120),
      vsync: this,
    );
    _selectionAnimation = AlwaysStoppedAnimation(
      widget.selectedIndex.toDouble(),
    );

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _centeredScrollController.initialize(
          context: context,
          initialIndex: widget.selectedIndex,
          totalItems: widget.files.length,
        );
        _centeredScrollController.scrollToIndex(
          widget.selectedIndex,
          immediate: true,
        );
      }
    });
  }

  @override
  void didUpdateWidget(OnlineSavesListView oldWidget) {
    super.didUpdateWidget(oldWidget);

    if (oldWidget.files.length != widget.files.length) {
      _centeredScrollController.updateTotalItems(widget.files.length);
    }

    if (oldWidget.selectedIndex != widget.selectedIndex) {
      final animationDuration = widget.isNavigatingFast
          ? const Duration(milliseconds: 120)
          : const Duration(milliseconds: 250);

      final scrollDuration = widget.isNavigatingFast
          ? const Duration(milliseconds: 180)
          : const Duration(milliseconds: 360);

      const curve = Curves.easeOutQuart;

      final double begin = _selectionAnimation.value;
      final double end = widget.selectedIndex.toDouble();

      _selectionController.duration = animationDuration;
      _selectionAnimation = Tween<double>(
        begin: begin,
        end: end,
      ).animate(CurvedAnimation(parent: _selectionController, curve: curve));

      _selectionController.forward(from: 0);

      _centeredScrollController.updateSelectedIndex(widget.selectedIndex);
      if (_centeredScrollController.scrollController.hasClients) {
        _centeredScrollController.scrollToIndex(
          widget.selectedIndex,
          duration: scrollDuration,
          curve: curve,
        );
      }
    }
  }

  @override
  void dispose() {
    _centeredScrollController.dispose();
    _selectionController.dispose();
    super.dispose();
  }

  void scrollToIndex(int index, {bool immediate = false}) {
    if (_centeredScrollController.scrollController.hasClients) {
      _centeredScrollController.scrollToIndex(index, immediate: immediate);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final double itemHeight = 56.r;
    final double marginBottom = 4.r;
    final double totalItemHeight = itemHeight + marginBottom;

    return Stack(
      children: [
        AnimatedBuilder(
          animation: Listenable.merge([
            _selectionController,
            _centeredScrollController.scrollController,
          ]),
          builder: (context, child) {
            final double scrollOffset =
                _centeredScrollController.scrollController.hasClients
                ? _centeredScrollController.scrollController.offset
                : 0.0;

            final double currentSelection = _selectionAnimation.value;

            final double topPosition =
                (currentSelection * totalItemHeight) + 4.r - scrollOffset;

            return Positioned(
              top: topPosition,
              left: 4.r,
              right: 4.r,
              height: itemHeight,
              child: Container(
                decoration: BoxDecoration(
                  color: theme.colorScheme.secondary,
                  borderRadius: BorderRadius.circular(12.r),
                ),
              ),
            );
          },
        ),
        ValueListenableBuilder<int>(
          valueListenable: _centeredScrollController.rebuildNotifier,
          builder: (context, rebuildCount, _) {
            return ListView.builder(
              key: ValueKey('online_saves_list_$rebuildCount'),
              controller: _centeredScrollController.scrollController,
              padding: EdgeInsets.symmetric(vertical: 4.r, horizontal: 4.w),
              itemCount: widget.files.length,
              itemBuilder: (context, index) {
                return GestureDetector(
                  onTap: () {
                    SfxService().playNavSound();
                    widget.onSelectionChanged(index);
                  },
                  child: _buildOnlineSaveItem(
                    context,
                    widget.files[index],
                    index,
                  ),
                );
              },
            );
          },
        ),
      ],
    );
  }

  Widget _buildSaveThumb(NeoSyncFile file, bool isSelected) {
    final gameHash = file.gameHash;
    if (gameHash == null || gameHash.isEmpty) {
      return _buildSaveThumbIcon(isSelected);
    }

    final imageUrl = 'https://media.neosync.cloud/games/$gameHash.webp';
    return Container(
      width: 44.r,
      height: 44.r,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(10.r),
        border: Border.all(
          color: Theme.of(context).colorScheme.outline.withValues(alpha: 0.25),
          width: 0.5.r,
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.2),
            blurRadius: 2.r,
            offset: Offset(1.0.r, 1.0.r),
          ),
        ],
      ),
      clipBehavior: Clip.antiAlias,
      child: Image.network(
        imageUrl,
        fit: BoxFit.cover,
        errorBuilder: (context, error, stackTrace) =>
            _buildSaveThumbIcon(isSelected),
        loadingBuilder: (context, child, loadingProgress) {
          if (loadingProgress == null) return child;
          return Container(
            color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.1),
            child: Center(
              child: SizedBox(
                width: 14.r,
                height: 14.r,
                child: CircularProgressIndicator(
                  strokeWidth: 2.r,
                  color: Theme.of(context).colorScheme.primary,
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildSaveThumbIcon(bool isSelected) {
    return Container(
      width: 44.r,
      height: 44.r,
      decoration: BoxDecoration(
        color: isSelected
            ? Theme.of(context).colorScheme.onSecondary.withValues(alpha: 0.2)
            : Theme.of(context).colorScheme.primary.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(10.r),
      ),
      child: Icon(
        Symbols.save_rounded,
        color: isSelected
            ? Theme.of(context).colorScheme.onSecondary
            : Theme.of(context).colorScheme.primary,
        size: 22.r,
      ),
    );
  }

  Widget _buildOnlineSaveItem(
    BuildContext context,
    NeoSyncFile file,
    int index,
  ) {
    final isSelected = index == widget.selectedIndex;
    final theme = Theme.of(context);

    // File name without the cloud path (v2/saves/system/emulator/.../game.ext).
    final fileName = file.fileName.contains('/') || file.fileName.contains('\\')
        ? p.basename(file.fileName.replaceAll('\\', '/'))
        : file.fileName;

    return Container(
      key: ValueKey('save_item_$index'),
      height: 56.r,
      margin: EdgeInsets.only(bottom: 4.r),
      padding: EdgeInsets.all(6.r),
      decoration: BoxDecoration(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(12.r),
        border: Border.all(
          color: isSelected
              ? Colors.transparent
              : theme.colorScheme.outline.withValues(alpha: 0.2),
          width: 0.5.r,
        ),
      ),
      child: Row(
        children: [
          _buildSaveThumb(file, isSelected),
          SizedBox(width: 8.r),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                // Game name
                AnimatedDefaultTextStyle(
                  duration: const Duration(milliseconds: 200),
                  curve: Curves.easeOut,
                  style: TextStyle(
                    fontSize: 10.r,
                    fontWeight: isSelected ? FontWeight.bold : FontWeight.w600,
                    color: isSelected
                        ? theme.colorScheme.onSecondary
                        : theme.colorScheme.onSurface,
                    fontFamily: theme.textTheme.bodyMedium?.fontFamily,
                  ),
                  child: Text(
                    file.gameName.isNotEmpty ? file.gameName : fileName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                SizedBox(height: 2.r),
                // Real on-disk path (file_path) + size
                Text(
                  '${file.filePath.isNotEmpty ? file.filePath : fileName} • ${file.fileSizeFormatted}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 8.r,
                    color: isSelected
                        ? theme.colorScheme.onSecondary.withValues(alpha: 0.8)
                        : theme.colorScheme.onSurface.withValues(alpha: 0.6),
                    fontFamily: theme.textTheme.bodySmall?.fontFamily,
                  ),
                ),
                if (file.systemName != null || file.emulator != null) ...[
                  SizedBox(height: 3.r),
                  Row(
                    children: [
                      if (file.systemName != null &&
                          file.systemName!.isNotEmpty) ...[
                        _buildMetaBadge(
                          theme,
                          file.systemName!,
                          isSelected,
                          Symbols.videogame_asset_rounded,
                        ),
                        SizedBox(width: 4.r),
                      ],
                      if (file.emulator != null &&
                          file.emulator!.isNotEmpty) ...[
                        _buildMetaBadge(
                          theme,
                          file.emulator!,
                          isSelected,
                          Symbols.memory_rounded,
                        ),
                      ],
                    ],
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMetaBadge(
    ThemeData theme,
    String label,
    bool isSelected,
    IconData icon,
  ) {
    return Container(
      padding: EdgeInsets.symmetric(horizontal: 5.r, vertical: 1.r),
      decoration: BoxDecoration(
        color: isSelected
            ? theme.colorScheme.onSecondary.withValues(alpha: 0.15)
            : theme.colorScheme.primary.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(4.r),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            icon,
            size: 8.r,
            color: isSelected
                ? theme.colorScheme.onSecondary
                : theme.colorScheme.primary,
          ),
          SizedBox(width: 3.r),
          Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 7.r,
              fontWeight: FontWeight.w600,
              color: isSelected
                  ? theme.colorScheme.onSecondary
                  : theme.colorScheme.primary,
            ),
          ),
        ],
      ),
    );
  }
}
