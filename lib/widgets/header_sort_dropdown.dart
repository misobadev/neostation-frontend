import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:provider/provider.dart';
import 'package:neostation/providers/sqlite_config_provider.dart';
import 'package:neostation/services/sfx_service.dart';
import 'package:neostation/utils/gamepad_nav.dart';
import 'package:neostation/models/config_model.dart';
import 'package:neostation/services/game_service.dart'; // fallback if GamepadNavigationManager is there
import 'package:neostation/widgets/core_footer.dart';
import 'package:neostation/l10n/app_locale.dart';
import 'package:flutter_localization/flutter_localization.dart';

class HeaderSortDropdown extends StatefulWidget {
  static final GlobalKey<HeaderSortDropdownState> globalKey =
      GlobalKey<HeaderSortDropdownState>();

  HeaderSortDropdown() : super(key: globalKey);

  @override
  State<HeaderSortDropdown> createState() => HeaderSortDropdownState();
}

class HeaderSortDropdownState extends State<HeaderSortDropdown> {
  final GlobalKey _buttonKey = GlobalKey();

  void showDropdown() {
    _showDropdown(context);
  }

  void _showDropdown(BuildContext context) async {
    final RenderBox renderBox =
        _buttonKey.currentContext?.findRenderObject() as RenderBox;
    final Offset offset = renderBox.localToGlobal(Offset.zero);
    final Size size = renderBox.size;
    final configProvider = context.read<SqliteConfigProvider>();

    final result = await showGeneralDialog<String>(
      context: context,
      barrierDismissible: true,
      barrierLabel: "Sort Dropdown",
      barrierColor: Colors.transparent,
      pageBuilder: (context, animation, secondaryAnimation) {
        return FadeTransition(
          opacity: animation,
          child: SortDropdownOverlay(
            offset: offset + Offset(0, size.height + 6.r),
            width: 170.r,
          ),
        );
      },
    );

    if (result != null) {
      SfxService().playNavSound();
      if (result == 'sort_alpha') {
        await configProvider.updateSystemSortBy('alphabetical');
      } else if (result == 'sort_year') {
        await configProvider.updateSystemSortBy('year');
      } else if (result == 'sort_manufacturer') {
        await configProvider.updateSystemSortBy('manufacturer');
      } else if (result == 'sort_manufacturer_type') {
        await configProvider.updateSystemSortBy('manufacturer_type');
      } else if (result == 'order_asc') {
        await configProvider.updateSystemSortOrder('asc');
      } else if (result == 'order_desc') {
        await configProvider.updateSystemSortOrder('desc');
      } else if (result == 'view_grid') {
        await configProvider.updateSystemViewMode('grid');
      } else if (result == 'view_carousel') {
        await configProvider.updateSystemViewMode('carousel');
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      key: _buttonKey,
      margin: EdgeInsets.symmetric(horizontal: 10.r),
      child: GamepadControl(
        label: AppLocale.viewMode.getString(context),
        iconPath: 'assets/images/gamepad/Xbox_X_button.png',
        onTap: () {
          SfxService().playNavSound();
          _showDropdown(context);
        },
        backgroundColor: Theme.of(context).colorScheme.primary,
        textColor: Colors.white,
      ),
    );
  }
}

class _DropdownOption {
  final String value;
  final String label;
  final IconData icon;
  final String group;
  _DropdownOption(this.value, this.label, this.icon, {required this.group});
}

class SortDropdownOverlay extends StatefulWidget {
  final Offset offset;
  final double width;

  const SortDropdownOverlay({
    super.key,
    required this.offset,
    required this.width,
  });

  @override
  State<SortDropdownOverlay> createState() => _SortDropdownOverlayState();
}

class _SortDropdownOverlayState extends State<SortDropdownOverlay> {
  late GamepadNavigation _gamepadNav;
  int _selectedIndex = 0;

  final List<GlobalKey> _itemKeys = List.generate(8, (_) => GlobalKey());
  final GlobalKey _colKey = GlobalKey();
  final ScrollController _scrollController = ScrollController();
  double _indicatorTop = -1;

  @override
  void initState() {
    super.initState();
    _gamepadNav = GamepadNavigation(
      onNavigateUp: () {
        setState(() {
          _selectedIndex = (_selectedIndex - 1 + 8) % 8;
        });
        _updateIndicator();
        SfxService().playNavSound();
      },
      onNavigateDown: () {
        setState(() {
          _selectedIndex = (_selectedIndex + 1) % 8;
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
        'sort_dropdown_overlay',
        onActivate: () => _gamepadNav.activate(),
        onDeactivate: () => _gamepadNav.deactivate(),
      );
      _updateIndicator();
    });
  }

  void _updateIndicator() {
    if (!mounted) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final key = _itemKeys[_selectedIndex];
      final RenderBox? box =
          key.currentContext?.findRenderObject() as RenderBox?;
      // _colKey is inside the ScrollView — gives document (scroll-independent) coords
      final RenderBox? colBox =
          _colKey.currentContext?.findRenderObject() as RenderBox?;
      if (box != null && colBox != null) {
        final offset = box.localToGlobal(Offset.zero, ancestor: colBox);
        setState(() {
          _indicatorTop = offset.dy;
        });
      }
      // Scroll AFTER position is committed so ensureVisible uses the new layout
      final ctx = key.currentContext;
      if (ctx != null) {
        Scrollable.ensureVisible(
          ctx,
          duration: const Duration(milliseconds: 150),
          curve: Curves.easeInOut,
          alignment: 0.5,
        );
      }
    });
  }

  void _handleSelection() {
    final List<_DropdownOption> options = _getOptions(context);
    Navigator.pop(context, options[_selectedIndex].value);
  }

  @override
  void dispose() {
    GamepadNavigationManager.popLayer('sort_dropdown_overlay');
    _gamepadNav.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  List<_DropdownOption> _getOptions(BuildContext context) {
    return [
      _DropdownOption(
        'view_grid',
        AppLocale.gridView.getString(context),
        Symbols.grid_view_rounded,
        group: AppLocale.viewModeGroup.getString(context),
      ),
      _DropdownOption(
        'view_carousel',
        AppLocale.carouselView.getString(context),
        Symbols.view_carousel_rounded,
        group: AppLocale.viewModeGroup.getString(context),
      ),
      _DropdownOption(
        'sort_alpha',
        AppLocale.alphabetical.getString(context),
        Symbols.sort_by_alpha_rounded,
        group: AppLocale.sortByGroup.getString(context),
      ),
      _DropdownOption(
        'sort_year',
        AppLocale.releaseYear.getString(context),
        Symbols.calendar_today_rounded,
        group: AppLocale.sortByGroup.getString(context),
      ),
      _DropdownOption(
        'sort_manufacturer',
        AppLocale.manufacturer.getString(context),
        Symbols.business_rounded,
        group: AppLocale.sortByGroup.getString(context),
      ),
      _DropdownOption(
        'sort_manufacturer_type',
        AppLocale.manufacturerType.getString(context),
        Symbols.category_rounded,
        group: AppLocale.sortByGroup.getString(context),
      ),
      _DropdownOption(
        'order_asc',
        AppLocale.ascending.getString(context),
        Symbols.arrow_upward_rounded,
        group: AppLocale.orderGroup.getString(context),
      ),
      _DropdownOption(
        'order_desc',
        AppLocale.descending.getString(context),
        Symbols.arrow_downward_rounded,
        group: AppLocale.orderGroup.getString(context),
      ),
    ];
  }

  List<Widget> _buildItems(ConfigModel config) {
    final options = _getOptions(context);
    List<Widget> children = [];
    String? currentGroup;

    for (int i = 0; i < options.length; i++) {
      final opt = options[i];
      if (opt.group != currentGroup) {
        if (currentGroup != null) {
          children.add(
            Divider(
              height: 4.r,
              thickness: 1,
              color: Theme.of(
                context,
              ).colorScheme.outline.withValues(alpha: 0.1),
            ),
          );
        }
        children.add(
          Padding(
            padding: EdgeInsets.symmetric(horizontal: 16.r, vertical: 6.r),
            child: Text(
              opt.group,
              style: TextStyle(
                fontSize: 10.r,
                fontWeight: FontWeight.w800,
                letterSpacing: 1.r,
                color: Theme.of(
                  context,
                ).colorScheme.onSurface.withValues(alpha: 0.5),
              ),
            ),
          ),
        );
        currentGroup = opt.group;
      }

      bool isSelected = false;
      if (opt.value == 'sort_alpha') {
        isSelected = config.systemSortBy == 'alphabetical';
      } else if (opt.value == 'sort_year') {
        isSelected = config.systemSortBy == 'year';
      } else if (opt.value == 'sort_manufacturer') {
        isSelected = config.systemSortBy == 'manufacturer';
      } else if (opt.value == 'sort_manufacturer_type') {
        isSelected = config.systemSortBy == 'manufacturer_type';
      } else if (opt.value == 'order_asc') {
        isSelected = config.systemSortOrder == 'asc';
      } else if (opt.value == 'order_desc') {
        isSelected = config.systemSortOrder == 'desc';
      } else if (opt.value == 'view_grid') {
        isSelected = config.systemViewMode == 'grid';
      } else if (opt.value == 'view_carousel') {
        isSelected = config.systemViewMode == 'carousel';
      }

      children.add(
        Container(
          key: _itemKeys[i],
          height: 24.r,
          margin: EdgeInsets.symmetric(horizontal: 4.r, vertical: 2.r),
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
            child: Container(
              padding: EdgeInsets.symmetric(horizontal: 12.r),
              child: Row(
                children: [
                  Icon(
                    opt.icon,
                    size: 14.r,
                    color: isSelected
                        ? Theme.of(context).colorScheme.secondary
                        : Theme.of(
                            context,
                          ).colorScheme.onSurface.withValues(alpha: 0.9),
                  ),
                  SizedBox(width: 8.r),
                  Expanded(
                    child: Text(
                      opt.label,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12.r,
                        color: isSelected
                            ? Theme.of(context).colorScheme.secondary
                            : Theme.of(context).colorScheme.onSurface,
                        fontWeight: isSelected
                            ? FontWeight.w700
                            : FontWeight.w500,
                      ),
                    ),
                  ),
                  if (isSelected)
                    Icon(
                      Symbols.check_rounded,
                      size: 14.r,
                      color: Theme.of(context).colorScheme.secondary,
                    ),
                ],
              ),
            ),
          ),
        ),
      );
    }
    return children;
  }

  @override
  Widget build(BuildContext context) {
    final configProvider = context.watch<SqliteConfigProvider>();
    final config = configProvider.config;
    final screenHeight = MediaQuery.of(context).size.height;
    final bottomPadding = MediaQuery.of(context).padding.bottom;
    // dropdown starts at top: 42.r — use all remaining space minus a small bottom margin
    final maxDropdownHeight = screenHeight - 42.r - bottomPadding - 16.r;

    return Stack(
      children: [
        Positioned(
          top: 42.r,
          left: 6.r,
          width: widget.width,
          child: Material(
            color: Colors.transparent,
            child: Container(
              constraints: BoxConstraints(maxHeight: maxDropdownHeight),
              padding: EdgeInsets.symmetric(vertical: 8.r),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surface,
                borderRadius: BorderRadius.circular(12.r),
                border: Border.all(
                  color: Theme.of(
                    context,
                  ).colorScheme.primary.withValues(alpha: 0.2),
                  width: 1,
                ),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.5),
                    blurRadius: 15,
                    offset: const Offset(0, 5),
                  ),
                ],
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(12.r),
                child: SingleChildScrollView(
                  controller: _scrollController,
                  physics: const BouncingScrollPhysics(),
                  // Stack inside ScrollView — _colKey coords are document-space
                  child: Stack(
                    key: _colKey,
                    children: [
                      Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: _buildItems(config),
                      ),
                      // Indicator inside scroll → scrolls with content, always aligned
                      if (_indicatorTop >= 0)
                        AnimatedPositioned(
                          duration: const Duration(milliseconds: 150),
                          curve: Curves.easeInOut,
                          top: _indicatorTop,
                          left: 4.r,
                          right: 4.r,
                          height: 28.r,
                          child: IgnorePointer(
                            child: Container(
                              decoration: BoxDecoration(
                                color: Theme.of(
                                  context,
                                ).colorScheme.primary.withValues(alpha: 0.15),
                                borderRadius: BorderRadius.circular(8.r),
                                border: Border.all(
                                  color: Theme.of(
                                    context,
                                  ).colorScheme.primary.withValues(alpha: 0.3),
                                  width: 1,
                                ),
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
