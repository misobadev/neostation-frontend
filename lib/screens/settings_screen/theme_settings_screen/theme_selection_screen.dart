import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:neostation/services/sfx_service.dart';
import 'package:provider/provider.dart';
import 'package:neostation/providers/palette_provider.dart';
import 'package:neostation/widgets/theme_card.dart';
import 'package:neostation/utils/gamepad_nav.dart';
import 'package:neostation/responsive.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

/// A specialized configuration screen for selecting application-wide color palettes and visual themes.
///
/// Implements a responsive grid layout with hardware-mapped gamepad navigation
/// (Up/Down/Left/Right) and real-time palette application via PaletteProvider.
class ThemeSelectionScreen extends StatefulWidget {
  const ThemeSelectionScreen({super.key});

  @override
  State<ThemeSelectionScreen> createState() => _ThemeSelectionScreenState();
}

class _ThemeSelectionScreenState extends State<ThemeSelectionScreen> {
  int _selectedIndex = 0;
  late GamepadNavigation _gamepadNav;
  final ScrollController _scrollController = ScrollController();

  /// Constructs a unified list of available themes including the native system resolver.
  List<Map<String, String>> _getCombinedThemes(
    PaletteProvider paletteProvider,
  ) {
    return [
      {
        'name': 'system',
        'displayName':
            PaletteProvider.paletteDisplayNames['system'] ?? 'System',
        'logoPath': paletteProvider.getCurrentLogoPath(),
      },
      ...paletteProvider.getPaletteList(),
    ];
  }

  @override
  void initState() {
    super.initState();
    final paletteProvider = Provider.of<PaletteProvider>(
      context,
      listen: false,
    );
    final combinedThemes = _getCombinedThemes(paletteProvider);

    // Synchronize the selection index with the active palette state.
    final currentThemeName = paletteProvider.currentPaletteName;
    final initialIndex = combinedThemes.indexWhere(
      (t) => t['name'] == currentThemeName,
    );
    if (initialIndex != -1) {
      _selectedIndex = initialIndex;
    }

    _initializeGamepadNavigation();

    // Ensure the viewport is aligned with the active theme upon initialization.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _ensureSelectedItemVisible(_selectedIndex);
    });
  }

  /// Configures the gamepad layer for specialized grid-based navigation.
  void _initializeGamepadNavigation() {
    _gamepadNav = GamepadNavigation(
      onNavigateUp: () => _navigateGrid(GridNavUtils.navigateUp),
      onNavigateDown: () => _navigateGrid(GridNavUtils.navigateDown),
      onNavigateLeft: () => _navigateGrid(GridNavUtils.navigateLeft),
      onNavigateRight: () => _navigateGrid(GridNavUtils.navigateRight),
      onSelectItem: () => _selectThemeByIndex(),
      onBack: () => Navigator.of(context).pop(),
    );
    _gamepadNav.initialize();
    _gamepadNav.activate();
  }

  /// Orchestrates grid-based focus movement using hardware-mapped protocols.
  void _navigateGrid(
    int Function({
      required int currentIndex,
      required int crossAxisCount,
      required int maxItems,
    })
    navFunc,
  ) {
    final paletteProvider = Provider.of<PaletteProvider>(
      context,
      listen: false,
    );
    final combined = _getCombinedThemes(paletteProvider);
    final crossAxisCount = Responsive.getThemesCrossAxisCount(context);

    if (mounted) {
      setState(() {
        _selectedIndex = navFunc(
          currentIndex: _selectedIndex,
          crossAxisCount: crossAxisCount,
          maxItems: combined.length,
        );
      });
      _ensureSelectedItemVisible(_selectedIndex);
    }
  }

  /// Viewport alignment protocol (placeholder for GlobalKey implementation).
  void _ensureSelectedItemVisible(int index) {
    // GridView padding provides sufficient boundary visibility for the current palette set.
  }

  /// Persistent state protocol: Applies the selected theme to the application.
  Future<void> _selectThemeByIndex() async {
    final paletteProvider = Provider.of<PaletteProvider>(
      context,
      listen: false,
    );
    final combined = _getCombinedThemes(paletteProvider);

    if (_selectedIndex < combined.length) {
      final selected = combined[_selectedIndex];
      await paletteProvider.setPalette(selected['name']!);
      if (mounted) setState(() {});
    }
  }

  @override
  void dispose() {
    _gamepadNav.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final paletteProvider = Provider.of<PaletteProvider>(context);
    final combined = _getCombinedThemes(paletteProvider);
    final crossAxisCount = Responsive.getThemesCrossAxisCount(context);

    return Scaffold(
      backgroundColor: Theme.of(context).colorScheme.surface,
      body: SafeArea(
        child: Column(
          children: [
            // Header Section: Branding and navigation escape.
            Padding(
              padding: EdgeInsets.all(16.r),
              child: Row(
                children: [
                  IconButton(
                    icon: const Icon(Symbols.arrow_back_rounded),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                  SizedBox(width: 8.r),
                  Text(
                    'Select Theme',
                    style: TextStyle(
                      fontSize: 20.r,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
            ),

            // Visualization Layer: Managed theme catalog.
            Expanded(
              child: GridView.builder(
                controller: _scrollController,
                padding: EdgeInsets.symmetric(horizontal: 16.r, vertical: 8.r),
                itemCount: combined.length,
                gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: crossAxisCount,
                  crossAxisSpacing: 8.r,
                  mainAxisSpacing: 8.r,
                  childAspectRatio: 16 / 9,
                ),
                itemBuilder: (context, index) {
                  final t = combined[index];

                  // Resolution: Determines if the palette is active in the current session.
                  final isSelected =
                      paletteProvider.currentPaletteName == t['name'] ||
                      (t['name'] == 'system' &&
                          paletteProvider.currentPaletteName == 'system');

                  return ThemeCard(
                    themeName: t['name']!,
                    displayName: t['displayName']!,
                    logoPath: t['logoPath']!,
                    isFocused: _selectedIndex == index,
                    isSelected: isSelected,
                    onTap: () async {
                      SfxService().playNavSound();
                      await paletteProvider.setPalette(t['name']!);
                      if (mounted) {
                        setState(() {
                          _selectedIndex = index;
                        });
                      }
                    },
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}
