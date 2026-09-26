import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:neostation/l10n/app_locale.dart';
import 'package:neostation/services/sfx_service.dart';
import 'package:neostation/utils/adaptive_scroll.dart';
import 'package:provider/provider.dart';
import '../../../providers/sqlite_config_provider.dart';
import '../../../providers/sqlite_database_provider.dart';
import '../../../widgets/custom_toggle_switch.dart';
import '../../../constants/recent_card_sizes.dart';
import '../../../constants/system_folder_names.dart';
import 'settings_title.dart';
import 'widgets/setting_value_chip.dart';
import 'widgets/settings_card_row.dart';

/// A specialized content panel for managing system visibility and interface components.
///
/// Orchestrates the display status of individual emulation systems and global
/// UI features like the 'Recent Games' card.
class SystemsSettingsContent extends StatefulWidget {
  final bool isContentFocused;
  final int selectedContentIndex;

  const SystemsSettingsContent({
    super.key,
    required this.isContentFocused,
    required this.selectedContentIndex,
  });

  @override
  State<SystemsSettingsContent> createState() => SystemsSettingsContentState();
}

class SystemsSettingsContentState extends State<SystemsSettingsContent> {
  final ScrollController _scrollController = ScrollController();

  /// Snaps during rapid D-pad navigation, animates on a single move.
  final AdaptiveScroller _scroller = AdaptiveScroller();

  /// GlobalKeys for maintaining focal visibility during gamepad navigation.
  final List<GlobalKey> _itemKeys = [];

  /// Ensures sufficient keys exist for the dynamic number of detected systems.
  void _ensureKeys(int count) {
    while (_itemKeys.length < count) {
      _itemKeys.add(GlobalKey());
    }
  }

  /// Synchronizes the viewport to ensure the currently focused setting is visible.
  void scrollToIndex(int index) {
    _scroller.ensureVisibleIndex(
      index,
      keys: _itemKeys,
      controller: _scrollController,
    );
  }

  /// Calculates the total number of navigable settings (Global Card + Detected Systems).
  int getItemCount(SqliteConfigProvider provider) {
    // hideRecent + recent card size + search card + favorites +
    // detectedSystems (excluding favorites to avoid duplication)
    return 4 +
        provider.detectedSystems
            .where((s) => s.folderName != SystemFolderNames.favorites)
            .length;
  }

  /// Executes the toggle action for the specified system or feature.
  void selectItem(int index, SqliteConfigProvider provider) {
    SfxService().playNavSound();
    final items = _buildItems(provider);
    if (index >= 0 && index < items.length) {
      final item = items[index];
      if (!item.isDisabled) {
        item.onToggle();
      }
    }
  }

  List<_SystemSettingRow> _buildItems(SqliteConfigProvider provider) {
    final hiddenFolders = provider.hiddenSystemFolders;
    final systems = provider.detectedSystems;
    final totalFavorites = context
        .read<SqliteDatabaseProvider>()
        .totalFavorites;
    final hasFavorites = totalFavorites > 0;

    return <_SystemSettingRow>[
      _SystemSettingRow(
        icon: Symbols.access_time_rounded,
        title: AppLocale.hideRecentCard.getString(context),
        subtitle: AppLocale.hideRecentCardSubtitle.getString(context),
        isEnabled: !provider.config.hideRecentCard,
        onToggle: () =>
            provider.updateHideRecentCard(!provider.config.hideRecentCard),
      ),
      _SystemSettingRow(
        icon: Symbols.aspect_ratio_rounded,
        title: AppLocale.recentCardSize.getString(context),
        subtitle: AppLocale.recentCardSizeSubtitle.getString(context),
        // The size only means anything while the card is on screen.
        isDisabled: provider.config.hideRecentCard,
        valueText: provider.config.recentCardSize == RecentCardSizes.twoByOne
            ? AppLocale.recentCardSize2x1.getString(context)
            : AppLocale.recentCardSizeDefault.getString(context),
        onToggle: () => provider.updateRecentCardSize(
          provider.config.recentCardSize == RecentCardSizes.twoByOne
              ? RecentCardSizes.defaultSize
              : RecentCardSizes.twoByOne,
        ),
      ),
      _SystemSettingRow(
        icon: Symbols.search_rounded,
        title: AppLocale.searchCard.getString(context),
        subtitle: AppLocale.searchCardSubtitle.getString(context),
        isEnabled: !provider.config.hideSearchCard,
        onToggle: () =>
            provider.updateHideSearchCard(!provider.config.hideSearchCard),
      ),
      _SystemSettingRow(
        icon: Symbols.favorite_rounded,
        title: AppLocale.favorite.getString(context),
        subtitle: SystemFolderNames.favorites,
        isEnabled:
            hasFavorites &&
            !hiddenFolders.contains(SystemFolderNames.favorites),
        isHideToggle: true,
        isDisabled: !hasFavorites,
        onToggle: hasFavorites
            ? () => provider.toggleSystemHidden(SystemFolderNames.favorites)
            : () {},
      ),
      ...systems
          .where((s) => s.folderName != SystemFolderNames.favorites)
          .map(
            (s) => _SystemSettingRow(
              icon: Symbols.videogame_asset_rounded,
              title: s.realName,
              subtitle: s.folderName,
              isEnabled: !hiddenFolders.contains(s.folderName),
              isHideToggle: true,
              onToggle: () => provider.toggleSystemHidden(s.folderName),
            ),
          ),
    ];
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<SqliteConfigProvider>(
      builder: (context, provider, _) {
        final items = _buildItems(provider);

        _ensureKeys(items.length);

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SettingsTitle(
              title: AppLocale.systemsSettings.getString(context),
              subtitle: AppLocale.systemsSettingsSubtitle.getString(context),
            ),
            SizedBox(height: 12.r),
            Expanded(
              child: ListView.builder(
                controller: _scrollController,
                physics: const ClampingScrollPhysics(),
                itemCount: items.length,
                itemBuilder: (context, index) {
                  final item = items[index];
                  final isSelected =
                      widget.isContentFocused &&
                      widget.selectedContentIndex == index;

                  void onTap() {
                    SfxService().playNavSound();
                    selectItem(index, provider);
                  }

                  return SettingsCardRow(
                    key: _itemKeys[index],
                    icon: item.icon,
                    title: item.title,
                    subtitle: item.subtitle,
                    selected: isSelected,
                    disabled: item.isDisabled,
                    onTap: item.isDisabled ? null : onTap,
                    trailing: item.valueText != null
                        ? SettingValueChip(text: item.valueText!)
                        : CustomToggleSwitch(
                            value: item.isEnabled,
                            onChanged: (_) => onTap(),
                            disabled: item.isDisabled,
                          ),
                  );
                },
              ),
            ),
          ],
        );
      },
    );
  }
}

/// Metadata model for a standardized settings row.
class _SystemSettingRow {
  final IconData icon;
  final String title;
  final String subtitle;
  final bool isEnabled;
  final bool isHideToggle;
  final bool isDisabled;

  /// Current value of a cyclable row. When set, the row renders a value chip
  /// instead of a toggle and [onToggle] advances to the next value.
  final String? valueText;

  final VoidCallback onToggle;

  const _SystemSettingRow({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onToggle,
    this.isEnabled = false,
    this.isHideToggle = false,
    this.isDisabled = false,
    this.valueText,
  });
}
