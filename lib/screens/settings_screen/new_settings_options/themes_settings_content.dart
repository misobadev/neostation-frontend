import 'dart:io';

import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:neostation/l10n/app_locale.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:neostation/services/sfx_service.dart';
import 'package:neostation/utils/adaptive_scroll.dart';
import 'package:provider/provider.dart';
import 'package:neostation/providers/theme_provider.dart';
import 'package:neostation/providers/sqlite_config_provider.dart';
import 'package:neostation/themes/app_themes.dart';
import 'package:neostation/themes/corner_radii.dart';
import 'package:neostation/widgets/neo_glass.dart';
import 'package:neostation/themes/theme_glass.dart';
import 'package:neostation/services/permission_service.dart';
import 'package:neostation/services/logger_service.dart';
import 'package:neostation/widgets/theme_card.dart';
import 'package:neostation/widgets/custom_notification.dart';
import 'package:neostation/widgets/confirm_action_dialog.dart';
import 'package:neostation/widgets/tv_directory_picker.dart';
import 'package:neostation/responsive.dart';
import 'package:neostation/utils/gamepad_nav.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

import 'settings_title.dart';

import 'package:neostation/utils/user_data_move_guard.dart';

/// A specialized content panel for selecting application color themes and visual themes.
///
/// Implements a responsive grid layout with hardware-mapped gamepad navigation
/// (Up/Down/Left/Right) and real-time theme application via ThemeProvider.
class ThemesSettingsContent extends StatefulWidget {
  final bool isContentFocused;
  final int selectedContentIndex;
  final ValueChanged<int>? onSelectionChanged;

  const ThemesSettingsContent({
    super.key,
    required this.isContentFocused,
    required this.selectedContentIndex,
    this.onSelectionChanged,
  });

  @override
  State<ThemesSettingsContent> createState() => ThemesSettingsContentState();
}

class ThemesSettingsContentState extends State<ThemesSettingsContent> {
  final _log = LoggerService.instance;
  final ScrollController _scrollController = ScrollController();

  /// Snaps during rapid D-pad navigation, animates on a single move.
  final AdaptiveScroller _scroller = AdaptiveScroller();

  /// Keys used for calculating viewport alignment during grid-based navigation.
  final List<GlobalKey> _itemKeys = [];

  /// NeoGlass appearance rows shown at the top, above the theme grid.
  static const int _neoglassRowCount = 3;

  /// The corner rounding row, after the NeoGlass controls.
  static const int _cornerRowIndex = 1 + _neoglassRowCount;

  /// The option tiles above the theme grid, side by side: Performance Mode,
  /// the NeoGlass appearance controls and the corner rounding.
  static const int _topRowCount = _cornerRowIndex + 1;

  /// The grid column under option tile [index], and back: the row of tiles
  /// spans the grid's width, so each maps onto the column beneath it.
  int _columnUnderTile(int index) =>
      (index * _gridColumns / _topRowCount).floor().clamp(0, _gridColumns - 1);
  int _tileOverColumn(int column) =>
      (((column + 0.5) * _topRowCount) / _gridColumns).floor().clamp(
        0,
        _topRowCount - 1,
      );

  /// Blur sigma choices (Off / 1 / 2). 0 disables the blur entirely.
  static const List<int> _blurSteps = [0, 1, 2];

  /// Transparency choices on a 0–30 scale, stepped by 10: 0 = no transparency,
  /// 30 = maximum (50% see-through).
  static const List<int> _transparencySteps = [0, 10, 20, 30];

  /// Rim stroke width choices.
  static const List<double> _borderSteps = [0, 1, 2];

  /// Number of theme-grid cells (system + registered variants + import tile).
  int _gridCount(BuildContext context) => getItemCount(context) - _topRowCount;

  /// The first index owned by the theme grid (everything before it is a
  /// NeoGlass appearance row).
  int get _gridStartIndex => _topRowCount;

  @override
  void initState() {
    super.initState();
    _initializeKeys();
  }

  /// Populates the key list based on the total number of available themes.
  void _initializeKeys() {
    _itemKeys.clear();
    final themeProvider = Provider.of<ThemeProvider>(context, listen: false);
    // Total Items: Native System Theme + Registered Theme Variants + Import
    // tile + NeoGlass appearance rows.
    final count = themeProvider.getThemeList().length + 2 + _topRowCount;
    for (int i = 0; i < count; i++) {
      _itemKeys.add(GlobalKey());
    }
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  /// Resolves the total theme count.
  int getItemCount(BuildContext context) {
    final themeProvider = Provider.of<ThemeProvider>(context, listen: false);
    // System theme + registered variants + Import tile + NeoGlass rows.
    return themeProvider.getThemeList().length + 2 + _topRowCount;
  }

  /// Dynamic Grid Resolution: Column count based on display geometry.
  int get _gridColumns => Responsive.getThemesCrossAxisCount(context);

  /// Vertical Progression: Moves focus to the element above in the grid or back
  /// into the NeoGlass rows from the grid's first row.
  void navigateUp() {
    final current = widget.selectedContentIndex;
    final gridCount = _gridCount(context);
    int newIndex;
    if (current < _topRowCount) {
      // The option tiles are the top row: nothing above them.
      return;
    } else {
      final gridIndex = current - _gridStartIndex;
      if (gridIndex < _gridColumns) {
        // Top grid row: step up into the option tile above.
        newIndex = _tileOverColumn(gridIndex);
      } else {
        newIndex =
            _gridStartIndex +
            GridNavUtils.navigateUp(
              currentIndex: gridIndex,
              crossAxisCount: _gridColumns,
              maxItems: gridCount,
            );
      }
    }
    widget.onSelectionChanged?.call(newIndex);
    _ensureSelectedItemVisible(newIndex);
  }

  /// Vertical Progression: Moves focus to the element below in the grid or into
  /// the grid from the last NeoGlass row.
  void navigateDown() {
    final current = widget.selectedContentIndex;
    final gridCount = _gridCount(context);
    int newIndex;
    if (current < _topRowCount) {
      // Option tiles: down into the grid cell beneath.
      newIndex =
          _gridStartIndex + _columnUnderTile(current).clamp(0, gridCount - 1);
    } else {
      final gridIndex = current - _gridStartIndex;
      newIndex =
          _gridStartIndex +
          GridNavUtils.navigateDown(
            currentIndex: gridIndex,
            crossAxisCount: _gridColumns,
            maxItems: gridCount,
          );
    }
    widget.onSelectionChanged?.call(newIndex);
    _ensureSelectedItemVisible(newIndex);
  }

  /// Horizontal Progression: Moves focus left or exits to the master menu if at boundary.
  bool navigateLeft() {
    final current = widget.selectedContentIndex;
    if (current < _topRowCount) {
      // Along the option tiles; the first one hands back to the menu.
      if (current == 0) return true;
      widget.onSelectionChanged?.call(current - 1);
      return false;
    }
    final gridIndex = current - _gridStartIndex;
    if (gridIndex % _gridColumns == 0) {
      return true; // Boundary reached: Return focus to the master menu.
    }
    final newIndex =
        _gridStartIndex +
        GridNavUtils.navigateLeft(
          currentIndex: gridIndex,
          crossAxisCount: _gridColumns,
          maxItems: _gridCount(context),
        );
    widget.onSelectionChanged?.call(newIndex);
    _ensureSelectedItemVisible(newIndex);
    return false;
  }

  /// Horizontal Progression: Moves focus to the next element on the right.
  void navigateRight() {
    final current = widget.selectedContentIndex;
    if (current < _topRowCount) {
      // Along the option tiles.
      if (current < _topRowCount - 1) {
        widget.onSelectionChanged?.call(current + 1);
      }
      return;
    }
    final gridIndex = current - _gridStartIndex;
    final newIndex =
        _gridStartIndex +
        GridNavUtils.navigateRight(
          currentIndex: gridIndex,
          crossAxisCount: _gridColumns,
          maxItems: _gridCount(context),
        );
    widget.onSelectionChanged?.call(newIndex);
    _ensureSelectedItemVisible(newIndex);
  }

  /// Brings the focused grid cell into view (used when focus re-enters the panel).
  void scrollToIndex(int index) => _ensureSelectedItemVisible(index);

  /// Orchestrates visual alignment to ensure the focused theme card is within the viewport.
  void _ensureSelectedItemVisible(int index) {
    _scroller.ensureVisibleIndex(
      index,
      keys: _itemKeys,
      controller: _scrollController,
    );
  }

  /// Persistence Protocol: Updates the active application theme, or cycles a
  /// NeoGlass appearance option when [index] points at one of the rows at the
  /// top of the panel.
  void selectItem(int index) async {
    if (index < _topRowCount) {
      final config = context.read<SqliteConfigProvider>().config;
      if (index == 0) {
        await context.read<SqliteConfigProvider>().updatePerformanceMode(
          !config.performanceMode,
        );
      } else if (index == _cornerRowIndex) {
        await context.read<SqliteConfigProvider>().updateCornerRadius(
          (config.cornerRadius + 1) % CornerRadii.stepCount,
        );
      } else if (!config.performanceMode) {
        await _cycleNeoglassOption(index - 1);
      }
      widget.onSelectionChanged?.call(index);
      return;
    }

    final themeProvider = Provider.of<ThemeProvider>(context, listen: false);
    final themes = themeProvider.getThemeList();
    final gridIndex = index - _gridStartIndex;

    if (gridIndex == 0) {
      // Index 0: Native System/Dynamic theme resolution.
      await themeProvider.setTheme('system');
    } else if (gridIndex - 1 < themes.length) {
      // Indices >0: Specific registered theme variants. Imported themes may
      // ship NeoGlass defaults; seed them so the theme's frosted look applies.
      final name = themes[gridIndex - 1]['name']!;
      await themeProvider.setTheme(name);
      await _applyThemeGlass(AppThemes.customThemes[name]?.glass);
    } else {
      // Last item: the "Import theme" tile.
      await _importTheme();
      return;
    }
    if (mounted) setState(() {});
    widget.onSelectionChanged?.call(index);
  }

  /// Seeds the user's NeoGlass settings from the applied theme's `glass` block,
  /// when it ships one. Each value stays user-overridable afterwards.
  Future<void> _applyThemeGlass(ThemeGlass? glass) async {
    if (glass == null || !mounted) return;
    final config = Provider.of<SqliteConfigProvider>(context, listen: false);
    await config.updateNeoglassBlur(glass.blur);
    await config.updateNeoglassTransparency(glass.transparency);
    await config.updateNeoglassBorderWidth(glass.borderWidth);
  }

  /// Cycles the NeoGlass appearance option at [row] (0 = blur, 1 = transparency,
  /// 2 = border width) to its next step and persists it.
  Future<void> _cycleNeoglassOption(int row) async {
    final provider = Provider.of<SqliteConfigProvider>(context, listen: false);
    final config = provider.config;
    if (config.performanceMode) return;
    switch (row) {
      case 0:
        final current = _blurSteps.indexOf(config.neoglassBlur);
        final next = _blurSteps[(current + 1) % _blurSteps.length];
        await provider.updateNeoglassBlur(next);
        break;
      case 1:
        final current = _transparencySteps.indexOf(config.neoglassTransparency);
        final next =
            _transparencySteps[(current + 1) % _transparencySteps.length];
        await provider.updateNeoglassTransparency(next);
        break;
      case 2:
        final current = _borderSteps.indexWhere(
          (v) => (v - config.neoglassBorderWidth).abs() < 0.001,
        );
        final next = _borderSteps[(current + 1) % _borderSteps.length];
        await provider.updateNeoglassBorderWidth(next);
        break;
    }
  }

  /// Opens a file picker, imports the selected daisyUI theme JSON, and applies
  /// it. Surfaces success/failure via [AppNotification].
  Future<void> _importTheme() async {
    // Refused during a user-data move: the theme would stay in the old folder.
    if (refuseWhileUserDataMoves()) return;

    final themeProvider = Provider.of<ThemeProvider>(context, listen: false);
    final pickerTitle = AppLocale.importTheme.getString(context);
    try {
      String? filePath;

      if (Platform.isAndroid && await PermissionService.isTelevision()) {
        // Android TV has no system file picker; use the in-app one.
        if (mounted) {
          filePath = await TvDirectoryPicker.showFilePicker(
            context,
            extensions: ['json'],
          );
        }
      } else {
        final result = await FilePicker.pickFile(
          type: FileType.custom,
          allowedExtensions: ['json'],
          dialogTitle: pickerTitle,
        );
        filePath = result?.path;
      }

      if (filePath == null) return;

      final result = await themeProvider.importTheme(File(filePath));
      await _applyThemeGlass(result.theme.glass);
      if (mounted) setState(() {});
      if (mounted) {
        final name = result.theme.name;
        AppNotification.showNotification(
          context,
          (result.created
                  ? AppLocale.importThemeSuccess
                  : AppLocale.importThemeExists)
              .getString(context)
              .replaceAll('%s', name),
          type: result.created
              ? NotificationType.success
              : NotificationType.info,
        );
      }
    } on FormatException catch (e) {
      _log.e('Theme import failed (malformed): $e');
      if (mounted) {
        AppNotification.showNotification(
          context,
          AppLocale.importThemeError.getString(context),
          type: NotificationType.error,
        );
      }
    } catch (e) {
      _log.e('Theme import failed: $e');
      if (mounted) {
        AppNotification.showNotification(
          context,
          AppLocale.importThemeError.getString(context),
          type: NotificationType.error,
        );
      }
    }
  }

  /// Gamepad entry point: deletes the theme at [index] if it is a custom
  /// (imported) one. No-op for built-ins, 'system', or the Import tile.
  void deleteFocusedTheme(int index) {
    if (index < _topRowCount) return; // NeoGlass rows.
    final themeProvider = Provider.of<ThemeProvider>(context, listen: false);
    final themes = themeProvider.getThemeList();
    final themeIndex = index - _gridStartIndex - 1;
    if (themeIndex < 0) return; // System theme.
    if (themeIndex >= themes.length) return; // Import tile.
    final t = themes[themeIndex];
    if (!themeProvider.isCustomTheme(t['name']!)) return;
    _deleteTheme(t['name']!, t['displayName']!);
  }

  /// Confirms and deletes a user-imported theme.
  Future<void> _deleteTheme(String themeName, String displayName) async {
    final themeProvider = Provider.of<ThemeProvider>(context, listen: false);
    final confirmed = await ConfirmActionDialog.show(
      context,
      title: AppLocale.deleteThemeTitle.getString(context),
      body: AppLocale.deleteThemeConfirm
          .getString(context)
          .replaceAll('%s', displayName),
      confirmLabel: AppLocale.delete.getString(context),
      icon: Symbols.delete_rounded,
    );
    if (!confirmed) return;

    await themeProvider.deleteTheme(themeName);
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final themeProvider = Provider.of<ThemeProvider>(context);
    final config = context.watch<SqliteConfigProvider>().config;

    // Contextual Theme Model construction.
    final List<Map<String, String>> allThemes = [
      {
        'name': 'system',
        'displayName': AppLocale.systemTheme.getString(context),
      },
      ...themeProvider.getThemeList(),
    ];

    // Synchronization of GlobalKeys with the dynamic theme list (+1 = Import
    // tile, +_topRowCount = NeoGlass appearance rows).
    if (_itemKeys.length != allThemes.length + 1 + _topRowCount) {
      _initializeKeys();
    }

    return SingleChildScrollView(
      controller: _scrollController,
      physics: const ClampingScrollPhysics(),
      padding: EdgeInsets.only(bottom: 24.r),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SettingsTitle(
            title: AppLocale.themes.getString(context),
            subtitle: AppLocale.themesSubtitle.getString(context),
          ),
          SizedBox(height: 12.r),

          // The appearance options, compact so the themes show without
          // scrolling: one row of tiles, each its name and current value,
          // all as tall as the tallest.
          IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final (index, label, value, enabled) in [
                  (
                    0,
                    AppLocale.performanceMode.getString(context),
                    config.performanceMode ? 'ON' : 'OFF',
                    true,
                  ),
                  (
                    1,
                    AppLocale.neoglassBlur.getString(context),
                    _blurLabel(config.neoglassBlur),
                    !config.performanceMode,
                  ),
                  (
                    2,
                    AppLocale.neoglassTransparency.getString(context),
                    '${config.neoglassTransparency}',
                    !config.performanceMode,
                  ),
                  (
                    3,
                    AppLocale.neoglassBorderWidth.getString(context),
                    _borderLabel(config.neoglassBorderWidth),
                    !config.performanceMode,
                  ),
                  // Not a glass effect: it costs nothing, so performance mode
                  // leaves it alone.
                  (
                    _cornerRowIndex,
                    AppLocale.cornerRadius.getString(context),
                    _cornerLabels[config.cornerRadius.clamp(0, 5)],
                    true,
                  ),
                ]) ...[
                  if (index > 0) SizedBox(width: 6.r),
                  Expanded(
                    child: _buildOptionTile(
                      keyIndex: index,
                      label: label,
                      value: value,
                      enabled: enabled,
                    ),
                  ),
                ],
              ],
            ),
          ),
          if (config.performanceMode || config.neoglassBlur > 0) ...[
            SizedBox(height: 6.r),
            Text(
              config.performanceMode
                  ? AppLocale.performanceModeNeoglassDisabled.getString(context)
                  : AppLocale.neoglassBlurGpuWarning.getString(context),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 9.r,
                color: Theme.of(context).colorScheme.onSurface
                    .withValues(alpha: 0.6),
              ),
            ),
          ],
          SizedBox(height: 12.r),

          // Theme grid.
          GridView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            itemCount: allThemes.length + 1,
            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: _gridColumns,
              crossAxisSpacing: 8.r,
              mainAxisSpacing: 8.r,
              childAspectRatio: 1.05,
            ),
            itemBuilder: (context, gridIndex) {
              final index = gridIndex + _gridStartIndex;
              // Focus Resolution: Determines if the item is currently highlighted via gamepad.
              final isFocused =
                  widget.isContentFocused &&
                  widget.selectedContentIndex == index;

              // Last item: the "Import theme" tile.
              if (gridIndex == allThemes.length) {
                return Container(
                  key: _itemKeys[index],
                  child: ImportThemeCard(
                    label: AppLocale.importTheme.getString(context),
                    isFocused: isFocused,
                    onTap: () {
                      SfxService().playNavSound();
                      widget.onSelectionChanged?.call(index);
                      selectItem(index);
                    },
                  ),
                );
              }

              final t = allThemes[gridIndex];

              // State Resolution: Determines if the theme is currently active.
              final isSelected =
                  themeProvider.currentThemeName == t['name'] ||
                  (gridIndex == 0 &&
                      themeProvider.currentThemeName == 'system');

              final isCustom = themeProvider.isCustomTheme(t['name']!);

              return Container(
                key: _itemKeys[index],
                child: ThemeCard(
                  themeName: t['name']!,
                  displayName: t['displayName']!,
                  isSelected: isSelected,
                  isFocused: isFocused,
                  onTap: () {
                    SfxService().playNavSound();
                    widget.onSelectionChanged?.call(index);
                    selectItem(index);
                  },
                  onLongPress: isCustom
                      ? () => _deleteTheme(t['name']!, t['displayName']!)
                      : null,
                  onDelete: isCustom
                      ? () => _deleteTheme(t['name']!, t['displayName']!)
                      : null,
                ),
              );
            },
          ),
        ],
      ),
    );
  }

  /// One compact option tile: its name over its current value. A, a tap or
  /// a click steps it to its next value.
  Widget _buildOptionTile({
    required int keyIndex,
    required String label,
    required String value,
    required bool enabled,
  }) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final focused =
        widget.isContentFocused && widget.selectedContentIndex == keyIndex;
    final radius = (theme.extension<CornerRadii>() ?? CornerRadii.m())
        .radiusInternalRadius;
    final fg = focused ? scheme.surface : scheme.onSurface;
    final tile = AnimatedContainer(
      duration: const Duration(milliseconds: 140),
      // At least this tall, taller when the system text is larger.
      constraints: BoxConstraints(minHeight: 44.r),
      padding: EdgeInsets.symmetric(horizontal: 8.r, vertical: 6.r),
      decoration: BoxDecoration(
        color: focused
            ? scheme.onSurface
            : scheme.surface.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(radius),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            label,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 8.5.r, color: fg.withValues(alpha: 0.7)),
          ),
          SizedBox(height: 3.r),
          Text(
            value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 12.r,
              fontWeight: FontWeight.w700,
              color: fg,
            ),
          ),
        ],
      ),
    );
    final rimWidth = NeoGlass.borderWidthOf(context);
    return Opacity(
      opacity: enabled ? 1 : 0.4,
      child: IgnorePointer(
        ignoring: !enabled,
        child: Semantics(
          button: true,
          label: '$label: $value',
          excludeSemantics: true,
          child: GestureDetector(
            key: _itemKeys[keyIndex],
            behavior: HitTestBehavior.opaque,
            onTap: () {
              SfxService().playNavSound();
              widget.onSelectionChanged?.call(keyIndex);
              selectItem(keyIndex);
            },
            child: rimWidth <= 0
                ? tile
                : NeoGlassRim(
                    cornerRadius: radius,
                    borderWidth: rimWidth,
                    child: tile,
                  ),
          ),
        ),
      ),
    );
  }

  /// Labels for the corner steps, square to the roundest.
  static const List<String> _cornerLabels = ['0', 'XS', 'S', 'M', 'L', 'XL'];

  /// Label for a blur sigma: "Off" at 0, otherwise the number.
  String _blurLabel(int blur) =>
      blur == 0 ? AppLocale.neoglassBlurOff.getString(context) : '$blur';

  /// Label for a border width: "Off" at 0, otherwise the number.
  String _borderLabel(double border) => border == 0
      ? AppLocale.neoglassBlurOff.getString(context)
      : border.toStringAsFixed(0);
}
