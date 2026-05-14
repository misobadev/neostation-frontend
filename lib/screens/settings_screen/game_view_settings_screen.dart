import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:neostation/services/sfx_service.dart';
import 'package:neostation/utils/gamepad_nav.dart';
import 'package:neostation/repositories/config_repository.dart';
import 'package:neostation/widgets/custom_notification.dart';
import 'package:neostation/services/logger_service.dart';

/// A specialized configuration screen for managing system-wide game library layout preferences.
///
/// Orchestrates the transition between Grid and List visualization modes, ensuring
/// persistent state via SQLite and providing hardware-mapped gamepad navigation.
class GameViewSettingsScreen extends StatefulWidget {
  const GameViewSettingsScreen({super.key});

  @override
  State<GameViewSettingsScreen> createState() => _GameViewSettingsScreenState();
}

class _GameViewSettingsScreenState extends State<GameViewSettingsScreen> {
  static final _log = LoggerService.instance;
  late GamepadNavigation _gamepadNav;
  int _selectedIndex = 1;
  String _currentView = 'list'; // Supported modes: 'grid', 'list'.

  late final List<FocusNode> _optionFocusNodes;

  /// Definitive model for supported library visualization modes.
  final List<Map<String, dynamic>> _viewOptions = [
    {
      'title': 'Grid View',
      'subtitle': 'Show games in a responsive grid layout',
      'icon': 'gamepad-bulk.png',
      'value': 'grid',
    },
    {
      'title': 'List View',
      'subtitle': 'Show games in a high-density list layout',
      'icon': 'folder-bulk.png',
      'value': 'list',
    },
  ];

  @override
  void initState() {
    super.initState();
    _optionFocusNodes = List.generate(
      _viewOptions.length,
      (_) => FocusNode(skipTraversal: true),
    );
    _loadCurrentView();
    _initializeGamepadNavigation();
  }

  /// Synchronizes the UI state with the persistent library visualization preference.
  Future<void> _loadCurrentView() async {
    try {
      final viewMode = await ConfigRepository.getGameViewMode();
      if (mounted) {
        setState(() {
          _currentView = viewMode;
          // Synchronize the selection index with the active view mode.
          _selectedIndex = _currentView == 'grid' ? 0 : 1;
        });
      }
    } catch (e) {
      _log.e('Failed to resolve persistent view mode: $e');
      if (mounted) {
        setState(() {
          _currentView = 'list'; // Fallback to safe default.
          _selectedIndex = 1;
        });
      }
    }
  }

  /// Persists the selected visualization mode and notifies the user.
  Future<void> _saveViewMode(String viewMode) async {
    try {
      await ConfigRepository.updateGameViewMode(viewMode);
      if (mounted) {
        setState(() {
          _currentView = viewMode;
        });

        AppNotification.showNotification(
          context,
          'Game view changed to ${viewMode == 'grid' ? 'Grid' : 'List'}',
          type: NotificationType.success,
        );
      }
    } catch (e) {
      _log.e('Failed to persist view mode preference: $e');
      if (mounted) {
        AppNotification.showNotification(
          context,
          'Error saving game view mode',
          type: NotificationType.error,
        );
      }
    }
  }

  @override
  void dispose() {
    _gamepadNav.dispose();
    for (final node in _optionFocusNodes) {
      node.dispose();
    }
    super.dispose();
  }

  /// Configures the gamepad layer for specialized screen-level navigation.
  void _initializeGamepadNavigation() {
    _gamepadNav = GamepadNavigation(
      onNavigateUp: () => _navigateUp(),
      onNavigateDown: () => _navigateDown(),
      onSelectItem: () => _selectItem(),
      onBack: () => Navigator.of(context).pop(),
    );

    _gamepadNav.initialize();
    _gamepadNav.activate();
  }

  void _navigateUp() {
    setState(() {
      _selectedIndex =
          (_selectedIndex - 1 + _viewOptions.length) % _viewOptions.length;
    });
  }

  void _navigateDown() {
    setState(() {
      _selectedIndex = (_selectedIndex + 1) % _viewOptions.length;
    });
  }

  void _selectItem() {
    final selectedOption = _viewOptions[_selectedIndex];
    _saveViewMode(selectedOption['value']);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header Section: Branding and navigation escape.
            Row(
              children: [
                IconButton(
                  icon: const Icon(Symbols.arrow_back_rounded),
                  onPressed: () => Navigator.of(context).pop(),
                  tooltip: 'Back',
                ),
                const SizedBox(width: 12),
                Text(
                  'Game View Settings',
                  style: theme.textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 24),

            // Descriptive Context.
            Text(
              'Choose how games are displayed in the system view:',
              style: theme.textTheme.bodyLarge,
            ),
            const SizedBox(height: 24),

            // Visualization Options Selection Layer.
            Expanded(
              child: ListView.builder(
                itemCount: _viewOptions.length,
                itemBuilder: (context, index) {
                  final option = _viewOptions[index];
                  final isSelected = index == _selectedIndex;
                  final isCurrent = option['value'] == _currentView;

                  return Card(
                    color: isSelected
                        ? theme.colorScheme.primary.withValues(alpha: 0.1)
                        : theme.colorScheme.surface,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                      side: BorderSide(
                        color: isSelected
                            ? theme.colorScheme.primary
                            : theme.colorScheme.surface,
                        width: isSelected ? 1 : 0,
                      ),
                    ),
                    margin: const EdgeInsets.only(bottom: 12),
                    child: InkWell(
                      canRequestFocus: false,
                      focusColor: Colors.transparent,
                      hoverColor: Colors.transparent,
                      highlightColor: Colors.transparent,
                      splashColor: Colors.transparent,
                      focusNode: _optionFocusNodes[index],
                      onTap: () {
                        SfxService().playNavSound();
                        _saveViewMode(option['value']);
                      },
                      borderRadius: BorderRadius.circular(12),
                      child: Padding(
                        padding: const EdgeInsets.all(16.0),
                        child: Row(
                          children: [
                            // Visualization Branding/Iconography.
                            SizedBox(
                              width: 48,
                              height: 48,
                              child: Image.asset(
                                'assets/images/icons/${option['icon']}',
                                color: isSelected
                                    ? theme.colorScheme.primary
                                    : theme.colorScheme.onSurface.withValues(
                                        alpha: 0.7,
                                      ),
                              ),
                            ),
                            const SizedBox(width: 16),

                            // Descriptive Labeling.
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Row(
                                    children: [
                                      Text(
                                        option['title'],
                                        style: theme.textTheme.titleMedium
                                            ?.copyWith(
                                              fontWeight: FontWeight.bold,
                                              color: isSelected
                                                  ? theme.colorScheme.primary
                                                  : theme.colorScheme.onSurface,
                                            ),
                                      ),
                                      if (isCurrent) ...[
                                        const SizedBox(width: 8),
                                        Icon(
                                          Symbols.check_circle_rounded,
                                          size: 20,
                                          color: theme.colorScheme.primary,
                                        ),
                                      ],
                                    ],
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    option['subtitle'],
                                    style: theme.textTheme.bodyMedium?.copyWith(
                                      color: isSelected
                                          ? theme.colorScheme.primary
                                                .withValues(alpha: 0.8)
                                          : theme.colorScheme.onSurface
                                                .withValues(alpha: 0.6),
                                    ),
                                  ),
                                ],
                              ),
                            ),

                            // Visual Radio Sentinel.
                            Container(
                              width: 20,
                              height: 20,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                border: Border.all(
                                  color: isSelected
                                      ? theme.colorScheme.primary
                                      : theme.colorScheme.onSurface.withValues(
                                          alpha: 0.3,
                                        ),
                                  width: 2,
                                ),
                              ),
                              child: isCurrent
                                  ? Center(
                                      child: Container(
                                        width: 10,
                                        height: 10,
                                        decoration: BoxDecoration(
                                          shape: BoxShape.circle,
                                          color: theme.colorScheme.primary,
                                        ),
                                      ),
                                    )
                                  : null,
                            ),
                          ],
                        ),
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
