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
import 'package:neostation/themes/corner_radii.dart';
import 'package:neostation/utils/gamepad_nav.dart';
import 'package:neostation/services/gamepad/gamepad_navigation_manager.dart';
import 'package:neostation/widgets/custom_notification.dart' as custom;
import 'package:neostation/widgets/core_footer.dart';
import 'package:neostation/widgets/neo_glass.dart';
import 'package:neostation/widgets/neosync_logo.dart';

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
      // L1/R1 switch the app's tabs, so the triggers turn the page.
      onLeftTrigger: () => _changePage(forward: false),
      onRightTrigger: () => _changePage(forward: true),
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
        _moveInGrid(-1);
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
        _moveInGrid(1);
    }
  }

  void _navigateUp() {
    switch (_region) {
      case _SaveRegion.menu:
        _moveMenuSelection(-1);
      case _SaveRegion.results:
        final neoSyncProvider = Provider.of<NeoSyncProvider>(
          context,
          listen: false,
        );
        // From the card's first row, Up goes back to the filters.
        if (_selectedSaveIndex < OnlineSavesListView.columns ||
            !_rowsShown(neoSyncProvider)) {
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
        if (_filtersExpanded) {
          setState(() {
            _region = _SaveRegion.filters;
            _barIndex = 0;
          });
        } else {
          _enterResults();
        }
      case _SaveRegion.filters:
        _enterResults();
      case _SaveRegion.results:
        _navigateSavesDown();
    }
    SfxService().playNavSound();
  }

  /// Whether the save rows are on screen. While a page loads, a spinner takes
  /// their place but [NeoSyncProvider.onlineFiles] still holds the previous
  /// page, so nothing may act on or move through a row until they are back.
  bool _rowsShown(NeoSyncProvider neoSyncProvider) =>
      !neoSyncProvider.isLoadingOnlineFiles &&
      neoSyncProvider.onlineFiles.isNotEmpty;

  void _enterResults() {
    final neoSyncProvider = Provider.of<NeoSyncProvider>(
      context,
      listen: false,
    );
    if (!_rowsShown(neoSyncProvider)) return;
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

  /// Shows the previous or next page of saves (L2/R2 or the page arrows) and
  /// highlights its first save. Not while a filter menu is open, or while a
  /// page is still loading, so a second pull can't skip the page in between.
  void _changePage({required bool forward}) {
    if (_region == _SaveRegion.menu) return;
    final neoSyncProvider = Provider.of<NeoSyncProvider>(
      context,
      listen: false,
    );
    if (neoSyncProvider.isLoadingOnlineFiles) return;
    if (forward) {
      if (!neoSyncProvider.hasOnlineNext) return;
      neoSyncProvider.nextOnlinePage();
    } else {
      if (!neoSyncProvider.hasOnlinePrevious) return;
      neoSyncProvider.previousOnlinePage();
    }
    _resetSelection();
  }

  /// Up a row on the card ([_navigateUp] leaves it from the first row).
  void _navigateSavesUp() {
    final neoSyncProvider = Provider.of<NeoSyncProvider>(
      context,
      listen: false,
    );
    if (!_rowsShown(neoSyncProvider)) return;
    final up = _selectedSaveIndex - OnlineSavesListView.columns;
    if (up >= 0) _updateSelectionIndex(up);
  }

  /// Down a row on the card: onto the save below, or the last one when the
  /// row below is shorter. Nothing below the last row.
  void _navigateSavesDown() {
    final neoSyncProvider = Provider.of<NeoSyncProvider>(
      context,
      listen: false,
    );
    if (!_rowsShown(neoSyncProvider)) return;
    final count = neoSyncProvider.onlineFiles.length;
    const columns = OnlineSavesListView.columns;
    final down = _selectedSaveIndex + columns;
    if (down < count) {
      _updateSelectionIndex(down);
    } else if (_selectedSaveIndex ~/ columns < (count - 1) ~/ columns) {
      _updateSelectionIndex(count - 1);
    }
  }

  /// Left or right along the card, row to row, stopping at either end.
  void _moveInGrid(int delta) {
    final neoSyncProvider = Provider.of<NeoSyncProvider>(
      context,
      listen: false,
    );
    if (!_rowsShown(neoSyncProvider)) return;
    final next = _selectedSaveIndex + delta;
    if (next < 0 || next >= neoSyncProvider.onlineFiles.length) return;
    _updateSelectionIndex(next);
    SfxService().playNavSound();
  }

  void _updateSelectionIndex(int newIndex) {
    if (_selectedSaveIndex == newIndex) return;
    setState(() => _selectedSaveIndex = newIndex);
  }

  Future<void> _selectSaveItem() async {
    final neoSyncProvider = Provider.of<NeoSyncProvider>(
      context,
      listen: false,
    );
    if (!_rowsShown(neoSyncProvider)) return;

    final now = DateTime.now();
    if (_lastSelectTime != null &&
        now.difference(_lastSelectTime!).inMilliseconds < _selectThrottleMs) {
      return;
    }
    _lastSelectTime = now;

    if (_selectedSaveIndex < neoSyncProvider.onlineFiles.length) {
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
          // The provider has reloaded the page: it is shorter only on the last
          // page, and empty when the reload failed.
          final remainingFiles = neoSyncProvider.onlineFiles.length;
          if (mounted && _selectedSaveIndex >= remainingFiles) {
            setState(
              () => _selectedSaveIndex = remainingFiles > 0
                  ? remainingFiles - 1
                  : 0,
            );
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
      final loaded = await neoSyncProvider.loadOnlineFiles();

      if (!mounted) return;
      if (!loaded) {
        _refreshFailed();
        return;
      }
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
      _refreshFailed();
    }
  }

  void _refreshFailed() {
    _resetSelection();
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
                SizedBox(height: 4.r),
                _buildFilterChips(theme),
              ],
              SizedBox(height: 6.r),
              Expanded(
                child: Consumer<NeoSyncProvider>(
                  builder: (context, neoSyncProvider, child) {
                    return NeoGlassRim(
                      cornerRadius:
                          (theme.extension<CornerRadii>() ?? CornerRadii.m())
                              .radiusExternalRadius,
                      child: Container(
                        padding: EdgeInsets.all(6.r),
                        decoration: BoxDecoration(
                          color: theme.colorScheme.surface,
                          borderRadius:
                              (theme.extension<CornerRadii>() ??
                                      CornerRadii.m())
                                  .radiusExternal,
                          border: Border.all(
                            color: theme.colorScheme.outline.withValues(
                              alpha: 0.15,
                            ),
                          ),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            _buildCardHeader(theme, neoSyncProvider),
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
                            if (_rowsShown(neoSyncProvider)) ...[
                              Divider(
                                height: 1,
                                color: theme.colorScheme.outline.withValues(
                                  alpha: 0.2,
                                ),
                              ),
                              SaveDetailPanel(
                                file:
                                    neoSyncProvider
                                        .onlineFiles[_selectedSaveIndex.clamp(
                                      0,
                                      neoSyncProvider.onlineFiles.length - 1,
                                    )],
                              ),
                            ],
                          ],
                        ),
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

  ({Color background, Color foreground}) _selectionPalette(
    ThemeData theme, {
    required bool focused,
    bool selected = false,
  }) {
    final scheme = theme.colorScheme;
    if (focused) {
      return (background: scheme.onSurface, foreground: scheme.surface);
    }
    return (
      background: selected
          ? Color.alphaBlend(
              scheme.onSurface.withValues(alpha: 0.18),
              scheme.surface,
            )
          : scheme.surface.withValues(alpha: 0.5),
      foreground: scheme.onSurface,
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
    final palette = _selectionPalette(
      theme,
      focused: focused,
      selected: _filtersExpanded,
    );
    final foreground = palette.foreground;
    return GestureDetector(
      onTap: _toggleFilters,
      child: NeoGlassRim(
        cornerRadius: (theme.extension<CornerRadii>() ?? CornerRadii.m())
            .radiusInternalRadius,
        child: Container(
          padding: EdgeInsets.symmetric(horizontal: 10.r, vertical: 5.r),
          decoration: BoxDecoration(
            color: palette.background,
            borderRadius: (theme.extension<CornerRadii>() ?? CornerRadii.m())
                .radiusInternal,
            border: Border.all(color: Colors.transparent, width: 2.r),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Symbols.tune_rounded, size: 14.r, color: foreground),
              SizedBox(width: 6.r),
              Text(
                AppLocale.searchFilters.getString(context),
                style: TextStyle(
                  fontSize: 11.r,
                  fontWeight: FontWeight.w700,
                  color: foreground,
                ),
              ),
              SizedBox(width: 4.r),
              Icon(
                _filtersExpanded
                    ? Symbols.expand_less_rounded
                    : Symbols.expand_more_rounded,
                size: 16.r,
                color: foreground.withValues(alpha: 0.75),
              ),
            ],
          ),
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
        style: TextStyle(fontSize: 11.r, color: scheme.onSurface),
        decoration: InputDecoration(
          hintText: AppLocale.searchSavesHint.getString(context),
          hintStyle: TextStyle(
            fontSize: 11.r,
            color: scheme.onSurface.withValues(alpha: 0.5),
          ),
          prefixIcon: Icon(Symbols.search_rounded, size: 14.r),
          prefixIconConstraints: BoxConstraints(minWidth: 30.r),
          suffixIcon: _onlineSearchController.text.isEmpty
              ? null
              : _buildClearQueryButton(theme, _searchFocused('clearQuery')),
          isDense: true,
          contentPadding: EdgeInsets.symmetric(horizontal: 10.r, vertical: 6.r),
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
          color: focused ? scheme.onSurface : Colors.transparent,
          borderRadius: BorderRadius.circular(10.r),
          border: Border.all(color: Colors.transparent, width: 2.r),
        ),
        child: Icon(
          Symbols.close_rounded,
          size: 18.r,
          color: focused
              ? scheme.surface
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

    final palette = _selectionPalette(
      theme,
      focused: isFocused,
      selected: active,
    );
    final foreground = palette.foreground;
    return GestureDetector(
      onTap: () {
        setState(() {
          _onlineSearchFocus.unfocus();
          _region = _SaveRegion.filters;
          _barIndex = _barItems.indexOf(key);
        });
        _openFilterMenu(key);
      },
      child: NeoGlassRim(
        cornerRadius: (theme.extension<CornerRadii>() ?? CornerRadii.m())
            .radiusInternalRadius,
        child: Container(
          margin: EdgeInsets.only(right: 6.r),
          padding: EdgeInsets.symmetric(horizontal: 10.r, vertical: 4.r),
          decoration: BoxDecoration(
            color: palette.background,
            borderRadius: (theme.extension<CornerRadii>() ?? CornerRadii.m())
                .radiusInternal,
            border: Border.all(color: Colors.transparent, width: 2.r),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                _barLabel(key),
                style: TextStyle(
                  fontSize: 10.r,
                  fontWeight: FontWeight.w600,
                  color: foreground,
                ),
              ),
              SizedBox(width: 4.r),
              Icon(
                Symbols.expand_more_rounded,
                size: 13.r,
                color: foreground.withValues(alpha: 0.75),
              ),
            ],
          ),
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
                                    ? scheme.onSurface
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
                                            ? scheme.surface
                                            : scheme.onSurface,
                                      ),
                                    ),
                                  ),
                                  if (isSelected)
                                    Icon(
                                      Symbols.check_rounded,
                                      size: 16.r,
                                      color: scheme.surface,
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
          textColor: theme.colorScheme.onTertiaryFixed,
          backgroundColor: theme.colorScheme.tertiaryFixed,
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

  /// The card's title row: NeoSync's isotype, "Online saves", and the page
  /// controls on the right.
  Widget _buildCardHeader(ThemeData theme, NeoSyncProvider provider) {
    final color = theme.colorScheme.onSurface;
    return Padding(
      padding: EdgeInsets.fromLTRB(6.r, 2.r, 2.r, 4.r),
      child: Row(
        children: [
          NeoSyncLogo.isotype(height: 13.r),
          SizedBox(width: 8.r),
          Expanded(
            child: Text(
              AppLocale.onlineSaves.getString(context).toUpperCase(),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 11.r,
                fontWeight: FontWeight.w700,
                letterSpacing: 1.5.r,
                color: color,
              ),
            ),
          ),
          _buildPagination(context, provider),
        ],
      ),
    );
  }

  Widget _buildPagination(BuildContext context, NeoSyncProvider provider) {
    if (provider.onlineTotalPages <= 1) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final textColor = theme.colorScheme.onSurface.withValues(alpha: 0.7);
    // No page change while one is still loading (see [_changePage]).
    final loading = provider.isLoadingOnlineFiles;
    final canGoBack = provider.hasOnlinePrevious && !loading;
    final canGoOn = provider.hasOnlineNext && !loading;
    // The trigger that turns the page that way, beside each arrow, dimmed
    // with it when there is no page to turn to.
    Widget trigger(String iconPath, {required bool enabled}) => SizedBox(
      width: 14.r,
      height: 14.r,
      child: Image.asset(
        iconPath,
        color: enabled
            ? textColor
            : theme.colorScheme.onSurface.withValues(alpha: 0.3),
        colorBlendMode: BlendMode.srcIn,
      ),
    );
    return Padding(
      padding: EdgeInsets.zero,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          trigger(
            'assets/images/gamepad/Xbox_LT_trigger.png',
            enabled: canGoBack,
          ),
          IconButton(
            onPressed: canGoBack ? () => _changePage(forward: false) : null,
            icon: Icon(Symbols.chevron_left_rounded, size: 16.r),
            visualDensity: VisualDensity.compact,
            color: theme.colorScheme.onSurface,
          ),
          Text(
            AppLocale.pageOf
                .getString(context)
                .replaceFirst('{current}', '${provider.onlinePage}')
                .replaceFirst('{total}', '${provider.onlineTotalPages}'),
            style: TextStyle(fontSize: 10.r, color: textColor),
          ),
          IconButton(
            onPressed: canGoOn ? () => _changePage(forward: true) : null,
            icon: Icon(Symbols.chevron_right_rounded, size: 16.r),
            visualDensity: VisualDensity.compact,
            color: theme.colorScheme.onSurface,
          ),
          trigger(
            'assets/images/gamepad/Xbox_RT_trigger.png',
            enabled: canGoOn,
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
              color: Theme.of(context).colorScheme.onSurface
                  .withValues(alpha: 0.5),
            ),
            SizedBox(height: 8.r),
            Text(
              // An empty list after a failed load isn't an empty account.
              provider.onlineFilesLoadFailed
                  ? AppLocale.failedToRefreshCloud.getString(context)
                  : provider.onlineTotal > 0
                  ? AppLocale.noSavesMatchFilters.getString(context)
                  : AppLocale.noOnlineSavesFound.getString(context),
              style: TextStyle(
                fontSize: 16.r,
                color: Theme.of(context).colorScheme.onSurface
                    .withValues(alpha: 0.7),
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

/// The online saves as a memory card: each save a square block with its game's
/// art (or its system, without art), the highlighted one ringed, and the rest
/// of the card's slots drawn empty. The name, path and size of the highlighted
/// save show under the grid ([SaveDetailPanel]), not on the blocks.
class OnlineSavesListView extends StatefulWidget {
  final List<NeoSyncFile> files;
  final int selectedIndex;
  final Function(int) onSelectionChanged;
  final bool isNavigatingFast;

  /// Blocks per row; the D-pad moves a row up or down by this many.
  static const int columns = 8;

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

class OnlineSavesListViewState extends State<OnlineSavesListView> {
  final ScrollController _scroll = ScrollController();

  /// One block plus the gap under it, and the grid's visible height, as laid
  /// out last: what keeping the highlighted row on screen needs.
  double _rowExtent = 0;
  double _viewport = 0;

  @override
  void didUpdateWidget(OnlineSavesListView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.selectedIndex != widget.selectedIndex) {
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => scrollToIndex(widget.selectedIndex),
      );
    }
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  /// Scrolls just enough to show [index]'s row.
  void scrollToIndex(int index, {bool immediate = false}) {
    if (!_scroll.hasClients || _rowExtent <= 0) return;
    final row = index ~/ OnlineSavesListView.columns;
    final top = row * _rowExtent;
    final bottom = top + _rowExtent;
    final offset = _scroll.offset;
    double? target;
    if (top < offset) {
      target = top;
    } else if (bottom > offset + _viewport) {
      target = bottom - _viewport;
    }
    if (target == null) return;
    target = target.clamp(0.0, _scroll.position.maxScrollExtent);
    if (immediate) {
      _scroll.jumpTo(target);
    } else {
      _scroll.animateTo(
        target,
        duration: widget.isNavigatingFast
            ? const Duration(milliseconds: 120)
            : const Duration(milliseconds: 220),
        curve: Curves.easeOutQuart,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    const columns = OnlineSavesListView.columns;
    final spacing = 6.r;
    final padding = 4.r;
    return LayoutBuilder(
      builder: (context, constraints) {
        final tile =
            (constraints.maxWidth - padding * 2 - spacing * (columns - 1)) /
            columns;
        _rowExtent = tile + spacing;
        _viewport = constraints.maxHeight;
        final rows = (widget.files.length / columns).ceil();
        // The card's empty slots finish the last row and fill the space left,
        // as on a memory card.
        final visibleRows = ((constraints.maxHeight - padding) / _rowExtent)
            .floor();
        final totalRows = rows > visibleRows ? rows : visibleRows;
        return GridView.builder(
          controller: _scroll,
          padding: EdgeInsets.all(padding),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: columns,
            mainAxisSpacing: spacing,
            crossAxisSpacing: spacing,
          ),
          itemCount: totalRows * columns,
          itemBuilder: (context, index) {
            if (index >= widget.files.length) return const _EmptySaveSlot();
            return GestureDetector(
              onTap: () {
                SfxService().playNavSound();
                widget.onSelectionChanged(index);
              },
              child: _SaveBlock(
                key: ValueKey('save_item_$index'),
                file: widget.files[index],
                selected: index == widget.selectedIndex,
              ),
            );
          },
        );
      },
    );
  }
}

/// One save on the card: its game's art, or its system's name without art.
class _SaveBlock extends StatelessWidget {
  const _SaveBlock({super.key, required this.file, required this.selected});

  final NeoSyncFile file;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final radius =
        (theme.extension<CornerRadii>() ?? CornerRadii.m()).radiusInternal;
    final hash = file.gameHash;
    final fallback = _SystemLabel(file: file);
    return AnimatedContainer(
      duration: const Duration(milliseconds: 120),
      padding: EdgeInsets.all(selected ? 2.r : 0),
      decoration: BoxDecoration(
        borderRadius: radius,
        // The highlight is a solid ring, as everywhere in the app: no glow.
        border: Border.all(
          color: selected ? scheme.onSurface : Colors.transparent,
          width: 2.r,
        ),
      ),
      child: ClipRRect(
        borderRadius: radius,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: theme.scaffoldBackgroundColor,
            border: Border.all(color: scheme.outline.withValues(alpha: 0.2)),
            borderRadius: radius,
          ),
          child: hash == null || hash.isEmpty
              ? fallback
              : Image.network(
                  'https://media.neosync.cloud/games/$hash.webp',
                  fit: BoxFit.cover,
                  width: double.infinity,
                  height: double.infinity,
                  errorBuilder: (context, error, stackTrace) => fallback,
                ),
        ),
      ),
    );
  }
}

/// A block without art: the save's system in short, or a save icon.
class _SystemLabel extends StatelessWidget {
  const _SystemLabel({required this.file});

  final NeoSyncFile file;

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.onSurface
        .withValues(alpha: 0.7);
    final system = file.systemName;
    return Center(
      child: system == null || system.isEmpty
          ? Icon(Symbols.save_rounded, size: 18.r, color: color)
          : Padding(
              padding: EdgeInsets.all(4.r),
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: Text(
                  system.toUpperCase(),
                  style: TextStyle(
                    fontSize: 10.r,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 1.r,
                    color: color,
                  ),
                ),
              ),
            ),
    );
  }
}

/// A free slot on the card, drawn dashed.
class _EmptySaveSlot extends StatelessWidget {
  const _EmptySaveSlot();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final radius = (theme.extension<CornerRadii>() ?? CornerRadii.m())
        .radiusInternalRadius;
    return CustomPaint(
      painter: _DashedSlotPainter(
        color: theme.colorScheme.outline.withValues(alpha: 0.35),
        radius: radius,
        dash: 5.r,
        gap: 4.r,
        stroke: 1.5.r,
      ),
    );
  }
}

class _DashedSlotPainter extends CustomPainter {
  _DashedSlotPainter({
    required this.color,
    required this.radius,
    required this.dash,
    required this.gap,
    required this.stroke,
  });

  final Color color;
  final double radius;
  final double dash;
  final double gap;
  final double stroke;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke;
    final inset = stroke / 2;
    final path = Path()
      ..addRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(
            inset,
            inset,
            size.width - stroke,
            size.height - stroke,
          ),
          Radius.circular(radius),
        ),
      );
    for (final metric in path.computeMetrics()) {
      var distance = 0.0;
      while (distance < metric.length) {
        canvas.drawPath(metric.extractPath(distance, distance + dash), paint);
        distance += dash + gap;
      }
    }
  }

  @override
  bool shouldRepaint(_DashedSlotPainter oldDelegate) =>
      oldDelegate.color != color ||
      oldDelegate.radius != radius ||
      oldDelegate.stroke != stroke;
}

/// Under the card: the highlighted save's name, where it is kept on disk, its
/// size, system and emulator, and whether it is a save or a state.
class SaveDetailPanel extends StatelessWidget {
  const SaveDetailPanel({super.key, required this.file});

  final NeoSyncFile file;

  static String _date(DateTime date) {
    final local = date.toLocal();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${local.year}-${two(local.month)}-${two(local.day)} '
        '${two(local.hour)}:${two(local.minute)}';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final fileName = file.fileName.contains('/') || file.fileName.contains('\\')
        ? p.basename(file.fileName.replaceAll('\\', '/'))
        : file.fileName;
    final meta = [
      if (file.systemName != null && file.systemName!.isNotEmpty)
        file.systemName!,
      if (file.emulator != null && file.emulator!.isNotEmpty) file.emulator!,
      _date(file.fileModifiedAt ?? file.uploadedAt),
    ].join('  ·  ');
    final muted = scheme.onSurface.withValues(alpha: 0.6);
    return Padding(
      padding: EdgeInsets.fromLTRB(8.r, 8.r, 8.r, 4.r),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  file.gameName.isNotEmpty ? file.gameName : fileName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12.r,
                    fontWeight: FontWeight.w700,
                    color: scheme.onSurface,
                  ),
                ),
                SizedBox(height: 3.r),
                Text(
                  file.filePath.isNotEmpty ? file.filePath : fileName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 9.r,
                    color: muted,
                    fontFamily: 'monospace',
                  ),
                ),
                SizedBox(height: 2.r),
                Text(
                  meta,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 9.r, color: muted),
                ),
              ],
            ),
          ),
          SizedBox(width: 12.r),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                file.type.toUpperCase(),
                style: TextStyle(
                  fontSize: 10.r,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 1.5.r,
                  color: scheme.onSurface,
                ),
              ),
              SizedBox(height: 6.r),
              Text(
                file.fileSizeFormatted,
                style: TextStyle(fontSize: 11.r, color: muted),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
