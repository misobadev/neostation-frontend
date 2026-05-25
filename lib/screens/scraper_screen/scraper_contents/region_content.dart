import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:neostation/l10n/app_locale.dart';
import 'package:neostation/repositories/scraper_repository.dart';
import 'package:neostation/services/sfx_service.dart';
import '../../settings_screen/new_settings_options/settings_title.dart';

class RegionContent extends StatefulWidget {
  final bool isContentFocused;
  final int selectedContentIndex;
  final ValueChanged<List<String>> onRegionPriorityChanged;

  const RegionContent({
    super.key,
    required this.isContentFocused,
    required this.selectedContentIndex,
    required this.onRegionPriorityChanged,
  });

  @override
  State<RegionContent> createState() => RegionContentState();
}

class RegionContentState extends State<RegionContent> {
  final ScrollController _scrollController = ScrollController();
  final Map<String, GlobalKey> _itemKeys = {};

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

  List<String> _orderedRegions = [];
  int _selectedIndex = 0;
  bool _isMoving = false;
  bool _isInitialized = false;

  @override
  void initState() {
    super.initState();
    _loadRegionPriority();
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _loadRegionPriority() async {
    final regions = await ScraperRepository.getRegionPriority();
    if (mounted) {
      setState(() {
        _orderedRegions = List<String>.from(regions);
        _itemKeys.clear();
        for (final code in _orderedRegions) {
          _itemKeys[code] = GlobalKey();
        }
        _isInitialized = true;
      });
    }
  }

  int get getItemCount => _orderedRegions.length;

  void navigateUp() {
    if (_isMoving) {
      _moveRegion(-1);
    } else {
      setState(() {
        _selectedIndex = (_selectedIndex - 1).clamp(0, _orderedRegions.length - 1);
      });
      scrollToIndex(_selectedIndex);
    }
  }

  void navigateDown() {
    if (_isMoving) {
      _moveRegion(1);
    } else {
      setState(() {
        _selectedIndex = (_selectedIndex + 1).clamp(0, _orderedRegions.length - 1);
      });
      scrollToIndex(_selectedIndex);
    }
  }

  bool navigateLeft() {
    if (_isMoving) {
      _dropItem();
      return false;
    }
    return true;
  }

  void navigateRight() {}

  void navigateBack() {
    if (_isMoving) {
      _dropItem();
    }
  }

  void selectItem() {
    if (_isMoving) {
      _dropItem();
    } else {
      setState(() {
        _isMoving = true;
      });
      SfxService().playNavSound();
    }
  }

  void _moveRegion(int direction) {
    final newIndex = _selectedIndex + direction;
    if (newIndex < 0 || newIndex >= _orderedRegions.length) return;

    SfxService().playNavSound();
    setState(() {
      final item = _orderedRegions.removeAt(_selectedIndex);
      _orderedRegions.insert(newIndex, item);
      _selectedIndex = newIndex;
    });
    scrollToIndex(_selectedIndex);
  }

  Future<void> _dropItem() async {
    SfxService().playNavSound();
    setState(() {
      _isMoving = false;
    });
    await _saveRegionPriority();
  }

  Future<void> _saveRegionPriority() async {
    final success = await ScraperRepository.saveRegionPriority(_orderedRegions);
    if (success && mounted) {
      widget.onRegionPriorityChanged(_orderedRegions);
    }
  }

  void _onReorder(int oldIndex, int newIndex) {
    if (newIndex > oldIndex) newIndex -= 1;
    SfxService().playNavSound();
    setState(() {
      final item = _orderedRegions.removeAt(oldIndex);
      _orderedRegions.insert(newIndex, item);
      _selectedIndex = newIndex;
      _isMoving = false;
    });
    _saveRegionPriority();
  }

  void scrollToIndex(int index) {
    if (index >= 0 && index < _orderedRegions.length) {
      final key = _itemKeys[_orderedRegions[index]];
      if (key != null) {
        final ctx = key.currentContext;
        if (ctx != null) {
          Scrollable.ensureVisible(
            ctx,
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeInOut,
            alignment: 0.5,
          );
        }
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_isInitialized) {
      return const Center(child: CircularProgressIndicator());
    }

    final theme = Theme.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SettingsTitle(
          title: AppLocale.regionPriority.getString(context),
          subtitle: AppLocale.regionPrioritySub.getString(context),
        ),
        SizedBox(height: 12.h),
        Expanded(
          child: ReorderableListView.builder(
            scrollController: _scrollController,
            physics: const BouncingScrollPhysics(),
            buildDefaultDragHandles: false,
            onReorder: _onReorder,
            itemCount: _orderedRegions.length,
            proxyDecorator: (child, index, animation) {
              return AnimatedBuilder(
                animation: animation,
                builder: (context, _) {
                  final animValue = Curves.easeInOut.transform(animation.value);
                  return Material(
                    elevation: 6.0 + (animValue * 6.0),
                    borderRadius: BorderRadius.circular(12.r),
                    color: Colors.transparent,
                    shadowColor: Theme.of(context).colorScheme.primary.withValues(alpha: 0.3),
                    child: Transform.scale(
                      scale: 1.02 + (animValue * 0.02),
                      child: Container(
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(12.r),
                          border: Border.all(
                            color: Theme.of(context).colorScheme.primary,
                            width: 2.r,
                          ),
                        ),
                        child: child,
                      ),
                    ),
                  );
                },
              );
            },
            itemBuilder: (context, index) {
              final regionCode = _orderedRegions[index];
              final isFocused = widget.isContentFocused && _selectedIndex == index;
              final isMovingItem = _isMoving && _selectedIndex == index;

              return Padding(
                key: _itemKeys[regionCode],
                padding: EdgeInsets.only(bottom: 4.h),
                child: _buildRegionCard(
                  context,
                  theme,
                  index: index,
                  regionCode: regionCode,
                  isFocused: isFocused,
                  isMovingItem: isMovingItem,
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _buildRegionCard(
    BuildContext context,
    ThemeData theme, {
    required int index,
    required String regionCode,
    required bool isFocused,
    required bool isMovingItem,
  }) {
    final regionName = _regionNames[regionCode] ?? regionCode.toUpperCase();
    final priority = index + 1;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        canRequestFocus: false,
        focusColor: Colors.transparent,
        hoverColor: Colors.transparent,
        highlightColor: Colors.transparent,
        splashColor: Colors.transparent,
        onTap: () {
          SfxService().playNavSound();
          if (_isMoving && _selectedIndex == index) {
            _dropItem();
          } else if (_isMoving) {
            setState(() {
              _selectedIndex = index;
            });
          } else {
            setState(() {
              _selectedIndex = index;
              _isMoving = true;
            });
          }
        },
        borderRadius: BorderRadius.circular(12.r),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
          padding: EdgeInsets.symmetric(horizontal: 12.r, vertical: 8.r),
          decoration: BoxDecoration(
            color: isMovingItem
                ? theme.colorScheme.primary.withValues(alpha: 0.2)
                : (isFocused
                    ? theme.cardColor.withValues(alpha: 0.5)
                    : theme.cardColor.withValues(alpha: 0.25)),
            borderRadius: BorderRadius.circular(12.r),
            border: Border.all(
              color: isMovingItem
                  ? theme.colorScheme.primary
                  : (isFocused
                      ? theme.colorScheme.primary.withValues(alpha: 0.5)
                      : theme.colorScheme.primary.withValues(alpha: 0.15)),
              width: isMovingItem ? 2.r : 1.r,
            ),
          ),
          child: Row(
            children: [
              Container(
                width: 28.r,
                height: 28.r,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: isMovingItem
                      ? theme.colorScheme.primary
                      : theme.colorScheme.onSurface.withValues(alpha: 0.1),
                ),
                child: Center(
                  child: Text(
                    '$priority',
                    style: theme.textTheme.labelSmall?.copyWith(
                      fontSize: 10.r,
                      fontWeight: FontWeight.bold,
                      color: isMovingItem
                          ? theme.colorScheme.onPrimary
                          : theme.colorScheme.onSurface.withValues(alpha: 0.6),
                    ),
                  ),
                ),
              ),
              SizedBox(width: 12.r),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      regionName,
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                        fontSize: 14.r,
                        color: isFocused
                            ? theme.colorScheme.primary
                            : theme.colorScheme.onSurface,
                      ),
                    ),
                    SizedBox(height: 2.r),
                    Text(
                      regionCode.toUpperCase(),
                      style: theme.textTheme.bodySmall?.copyWith(
                        fontSize: 10.r,
                        color: theme.colorScheme.onSurface.withValues(alpha: 0.4),
                      ),
                    ),
                  ],
                ),
              ),
              ReorderableDragStartListener(
                index: index,
                child: MouseRegion(
                  cursor: _isMoving && _selectedIndex == index
                      ? SystemMouseCursors.grabbing
                      : SystemMouseCursors.grab,
                  child: Padding(
                    padding: EdgeInsets.all(4.r),
                    child: isMovingItem
                        ? Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                Symbols.swap_vert_rounded,
                                size: 20.r,
                                color: theme.colorScheme.primary,
                              ),
                              SizedBox(width: 4.r),
                              Text(
                                '$priority/${_orderedRegions.length}',
                                style: theme.textTheme.labelSmall?.copyWith(
                                  fontSize: 10.r,
                                  color: theme.colorScheme.primary,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ],
                          )
                        : Icon(
                            Symbols.drag_indicator_rounded,
                            size: 20.r,
                            color: isFocused
                                ? theme.colorScheme.onSurface.withValues(alpha: 0.5)
                                : theme.colorScheme.onSurface.withValues(alpha: 0.2),
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
}
