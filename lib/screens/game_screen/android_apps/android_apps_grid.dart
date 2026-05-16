import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:neostation/responsive.dart';
import 'package:neostation/services/android_service.dart';
import 'package:neostation/services/logger_service.dart';
import 'package:neostation/services/sfx_service.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:provider/provider.dart';
import '../../../models/system_model.dart';
import '../../../models/game_model.dart';
import '../../../services/game_service.dart';
import '../../../utils/gamepad_nav.dart';
import '../../../providers/palette_provider.dart';
import '../../../widgets/android_apps_footer.dart';
import '../../../widgets/custom_notification.dart';
import '../../../l10n/app_locale.dart';
import 'android_app_card.dart';

/// A specialized grid view for browsing and launching native Android applications.
///
/// Implements a high-performance custom grid using Stack/Positioned to allow
/// for seamless, console-style focus animations and absolute control over
/// the selector highlight positioning.
class AndroidAppsGrid extends StatefulWidget {
  final SystemModel system;

  const AndroidAppsGrid({super.key, required this.system});

  @override
  State<AndroidAppsGrid> createState() => _AndroidAppsGridState();
}

class _AndroidAppsGridState extends State<AndroidAppsGrid> {
  static final _log = LoggerService.instance;

  List<GameModel> _apps = [];
  bool _isLoading = true;
  int _selectedIndex = 0;
  late GamepadNavigation _gamepadNav;
  final ScrollController _scrollController = ScrollController();

  // Navigation state for performance optimization (Fast Scroll).
  bool _isNavigatingFast = false;
  DateTime? _lastNavTime;

  bool _canPop = false;
  bool _isNavigatingBack = false;

  @override
  void initState() {
    super.initState();
    _loadApps();
    _initializeGamepad();
  }

  @override
  void dispose() {
    _gamepadNav.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  /// Configures input handling for gamepad and keyboard navigation.
  void _initializeGamepad() {
    _gamepadNav = GamepadNavigation(
      onNavigateUp: _navigateUp,
      onNavigateDown: _navigateDown,
      onNavigateLeft: _navigateLeft,
      onNavigateRight: _navigateRight,
      onSelectItem: _launchSelectedApp,
      onFavorite: _toggleFavorite,
      onBack: _goBack,
    );

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _gamepadNav.initialize();
      _gamepadNav.activate();
    });
  }

  /// Populates the grid by loading detected Android packages from the database.
  Future<void> _loadApps() async {
    try {
      final apps = await GameService.loadGamesForSystem(widget.system);
      if (mounted) {
        setState(() {
          _apps = apps;
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

  void _navigateUp() {
    final columns = Responsive.getAndroidAppsCrossAxisCount(context);
    if (_selectedIndex >= columns) {
      _updateSelection(_selectedIndex - columns);
    }
  }

  void _navigateDown() {
    final columns = Responsive.getAndroidAppsCrossAxisCount(context);
    if (_selectedIndex + columns < _apps.length) {
      _updateSelection(_selectedIndex + columns);
    } else if (_selectedIndex < _apps.length - 1) {
      // Focus boundary: snap to the last item if in the final row.
      _updateSelection(_apps.length - 1);
    }
  }

  void _navigateLeft() {
    if (_selectedIndex > 0) {
      _updateSelection(_selectedIndex - 1);
    }
  }

  void _navigateRight() {
    if (_selectedIndex < _apps.length - 1) {
      _updateSelection(_selectedIndex + 1);
    }
  }

  /// Updates the focused item index and manages navigation speed heuristics.
  void _updateSelection(int newIndex) {
    if (newIndex == _selectedIndex) return;

    final now = DateTime.now();
    _isNavigatingFast =
        _lastNavTime != null &&
        now.difference(_lastNavTime!).inMilliseconds < 150;
    _lastNavTime = now;

    SfxService().playNavSound();
    setState(() {
      _selectedIndex = newIndex;
    });

    _ensureSelectedItemVisible();
  }

  /// Dynamically synchronizes the scroll offset to keep the focused item centered or visible.
  void _ensureSelectedItemVisible() {
    if (!_scrollController.hasClients || _apps.isEmpty) return;

    final columns = Responsive.getAndroidAppsCrossAxisCount(context);
    final spacing = 8.r;
    final horizontalPadding = 12.r;

    final screenWidth = MediaQuery.of(context).size.width - 22.r;
    final totalSpacing = spacing * (columns - 1);
    final availableWidth = screenWidth - totalSpacing - horizontalPadding;
    final itemWidth = availableWidth / columns;
    final rowHeight = itemWidth + spacing;

    final selectedRow = _selectedIndex ~/ columns;
    final totalRows = (_apps.length / columns).ceil();

    final viewportHeight = _scrollController.position.viewportDimension;
    final maxScrollExtent = _scrollController.position.maxScrollExtent;
    final minScrollExtent = _scrollController.position.minScrollExtent;

    double targetOffset;
    if (selectedRow == 0) {
      targetOffset = minScrollExtent;
    } else if (selectedRow >= totalRows - 1) {
      targetOffset = maxScrollExtent;
    } else {
      // Center the targeted row within the viewport for optimal visibility.
      final targetRowCenter = selectedRow * rowHeight + (rowHeight / 2);
      targetOffset = (targetRowCenter - (viewportHeight / 2)).clamp(
        minScrollExtent,
        maxScrollExtent,
      );
    }

    _scrollController.animateTo(
      targetOffset,
      duration: _isNavigatingFast
          ? const Duration(milliseconds: 180)
          : const Duration(milliseconds: 360),
      curve: Curves.easeOutQuart,
    );
  }

  /// Delegates execution to the Android platform service for external app launching.
  Future<void> _launchSelectedApp() async {
    if (_apps.isEmpty) return;
    final app = _apps[_selectedIndex];
    final packageName = app.romPath;

    if (packageName != null) {
      SfxService().playEnterSound();
      _log.i('Launching Android app: $packageName');
      await AndroidService.launchPackage(packageName);
    }
  }

  /// Standard exit handler with gamepad input management.
  void _goBack() {
    if (_isNavigatingBack) return;
    _isNavigatingBack = true;

    SfxService().playBackSound();

    setState(() {
      _canPop = true;
    });

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        Navigator.of(context).pop();

        Future.delayed(const Duration(milliseconds: 500), () {
          if (mounted) {
            _isNavigatingBack = false;
          }
        });
      }
    });
  }

  Future<void> _toggleFavorite() async {
    if (_apps.isEmpty) return;

    final selectedApp = _apps[_selectedIndex];
    try {
      await GameService.toggleFavorite(selectedApp);
      if (!mounted) return;

      final updatedSelection = selectedApp.copyWith(
        isFavorite: !(selectedApp.isFavorite ?? false),
      );

      setState(() {
        _apps[_selectedIndex] = updatedSelection;
        _apps.sort((a, b) {
          if (a.isFavorite == true && b.isFavorite != true) return -1;
          if (a.isFavorite != true && b.isFavorite == true) return 1;
          return a.name.compareTo(b.name);
        });
        _selectedIndex = _apps.indexWhere(
          (app) => app.romPath == updatedSelection.romPath,
        );
        if (_selectedIndex < 0) _selectedIndex = 0;
      });

      AppNotification.showNotification(
        context,
        AppLocale.favoriteUpdated.getString(context),
        type: NotificationType.success,
      );
      _ensureSelectedItemVisible();
    } catch (e) {
      _log.e('Error toggling Android app favorite: $e');
      if (!mounted) return;
      AppNotification.showNotification(
        context,
        AppLocale.errorUpdatingFavorite.getString(context),
        type: NotificationType.error,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final paletteProvider = context.watch<PaletteProvider>();
    final isOled = paletteProvider.isOled;

    return PopScope(
      canPop: _canPop,
      onPopInvokedWithResult: (bool didPop, dynamic result) {
        if (didPop) return;
        _goBack();
      },
      child: Scaffold(
        backgroundColor: theme.scaffoldBackgroundColor,
        body: Stack(
          children: [
            // Ambient UI layer: Shared background architecture.
            if (!isOled)
              Positioned.fill(
                child: Builder(
                  builder: (context) {
                    final bg = Theme.of(context).scaffoldBackgroundColor;
                    return Container(decoration: BoxDecoration(color: bg));
                  },
                ),
              )
            else
              Positioned.fill(
                child: Container(color: theme.scaffoldBackgroundColor),
              ),

            Column(
              children: [
                _buildCompactHeader(),

                Expanded(
                  child: _isLoading
                      ? const Center(child: CircularProgressIndicator())
                      : _apps.isEmpty
                      ? _buildEmptyState()
                      : _buildManualGrid(),
                ),

                AndroidAppsFooter(
                  appName: _apps.isNotEmpty ? _apps[_selectedIndex].name : '',
                  onLaunch: _launchSelectedApp,
                  onFavorite: _toggleFavorite,
                  onBack: _goBack,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// Renders a minimal header displaying the current system and library count.
  Widget _buildCompactHeader() {
    final theme = Theme.of(context);

    return Container(
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
            'ANDROID APPS',
            style: TextStyle(
              fontSize: 12.r,
              fontWeight: FontWeight.w900,
              letterSpacing: 2.0,
              color: theme.colorScheme.onSurface.withValues(alpha: 0.8),
            ),
          ),
          const Spacer(),
          Text(
            '${_apps.length} ITEMS',
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

  /// High-performance manual grid layout.
  /// Uses a Stack to overlay the selector highlight independently of the grid items
  /// for smooth focus transition animations.
  Widget _buildManualGrid() {
    return LayoutBuilder(
      builder: (context, constraints) {
        final cols = Responsive.getAndroidAppsCrossAxisCount(context);
        final spacing = 8.r;
        final horizontalPadding = 12.r;

        final screenWidth = constraints.maxWidth;
        final totalSpacing = spacing * (cols - 1);
        final availableWidth = screenWidth - totalSpacing - horizontalPadding;
        final itemWidth = availableWidth / cols;
        final itemHeight = itemWidth;

        final numRows = (_apps.length / cols).ceil();
        final totalHeight =
            numRows * itemHeight + (numRows > 0 ? (numRows - 1) * spacing : 0);

        final selRow = _selectedIndex ~/ cols;
        final selCol = _selectedIndex % cols;
        final highlightLeft =
            (horizontalPadding / 2) + selCol * (itemWidth + spacing);
        final highlightTop = selRow * (itemHeight + spacing);

        return SingleChildScrollView(
          controller: _scrollController,
          padding: EdgeInsets.symmetric(
            vertical: 8.r,
            horizontal: horizontalPadding / 2,
          ),
          physics: const BouncingScrollPhysics(
            parent: AlwaysScrollableScrollPhysics(),
          ),
          child: SizedBox(
            height: totalHeight,
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                // Layer 1: Grid Items
                ...List.generate(_apps.length, (index) {
                  final row = index ~/ cols;
                  final col = index % cols;
                  final left = col * (itemWidth + spacing);
                  final top = row * (itemHeight + spacing);

                  return Positioned(
                    left: left,
                    top: top,
                    width: itemWidth,
                    height: itemHeight,
                    child: AndroidAppCard(
                      app: _apps[index],
                      isSelected: _selectedIndex == index,
                      onTap: () {
                        setState(() {
                          _selectedIndex = index;
                          _ensureSelectedItemVisible();
                        });
                      },
                    ),
                  );
                }),

                // Layer 2: Selector Highlight Overlay (Animated)
                AnimatedPositioned(
                  duration: Duration(
                    milliseconds: _isNavigatingFast ? 120 : 300,
                  ),
                  curve: Curves.easeOutQuart,
                  left: highlightLeft - (horizontalPadding / 2) - 1.r,
                  top: highlightTop - 1.r,
                  width: itemWidth + 2.r,
                  height: itemHeight + 2.r,
                  child: IgnorePointer(
                    child: Container(
                      decoration: BoxDecoration(
                        border: Border.all(
                          color: Theme.of(context).colorScheme.secondary,
                          width: 4.r,
                        ),
                        borderRadius: BorderRadius.circular(16.r),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  /// Placeholder visual for empty app libraries.
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
