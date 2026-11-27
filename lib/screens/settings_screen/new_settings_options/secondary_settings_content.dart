import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:neostation/l10n/app_locale.dart';
import 'package:neostation/models/config_model.dart';
import 'package:neostation/providers/sqlite_config_provider.dart';
import 'package:neostation/services/launch_display_service.dart';
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
/// Items (gamepad index order): 0 = fanart dim, 1 = hide system logo,
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

class SecondarySettingsContentState extends State<SecondarySettingsContent> {
  final ScrollController _scrollController = ScrollController();
  final List<GlobalKey> _itemKeys = [];

  /// Snaps during rapid D-pad navigation, animates on a single move.
  final AdaptiveScroller _scroller = AdaptiveScroller();

  /// Inactivity-delay stops for the Now Playing dim, in seconds (0 = Never).
  static const _dimDelayCycle = [1, 3, 5, 0];

  /// Darkness stops for the Now Playing dim, as a percentage. 0% is omitted
  /// deliberately — "no dim" is expressed by setting the delay to Never.
  static const _dimLevelCycle = [25, 50, 75, 100];

  /// Left inset applied to option rows so they read as nested under their
  /// section header (mirrors how Directories' icon-cards sit indented below
  /// each subheader).
  double get _rowIndent => 16.r;

  /// Whether the "Swap screens" row applies: Android 10+ with a second
  /// display. It is the first row, so every other row shifts by one.
  bool _canSwapScreens = false;
  int get _offset => _canSwapScreens ? 1 : 0;

  @override
  void initState() {
    super.initState();
    // One spare key for the swap row, which appears once the check returns.
    for (var i = 0; i < _baseItemCount + 1; i++) {
      _itemKeys.add(GlobalKey());
    }
    _checkScreenSwap();
  }

  Future<void> _checkScreenSwap() async {
    if (!Platform.isAndroid) return;
    final provider = context.read<SqliteConfigProvider>();
    final canSwap =
        await LaunchDisplayService.hasSecondaryDisplay() &&
        await provider.isScreenSwapSupported();
    if (mounted && canSwap != _canSwapScreens) {
      setState(() => _canSwapScreens = canSwap);
    }
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  /// Number of navigable items in this panel.
  int getItemCount() => _baseItemCount + _offset;

  static const _baseItemCount = 6;

  /// Dispatches a gamepad-select to the focused item.
  void selectItem(int index) {
    final provider = context.read<SqliteConfigProvider>();
    if (_canSwapScreens && index == 0) {
      provider.updateSwapScreens(!provider.config.swapScreens);
      return;
    }
    index -= _offset;
    if (index == 0) {
      _cycleFanartDim(provider);
    } else if (index == 1) {
      provider.updateSecondaryHideSystemLogo(
        !provider.config.secondaryHideSystemLogo,
      );
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
                if (_canSwapScreens) ...[
                  _buildToggleRow(
                    index: 0,
                    title: AppLocale.swapScreens.getString(context),
                    subtitle: AppLocale.swapScreensSub.getString(context),
                    value: config.swapScreens,
                    // While the bottom screen is hidden the choice is kept
                    // and applied when it is shown again.
                    onChanged: provider.updateSwapScreens,
                  ),
                  SizedBox(height: 12.r),
                ],
                _buildValueRow(
                  index: 0 + _offset,
                  title: AppLocale.nowPlayingFanartDim.getString(context),
                  subtitle: AppLocale.nowPlayingFanartDimSubtitle.getString(
                    context,
                  ),
                  valueText: _fanartDimLabel(config.fanartDimLevel),
                  onTap: () => _cycleFanartDim(provider),
                ),
                SizedBox(height: 12.r),
                _buildToggleRow(
                  index: 1 + _offset,
                  title: AppLocale.secondaryHideSystemLogo.getString(context),
                  subtitle: AppLocale.secondaryHideSystemLogoSubtitle.getString(
                    context,
                  ),
                  value: config.secondaryHideSystemLogo,
                  onChanged: (v) => provider.updateSecondaryHideSystemLogo(v),
                ),
                SizedBox(height: 24.r),
                SettingsSectionHeader(
                  label: AppLocale.secondarySectionNowPlaying.getString(
                    context,
                  ),
                ),
                _buildValueRow(
                  index: 2 + _offset,
                  title: AppLocale.nowPlayingDimAfter.getString(context),
                  subtitle: AppLocale.nowPlayingDimAfterSubtitle.getString(
                    context,
                  ),
                  valueText: _dimDelayLabel(config.nowPlayingDimDelay),
                  onTap: () => _cycleDimDelay(provider),
                ),
                SizedBox(height: 12.r),
                _buildValueRow(
                  index: 3 + _offset,
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
                  index: 4 + _offset,
                  title: AppLocale.nowPlayingDockEnabled.getString(context),
                  subtitle: AppLocale.nowPlayingDockEnabledSubtitle.getString(
                    context,
                  ),
                  value: config.dockEnabled,
                  onChanged: (v) => provider.updateDockEnabled(v),
                ),
                SizedBox(height: 12.r),
                _buildValueRow(
                  index: 5 + _offset,
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
