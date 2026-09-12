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
import 'widgets/setting_row.dart';
import 'widgets/setting_value_chip.dart';

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

  /// Number of NeoGlass appearance rows shown at the top, above the theme grid.
  static const int _neoglassRowCount = 3;

  /// Blur sigma choices (Off / 1 / 2). 0 disables the blur entirely.
  static const List<int> _blurSteps = [0, 1, 2];

  /// Transparency choices on a 0–20 scale, stepped by 5: 0 = no transparency,
  /// 20 = maximum.
  static const List<int> _transparencySteps = [0, 5, 10, 15, 20];

  /// Rim stroke width choices.
  static const List<double> _borderSteps = [0, 1, 2, 3, 4];

  /// Number of theme-grid cells (system + registered variants + import tile).
  int _gridCount(BuildContext context) =>
      getItemCount(context) - _neoglassRowCount;

  /// The first index owned by the theme grid (everything before it is a
  /// NeoGlass appearance row).
  int get _gridStartIndex => _neoglassRowCount;

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
    final count = themeProvider.getThemeList().length + 2 + _neoglassRowCount;
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
    return themeProvider.getThemeList().length + 2 + _neoglassRowCount;
  }

  /// Dynamic Grid Resolution: Column count based on display geometry.
  int get _gridColumns => Responsive.getThemesCrossAxisCount(context);

  /// Vertical Progression: Moves focus to the element above in the grid or back
  /// into the NeoGlass rows from the grid's first row.
  void navigateUp() {
    final current = widget.selectedContentIndex;
    final gridCount = _gridCount(context);
    int newIndex;
    if (current < _neoglassRowCount) {
      // NeoGlass rows: move up, or wrap to the grid's last cell.
      newIndex = current == 0 ? _gridStartIndex + gridCount - 1 : current - 1;
    } else {
      final gridIndex = current - _gridStartIndex;
      if (gridIndex < _gridColumns) {
        // Top grid row: step up into the last NeoGlass row.
        newIndex = _neoglassRowCount - 1;
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
    if (current < _neoglassRowCount) {
      // NeoGlass rows: move down, or into the grid's first cell.
      newIndex = current == _neoglassRowCount - 1
          ? _gridStartIndex
          : current + 1;
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
    if (current < _neoglassRowCount) {
      return true; // NeoGlass rows are full-width; Left returns to the menu.
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
    if (current < _neoglassRowCount) {
      return; // NeoGlass rows are full-width; Right is a no-op.
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
    if (index < _neoglassRowCount) {
      await _cycleNeoglassOption(index);
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
      // Indices >0: Specific registered theme variants.
      await themeProvider.setTheme(themes[gridIndex - 1]['name']!);
    } else {
      // Last item: the "Import theme" tile.
      await _importTheme();
      return;
    }
    if (mounted) setState(() {});
    widget.onSelectionChanged?.call(index);
  }

  /// Cycles the NeoGlass appearance option at [row] (0 = blur, 1 = transparency,
  /// 2 = border width) to its next step and persists it.
  Future<void> _cycleNeoglassOption(int row) async {
    final provider = Provider.of<SqliteConfigProvider>(context, listen: false);
    final config = provider.config;
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
    if (index < _neoglassRowCount) return; // NeoGlass rows.
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
    // tile, +_neoglassRowCount = NeoGlass appearance rows).
    if (_itemKeys.length != allThemes.length + 1 + _neoglassRowCount) {
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

          // NeoGlass appearance controls (frosted-glass chrome).
          Text(
            AppLocale.neoglassGroup.getString(context),
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
              fontSize: 13.r,
              fontWeight: FontWeight.w600,
            ),
          ),
          SizedBox(height: 8.r),
          _buildNeoglassRow(
            keyIndex: 0,
            title: AppLocale.neoglassBlur.getString(context),
            subtitle: AppLocale.neoglassBlurSubtitle.getString(context),
            value: _blurLabel(config.neoglassBlur),
          ),
          if (config.neoglassBlur > 0) ...[
            SizedBox(height: 4.r),
            Padding(
              padding: EdgeInsets.symmetric(horizontal: 12.r),
              child: Text(
                AppLocale.neoglassBlurGpuWarning.getString(context),
                style: TextStyle(
                  fontSize: 9.r,
                  color: Theme.of(
                    context,
                  ).colorScheme.onSurface.withValues(alpha: 0.6),
                ),
              ),
            ),
          ],
          SizedBox(height: 8.r),
          _buildNeoglassRow(
            keyIndex: 1,
            title: AppLocale.neoglassTransparency.getString(context),
            subtitle: AppLocale.neoglassTransparencySubtitle.getString(context),
            value: '${config.neoglassTransparency}',
          ),
          SizedBox(height: 8.r),
          _buildNeoglassRow(
            keyIndex: 2,
            title: AppLocale.neoglassBorderWidth.getString(context),
            subtitle: AppLocale.neoglassBorderWidthSubtitle.getString(context),
            value: _borderLabel(config.neoglassBorderWidth),
          ),
          SizedBox(height: 20.r),

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

  /// Builds one NeoGlass appearance row (a [SettingRow] with a value chip).
  Widget _buildNeoglassRow({
    required int keyIndex,
    required String title,
    required String subtitle,
    required String value,
  }) {
    final isFocused =
        widget.isContentFocused && widget.selectedContentIndex == keyIndex;
    return SettingRow(
      key: _itemKeys[keyIndex],
      onTap: () {
        SfxService().playNavSound();
        widget.onSelectionChanged?.call(keyIndex);
        selectItem(keyIndex);
      },
      focused: isFocused,
      title: title,
      subtitle: subtitle,
      trailing: SettingValueChip(text: value),
    );
  }

  /// Label for a blur sigma: "Off" at 0, otherwise the number.
  String _blurLabel(int blur) =>
      blur == 0 ? AppLocale.neoglassBlurOff.getString(context) : '$blur';

  /// Label for a border width: "Off" at 0, otherwise the number.
  String _borderLabel(double border) => border == 0
      ? AppLocale.neoglassBlurOff.getString(context)
      : border.toStringAsFixed(0);
}
