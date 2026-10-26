import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:provider/provider.dart';
import 'package:neostation/providers/sqlite_config_provider.dart';
import 'package:neostation/services/sfx_service.dart';
import 'package:neostation/utils/gamepad_nav.dart';
import 'package:neostation/models/config_model.dart';
import 'package:neostation/services/game_service.dart';
import 'package:neostation/l10n/app_locale.dart';
import 'package:flutter_localization/flutter_localization.dart';

import '../themes/corner_radii.dart';

/// Opens the view/sort picker used by the collections browser.
///
/// The systems screen moved its display and sorting controls into the centered
/// Options dialog, so this picker is no longer reached from the app header.
/// Collections still uses it: view mode and card size drive its cards exactly
/// as they drive the systems screen's, while release year / manufacturer
/// describe hardware and mean nothing for a collection.
///
/// [includeCardStyle] adds the box-art/fanart row. Systems cards are drawn from
/// theme artwork and have no such choice, but a collection card previews the
/// games it holds, and that preview follows the same setting the games views
/// use — so the collections browser offers the switch where its effect is
/// visible instead of making the user find a games list to change it.
///
/// [includeCollectionSorting] swaps in the sort rows that mean something for a
/// collection — name, date added, game count — writing
/// `collectionSortBy` / `collectionSortOrder` instead of the system pair. It is
/// the collections answer to [includeSorting]: the two are mutually exclusive,
/// because a picker cannot offer two different "sort by" groups at once.
Future<void> showSystemViewDropdown(
  BuildContext context, {
  bool includeSorting = true,
  bool includeCardStyle = false,
  bool includeCollectionSorting = false,
}) async {
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
          width: 180.r,
          includeSorting: includeSorting,
          includeCardStyle: includeCardStyle,
          includeCollectionSorting: includeCollectionSorting,
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
    } else if (result == 'csort_name') {
      await configProvider.updateCollectionSortBy('name');
    } else if (result == 'csort_date') {
      await configProvider.updateCollectionSortBy('date_added');
    } else if (result == 'csort_count') {
      await configProvider.updateCollectionSortBy('game_count');
    } else if (result == 'corder_asc') {
      await configProvider.updateCollectionSortOrder('asc');
    } else if (result == 'corder_desc') {
      await configProvider.updateCollectionSortOrder('desc');
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
    } else if (result.startsWith('card_style_')) {
      final style = result.substring('card_style_'.length);
      await configProvider.updateGameCarouselCardStyle(style);
    }
  }
}

class _DropdownOption {
  final String value;
  final String label;
  final IconData icon;
  final String group;
  final bool isCardSize;
  final bool isCardStyle;

  /// True for the two rows that hold a horizontal picker rather than being one
  /// selectable value.
  bool get isSegmented => isCardSize || isCardStyle;

  _DropdownOption(
    this.value,
    this.label,
    this.icon, {
    required this.group,
    this.isCardSize = false,
    this.isCardStyle = false,
  });
}

class SortDropdownOverlay extends StatefulWidget {
  final double width;

  /// Whether the "sort by" and "order" groups are offered.
  ///
  /// False for callers whose cards are not systems (the collections browser):
  /// the view-mode and card-size rows still apply, the hardware-describing sort
  /// rows do not. Suppressing rows here keeps one picker instead of a fork.
  final bool includeSorting;

  /// Whether the collection-shaped "sort by"/"order" groups are offered
  /// instead. See [showSystemViewDropdown].
  final bool includeCollectionSorting;

  /// Whether the box-art/fanart row is offered. See [showSystemViewDropdown].
  final bool includeCardStyle;

  const SortDropdownOverlay({
    super.key,
    required this.width,
    this.includeSorting = true,
    this.includeCardStyle = false,
    this.includeCollectionSorting = false,
  });

  @override
  State<SortDropdownOverlay> createState() => _SortDropdownOverlayState();
}

class _SortDropdownOverlayState extends State<SortDropdownOverlay> {
  late GamepadNavigation _gamepadNav;
  int _selectedIndex = 0;

  final ScrollController _scrollController = ScrollController();

  /// Whether there is more content above / below the viewport.
  ///
  /// Drives the edge fades. Without them a menu taller than the screen just
  /// stops mid-row at the panel border, which reads as broken rather than as
  /// scrollable — the state the collections picker landed in once its sort
  /// rows pushed the ORDER group past the bottom of a 1080 px screen.
  bool _canScrollUp = false;
  bool _canScrollDown = false;

  void _updateScrollEdges() {
    if (!mounted || !_scrollController.hasClients) return;
    final position = _scrollController.position;
    // A pixel of tolerance: bouncing physics overshoots by fractions and would
    // otherwise flip the fades on and off at rest.
    final up = position.pixels > 1.0;
    final down = position.pixels < position.maxScrollExtent - 1.0;
    if (up != _canScrollUp || down != _canScrollDown) {
      setState(() {
        _canScrollUp = up;
        _canScrollDown = down;
      });
    }
  }

  /// Index within the card-size row when it is focused. 0=S,1=M,2=L,3=XL
  int _cardSizeIndex = 1; // default M

  /// The two card styles, in the order the row lays them out.
  static const List<String> _cardStyles = ['fanart', 'box'];

  /// Index within the card-style row when it is focused.
  int _cardStyleIndex = 0;

  @override
  void initState() {
    super.initState();
    final config = context.read<SqliteConfigProvider>().config;
    final sizes = ['S', 'M', 'L', 'XL'];
    final idx = sizes.indexOf(config.systemGridColumns);
    _cardSizeIndex = idx >= 0 ? idx : 1;
    final styleIdx = _cardStyles.indexOf(config.gameCarouselCardStyle);
    _cardStyleIndex = styleIdx >= 0 ? styleIdx : 0;

    // The controller has no position until after the first layout, so the
    // initial state is read in a post-frame pass rather than here.
    _scrollController.addListener(_updateScrollEdges);
    WidgetsBinding.instance.addPostFrameCallback((_) => _updateScrollEdges());

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
        position += options[i].isSegmented ? 32.r : 28.r;
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
    } else if (opt.isCardStyle) {
      setState(() {
        _cardStyleIndex =
            (_cardStyleIndex - 1 + _cardStyles.length) % _cardStyles.length;
      });
      SfxService().playNavSound();
      _applyCardStyle();
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
    } else if (opt.isCardStyle) {
      setState(() {
        _cardStyleIndex = (_cardStyleIndex + 1) % _cardStyles.length;
      });
      SfxService().playNavSound();
      _applyCardStyle();
    }
  }

  void _applyCardSize() {
    final sizes = ['S', 'M', 'L', 'XL'];
    final size = sizes[_cardSizeIndex];
    final configProvider = context.read<SqliteConfigProvider>();
    configProvider.updateSystemGridColumns(size);
  }

  void _applyCardStyle() {
    context.read<SqliteConfigProvider>().updateGameCarouselCardStyle(
      _cardStyles[_cardStyleIndex],
    );
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
    if (opt.isCardStyle) {
      _applyCardStyle();
      Navigator.pop(context, 'card_style_${_cardStyles[_cardStyleIndex]}');
      return;
    }
    Navigator.pop(context, opt.value);
  }

  @override
  void dispose() {
    GamepadNavigationManager.popLayer('sort_dropdown_overlay');
    _gamepadNav.dispose();
    _scrollController.removeListener(_updateScrollEdges);
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

    if (widget.includeCardStyle) {
      options.add(
        _DropdownOption(
          'card_style',
          '',
          Symbols.image_rounded,
          group: AppLocale.cardStyleGroup.getString(context),
          isCardStyle: true,
        ),
      );
    }

    if (widget.includeCollectionSorting) {
      options.addAll([
        _DropdownOption(
          'csort_name',
          AppLocale.alphabetical.getString(context),
          Symbols.sort_by_alpha_rounded,
          group: AppLocale.sortByGroup.getString(context),
        ),
        _DropdownOption(
          'csort_date',
          AppLocale.dateAdded.getString(context),
          Symbols.calendar_today_rounded,
          group: AppLocale.sortByGroup.getString(context),
        ),
        _DropdownOption(
          'csort_count',
          AppLocale.sortByGameCount.getString(context),
          Symbols.tag_rounded,
          group: AppLocale.sortByGroup.getString(context),
        ),
        _DropdownOption(
          'corder_asc',
          AppLocale.ascending.getString(context),
          Symbols.arrow_upward_rounded,
          group: AppLocale.orderGroup.getString(context),
        ),
        _DropdownOption(
          'corder_desc',
          AppLocale.descending.getString(context),
          Symbols.arrow_downward_rounded,
          group: AppLocale.orderGroup.getString(context),
        ),
      ]);
      return options;
    }

    if (!widget.includeSorting) return options;

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
              color: Theme.of(context).colorScheme.outline,
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
                letterSpacing: 1.r,
                color: Theme.of(
                  context,
                ).colorScheme.onSurface.withValues(alpha: 0.4),
              ),
            ),
          ),
        );
        currentGroup = opt.group;
      }

      if (opt.isSegmented) {
        // One row, two shapes: the card-size row picks S/M/L/XL, the card-style
        // row picks fanart/box art. Same focus, same left/right handling, same
        // paint — only the values and where they are written differ.
        final isSize = opt.isCardSize;
        final values = isSize ? const ['S', 'M', 'L', 'XL'] : _cardStyles;
        final labels = isSize
            ? values
            : [
                AppLocale.fanartCard.getString(context),
                AppLocale.boxCard.getString(context),
              ];
        final currentValueIndex = values.indexOf(
          isSize ? config.systemGridColumns : config.gameCarouselCardStyle,
        );
        final stagedIndex = isSize ? _cardSizeIndex : _cardStyleIndex;
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
            borderRadius:
                Theme.of(context).extension<CornerRadii>()?.radiusExternal ??
                BorderRadius.circular(8.r),
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
                borderRadius:
                    Theme.of(
                      context,
                    ).extension<CornerRadii>()?.radiusExternal ??
                    BorderRadius.circular(8.r),
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
                    opt.icon,
                    size: 14.r,
                    color: Theme.of(
                      context,
                    ).colorScheme.onSurface.withValues(alpha: 0.5),
                  ),
                  SizedBox(width: 8.r),
                  Expanded(
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                      children: labels.asMap().entries.map((entry) {
                        final idx = entry.key;
                        final label = entry.value;
                        final isSelected =
                            (isFocused && idx == stagedIndex) ||
                            (!isFocused && idx == currentValueIndex);
                        return InkWell(
                          onTap: () {
                            setState(() {
                              _selectedIndex = i;
                              if (isSize) {
                                _cardSizeIndex = idx;
                              } else {
                                _cardStyleIndex = idx;
                              }
                            });
                            SfxService().playNavSound();
                            if (isSize) {
                              _applyCardSize();
                            } else {
                              _applyCardStyle();
                            }
                          },
                          focusColor: Colors.transparent,
                          hoverColor: Colors.transparent,
                          splashColor: Colors.transparent,
                          highlightColor: Colors.transparent,
                          borderRadius:
                              Theme.of(
                                context,
                              ).extension<CornerRadii>()?.radiusInternal ??
                              BorderRadius.circular(4.r),
                          child: Container(
                            padding: EdgeInsets.symmetric(
                              horizontal: 6.r,
                              vertical: 2.r,
                            ),
                            decoration: BoxDecoration(
                              color: isSelected
                                  ? Theme.of(context).colorScheme.primary
                                  : Colors.transparent,
                              borderRadius:
                                  Theme.of(
                                    context,
                                  ).extension<CornerRadii>()?.radiusInternal ??
                                  BorderRadius.circular(4.r),
                            ),
                            child: Text(
                              label,
                              style: TextStyle(
                                fontSize: 11.r,
                                fontWeight: FontWeight.w700,
                                color: isSelected
                                    ? Theme.of(context).colorScheme.onPrimary
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
      } else if (opt.value == 'csort_name') {
        isSelected = config.collectionSortBy == 'name';
      } else if (opt.value == 'csort_date') {
        isSelected = config.collectionSortBy == 'date_added';
      } else if (opt.value == 'csort_count') {
        isSelected = config.collectionSortBy == 'game_count';
      } else if (opt.value == 'corder_asc') {
        isSelected = config.collectionSortOrder == 'asc';
      } else if (opt.value == 'corder_desc') {
        isSelected = config.collectionSortOrder == 'desc';
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
                        ? Theme.of(context).colorScheme.primary
                        : Theme.of(context).colorScheme.onSurface,
                  ),
                  SizedBox(width: 8.r),
                  Expanded(
                    child: Text(
                      opt.label,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12.r,
                        color: isSelected
                            ? Theme.of(context).colorScheme.primary
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
                      color: Theme.of(context).colorScheme.primary,
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

  /// Fades whichever edge has content beyond it.
  ///
  /// `dstIn` multiplies the child's alpha by the gradient, so the rows nearest
  /// a scrollable edge dissolve instead of being sliced off square by the
  /// panel border. An edge with nothing beyond it keeps a hard stop, so the
  /// first and last rows are never dimmed for no reason, and a menu short
  /// enough to fit gets no mask at all.
  Widget _withEdgeFades({required Widget child}) {
    if (!_canScrollUp && !_canScrollDown) return child;

    return ShaderMask(
      blendMode: BlendMode.dstIn,
      shaderCallback: (bounds) => LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        stops: [
          0.0,
          _canScrollUp ? 0.05 : 0.0,
          _canScrollDown ? 0.95 : 1.0,
          1.0,
        ],
        colors: const [
          Colors.transparent,
          Colors.white,
          Colors.white,
          Colors.transparent,
        ],
      ).createShader(bounds),
      child: child,
    );
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
                borderRadius:
                    Theme.of(
                      context,
                    ).extension<CornerRadii>()?.radiusExternal ??
                    BorderRadius.circular(12.r),
                border: Border.all(
                  color: Theme.of(context).colorScheme.outline,
                  width: 1.r,
                ),
                boxShadow: [
                  BoxShadow(
                    color: Theme.of(
                      context,
                    ).colorScheme.shadow.withValues(alpha: 0.5),
                    blurRadius: 4.r,
                    offset: Offset(2.r, 2.r),
                  ),
                ],
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(12.r),
                child: _withEdgeFades(
                  // Metrics change without the controller's own listener
                  // firing — the first layout, and a row group appearing or
                  // disappearing between callers — so the notification is
                  // listened to as well as the controller.
                  child: NotificationListener<ScrollMetricsNotification>(
                    onNotification: (_) {
                      WidgetsBinding.instance.addPostFrameCallback(
                        (_) => _updateScrollEdges(),
                      );
                      return false;
                    },
                    // No scrollbar: the panel is narrow enough that a track
                    // crowds the rows, and the edge fades already say there is
                    // more. Rejected on device.
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
          ),
        ),
      ],
    );
  }
}
