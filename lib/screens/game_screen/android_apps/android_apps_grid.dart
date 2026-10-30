import 'package:flutter/material.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:provider/provider.dart';

import '../../../l10n/app_locale.dart';
import '../../../models/game_model.dart';
import '../../../models/my_systems.dart';
import '../../../models/system_model.dart';
import '../../../providers/sqlite_config_provider.dart';
import '../../../responsive.dart';
import '../../../services/android_service.dart';
import '../../../services/game_service.dart';
import '../../../services/logger_service.dart';
import '../../../services/sfx_service.dart';
import '../../../widgets/android_apps_footer.dart';
import '../../systems_screen/my_systems_section/my_systems_grid.dart';
import 'android_app_card.dart';
import 'android_options_dialog.dart';

/// The Android apps board, laid out with the Systems grid and cards.
///
/// There is no Recent card or other virtual entry here: the grid is exactly
/// the installed apps, with the app icon centred and its short name in the
/// footer where a system card puts its logo.
class AndroidAppsGrid extends StatefulWidget {
  final SystemModel system;

  /// Renders inside the root tab rather than as a pushed Systems route.
  final bool embedded;

  const AndroidAppsGrid({
    super.key,
    required this.system,
    this.embedded = false,
  });

  @override
  State<AndroidAppsGrid> createState() => _AndroidAppsGridState();
}

class _AndroidAppsGridState extends State<AndroidAppsGrid> {
  static final _log = LoggerService.instance;

  /// The systems grid pops the layer it pushed by id; a unique id keeps two
  /// live instances (the tab and a pushed route) from unregistering each
  /// other.
  static int _navLayerSeq = 0;
  late final String _navLayerId = 'android_apps_grid#${++_navLayerSeq}';

  List<GameModel> _apps = [];
  bool _isLoading = true;
  int _selectedIndex = 0;

  bool _canPop = false;
  bool _isNavigatingBack = false;

  /// Guards a second launch while the previous handoff is still in flight.
  bool _isLaunching = false;
  DateTime? _lastLaunchTime;
  static const Duration _launchCooldown = Duration(milliseconds: 1500);

  @override
  void initState() {
    super.initState();
    _loadApps();
  }

  /// Populates the grid by loading detected Android packages from the database.
  Future<void> _loadApps() async {
    try {
      final apps = await GameService.loadGamesForSystem(widget.system);
      if (mounted) {
        setState(() {
          _apps = apps;
          _selectedIndex = apps.isEmpty
              ? 0
              : _selectedIndex.clamp(0, apps.length - 1);
          _isLoading = false;
        });
      }
    } catch (e) {
      _log.e('Error loading Android apps: $e');
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  void _onCardTapped(int index) {
    if (index == _selectedIndex) return;
    setState(() => _selectedIndex = index);
  }

  /// Launches the focused app through the Android platform service.
  ///
  /// A launch hands the foreground to another app, so a second dispatch that
  /// arrives before the handoff is always a duplicate.
  Future<void> _launchSelectedApp() async {
    if (_apps.isEmpty || _isLaunching) return;
    if (_lastLaunchTime != null &&
        DateTime.now().difference(_lastLaunchTime!) < _launchCooldown) {
      return;
    }

    final app = _apps[_selectedIndex];
    final packageName = app.romPath;
    if (packageName == null) return;

    _isLaunching = true;
    _lastLaunchTime = DateTime.now();
    try {
      _log.i('Launching Android app: $packageName');
      await AndroidService.launchPackage(packageName);
    } finally {
      _isLaunching = false;
      _lastLaunchTime = DateTime.now();
    }
  }

  /// Standard exit handler for the pushed route.
  void _goBack() {
    if (_isNavigatingBack) return;
    _isNavigatingBack = true;
    SfxService().playBackSound();

    setState(() => _canPop = true);

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        Navigator.of(context).pop();
        Future.delayed(const Duration(milliseconds: 500), () {
          if (mounted) _isNavigatingBack = false;
        });
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final config = context.watch<SqliteConfigProvider>().config;
    final crossAxisCount = Responsive.getSystemsCrossAxisCountFromSize(
      config.androidGridColumns,
    );
    final selectedIndex = _apps.isEmpty
        ? 0
        : _selectedIndex.clamp(0, _apps.length - 1);
    final cards = [
      for (final app in _apps)
        SystemInfo(
          title: app.name,
          shortName: app.name,
          folderName: 'android',
          primaryFolderName: 'android',
          gameModel: app,
        ),
    ];

    return PopScope(
      canPop: _canPop,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop || widget.embedded) return;
        _goBack();
      },
      child: Scaffold(
        backgroundColor: theme.scaffoldBackgroundColor,
        body: Column(
          children: [
            // The global header floats above embedded tab content.
            if (widget.embedded) SizedBox(height: 46.r),
            if (!widget.embedded) _buildCompactHeader(context),
            Expanded(
              child: _isLoading
                  ? const Center(child: CircularProgressIndicator())
                  : _apps.isEmpty
                  ? _buildEmptyState()
                  : Padding(
                      padding: EdgeInsets.symmetric(horizontal: 6.r),
                      child: SystemCardGridView(
                        crossAxisCount: crossAxisCount,
                        // Same card shape as the Systems grid.
                        childAspectRatio: 0.80,
                        selectedIndex: selectedIndex,
                        systems: cards,
                        navLayerId: _navLayerId,
                        onCardTapped: _onCardTapped,
                        onEnterPressed: _launchSelectedApp,
                        onBackPressed: widget.embedded ? null : _goBack,
                        onEscapePressed: () =>
                            showAndroidOptionsDialog(context),
                        bindYButton: false,
                        enableTabBumpers: widget.embedded,
                        enablePullToRescan: false,
                        // Pinch changes the Android board's own size, leaving
                        // the Systems grid's density alone.
                        enablePinchResize: true,
                        pinchSize: config.androidGridColumns,
                        onPinchSizeChanged: (size) => context
                            .read<SqliteConfigProvider>()
                            .updateAndroidGridColumns(size),
                        crossAxisCountForSize:
                            Responsive.getSystemsCrossAxisCountFromSize,
                        enableSecondaryDisplay: false,
                        enableThemeAssets: false,
                        cardOverrideBuilder:
                            (context, index, info, isSelected, onTap) {
                              return AndroidAppCard(
                                app: _apps[index],
                                isSelected: isSelected,
                                onTap: onTap,
                              );
                            },
                      ),
                    ),
            ),
            AndroidAppsFooter(
              appName: _apps.isEmpty ? '' : _apps[selectedIndex].name,
              onLaunch: () {
                SfxService().playEnterSound();
                _launchSelectedApp();
              },
              onBack: widget.embedded ? null : _goBack,
              showBack: !widget.embedded,
            ),
          ],
        ),
      ),
    );
  }

  /// Minimal header for the pushed route. The tab uses the global header.
  Widget _buildCompactHeader(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: EdgeInsets.only(top: 12.r, left: 16.r, right: 16.r, bottom: 4.r),
      child: Row(
        children: [
          Opacity(
            opacity: 0.8,
            child: Icon(
              Symbols.grid_view_rounded,
              size: 16.r,
              color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
            ),
          ),
          SizedBox(width: 8.r),
          Text(
            AppLocale.androidApps.getString(context).toUpperCase(),
            style: TextStyle(
              fontSize: 12.r,
              fontWeight: FontWeight.w900,
              letterSpacing: 2.0,
              color: theme.colorScheme.onSurface.withValues(alpha: 0.8),
            ),
          ),
          const Spacer(),
          Text(
            '${_apps.length} ${AppLocale.apps.getString(context)}'
                .toUpperCase(),
            style: TextStyle(
              fontSize: 9.r,
              color: theme.colorScheme.onSurface.withValues(alpha: 0.4),
              fontWeight: FontWeight.w800,
              letterSpacing: 1.0,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Opacity(
        opacity: 0.2,
        child: Icon(
          Symbols.apps_rounded,
          size: 48.r,
          color: Theme.of(context).colorScheme.onSurface,
        ),
      ),
    );
  }
}
