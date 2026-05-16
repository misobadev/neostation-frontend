import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:neostation/l10n/app_locale.dart';
import 'package:neostation/services/sfx_service.dart';
import 'package:provider/provider.dart';
import '../../../providers/sqlite_config_provider.dart';
import '../../../widgets/custom_toggle_switch.dart';
import '../../../constants/system_folder_names.dart';
import 'settings_title.dart';

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
  static const int _fixedSettingsRowsCount = 2; // Recent + Favorites

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
    if (index >= 0 && index < _itemKeys.length) {
      final ctx = _itemKeys[index].currentContext;
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

  /// Calculates the total number of navigable settings (Global Card + Detected Systems).
  int getItemCount(SqliteConfigProvider provider) {
    return _fixedSettingsRowsCount + provider.detectedSystems.length;
  }

  /// Executes the toggle action for the specified system or feature.
  void selectItem(int index, SqliteConfigProvider provider) {
    SfxService().playNavSound();
    final items = _buildItems(provider);
    if (index >= 0 && index < items.length) {
      items[index].onToggle();
    }
  }

  List<_SettingsRow> _buildItems(SqliteConfigProvider provider) {
    final hiddenFolders = provider.hiddenSystemFolders;
    final systems = provider.detectedSystems;

    return <_SettingsRow>[
      _SettingsRow(
        icon: Symbols.access_time_rounded,
        title: AppLocale.hideRecentCard.getString(context),
        subtitle: AppLocale.hideRecentCardSubtitle.getString(context),
        isEnabled: !provider.config.hideRecentCard,
        onToggle: () =>
            provider.updateHideRecentCard(!provider.config.hideRecentCard),
      ),
      _SettingsRow(
        icon: Symbols.favorite_rounded,
        title: AppLocale.favorite.getString(context),
        subtitle: SystemFolderNames.favorites,
        isEnabled: !hiddenFolders.contains(SystemFolderNames.favorites),
        isHideToggle: true,
        onToggle: () => provider.toggleSystemHidden(SystemFolderNames.favorites),
      ),
      ...systems.map(
        (s) => _SettingsRow(
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

                  return _buildRow(
                    context,
                    item,
                    isSelected,
                    _itemKeys[index],
                    () {
                      SfxService().playNavSound();
                      selectItem(index, provider);
                    },
                  );
                },
              ),
            ),
          ],
        );
      },
    );
  }

  /// Constructs a standardized configuration row with icon, metadata, and state toggle.
  Widget _buildRow(
    BuildContext context,
    _SettingsRow item,
    bool isSelected,
    GlobalKey rowKey,
    VoidCallback onTap,
  ) {
    final theme = Theme.of(context);

    final Color borderColor = isSelected
        ? theme.colorScheme.primary
        : theme.colorScheme.outline.withValues(alpha: 0);

    return Container(
      key: rowKey,
      decoration: BoxDecoration(
        color: theme.cardColor.withValues(alpha: 0.25),
        borderRadius: BorderRadius.circular(12.r),
        border: Border.all(color: borderColor, width: isSelected ? 2.r : 1.r),
      ),
      margin: EdgeInsets.only(bottom: 8.r),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12.r),
        canRequestFocus: false,
        focusColor: Colors.transparent,
        hoverColor: Colors.transparent,
        highlightColor: Colors.transparent,
        splashColor: Colors.transparent,
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: 12.r, vertical: 8.r),
          child: Row(
            children: [
              Icon(
                item.icon,
                color: isSelected
                    ? theme.colorScheme.primary
                    : theme.colorScheme.onSurface,
                size: 20.r,
              ),
              SizedBox(width: 12.r),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      item.title,
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.bold,
                        fontSize: 12.r,
                        color: isSelected
                            ? theme.colorScheme.primary
                            : theme.colorScheme.onSurface,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    if (item.subtitle.isNotEmpty) ...[
                      SizedBox(height: 2.r),
                      Text(
                        item.subtitle,
                        style: theme.textTheme.bodySmall?.copyWith(
                          fontSize: 9.r,
                          color: theme.colorScheme.onSurface.withValues(
                            alpha: 0.6,
                          ),
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ],
                ),
              ),
              CustomToggleSwitch(
                value: item.isHideToggle ? !item.isEnabled : item.isEnabled,
                onChanged: (_) => onTap(),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Metadata model for a standardized settings row.
class _SettingsRow {
  final IconData icon;
  final String title;
  final String subtitle;
  final bool isEnabled;
  final bool isHideToggle;
  final VoidCallback onToggle;

  const _SettingsRow({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.isEnabled,
    required this.onToggle,
    this.isHideToggle = false,
  });
}
