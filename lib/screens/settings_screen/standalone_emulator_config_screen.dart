import 'dart:io';
import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:file_picker/file_picker.dart';
import 'package:neostation/services/game_service.dart';
import 'package:neostation/services/sfx_service.dart';
import 'package:neostation/repositories/emulator_repository.dart';
import 'package:neostation/utils/gamepad_nav.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:neostation/widgets/custom_notification.dart';
import 'package:neostation/services/logger_service.dart';

/// A specialized configuration screen for mapping hardware-specific standalone
/// emulator binaries to the application's execution engine.
///
/// Orchestrates platform-specific file picking, path persistence via unique
/// identifiers, and provides a hardware-mapped interface for emulator setup.
class StandaloneEmulatorConfigScreen extends StatefulWidget {
  final String systemId;
  final String systemName;

  const StandaloneEmulatorConfigScreen({
    super.key,
    required this.systemId,
    required this.systemName,
  });

  @override
  State<StandaloneEmulatorConfigScreen> createState() =>
      _StandaloneEmulatorConfigScreenState();
}

class _StandaloneEmulatorConfigScreenState
    extends State<StandaloneEmulatorConfigScreen> {
  late GamepadNavigation _gamepadNav;
  int _selectedIndex = 0;
  List<Map<String, dynamic>> _emulators = [];
  bool _isLoading = true;

  static final _log = LoggerService.instance;

  @override
  void initState() {
    super.initState();
    _initializeGamepadNavigation();
    _loadEmulators();
  }

  /// Synchronizes the local emulator catalog for the selected system context.
  Future<void> _loadEmulators() async {
    try {
      if (mounted) setState(() => _isLoading = true);

      final emulators =
          await EmulatorRepository.getStandaloneEmulatorsBySystemId(
            widget.systemId,
          );

      if (mounted) {
        setState(() {
          _emulators = emulators;
          _isLoading = false;
        });
      }
    } catch (e) {
      _log.e('Failed to synchronize emulator configuration: $e');
      if (mounted) setState(() => _isLoading = false);
    }
  }

  @override
  void dispose() {
    GamepadNavigationManager.popLayer('standalone_emulator_config_screen');
    _gamepadNav.dispose();
    super.dispose();
  }

  /// Configures the gamepad stack for high-precision navigation within the configuration context.
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
        'standalone_emulator_config_screen',
        onActivate: () => _gamepadNav.activate(),
        onDeactivate: () => _gamepadNav.deactivate(),
      );
    });
  }

  void _navigateUp() {
    if (_emulators.isEmpty) return;
    setState(() {
      _selectedIndex =
          (_selectedIndex - 1 + _emulators.length) % _emulators.length;
    });
  }

  void _navigateDown() {
    if (_emulators.isEmpty) return;
    setState(() {
      _selectedIndex = (_selectedIndex + 1) % _emulators.length;
    });
  }

  void _selectItem() {
    if (_emulators.isEmpty || _selectedIndex >= _emulators.length) return;

    final emulator = _emulators[_selectedIndex];
    _pickEmulatorExecutable(emulator);
  }

  /// Orchestrates the platform-specific executable selection flow.
  Future<void> _pickEmulatorExecutable(Map<String, dynamic> emulator) async {
    try {
      // Suspend gamepad navigation to prevent input conflicts during native file selector interactions.
      _gamepadNav.deactivate();

      String? executablePath;

      if (Platform.isWindows) {
        // Windows Environment: Utilize the specialized executable filter.
        final result = await FilePicker.platform.pickFiles(
          type: FileType.custom,
          allowedExtensions: ['exe'],
          dialogTitle: 'Select ${emulator['name']} executable',
        );

        if (result != null && result.files.single.path != null) {
          executablePath = result.files.single.path!;
        }
      } else {
        // POSIX Environments (Linux/macOS): Utilize generic binary selection.
        final result = await FilePicker.platform.pickFiles(
          type: FileType.any,
          dialogTitle: 'Select ${emulator['name']} executable',
        );

        if (result != null && result.files.single.path != null) {
          executablePath = result.files.single.path!;
        }
      }

      if (executablePath != null) {
        // Commit the validated binary path to the persistent SQLite store.
        await EmulatorRepository.setStandaloneEmulatorPath(
          emulator['unique_identifier']?.toString() ?? '',
          executablePath,
        );

        if (mounted) {
          AppNotification.showNotification(
            context,
            '${emulator['name']} path configured successfully',
            type: NotificationType.success,
          );
        }

        // Synchronize the local UI state with the updated persistent model.
        await _loadEmulators();
      }
    } catch (e) {
      _log.e('Binary selection flow interrupted: $e');
      if (mounted) {
        await _showErrorDialog('Error selecting file: $e');
      }
    } finally {
      // Restore gamepad navigation responsiveness.
      _gamepadNav.activate();
    }
  }

  /// Displays a localized error dialog for critical configuration failures.
  Future<void> _showErrorDialog(String message) async {
    return showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Error'),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  /// Resolves the human-readable status for a given emulator configuration.
  String _getStatusText(Map<String, dynamic> emulator) {
    final path = emulator['emulator_path']?.toString();
    if (path == null || path.isEmpty) {
      return 'Not configured';
    }
    return 'Configured';
  }

  /// Resolves the visual status color for a given emulator configuration.
  Color _getStatusColor(Map<String, dynamic> emulator) {
    final path = emulator['emulator_path']?.toString();
    if (path == null || path.isEmpty) {
      return Colors.orange;
    }
    return Colors.green;
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
            // Header Section: Contextual branding and navigation escape.
            Container(
              padding: EdgeInsets.symmetric(horizontal: 32.w, vertical: 24.h),
              decoration: BoxDecoration(
                color: colorScheme.surface,
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.3),
                    blurRadius: 8.w,
                    offset: Offset(0, 2.h),
                  ),
                ],
              ),
              child: Row(
                children: [
                  IconButton(
                    icon: Icon(Symbols.arrow_back_rounded, color: colorScheme.onSurface),
                    onPressed: () => Navigator.pop(context),
                  ),
                  SizedBox(width: 16.w),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          widget.systemName,
                          style: TextStyle(
                            fontSize: 24.sp,
                            fontWeight: FontWeight.bold,
                            color: colorScheme.onSurface,
                          ),
                        ),
                        Text(
                          'Configure emulator paths',
                          style: TextStyle(
                            fontSize: 14.sp,
                            color: colorScheme.onSurface.withValues(alpha: 0.6),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),

            // Content Section: Managed emulator catalog.
            Expanded(
              child: _isLoading
                  ? Center(
                      child: CircularProgressIndicator(
                        color: colorScheme.primary,
                      ),
                    )
                  : _emulators.isEmpty
                  ? Center(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(
                            Symbols.info_rounded,
                            size: 64.sp,
                            color: colorScheme.onSurface.withValues(alpha: 0.6),
                          ),
                          SizedBox(height: 16.h),
                          Text(
                            'No emulators found',
                            style: TextStyle(
                              fontSize: 18.sp,
                              color: colorScheme.onSurface.withValues(
                                alpha: 0.6,
                              ),
                            ),
                          ),
                        ],
                      ),
                    )
                  : ListView.builder(
                      padding: EdgeInsets.all(24.w),
                      itemCount: _emulators.length,
                      itemBuilder: (context, index) {
                        final emulator = _emulators[index];
                        final isSelected = _selectedIndex == index;
                        final path = emulator['emulator_path']?.toString();

                        return GestureDetector(
                          onTap: () {
                            SfxService().playNavSound();
                            _pickEmulatorExecutable(emulator);
                          },
                          child: Container(
                            margin: EdgeInsets.only(bottom: 16.h),
                            padding: EdgeInsets.all(20.w),
                            decoration: BoxDecoration(
                              color: isSelected
                                  ? colorScheme.primary.withValues(alpha: 0.2)
                                  : colorScheme.surfaceContainerHighest,
                              borderRadius: BorderRadius.circular(16.w),
                              border: Border.all(
                                color: isSelected
                                    ? colorScheme.primary
                                    : Colors.transparent,
                                width: 2.w,
                              ),
                              boxShadow: [
                                BoxShadow(
                                  color: Colors.black.withValues(alpha: 0.2),
                                  blurRadius: 8.w,
                                  offset: Offset(0, 2.h),
                                ),
                              ],
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    // Visual Branding: Hardware identity and status mapping.
                                    Container(
                                      width: 48.w,
                                      height: 48.w,
                                      decoration: BoxDecoration(
                                        color: _getStatusColor(
                                          emulator,
                                        ).withValues(alpha: 0.2),
                                        borderRadius: BorderRadius.circular(
                                          12.w,
                                        ),
                                      ),
                                      child: Icon(
                                        Symbols.computer_rounded,
                                        color: _getStatusColor(emulator),
                                        size: 24.sp,
                                      ),
                                    ),
                                    SizedBox(width: 16.w),

                                    // Metadata Layer: Technical emulator info.
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Text(
                                            emulator['name']?.toString() ??
                                                'Unknown',
                                            style: TextStyle(
                                              fontSize: 18.sp,
                                              fontWeight: FontWeight.w600,
                                              color: colorScheme.onSurface,
                                            ),
                                          ),
                                          SizedBox(height: 4.h),
                                          Row(
                                            children: [
                                              Container(
                                                width: 8.w,
                                                height: 8.w,
                                                decoration: BoxDecoration(
                                                  color: _getStatusColor(
                                                    emulator,
                                                  ),
                                                  shape: BoxShape.circle,
                                                ),
                                              ),
                                              SizedBox(width: 8.w),
                                              Text(
                                                _getStatusText(emulator),
                                                style: TextStyle(
                                                  fontSize: 14.sp,
                                                  color: _getStatusColor(
                                                    emulator,
                                                  ),
                                                  fontWeight: FontWeight.w500,
                                                ),
                                              ),
                                            ],
                                          ),
                                        ],
                                      ),
                                    ),

                                    // Interaction Sentinel.
                                    Icon(
                                      Symbols.settings_rounded,
                                      color: isSelected
                                          ? colorScheme.primary
                                          : colorScheme.onSurface.withValues(
                                              alpha: 0.6,
                                            ),
                                      size: 24.sp,
                                    ),
                                  ],
                                ),

                                // Dynamic Metadata: Active filesystem path visualization.
                                if (path != null && path.isNotEmpty) ...[
                                  SizedBox(height: 12.h),
                                  Container(
                                    padding: EdgeInsets.all(12.w),
                                    decoration: BoxDecoration(
                                      color: colorScheme.surface.withValues(
                                        alpha: 0.5,
                                      ),
                                      borderRadius: BorderRadius.circular(8.w),
                                    ),
                                    child: Row(
                                      children: [
                                        Icon(
                                          Symbols.folder_rounded,
                                          size: 16.sp,
                                          color: colorScheme.onSurface
                                              .withValues(alpha: 0.6),
                                        ),
                                        SizedBox(width: 8.w),
                                        Expanded(
                                          child: Text(
                                            path,
                                            style: TextStyle(
                                              fontSize: 12.sp,
                                              color: colorScheme.onSurface
                                                  .withValues(alpha: 0.6),
                                              fontFamily: 'monospace',
                                            ),
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ],
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
