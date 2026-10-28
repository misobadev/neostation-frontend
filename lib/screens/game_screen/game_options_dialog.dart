import 'package:neostation/constants/game_view_items.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:provider/provider.dart';
import 'package:neostation/l10n/app_locale.dart';
import 'package:neostation/models/config_model.dart';
import 'package:neostation/providers/sqlite_config_provider.dart';
import 'package:neostation/services/gamepad/gamepad_navigation_manager.dart';
import 'package:neostation/services/sfx_service.dart';
import 'package:neostation/themes/corner_radii.dart';
import 'package:neostation/utils/gamepad_nav.dart';
import 'package:neostation/widgets/context_menu/game_context_menu.dart';

/// Actions the game Options panel can hand back to the games screen.
enum GameOptionsAction {
  settings,
  scrape,
  identify,
  search,
  random,
  newCollection,
}

enum _GameMenu { main, view, addTo }

// This guard belongs to the shared entry point: separate mounted games screens
// can receive the same input before the dialog registers its navigation layer.
final _gameOptionsDialogs = Expando<bool>('game options dialog open');

/// Opens the games screen's Options menu from the left edge.
Future<GameOptionsAction?> showGameOptionsDialog({
  required BuildContext context,
  required String gameTitle,
  required List<GameContextMenuTarget> targets,
  required bool canScrape,
  required bool canIdentify,
  required String? createTargetLabel,
}) async {
  final navigator = Navigator.of(context, rootNavigator: true);
  if (_gameOptionsDialogs[navigator] == true) return null;
  _gameOptionsDialogs[navigator] = true;
  try {
    return await showGeneralDialog<GameOptionsAction>(
      context: context,
      barrierDismissible: true,
      barrierLabel: AppLocale.hintOptions.getString(context),
      barrierColor: Colors.black.withValues(alpha: 0.35),
      transitionDuration: const Duration(milliseconds: 220),
      pageBuilder: (context, animation, secondaryAnimation) =>
          GameOptionsDialog(
            gameTitle: gameTitle,
            targets: targets,
            canScrape: canScrape,
            canIdentify: canIdentify,
            createTargetLabel: createTargetLabel,
          ),
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
  } finally {
    _gameOptionsDialogs[navigator] = false;
  }
}

/// A left-side, gamepad-navigable list of everything the selected game can do.
class GameOptionsDialog extends StatefulWidget {
  const GameOptionsDialog({
    super.key,
    required this.gameTitle,
    required this.targets,
    required this.canScrape,
    required this.canIdentify,
    required this.createTargetLabel,
  });

  final String gameTitle;
  final List<GameContextMenuTarget> targets;
  final bool canScrape;
  final bool canIdentify;
  final String? createTargetLabel;

  @override
  State<GameOptionsDialog> createState() => _GameOptionsDialogState();
}

class _GameOptionsDialogState extends State<GameOptionsDialog> {
  _GameMenu _menu = _GameMenu.main;
  int _rootIndex = 0;
  int _submenuIndex = 0;

  final Map<String, GlobalKey> _rowKeys = {};
  final Map<String, bool> _members = {};
  final Set<String> _pendingToggles = {};

  late GamepadNavigation _gamepadNav;
  bool _isClosing = false;
  late final String _navLayerId =
      'game_options_dialog#${identityHashCode(this)}';

  @override
  void initState() {
    super.initState();
    for (final target in widget.targets) {
      _members[target.id] = target.isMember;
    }
    _gamepadNav = GamepadNavigation(
      onNavigateUp: () => _moveRow(-1),
      onNavigateDown: () => _moveRow(1),
      onNavigateLeft: () => _moveHorizontal(-1),
      onNavigateRight: () => _moveHorizontal(1),
      onSelectItem: _activateFocused,
      onBack: _goBack,
      onSettings: _close,
    );

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _gamepadNav.initialize();
      GamepadNavigationManager.pushLayer(
        _navLayerId,
        modal: true,
        onActivate: () => _gamepadNav.activate(),
        onDeactivate: () => _gamepadNav.deactivate(),
      );
    });
  }

  @override
  void dispose() {
    GamepadNavigationManager.popLayer(_navLayerId);
    _gamepadNav.dispose();
    super.dispose();
  }

  GlobalKey _keyFor(String id) => _rowKeys.putIfAbsent(id, GlobalKey.new);

  List<_MenuEntry> _buildRootEntries(BuildContext context) {
    return [
      _MenuEntry.group(
        '${AppLocale.gameOptionsThisGame.getString(context)} · '
        '${widget.gameTitle}',
      ),
      _MenuEntry.row(
        _OptionRow(
          id: 'game_settings',
          label: AppLocale.gameSettings.getString(context),
          icon: Symbols.settings_rounded,
          action: true,
        ),
      ),
      if (widget.canScrape)
        _MenuEntry.row(
          _OptionRow(
            id: 'scrape',
            label: AppLocale.hintScrape.getString(context),
            icon: Symbols.cloud_download_rounded,
            action: true,
          ),
        ),
      if (widget.canIdentify)
        _MenuEntry.row(
          _OptionRow(
            id: 'identify',
            label: AppLocale.identifyGame.getString(context),
            icon: Symbols.manage_search_rounded,
            action: true,
          ),
        ),
      if (widget.targets.isNotEmpty || widget.createTargetLabel != null)
        _MenuEntry.row(
          _OptionRow(
            id: 'add_to',
            label: AppLocale.addTo.getString(context),
            icon: Symbols.playlist_add_rounded,
            action: true,
          ),
        ),
      _MenuEntry.group(AppLocale.gameOptionsView.getString(context)),
      _MenuEntry.row(
        _OptionRow(
          id: 'search',
          label: AppLocale.systemOptionsGameSearch.getString(context),
          icon: Symbols.search_rounded,
          action: true,
        ),
      ),
      _MenuEntry.row(
        _OptionRow(
          id: 'view_mode',
          label: AppLocale.viewMode.getString(context),
          icon: Symbols.grid_view_rounded,
          action: true,
        ),
      ),
      _MenuEntry.row(
        _OptionRow(
          id: 'random',
          label: AppLocale.randomGame.getString(context),
          icon: Symbols.casino_rounded,
          action: true,
        ),
      ),
    ];
  }

  List<_MenuEntry> _buildAddToEntries(BuildContext context) {
    return [
      _MenuEntry.group(AppLocale.addTo.getString(context)),
      for (final target in widget.targets)
        _MenuEntry.row(
          _OptionRow(
            id: 'target:${target.id}',
            label: target.label,
            icon: target.icon,
            toggle: true,
            checked: _members[target.id] ?? target.isMember,
          ),
        ),
      if (widget.createTargetLabel != null)
        _MenuEntry.row(
          _OptionRow(
            id: 'new_collection',
            label: widget.createTargetLabel!,
            icon: Symbols.add_rounded,
            action: true,
          ),
        ),
    ];
  }

  List<_MenuEntry> _buildViewEntries(BuildContext context, ConfigModel config) {
    final mode = config.gameViewMode;
    return [
      _MenuEntry.group(AppLocale.viewModeGroup.getString(context)),
      _MenuEntry.row(
        _OptionRow(
          id: 'view_list',
          label: AppLocale.listView.getString(context),
          icon: Symbols.list_rounded,
          selected: mode == 'list',
        ),
      ),
      _MenuEntry.row(
        _OptionRow(
          id: 'view_grid',
          label: AppLocale.gridView.getString(context),
          icon: Symbols.grid_view_rounded,
          selected: mode == 'grid',
        ),
      ),
      _MenuEntry.row(
        _OptionRow(
          id: 'view_carousel',
          label: AppLocale.carouselView.getString(context),
          icon: Symbols.view_carousel_rounded,
          selected: mode == 'carousel',
        ),
      ),
      if (mode == 'grid') ...[
        _MenuEntry.group(AppLocale.cardSizeGroup.getString(context)),
        _MenuEntry.row(
          _OptionRow(
            id: 'card_size',
            label: '',
            icon: Symbols.crop_free_rounded,
            segmented: true,
          ),
        ),
      ],
      if (mode == 'grid' || mode == 'carousel') ...[
        _MenuEntry.group(AppLocale.cardStyleGroup.getString(context)),
        _MenuEntry.row(
          _OptionRow(
            id: 'card_style',
            label: '',
            icon: Symbols.style_rounded,
            segmented: true,
          ),
        ),
      ],
      if (mode == 'list') ...[
        _MenuEntry.group(AppLocale.listSizeGroup.getString(context)),
        _MenuEntry.row(
          _OptionRow(
            id: 'list_size',
            label: '',
            icon: Symbols.text_fields_rounded,
            segmented: true,
          ),
        ),
      ],
      // What this view shows, under its size and style. Each view keeps its
      // own choices and lists only the items its footer has.
      if (GameViewItem.itemsFor[mode] case final items?) ...[
        _MenuEntry.group(AppLocale.viewShowGroup.getString(context)),
        for (final item in items)
          _MenuEntry.row(
            _OptionRow(
              id: '$_viewItemPrefix$mode.$item',
              label: _viewItemLabel(context, item),
              icon: _viewItemIcon(item),
              toggle: true,
              checked: !GameViewItem.hiddenIn(
                config.gameViewHiddenItems,
                mode,
              ).contains(item),
            ),
          ),
      ],
    ];
  }

  List<_MenuEntry> _entriesFor(BuildContext context, ConfigModel config) {
    return switch (_menu) {
      _GameMenu.main => _buildRootEntries(context),
      _GameMenu.view => _buildViewEntries(context, config),
      _GameMenu.addTo => _buildAddToEntries(context),
    };
  }

  List<_OptionRow> _rowsOf(List<_MenuEntry> entries) => [
    for (final entry in entries)
      if (!entry.isGroup) entry.row!,
  ];

  int _currentIndex() => _menu == _GameMenu.main ? _rootIndex : _submenuIndex;

  void _setCurrentIndex(int index) {
    if (_menu == _GameMenu.main) {
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
    if (_currentIndex() >= rows.length) {
      _setCurrentIndex(rows.length - 1);
    }
  }

  void _moveRow(int delta) {
    final config = context.read<SqliteConfigProvider>().config;
    final rows = _rowsOf(_entriesFor(context, config));
    _clampCurrent(rows);
    if (rows.isEmpty) return;

    final next = (_currentIndex() + delta).clamp(0, rows.length - 1);
    if (next == _currentIndex()) return;

    setState(() => _setCurrentIndex(next));
    SfxService().playNavSound();
    _revealRow(rows[next]);
  }

  void _activateFocused() {
    final config = context.read<SqliteConfigProvider>().config;
    final rows = _rowsOf(_entriesFor(context, config));
    _clampCurrent(rows);
    if (rows.isEmpty) return;

    final row = rows[_currentIndex()];
    if (row.segmented) {
      SfxService().playNavSound();
      return;
    }
    if (row.toggle) {
      _toggleRow(row);
      return;
    }
    _activateRow(row);
  }

  Future<void> _activateRow(_OptionRow row) async {
    final provider = context.read<SqliteConfigProvider>();
    SfxService().playNavSound();

    switch (row.id) {
      case 'game_settings':
        Navigator.of(context).pop(GameOptionsAction.settings);
        return;
      case 'scrape':
        Navigator.of(context).pop(GameOptionsAction.scrape);
        return;
      case 'identify':
        Navigator.of(context).pop(GameOptionsAction.identify);
        return;
      case 'search':
        Navigator.of(context).pop(GameOptionsAction.search);
        return;
      case 'random':
        Navigator.of(context).pop(GameOptionsAction.random);
        return;
      case 'new_collection':
        Navigator.of(context).pop(GameOptionsAction.newCollection);
        return;
      case 'add_to':
        setState(() {
          _menu = _GameMenu.addTo;
          _submenuIndex = 0;
        });
        return;
      case 'view_mode':
        setState(() {
          _menu = _GameMenu.view;
          _submenuIndex = 0;
        });
        return;
      case 'view_list':
        await provider.updateGameViewMode('list');
      case 'view_grid':
        await provider.updateGameViewMode('grid');
      case 'view_carousel':
        await provider.updateGameViewMode('carousel');
    }

    if (!mounted) return;
    final rows = _rowsOf(_entriesFor(context, provider.config));
    _clampCurrent(rows);
    if (rows.isNotEmpty) _revealRow(rows[_submenuIndex]);
  }

  /// Flips a toggle row: the visibility of an item in a games view, or
  /// membership of an "Add to" target.
  void _toggleRow(_OptionRow row) {
    if (row.id.startsWith(_viewItemPrefix)) {
      final viewItem = row.id.substring(_viewItemPrefix.length);
      final dot = viewItem.indexOf('.');
      SfxService().playNavSound();
      // Checked means shown, so a checked row is being hidden.
      context.read<SqliteConfigProvider>().updateGameViewItemHidden(
        viewItem.substring(0, dot),
        viewItem.substring(dot + 1),
        row.checked,
      );
      return;
    }
    _toggleTarget(row);
  }

  static const String _viewItemPrefix = 'view_item:';

  String _viewItemLabel(BuildContext context, String item) => switch (item) {
    GameViewItem.fileName => AppLocale.fileName.getString(context),
    GameViewItem.playTime => AppLocale.playTime.getString(context),
    GameViewItem.rating => AppLocale.viewItemRating.getString(context),
    GameViewItem.achievements => AppLocale.achievements.getString(context),
    GameViewItem.random => AppLocale.randomGame.getString(context),
    GameViewItem.favorite => AppLocale.favorite.getString(context),
    GameViewItem.settings => AppLocale.gameSettings.getString(context),
    _ => AppLocale.play.getString(context),
  };

  static IconData _viewItemIcon(String item) => switch (item) {
    GameViewItem.fileName => Symbols.description_rounded,
    GameViewItem.playTime => Symbols.schedule_rounded,
    GameViewItem.rating => Symbols.star_rounded,
    GameViewItem.achievements => Symbols.trophy_rounded,
    GameViewItem.random => Symbols.casino_rounded,
    GameViewItem.favorite => Symbols.favorite_rounded,
    GameViewItem.settings => Symbols.settings_rounded,
    _ => Symbols.play_arrow_rounded,
  };

  Future<void> _toggleTarget(_OptionRow row) async {
    final targetId = row.id.substring('target:'.length);
    if (_pendingToggles.contains(targetId)) return;
    final target = widget.targets.firstWhere((t) => t.id == targetId);
    final member = !(_members[targetId] ?? target.isMember);

    setState(() => _members[targetId] = member);
    _pendingToggles.add(targetId);
    SfxService().playNavSound();

    final applied = await target.setMember(member);
    _pendingToggles.remove(targetId);
    if (!mounted) return;
    if (!applied) {
      setState(() => _members[targetId] = !member);
    }
  }

  void _goBack() {
    if (_isClosing) return;
    if (_menu != _GameMenu.main) {
      SfxService().playBackSound();
      setState(() {
        _menu = _GameMenu.main;
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
    final entries = _entriesFor(context, config);
    final rows = _rowsOf(entries);
    _clampCurrent(rows);

    final theme = Theme.of(context);
    final radii =
        theme.extension<CornerRadii>()?.radiusExternal ??
        BorderRadius.circular(16.r);
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
                child: Container(
                  decoration: BoxDecoration(
                    color: theme.colorScheme.surface,
                    borderRadius: radii,
                    border: Border.all(
                      color: theme.colorScheme.outline.withValues(alpha: 0.5),
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: theme.colorScheme.shadow.withValues(alpha: 0.5),
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
                          padding: EdgeInsets.fromLTRB(12.r, 6.r, 12.r, 10.r),
                          child: SingleChildScrollView(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                for (final entry in entries)
                                  if (entry.isGroup)
                                    _buildGroupLabel(context, entry.group!)
                                  else if (entry.row!.segmented)
                                    _buildSegmentedRow(
                                      context,
                                      config,
                                      entry.row!,
                                      rows.indexOf(entry.row!),
                                    )
                                  else
                                    _buildRow(
                                      context,
                                      entry.row!,
                                      focused:
                                          _currentIndex() ==
                                          rows.indexOf(entry.row!),
                                      onTap: () {
                                        _focusRow(rows.indexOf(entry.row!));
                                        if (entry.row!.toggle) {
                                          _toggleRow(entry.row!);
                                        } else {
                                          _activateRow(entry.row!);
                                        }
                                      },
                                      onHover: () =>
                                          _focusRow(rows.indexOf(entry.row!)),
                                    ),
                              ],
                            ),
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
    );
  }

  void _focusRow(int index) {
    setState(() => _setCurrentIndex(index));
  }

  Widget _buildHeader(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: EdgeInsets.fromLTRB(8.r, 2.r, 8.r, 2.r),
      child: Row(
        children: [
          SizedBox(
            width: 26.r,
            child: _menu == _GameMenu.main
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

  Widget _buildGroupLabel(BuildContext context, String label) {
    final theme = Theme.of(context);
    return Padding(
      padding: EdgeInsets.fromLTRB(4.r, 8.r, 4.r, 3.r),
      child: Text(
        label.toUpperCase(),
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontSize: 9.r,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.8,
          color: theme.colorScheme.onSurface.withValues(alpha: 0.4),
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
    final radius =
        theme.extension<CornerRadii>()?.radiusInternal ??
        BorderRadius.circular(8.r);

    return Padding(
      padding: EdgeInsets.symmetric(vertical: 2.r),
      child: Material(
        color: focused ? accent.withValues(alpha: 0.14) : Colors.transparent,
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
            padding: EdgeInsets.symmetric(horizontal: 10.r, vertical: 7.r),
            decoration: BoxDecoration(
              borderRadius: radius,
              border: focused
                  ? Border.all(color: accent.withValues(alpha: 0.45), width: 1)
                  : Border.all(color: Colors.transparent, width: 1),
            ),
            child: Row(
              children: [
                Icon(
                  row.icon,
                  size: 17.r,
                  color: focused
                      ? accent
                      : theme.colorScheme.onSurface.withValues(alpha: 0.6),
                ),
                SizedBox(width: 9.r),
                Expanded(
                  child: Text(
                    row.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 11.r,
                      fontWeight: row.selected
                          ? FontWeight.w700
                          : FontWeight.w500,
                      color: row.selected
                          ? accent
                          : theme.colorScheme.onSurface,
                    ),
                  ),
                ),
                SizedBox(width: 4.r),
                if (row.toggle)
                  Icon(
                    row.checked
                        ? Symbols.check_box_rounded
                        : Symbols.check_box_outline_blank_rounded,
                    size: 16.r,
                    color: row.checked
                        ? accent
                        : theme.colorScheme.onSurface.withValues(alpha: 0.35),
                  )
                else if (row.action)
                  Icon(
                    Symbols.chevron_right_rounded,
                    size: 16.r,
                    color: focused
                        ? accent
                        : theme.colorScheme.onSurface.withValues(alpha: 0.35),
                  )
                else if (row.selected)
                  Icon(Symbols.check_rounded, size: 16.r, color: accent),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildSegmentedRow(
    BuildContext context,
    ConfigModel config,
    _OptionRow row,
    int rowIndex,
  ) {
    final theme = Theme.of(context);
    final focused = _currentIndex() == rowIndex;
    final accent = theme.colorScheme.primary;
    final radius =
        theme.extension<CornerRadii>()?.radiusInternal ??
        BorderRadius.circular(8.r);
    final spec = _segmentSpec(context, config, row.id);
    if (spec == null) return const SizedBox.shrink();

    return Padding(
      padding: EdgeInsets.symmetric(vertical: 2.r),
      child: Material(
        color: focused ? accent.withValues(alpha: 0.14) : Colors.transparent,
        borderRadius: radius,
        child: InkWell(
          key: _keyFor(row.id),
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
              border: focused
                  ? Border.all(color: accent.withValues(alpha: 0.45), width: 1)
                  : Border.all(color: Colors.transparent, width: 1),
            ),
            child: Row(
              children: [
                Icon(
                  row.icon,
                  size: 17.r,
                  color: focused
                      ? accent
                      : theme.colorScheme.onSurface.withValues(alpha: 0.6),
                ),
                SizedBox(width: 9.r),
                Expanded(
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: spec.values.asMap().entries.map((entry) {
                      final isSelected = entry.key == spec.selectedIndex;
                      return InkWell(
                        onTap: () {
                          _focusRow(rowIndex);
                          spec.apply(entry.value);
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
                            horizontal: 6.r,
                            vertical: 3.r,
                          ),
                          decoration: BoxDecoration(
                            color: isSelected ? accent : Colors.transparent,
                            borderRadius:
                                theme
                                    .extension<CornerRadii>()
                                    ?.radiusInternal ??
                                BorderRadius.circular(4.r),
                          ),
                          child: Text(
                            spec.labels[entry.key],
                            style: TextStyle(
                              fontSize: 9.r,
                              fontWeight: FontWeight.w700,
                              color: isSelected
                                  ? theme.colorScheme.onPrimary
                                  : theme.colorScheme.onSurface,
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
    );
  }

  _SegmentSpec? _segmentSpec(
    BuildContext context,
    ConfigModel config,
    String id,
  ) {
    const sizes = ['S', 'M', 'L', 'XL'];
    switch (id) {
      case 'card_size':
        return _SegmentSpec(
          values: sizes,
          labels: sizes,
          selectedIndex: sizes.indexOf(config.gameGridColumns),
          apply: (value) =>
              context.read<SqliteConfigProvider>().updateGameGridColumns(value),
        );
      case 'card_style':
        const styles = ['fanart', 'box'];
        return _SegmentSpec(
          values: styles,
          labels: [
            AppLocale.fanartCard.getString(context),
            AppLocale.boxCard.getString(context),
          ],
          selectedIndex: styles.indexOf(config.gameCarouselCardStyle),
          apply: (value) => context
              .read<SqliteConfigProvider>()
              .updateGameCarouselCardStyle(value),
        );
      case 'list_size':
        return _SegmentSpec(
          values: sizes,
          labels: sizes,
          selectedIndex: sizes.indexOf(config.gameListSize),
          apply: (value) =>
              context.read<SqliteConfigProvider>().updateGameListSize(value),
        );
    }
    return null;
  }

  void _moveHorizontal(int delta) {
    if (_menu != _GameMenu.view) return;

    final config = context.read<SqliteConfigProvider>().config;
    final rows = _rowsOf(_entriesFor(context, config));
    _clampCurrent(rows);
    if (rows.isEmpty) return;
    final row = rows[_submenuIndex];
    if (!row.segmented) return;

    final spec = _segmentSpec(context, config, row.id);
    if (spec == null) return;

    final current = spec.selectedIndex < 0 ? 0 : spec.selectedIndex;
    final next = (current + delta).clamp(0, spec.values.length - 1);
    if (next == current) return;
    spec.apply(spec.values[next]);
    SfxService().playNavSound();
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
            _menu == _GameMenu.main
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

class _MenuEntry {
  const _MenuEntry.group(this.group) : row = null;

  const _MenuEntry.row(this.row) : group = null;

  final String? group;
  final _OptionRow? row;

  bool get isGroup => group != null;
}

class _OptionRow {
  const _OptionRow({
    required this.id,
    required this.label,
    required this.icon,
    this.selected = false,
    this.action = false,
    this.toggle = false,
    this.checked = false,
    this.segmented = false,
  });

  final String id;
  final String label;
  final IconData icon;
  final bool selected;
  final bool action;
  final bool toggle;
  final bool checked;
  final bool segmented;
}

class _SegmentSpec {
  const _SegmentSpec({
    required this.values,
    required this.labels,
    required this.selectedIndex,
    required this.apply,
  });

  final List<String> values;
  final List<String> labels;
  final int selectedIndex;
  final ValueChanged<String> apply;
}
