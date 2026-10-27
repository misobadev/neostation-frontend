part of '../system_emulator_settings_dialog.dart';

/// Dialog chrome for the settings dialog.
///
/// The frame builders — loading / error states, header, tab strip, and footer —
/// moved out of the monolith. Behaviour is unchanged. State lives on the host
/// [State] (extensions can't declare fields); `setState` calls route through the
/// host [rebuild] bridge (`State.setState` is `@protected`).
extension _Chrome on _SystemEmulatorSettingsDialogState {
  Widget _buildLoadingState() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          CircularProgressIndicator(
            valueColor: AlwaysStoppedAnimation<Color>(
              Theme.of(context).colorScheme.secondary,
            ),
          ),
          SizedBox(height: 12.r),
          Text(
            AppLocale.loadingEmulators.getString(context),
            style: TextStyle(
              fontSize: 12.r,
              color: Theme.of(context).colorScheme.onSurface,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildErrorState() {
    return Center(
      child: Padding(
        padding: EdgeInsets.all(24.r),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Symbols.error_outline_rounded,
              size: 48.r,
              color: Theme.of(context).colorScheme.error,
            ),
            SizedBox(height: 12.r),
            Text(
              _errorMessage ?? AppLocale.anErrorOccurred.getString(context),
              style: TextStyle(
                fontSize: 12.r,
                color: Theme.of(context).colorScheme.onSurface,
              ),
              textAlign: TextAlign.center,
            ),
            SizedBox(height: 18.r),
            ElevatedButton(
              onPressed: _loadCores,
              style:
                  ElevatedButton.styleFrom(
                    backgroundColor: Theme.of(context).colorScheme.secondary,
                    padding: EdgeInsets.symmetric(
                      horizontal: 20.r,
                      vertical: 8.r,
                    ),
                  ).copyWith(
                    overlayColor: WidgetStateProperty.all(Colors.transparent),
                  ),
              child: Text(AppLocale.retry.getString(context)),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader() {
    return Container(
      padding: EdgeInsets.symmetric(horizontal: 12.r, vertical: 8.r),
      decoration: BoxDecoration(color: Colors.transparent),
      child: Row(
        children: [
          // Title
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  AppLocale.systemSettings.getString(context),
                  style: TextStyle(
                    fontSize: 12.r,
                    fontWeight: FontWeight.bold,
                    color: Theme.of(context).colorScheme.onSurface,
                  ),
                ),
                SizedBox(height: 1.r),
                Text(
                  widget.system.realName,
                  style: TextStyle(
                    fontSize: 10.r,
                    fontWeight: FontWeight.w500,
                    color: Theme.of(
                      context,
                    ).colorScheme.onSurface.withValues(alpha: 0.6),
                  ),
                ),
              ],
            ),
          ),
          // Close button
          Material(
            color: Colors.transparent,
            child: InkWell(
              canRequestFocus: false,
              focusColor: Colors.transparent,
              hoverColor: Colors.transparent,
              highlightColor: Colors.transparent,
              splashColor: Colors.transparent,
              borderRadius: BorderRadius.circular(8.r),
              focusNode: _headerCloseButtonFocusNode,
              onTap: () {
                SfxService().playBackSound();
                Navigator.of(context).pop();
              },
              child: Container(
                padding: EdgeInsets.all(6.r),
                child: Icon(
                  Symbols.close_rounded,
                  size: 18.r,
                  color: Theme.of(
                    context,
                  ).colorScheme.onSurface.withValues(alpha: 0.5),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTabsHeader() {
    final theme = Theme.of(context);
    return Container(
      padding: EdgeInsets.symmetric(horizontal: 12.r),
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(
            color: theme.colorScheme.outline.withValues(alpha: 0.1),
          ),
        ),
      ),
      child: Row(
        children: [
          // LB Icon
          Padding(
            padding: EdgeInsets.only(right: 8.r),
            child: Image.asset(
              'assets/images/gamepad/Xbox_LB_bumper.png',
              height: 24.r,
              color: theme.colorScheme.onSurface.withValues(alpha: 0.5),
              colorBlendMode: BlendMode.srcIn,
            ),
          ),
          _buildTabItem(0, AppLocale.general.getString(context)),
          if (_availableTabs.contains(1)) ...[
            SizedBox(width: 16.r),
            _buildTabItem(1, AppLocale.emulators.getString(context)),
          ],
          SizedBox(width: 16.r),
          _buildTabItem(2, AppLocale.appearance.getString(context)),
          if (_availableTabs.contains(3)) ...[
            SizedBox(width: 16.r),
            _buildTabItem(3, AppLocale.hiddenGames.getString(context)),
          ],
          const Spacer(),
          // RB Icon
          Padding(
            padding: EdgeInsets.only(left: 8.r),
            child: Image.asset(
              'assets/images/gamepad/Xbox_RB_bumper.png',
              height: 24.r,
              color: theme.colorScheme.onSurface.withValues(alpha: 0.5),
              colorBlendMode: BlendMode.srcIn,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTabItem(int index, String label) {
    final bool isSelected = _currentTab == index;
    return InkWell(
      canRequestFocus: false,
      focusColor: Colors.transparent,
      hoverColor: Colors.transparent,
      highlightColor: Colors.transparent,
      splashColor: Colors.transparent,
      onTap: () {
        SfxService().playNavSound();
        rebuild(() => _currentTab = index);
      },
      child: Container(
        padding: EdgeInsets.symmetric(vertical: 8.r),
        decoration: BoxDecoration(
          border: Border(
            bottom: BorderSide(
              color: isSelected
                  ? Theme.of(context).colorScheme.secondary
                  : Colors.transparent,
              width: 2.r,
            ),
          ),
        ),
        child: Text(
          label.toUpperCase(),
          style: TextStyle(
            fontSize: 10.r,
            fontWeight: isSelected ? FontWeight.bold : FontWeight.w500,
            color: isSelected
                ? Theme.of(context).colorScheme.secondary
                : Theme.of(
                    context,
                  ).colorScheme.onSurface.withValues(alpha: 0.5),
            letterSpacing: 0.5.r,
          ),
        ),
      ),
    );
  }

  Widget _buildFooter() {
    final theme = Theme.of(context);
    final radii = theme.extension<CornerRadii>() ?? CornerRadii.m();
    return Container(
      padding: EdgeInsets.symmetric(vertical: 8.r, horizontal: 12.r),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(
          alpha: 0.05,
        ),
        borderRadius: BorderRadius.only(
          bottomLeft: radii.radiusExternal.bottomLeft,
          bottomRight: radii.radiusExternal.bottomRight,
        ),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          _buildHint(
            context,
            'assets/images/gamepad/Xbox_D-pad_ALL.png',
            AppLocale.hintNavigate.getString(context),
          ),
          SizedBox(width: 18.r),
          _buildHint(
            context,
            'assets/images/gamepad/Xbox_B_button.png',
            AppLocale.close.getString(context),
          ),
        ],
      ),
    );
  }

  Widget _buildHint(BuildContext context, String asset, String label) {
    final theme = Theme.of(context);
    final color = theme.colorScheme.onSurface.withValues(alpha: 0.6);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        ColorFiltered(
          colorFilter: ColorFilter.mode(color, BlendMode.srcIn),
          child: Image.asset(asset, width: 15.r, height: 15.r),
        ),
        SizedBox(width: 5.r),
        Text(
          label,
          style: TextStyle(
            fontSize: 9.r,
            fontWeight: FontWeight.w600,
            color: color,
          ),
        ),
      ],
    );
  }
}
