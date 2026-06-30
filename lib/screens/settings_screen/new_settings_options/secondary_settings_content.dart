import 'package:flutter/material.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:neostation/l10n/app_locale.dart';
import 'package:neostation/providers/sqlite_config_provider.dart';
import 'package:neostation/services/screenshot_service.dart';
import 'package:provider/provider.dart';

import '../../../widgets/custom_toggle_switch.dart';

/// Settings detail panel for secondary-display options. Only reachable while a
/// secondary display is active (the menu entry is hidden otherwise), so it
/// always renders its full set of controls.
///
/// Items (gamepad index order): 0 = dim delay, 1 = dim darkness,
/// 2 = screenshot access.
class SecondarySettingsContent extends StatefulWidget {
  final bool isContentFocused;
  final int selectedContentIndex;

  const SecondarySettingsContent({
    super.key,
    required this.isContentFocused,
    required this.selectedContentIndex,
  });

  @override
  State<SecondarySettingsContent> createState() =>
      SecondarySettingsContentState();
}

class SecondarySettingsContentState extends State<SecondarySettingsContent>
    with WidgetsBindingObserver {
  final ScrollController _scrollController = ScrollController();
  final List<GlobalKey> _itemKeys = [];

  /// Inactivity-delay stops for the Now Playing dim, in seconds (0 = Never).
  static const _dimDelayCycle = [1, 3, 5, 0];

  /// Darkness stops for the Now Playing dim, as a percentage. 0% is omitted
  /// deliberately — "no dim" is expressed by setting the delay to Never.
  static const _dimLevelCycle = [25, 50, 75, 100];

  /// Whether the screenshot accessibility service is currently granted.
  bool _screenshotAccessEnabled = false;

  @override
  void initState() {
    super.initState();
    for (var i = 0; i < 3; i++) {
      _itemKeys.add(GlobalKey());
    }
    WidgetsBinding.instance.addObserver(this);
    _refreshScreenshotAccess();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _scrollController.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    // Re-check after returning from the accessibility settings screen.
    if (state == AppLifecycleState.resumed) {
      _refreshScreenshotAccess();
    }
  }

  /// Reloads the screenshot-access status into the UI.
  Future<void> _refreshScreenshotAccess() async {
    final enabled = await ScreenshotService.isAccessEnabled();
    if (!mounted) return;
    // Mirror the state to the secondary display so its screenshot button
    // shows/hides to match.
    context.read<SqliteConfigProvider>().pushScreenshotAccess(enabled);
    if (enabled != _screenshotAccessEnabled) {
      setState(() => _screenshotAccessEnabled = enabled);
    }
  }

  /// Number of navigable items in this panel.
  int getItemCount() => 3;

  /// Dispatches a gamepad-select to the focused item.
  void selectItem(int index) {
    final provider = context.read<SqliteConfigProvider>();
    if (index == 0) {
      _cycleDimDelay(provider);
    } else if (index == 1) {
      // Darkness is meaningless when the panel never dims.
      if (provider.config.nowPlayingDimDelay > 0) {
        _cycleDimLevel(provider);
      }
    } else if (index == 2) {
      ScreenshotService.openAccessSettings();
    }
  }

  /// Scrolls the item at [index] into view for gamepad navigation.
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

  /// Human label for a dim delay; 0 reads as "Never".
  String _dimDelayLabel(int seconds) => seconds <= 0
      ? AppLocale.nowPlayingDimNever.getString(context)
      : '${seconds}s';

  /// Advances the dim delay to the next stop and persists it.
  void _cycleDimDelay(SqliteConfigProvider provider) {
    final cur = provider.config.nowPlayingDimDelay;
    final i = _dimDelayCycle.indexOf(cur);
    final next = _dimDelayCycle[(i < 0 ? 0 : (i + 1) % _dimDelayCycle.length)];
    provider.updateNowPlayingDimDelay(next);
  }

  /// Advances the dim darkness to the next stop and persists it. If the current
  /// value isn't on a stop, snaps up to the nearest stop first.
  void _cycleDimLevel(SqliteConfigProvider provider) {
    final cur = provider.config.nowPlayingDimLevel;
    var i = _dimLevelCycle.indexWhere((v) => v >= cur);
    if (i < 0) i = _dimLevelCycle.length - 1;
    if (_dimLevelCycle[i] != cur) {
      provider.updateNowPlayingDimLevel(_dimLevelCycle[i]);
      return;
    }
    provider.updateNowPlayingDimLevel(
      _dimLevelCycle[(i + 1) % _dimLevelCycle.length],
    );
  }

  /// Renders a settings row whose right side shows a cyclable value (tap or
  /// gamepad-select to advance).
  Widget _buildValueRow({
    required int index,
    required String title,
    required String subtitle,
    required String valueText,
    required VoidCallback onTap,
    bool enabled = true,
  }) {
    final theme = Theme.of(context);
    final focused =
        widget.isContentFocused && widget.selectedContentIndex == index;
    final row = Container(
      key: _itemKeys[index],
      padding: EdgeInsets.only(left: 12.r, right: 12.r, top: 6.r, bottom: 6.r),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(8.r),
        border: Border.all(
          color: focused ? theme.colorScheme.primary : Colors.transparent,
          width: 2,
        ),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: theme.textTheme.bodyLarge?.copyWith(
                    fontSize: 12.r,
                    fontWeight: FontWeight.w500,
                    color: focused
                        ? theme.colorScheme.primary
                        : theme.colorScheme.onSurface,
                  ),
                ),
                SizedBox(height: 4.r),
                Text(
                  subtitle,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontSize: 9.r,
                    color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
                  ),
                ),
              ],
            ),
          ),
          SizedBox(width: 12.r),
          Container(
            padding: EdgeInsets.symmetric(horizontal: 12.r, vertical: 6.r),
            decoration: BoxDecoration(
              color: theme.colorScheme.primary.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(6.r),
            ),
            child: Text(
              valueText,
              style: theme.textTheme.bodyLarge?.copyWith(
                fontSize: 12.r,
                fontWeight: FontWeight.w600,
                color: theme.colorScheme.primary,
              ),
            ),
          ),
        ],
      ),
    );
    // When disabled (e.g. delay is Never), grey the row out and ignore input.
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: enabled ? onTap : null,
      child: Opacity(opacity: enabled ? 1.0 : 0.4, child: row),
    );
  }

  /// Toggle row for screenshot access, styled like the All Files Access row.
  /// The switch reflects the granted state; toggling it (the OS service can't be
  /// flipped programmatically) opens Android's accessibility settings.
  Widget _buildScreenshotAccessRow() {
    const index = 2;
    final theme = Theme.of(context);
    final focused =
        widget.isContentFocused && widget.selectedContentIndex == index;
    return Container(
      key: _itemKeys[index],
      padding: EdgeInsets.only(left: 12.r, right: 12.r, top: 6.r, bottom: 6.r),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(8.r),
        border: Border.all(
          color: focused ? theme.colorScheme.primary : Colors.transparent,
          width: 2,
        ),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  AppLocale.screenshotAccess.getString(context),
                  style: theme.textTheme.bodyLarge?.copyWith(
                    fontSize: 12.r,
                    fontWeight: FontWeight.w500,
                    color: focused
                        ? theme.colorScheme.primary
                        : theme.colorScheme.onSurface,
                  ),
                ),
                SizedBox(height: 4.r),
                Text(
                  AppLocale.screenshotAccessSubtitle.getString(context),
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontSize: 9.r,
                    color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
                  ),
                ),
              ],
            ),
          ),
          CustomToggleSwitch(
            value: _screenshotAccessEnabled,
            onChanged: (_) => ScreenshotService.openAccessSettings(),
            activeColor: theme.colorScheme.primary,
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<SqliteConfigProvider>();
    final config = provider.config;

    return SingleChildScrollView(
      controller: _scrollController,
      padding: EdgeInsets.symmetric(horizontal: 24.r, vertical: 24.r),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildValueRow(
            index: 0,
            title: AppLocale.nowPlayingDimAfter.getString(context),
            subtitle: AppLocale.nowPlayingDimAfterSubtitle.getString(context),
            valueText: _dimDelayLabel(config.nowPlayingDimDelay),
            onTap: () => _cycleDimDelay(provider),
          ),
          SizedBox(height: 12.r),
          _buildValueRow(
            index: 1,
            title: AppLocale.nowPlayingDimDarkness.getString(context),
            subtitle: AppLocale.nowPlayingDimDarknessSubtitle.getString(context),
            valueText: '${config.nowPlayingDimLevel}%',
            enabled: config.nowPlayingDimDelay > 0,
            onTap: () => _cycleDimLevel(provider),
          ),
          SizedBox(height: 12.r),
          _buildScreenshotAccessRow(),
        ],
      ),
    );
  }
}
