import 'package:flutter/material.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:neostation/l10n/app_locale.dart';
import 'package:neostation/providers/sqlite_config_provider.dart';
import 'package:neostation/services/gamepad/gamepad_navigation_manager.dart';
import 'package:neostation/services/sfx_service.dart';
import 'package:neostation/themes/corner_radii.dart';
import 'package:neostation/utils/gamepad_nav.dart';
import 'package:neostation/widgets/neo_glass.dart';
import 'package:provider/provider.dart';

const List<String> _sizes = ['S', 'M', 'L', 'XL'];

/// Opens the Android apps card-size menu from Start.
Future<void> showAndroidOptionsDialog(BuildContext context) {
  return showGeneralDialog<void>(
    context: context,
    barrierDismissible: true,
    barrierLabel: AppLocale.hintOptions.getString(context),
    barrierColor: Colors.black.withValues(alpha: 0.35),
    transitionDuration: const Duration(milliseconds: 220),
    pageBuilder: (context, animation, secondaryAnimation) =>
        const _AndroidOptionsDialog(),
    transitionBuilder: (context, animation, secondaryAnimation, child) {
      final curved = CurvedAnimation(
        parent: animation,
        curve: Curves.easeOutCubic,
        reverseCurve: Curves.easeInCubic,
      );
      return FadeTransition(
        opacity: curved,
        child: SlideTransition(
          position: Tween<Offset>(
            begin: const Offset(-1, 0),
            end: Offset.zero,
          ).animate(curved),
          child: child,
        ),
      );
    },
  );
}

class _AndroidOptionsDialog extends StatefulWidget {
  const _AndroidOptionsDialog();

  @override
  State<_AndroidOptionsDialog> createState() => _AndroidOptionsDialogState();
}

class _AndroidOptionsDialogState extends State<_AndroidOptionsDialog> {
  late final GamepadNavigation _gamepadNav;
  bool _isClosing = false;

  @override
  void initState() {
    super.initState();
    _gamepadNav = GamepadNavigation(
      onNavigateLeft: () => _move(-1),
      onNavigateRight: () => _move(1),
      onSelectItem: () => SfxService().playNavSound(),
      onBack: _close,
      onSettings: _close,
    );

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _gamepadNav.initialize();
      GamepadNavigationManager.pushLayer(
        'android_options_dialog',
        modal: true,
        onActivate: () => _gamepadNav.activate(),
        onDeactivate: () => _gamepadNav.deactivate(),
      );
    });
  }

  @override
  void dispose() {
    GamepadNavigationManager.popLayer('android_options_dialog');
    _gamepadNav.dispose();
    super.dispose();
  }

  void _close() {
    if (_isClosing) return;
    _isClosing = true;
    Navigator.of(context).pop();
  }

  void _setSize(int index) {
    SfxService().playNavSound();
    context.read<SqliteConfigProvider>().updateAndroidGridColumns(
      _sizes[index],
    );
  }

  void _move(int delta) {
    final provider = context.read<SqliteConfigProvider>();
    final current = _sizes.indexOf(provider.config.androidGridColumns);
    final index = ((current < 0 ? 1 : current) + delta).clamp(
      0,
      _sizes.length - 1,
    );
    if (index == current) return;
    _setSize(index);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final cornerRadii = theme.extension<CornerRadii>() ?? CornerRadii.m();
    final radii = cornerRadii.radiusExternal;
    final screen = MediaQuery.sizeOf(context);
    final panelWidth = screen.width * 0.34;
    final maxPanelHeight = screen.height * 0.82;
    final config = context.watch<SqliteConfigProvider>().config;
    final selectedIndex = _sizes.indexOf(config.androidGridColumns);

    return SafeArea(
      child: Align(
        alignment: Alignment.centerLeft,
        child: Padding(
          padding: EdgeInsets.only(left: 16.r, top: 12.r, bottom: 12.r),
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth: panelWidth,
              maxHeight: maxPanelHeight,
            ),
            child: SizedBox(
              width: panelWidth,
              child: Material(
                color: Colors.transparent,
                child: NeoGlassRim(
                  cornerRadius: cornerRadii.radiusExternalRadius,
                  child: Container(
                    decoration: BoxDecoration(
                      color: scheme.surface,
                      borderRadius: radii,
                      border: Border.all(
                        color: scheme.outline.withValues(alpha: 0.5),
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: scheme.shadow.withValues(alpha: 0.5),
                          blurRadius: 24.r,
                          offset: Offset(8.r, 0),
                        ),
                      ],
                    ),
                    clipBehavior: Clip.antiAlias,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        _buildHeader(context),
                        _divider(context),
                        Flexible(
                          fit: FlexFit.loose,
                          child: Padding(
                            padding: EdgeInsets.fromLTRB(
                              12.r,
                              10.r,
                              12.r,
                              12.r,
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                _buildGroupLabel(
                                  context,
                                  AppLocale.cardSizeGroup.getString(context),
                                ),
                                SizedBox(height: 4.r),
                                _buildCardSizeRow(
                                  context,
                                  selectedIndex < 0 ? 1 : selectedIndex,
                                ),
                              ],
                            ),
                          ),
                        ),
                        _divider(context),
                        _buildFooter(context),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildHeader(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: EdgeInsets.fromLTRB(8.r, 2.r, 8.r, 2.r),
      child: Row(
        children: [
          SizedBox(width: 26.r),
          Expanded(
            child: Center(
              child: Text(
                AppLocale.hintOptions.getString(context),
                style: TextStyle(
                  fontSize: 13.r,
                  fontWeight: FontWeight.w800,
                  color: theme.colorScheme.onSurface,
                ),
              ),
            ),
          ),
          SizedBox(
            width: 26.r,
            child: InkWell(
              onTap: _close,
              borderRadius: BorderRadius.circular(6.r),
              child: Padding(
                padding: EdgeInsets.all(4.r),
                child: Icon(
                  Symbols.close_rounded,
                  size: 16.r,
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _divider(BuildContext context) => Divider(
    height: 1,
    thickness: 1,
    color: Theme.of(context).colorScheme.outline.withValues(alpha: 0.25),
  );

  Widget _buildGroupLabel(BuildContext context, String label) {
    final theme = Theme.of(context);
    return Padding(
      padding: EdgeInsets.fromLTRB(4.r, 10.r, 4.r, 4.r),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 9.r,
          fontWeight: FontWeight.w700,
          letterSpacing: 1.r,
          color: theme.colorScheme.onSurface.withValues(alpha: 0.38),
        ),
      ),
    );
  }

  Widget _buildCardSizeRow(BuildContext context, int selected) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final cornerRadii = theme.extension<CornerRadii>() ?? CornerRadii.m();
    final radius = cornerRadii.radiusInternal;

    return NeoGlassRim(
      cornerRadius: cornerRadii.radiusInternalRadius,
      child: Material(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.16),
        borderRadius: radius,
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: 10.r, vertical: 5.r),
          child: Row(
            children: [
              Icon(
                Symbols.crop_free_rounded,
                size: 17.r,
                color: scheme.onSurface.withValues(alpha: 0.6),
              ),
              SizedBox(width: 9.r),
              Expanded(
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    for (var index = 0; index < _sizes.length; index++)
                      InkWell(
                        onTap: () => _setSize(index),
                        focusColor: Colors.transparent,
                        hoverColor: Colors.transparent,
                        splashColor: Colors.transparent,
                        highlightColor: Colors.transparent,
                        borderRadius: radius,
                        child: Container(
                          padding: EdgeInsets.symmetric(
                            horizontal: 9.r,
                            vertical: 3.r,
                          ),
                          decoration: BoxDecoration(
                            color: index == selected
                                ? scheme.primary
                                : Colors.transparent,
                            borderRadius: radius,
                          ),
                          child: Text(
                            _sizes[index],
                            style: TextStyle(
                              fontSize: 10.r,
                              fontWeight: FontWeight.w700,
                              color: index == selected
                                  ? scheme.onPrimary
                                  : scheme.onSurface,
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildFooter(BuildContext context) {
    return Padding(
      padding: EdgeInsets.symmetric(vertical: 8.r),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          _buildHint(
            context,
            'assets/images/gamepad/Xbox_A_button.png',
            AppLocale.hintSelect.getString(context),
          ),
          SizedBox(width: 18.r),
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
