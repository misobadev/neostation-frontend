import 'dart:io';
import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:file_picker/file_picker.dart';
import 'package:neostation/l10n/app_locale.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:neostation/services/sfx_service.dart';
import 'package:provider/provider.dart';
import '../models/core_emulator_model.dart';
import '../models/standalone_emulator_model.dart';
import '../models/system_model.dart';
import '../providers/sqlite_config_provider.dart';
import '../providers/sqlite_database_provider.dart';
import '../repositories/system_repository.dart';
import '../repositories/emulator_repository.dart';
import '../services/config_service.dart';
import 'package:neostation/services/logger_service.dart';
import '../utils/gamepad_nav.dart';
import '../services/game_service.dart' show GamepadNavigationManager;
import '../utils/centered_scroll_controller.dart';
import 'package:path/path.dart' as path;

import 'custom_notification.dart';
import 'package:neostation/widgets/custom_toggle_switch.dart';
import '../widgets/shaders/shader_gif_widget.dart';
import '../utils/image_utils.dart';
import '../widgets/core_footer.dart';
import '../services/permission_service.dart';
import '../widgets/tv_directory_picker.dart';

/// Steam-style dialog to configure emulators/cores for a system
class SystemEmulatorSettingsDialog extends StatefulWidget {
  final SystemModel system;

  const SystemEmulatorSettingsDialog({super.key, required this.system});

  @override
  State<SystemEmulatorSettingsDialog> createState() =>
      _SystemEmulatorSettingsDialogState();
}

class _SystemEmulatorSettingsDialogState
    extends State<SystemEmulatorSettingsDialog> {
  List<EmulatorListItem> _displayItems = []; // Grouped items for display
  int _totalEmulators = 0;
  bool _isLoading = true;
  String? _errorMessage;
  int _selectedIndex = 0;
  late GamepadNavigation _gamepadNav; // Now includes keyboard on desktop
  late CenteredScrollController _centeredScrollController;
  late ScrollController _generalScrollController;

  static final _log = LoggerService.instance;

  // Tabs state
  int _currentTab = 0; // Default to General tab
  int _generalIndex = 0; // Index for General tab items
  int _appearanceIndex = 0; // Index for Appearance tab items
  // 0: Prefer filename, 1: Hide ext, 2: (), 3: [], 4: Logo, 5: Recursive?
  late int _totalGeneralItems;
  late List<GlobalKey> _generalItemKeys;
  late List<GlobalKey> _appearanceItemKeys;

  late SystemModel _system;

  // Focus nodes for arrow key navigation blocking
  late final FocusNode _headerCloseButtonFocusNode;
  late final FocusNode _footerCloseButtonFocusNode;
  late List<FocusNode> _coreItemFocusNodes;
  late List<FocusNode> _setDefaultButtonFocusNodes;
  List<MenuController> _menuControllers = [];
  List<FocusNode> _menuFocusNodes = [];
  final Map<int, List<FocusNode>> _menuCoresFocusNodes =
      {}; // index -> list of FocusNodes for cores
  int _openMenuIndex = -1; // Index of the open MenuAnchor, -1 if none

  @override
  void initState() {
    super.initState();

    // Initialize focus nodes for arrow key navigation blocking
    _headerCloseButtonFocusNode = FocusNode(skipTraversal: true);
    _footerCloseButtonFocusNode = FocusNode(skipTraversal: true);
    _coreItemFocusNodes = [];
    _setDefaultButtonFocusNodes = [];

    // Initialize the centered scroll controller
    _centeredScrollController = CenteredScrollController(
      centerPosition: 0.5, // Center towards the top of the viewport
    );

    // Initialize local system state
    _system = widget.system;
    _totalGeneralItems =
        (_system.folderName == 'all' || _system.folderName == 'android')
        ? 5
        : 6;

    _generalScrollController = ScrollController();
    _generalItemKeys = List.generate(
      _totalGeneralItems,
      (index) => GlobalKey(
        debugLabel:
            'general_item_${_system.folderName}_${index}_${identityHashCode(this)}',
      ),
    );

    _appearanceItemKeys = List.generate(
      2,
      (index) => GlobalKey(
        debugLabel:
            'appearance_item_${_system.folderName}_${index}_${identityHashCode(this)}',
      ),
    );

    _loadCores();
    _initializeGamepad();
  }

  @override
  void dispose() {
    _cleanupGamepad();
    _centeredScrollController.dispose();
    _generalScrollController.dispose();
    // Dispose focus nodes
    _headerCloseButtonFocusNode.dispose();
    _footerCloseButtonFocusNode.dispose();
    for (final node in _coreItemFocusNodes) {
      node.dispose();
    }
    for (final node in _setDefaultButtonFocusNodes) {
      node.dispose();
    }
    for (final node in _menuFocusNodes) {
      node.dispose();
    }
    for (final nodesList in _menuCoresFocusNodes.values) {
      for (final node in nodesList) {
        node.dispose();
      }
    }
    super.dispose();
  }

  void _initializeGamepad() {
    _gamepadNav = GamepadNavigation(
      onNavigateUp: _navigateUp,
      onNavigateDown: _navigateDown,
      onPreviousTab: _previousTab,
      onNextTab: _nextTab,
      onSelectItem: _handleSelectItem,
      onBack: _closeDialog,
    );

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _gamepadNav.initialize();
      GamepadNavigationManager.pushLayer(
        'system_emulator_settings_dialog',
        onActivate: () => _gamepadNav.activate(),
        onDeactivate: () => _gamepadNav.deactivate(),
      );
    });
  }

  void _cleanupGamepad() {
    GamepadNavigationManager.popLayer('system_emulator_settings_dialog');
    _gamepadNav.dispose();
  }

  void _navigateUp() {
    if (_openMenuIndex != -1) {
      final focusedContext = FocusManager.instance.primaryFocus?.context;
      if (focusedContext != null) {
        Actions.invoke(
          focusedContext,
          const DirectionalFocusIntent(TraversalDirection.up),
        );
      }
      return;
    }
    if (_currentTab == 1) {
      if (_totalEmulators == 0) return;

      int newIndex = _selectedIndex;
      // Find previous selectable item (skip headers)
      for (int i = 1; i <= _totalEmulators; i++) {
        final candidate = (newIndex - i + _totalEmulators) % _totalEmulators;
        if (_displayItems[candidate] is! EmulatorHeaderItem) {
          setState(() {
            _selectedIndex = candidate;
          });
          break;
        }
      }

      _centeredScrollController.updateSelectedIndex(_selectedIndex);
      _scrollToSelected();
    } else if (_currentTab == 0) {
      setState(() {
        _generalIndex =
            (_generalIndex - 1 + _totalGeneralItems) % _totalGeneralItems;
      });
      _scrollToGeneralSelected();
    } else if (_currentTab == 2) {
      setState(() {
        _appearanceIndex = (_appearanceIndex - 1 + 2) % 2;
      });
      _scrollToAppearanceSelected();
    }
  }

  void _navigateDown() {
    if (_openMenuIndex != -1) {
      final focusedContext = FocusManager.instance.primaryFocus?.context;
      if (focusedContext != null) {
        Actions.invoke(
          focusedContext,
          const DirectionalFocusIntent(TraversalDirection.down),
        );
      }
      return;
    }
    if (_currentTab == 1) {
      if (_totalEmulators == 0) return;

      int newIndex = _selectedIndex;
      // Find next selectable item (skip headers)
      for (int i = 1; i <= _totalEmulators; i++) {
        final candidate = (newIndex + i) % _totalEmulators;
        if (_displayItems[candidate] is! EmulatorHeaderItem) {
          setState(() {
            _selectedIndex = candidate;
          });
          break;
        }
      }

      _centeredScrollController.updateSelectedIndex(_selectedIndex);
      _scrollToSelected();
    } else if (_currentTab == 0) {
      setState(() {
        _generalIndex = (_generalIndex + 1) % _totalGeneralItems;
      });
      _scrollToGeneralSelected();
    } else if (_currentTab == 2) {
      setState(() {
        _appearanceIndex = (_appearanceIndex + 1) % 2;
      });
      _scrollToAppearanceSelected();
    }
  }

  void _previousTab() {
    List<int> availableTabs = [0, 2];
    if (widget.system.folderName != 'all' &&
        widget.system.folderName != 'android') {
      availableTabs = [0, 1, 2];
    }

    int currentIndex = availableTabs.indexOf(_currentTab);
    int prevIndex =
        (currentIndex - 1 + availableTabs.length) % availableTabs.length;
    setState(() {
      _currentTab = availableTabs[prevIndex];
    });
  }

  void _nextTab() {
    List<int> availableTabs = [0, 2];
    if (widget.system.folderName != 'all' &&
        widget.system.folderName != 'android') {
      availableTabs = [0, 1, 2];
    }

    int currentIndex = availableTabs.indexOf(_currentTab);
    int nextIndex = (currentIndex + 1) % availableTabs.length;
    setState(() {
      _currentTab = availableTabs[nextIndex];
    });
  }

  void _handleSelectItem() {
    if (_openMenuIndex != -1) {
      final focusedContext = FocusManager.instance.primaryFocus?.context;
      if (focusedContext != null) {
        Actions.invoke(focusedContext, const ActivateIntent());
      }
      return;
    }
    if (_currentTab == 1) {
      _setSelectedAsDefault();
    } else if (_currentTab == 0) {
      if (_generalIndex == 0) {
        _togglePreferFileName(!_system.preferFileName);
      } else if (_generalIndex == 1) {
        _toggleHideExtension(!_system.hideExtension);
      } else if (_generalIndex == 2) {
        _toggleHideParentheses(!_system.hideParentheses);
      } else if (_generalIndex == 3) {
        _toggleHideBrackets(!_system.hideBrackets);
      } else if (_generalIndex == 4) {
        _toggleHideLogo(!_system.hideLogo);
      } else if (_generalIndex == 5 &&
          widget.system.folderName != 'all' &&
          widget.system.folderName != 'android') {
        _toggleRecursiveScan(!_system.recursiveScan);
      }
    } else if (_currentTab == 2) {
      if (_appearanceIndex == 0) {
        _pickAndSaveImage();
      } else if (_appearanceIndex == 1) {
        _pickAndSaveLogoImage();
      }
    }
  }

  Future<void> _toggleRecursiveScan(bool value) async {
    setState(() {
      _system = _system.copyWith(recursiveScan: value);
    });

    // 1. Save to DB
    await SystemRepository.setRecursiveScan(widget.system.id!, value);

    if (mounted) {
      AppNotification.showNotification(
        context,
        (value
                ? AppLocale.recursiveScanEnabled
                : AppLocale.recursiveScanDisabled)
            .getString(context)
            .replaceFirst('{name}', widget.system.realName),
        type: NotificationType.info,
        notificationId: 'system_scan_${widget.system.id}',
      );
    }

    // 2. Trigger automatic scan (Silent)
    try {
      // Ensure we use the updated recursiveScan flag for the scan
      final systemToScan = widget.system.copyWith(recursiveScan: value);

      if (!mounted) return;

      // Perform silent scan via provider
      final summary = await context
          .read<SqliteConfigProvider>()
          .rescanSystemSilent(systemToScan);

      // 3. Refresh current system's game list in the provider
      if (mounted) {
        // Refresh current system's game list
        context.read<SqliteDatabaseProvider>().loadGamesForSystem(
          systemToScan.folderName,
        );
      }

      if (mounted) {
        String message = 'Scan complete for ${widget.system.realName}';
        if (summary.hasChanges) {
          message += ': ';
          if (summary.added > 0) message += '${summary.added} added';
          if (summary.added > 0 && summary.removed > 0) message += ', ';
          if (summary.removed > 0) message += '${summary.removed} removed';
        } else {
          message += '. No changes found.';
        }

        AppNotification.showNotification(
          context,
          message,
          type: summary.hasChanges
              ? NotificationType.success
              : NotificationType.info,
          notificationId: 'system_scan_${widget.system.id}',
        );
      }
    } catch (e) {
      _log.e('Error during auto-scan: $e');
      if (mounted) {
        AppNotification.showNotification(
          context,
          AppLocale.errorScanningSystem
              .getString(context)
              .replaceFirst('{error}', e.toString()),
          type: NotificationType.error,
          notificationId: 'system_scan_${widget.system.id}',
        );
      }
    }
  }

  Future<void> _togglePreferFileName(bool value) async {
    setState(() => _system = _system.copyWith(preferFileName: value));
    await SystemRepository.setPreferFileName(widget.system.id!, value);
    if (mounted) {
      await context.read<SqliteConfigProvider>().refreshSystem(_system);
      if (!mounted) return;
      context.read<SqliteDatabaseProvider>().loadGamesForSystem(
        widget.system.folderName,
      );
      AppNotification.showNotification(
        context,
        value
            ? AppLocale.romFileNamesUsed.getString(context)
            : AppLocale.scrapedTitlesUsed.getString(context),
        type: NotificationType.info,
      );
    }
  }

  Future<void> _toggleHideExtension(bool value) async {
    setState(() => _system = _system.copyWith(hideExtension: value));
    await SystemRepository.setHideExtension(widget.system.id!, value);
    if (mounted) {
      await context.read<SqliteConfigProvider>().refreshSystem(_system);
      if (!mounted) return;
      context.read<SqliteDatabaseProvider>().loadGamesForSystem(
        widget.system.folderName,
      );
      AppNotification.showNotification(
        context,
        (value ? AppLocale.gameExtensionsHidden : AppLocale.gameExtensionsShown)
            .getString(context),
        type: NotificationType.info,
      );
    }
  }

  Future<void> _toggleHideParentheses(bool value) async {
    setState(() => _system = _system.copyWith(hideParentheses: value));
    await SystemRepository.setHideParentheses(widget.system.id!, value);
    if (mounted) {
      await context.read<SqliteConfigProvider>().refreshSystem(_system);
      if (!mounted) return;
      context.read<SqliteDatabaseProvider>().loadGamesForSystem(
        widget.system.folderName,
      );
      AppNotification.showNotification(
        context,
        (value ? AppLocale.parenthesesHidden : AppLocale.parenthesesShown)
            .getString(context),
        type: NotificationType.info,
      );
    }
  }

  Future<void> _toggleHideBrackets(bool value) async {
    setState(() => _system = _system.copyWith(hideBrackets: value));
    await SystemRepository.setHideBrackets(widget.system.id!, value);
    if (mounted) {
      await context.read<SqliteConfigProvider>().refreshSystem(_system);
      if (!mounted) return;
      context.read<SqliteDatabaseProvider>().loadGamesForSystem(
        widget.system.folderName,
      );
      AppNotification.showNotification(
        context,
        (value ? AppLocale.bracketsHidden : AppLocale.bracketsShown).getString(
          context,
        ),
        type: NotificationType.info,
      );
    }
  }

  Future<void> _toggleHideLogo(bool value) async {
    setState(() => _system = _system.copyWith(hideLogo: value));
    await SystemRepository.setHideLogo(widget.system.id!, value);
    if (mounted) {
      await context.read<SqliteConfigProvider>().refreshSystem(_system);
      if (!mounted) return;
      AppNotification.showNotification(
        context,
        (value ? AppLocale.systemLogoHidden : AppLocale.systemLogoShown)
            .getString(context),
        type: NotificationType.info,
      );
    }
  }

  void _scrollToSelected({bool animate = true}) {
    _centeredScrollController.scrollToIndex(
      _selectedIndex,
      immediate: !animate,
    );
  }

  void _scrollToGeneralSelected() {
    final key = _generalItemKeys[_generalIndex];
    if (key.currentContext != null) {
      Scrollable.ensureVisible(
        key.currentContext!,
        alignment: 0.5,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeInOut,
      );
    }
  }

  void _scrollToAppearanceSelected() {
    final key = _appearanceItemKeys[_appearanceIndex];
    if (key.currentContext != null) {
      Scrollable.ensureVisible(
        key.currentContext!,
        alignment: 0.5,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeInOut,
      );
    }
  }

  void _setSelectedAsDefault() {
    if (_totalEmulators == 0 || _selectedIndex >= _totalEmulators) return;

    final item = _displayItems[_selectedIndex];
    if (item is EmulatorCoreItem) {
      _setAsDefault(item.core);
    } else if (item is EmulatorStandaloneItem) {
      final isConfigured = Platform.isAndroid
          ? item.isInstalled
          : item.standalone.isConfigured;
      if (isConfigured) {
        _setStandaloneAsDefault(item.standalone);
      }
    } else if (item is EmulatorGroupedCoreItem) {
      // Check if disabled (using same logic as UI)
      final isDisabled = Platform.isAndroid
          ? !item.isInstalled
          : !item.retroArchConfigured;

      if (!isDisabled && _selectedIndex < _menuControllers.length) {
        _menuControllers[_selectedIndex].open();
      }
    }
  }

  void _closeDialog() {
    // Limpiar gamepad antes de cerrar
    if (_openMenuIndex != -1) {
      if (_openMenuIndex < _menuControllers.length) {
        _menuControllers[_openMenuIndex].close();
      }
      return;
    }
    _cleanupGamepad();
    Navigator.of(context).pop();
  }

  Future<void> _loadCores() async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      if (widget.system.id == null) {
        throw Exception('System ID is null');
      }

      // Fetch fresh system settings to ensure we have custom logos/settings
      try {
        final freshSystem = await SystemRepository.getSystemByFolderName(
          widget.system.folderName,
        );
        if (freshSystem != null) _system = freshSystem;
      } catch (e) {
        _log.w(
          'System not found in DB: ${widget.system.folderName}. Using passed model.',
        );
        _system = widget.system;
      }

      // Load both cores and standalone emulators
      final cores = await EmulatorRepository.getCoresBySystemId(
        widget.system.id!,
      );
      final standalonesData =
          await EmulatorRepository.getStandaloneEmulatorsBySystemId(
            widget.system.id!,
          );
      final standalones = standalonesData
          .map((e) => StandaloneEmulatorModel.fromMap(e))
          .toList();

      // Setup grouped items for display
      final displayItems = <EmulatorListItem>[];

      // Check if RetroArch is configured (for desktop platforms)
      bool retroArchConfigured = false;
      String? retroArchPath;
      if (!Platform.isAndroid) {
        try {
          final detectedEmus =
              await EmulatorRepository.getUserDetectedEmulators();
          if (detectedEmus.containsKey('RetroArch')) {
            retroArchConfigured = true;
            retroArchPath = detectedEmus['RetroArch']?.path;
          }
        } catch (e) {
          _log.e('Error checking RetroArch configuration: $e');
        }
      }

      // Group cores by variant (Package name on Android, generic on Desktop)
      final groupedCores = <String, List<CoreEmulatorModel>>{};
      for (final core in cores) {
        String groupKey;
        if (Platform.isAndroid) {
          groupKey = core.androidPackageName ?? 'com.retroarch';

          // Heuristic fallback if package name is missing but uniqueId exists
          if (core.androidPackageName == null ||
              core.androidPackageName!.isEmpty) {
            final uid = core.uniqueId;
            if (uid.contains('.ra64.')) {
              groupKey = 'com.retroarch.aarch64';
            } else if (uid.contains('.ra32.')) {
              groupKey = 'com.retroarch.ra32';
            } else if (uid.contains('.ra.')) {
              groupKey = 'com.retroarch';
            }
          }
        } else {
          groupKey = 'RetroArch'; // Unified on desktop
        }

        if (!groupedCores.containsKey(groupKey)) {
          groupedCores[groupKey] = [];
        }
        groupedCores[groupKey]!.add(core);
      }

      // 1. Add grouped RetroArch entries
      groupedCores.forEach((groupKey, groupCores) {
        String groupName = 'RetroArch';
        if (groupKey == 'com.retroarch.aarch64') {
          groupName = 'RetroArch 64';
        } else if (groupKey == 'com.retroarch.ra32') {
          groupName = 'RetroArch 32';
        } else if (groupKey == 'com.retroarch.a' ||
            groupKey == 'com.retroarch.plus') {
          groupName = 'RetroArch Plus';
        }

        // Check if ANY core in this group is installed (on Android)
        bool isInstalled = groupCores.any((c) => c.isInstalled);

        displayItems.add(
          EmulatorGroupedCoreItem(
            groupName: groupName,
            packageName: groupKey,
            cores: groupCores,
            isInstalled: isInstalled,
            retroArchConfigured: retroArchConfigured,
            retroArchPath: retroArchPath,
          ),
        );
      });

      // 2. Add Standalone emulators
      for (final standalone in standalones) {
        final isInstalled = await standalone.isInstalled;
        displayItems.add(
          EmulatorStandaloneItem(standalone, isInstalled: isInstalled),
        );
      }

      setState(() {
        _displayItems = displayItems;
        _totalEmulators = _displayItems.length; // Now strictly UI items

        // Find selected index based on default
        _selectedIndex = 0;

        // Strategy: find the item that corresponds to the default
        int foundIndex = -1;

        // We iterate _displayItems to find the match
        for (int i = 0; i < _displayItems.length; i++) {
          final item = _displayItems[i];

          if (item is EmulatorStandaloneItem) {
            if (item.standalone.isUserDefault == true) {
              foundIndex = i;
              break;
            }
          } else if (item is EmulatorGroupedCoreItem) {
            if (item.cores.any((c) => c.isDefault)) {
              foundIndex = i;
              break;
            }
          } else if (item is EmulatorCoreItem) {
            if (item.core.isDefault) {
              foundIndex = i;
              break;
            }
          }
        }

        if (foundIndex != -1) {
          _selectedIndex = foundIndex;
        } else if (_displayItems.isNotEmpty) {
          for (int i = 0; i < _displayItems.length; i++) {
            if (_displayItems[i] is! EmulatorHeaderItem) {
              _selectedIndex = i;
              break;
            }
          }
        }
      });

      // Update focus nodes for the new emulators list
      _updateFocusNodes();

      // Inicializar el controller después de cargar emulators
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _centeredScrollController.initialize(
          context: context,
          initialIndex: _selectedIndex,
          totalItems: _totalEmulators,
        );
        // Actualizar el total de items después de inicializar
        _centeredScrollController.updateTotalItems(_totalEmulators);
      });
    } catch (e, stackTrace) {
      _log.e('ERROR loading cores: $e');
      _log.e('StackTrace: $stackTrace');

      setState(() {
        _errorMessage = 'Error loading cores: $e';
      });
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  /// Update focus nodes when cores list changes
  void _updateFocusNodes() {
    // Dispose old focus nodes
    for (final node in _coreItemFocusNodes) {
      node.dispose();
    }
    for (final node in _setDefaultButtonFocusNodes) {
      node.dispose();
    }

    // Create new focus nodes for both cores and standalones
    _coreItemFocusNodes = List.generate(
      _totalEmulators,
      (_) => FocusNode(skipTraversal: true),
    );
    _setDefaultButtonFocusNodes = List.generate(
      _totalEmulators,
      (_) => FocusNode(skipTraversal: true),
    );

    // Initialize MenuControllers and FocusNodes
    _menuControllers = List.generate(_totalEmulators, (_) => MenuController());
    _menuFocusNodes = List.generate(_totalEmulators, (_) => FocusNode());

    // Dispose and clear core focus nodes
    for (final nodesList in _menuCoresFocusNodes.values) {
      for (final node in nodesList) {
        node.dispose();
      }
    }
    _menuCoresFocusNodes.clear();

    // Create new focus nodes for cores within menu
    for (int i = 0; i < _displayItems.length; i++) {
      final item = _displayItems[i];
      if (item is EmulatorGroupedCoreItem) {
        _menuCoresFocusNodes[i] = List.generate(
          item.cores.length,
          (_) => FocusNode(),
        );
      }
    }
  }

  Future<void> _setAsDefault(CoreEmulatorModel core) async {
    try {
      if (widget.system.id == null) {
        throw Exception('System ID is null');
      }

      await EmulatorRepository.setDefaultCore(
        widget.system.id!,
        core.uniqueId,
        core.osId,
      );

      // Reload cores to refresh UI and grouping
      await _loadCores();

      if (mounted) {
        AppNotification.showNotification(
          context,
          AppLocale.coreSetAsDefault
              .getString(context)
              .replaceFirst('{name}', core.name),
          type: NotificationType.success,
        );
      }
    } catch (e, stackTrace) {
      _log.e('Error setting default core: $e');
      _log.e('   Stack trace: $stackTrace');

      // Show user-friendly error message
      if (mounted) {
        AppNotification.showNotification(
          context,
          AppLocale.errorSettingDefault
              .getString(context)
              .replaceFirst('{name}', core.name),
          type: NotificationType.error,
        );
      }
    }
  }

  Future<void> _setStandaloneAsDefault(
    StandaloneEmulatorModel standalone,
  ) async {
    try {
      if (widget.system.id == null) {
        throw Exception('System ID is null');
      }

      await EmulatorRepository.setDefaultStandaloneEmulator(
        widget.system.id!,
        standalone.uniqueIdentifier,
      );

      // Reload cores to refresh UI and grouping
      await _loadCores();

      if (mounted) {
        AppNotification.showNotification(
          context,
          AppLocale.coreSetAsDefault
              .getString(context)
              .replaceFirst('{name}', standalone.name),
          type: NotificationType.success,
        );
      }
    } catch (e, stackTrace) {
      _log.e('Error setting default standalone emulator: $e');
      _log.e('   Stack trace: $stackTrace');

      // Show user-friendly error message
      if (mounted) {
        AppNotification.showNotification(
          context,
          AppLocale.errorSettingDefault
              .getString(context)
              .replaceFirst('{name}', standalone.name),
          type: NotificationType.error,
        );
      }
    }
  }

  Future<void> _configureStandalonePath(
    StandaloneEmulatorModel standalone,
  ) async {
    try {
      // Determine executable extension based on platform
      final extension = Platform.isWindows ? 'exe' : null;

      // Open file picker
      final result = await FilePicker.platform.pickFiles(
        dialogTitle: AppLocale.selectEmulatorExecutable
            .getString(context)
            .replaceFirst('{name}', standalone.name),
        type: extension != null ? FileType.custom : FileType.any,
        allowedExtensions: extension != null ? [extension] : null,
        lockParentWindow: true,
      );

      if (result == null || result.files.isEmpty) {
        return; // User cancelled
      }

      final selectedPath = result.files.first.path;
      if (selectedPath == null) {
        return;
      }

      // Verify file exists
      bool exists = false;
      if (Platform.isMacOS && selectedPath.endsWith('.app')) {
        exists = await Directory(selectedPath).exists();
      } else {
        exists = await File(selectedPath).exists();
      }

      if (!exists) {
        if (mounted) {
          AppNotification.showNotification(
            context,
            AppLocale.selectedFileNotExist.getString(context),
            type: NotificationType.error,
          );
        }
        return;
      }

      // Save path to database
      await EmulatorRepository.setStandaloneEmulatorPath(
        standalone.uniqueIdentifier,
        selectedPath,
      );

      // Reload the full dialog to update UI (same as RetroArch)
      await _loadCores();

      if (mounted) {
        AppNotification.showNotification(
          context,
          AppLocale.emulatorPathConfigured
              .getString(context)
              .replaceFirst('{name}', standalone.name),
          type: NotificationType.success,
        );
      }
    } catch (e) {
      if (mounted) {
        AppNotification.showNotification(
          context,
          AppLocale.errorConfiguringPath
              .getString(context)
              .replaceFirst('{error}', e.toString()),
          type: NotificationType.error,
        );
      }
    }
  }

  /// Configure RetroArch executable path on desktop platforms
  Future<void> _configureRetroArchPath() async {
    try {
      // Open file picker for RetroArch executable
      FilePickerResult? result = await FilePicker.platform.pickFiles(
        type: Platform.isWindows ? FileType.custom : FileType.any,
        allowedExtensions: Platform.isWindows ? ['exe'] : null,
        dialogTitle: AppLocale.selectRetroArchExe.getString(context),
      );

      if (result == null || result.files.single.path == null) {
        return; // User cancelled
      }

      final selectedPath = result.files.single.path!;

      // Verify the file exists
      bool exists = false;
      if (Platform.isMacOS && selectedPath.endsWith('.app')) {
        exists = await Directory(selectedPath).exists();
      } else {
        exists = await File(selectedPath).exists();
      }

      if (!exists) {
        if (mounted) {
          AppNotification.showNotification(
            context,
            AppLocale.selectedFileNotExist.getString(context),
            type: NotificationType.error,
          );
        }
        return;
      }

      // Save RetroArch path
      await EmulatorRepository.saveDetectedEmulatorPath(
        emulatorName: 'RetroArch',
        emulatorPath: selectedPath,
      );

      // Refresh the dialog to update UI
      await _loadCores();

      if (mounted) {
        AppNotification.showNotification(
          context,
          AppLocale.retroArchPathConfigured.getString(context),
          type: NotificationType.success,
        );
      }
    } catch (e) {
      if (mounted) {
        AppNotification.showNotification(
          context,
          AppLocale.errorConfiguringRetroArchPath
              .getString(context)
              .replaceFirst('{error}', e.toString()),
          type: NotificationType.error,
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: EdgeInsets.symmetric(horizontal: 16.r, vertical: 16.r),
      child: Container(
        constraints: BoxConstraints(maxWidth: 640.r, maxHeight: 480.r),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surface,
          borderRadius: BorderRadius.circular(12.r),
          border: Border.all(
            color: Theme.of(context).colorScheme.outline.withValues(alpha: 0.1),
          ),
          boxShadow: [
            BoxShadow(
              color: Theme.of(
                context,
              ).colorScheme.shadow.withValues(alpha: 0.5),
              blurRadius: 10.r,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _buildHeader(),
            _buildTabsHeader(),
            Expanded(
              child: _currentTab == 0
                  ? _buildGeneralTab()
                  : _currentTab == 1
                  ? (_isLoading
                        ? _buildLoadingState()
                        : _errorMessage != null
                        ? _buildErrorState()
                        : _buildEmulatorsTab())
                  : _buildAppearanceTab(),
            ),
            _buildFooter(),
          ],
        ),
      ),
    );
  }

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
      decoration: BoxDecoration(
        color: Colors.transparent,
        borderRadius: BorderRadius.only(
          topLeft: Radius.circular(12.r),
          topRight: Radius.circular(12.r),
        ),
      ),
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
          if (widget.system.folderName != 'all' &&
              widget.system.folderName != 'android') ...[
            SizedBox(width: 16.r),
            _buildTabItem(1, AppLocale.emulators.getString(context)),
          ],
          SizedBox(width: 16.r),
          _buildTabItem(2, AppLocale.appearance.getString(context)),
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
        setState(() => _currentTab = index);
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

  Widget _buildGeneralTab() {
    return ListView(
      controller: _generalScrollController,
      padding: EdgeInsets.symmetric(horizontal: 12.r, vertical: 6.r),
      children: [_buildGeneralSettingsSection()],
    );
  }

  Widget _buildAppearanceTab() {
    return ListView(
      padding: EdgeInsets.symmetric(horizontal: 12.r, vertical: 6.r),
      children: [_buildSystemImagesSection()],
    );
  }

  Widget _buildSystemImagesSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: EdgeInsets.only(bottom: 8.r),
          child: Text(
            AppLocale.systemImages.getString(context),
            style: TextStyle(
              fontSize: 12.r,
              fontWeight: FontWeight.bold,
              color: Theme.of(context).colorScheme.onSurface,
            ),
          ),
        ),
        _buildImagePickerItem(
          index: 0,
          key: _appearanceItemKeys[0],
          title: AppLocale.backgroundImage.getString(context),
          subtitle: AppLocale.backgroundImageSubtitle.getString(context),
          currentPath:
              _system.customBackgroundPath ?? _system.backgroundImage ?? '',
          hasCustom:
              _system.customBackgroundPath != null &&
              _system.customBackgroundPath!.isNotEmpty,
          onPick: _pickAndSaveImage,
          onReset: _resetImage,
        ),
        SizedBox(height: 6.r),
        _buildImagePickerItem(
          index: 1,
          key: _appearanceItemKeys[1],
          title: AppLocale.logoImage.getString(context),
          subtitle: AppLocale.logoImageSubtitle.getString(context),
          currentPath: _system.customLogoPath ?? '',
          hasCustom:
              _system.customLogoPath != null &&
              _system.customLogoPath!.isNotEmpty,
          onPick: _pickAndSaveLogoImage,
          onReset: _resetLogoImage,
        ),
      ],
    );
  }

  Widget _buildImagePickerItem({
    required int index,
    required Key key,
    required String title,
    required String subtitle,
    required String currentPath,
    required bool hasCustom,
    required VoidCallback onPick,
    required VoidCallback onReset,
  }) {
    final bool isFocused = _currentTab == 2 && _appearanceIndex == index;
    final theme = Theme.of(context);

    return Container(
      key: key,
      height: 50.r,
      padding: EdgeInsets.symmetric(horizontal: 12.r),
      decoration: BoxDecoration(
        color: isFocused
            ? theme.colorScheme.secondary.withValues(alpha: 0.1)
            : Colors.transparent,
        borderRadius: BorderRadius.circular(8.r),
        border: isFocused
            ? Border.all(
                color: theme.colorScheme.secondary.withValues(alpha: 0.5),
              )
            : null,
      ),
      child: Row(
        children: [
          // Preview (Small)
          Container(
            key: ValueKey('${currentPath}_${_system.imageVersion}'),
            width: 36.r,
            height: 36.r,
            clipBehavior: Clip.antiAlias,
            decoration: BoxDecoration(
              color: Colors.black26,
              borderRadius: BorderRadius.circular(4.r),
            ),
            child: currentPath.isEmpty
                ? Icon(
                    Symbols.image_not_supported_rounded,
                    size: 16.r,
                    color: Colors.white54,
                  )
                : _buildPreviewImage(currentPath),
          ),

          SizedBox(width: 12.r),
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    fontSize: 12.r,
                    fontWeight: FontWeight.w500,
                    color: theme.colorScheme.onSurface,
                  ),
                ),
                Text(
                  hasCustom
                      ? AppLocale.customImageSet.getString(context)
                      : subtitle,
                  style: TextStyle(
                    fontSize: 10.r,
                    color: hasCustom
                        ? theme.colorScheme.primary
                        : theme.colorScheme.onSurface.withValues(alpha: 0.6),
                    fontWeight: hasCustom ? FontWeight.bold : FontWeight.normal,
                  ),
                ),
              ],
            ),
          ),
          // Buttons (Small & Compact)
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              IconButton(
                onPressed: onPick,
                icon: Icon(Symbols.upload_file_rounded, size: 16.r),
                tooltip: AppLocale.upload.getString(context),
                padding: EdgeInsets.zero,
                constraints: BoxConstraints(minWidth: 24.r, minHeight: 24.r),
                color: theme.colorScheme.primary,
              ),
              if (hasCustom) ...[
                SizedBox(width: 4.r),
                IconButton(
                  onPressed: onReset,
                  icon: Icon(Symbols.delete_outline_rounded, size: 16.r),
                  tooltip: AppLocale.reset.getString(context),
                  padding: EdgeInsets.zero,
                  constraints: BoxConstraints(minWidth: 24.r, minHeight: 24.r),
                  color: theme.colorScheme.error,
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _pickAndSaveImage() async {
    try {
      String? pickedPath;

      if (Platform.isAndroid && await PermissionService.isTelevision()) {
        if (!mounted) return;
        pickedPath = await TvDirectoryPicker.showFilePicker(
          context,
          extensions: ['png', 'jpg', 'jpeg', 'webp', 'gif'],
        );
      } else {
        final result = await FilePicker.platform.pickFiles(
          type: FileType.custom,
          allowedExtensions: ['png', 'jpg', 'jpeg', 'webp', 'gif'],
          dialogTitle: 'Select Background Image',
          lockParentWindow: true,
        );
        pickedPath = result?.files.single.path;
      }

      if (pickedPath == null) return;

      final originalFile = File(pickedPath);
      if (!originalFile.existsSync()) return;

      final extension = path.extension(originalFile.path);
      const suffix = '_background';
      final fileName = '${_system.folderName}$suffix$extension';

      final userDataPath = await ConfigService.getUserDataPath();
      final targetDir = Directory(path.join(userDataPath, 'media', 'systems'));
      if (!targetDir.existsSync()) {
        await targetDir.create(recursive: true);
      }
      final targetPath = path.join(targetDir.path, fileName);

      // Copy file
      await originalFile.copy(targetPath);

      // Evict from cache to ensure immediate UI update
      await FileImage(File(targetPath)).evict();

      // Nuclear option: Clear global image cache to force reload
      PaintingBinding.instance.imageCache.clear();
      PaintingBinding.instance.imageCache.clearLiveImages();

      // Update DB
      await SystemRepository.setCustomImages(
        _system.id!,
        backgroundPath: targetPath,
      );

      // Update State
      setState(() {
        // Increment version to force rebuild in dialog preview
        final newVersion = (_system.imageVersion) + 1;

        _system = _system.copyWith(
          customBackgroundPath: targetPath,
          imageVersion: newVersion,
        );
      });

      if (mounted) {
        // Refresh provider to update UI everywhere
        final configProvider = context.read<SqliteConfigProvider>();
        await configProvider.refreshSystem(_system);
        if (!mounted) return;

        AppNotification.showNotification(
          context,
          AppLocale.imageUpdatedSuccess.getString(context),
          type: NotificationType.success,
        );
      }
    } catch (e) {
      if (mounted) {
        AppNotification.showNotification(
          context,
          AppLocale.errorUpdatingImage
              .getString(context)
              .replaceFirst('{error}', e.toString()),
          type: NotificationType.error,
        );
      }
    }
  }

  Future<void> _resetImage() async {
    try {
      await SystemRepository.setCustomImages(_system.id!, backgroundPath: '');

      // Clear global image cache to force reload
      PaintingBinding.instance.imageCache.clear();
      PaintingBinding.instance.imageCache.clearLiveImages();

      setState(() {
        _system = _system.copyWith(customBackgroundPath: '');
      });

      if (mounted) {
        // Refresh provider to update UI everywhere
        final configProvider = context.read<SqliteConfigProvider>();
        await configProvider.refreshSystem(_system);
        if (!mounted) return;

        AppNotification.showNotification(
          context,
          AppLocale.imageResetDefault.getString(context),
          type: NotificationType.info,
        );
      }
    } catch (e) {
      if (mounted) {
        AppNotification.showNotification(
          context,
          AppLocale.errorResettingImage
              .getString(context)
              .replaceFirst('{error}', e.toString()),
          type: NotificationType.error,
        );
      }
    }
  }

  Future<void> _pickAndSaveLogoImage() async {
    try {
      String? pickedPath;

      if (Platform.isAndroid && await PermissionService.isTelevision()) {
        if (!mounted) return;
        pickedPath = await TvDirectoryPicker.showFilePicker(
          context,
          extensions: ['png', 'jpg', 'jpeg', 'webp'],
        );
      } else {
        final result = await FilePicker.platform.pickFiles(
          type: FileType.custom,
          allowedExtensions: ['png', 'jpg', 'jpeg', 'webp'],
          dialogTitle: 'Select Logo Image',
          lockParentWindow: true,
        );
        pickedPath = result?.files.single.path;
      }

      if (pickedPath == null) return;

      final originalFile = File(pickedPath);
      if (!originalFile.existsSync()) return;

      final extension = path.extension(originalFile.path);
      final fileName = '${_system.folderName}_logo$extension';

      final userDataPath = await ConfigService.getUserDataPath();
      final targetDir = Directory(path.join(userDataPath, 'media', 'systems'));
      if (!targetDir.existsSync()) {
        await targetDir.create(recursive: true);
      }
      final targetPath = path.join(targetDir.path, fileName);

      await originalFile.copy(targetPath);

      PaintingBinding.instance.imageCache.clear();
      PaintingBinding.instance.imageCache.clearLiveImages();

      await SystemRepository.setCustomImages(_system.id!, logoPath: targetPath);

      setState(() {
        final newVersion = _system.imageVersion + 1;
        _system = _system.copyWith(
          customLogoPath: targetPath,
          imageVersion: newVersion,
        );
      });

      if (mounted) {
        final configProvider = context.read<SqliteConfigProvider>();
        await configProvider.refreshSystem(_system);
        if (!mounted) return;

        AppNotification.showNotification(
          context,
          AppLocale.imageUpdatedSuccess.getString(context),
          type: NotificationType.success,
        );
      }
    } catch (e) {
      if (mounted) {
        AppNotification.showNotification(
          context,
          AppLocale.errorUpdatingImage
              .getString(context)
              .replaceFirst('{error}', e.toString()),
          type: NotificationType.error,
        );
      }
    }
  }

  Future<void> _resetLogoImage() async {
    try {
      await SystemRepository.setCustomImages(_system.id!, logoPath: '');

      PaintingBinding.instance.imageCache.clear();
      PaintingBinding.instance.imageCache.clearLiveImages();

      setState(() {
        _system = _system.copyWith(customLogoPath: '');
      });

      if (mounted) {
        final configProvider = context.read<SqliteConfigProvider>();
        await configProvider.refreshSystem(_system);
        if (!mounted) return;

        AppNotification.showNotification(
          context,
          AppLocale.imageResetDefault.getString(context),
          type: NotificationType.info,
        );
      }
    } catch (e) {
      if (mounted) {
        AppNotification.showNotification(
          context,
          AppLocale.errorResettingImage
              .getString(context)
              .replaceFirst('{error}', e.toString()),
          type: NotificationType.error,
        );
      }
    }
  }

  Widget _buildPreviewImage(String path) {
    if (path.isEmpty) return const SizedBox.shrink();

    if (ImageUtils.isGif(path)) {
      return ShaderGifWidget(imagePath: path, key: ValueKey('preview_$path'));
    }

    if (File(path).existsSync()) {
      return Image.file(
        File(path),
        fit: BoxFit.cover,
        errorBuilder: (context, error, stackTrace) =>
            Icon(Symbols.broken_image_rounded, size: 16.r, color: Colors.white24),
      );
    } else if (path.startsWith('assets')) {
      return Image.asset(
        path,
        fit: BoxFit.cover,
        errorBuilder: (context, error, stackTrace) =>
            Icon(Symbols.broken_image_rounded, size: 16.r, color: Colors.white24),
      );
    } else {
      return Image.network(
        path,
        fit: BoxFit.cover,
        errorBuilder: (context, error, stackTrace) =>
            Icon(Symbols.broken_image_rounded, size: 16.r, color: Colors.white24),
      );
    }
  }

  Widget _buildGeneralSettingsSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildSwitchItem(
          index: 0,
          key: _generalItemKeys[0],
          title: AppLocale.alwaysShowRomName.getString(context),
          subtitle: AppLocale.alwaysShowRomNameSubtitle.getString(context),
          value: _system.preferFileName,
          onChanged: _togglePreferFileName,
        ),
        SizedBox(height: 4.r),
        _buildSwitchItem(
          index: 1,
          key: _generalItemKeys[1],
          title: AppLocale.hideExtension.getString(context),
          subtitle: AppLocale.hideExtensionSubtitle.getString(context),
          value: _system.hideExtension,
          onChanged: _toggleHideExtension,
        ),
        SizedBox(height: 4.r),
        _buildSwitchItem(
          index: 2,
          key: _generalItemKeys[2],
          title: AppLocale.hideParentheses.getString(context),
          subtitle: AppLocale.hideParenthesesSubtitle.getString(context),
          value: _system.hideParentheses,
          onChanged: _toggleHideParentheses,
        ),
        SizedBox(height: 4.r),
        _buildSwitchItem(
          index: 3,
          key: _generalItemKeys[3],
          title: AppLocale.hideBrackets.getString(context),
          subtitle: AppLocale.hideBracketsSubtitle.getString(context),
          value: _system.hideBrackets,
          onChanged: _toggleHideBrackets,
        ),
        SizedBox(height: 4.r),
        _buildSwitchItem(
          index: 4,
          key: _generalItemKeys[4],
          title: AppLocale.hideSystemLogo.getString(context),
          subtitle: AppLocale.hideSystemLogoSubtitle.getString(context),
          value: _system.hideLogo,
          onChanged: _toggleHideLogo,
        ),

        if (widget.system.folderName != 'all' &&
            widget.system.folderName != 'android') ...[
          SizedBox(height: 4.r),
          _buildSwitchItem(
            index: 5,
            key: _generalItemKeys[5],
            title: AppLocale.recursiveScan.getString(context),
            subtitle: AppLocale.recursiveScanSubtitle.getString(context),
            value: _system.recursiveScan,
            onChanged: _toggleRecursiveScan,
          ),
        ],
      ],
    );
  }

  Widget _buildSwitchItem({
    required int index,
    required Key key,
    required String title,
    required String subtitle,
    required bool value,
    required ValueChanged<bool> onChanged,
  }) {
    final bool isFocused = _generalIndex == index;
    final theme = Theme.of(context);

    return Container(
      key: key,
      decoration: BoxDecoration(
        color: isFocused
            ? theme.colorScheme.secondary.withValues(alpha: 0.2)
            : Colors.transparent,
        borderRadius: BorderRadius.circular(8.r),
      ),
      child: InkWell(
        onTap: () {
          SfxService().playNavSound();
          onChanged(!value);
        },
        borderRadius: BorderRadius.circular(8.r),
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: 12.r, vertical: 6.r),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: TextStyle(
                        fontSize: 10.r,
                        fontWeight: FontWeight.w600,
                        color: isFocused
                            ? theme.colorScheme.secondary
                            : theme.colorScheme.onSurface,
                      ),
                    ),
                    Text(
                      subtitle,
                      style: TextStyle(
                        fontSize: 9.r,
                        color: theme.colorScheme.onSurface.withValues(
                          alpha: 0.6,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              CustomToggleSwitch(
                value: value,
                onChanged: onChanged,
                activeColor: theme.colorScheme.primary,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildEmulatorsTab() {
    return _buildCoresList();
  }

  Widget _buildCoresList() {
    if (_totalEmulators == 0) {
      return Center(
        child: Padding(
          padding: EdgeInsets.all(8.r),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Symbols.gamepad_rounded,
                size: 28.r,
                color: Theme.of(context).colorScheme.onSurface,
              ),
              SizedBox(height: 8.r),
              Text(
                AppLocale.noEmulatorsAvailable.getString(context),
                style: TextStyle(
                  fontSize: 12.r,
                  color: Theme.of(context).colorScheme.onSurface,
                ),
              ),
            ],
          ),
        ),
      );
    }

    return ValueListenableBuilder<int>(
      valueListenable: _centeredScrollController.rebuildNotifier,
      builder: (context, rebuildCount, child) {
        return ListView.builder(
          key: ValueKey('emulators_list_rebuild_$rebuildCount'),
          controller: _centeredScrollController.scrollController,
          padding: EdgeInsets.symmetric(horizontal: 8.r, vertical: 4.r),
          itemCount: _totalEmulators,
          itemBuilder: (context, index) {
            final item = _displayItems[index];
            final isSelected = _selectedIndex == index;

            if (item is EmulatorGroupedCoreItem) {
              return _buildGroupedCoreItem(item, index, isSelected);
            } else if (item is EmulatorCoreItem) {
              return _buildCoreItem(
                item.core,
                index,
                isSelected,
                item.retroArchConfigured,
                item.retroArchPath,
              );
            } else if (item is EmulatorStandaloneItem) {
              return _buildStandaloneItem(item, index, isSelected);
            }
            return const SizedBox.shrink();
          },
        );
      },
    );
  }

  Widget _buildGroupedCoreItem(
    EmulatorGroupedCoreItem item,
    int index,
    bool isSelected,
  ) {
    final theme = Theme.of(context);
    final isConfigured = Platform.isAndroid
        ? item.isInstalled
        : item.retroArchConfigured;
    final isDisabled = !isConfigured;

    final CoreEmulatorModel? selectedCore = item.cores.any((c) => c.isDefault)
        ? item.cores.firstWhere((c) => c.isDefault)
        : null;

    return Container(
      margin: EdgeInsets.only(bottom: 6.r),
      decoration: BoxDecoration(
        color: isSelected
            ? theme.colorScheme.secondary.withValues(alpha: 0.15)
            : theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(6.r),
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          canRequestFocus: false,
          focusColor: Colors.transparent,
          hoverColor: Colors.transparent,
          highlightColor: Colors.transparent,
          splashColor: Colors.transparent,
          overlayColor: WidgetStateProperty.all(Colors.transparent),
          splashFactory: NoSplash.splashFactory,
          borderRadius: BorderRadius.circular(8.r),
          focusNode: _coreItemFocusNodes[index],
          onTap: () {
            SfxService().playNavSound();
            setState(() {
              _selectedIndex = index;
            });
            _centeredScrollController.updateSelectedIndex(index);
            WidgetsBinding.instance.addPostFrameCallback((_) {
              _scrollToSelected();
            });
          },
          child: Padding(
            padding: EdgeInsets.symmetric(horizontal: 8.r, vertical: 4.r),
            child: Row(
              children: [
                // Wrap left part and dropdown in Opacity
                Expanded(
                  child: Opacity(
                    opacity: isDisabled ? 0.5 : 1.0,
                    child: Row(
                      children: [
                        // Variant Icon
                        Container(
                          width: 24.r,
                          height: 24.r,
                          decoration: BoxDecoration(
                            color: isSelected
                                ? theme.colorScheme.secondary.withValues(
                                    alpha: 0.2,
                                  )
                                : theme.colorScheme.secondary.withValues(
                                    alpha: 0.1,
                                  ),
                            borderRadius: BorderRadius.circular(4.r),
                          ),
                          child: Padding(
                            padding: EdgeInsets.all(4.r),
                            child: Image.asset(
                              'assets/images/emulators/retroarch.webp',
                              color: isSelected
                                  ? theme.colorScheme.secondary
                                  : theme.colorScheme.onSurface,
                              colorBlendMode: BlendMode.srcIn,
                              errorBuilder: (context, error, stackTrace) =>
                                  Icon(
                                    Symbols.gamepad_rounded,
                                    size: 14.r,
                                    color: isSelected
                                        ? theme.colorScheme.secondary
                                        : theme.colorScheme.onSurface,
                                  ),
                            ),
                          ),
                        ),
                        SizedBox(width: 10.r),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                item.groupName,
                                style: TextStyle(
                                  fontSize: 12.r,
                                  fontWeight: FontWeight.w600,
                                  color: isSelected
                                      ? theme.colorScheme.secondary
                                      : theme.colorScheme.onSurface,
                                ),
                              ),
                              Row(
                                children: [
                                  Icon(
                                    Platform.isAndroid
                                        ? (item.isInstalled
                                              ? Symbols.check_circle_rounded
                                              : Symbols.error_outline_rounded)
                                        : (item.retroArchConfigured
                                              ? Symbols.check_circle_rounded
                                              : Symbols.warning_rounded),
                                    size: 11.r,
                                    color: Platform.isAndroid
                                        ? (item.isInstalled
                                              ? const Color(0xFF56C288)
                                              : const Color(0xFFFDAF1E))
                                        : (item.retroArchConfigured
                                              ? const Color(0xFF56C288)
                                              : const Color(0xFFFDAF1E)),
                                  ),
                                  SizedBox(width: 4.r),
                                  Text(
                                    Platform.isAndroid
                                        ? (item.isInstalled
                                              ? AppLocale.installed.getString(
                                                  context,
                                                )
                                              : AppLocale.notInstalled
                                                    .getString(context))
                                        : (item.retroArchConfigured
                                              ? AppLocale.configured.getString(
                                                  context,
                                                )
                                              : AppLocale.notConfigured
                                                    .getString(context)),
                                    style: TextStyle(
                                      fontSize: 10.r,
                                      color: isSelected
                                          ? theme.colorScheme.secondary
                                          : theme.colorScheme.onSurface
                                                .withValues(alpha: 0.6),
                                    ),
                                  ),
                                ],
                              ),
                              if (!Platform.isAndroid &&
                                  item.retroArchConfigured &&
                                  item.retroArchPath != null)
                                Padding(
                                  padding: EdgeInsets.only(top: 2.r),
                                  child: Text(
                                    item.retroArchPath!,
                                    style: TextStyle(
                                      fontSize: 9.r,
                                      color: theme.colorScheme.onSurface
                                          .withValues(alpha: 0.5),
                                      fontFamily: 'monospace',
                                    ),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                            ],
                          ),
                        ),
                        SizedBox(width: 8.r),
                        // MenuAnchor for Core selection
                        Container(
                          height: 28.r,
                          padding: EdgeInsets.symmetric(horizontal: 8.r),
                          decoration: BoxDecoration(
                            color: selectedCore != null
                                ? const Color(
                                    0xFF56C288,
                                  ) // Green when a core is selected
                                : Colors.white, // White otherwise
                            borderRadius: BorderRadius.circular(6.r),
                          ),
                          child: Theme(
                            data: theme.copyWith(
                              hoverColor: Colors.transparent,
                              splashColor: Colors.transparent,
                              highlightColor: Colors.transparent,
                            ),
                            child: MenuAnchor(
                              controller: _menuControllers[index],
                              childFocusNode: _menuFocusNodes[index],
                              onOpen: () {
                                setState(() => _openMenuIndex = index);
                                // Request focus on the first item when it opens
                                WidgetsBinding.instance.addPostFrameCallback((
                                  _,
                                ) {
                                  if (_menuCoresFocusNodes[index]?.isNotEmpty ==
                                      true) {
                                    _menuCoresFocusNodes[index]![0]
                                        .requestFocus();
                                  } else {
                                    _menuFocusNodes[index].requestFocus();
                                  }
                                });
                              },
                              onClose: () {
                                setState(() => _openMenuIndex = -1);
                              },
                              style: MenuStyle(
                                backgroundColor: WidgetStateProperty.all(
                                  const Color(0xFF1A1C1E),
                                ),
                                shape: WidgetStateProperty.all(
                                  RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(8.r),
                                    side: BorderSide(
                                      color: Colors.white.withValues(
                                        alpha: 0.1,
                                      ),
                                      width: 1.r,
                                    ),
                                  ),
                                ),
                              ),
                              menuChildren: item.cores.asMap().entries.map((
                                entry,
                              ) {
                                final coreIndex = entry.key;
                                final core = entry.value;
                                return MenuItemButton(
                                  focusNode:
                                      _menuCoresFocusNodes[index]?[coreIndex],
                                  onPressed: () => _setAsDefault(core),
                                  style: ButtonStyle(
                                    backgroundColor:
                                        WidgetStateProperty.resolveWith((
                                          states,
                                        ) {
                                          if (states.contains(
                                            WidgetState.focused,
                                          )) {
                                            return theme.colorScheme.secondary
                                                .withValues(alpha: 0.2);
                                          }
                                          return null;
                                        }),
                                  ),
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      if (core
                                          .isretroAchievementsCompatible) ...[
                                        Icon(
                                          Symbols.emoji_events_rounded,
                                          size: 12.r,
                                          color: const Color(0xFFFFD700),
                                        ),
                                        SizedBox(width: 6.r),
                                      ],
                                      Text(
                                        core.name
                                            .replaceAll('RetroArch ', '')
                                            .replaceAll('RetroArch32 ', '')
                                            .replaceAll('RetroArch64 ', '')
                                            .replaceAll(' (32-bit)', '')
                                            .replaceAll(' (64-bit)', ''),
                                        style: TextStyle(
                                          fontSize: 11.r,
                                          color: Colors.white,
                                        ),
                                      ),
                                      if (core.isDefault) ...[
                                        SizedBox(width: 8.r),
                                        Icon(
                                          Symbols.check_circle_rounded,
                                          size: 12.r,
                                          color: const Color(0xFF56C288),
                                        ),
                                      ],
                                    ],
                                  ),
                                );
                              }).toList(),
                              builder: (context, controller, child) {
                                return InkWell(
                                  canRequestFocus: false,
                                  focusColor: Colors.transparent,
                                  hoverColor: Colors.transparent,
                                  highlightColor: Colors.transparent,
                                  splashColor: Colors.transparent,
                                  onTap: isDisabled
                                      ? null
                                      : () {
                                          SfxService().playNavSound();
                                          if (controller.isOpen) {
                                            controller.close();
                                          } else {
                                            controller.open();
                                          }
                                        },
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      if (selectedCore
                                              ?.isretroAchievementsCompatible ==
                                          true) ...[
                                        Icon(
                                          Symbols.emoji_events_rounded,
                                          size: 11.r,
                                          color: const Color(0xFFFFD700),
                                        ),
                                        SizedBox(width: 4.r),
                                      ],
                                      Text(
                                        selectedCore?.name
                                                .replaceAll('RetroArch ', '')
                                                .replaceAll('RetroArch32 ', '')
                                                .replaceAll('RetroArch64 ', '')
                                                .replaceAll(' (32-bit)', '')
                                                .replaceAll(' (64-bit)', '') ??
                                            AppLocale.selectCore.getString(
                                              context,
                                            ),
                                        style: TextStyle(
                                          fontSize: 10.r,
                                          fontWeight: FontWeight.bold,
                                          color: selectedCore != null
                                              ? Colors.white
                                              : const Color(0xFF1A1C1E),
                                        ),
                                      ),
                                      Icon(
                                        Symbols.arrow_drop_down_rounded,
                                        size: 16.r,
                                        color: selectedCore != null
                                            ? Colors.white
                                            : const Color(0xFF1A1C1E),
                                      ),
                                    ],
                                  ),
                                );
                              },
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),

                // Desktop: Configure RetroArch path (Persistent/Always enabled)
                if (!Platform.isAndroid)
                  Tooltip(
                    message: AppLocale.selectRetroArchExe.getString(context),
                    child: Container(
                      margin: EdgeInsets.only(left: 8.r),
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(6.r),
                      ),
                      child: Material(
                        color: Colors.transparent,
                        child: InkWell(
                          canRequestFocus: false,
                          focusColor: Colors.transparent,
                          hoverColor: Colors.transparent,
                          highlightColor: Colors.transparent,
                          splashColor: Colors.transparent,
                          borderRadius: BorderRadius.circular(6.r),
                          onTap: () {
                            SfxService().playNavSound();
                            _configureRetroArchPath();
                          },
                          child: Padding(
                            padding: EdgeInsets.all(6.r),
                            child: Icon(
                              Symbols.folder_open_rounded,
                              size: 14.r,
                              color: Colors.white,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildCoreItem(
    CoreEmulatorModel core,
    int index,
    bool isSelected,
    bool retroArchConfigured,
    String? retroArchPath,
  ) {
    return Container(
      margin: EdgeInsets.only(bottom: 6.r),
      decoration: BoxDecoration(
        color: isSelected
            ? Theme.of(context).colorScheme.secondary.withValues(alpha: 0.15)
            : Theme.of(
                context,
              ).colorScheme.surfaceContainerHighest.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(6.r),
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          canRequestFocus: false,
          focusColor: Colors.transparent,
          hoverColor: Colors.transparent,
          highlightColor: Colors.transparent,
          splashColor: Colors.transparent,
          overlayColor: WidgetStateProperty.all(Colors.transparent),
          splashFactory: NoSplash.splashFactory,
          borderRadius: BorderRadius.circular(8.r),
          focusNode: _coreItemFocusNodes[index],
          onTap: () {
            SfxService().playNavSound();
            setState(() {
              _selectedIndex = index;
            });
            _centeredScrollController.updateSelectedIndex(index);
            WidgetsBinding.instance.addPostFrameCallback((_) {
              _scrollToSelected();
            });
          },
          child: Padding(
            padding: EdgeInsets.symmetric(horizontal: 8.r, vertical: 4.r),
            child: Row(
              children: [
                // Core icon
                Container(
                  width: 24.r,
                  height: 24.r,
                  decoration: BoxDecoration(
                    color: isSelected
                        ? Theme.of(
                            context,
                          ).colorScheme.secondary.withValues(alpha: 0.2)
                        : Theme.of(
                            context,
                          ).colorScheme.secondary.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(4.r),
                  ),
                  child: Padding(
                    padding: EdgeInsets.all(4.r),
                    child: Image.asset(
                      'assets/images/emulators/retroarch.webp',
                      color: isSelected
                          ? Theme.of(context).colorScheme.secondary
                          : Theme.of(context).colorScheme.onSurface,
                      colorBlendMode: BlendMode.srcIn,
                      errorBuilder: (context, error, stackTrace) => Icon(
                        Symbols.gamepad_rounded,
                        size: 14.r,
                        color: isSelected
                            ? Theme.of(context).colorScheme.secondary
                            : Theme.of(context).colorScheme.onSurface,
                      ),
                    ),
                  ),
                ),
                SizedBox(width: 10.r),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Text(
                            core.name,
                            style: TextStyle(
                              fontSize: 12.r,
                              fontWeight: FontWeight.w600,
                              color: isSelected
                                  ? Theme.of(context).colorScheme.secondary
                                  : Theme.of(context).colorScheme.onSurface,
                            ),
                          ),
                        ],
                      ),
                      SizedBox(height: 1.r),
                      Row(
                        children: [
                          if (core.isretroAchievementsCompatible)
                            Container(
                              margin: EdgeInsets.only(right: 6.r),
                              padding: EdgeInsets.symmetric(
                                horizontal: 6.r,
                                vertical: 2.r,
                              ),
                              decoration: BoxDecoration(
                                color: const Color(0xFFFFD700),
                                borderRadius: BorderRadius.circular(4.r),
                                border: Border.all(
                                  color: const Color(
                                    0xFF00387D,
                                  ).withValues(alpha: 0.2),
                                  width: 0.5.r,
                                ),
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(
                                    Symbols.emoji_events_rounded,
                                    size: 10.r,
                                    color: const Color(0xFF00387D),
                                  ),
                                ],
                              ),
                            ),
                          // Status indicator (desktop: configured/not configured)
                          Row(
                            children: [
                              Icon(
                                Platform.isAndroid
                                    ? (core.isInstalled
                                          ? Symbols.check_circle_rounded
                                          : Symbols.error_outline_rounded)
                                    : (retroArchConfigured
                                          ? Symbols.check_circle_rounded
                                          : Symbols.warning_rounded),
                                size: 12.r,
                                color: Platform.isAndroid
                                    ? (core.isInstalled
                                          ? const Color(0xFF56C288)
                                          : const Color(0xFFFDAF1E))
                                    : (retroArchConfigured
                                          ? const Color(0xFF56C288)
                                          : const Color(0xFFFDAF1E)),
                              ),
                              SizedBox(width: 4.r),
                              Text(
                                Platform.isAndroid
                                    ? (core.isInstalled
                                          ? AppLocale.installed.getString(
                                              context,
                                            )
                                          : AppLocale.notInstalled.getString(
                                              context,
                                            ))
                                    : (retroArchConfigured
                                          ? AppLocale.configured.getString(
                                              context,
                                            )
                                          : AppLocale.notConfigured.getString(
                                              context,
                                            )),
                                style: TextStyle(
                                  fontSize: 11.r,
                                  color: isSelected
                                      ? Theme.of(context).colorScheme.secondary
                                      : Theme.of(context).colorScheme.onSurface,
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                      if (!Platform.isAndroid &&
                          retroArchConfigured &&
                          retroArchPath != null)
                        Padding(
                          padding: EdgeInsets.only(top: 2.r),
                          child: Text(
                            retroArchPath,
                            style: TextStyle(
                              fontSize: 9.r,
                              color: Theme.of(
                                context,
                              ).colorScheme.onSurface.withValues(alpha: 0.5),
                              fontFamily: 'monospace',
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                    ],
                  ),
                ),
                // Desktop: Configure RetroArch path (Persistent)
                if (!Platform.isAndroid)
                  Tooltip(
                    message: AppLocale.selectRetroArchExe.getString(context),
                    child: Container(
                      margin: EdgeInsets.only(left: 8.r, right: 8.r),
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(6.r),
                      ),
                      child: Material(
                        color: Colors.transparent,
                        child: InkWell(
                          canRequestFocus: false,
                          focusColor: Colors.transparent,
                          hoverColor: Colors.transparent,
                          highlightColor: Colors.transparent,
                          splashColor: Colors.transparent,
                          borderRadius: BorderRadius.circular(6.r),
                          onTap: () {
                            SfxService().playNavSound();
                            _configureRetroArchPath();
                          },
                          child: Padding(
                            padding: EdgeInsets.all(6.r),
                            child: Icon(
                              Symbols.folder_open_rounded,
                              size: 14.r,
                              color: Colors.white,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                // Set as default button - always visible
                Builder(
                  builder: (context) {
                    final isConfigured = Platform.isAndroid
                        ? true // On Android assuming configured/installed check handled elsewhere or allowing selection
                        : retroArchConfigured;

                    final isDisabled = !isConfigured;

                    return Opacity(
                      opacity: isDisabled ? 0.5 : 1.0,
                      child: Container(
                        decoration: BoxDecoration(
                          color: core.isDefault
                              ? const Color(0xFF56C288) // Green when selected
                              : Colors.white, // White when not selected
                          borderRadius: BorderRadius.circular(6.r),
                        ),
                        child: Material(
                          color: Colors.transparent,
                          child: InkWell(
                            canRequestFocus: false,
                            focusColor: Colors.transparent,
                            hoverColor: Colors.transparent,
                            highlightColor: Colors.transparent,
                            splashColor: Colors.transparent,
                            overlayColor: WidgetStateProperty.all(
                              Colors.transparent,
                            ),
                            splashFactory: NoSplash.splashFactory,
                            borderRadius: BorderRadius.circular(6.r),
                            focusNode: _setDefaultButtonFocusNodes[index],
                            onTap: (core.isDefault || isDisabled)
                                ? null
                                : () {
                                    SfxService().playEnterSound();
                                    _setAsDefault(core);
                                  }, // Disabled when default or not configured
                            child: Padding(
                              padding: EdgeInsets.symmetric(
                                horizontal: 10.r,
                                vertical: 6.r,
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  if (core.isDefault)
                                    Icon(
                                      Symbols.check_circle_rounded,
                                      size: 12.r,
                                      color: Colors.white,
                                    )
                                  else
                                    SizedBox(
                                      height: 12.r,
                                      width: 12.r,
                                      child: Image.asset(
                                        'assets/images/gamepad/Xbox_A_button.png',
                                        color: const Color(0xFF1A1C1E),
                                        colorBlendMode: BlendMode.srcIn,
                                      ),
                                    ),
                                  SizedBox(width: 4.r),
                                  Text(
                                    core.isDefault
                                        ? AppLocale.selected.getString(context)
                                        : AppLocale.select.getString(context),
                                    style: TextStyle(
                                      fontSize: 10.r,
                                      fontWeight: FontWeight.bold,
                                      color: core.isDefault
                                          ? Colors.white
                                          : const Color(0xFF1A1C1E),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildStandaloneItem(
    EmulatorStandaloneItem item,
    int index,
    bool isSelected,
  ) {
    final standalone = item.standalone;
    final isInstalled = item.isInstalled;
    final theme = Theme.of(context);

    // Status logic (Android: installed, Desktop: configured)
    final isConfigured = Platform.isAndroid
        ? isInstalled
        : standalone.isConfigured;

    final isDisabled = !isConfigured;

    return Container(
      margin: EdgeInsets.only(bottom: 6.r),
      decoration: BoxDecoration(
        color: isSelected
            ? theme.colorScheme.secondary.withValues(alpha: 0.15)
            : theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(6.r),
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          canRequestFocus: false,
          focusColor: Colors.transparent,
          hoverColor: Colors.transparent,
          highlightColor: Colors.transparent,
          splashColor: Colors.transparent,
          overlayColor: WidgetStateProperty.all(Colors.transparent),
          splashFactory: NoSplash.splashFactory,
          borderRadius: BorderRadius.circular(8.r),
          focusNode: _coreItemFocusNodes[index],
          onTap: () {
            SfxService().playNavSound();
            setState(() {
              _selectedIndex = index;
            });
            _centeredScrollController.updateSelectedIndex(index);
            WidgetsBinding.instance.addPostFrameCallback((_) {
              _scrollToSelected();
            });
          },
          child: Padding(
            padding: EdgeInsets.symmetric(horizontal: 8.r, vertical: 4.r),
            child: Row(
              children: [
                // Wrap main info in Opacity
                Expanded(
                  child: Opacity(
                    opacity: isDisabled ? 0.5 : 1.0,
                    child: Row(
                      children: [
                        // Standalone icon
                        Container(
                          width: 24.r,
                          height: 24.r,
                          decoration: BoxDecoration(
                            color: isSelected
                                ? theme.colorScheme.secondary.withValues(
                                    alpha: 0.2,
                                  )
                                : theme.colorScheme.secondary.withValues(
                                    alpha: 0.1,
                                  ),
                            borderRadius: BorderRadius.circular(4.r),
                          ),
                          child: Padding(
                            padding: EdgeInsets.all(4.r),
                            child: Icon(
                              Symbols.apps_rounded,
                              size: 14.r,
                              color: isSelected
                                  ? theme.colorScheme.secondary
                                  : theme.colorScheme.onSurface,
                            ),
                          ),
                        ),
                        SizedBox(width: 10.r),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                standalone.name,
                                style: TextStyle(
                                  fontSize: 12.r,
                                  fontWeight: FontWeight.w600,
                                  color: isSelected
                                      ? theme.colorScheme.secondary
                                      : theme.colorScheme.onSurface,
                                ),
                              ),
                              SizedBox(height: 1.r),
                              Row(
                                children: [
                                  if (standalone.isretroAchievementsCompatible)
                                    Container(
                                      margin: EdgeInsets.only(right: 6.r),
                                      padding: EdgeInsets.symmetric(
                                        horizontal: 6.r,
                                        vertical: 2.r,
                                      ),
                                      decoration: BoxDecoration(
                                        color: const Color(0xFFFFD700),
                                        borderRadius: BorderRadius.circular(
                                          4.r,
                                        ),
                                        border: Border.all(
                                          color: const Color(
                                            0xFF00387D,
                                          ).withValues(alpha: 0.2),
                                          width: 0.5.r,
                                        ),
                                      ),
                                      child: Icon(
                                        Symbols.emoji_events_rounded,
                                        size: 10.r,
                                        color: const Color(0xFF00387D),
                                      ),
                                    ),
                                  Icon(
                                    Platform.isAndroid
                                        ? (isInstalled
                                              ? Symbols.check_circle_rounded
                                              : Symbols.error_outline_rounded)
                                        : (standalone.isConfigured
                                              ? Symbols.check_circle_rounded
                                              : Symbols.warning_rounded),
                                    size: 12.r,
                                    color: isConfigured
                                        ? const Color(0xFF56C288)
                                        : const Color(0xFFFDAF1E),
                                  ),
                                  SizedBox(width: 4.r),
                                  Text(
                                    Platform.isAndroid
                                        ? (isInstalled
                                              ? AppLocale.installed.getString(
                                                  context,
                                                )
                                              : AppLocale.notInstalled
                                                    .getString(context))
                                        : (standalone.isConfigured
                                              ? AppLocale.configured.getString(
                                                  context,
                                                )
                                              : AppLocale.notConfigured
                                                    .getString(context)),
                                    style: TextStyle(
                                      fontSize: 11.r,
                                      color: isSelected
                                          ? theme.colorScheme.secondary
                                          : theme.colorScheme.onSurface,
                                    ),
                                  ),
                                  if (!Platform.isAndroid &&
                                      standalone.isConfigured &&
                                      standalone.userPath != null) ...[
                                    SizedBox(width: 8.r),
                                    Expanded(
                                      child: Text(
                                        standalone.userPath!,
                                        style: TextStyle(
                                          fontSize: 9.r,
                                          color: theme.colorScheme.onSurface
                                              .withValues(alpha: 0.5),
                                          fontFamily: 'monospace',
                                        ),
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ),
                                  ],
                                ],
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),

                // Select button
                Opacity(
                  opacity: isDisabled ? 0.5 : 1.0,
                  child: Container(
                    decoration: BoxDecoration(
                      color: standalone.isUserDefault == true
                          ? const Color(0xFF56C288)
                          : Colors.white,
                      borderRadius: BorderRadius.circular(6.r),
                    ),
                    child: Material(
                      color: Colors.transparent,
                      child: InkWell(
                        canRequestFocus: false,
                        focusColor: Colors.transparent,
                        hoverColor: Colors.transparent,
                        highlightColor: Colors.transparent,
                        splashColor: Colors.transparent,
                        borderRadius: BorderRadius.circular(6.r),
                        onTap: (standalone.isUserDefault == true || isDisabled)
                            ? null
                            : () {
                                SfxService().playEnterSound();
                                _setStandaloneAsDefault(standalone);
                              },
                        child: Padding(
                          padding: EdgeInsets.symmetric(
                            horizontal: 10.r,
                            vertical: 6.r,
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              if (standalone.isUserDefault == true)
                                Icon(
                                  Symbols.check_circle_rounded,
                                  size: 12.r,
                                  color: Colors.white,
                                )
                              else
                                SizedBox(
                                  height: 12.r,
                                  width: 12.r,
                                  child: Image.asset(
                                    'assets/images/gamepad/Xbox_A_button.png',
                                    color: const Color(0xFF1A1C1E),
                                    colorBlendMode: BlendMode.srcIn,
                                  ),
                                ),
                              SizedBox(width: 4.r),
                              Text(
                                standalone.isUserDefault == true
                                    ? AppLocale.selected.getString(context)
                                    : AppLocale.select.getString(context),
                                style: TextStyle(
                                  fontSize: 10.r,
                                  fontWeight: FontWeight.bold,
                                  color: standalone.isUserDefault == true
                                      ? Colors.white
                                      : const Color(0xFF1A1C1E),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),

                // Desktop: Folder button (Persistent)
                if (!Platform.isAndroid)
                  Tooltip(
                    message: AppLocale.selectExecutablePath.getString(context),
                    child: Container(
                      margin: EdgeInsets.only(left: 8.r),
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(6.r),
                      ),
                      child: Material(
                        color: Colors.transparent,
                        child: InkWell(
                          canRequestFocus: false,
                          focusColor: Colors.transparent,
                          hoverColor: Colors.transparent,
                          highlightColor: Colors.transparent,
                          splashColor: Colors.transparent,
                          borderRadius: BorderRadius.circular(6.r),
                          onTap: () {
                            SfxService().playNavSound();
                            _configureStandalonePath(standalone);
                          },
                          child: Padding(
                            padding: EdgeInsets.all(6.r),
                            child: Icon(
                              Symbols.folder_open_rounded,
                              size: 14.r,
                              color: Colors.white,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildFooter() {
    final theme = Theme.of(context);
    return Container(
      padding: EdgeInsets.all(8.r),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(
          alpha: 0.05,
        ),
        borderRadius: BorderRadius.only(
          bottomLeft: Radius.circular(12.r),
          bottomRight: Radius.circular(12.r),
        ),
      ),
      child: Row(
        children: [
          // Gamepad controls hint
          Expanded(
            child: Row(
              children: [
                GamepadControl(
                  iconPath: 'assets/images/gamepad/Xbox_D-pad_ALL.png',
                  label: AppLocale.navigate.getString(context),
                  backgroundColor: theme.colorScheme.tertiary,
                  textColor: theme.colorScheme.onPrimary,
                ),
              ],
            ),
          ),
          SizedBox(width: 8.r),
          // Close button
          GamepadControl(
            iconPath: 'assets/images/gamepad/Xbox_B_button.png',
            label: AppLocale.close.getString(context),
            backgroundColor: theme.colorScheme.error,
            textColor: theme.colorScheme.onError,
            onTap: () {
              SfxService().playBackSound();
              Navigator.of(context).pop();
            },
          ),
        ],
      ),
    );
  }
}

// Helper classes for grouped display
abstract class EmulatorListItem {}

class EmulatorHeaderItem extends EmulatorListItem {
  final String title;
  final bool isInstalled;
  final String? packageName;

  EmulatorHeaderItem({
    required this.title,
    this.isInstalled = false,
    this.packageName,
  });
}

class EmulatorCoreItem extends EmulatorListItem {
  final CoreEmulatorModel core;
  final bool retroArchConfigured;
  final String? retroArchPath;

  EmulatorCoreItem(
    this.core, {
    this.retroArchConfigured = false,
    this.retroArchPath,
  });
}

class EmulatorStandaloneItem extends EmulatorListItem {
  final StandaloneEmulatorModel standalone;
  final bool isInstalled;

  EmulatorStandaloneItem(this.standalone, {this.isInstalled = false});
}

class EmulatorGroupedCoreItem extends EmulatorListItem {
  final String groupName;
  final String? packageName;
  final List<CoreEmulatorModel> cores;
  final bool isInstalled;
  final bool retroArchConfigured;
  final String? retroArchPath;

  EmulatorGroupedCoreItem({
    required this.groupName,
    this.packageName,
    required this.cores,
    this.isInstalled = false,
    this.retroArchConfigured = false,
    this.retroArchPath,
  });
}
