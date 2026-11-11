import 'package:flutter/material.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:neostation/l10n/app_locale.dart';
import 'package:neostation/models/database_game_model.dart';
import 'package:neostation/models/game_model.dart';
import 'package:neostation/models/system_model.dart';
import 'package:neostation/providers/sqlite_config_provider.dart';
import 'package:neostation/repositories/game_repository.dart';
import 'package:neostation/services/gamepad/gamepad_navigation_manager.dart';
import 'package:neostation/services/logger_service.dart';
import 'package:neostation/services/sfx_service.dart';
import 'package:neostation/themes/corner_radii.dart';
import 'package:neostation/utils/gamepad_nav.dart';
import 'package:neostation/widgets/custom_notification.dart';
import 'package:neostation/widgets/neo_glass.dart';
import 'package:provider/provider.dart';

const List<String> _sizes = ['S', 'M', 'L', 'XL'];

/// Opens the Android apps options panel from Start: card size, hiding the
/// focused app, and restoring hidden ones.
///
/// [focusedApp] is the app under the grid's cursor, or null when the grid is
/// empty. [onAppsChanged] runs after an app is hidden or restored, so the grid
/// can reload its list.
Future<void> showAndroidOptionsDialog(
  BuildContext context, {
  required SystemModel system,
  required GameModel? focusedApp,
  required Future<void> Function() onAppsChanged,
}) {
  return showGeneralDialog<void>(
    context: context,
    barrierDismissible: true,
    barrierLabel: AppLocale.hintOptions.getString(context),
    barrierColor: Colors.black.withValues(alpha: 0.35),
    transitionDuration: const Duration(milliseconds: 220),
    pageBuilder: (context, animation, secondaryAnimation) =>
        AndroidOptionsDialog(
          system: system,
          focusedApp: focusedApp,
          onAppsChanged: onAppsChanged,
        ),
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

/// What a row of the panel does; the rows are rebuilt from the panel's state
/// on every frame, so the cursor is an index into the current list.
enum _RowKind { cardSize, hideFocused, hiddenApp, unhideAll }

class _PanelRow {
  const _PanelRow(this.kind, {this.app});
  final _RowKind kind;
  final DatabaseGameModel? app;
}

/// The panel [showAndroidOptionsDialog] opens. Public for widget tests.
class AndroidOptionsDialog extends StatefulWidget {
  const AndroidOptionsDialog({
    super.key,
    required this.system,
    required this.focusedApp,
    required this.onAppsChanged,
  });

  final SystemModel system;
  final GameModel? focusedApp;
  final Future<void> Function() onAppsChanged;

  @override
  State<AndroidOptionsDialog> createState() => _AndroidOptionsDialogState();
}

class _AndroidOptionsDialogState extends State<AndroidOptionsDialog> {
  static final _log = LoggerService.instance;

  late final GamepadNavigation _gamepadNav;
  bool _isClosing = false;

  /// Guards against a second hide/unhide while one is being written.
  bool _isBusy = false;

  List<DatabaseGameModel> _hiddenApps = [];
  int _focus = 0;
  final Map<int, GlobalKey> _rowKeys = {};

  List<_PanelRow> get _rows => [
    const _PanelRow(_RowKind.cardSize),
    if (widget.focusedApp != null) const _PanelRow(_RowKind.hideFocused),
    for (final app in _hiddenApps) _PanelRow(_RowKind.hiddenApp, app: app),
    if (_hiddenApps.length > 1) const _PanelRow(_RowKind.unhideAll),
  ];

  @override
  void initState() {
    super.initState();
    _gamepadNav = GamepadNavigation(
      onNavigateUp: () => _moveFocus(-1),
      onNavigateDown: () => _moveFocus(1),
      onNavigateLeft: () => _changeSize(-1),
      onNavigateRight: () => _changeSize(1),
      onSelectItem: () => _activate(_focus),
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
    _loadHiddenApps();
  }

  @override
  void dispose() {
    GamepadNavigationManager.popLayer('android_options_dialog');
    _gamepadNav.dispose();
    super.dispose();
  }

  Future<void> _loadHiddenApps() async {
    try {
      final apps = await GameRepository.getHiddenGames(
        systemId: widget.system.id,
      );
      apps.sort(
        (a, b) =>
            _appName(a).toLowerCase().compareTo(_appName(b).toLowerCase()),
      );
      if (!mounted) return;
      setState(() {
        _hiddenApps = apps;
        _focus = _focus.clamp(0, _rows.length - 1);
      });
    } catch (e) {
      _log.e('Error loading hidden Android apps: $e');
    }
  }

  /// The app's label, which the scan stores as the title.
  static String _appName(DatabaseGameModel app) {
    final label = app.titleName?.trim();
    return label == null || label.isEmpty ? app.displayTitle : label;
  }

  void _close() {
    if (_isClosing) return;
    _isClosing = true;
    Navigator.of(context).pop();
  }

  void _moveFocus(int delta) {
    final next = (_focus + delta).clamp(0, _rows.length - 1);
    if (next == _focus) return;
    SfxService().playNavSound();
    setState(() => _focus = next);
    _scrollToFocus();
  }

  /// Keeps the focused row on screen when the hidden list outgrows the panel.
  void _scrollToFocus() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final rowContext = _rowKeys[_focus]?.currentContext;
      if (rowContext == null || !rowContext.mounted) return;
      Scrollable.ensureVisible(
        rowContext,
        alignment: 0.5,
        duration: const Duration(milliseconds: 150),
      );
    });
  }

  void _setSize(int index) {
    SfxService().playNavSound();
    context.read<SqliteConfigProvider>().updateAndroidGridColumns(
      _sizes[index],
    );
  }

  /// Left/right steps the card size, but only while the size row is focused.
  void _changeSize(int delta) {
    if (_rows[_focus].kind != _RowKind.cardSize) return;
    final provider = context.read<SqliteConfigProvider>();
    final current = _sizes.indexOf(provider.config.androidGridColumns);
    final index = ((current < 0 ? 1 : current) + delta).clamp(
      0,
      _sizes.length - 1,
    );
    if (index == current) return;
    _setSize(index);
  }

  void _activate(int index) {
    final rows = _rows;
    if (index < 0 || index >= rows.length) return;
    if (index != _focus) setState(() => _focus = index);
    final row = rows[index];
    switch (row.kind) {
      case _RowKind.cardSize:
        break;
      case _RowKind.hideFocused:
        _hideFocusedApp();
      case _RowKind.hiddenApp:
        _unhideApp(row.app!);
      case _RowKind.unhideAll:
        _unhideAllApps();
    }
  }

  /// Hides the app under the grid's cursor and closes the panel.
  ///
  /// Unconfirmed, like hiding a game: nothing is deleted, and the app is one
  /// Start press away from coming back.
  Future<void> _hideFocusedApp() async {
    final app = widget.focusedApp;
    // An app's row is keyed by its package name, stored as both filename and
    // path. [GameModel.romname] can't stand in for it: it drops everything
    // after the last dot, which for a package is most of the name.
    final package = app?.romPath;
    if (app == null || package == null || _isBusy) return;
    _isBusy = true;
    final name = app.name.isNotEmpty ? app.name : package;
    try {
      await GameRepository.setGameHidden(
        widget.system.folderName,
        package,
        true,
      );
      await widget.onAppsChanged();
    } catch (e) {
      _log.e('Hiding Android app $package failed: $e');
      _isBusy = false;
      return;
    }
    _isBusy = false;
    if (!mounted) return;
    AppNotification.showNotification(
      context,
      AppLocale.gameHidden.getString(context).replaceFirst('{name}', name),
      type: NotificationType.info,
    );
    _close();
  }

  Future<void> _unhideApp(DatabaseGameModel app) async {
    if (_isBusy) return;
    _isBusy = true;
    try {
      await GameRepository.setGameHidden(
        widget.system.folderName,
        app.filename,
        false,
      );
      await _afterRestore();
    } catch (e) {
      _log.e('Unhiding Android app ${app.filename} failed: $e');
      return;
    } finally {
      _isBusy = false;
    }
    if (!mounted) return;
    AppNotification.showNotification(
      context,
      AppLocale.gameUnhidden
          .getString(context)
          .replaceFirst('{name}', _appName(app)),
      type: NotificationType.success,
    );
  }

  Future<void> _unhideAllApps() async {
    if (_isBusy) return;
    _isBusy = true;
    try {
      await GameRepository.unhideAllGamesForSystem(widget.system.id!);
      await _afterRestore();
    } catch (e) {
      _log.e('Unhiding all Android apps failed: $e');
      return;
    } finally {
      _isBusy = false;
    }
    if (!mounted) return;
    AppNotification.showNotification(
      context,
      AppLocale.allAppsUnhidden.getString(context),
      type: NotificationType.success,
    );
  }

  Future<void> _afterRestore() async {
    await widget.onAppsChanged();
    await _loadHiddenApps();
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
                            child: SingleChildScrollView(
                              child: _buildRows(
                                context,
                                selectedIndex < 0 ? 1 : selectedIndex,
                              ),
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

  Widget _buildRows(BuildContext context, int selectedSize) {
    final rows = _rows;
    final children = <Widget>[];
    for (var i = 0; i < rows.length; i++) {
      final row = rows[i];
      final key = _rowKeys.putIfAbsent(i, GlobalKey.new);
      switch (row.kind) {
        case _RowKind.cardSize:
          children
            ..add(
              _buildGroupLabel(
                context,
                AppLocale.cardSizeGroup.getString(context),
              ),
            )
            ..add(SizedBox(height: 4.r))
            ..add(
              KeyedSubtree(
                key: key,
                child: _buildCardSizeRow(context, selectedSize, i == _focus),
              ),
            );
        case _RowKind.hideFocused:
          children
            ..add(SizedBox(height: 6.r))
            ..add(
              _buildActionRow(
                context,
                key: key,
                index: i,
                icon: Symbols.visibility_off_rounded,
                label: AppLocale.hideApp.getString(context),
                detail: widget.focusedApp!.name,
              ),
            );
        case _RowKind.hiddenApp:
          if (i == 0 || rows[i - 1].kind != _RowKind.hiddenApp) {
            children.add(
              _buildGroupLabel(
                context,
                AppLocale.hiddenAppsGroup.getString(context),
              ),
            );
          }
          children
            ..add(SizedBox(height: 4.r))
            ..add(
              _buildActionRow(
                context,
                key: key,
                index: i,
                icon: Symbols.visibility_rounded,
                label: _appName(row.app!),
                detail: AppLocale.unhide.getString(context),
              ),
            );
        case _RowKind.unhideAll:
          children
            ..add(SizedBox(height: 4.r))
            ..add(
              _buildActionRow(
                context,
                key: key,
                index: i,
                icon: Symbols.restore_rounded,
                label: AppLocale.unhideAll.getString(context),
              ),
            );
      }
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: children,
    );
  }

  /// Focus ring shared by every row: the cursor is drawn the way a selected
  /// size pill is, so the panel reads as one control.
  BoxDecoration? _focusRing(BuildContext context, bool focused) {
    if (!focused) return null;
    final theme = Theme.of(context);
    final cornerRadii = theme.extension<CornerRadii>() ?? CornerRadii.m();
    return BoxDecoration(
      borderRadius: cornerRadii.radiusInternal,
      border: Border.all(color: theme.colorScheme.primary, width: 1.5.r),
    );
  }

  Widget _buildActionRow(
    BuildContext context, {
    required Key key,
    required int index,
    required IconData icon,
    required String label,
    String? detail,
  }) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final cornerRadii = theme.extension<CornerRadii>() ?? CornerRadii.m();
    final radius = cornerRadii.radiusInternal;
    final focused = index == _focus;

    return Container(
      key: key,
      foregroundDecoration: _focusRing(context, focused),
      child: NeoGlassRim(
        cornerRadius: cornerRadii.radiusInternalRadius,
        child: Material(
          color: scheme.surfaceContainerHighest.withValues(alpha: 0.16),
          borderRadius: radius,
          child: InkWell(
            onTap: () => _activate(index),
            borderRadius: radius,
            child: Padding(
              padding: EdgeInsets.symmetric(horizontal: 10.r, vertical: 7.r),
              child: Row(
                children: [
                  Icon(
                    icon,
                    size: 17.r,
                    color: scheme.onSurface.withValues(alpha: 0.6),
                  ),
                  SizedBox(width: 9.r),
                  Expanded(
                    child: Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 11.r,
                        fontWeight: FontWeight.w700,
                        color: scheme.onSurface,
                      ),
                    ),
                  ),
                  if (detail != null) ...[
                    SizedBox(width: 8.r),
                    Flexible(
                      child: Text(
                        detail,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 9.r,
                          fontWeight: FontWeight.w600,
                          color: scheme.onSurface.withValues(alpha: 0.5),
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildCardSizeRow(BuildContext context, int selected, bool focused) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final cornerRadii = theme.extension<CornerRadii>() ?? CornerRadii.m();
    final radius = cornerRadii.radiusInternal;

    return Container(
      foregroundDecoration: _focusRing(context, focused),
      child: NeoGlassRim(
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
