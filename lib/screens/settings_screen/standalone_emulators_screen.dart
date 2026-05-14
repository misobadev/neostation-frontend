import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:neostation/services/sfx_service.dart';
import 'package:neostation/repositories/emulator_repository.dart';
import 'package:neostation/utils/gamepad_nav.dart';
import 'package:neostation/services/game_service.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:neostation/services/logger_service.dart';
import 'standalone_emulator_config_screen.dart';

/// A specialized configuration screen for managing standalone emulator associations per system.
///
/// Orchestrates the discovery of non-libretro emulators compatible with the
/// current host OS, providing a centralized interface for configuring native
/// execution paths and arguments.
class StandaloneEmulatorsScreen extends StatefulWidget {
  const StandaloneEmulatorsScreen({super.key});

  @override
  State<StandaloneEmulatorsScreen> createState() =>
      _StandaloneEmulatorsScreenState();
}

class _StandaloneEmulatorsScreenState extends State<StandaloneEmulatorsScreen> {
  late GamepadNavigation _gamepadNav;
  int _selectedIndex = 0;
  List<Map<String, dynamic>> _systems = [];
  bool _isLoading = true;

  static final _log = LoggerService.instance;

  @override
  void initState() {
    super.initState();
    _initializeGamepadNavigation();
    _loadSystemsWithStandaloneEmulators();
  }

  /// Resolves the list of systems that support standalone emulation on the current platform.
  Future<void> _loadSystemsWithStandaloneEmulators() async {
    try {
      if (mounted) setState(() => _isLoading = true);

      final systems =
          await EmulatorRepository.getSystemsWithStandaloneEmulators();

      if (mounted) {
        setState(() {
          _systems = systems;
          _isLoading = false;
        });
      }
    } catch (e) {
      _log.e('Failed to synchronize standalone emulator catalog: $e');
      if (mounted) setState(() => _isLoading = false);
    }
  }

  @override
  void dispose() {
    GamepadNavigationManager.popLayer('standalone_emulators_screen');
    _gamepadNav.dispose();
    super.dispose();
  }

  /// Configures the multi-layer gamepad stack for the standalone configuration context.
  void _initializeGamepadNavigation() {
    _gamepadNav = GamepadNavigation(
      onNavigateUp: _navigateUp,
      onNavigateDown: _navigateDown,
      onNavigateLeft: () {},
      onNavigateRight: () {},
      onSelectItem: _selectItem,
      onBack: () => Navigator.of(context).pop(),
    );

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _gamepadNav.initialize();
      GamepadNavigationManager.pushLayer(
        'standalone_emulators_screen',
        onActivate: () => _gamepadNav.activate(),
        onDeactivate: () => _gamepadNav.deactivate(),
      );
    });
  }

  void _navigateUp() {
    if (_systems.isEmpty) return;
    setState(() {
      _selectedIndex = (_selectedIndex - 1 + _systems.length) % _systems.length;
    });
  }

  void _navigateDown() {
    if (_systems.isEmpty) return;
    setState(() {
      _selectedIndex = (_selectedIndex + 1) % _systems.length;
    });
  }

  void _selectItem() {
    if (_systems.isEmpty || _selectedIndex >= _systems.length) return;

    final system = _systems[_selectedIndex];
    _openEmulatorConfig(system);
  }

  /// Dispatches navigation to the detailed emulator configuration for the selected system.
  Future<void> _openEmulatorConfig(Map<String, dynamic> system) async {
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => StandaloneEmulatorConfigScreen(
          systemId: system['id']?.toString() ?? '',
          systemName: system['real_name']?.toString() ?? '',
        ),
      ),
    );

    // Synchronize the system list to reflect any modified configuration.
    await _loadSystemsWithStandaloneEmulators();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Scaffold(
      backgroundColor: colorScheme.surface,
      body: SafeArea(
        child: Column(
          children: [
            // Header Section: Title and navigation escape.
            Container(
              padding: EdgeInsets.symmetric(horizontal: 32.r, vertical: 24.r),
              decoration: BoxDecoration(
                color: colorScheme.surface,
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.3),
                    blurRadius: 8.r,
                    offset: Offset(0, 2.r),
                  ),
                ],
              ),
              child: Row(
                children: [
                  IconButton(
                    icon: Icon(Symbols.arrow_back_rounded, color: colorScheme.onSurface),
                    onPressed: () => Navigator.pop(context),
                  ),
                  SizedBox(width: 8.r),
                  Icon(Symbols.gamepad_rounded, color: colorScheme.primary, size: 32.r),
                  SizedBox(width: 16.r),
                  Text(
                    'Standalone Emulators',
                    style: TextStyle(
                      fontSize: 28.r,
                      fontWeight: FontWeight.bold,
                      color: colorScheme.onSurface,
                    ),
                  ),
                ],
              ),
            ),

            // Content Section: Lifecycle-aware system catalog.
            Expanded(
              child: _isLoading
                  ? Center(
                      child: CircularProgressIndicator(
                        color: colorScheme.primary,
                      ),
                    )
                  : _systems.isEmpty
                  ? Center(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(
                            Symbols.info_rounded,
                            size: 64.r,
                            color: colorScheme.onSurface.withValues(alpha: 0.6),
                          ),
                          SizedBox(height: 16.r),
                          Text(
                            'No standalone emulators configured',
                            style: TextStyle(
                              fontSize: 18.r,
                              color: colorScheme.onSurface.withValues(
                                alpha: 0.6,
                              ),
                            ),
                          ),
                        ],
                      ),
                    )
                  : ListView.builder(
                      padding: EdgeInsets.all(24.r),
                      itemCount: _systems.length,
                      itemBuilder: (context, index) {
                        final system = _systems[index];
                        final isSelected = _selectedIndex == index;

                        return GestureDetector(
                          onTap: () {
                            SfxService().playNavSound();
                            _openEmulatorConfig(system);
                          },
                          child: Container(
                            margin: EdgeInsets.only(bottom: 16.r),
                            padding: EdgeInsets.all(20.r),
                            decoration: BoxDecoration(
                              color: isSelected
                                  ? colorScheme.primary.withValues(alpha: 0.2)
                                  : colorScheme.surfaceContainerHighest,
                              borderRadius: BorderRadius.circular(16.r),
                              border: Border.all(
                                color: isSelected
                                    ? colorScheme.primary
                                    : Colors.transparent,
                                width: 2.r,
                              ),
                              boxShadow: [
                                BoxShadow(
                                  color: Colors.black.withValues(alpha: 0.2),
                                  blurRadius: 8.r,
                                  offset: Offset(0, 2.r),
                                ),
                              ],
                            ),
                            child: Row(
                              children: [
                                // System Visualization: Hardware identity.
                                Container(
                                  width: 56.r,
                                  height: 56.r,
                                  decoration: BoxDecoration(
                                    color: colorScheme.primary.withValues(
                                      alpha: 0.2,
                                    ),
                                    borderRadius: BorderRadius.circular(12.r),
                                  ),
                                  child: Icon(
                                    Symbols.videogame_asset_rounded,
                                    color: colorScheme.primary,
                                    size: 32.r,
                                  ),
                                ),
                                SizedBox(width: 20.r),

                                // Metadata Layer: Descriptive system info.
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        system['real_name']?.toString() ??
                                            'Unknown',
                                        style: TextStyle(
                                          fontSize: 20.r,
                                          fontWeight: FontWeight.w600,
                                          color: colorScheme.onSurface,
                                        ),
                                      ),
                                      SizedBox(height: 4.r),
                                      Text(
                                        '${system['emulator_count']} emulator${system['emulator_count'] > 1 ? 's' : ''} available',
                                        style: TextStyle(
                                          fontSize: 14.r,
                                          color: colorScheme.onSurface
                                              .withValues(alpha: 0.6),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),

                                // Selection Sentinel.
                                Icon(
                                  Symbols.chevron_right_rounded,
                                  color: isSelected
                                      ? colorScheme.primary
                                      : colorScheme.onSurface.withValues(
                                          alpha: 0.6,
                                        ),
                                  size: 28.r,
                                ),
                              ],
                            ),
                          ),
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
