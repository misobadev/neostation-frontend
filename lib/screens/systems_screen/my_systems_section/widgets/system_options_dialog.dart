import 'package:flutter/material.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:provider/provider.dart';
import 'package:neostation/constants/system_folder_names.dart';
import 'package:neostation/l10n/app_locale.dart';
import 'package:neostation/models/config_model.dart';
import 'package:neostation/models/my_systems.dart';
import 'package:neostation/providers/sqlite_config_provider.dart';
import 'package:neostation/services/gamepad/gamepad_navigation_manager.dart';
import 'package:neostation/services/sfx_service.dart';
import 'package:neostation/themes/corner_radii.dart';
import 'package:neostation/widgets/neo_glass.dart';
import 'package:neostation/utils/gamepad_nav.dart';

/// Actions the Options dialog can hand back to the systems screen.
enum SystemOptionsAction { search, gameSettings }

enum _OptionsMenu { main, layout, sorting }

/// Opens the systems screen's Options menu from the left edge.
///
/// The root is a one-column list. System Layout and System Sorting replace that
/// list with their own options; System Settings and Game Search report actions
/// back to the systems screen.
Future<SystemOptionsAction?> showSystemOptionsDialog({
  required BuildContext context,
  required SystemInfo system,
}) {
  return showGeneralDialog<SystemOptionsAction>(
    context: context,
    barrierDismissible: true,
    barrierLabel: AppLocale.hintOptions.getString(context),
    barrierColor: Colors.black.withValues(alpha: 0.35),
    transitionDuration: const Duration(milliseconds: 220),
    pageBuilder: (context, animation, secondaryAnimation) =>
        SystemOptionsDialog(system: system),
    transitionBuilder: (context, animation, secondaryAnimation, child) {
      final curved = CurvedAnimation(
        parent: animation,
        curve: Curves.easeOutCubic,
        reverseCurve: Curves.easeInCubic,
      );
      return FadeTransition(
        opacity: curved,
        child: SlideTransition(
          position: Tween<Offset>(
            begin: const Offset(-1, 0),
            end: Offset.zero,
          ).animate(curved),
          child: child,
        ),
      );
    },
  );
}

/// A gamepad-navigable options menu anchored to the left edge.
class SystemOptionsDialog extends StatefulWidget {
  const SystemOptionsDialog({super.key, required this.system});

  final SystemInfo system;

  @override
  State<SystemOptionsDialog> createState() => _SystemOptionsDialogState();
}

class _SystemOptionsDialogState extends State<SystemOptionsDialog> {
  _OptionsMenu _menu = _OptionsMenu.main;
  int _rootIndex = 0;
  int _submenuIndex = 0;

  final Map<String, GlobalKey> _rowKeys = {};

  /// A route can only be popped once. Start, B and the close button can all
  /// arrive within the dismissal animation; the first one owns the pop.
  bool _isClosing = false;

  late GamepadNavigation _gamepadNav;

  bool get _isSearchCard =>
      widget.system.folderName == SystemFolderNames.search;

  @override
  void initState() {
    super.initState();
    _gamepadNav = GamepadNavigation(
      onNavigateUp: () => _moveRow(-1),
      onNavigateDown: () => _moveRow(1),
      onNavigateLeft: () => _moveCardSize(-1),
      onNavigateRight: () => _moveCardSize(1),
      onSelectItem: _activateFocused,
      onBack: _goBack,
      onSettings: _close,
    );

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _gamepadNav.initialize();
      GamepadNavigationManager.pushLayer(
        'system_options_dialog',
        modal: true,
        onActivate: () => _gamepadNav.activate(),
        onDeactivate: () => _gamepadNav.deactivate(),
      );
    });
  }

  @override
  void dispose() {
    GamepadNavigationManager.popLayer('system_options_dialog');
    _gamepadNav.dispose();
    super.dispose();
  }

  GlobalKey _keyFor(String id) => _rowKeys.putIfAbsent(id, GlobalKey.new);

  List<_OptionRow> _buildRootRows(BuildContext context) {
    return [
      _OptionRow(
        id: 'system_layout',
        label: AppLocale.systemOptionsSystemLayout.getString(context),
        description: AppLocale.systemOptionsSystemViewSubtitle.getString(
          context,
        ),
        icon: Symbols.grid_view_rounded,
        action: true,
      ),
      _OptionRow(
        id: 'system_sorting',
        label: AppLocale.systemOptionsSystemSorting.getString(context),
        description: AppLocale.systemOptionsSystemSortingSubtitle.getString(
          context,
        ),
        icon: Symbols.sort_by_alpha_rounded,
        action: true,
      ),
      if (!_isSearchCard) ...[
        _OptionRow(
          id: 'system_settings',
          label: AppLocale.systemSettings.getString(context),
          description: AppLocale.systemOptionsGameSettingsDescription.getString(
            context,
          ),
          icon: Symbols.settings_rounded,
          action: true,
        ),
        _OptionRow(
          id: 'game_search',
          label: AppLocale.systemOptionsGameSearch.getString(context),
          description: AppLocale.systemOptionsSearchDescription.getString(
            context,
          ),
          icon: Symbols.search_rounded,
          action: true,
        ),
      ],
    ];
  }

  List<_OptionsEntry> _buildLayoutEntries(
    BuildContext context,
    ConfigModel config,
  ) {
    final viewMode = config.systemViewMode;
    final isGrid = viewMode == 'grid';

    return [
      _OptionsEntry.group(AppLocale.viewModeGroup.getString(context)),
      _OptionsEntry.row(
        _OptionRow(
          id: 'view_grid',
          label: AppLocale.gridView.getString(context),
          icon: Symbols.grid_view_rounded,
          selected: viewMode == 'grid',
        ),
      ),
      _OptionsEntry.row(
        _OptionRow(
          id: 'view_carousel',
          label: AppLocale.carouselView.getString(context),
          icon: Symbols.view_carousel_rounded,
          selected: viewMode == 'carousel',
        ),
      ),
      if (isGrid) ...[
        _OptionsEntry.group(AppLocale.cardSizeGroup.getString(context)),
        _OptionsEntry.row(
          _OptionRow(
            id: 'card_size',
            label: '',
            icon: Symbols.crop_free_rounded,
            segmented: true,
          ),
        ),
      ],
    ];
  }

  List<_OptionsEntry> _buildSortingEntries(
    BuildContext context,
    ConfigModel config,
  ) {
    final sortBy = config.systemSortBy;
    final sortOrder = config.systemSortOrder;

    return [
      _OptionsEntry.group(AppLocale.sortByGroup.getString(context)),
      _OptionsEntry.row(
        _OptionRow(
          id: 'sort_alpha',
          label: AppLocale.alphabetical.getString(context),
          icon: Symbols.sort_by_alpha_rounded,
          selected: sortBy == 'alphabetical',
        ),
      ),
      _OptionsEntry.row(
        _OptionRow(
          id: 'sort_year',
          label: AppLocale.releaseYear.getString(context),
          icon: Symbols.calendar_today_rounded,
          selected: sortBy == 'year',
        ),
      ),
      _OptionsEntry.row(
        _OptionRow(
          id: 'sort_manufacturer',
          label: AppLocale.manufacturer.getString(context),
          icon: Symbols.business_rounded,
          selected: sortBy == 'manufacturer',
        ),
      ),
      _OptionsEntry.row(
        _OptionRow(
          id: 'sort_manufacturer_type',
          label: AppLocale.manufacturerType.getString(context),
          icon: Symbols.category_rounded,
          selected: sortBy == 'manufacturer_type',
        ),
      ),
      _OptionsEntry.group(AppLocale.orderGroup.getString(context)),
      _OptionsEntry.row(
        _OptionRow(
          id: 'order_asc',
          label: AppLocale.ascending.getString(context),
          icon: Symbols.arrow_upward_rounded,
          selected: sortOrder == 'asc',
        ),
      ),
      _OptionsEntry.row(
        _OptionRow(
          id: 'order_desc',
          label: AppLocale.descending.getString(context),
          icon: Symbols.arrow_downward_rounded,
          selected: sortOrder == 'desc',
        ),
      ),
    ];
  }

  List<_OptionsEntry> _submenuEntries(
    BuildContext context,
    ConfigModel config,
  ) {
    return _menu == _OptionsMenu.layout
        ? _buildLayoutEntries(context, config)
        : _buildSortingEntries(context, config);
  }

  List<_OptionRow> _rowsOf(List<_OptionsEntry> entries) => [
    for (final entry in entries)
      if (!entry.isGroup) entry.row!,
  ];

  List<_OptionRow> _currentRows(BuildContext context, ConfigModel config) {
    return _menu == _OptionsMenu.main
        ? _buildRootRows(context)
        : _rowsOf(_submenuEntries(context, config));
  }

  int _currentIndex() =>
      _menu == _OptionsMenu.main ? _rootIndex : _submenuIndex;

  void _setCurrentIndex(int index) {
    if (_menu == _OptionsMenu.main) {
      _rootIndex = index;
    } else {
      _submenuIndex = index;
    }
  }

  void _clampCurrent(List<_OptionRow> rows) {
    if (rows.isEmpty) {
      _setCurrentIndex(0);
      return;
    }
    final index = _currentIndex();
    if (index >= rows.length) {
      _setCurrentIndex(rows.length - 1);
    }
  }

  void _moveRow(int delta) {
    final config = context.read<SqliteConfigProvider>().config;
    final rows = _currentRows(context, config);
    _clampCurrent(rows);
    if (rows.isEmpty) return;

    final next = (_currentIndex() + delta).clamp(0, rows.length - 1);
    if (next == _currentIndex()) return;

    setState(() => _setCurrentIndex(next));
    SfxService().playNavSound();
    _revealRow(rows[next]);
  }

  void _moveCardSize(int delta) {
    if (_menu != _OptionsMenu.layout) return;

    final config = context.read<SqliteConfigProvider>().config;
    final rows = _rowsOf(_submenuEntries(context, config));
    _clampCurrent(rows);
    if (rows.isEmpty) return;
    if (!rows[_submenuIndex].segmented) return;

    const sizes = ['S', 'M', 'L', 'XL'];
    final current = sizes.indexOf(config.systemGridColumns);
    final next = (current < 0 ? 1 : current) + delta;
    if (next < 0 || next >= sizes.length) return;

    context.read<SqliteConfigProvider>().updateSystemGridColumns(sizes[next]);
    SfxService().playNavSound();
  }

  void _focusRow(int index) {
    setState(() => _setCurrentIndex(index));
  }

  void _activateFocused() {
    final config = context.read<SqliteConfigProvider>().config;
    final rows = _currentRows(context, config);
    _clampCurrent(rows);
    if (rows.isEmpty) return;

    final row = rows[_currentIndex()];
    if (row.segmented) {
      SfxService().playNavSound();
      return;
    }
    _activateRow(row);
  }

  Future<void> _activateRow(_OptionRow row) async {
    final provider = context.read<SqliteConfigProvider>();
    SfxService().playNavSound();

    switch (row.id) {
      case 'system_settings':
        Navigator.of(context).pop(SystemOptionsAction.gameSettings);
        return;
      case 'game_search':
        Navigator.of(context).pop(SystemOptionsAction.search);
        return;
      case 'system_layout':
        setState(() {
          _menu = _OptionsMenu.layout;
          _submenuIndex = 0;
        });
        return;
      case 'system_sorting':
        setState(() {
          _menu = _OptionsMenu.sorting;
          _submenuIndex = 0;
        });
        return;
      case 'view_grid':
        await provider.updateSystemViewMode('grid');
      case 'view_carousel':
        await provider.updateSystemViewMode('carousel');
      case 'sort_alpha':
        await provider.updateSystemSortBy('alphabetical');
      case 'sort_year':
        await provider.updateSystemSortBy('year');
      case 'sort_manufacturer':
        await provider.updateSystemSortBy('manufacturer');
      case 'sort_manufacturer_type':
        await provider.updateSystemSortBy('manufacturer_type');
      case 'order_asc':
        await provider.updateSystemSortOrder('asc');
      case 'order_desc':
        await provider.updateSystemSortOrder('desc');
    }

    if (!mounted) return;
    final rows = _rowsOf(_submenuEntries(context, provider.config));
    _clampCurrent(rows);
    if (rows.isNotEmpty) _revealRow(rows[_submenuIndex]);
  }

  void _goBack() {
    if (_isClosing) return;
    if (_menu != _OptionsMenu.main) {
      SfxService().playBackSound();
      setState(() {
        _menu = _OptionsMenu.main;
        _submenuIndex = 0;
      });
      return;
    }
    _close();
  }

  void _close() {
    if (_isClosing) return;
    _isClosing = true;
    SfxService().playBackSound();
    Navigator.of(context).pop();
  }

  void _revealRow(_OptionRow row) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final context = _keyFor(row.id).currentContext;
      if (context == null) return;
      Scrollable.ensureVisible(
        context,
        duration: const Duration(milliseconds: 120),
        curve: Curves.easeOut,
        alignment: 0.5,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final config = context.watch<SqliteConfigProvider>().config;
    final entries = _menu == _OptionsMenu.main
        ? const <_OptionsEntry>[]
        : _submenuEntries(context, config);
    final rows = _menu == _OptionsMenu.main
        ? _buildRootRows(context)
        : _rowsOf(entries);
    _clampCurrent(rows);

    final theme = Theme.of(context);
    final cornerRadii = theme.extension<CornerRadii>() ?? CornerRadii.m();
    final radii = cornerRadii.radiusExternal;
    final screen = MediaQuery.sizeOf(context);
    final panelWidth = screen.width * 0.34;
    final maxPanelHeight = screen.height * 0.82;

    return SafeArea(
      child: Align(
        alignment: Alignment.centerLeft,
        child: Padding(
          padding: EdgeInsets.only(left: 16.r, top: 12.r, bottom: 12.r),
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth: panelWidth,
              maxHeight: maxPanelHeight,
            ),
            child: SizedBox(
              width: panelWidth,
              child: Material(
                color: Colors.transparent,
                child: NeoGlassRim(
                  cornerRadius: cornerRadii.radiusExternalRadius,
                  child: Container(
                    decoration: BoxDecoration(
                      color: theme.colorScheme.surface,
                      borderRadius: radii,
                      border: Border.all(
                        color: theme.colorScheme.outline.withValues(alpha: 0.5),
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: theme.colorScheme.shadow.withValues(
                            alpha: 0.5,
                          ),
                          blurRadius: 24.r,
                          offset: Offset(8.r, 0),
                        ),
                      ],
                    ),
                    clipBehavior: Clip.antiAlias,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        _buildHeader(context),
                        Divider(
                          height: 1,
                          thickness: 1,
                          color: theme.colorScheme.outline.withValues(
                            alpha: 0.25,
                          ),
                        ),
                        Flexible(
                          fit: FlexFit.loose,
                          child: Padding(
                            padding: EdgeInsets.fromLTRB(
                              12.r,
                              10.r,
                              12.r,
                              12.r,
                            ),
                            child: _menu == _OptionsMenu.main
                                ? _buildRootBody(context, rows)
                                : _buildSubmenuBody(
                                    context,
                                    config,
                                    entries,
                                    rows,
                                  ),
                          ),
                        ),
                        Divider(
                          height: 1,
                          thickness: 1,
                          color: theme.colorScheme.outline.withValues(
                            alpha: 0.25,
                          ),
                        ),
                        _buildFooter(context),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildHeader(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: EdgeInsets.fromLTRB(8.r, 2.r, 8.r, 2.r),
      child: Row(
        children: [
          SizedBox(
            width: 26.r,
            child: _menu == _OptionsMenu.main
                ? null
                : _headerButton(context, Symbols.arrow_back_rounded, _goBack),
          ),
          Expanded(
            child: Center(
              child: Text(
                AppLocale.hintOptions.getString(context),
                style: TextStyle(
                  fontSize: 13.r,
                  fontWeight: FontWeight.w800,
                  color: theme.colorScheme.onSurface,
                ),
              ),
            ),
          ),
          SizedBox(
            width: 26.r,
            child: _headerButton(context, Symbols.close_rounded, _close),
          ),
        ],
      ),
    );
  }

  Widget _headerButton(
    BuildContext context,
    IconData icon,
    VoidCallback onTap,
  ) {
    final theme = Theme.of(context);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(6.r),
      child: Padding(
        padding: EdgeInsets.all(4.r),
        child: Icon(
          icon,
          size: 16.r,
          color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
        ),
      ),
    );
  }

  Widget _buildRootBody(BuildContext context, List<_OptionRow> rows) {
    final name = _isSearchCard
        ? ''
        : widget.system.title ?? widget.system.shortName ?? '';
    final selectedTitle = name.isEmpty
        ? AppLocale.systemOptionsSelectedSystem.getString(context)
        : '${AppLocale.systemOptionsSelectedSystem.getString(context)} $name';

    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildSectionLabel(
            context,
            AppLocale.systemOptionsSystemView.getString(context),
          ),
          SizedBox(height: 4.r),
          _buildRootRow(context, rows[0], 0),
          if (rows.length > 1) _buildRootRow(context, rows[1], 1),
          SizedBox(height: 12.r),
          _buildSectionLabel(context, selectedTitle),
          SizedBox(height: 4.r),
          if (_isSearchCard)
            _buildNoSystemMessage(context)
          else ...[
            if (rows.length > 2) _buildRootRow(context, rows[2], 2),
            if (rows.length > 3) _buildRootRow(context, rows[3], 3),
          ],
        ],
      ),
    );
  }

  Widget _buildSectionLabel(BuildContext context, String label) {
    final theme = Theme.of(context);
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: 4.r),
      child: Text(
        label.toUpperCase(),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontSize: 9.r,
          fontWeight: FontWeight.w700,
          letterSpacing: 1.r,
          color: theme.colorScheme.onSurface.withValues(alpha: 0.4),
        ),
      ),
    );
  }

  Widget _buildRootRow(BuildContext context, _OptionRow row, int index) {
    return _buildRow(
      context,
      row,
      focused: _rootIndex == index,
      onTap: () {
        _focusRow(index);
        _activateRow(row);
      },
      onHover: () => _focusRow(index),
    );
  }

  Widget _buildSubmenuBody(
    BuildContext context,
    ConfigModel config,
    List<_OptionsEntry> entries,
    List<_OptionRow> rows,
  ) {
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final entry in entries)
            if (entry.isGroup)
              _buildGroupLabel(context, entry.group!)
            else if (entry.row!.segmented)
              _buildCardSizeRow(context, config, rows.indexOf(entry.row!))
            else
              _buildRow(
                context,
                entry.row!,
                focused: _submenuIndex == rows.indexOf(entry.row!),
                onTap: () {
                  _focusRow(rows.indexOf(entry.row!));
                  _activateRow(entry.row!);
                },
                onHover: () => _focusRow(rows.indexOf(entry.row!)),
              ),
        ],
      ),
    );
  }

  Widget _buildCardSizeRow(
    BuildContext context,
    ConfigModel config,
    int rowIndex,
  ) {
    final theme = Theme.of(context);
    final focused = _submenuIndex == rowIndex;
    final accent = theme.colorScheme.primary;
    final cornerRadii = theme.extension<CornerRadii>() ?? CornerRadii.m();
    final radius = cornerRadii.radiusInternal;
    const sizes = ['S', 'M', 'L', 'XL'];
    final selected = sizes.indexOf(config.systemGridColumns);
    final focusedBackground = theme.colorScheme.onSurface;
    final focusedForeground = theme.colorScheme.surface;

    return Padding(
      padding: EdgeInsets.symmetric(vertical: 5.r),
      child: NeoGlassRim(
        cornerRadius: cornerRadii.radiusInternalRadius,
        child: Material(
          color: focused
              ? focusedBackground
              : theme.colorScheme.surfaceContainerHighest.withValues(
                  alpha: 0.16,
                ),
          borderRadius: radius,
          child: InkWell(
            key: _keyFor('card_size'),
            onTap: () => _focusRow(rowIndex),
            onHover: (hovering) {
              if (hovering) _focusRow(rowIndex);
            },
            focusColor: Colors.transparent,
            hoverColor: Colors.transparent,
            splashColor: Colors.transparent,
            highlightColor: Colors.transparent,
            borderRadius: radius,
            child: Container(
              padding: EdgeInsets.symmetric(horizontal: 10.r, vertical: 5.r),
              decoration: BoxDecoration(
                borderRadius: radius,
                border: Border.all(color: Colors.transparent, width: 1),
              ),
              child: Row(
                children: [
                  Icon(
                    Symbols.crop_free_rounded,
                    size: 17.r,
                    color: focused
                        ? focusedForeground
                        : theme.colorScheme.onSurface.withValues(alpha: 0.6),
                  ),
                  SizedBox(width: 9.r),
                  Expanded(
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                      children: sizes.asMap().entries.map((entry) {
                        final isSelected = entry.key == selected;
                        return InkWell(
                          onTap: () {
                            _focusRow(rowIndex);
                            context
                                .read<SqliteConfigProvider>()
                                .updateSystemGridColumns(entry.value);
                            SfxService().playNavSound();
                          },
                          focusColor: Colors.transparent,
                          hoverColor: Colors.transparent,
                          splashColor: Colors.transparent,
                          highlightColor: Colors.transparent,
                          borderRadius:
                              theme.extension<CornerRadii>()?.radiusInternal ??
                              BorderRadius.circular(4.r),
                          child: Container(
                            padding: EdgeInsets.symmetric(
                              horizontal: 7.r,
                              vertical: 3.r,
                            ),
                            decoration: BoxDecoration(
                              color: focused
                                  ? (isSelected
                                        ? focusedForeground
                                        : Colors.transparent)
                                  : (isSelected ? accent : Colors.transparent),
                              borderRadius:
                                  theme
                                      .extension<CornerRadii>()
                                      ?.radiusInternal ??
                                  BorderRadius.circular(4.r),
                            ),
                            child: Text(
                              entry.value,
                              style: TextStyle(
                                fontSize: 10.r,
                                fontWeight: FontWeight.w700,
                                color: focused
                                    ? (isSelected
                                          ? focusedBackground
                                          : focusedForeground.withValues(
                                              alpha: 0.65,
                                            ))
                                    : (isSelected
                                          ? theme.colorScheme.onPrimary
                                          : theme.colorScheme.onSurface),
                              ),
                            ),
                          ),
                        );
                      }).toList(),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildNoSystemMessage(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: 4.r, vertical: 4.r),
      child: Text(
        AppLocale.systemOptionsNoSystem.getString(context),
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontSize: 9.r,
          color: theme.colorScheme.onSurface.withValues(alpha: 0.55),
        ),
      ),
    );
  }

  Widget _buildGroupLabel(BuildContext context, String label) {
    final theme = Theme.of(context);
    return Padding(
      padding: EdgeInsets.fromLTRB(4.r, 10.r, 4.r, 4.r),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 9.r,
          fontWeight: FontWeight.w700,
          letterSpacing: 1.r,
          color: theme.colorScheme.onSurface.withValues(alpha: 0.38),
        ),
      ),
    );
  }

  Widget _buildRow(
    BuildContext context,
    _OptionRow row, {
    required bool focused,
    required VoidCallback onTap,
    required VoidCallback onHover,
  }) {
    final theme = Theme.of(context);
    final accent = theme.colorScheme.primary;
    final cornerRadii = theme.extension<CornerRadii>() ?? CornerRadii.m();
    final radius = cornerRadii.radiusInternal;
    final focusedBackground = theme.colorScheme.onSurface;
    final focusedForeground = theme.colorScheme.surface;
    final mutedSelection = Color.alphaBlend(
      theme.colorScheme.onSurface.withValues(alpha: 0.18),
      theme.colorScheme.surface,
    );

    return Padding(
      padding: EdgeInsets.symmetric(vertical: 5.r),
      child: NeoGlassRim(
        cornerRadius: cornerRadii.radiusInternalRadius,
        child: Material(
          color: focused
              ? focusedBackground
              : (row.selected
                    ? mutedSelection
                    : theme.colorScheme.surfaceContainerHighest.withValues(
                        alpha: 0.16,
                      )),
          borderRadius: radius,
          child: InkWell(
            key: _keyFor(row.id),
            onTap: onTap,
            onHover: (hovering) {
              if (hovering) onHover();
            },
            focusColor: Colors.transparent,
            hoverColor: Colors.transparent,
            splashColor: Colors.transparent,
            highlightColor: Colors.transparent,
            borderRadius: radius,
            child: Container(
              padding: EdgeInsets.symmetric(
                horizontal: 10.r,
                vertical: row.description == null ? 8.r : 7.r,
              ),
              decoration: BoxDecoration(
                borderRadius: radius,
                border: Border.all(color: Colors.transparent, width: 1),
              ),
              child: Row(
                children: [
                  Icon(
                    row.icon,
                    size: 17.r,
                    color: focused
                        ? focusedForeground
                        : theme.colorScheme.onSurface.withValues(alpha: 0.6),
                  ),
                  SizedBox(width: 9.r),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          row.label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 12.r,
                            fontWeight: row.selected
                                ? FontWeight.w700
                                : FontWeight.w500,
                            color: focused
                                ? focusedForeground
                                : theme.colorScheme.onSurface,
                          ),
                        ),
                        if (row.description != null) ...[
                          SizedBox(height: 1.r),
                          Text(
                            row.description!,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            softWrap: false,
                            style: TextStyle(
                              fontSize: 9.r,
                              height: 1.25,
                              color: focused
                                  ? focusedForeground.withValues(alpha: 0.6)
                                  : theme.colorScheme.onSurface.withValues(
                                      alpha: 0.5,
                                    ),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                  SizedBox(width: 4.r),
                  if (row.action)
                    Icon(
                      Symbols.chevron_right_rounded,
                      size: 16.r,
                      color: focused
                          ? focusedForeground.withValues(alpha: 0.7)
                          : theme.colorScheme.onSurface.withValues(alpha: 0.35),
                    )
                  else if (row.selected)
                    Icon(
                      Symbols.check_rounded,
                      size: 16.r,
                      color: focused ? focusedForeground : accent,
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildFooter(BuildContext context) {
    return Padding(
      padding: EdgeInsets.symmetric(vertical: 8.r),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          _buildHint(
            context,
            'assets/images/gamepad/Xbox_A_button.png',
            AppLocale.hintSelect.getString(context),
          ),
          SizedBox(width: 18.r),
          _buildHint(
            context,
            'assets/images/gamepad/Xbox_D-pad_ALL.png',
            AppLocale.hintNavigate.getString(context),
          ),
          SizedBox(width: 18.r),
          _buildHint(
            context,
            'assets/images/gamepad/Xbox_B_button.png',
            _menu == _OptionsMenu.main
                ? AppLocale.close.getString(context)
                : AppLocale.hintBack.getString(context),
          ),
        ],
      ),
    );
  }

  Widget _buildHint(BuildContext context, String asset, String label) {
    final theme = Theme.of(context);
    final color = theme.colorScheme.onSurface.withValues(alpha: 0.6);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        ColorFiltered(
          colorFilter: ColorFilter.mode(color, BlendMode.srcIn),
          child: Image.asset(asset, width: 15.r, height: 15.r),
        ),
        SizedBox(width: 5.r),
        Text(
          label,
          style: TextStyle(
            fontSize: 9.r,
            fontWeight: FontWeight.w600,
            color: color,
          ),
        ),
      ],
    );
  }
}

class _OptionsEntry {
  const _OptionsEntry.group(this.group) : row = null;

  const _OptionsEntry.row(this.row) : group = null;

  final String? group;
  final _OptionRow? row;

  bool get isGroup => group != null;
}

class _OptionRow {
  const _OptionRow({
    required this.id,
    required this.label,
    required this.icon,
    this.description,
    this.selected = false,
    this.action = false,
    this.segmented = false,
  });

  final String id;
  final String label;
  final String? description;
  final IconData icon;
  final bool selected;
  final bool action;
  final bool segmented;
}
