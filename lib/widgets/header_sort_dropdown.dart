import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:provider/provider.dart';
import 'package:neostation/providers/sqlite_config_provider.dart';
import 'package:neostation/services/sfx_service.dart';
import 'package:neostation/utils/gamepad_nav.dart';
import 'package:neostation/models/config_model.dart';
import 'package:neostation/services/game_service.dart';
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
      } else if (result.startsWith('card_size_')) {
        final size = result.substring('card_size_'.length);
        await configProvider.updateSystemGridColumns(size);
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
  final bool isCardSize;
  _DropdownOption(
    this.value,
    this.label,
    this.icon, {
    required this.group,
    this.isCardSize = false,
  });
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

  final ScrollController _scrollController = ScrollController();

  /// Index within the card-size row when it is focused. 0=S,1=M,2=L,3=XL
  int _cardSizeIndex = 1; // default M

  @override
  void initState() {
    super.initState();
    final config = context.read<SqliteConfigProvider>().config;
    final sizes = ['S', 'M', 'L', 'XL'];
    final idx = sizes.indexOf(config.systemGridColumns);
    _cardSizeIndex = idx >= 0 ? idx : 1;

    _gamepadNav = GamepadNavigation(
      onNavigateUp: () {
        final count = _getOptions(context).length;
        setState(() {
          _selectedIndex = (_selectedIndex - 1 + count) % count;
        });
        _scrollToSelected();
        SfxService().playNavSound();
      },
      onNavigateDown: () {
        final count = _getOptions(context).length;
        setState(() {
          _selectedIndex = (_selectedIndex + 1) % count;
        });
        _scrollToSelected();
        SfxService().playNavSound();
      },
      onNavigateLeft: _handleNavigateLeft,
      onNavigateRight: _handleNavigateRight,
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
    });
  }

  void _scrollToSelected() {
    if (!mounted) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final options = _getOptions(context);
      if (_selectedIndex < 0 || _selectedIndex >= options.length) return;

      // Approximate scroll position based on item height.
      // Group header = 16.r, divider = 4.r, normal item = 28.r (24+margin), card-size = 32.r (28+margin)
      double position = 8.r; // top padding
      for (int i = 0; i < _selectedIndex; i++) {
        if (options[i].group != (i > 0 ? options[i - 1].group : null)) {
          position += 16.r; // header
          if (i > 0) position += 4.r; // divider
        }
        position += options[i].isCardSize ? 32.r : 28.r;
      }
      // add header for current if it's the first of group
      if (_selectedIndex == 0 ||
          options[_selectedIndex].group != options[_selectedIndex - 1].group) {
        position += 16.r;
      }

      _scrollController.animateTo(
        position.clamp(0.0, _scrollController.position.maxScrollExtent),
        duration: const Duration(milliseconds: 150),
        curve: Curves.easeInOut,
      );
    });
  }

  void _handleNavigateLeft() {
    final options = _getOptions(context);
    if (_selectedIndex < 0 || _selectedIndex >= options.length) return;
    final opt = options[_selectedIndex];
    if (opt.isCardSize) {
      setState(() {
        _cardSizeIndex = (_cardSizeIndex - 1 + 4) % 4;
      });
      SfxService().playNavSound();
      _applyCardSize();
    }
  }

  void _handleNavigateRight() {
    final options = _getOptions(context);
    if (_selectedIndex < 0 || _selectedIndex >= options.length) return;
    final opt = options[_selectedIndex];
    if (opt.isCardSize) {
      setState(() {
        _cardSizeIndex = (_cardSizeIndex + 1) % 4;
      });
      SfxService().playNavSound();
      _applyCardSize();
    }
  }

  void _applyCardSize() {
    final sizes = ['S', 'M', 'L', 'XL'];
    final size = sizes[_cardSizeIndex];
    final configProvider = context.read<SqliteConfigProvider>();
    configProvider.updateSystemGridColumns(size);
  }

  void _handleSelection() {
    final List<_DropdownOption> options = _getOptions(context);
    final opt = options[_selectedIndex];
    if (opt.isCardSize) {
      _applyCardSize();
      Navigator.pop(
        context,
        'card_size_${['S', 'M', 'L', 'XL'][_cardSizeIndex]}',
      );
      return;
    }
    Navigator.pop(context, opt.value);
  }

  @override
  void dispose() {
    GamepadNavigationManager.popLayer('sort_dropdown_overlay');
    _gamepadNav.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  List<_DropdownOption> _getOptions(BuildContext context) {
    final config = context.read<SqliteConfigProvider>().config;
    final List<_DropdownOption> options = [
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
    ];

    if (config.systemViewMode == 'grid') {
      options.add(
        _DropdownOption(
          'card_size',
          '',
          Symbols.crop_free_rounded,
          group: AppLocale.cardSizeGroup.getString(context),
          isCardSize: true,
        ),
      );
    }

    options.addAll([
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
    ]);

    return options;
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

      if (opt.isCardSize) {
        final sizes = ['S', 'M', 'L', 'XL'];
        final currentSizeIndex = sizes.indexOf(config.systemGridColumns);
        final isFocused = i == _selectedIndex;

        children.add(
          InkWell(
            onTap: () {
              setState(() => _selectedIndex = i);
            },
            focusColor: Colors.transparent,
            hoverColor: Colors.transparent,
            splashColor: Colors.transparent,
            highlightColor: Colors.transparent,
            borderRadius: BorderRadius.circular(8.r),
            child: Container(
              height: 28.r,
              margin: EdgeInsets.symmetric(horizontal: 4.r, vertical: 2.r),
              padding: EdgeInsets.symmetric(horizontal: 12.r),
              decoration: BoxDecoration(
                color: isFocused
                    ? Theme.of(
                        context,
                      ).colorScheme.primary.withValues(alpha: 0.15)
                    : Colors.transparent,
                borderRadius: BorderRadius.circular(8.r),
                border: isFocused
                    ? Border.all(
                        color: Theme.of(
                          context,
                        ).colorScheme.primary.withValues(alpha: 0.3),
                        width: 1,
                      )
                    : null,
              ),
              child: Row(
                children: [
                  Icon(
                    Symbols.crop_free_rounded,
                    size: 14.r,
                    color: Theme.of(
                      context,
                    ).colorScheme.onSurface.withValues(alpha: 0.9),
                  ),
                  SizedBox(width: 8.r),
                  Expanded(
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                      children: sizes.asMap().entries.map((entry) {
                        final idx = entry.key;
                        final size = entry.value;
                        final isSelected =
                            (isFocused && idx == _cardSizeIndex) ||
                            (!isFocused && idx == currentSizeIndex);
                        return InkWell(
                          onTap: () {
                            setState(() {
                              _selectedIndex = i;
                              _cardSizeIndex = idx;
                            });
                            SfxService().playNavSound();
                            _applyCardSize();
                          },
                          focusColor: Colors.transparent,
                          hoverColor: Colors.transparent,
                          splashColor: Colors.transparent,
                          highlightColor: Colors.transparent,
                          borderRadius: BorderRadius.circular(4.r),
                          child: Container(
                            padding: EdgeInsets.symmetric(
                              horizontal: 6.r,
                              vertical: 2.r,
                            ),
                            decoration: BoxDecoration(
                              color: isSelected
                                  ? Theme.of(context).colorScheme.secondary
                                  : Colors.transparent,
                              borderRadius: BorderRadius.circular(4.r),
                            ),
                            child: Text(
                              size,
                              style: TextStyle(
                                fontSize: 11.r,
                                fontWeight: FontWeight.w700,
                                color: isSelected
                                    ? Theme.of(context).colorScheme.onSecondary
                                    : Theme.of(context).colorScheme.onSurface,
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
        );
        continue;
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

      final bool itemIsFocused = i == _selectedIndex;

      children.add(
        Container(
          height: 24.r,
          margin: EdgeInsets.symmetric(horizontal: 4.r, vertical: 2.r),
          decoration: BoxDecoration(
            color: itemIsFocused
                ? Theme.of(context).colorScheme.primary.withValues(alpha: 0.15)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(8.r),
            border: itemIsFocused
                ? Border.all(
                    color: Theme.of(
                      context,
                    ).colorScheme.primary.withValues(alpha: 0.3),
                    width: 1,
                  )
                : null,
          ),
          child: InkWell(
            onTap: () {
              setState(() => _selectedIndex = i);
              _handleSelection();
            },
            onHover: (v) {
              if (v) {
                setState(() => _selectedIndex = i);
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
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: _buildItems(config),
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
