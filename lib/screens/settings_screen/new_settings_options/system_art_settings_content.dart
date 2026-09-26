import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:neostation/l10n/app_locale.dart';
import 'package:neostation/providers/neo_assets_provider.dart';
import 'package:neostation/providers/sqlite_config_provider.dart';
import 'package:neostation/services/game_service.dart'
    show GamepadNavigationManager;
import 'package:neostation/services/sfx_service.dart';
import 'package:neostation/utils/adaptive_scroll.dart';
import 'package:neostation/utils/gamepad_nav.dart';
import 'package:neostation/widgets/custom_toggle_switch.dart';
import 'package:neostation/widgets/system_art_pack_dialog.dart';
import 'package:neostation/widgets/system_art_pack_tile.dart';
import 'package:provider/provider.dart';
import 'settings_title.dart';
import 'widgets/setting_row.dart';

class SystemArtSettingsContent extends StatefulWidget {
  final bool isContentFocused;
  final int selectedContentIndex;
  final ValueChanged<int>? onSelectionChanged;

  const SystemArtSettingsContent({
    super.key,
    required this.isContentFocused,
    required this.selectedContentIndex,
    this.onSelectionChanged,
  });

  @override
  State<SystemArtSettingsContent> createState() =>
      SystemArtSettingsContentState();
}

class SystemArtSettingsContentState extends State<SystemArtSettingsContent> {
  final ScrollController _scrollController = ScrollController();

  /// Snaps during rapid D-pad navigation, animates on a single move.
  final AdaptiveScroller _scroller = AdaptiveScroller();
  final List<GlobalKey> _itemKeys = [];

  /// The list is a single column, so vertical navigation moves one row at a
  /// time. Left always returns to the category menu.
  static const int _gridColumns = 1;

  int getItemCount() => _itemKeys.length;

  void _initKeys(int count) {
    _itemKeys.clear();
    for (int i = 0; i < count; i++) {
      _itemKeys.add(GlobalKey());
    }
  }

  void _ensureSelectedItemVisible(int index) {
    _scroller.ensureVisibleIndex(
      index,
      keys: _itemKeys,
      controller: _scrollController,
    );
  }

  void navigateUp() {
    final newIndex = GridNavUtils.navigateUp(
      currentIndex: widget.selectedContentIndex,
      crossAxisCount: _gridColumns,
      maxItems: getItemCount(),
    );
    widget.onSelectionChanged?.call(newIndex);
    _ensureSelectedItemVisible(newIndex);
  }

  void navigateDown() {
    final newIndex = GridNavUtils.navigateDown(
      currentIndex: widget.selectedContentIndex,
      crossAxisCount: _gridColumns,
      maxItems: getItemCount(),
    );
    widget.onSelectionChanged?.call(newIndex);
    _ensureSelectedItemVisible(newIndex);
  }

  bool navigateLeft() {
    // Single-column list: Left always hands focus back to the menu.
    return true;
  }

  void navigateRight() {
    // Single-column list: there is nothing to the right.
  }

  void scrollToIndex(int index) => _ensureSelectedItemVisible(index);

  void selectItem(int index) {
    _onItemTapped(index);
  }

  /// Handles A/tap on a row: toggles the logos setting, clears the applied pack
  /// for "None", or opens the pack detail dialog for a pack.
  void _onItemTapped(int index) async {
    final neoAssets = context.read<NeoAssetsProvider>();
    final config = context.read<SqliteConfigProvider>();
    final themes = neoAssets.themes;

    // Index 0: hide the system card logos.
    if (index == 0) {
      await config.updateHideSystemLogos(!config.config.hideSystemLogos);
      return;
    }

    // Index 1: "None".
    if (index == 1) {
      // "None" has nothing to redownload, so re-picking it is a no-op.
      if (neoAssets.activeThemeFolder.isEmpty) return;
      final confirmed = await _showConfirmDialog(
        AppLocale.systemArtNone.getString(context),
        true,
      );
      if (!confirmed) return;
      if (!mounted) return;
      widget.onSelectionChanged?.call(index);
      await neoAssets.clearTheme();
      return;
    }

    // Index 2+: packs.
    final themeIndex = index - 2;
    if (themeIndex < 0 || themeIndex >= themes.length) return;
    widget.onSelectionChanged?.call(index);
    await SystemArtPackDialog.show(context, themes[themeIndex]);
  }

  Future<bool> _showConfirmDialog(
    String themeName,
    bool isNone, {
    bool isRedownload = false,
  }) async {
    final result = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => _ThemeConfirmDialog(
        themeName: themeName,
        isNone: isNone,
        isRedownload: isRedownload,
      ),
    );
    return result ?? false;
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final neoAssets = context.watch<NeoAssetsProvider>();
    final theme = Theme.of(context);

    final themes = neoAssets.themes;
    final config = context.watch<SqliteConfigProvider>();
    final itemCount = themes.length + 2; // toggle + "None".
    if (_itemKeys.length != itemCount) {
      _initKeys(itemCount);
    }

    return SingleChildScrollView(
      controller: _scrollController,
      physics: const ClampingScrollPhysics(),
      padding: EdgeInsets.only(bottom: 24.r),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SettingsTitle(
            title: AppLocale.systemArt.getString(context),
            subtitle: AppLocale.systemArtSubtitle.getString(context),
          ),
          SizedBox(height: 12.r),

          if (neoAssets.downloading)
            _buildDownloadProgress(neoAssets, theme)
          else if (neoAssets.loading)
            _buildLoadingIndicator(theme)
          else ...[
            _buildHideLogosRow(context, theme, config),
            _buildNoneTile(theme),
            for (int i = 0; i < themes.length; i++)
              Container(
                key: _itemKeys[i + 2],
                child: SystemArtPackTile(
                  pack: themes[i],
                  isActive: neoAssets.isThemeActive(themes[i].folder),
                  isFocused:
                      widget.isContentFocused &&
                      widget.selectedContentIndex == i + 2,
                  onTap: () {
                    SfxService().playNavSound();
                    _onItemTapped(i + 2);
                  },
                ),
              ),
          ],
        ],
      ),
    );
  }

  /// The global "hide system logos" toggle shown at the top of the section.
  Widget _buildHideLogosRow(
    BuildContext context,
    ThemeData theme,
    SqliteConfigProvider config,
  ) {
    return Padding(
      padding: EdgeInsets.only(bottom: 8.r),
      child: SettingRow(
        key: _itemKeys.isNotEmpty ? _itemKeys[0] : null,
        onTap: () {
          SfxService().playNavSound();
          _onItemTapped(0);
        },
        focused: widget.isContentFocused && widget.selectedContentIndex == 0,
        title: AppLocale.systemArtHideLogos.getString(context),
        subtitle: AppLocale.systemArtHideLogosSubtitle.getString(context),
        trailing: CustomToggleSwitch(
          value: config.config.hideSystemLogos,
          onChanged: (value) {
            context.read<SqliteConfigProvider>().updateHideSystemLogos(value);
          },
          activeColor: theme.colorScheme.primary,
        ),
      ),
    );
  }

  Widget _buildNoneTile(ThemeData theme) {
    final primary = theme.colorScheme.primary;
    final isFocused =
        widget.isContentFocused && widget.selectedContentIndex == 1;
    final isActive = context
        .watch<NeoAssetsProvider>()
        .activeThemeFolder
        .isEmpty;

    return Container(
      key: _itemKeys.length > 1 ? _itemKeys[1] : null,
      margin: EdgeInsets.symmetric(vertical: 4.r),
      padding: EdgeInsets.all(8.r),
      decoration: BoxDecoration(
        color: theme.cardColor,
        borderRadius: BorderRadius.circular(12.r),
        border: Border.all(
          color: isFocused
              ? primary
              : (isActive
                    ? Colors.greenAccent.withValues(alpha: 0.7)
                    : theme.colorScheme.onSurface.withValues(alpha: 0.12)),
          width: isFocused ? 2.r : 1.r,
        ),
      ),
      child: InkWell(
        onTap: () {
          SfxService().playNavSound();
          _onItemTapped(1);
        },
        child: Row(
          children: [
            Container(
              width: 64.r,
              height: 64.r,
              decoration: BoxDecoration(
                color: theme.colorScheme.surface,
                borderRadius: BorderRadius.circular(8.r),
              ),
              child: Center(
                child: Icon(
                  Symbols.block_rounded,
                  size: 28.r,
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.3),
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
                    AppLocale.systemArtNone.getString(context),
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontSize: 14.r,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  SizedBox(height: 4.r),
                  Text(
                    AppLocale.systemArtNoneSubtitle.getString(context),
                    style: TextStyle(
                      fontSize: 10.r,
                      color: theme.colorScheme.onSurface.withValues(
                        alpha: 0.65,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            if (isActive)
              Icon(
                Symbols.check_circle_rounded,
                size: 18.r,
                color: Colors.greenAccent,
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildLoadingIndicator(ThemeData theme) {
    return Padding(
      padding: EdgeInsets.all(32.r),
      child: Center(
        child: Column(
          children: [
            SizedBox(
              width: 24.r,
              height: 24.r,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: theme.colorScheme.primary,
              ),
            ),
            SizedBox(height: 12.r),
            Text(
              AppLocale.systemArtLoading.getString(context),
              style: theme.textTheme.bodyMedium?.copyWith(
                fontSize: 11.r,
                color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDownloadProgress(NeoAssetsProvider neoAssets, ThemeData theme) {
    final primary = theme.colorScheme.primary;
    final pct = (neoAssets.downloadProgress * 100).toInt();
    final counts = neoAssets.downloadTotal > 0
        ? '${neoAssets.downloadDone}/${neoAssets.downloadTotal}'
        : '';

    return Padding(
      padding: EdgeInsets.all(32.r),
      child: Center(
        child: Column(
          children: [
            SizedBox(
              width: 48.r,
              height: 48.r,
              child: CircularProgressIndicator(
                value: neoAssets.downloadProgress,
                strokeWidth: 3,
                color: primary,
                backgroundColor: primary.withValues(alpha: 0.15),
              ),
            ),
            SizedBox(height: 16.r),
            Text(
              AppLocale.systemArtDownloading.getString(context),
              style: theme.textTheme.bodyMedium?.copyWith(
                fontSize: 12.r,
                color: theme.colorScheme.onSurface.withValues(alpha: 0.8),
              ),
            ),
            SizedBox(height: 4.r),
            Text(
              counts.isEmpty ? '$pct%' : '$pct%  ($counts)',
              style: theme.textTheme.bodyLarge?.copyWith(
                fontSize: 14.r,
                fontWeight: FontWeight.w600,
                color: primary,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ThemeConfirmDialog extends StatefulWidget {
  final String themeName;
  final bool isNone;

  /// The pack is already applied and the user is re-picking it to wipe the
  /// cache and fetch it again — worded as a repair, not as applying a theme.
  final bool isRedownload;

  const _ThemeConfirmDialog({
    required this.themeName,
    required this.isNone,
    this.isRedownload = false,
  });

  @override
  State<_ThemeConfirmDialog> createState() => _ThemeConfirmDialogState();
}

class _ThemeConfirmDialogState extends State<_ThemeConfirmDialog> {
  late final GamepadNavigation _gamepadNav;

  @override
  void initState() {
    super.initState();
    _gamepadNav = GamepadNavigation(
      onSelectItem: () {
        if (mounted) Navigator.of(context).pop(true);
      },
      onBack: () {
        if (mounted) Navigator.of(context).pop(false);
      },
    );

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _gamepadNav.initialize();
      GamepadNavigationManager.pushLayer(
        'theme_confirm_dialog',
        onActivate: () => _gamepadNav.activate(),
        onDeactivate: () => _gamepadNav.deactivate(),
      );
    });
  }

  @override
  void dispose() {
    GamepadNavigationManager.popLayer('theme_confirm_dialog');
    _gamepadNav.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final primary = theme.colorScheme.primary;

    return AlertDialog(
      backgroundColor: theme.cardColor,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12.r),
        side: BorderSide(color: primary.withValues(alpha: 0.3)),
      ),
      title: Row(
        children: [
          Icon(Symbols.image_rounded, color: primary, size: 20.r),
          SizedBox(width: 8.r),
          Text(
            (widget.isRedownload
                    ? AppLocale.systemArtRedownloadTitle
                    : AppLocale.systemArtApplyTitle)
                .getString(context),
            style: theme.textTheme.titleMedium?.copyWith(
              fontSize: 14.r,
              color: primary,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '"${widget.themeName}"',
            style: theme.textTheme.bodyLarge?.copyWith(
              fontSize: 13.r,
              fontWeight: FontWeight.w600,
            ),
          ),
          if (!widget.isNone) ...[
            SizedBox(height: 8.r),
            Text(
              (widget.isRedownload
                      ? AppLocale.systemArtRedownloadBody
                      : AppLocale.systemArtApplyBody)
                  .getString(context),
              style: theme.textTheme.bodyMedium?.copyWith(
                fontSize: 11.r,
                color: theme.colorScheme.onSurface.withValues(alpha: 0.7),
              ),
            ),
          ],
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                width: 18.r,
                height: 18.r,
                child: Image.asset(
                  'assets/images/gamepad/Xbox_B_button.png',
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
                  colorBlendMode: BlendMode.srcIn,
                ),
              ),
              SizedBox(width: 4.r),
              Text(
                AppLocale.cancel.getString(context),
                style: TextStyle(
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
                  fontSize: 12.r,
                ),
              ),
            ],
          ),
        ),
        ElevatedButton(
          style: ElevatedButton.styleFrom(
            backgroundColor: primary,
            foregroundColor: theme.colorScheme.onPrimary,
            padding: EdgeInsets.symmetric(horizontal: 16.r, vertical: 8.r),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8.r),
            ),
          ),
          onPressed: () => Navigator.of(context).pop(true),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                width: 18.r,
                height: 18.r,
                child: Image.asset(
                  'assets/images/gamepad/Xbox_A_button.png',
                  color: theme.colorScheme.onPrimary,
                  colorBlendMode: BlendMode.srcIn,
                ),
              ),
              SizedBox(width: 4.r),
              Text(
                (widget.isRedownload ? AppLocale.download : AppLocale.apply)
                    .getString(context),
                style: TextStyle(fontSize: 12.r),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
