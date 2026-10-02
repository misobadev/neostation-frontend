import 'package:flutter/material.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:neostation/l10n/app_locale.dart';
import 'package:neostation/models/config_model.dart';
import 'package:neostation/providers/sqlite_config_provider.dart';
import 'package:neostation/services/screenshot_service.dart';
import 'package:neostation/utils/adaptive_scroll.dart';
import 'package:provider/provider.dart';

import '../../../widgets/custom_toggle_switch.dart';
import 'settings_title.dart';
import 'widgets/setting_row.dart';
import 'widgets/setting_value_chip.dart';
import 'widgets/settings_section_header.dart';

/// Settings detail panel for secondary-display options. Only reachable while a
/// secondary display is active (the menu entry is hidden otherwise), so it
/// always renders its full set of controls.
///
/// Items (gamepad index order): 0 = fanart dim, 1 = screenshot access,
/// 2 = dim delay, 3 = dim darkness, 4 = dock enabled, 5 = dock slots.
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

  /// Snaps during rapid D-pad navigation, animates on a single move.
  final AdaptiveScroller _scroller = AdaptiveScroller();

  /// Inactivity-delay stops for the Now Playing dim, in seconds (0 = Never).
  static const _dimDelayCycle = [1, 3, 5, 0];

  /// Darkness stops for the Now Playing dim, as a percentage. 0% is omitted
  /// deliberately — "no dim" is expressed by setting the delay to Never.
  static const _dimLevelCycle = [25, 50, 75, 100];

  /// Whether the screenshot accessibility service is currently granted.
  bool _screenshotAccessEnabled = false;

  /// Left inset applied to option rows so they read as nested under their
  /// section header (mirrors how Directories' icon-cards sit indented below
  /// each subheader).
  double get _rowIndent => 16.r;

  @override
  void initState() {
    super.initState();
    for (var i = 0; i < 6; i++) {
      _itemKeys.add(GlobalKey());
    }
    WidgetsBinding.instance.addObserver(this);
    // Seed from the last-known value the provider already holds so the toggle
    // renders in its correct position on the first frame instead of flashing
    // off→on once the async check below resolves.
    _screenshotAccessEnabled =
        context
            .read<SqliteConfigProvider>()
            .secondaryDisplayState
            ?.value
            ?.screenshotAccessEnabled ??
        false;
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
  int getItemCount() => 6;

  /// Dispatches a gamepad-select to the focused item.
  void selectItem(int index) {
    final provider = context.read<SqliteConfigProvider>();
    if (index == 0) {
      _cycleFanartDim(provider);
    } else if (index == 1) {
      ScreenshotService.openAccessSettings();
    } else if (index == 2) {
      _cycleDimDelay(provider);
    } else if (index == 3) {
      // Darkness is meaningless when the panel never dims.
      if (provider.config.nowPlayingDimDelay > 0) {
        _cycleDimLevel(provider);
      }
    } else if (index == 4) {
      provider.updateDockEnabled(!provider.config.dockEnabled);
    } else if (index == 5) {
      // Slot count is meaningless when the dock is hidden.
      if (provider.config.dockEnabled) {
        _cycleDockSlotCount(provider);
      }
    }
  }

  /// Cycles the fanart dim 0→25→50→75→0 (%) and persists it.
  void _cycleFanartDim(SqliteConfigProvider provider) {
    const steps = [0, 25, 50, 75];
    final cur = provider.config.fanartDimLevel;
    final i = steps.indexOf(cur);
    final next = steps[(i < 0 ? 0 : (i + 1) % steps.length)];
    provider.updateFanartDimLevel(next);
  }

  /// Advances the visible dock slot count 0→1→…→max→0 and persists it.
  void _cycleDockSlotCount(SqliteConfigProvider provider) {
    final cur = provider.config.dockSlotCount;
    final next = cur >= ConfigModel.dockMaxSlotCount
        ? ConfigModel.dockMinSlotCount
        : cur + 1;
    provider.updateDockSlotCount(next);
  }

  /// Scrolls the item at [index] into view for gamepad navigation.
  void scrollToIndex(int index) {
    _scroller.ensureVisibleIndex(
      index,
      keys: _itemKeys,
      controller: _scrollController,
    );
  }

  /// Human label for a dim delay; 0 reads as "Never".
  String _dimDelayLabel(int seconds) => seconds <= 0
      ? AppLocale.nowPlayingDimNever.getString(context)
      : '${seconds}s';

  String _fanartDimLabel(int percent) => percent <= 0
      ? AppLocale.nowPlayingDimOff.getString(context)
      : '$percent%';

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
    // When disabled (e.g. delay is Never), grey the row out and ignore input.
    return Padding(
      padding: EdgeInsets.only(left: _rowIndent),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: enabled ? onTap : null,
        child: Opacity(
          opacity: enabled ? 1.0 : 0.4,
          child: SettingRow(
            key: _itemKeys[index],
            focused:
                widget.isContentFocused && widget.selectedContentIndex == index,
            title: title,
            subtitle: subtitle,
            trailing: SettingValueChip(text: valueText),
          ),
        ),
      ),
    );
  }

  /// A labelled row with a trailing on/off switch, for boolean settings.
  Widget _buildToggleRow({
    required int index,
    required String title,
    required String subtitle,
    required bool value,
    required ValueChanged<bool> onChanged,
  }) {
    return Padding(
      padding: EdgeInsets.only(left: _rowIndent),
      child: SettingRow(
        key: _itemKeys[index],
        focused:
            widget.isContentFocused && widget.selectedContentIndex == index,
        title: title,
        subtitle: subtitle,
        trailing: CustomToggleSwitch(
          value: value,
          onChanged: onChanged,
          activeColor: Theme.of(context).colorScheme.primary,
        ),
      ),
    );
  }

  /// The switch reflects the granted state; toggling it (the OS service can't be
  /// flipped programmatically) opens Android's accessibility settings.
  Widget _buildScreenshotAccessRow() {
    const index = 1;
    return Padding(
      padding: EdgeInsets.only(left: _rowIndent),
      child: SettingRow(
        key: _itemKeys[index],
        focused:
            widget.isContentFocused && widget.selectedContentIndex == index,
        title: AppLocale.screenshotAccess.getString(context),
        subtitle: AppLocale.screenshotAccessSubtitle.getString(context),
        trailing: CustomToggleSwitch(
          value: _screenshotAccessEnabled,
          onChanged: (_) => ScreenshotService.openAccessSettings(),
          activeColor: Theme.of(context).colorScheme.primary,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<SqliteConfigProvider>();
    final config = provider.config;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Pinned header — stays put while the settings list scrolls beneath it.
        SettingsTitle(title: AppLocale.secondaryDisplay.getString(context)),
        SizedBox(height: 12.r),
        Expanded(
          child: SingleChildScrollView(
            controller: _scrollController,
            padding: EdgeInsets.only(bottom: 24.r),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SettingsSectionHeader(
                  label: AppLocale.general.getString(context),
                ),
                _buildValueRow(
                  index: 0,
                  title: AppLocale.nowPlayingFanartDim.getString(context),
                  subtitle: AppLocale.nowPlayingFanartDimSubtitle.getString(
                    context,
                  ),
                  valueText: _fanartDimLabel(config.fanartDimLevel),
                  onTap: () => _cycleFanartDim(provider),
                ),
                SizedBox(height: 12.r),
                _buildScreenshotAccessRow(),
                SizedBox(height: 24.r),
                SettingsSectionHeader(
                  label: AppLocale.secondarySectionNowPlaying.getString(
                    context,
                  ),
                ),
                _buildValueRow(
                  index: 2,
                  title: AppLocale.nowPlayingDimAfter.getString(context),
                  subtitle: AppLocale.nowPlayingDimAfterSubtitle.getString(
                    context,
                  ),
                  valueText: _dimDelayLabel(config.nowPlayingDimDelay),
                  onTap: () => _cycleDimDelay(provider),
                ),
                SizedBox(height: 12.r),
                _buildValueRow(
                  index: 3,
                  title: AppLocale.nowPlayingDimDarkness.getString(context),
                  subtitle: AppLocale.nowPlayingDimDarknessSubtitle.getString(
                    context,
                  ),
                  valueText: '${config.nowPlayingDimLevel}%',
                  enabled: config.nowPlayingDimDelay > 0,
                  onTap: () => _cycleDimLevel(provider),
                ),
                SizedBox(height: 24.r),
                SettingsSectionHeader(
                  label: AppLocale.secondarySectionDock.getString(context),
                ),
                _buildToggleRow(
                  index: 4,
                  title: AppLocale.nowPlayingDockEnabled.getString(context),
                  subtitle: AppLocale.nowPlayingDockEnabledSubtitle.getString(
                    context,
                  ),
                  value: config.dockEnabled,
                  onChanged: (v) => provider.updateDockEnabled(v),
                ),
                SizedBox(height: 12.r),
                _buildValueRow(
                  index: 5,
                  title: AppLocale.nowPlayingDockSlots.getString(context),
                  subtitle: AppLocale.nowPlayingDockSlotsSubtitle.getString(
                    context,
                  ),
                  valueText: '${config.dockSlotCount}',
                  enabled: config.dockEnabled,
                  onTap: () => _cycleDockSlotCount(provider),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
