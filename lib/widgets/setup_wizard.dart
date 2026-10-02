import 'dart:io';
import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:flutter/services.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:provider/provider.dart';
import 'package:neostation/services/logger_service.dart';
import 'package:neostation/services/permission_service.dart';
import 'package:neostation/services/config_service.dart';
import 'package:neostation/services/user_data_location_service.dart';
import 'package:neostation/services/screenshot_service.dart';
import 'package:neostation/providers/theme_provider.dart';
import 'package:neostation/providers/neo_assets_provider.dart';
import 'package:neostation/widgets/system_art_pack_tile.dart';
import 'package:neostation/providers/file_provider.dart';
import 'package:neostation/services/esde_import_service.dart';
import 'package:neostation/services/global_notification_service.dart';
import '../providers/sqlite_config_provider.dart';
import '../utils/gamepad_nav.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:neostation/l10n/app_locale.dart';
import '../widgets/tv_directory_picker.dart';
import '../widgets/folder_not_empty_dialog.dart';
import 'core_footer.dart';
import '../models/secondary_display_state.dart';

/// Initial configuration wizard for the first time the app is opened
class SetupWizard extends StatefulWidget {
  final VoidCallback onComplete;

  const SetupWizard({super.key, required this.onComplete});

  @override
  State<SetupWizard> createState() => _SetupWizardState();
}

class _SetupWizardState extends State<SetupWizard> with WidgetsBindingObserver {
  int _currentStep = 0;
  bool _isSelectingFolder = false;
  bool _isSelectingUserDataFolder = false;
  String? _selectedFolder;
  String? _selectedUserDataPath;
  SecondaryDisplayState? _secondaryDisplayState;

  // --- ES-DE import step state (optional step after scanning) ---
  bool _isImportingEsde = false;
  double _esdeProgress = 0.0;
  String _esdeLabel = '';
  EsdeImportResult? _esdeResult;

  // --- Art-pack step state (optional final step) ---
  bool _isDownloadingArt = false;

  /// Folder of the pack selected in the art-pack list. Empty means "use the
  /// recommended pack" (first non-AI), resolved when the list is built.
  String _selectedArtPackFolder = '';

  /// Scrolls the art-pack list so the D-pad selection stays on screen.
  final ScrollController _artPackScrollController = ScrollController();
  final List<GlobalKey> _artPackKeys = [];

  /// Whether All-Files (storage) access is currently granted.
  bool _storageGranted = false;

  /// Set whenever the app leaves the foreground, so the permissions step can
  /// tell "a system Settings screen actually opened" from "the grant never
  /// launched at all". Only the latter may re-arm gamepad input on a timer —
  /// see [_handlePermissionAction].
  bool _leftForegroundDuringGrant = false;

  /// Whether the screenshot/return accessibility service is currently granted.
  /// Both are re-checked whenever the app resumes (the user grants them in
  /// system Settings, so we can't observe the change synchronously).
  bool _accessibilityGranted = false;

  /// Whether a secondary display is present. The accessibility (Screen Return)
  /// grant only makes sense on dual-screen devices, so we hide it otherwise.
  bool _hasSecondaryDisplay = false;

  /// Whether the accessibility grant should be offered at all.
  bool get _needsAccessibility => Platform.isAndroid && _hasSecondaryDisplay;

  /// Whether the accessibility requirement is satisfied — either it's granted,
  /// or it doesn't apply on this device.
  bool get _accessibilityDone => !_needsAccessibility || _accessibilityGranted;

  /// True once setup is being finalised, so the per-frame secondary-display
  /// push stops re-asserting `setupWizardActive` and the dock can come in.
  bool _finishing = false;

  static final _log = LoggerService.instance;

  GamepadNavigation? _gamepadNav;

  // Step indices. Android has two extra steps (Permissions + Accessibility)
  // that don't exist on desktop; the getters resolve to -1 there so a
  // comparison against a real (>= 0) step never matches.
  //   Android: 0=UserData, 1=Permissions, 2=Folder, 3=Scanning,
  //            4=EsdeImport, 5=ArtPack
  //   Desktop: 0=UserData, 1=Folder, 2=Scanning, 3=EsdeImport, 4=ArtPack
  // The Permissions step covers both All-Files access and the accessibility
  // (Screen Return) service.
  int get _stepUserData => 0;
  int get _stepPermissions => Platform.isAndroid ? 1 : -1;
  int get _stepFolder => Platform.isAndroid ? 2 : 1;
  int get _stepScanning => Platform.isAndroid ? 3 : 2;
  int get _stepEsde => Platform.isAndroid ? 4 : 3;
  int get _stepArtPack => Platform.isAndroid ? 5 : 4;

  /// The art-pack step is always the final step of the wizard.
  bool get _isLastStep => _currentStep == _stepArtPack;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initializeSteps();
    _initGamepad();
    if (Platform.isAndroid) {
      _secondaryDisplayState = SecondaryDisplayState.instance;
      _hasSecondaryDisplay =
          _secondaryDisplayState!.value?.isSecondaryActive ?? false;
      _secondaryDisplayState!.addListener(_onSecondaryStateChanged);
      _refreshPermissionStates();
    }
  }

  /// Keeps [_hasSecondaryDisplay] in sync so the accessibility row appears the
  /// moment a secondary display reports in (it may connect after the wizard
  /// first builds).
  void _onSecondaryStateChanged() {
    final has = _secondaryDisplayState?.value?.isSecondaryActive ?? false;
    if (has != _hasSecondaryDisplay && mounted) {
      setState(() => _hasSecondaryDisplay = has);
    }
  }

  /// Re-polls both permission states (storage + accessibility). Called on
  /// resume so the Permissions step reflects grants the user just made in
  /// system Settings.
  Future<void> _refreshPermissionStates() async {
    final storage = await PermissionService.hasAllFilesAccess();
    final access = await ScreenshotService.isAccessEnabled();
    if (mounted &&
        (storage != _storageGranted || access != _accessibilityGranted)) {
      setState(() {
        _storageGranted = storage;
        _accessibilityGranted = access;
      });
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) {
      // Something came to the front (the Settings screen we just asked for,
      // most likely), so the safety re-arm in _handlePermissionAction must
      // stand down: re-enabling gamepad input while backgrounded is the exact
      // key leakage that deactivate() is there to prevent.
      _leftForegroundDuringGrant = true;
      return;
    }
    if (Platform.isAndroid) {
      _refreshPermissionStates();
      // The gamepad was deactivated before we sent the user to Settings; bring
      // it back now that we have focus again on the Permissions step.
      if (_currentStep == _stepPermissions) _gamepadNav?.activate();
    }
  }

  void _initGamepad() {
    _gamepadNav = GamepadNavigation(
      onSelectItem: () {
        if (_isSelectingFolder || _isSelectingUserDataFolder) return;

        if (_isImportingEsde || _isDownloadingArt) return;
        // Mirror the on-screen button's disabled state on the final step: while
        // the theme manifest is still in flight we can't tell whether a pack is
        // available, and letting A through would finish setup with no art.
        if (_isLastStep) {
          final neoAssets = context.read<NeoAssetsProvider>();
          if (neoAssets.loading &&
              !neoAssets.hasActiveTheme &&
              neoAssets.themes.isEmpty) {
            return;
          }
        }
        if (_currentStep == _stepScanning) {
          // A advances to the ES-DE step once the scan is done.
          final provider = Provider.of<SqliteConfigProvider>(
            context,
            listen: false,
          );
          if (provider.scanCompleted) _handleMainAction();
        } else {
          // Every step — including the final art-pack one — goes through the
          // same primary action as the on-screen button. Shortcutting the last
          // step to _finishSetup() here meant an A press completed setup
          // without ever downloading/applying the art pack.
          _handleMainAction();
        }
      },
      onBack: () {
        _handleSkip();
      },
      onNavigateUp: () => _moveArtPackSelection(-1),
      onNavigateDown: () => _moveArtPackSelection(1),
    );
    _gamepadNav?.initialize();
    _gamepadNav?.activate();
  }

  /// Moves the art-pack list selection by [delta] (D-pad up/down). A no-op on
  /// every other wizard step.
  void _moveArtPackSelection(int delta) {
    if (_currentStep != _stepArtPack) return;
    final neoAssets = context.read<NeoAssetsProvider>();
    final themes = neoAssets.themes;
    if (themes.isEmpty) return;
    final current = _effectiveArtPackFolder(neoAssets);
    final index = themes.indexWhere((t) => t.folder == current);
    final next = (index + delta).clamp(0, themes.length - 1);
    if (next == index) return;
    setState(() => _selectedArtPackFolder = themes[next].folder);
    _ensureArtPackVisible(next);
  }

  /// Scrolls the art-pack list so the tile at [index] is visible. Runs after
  /// the frame so the newly selected tile's key has a context to scroll to.
  void _ensureArtPackVisible(int index) {
    if (index < 0 || index >= _artPackKeys.length) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final tileContext = _artPackKeys[index].currentContext;
      if (tileContext == null) return;
      Scrollable.ensureVisible(
        tileContext,
        alignment: 0.5,
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeInOut,
      );
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _secondaryDisplayState?.removeListener(_onSecondaryStateChanged);
    _gamepadNav?.dispose();
    _artPackScrollController.dispose();
    // Shared singleton — never dispose the instance.
    super.dispose();
  }

  void _updateSecondaryScreen(int bgColor, bool isOled) {
    if (_secondaryDisplayState == null) return;
    _secondaryDisplayState!.updateState(
      // Re-asserted on every push: the shared state is written by both engines
      // and the secondary's own pushes copyWith from a snapshot that may
      // predate the flag, so a single push can be echoed away (same hazard as
      // `appReady`). Stops once we're finishing so it can't undo the clear.
      setupWizardActive: !_finishing,
      systemName: AppLocale.welcomeNeoStation.getString(context),
      useFluidShader: true,
      backgroundColor: bgColor,
      isOled: isOled,
      isGameSelected: false,
      clearFanart: true,
      clearScreenshot: true,
      clearWheel: true,
      clearVideo: true,
      clearImageBytes: true,
      clearGameId: true,
    );
  }

  void _handleSkip() {
    // Permissions step: neither grant is a hard requirement. ROM access goes
    // through SAF, and UserDataLocationService already falls back to the
    // app-specific external dir without All-Files access. The skip is
    // deliberately unconditional — gating it on `_storageGranted` walled users
    // in at this step on ROMs where the All-Files grant can't be launched at
    // all (reported on Lenovo tablets), with no Next, no Skip and no way out.
    if (_currentStep == _stepPermissions) {
      setState(() => _currentStep = _stepFolder);
      return;
    }

    if (_currentStep == _stepFolder) {
      // Skip folder selection → Advance to Scanning step.
      setState(() => _currentStep = _stepScanning);

      // Start initial scan to detect available systems (e.g., Android apps).
      final provider = Provider.of<SqliteConfigProvider>(
        context,
        listen: false,
      );
      WidgetsBinding.instance.addPostFrameCallback((_) {
        provider.scanSystems();
      });
      return;
    }

    // Both trailing steps (ES-DE import, art pack) are optional — skipping
    // the ES-DE step advances to the art-pack step; skipping the art-pack
    // step finishes setup.
    if (_currentStep == _stepEsde) {
      setState(() => _currentStep = _stepArtPack);
      return;
    }
    if (_currentStep == _stepArtPack) {
      _finishSetup();
      return;
    }
  }

  void _initializeSteps() {
    // Load the current user-data path for display in step 0.
    _loadUserDataPath();
  }

  Future<void> _loadUserDataPath() async {
    try {
      await _resetUnwritableUserDataPath();
    } catch (e) {
      _log.e('Wizard: user-data path check failed: $e');
    }
    final p = await ConfigService.getUserDataPath();
    if (mounted) setState(() => _selectedUserDataPath = p);
  }

  Future<void> _resetUnwritableUserDataPath() async {
    final p = await ConfigService.getUserDataPath();
    // Earlier builds saved a folder the database couldn't be created in, and
    // the wizard reopens on every launch because setup never completed. Drop
    // that path so Next doesn't carry it forward. Safe here: the wizard only
    // runs before setup completes, so there is no library at that path yet.
    final custom = await UserDataLocationService.getCustomPath();
    if (!mounted) return;
    if (custom != null &&
        custom == p &&
        !context.read<SqliteConfigProvider>().databaseOpened &&
        !await UserDataLocationService.canWriteDirectory(custom)) {
      _log.w('Wizard: saved user-data path $custom is not writable, resetting');
      await UserDataLocationService.clearCustomPath();
      if (!mounted) return;
      await context.read<SqliteConfigProvider>().reinitialize();
      if (!mounted) return;
      await context.read<NeoAssetsProvider>().reinitialize();
    }
  }

  // Step layout:
  // Android: 0=UserData, 1=Permissions, 2=FolderSelect, 3=Scanning,
  //          4=EsdeImport, 5=ArtPack (6 steps)
  // Desktop: 0=UserData, 1=FolderSelect, 2=Scanning, 3=EsdeImport,
  //          4=ArtPack (5 steps)
  int get _totalSteps => Platform.isAndroid ? 6 : 5;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final themeProvider = Provider.of<ThemeProvider>(context);
    final orientation = MediaQuery.of(context).orientation;
    final isLandscape = orientation == Orientation.landscape;
    final isOled = themeProvider.isOled;
    final bgColor = theme.scaffoldBackgroundColor;

    // Synchronize secondary screen
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _updateSecondaryScreen(bgColor.toARGB32(), isOled);
    });

    return Scaffold(
      backgroundColor: bgColor,
      body: Stack(
        children: [
          // Dynamic Background: Fluid Shader
          if (!isOled)
            Positioned.fill(
              child: Builder(
                builder: (context) {
                  final bg = Theme.of(context).scaffoldBackgroundColor;
                  return Container(decoration: BoxDecoration(color: bg));
                },
              ),
            ),

          // Contenido principal
          SafeArea(
            child: isLandscape
                ? _buildLandscapeLayout(theme)
                : _buildPortraitLayout(theme),
          ),
        ],
      ),
    );
  }

  Widget _buildPortraitLayout(ThemeData theme) {
    return Center(
      child: Container(
        constraints: BoxConstraints(maxWidth: 600.w),
        padding: EdgeInsets.all(32.r),
        decoration: BoxDecoration(
          color: theme.colorScheme.surface.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(32.r),
          border: Border.all(
            color: theme.colorScheme.primary.withValues(alpha: 0.2),
            width: 1.5,
          ),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            // Logo
            Image.asset(
              'assets/images/logo_transparent.png',
              width: 120.r,
              height: 120.r,
            ),
            SizedBox(height: 24.r),

            // Título
            Text(
              AppLocale.welcomeNeoStation.getString(context),
              style: TextStyle(
                fontSize: 28.r,
                fontWeight: FontWeight.bold,
                color: theme.colorScheme.onSurface,
              ),
              textAlign: TextAlign.center,
            ),
            SizedBox(height: 12.r),

            Text(
              AppLocale.letsGetSetup.getString(context),
              style: TextStyle(
                fontSize: 16.r,
                color: theme.colorScheme.onSurface.withValues(alpha: 0.7),
              ),
              textAlign: TextAlign.center,
            ),

            SizedBox(height: 48.r),

            // Progress indicator
            _buildProgressIndicator(theme),

            SizedBox(height: 32.r),

            // Step content
            Expanded(child: _buildStepContent(theme)),

            SizedBox(height: 24.r),

            // Navigation buttons
            _buildNavigationButtons(theme),
          ],
        ),
      ),
    );
  }

  Widget _buildLandscapeLayout(ThemeData theme) {
    return Padding(
      padding: EdgeInsets.all(16.r),
      child: Row(
        children: [
          // Left side: Logo and title
          Expanded(
            flex: 2,
            child: Container(
              padding: EdgeInsets.all(24.r),
              decoration: BoxDecoration(
                color: theme.colorScheme.surface.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(24.r),
                border: Border.all(
                  color: theme.colorScheme.primary.withValues(alpha: 0.1),
                  width: 1.r,
                ),
              ),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Image.asset(
                    'assets/images/logo_transparent.png',
                    width: 64.r,
                    height: 64.r,
                  ),
                  SizedBox(height: 12.r),

                  Text(
                    AppLocale.welcomeNeoStation.getString(context),
                    style: TextStyle(
                      fontSize: 14.r,
                      fontWeight: FontWeight.bold,
                      color: theme.colorScheme.onSurface,
                    ),
                    textAlign: TextAlign.center,
                  ),
                  SizedBox(height: 8.r),

                  Text(
                    AppLocale.letsGetSetup.getString(context),
                    style: TextStyle(
                      fontSize: 10.r,
                      color: theme.colorScheme.onSurface.withValues(alpha: 0.7),
                    ),
                    textAlign: TextAlign.center,
                  ),

                  SizedBox(height: 16.r),

                  // Progress indicator vertical — scaled to fit the remaining
                  // card height so it never overflows regardless of step count.
                  Flexible(
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      child: _buildVerticalProgressIndicator(theme),
                    ),
                  ),
                ],
              ),
            ),
          ),

          SizedBox(width: 16.r),

          // Right side: Content and navigation
          Expanded(
            flex: 3,
            child: Container(
              padding: EdgeInsets.all(16.r),
              decoration: BoxDecoration(
                color: theme.colorScheme.surface.withValues(alpha: 0.05),
                borderRadius: BorderRadius.circular(24.r),
                border: Border.all(
                  color: theme.colorScheme.primary.withValues(alpha: 0.05),
                  width: 1.r,
                ),
              ),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Expanded(
                    child: Center(
                      child: Container(
                        constraints: BoxConstraints(maxWidth: 400.w),
                        child: _buildStepContent(theme),
                      ),
                    ),
                  ),

                  SizedBox(height: 8.r),

                  // Navigation buttons
                  _buildNavigationButtons(theme),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildVerticalProgressIndicator(ThemeData theme) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: List.generate(_totalSteps, (index) {
        final isCompleted = index < _currentStep;
        final isCurrent = index == _currentStep;

        return Column(
          children: [
            Container(
              width: 24.r,
              height: 24.r,
              decoration: BoxDecoration(
                color: isCompleted || isCurrent
                    ? theme.colorScheme.primary
                    : Colors.transparent,
                shape: BoxShape.circle,
                border: Border.all(
                  color: isCompleted || isCurrent
                      ? theme.colorScheme.primary
                      : theme.colorScheme.primary.withValues(alpha: 0.3),
                  width: 2.r,
                ),
              ),
              child: Center(
                child: isCompleted
                    ? Icon(
                        Symbols.check_rounded,
                        color: Colors.white,
                        size: 14.r,
                      )
                    : Text(
                        '${index + 1}',
                        style: TextStyle(
                          fontSize: 10.r,
                          fontWeight: FontWeight.bold,
                          color: isCurrent
                              ? Colors.white
                              : theme.colorScheme.primary.withValues(
                                  alpha: 0.5,
                                ),
                        ),
                      ),
              ),
            ),
            if (index < _totalSteps - 1)
              Container(
                width: 2.r,
                height: 18.r,
                color: isCompleted
                    ? theme.colorScheme.primary
                    : theme.colorScheme.primary.withValues(alpha: 0.2),
              ),
          ],
        );
      }),
    );
  }

  Widget _buildProgressIndicator(ThemeData theme) {
    // Scale down to fit the screen width so the extra steps don't overflow.
    return FittedBox(
      fit: BoxFit.scaleDown,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: List.generate(_totalSteps, (index) {
          final isCompleted = index < _currentStep;
          final isCurrent = index == _currentStep;

          return Row(
            children: [
              Container(
                width: 40.r,
                height: 40.r,
                decoration: BoxDecoration(
                  color: isCompleted || isCurrent
                      ? theme.colorScheme.primary
                      : Colors.transparent,
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: isCompleted || isCurrent
                        ? theme.colorScheme.primary
                        : theme.colorScheme.primary.withValues(alpha: 0.3),
                    width: 2.r,
                  ),
                ),
                child: Center(
                  child: isCompleted
                      ? Icon(
                          Symbols.check_rounded,
                          color: Colors.white,
                          size: 24.r,
                        )
                      : Text(
                          '${index + 1}',
                          style: TextStyle(
                            fontSize: 18.r,
                            fontWeight: FontWeight.bold,
                            color: isCurrent
                                ? Colors.white
                                : theme.colorScheme.primary.withValues(
                                    alpha: 0.5,
                                  ),
                          ),
                        ),
                ),
              ),
              if (index < _totalSteps - 1)
                Container(
                  width: 40.r,
                  height: 2.r,
                  color: isCompleted
                      ? theme.colorScheme.primary
                      : theme.colorScheme.primary.withValues(alpha: 0.2),
                ),
            ],
          );
        }),
      ),
    );
  }

  Widget _buildStepContent(ThemeData theme) {
    if (_currentStep == _stepUserData) {
      return _buildUserDataLocationStep(theme);
    }
    if (_currentStep == _stepPermissions) {
      return _buildPermissionStep(theme);
    }
    if (_currentStep == _stepFolder) {
      return _buildFolderSelectionStep(theme);
    }
    if (_currentStep == _stepScanning) {
      return _buildScanningStep(theme);
    }
    if (_currentStep == _stepEsde) {
      return _buildEsdeStep(theme);
    }
    if (_currentStep == _stepArtPack) {
      return _buildArtPackStep(theme);
    }
    return Container();
  }

  Widget _buildUserDataLocationStep(ThemeData theme) {
    final orientation = MediaQuery.of(context).orientation;
    final isLandscape = orientation == Orientation.landscape;
    final iconSize = isLandscape ? 48.r : 80.r;
    final titleSize = isLandscape ? 14.r : 24.r;
    final textSize = isLandscape ? 10.r : 14.r;

    return SingleChildScrollView(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Symbols.folder_special_rounded,
            size: iconSize,
            color: _selectedUserDataPath != null
                ? theme.colorScheme.primary
                : theme.colorScheme.primary.withValues(alpha: 0.6),
          ),
          SizedBox(height: isLandscape ? 16.r : 24.r),

          Text(
            AppLocale.userDataLocation.getString(context),
            style: TextStyle(
              fontSize: titleSize,
              fontWeight: FontWeight.bold,
              color: theme.colorScheme.onSurface,
            ),
            textAlign: TextAlign.center,
          ),
          SizedBox(height: isLandscape ? 8.r : 16.r),

          Text(
            AppLocale.userDataLocationSubtitle.getString(context),
            style: TextStyle(
              fontSize: textSize,
              color: theme.colorScheme.onSurface.withValues(alpha: 0.7),
              height: 1.3,
            ),
            textAlign: TextAlign.center,
          ),

          if (_selectedUserDataPath != null) ...[
            SizedBox(height: isLandscape ? 8.r : 16.r),
            Container(
              padding: EdgeInsets.all(10.r),
              decoration: BoxDecoration(
                color: theme.colorScheme.primary.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(8.r),
                border: Border.all(
                  color: theme.colorScheme.primary.withValues(alpha: 0.2),
                ),
              ),
              child: Row(
                children: [
                  Icon(
                    Symbols.folder_rounded,
                    size: 16.r,
                    color: theme.colorScheme.primary,
                  ),
                  SizedBox(width: 8.r),
                  Expanded(
                    child: Text(
                      _selectedUserDataPath!,
                      style: TextStyle(
                        fontSize: 11.r,
                        color: theme.colorScheme.onSurface,
                        fontFamily: 'monospace',
                      ),
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            ),
          ],

          SizedBox(height: isLandscape ? 12.r : 20.r),

          // "Change Location" inline button
          GamepadControl(
            icon: Symbols.folder_rounded,
            label: AppLocale.selectUserDataFolder.getString(context),
            onTap: _isSelectingUserDataFolder
                ? null
                : () => _selectUserDataLocationWizard(),
            busy: _isSelectingUserDataFolder,
            textColor: theme.colorScheme.primary,
          ),
        ],
      ),
    );
  }

  void _showUserDataNotWritable() {
    var message = AppLocale.userDataFolderNotWritable.getString(context);
    if (Platform.isAndroid) {
      message +=
          '\n${AppLocale.userDataFolderGrantAllFiles.getString(context)}';
    }
    GlobalNotificationService().show(
      id: 'wizard_user_data_not_writable',
      message: message,
      type: GlobalNotificationType.error,
    );
  }

  /// Opens a folder picker, saves the new user-data path, and reinitializes the DB.
  Future<void> _selectUserDataLocationWizard() async {
    setState(() => _isSelectingUserDataFolder = true);
    _gamepadNav?.deactivate();

    try {
      String? selected;

      if (Platform.isAndroid) {
        final isTV = await PermissionService.isTelevision();
        if (isTV) {
          if (mounted) selected = await TvDirectoryPicker.show(context);
        } else {
          // Regular Android: same SAF picker as ROM folder selection.
          // Convert content:// URI to real filesystem path for SQLite access.
          try {
            final uri = await PermissionService.requestFolderAccess();
            if (uri != null) {
              selected = UserDataLocationService.safUriToRealPath(
                uri.toString(),
              );
            }
          } on PlatformException catch (e) {
            if (e.code == 'PICKER_FAILED' && mounted) {
              selected = await TvDirectoryPicker.show(context);
            }
          }
        }
      } else {
        selected = await TvDirectoryPicker.pickDirectory(
          context,
          dialogTitle: AppLocale.selectUserDataFolder.getString(context),
          initialDirectory: _selectedUserDataPath,
        );
      }

      if (selected == null || !mounted) return;

      // Normalize trailing separator.
      if (selected.endsWith(Platform.pathSeparator)) {
        selected = selected.substring(0, selected.length - 1);
      }

      if (selected == _selectedUserDataPath) return;

      // Refuse a folder the database can't be created in. On Android this
      // step runs before the permissions step, so without All-Files access a
      // folder like /storage/emulated/0/Emulation lists fine but can't be
      // written. Saving it anyway left SQLite failing with code 14 on every
      // launch, stuck on an empty library.
      if (!await UserDataLocationService.canWriteDirectory(selected)) {
        if (mounted) _showUserDataNotWritable();
        return;
      }

      // Warn if the chosen folder already contains files, so the user doesn't
      // unknowingly store NeoStation's data inside an existing library.
      final entryCount = await UserDataLocationService.countDirectoryEntries(
        selected,
      );
      if (!mounted) return;
      if (entryCount > 0) {
        final proceed = await FolderNotEmptyDialog.show(
          context,
          path: selected,
          itemCount: entryCount,
        );
        if (!proceed || !mounted) return;
      }

      final previousCustomPath = await UserDataLocationService.getCustomPath();
      await UserDataLocationService.setCustomPath(selected);

      // Reinitialize the DB at the new path (no data yet on first launch).
      if (!mounted) return;
      final configProvider = Provider.of<SqliteConfigProvider>(
        context,
        listen: false,
      );
      await configProvider.reinitialize();

      // The provider swallows its own init errors, so ask whether the database
      // itself opened. Not `error`: that also catches unrelated startup steps,
      // and reverting on those would undo a folder that works. A folder that
      // passed the probe can still refuse the database; put the previous
      // location back rather than persist one that never opens.
      if (!configProvider.databaseOpened) {
        _log.e(
          'Wizard: database failed to open at $selected, restoring '
          '${previousCustomPath ?? 'default location'}',
        );
        if (previousCustomPath != null) {
          await UserDataLocationService.setCustomPath(previousCustomPath);
        } else {
          await UserDataLocationService.clearCustomPath();
        }
        await configProvider.reinitialize();
        if (mounted) _showUserDataNotWritable();
        selected = await ConfigService.getUserDataPath();
      }

      // The database is now open at the new path, but this provider resolved
      // its cache directory and active theme against the old one at launch.
      // Without this the art pack downloaded on the final step lands in the
      // folder the app started in, and is gone on the next launch even though
      // System Art still shows the pack as applied.
      if (!mounted) return;
      await context.read<NeoAssetsProvider>().reinitialize();

      if (mounted) setState(() => _selectedUserDataPath = selected);
    } catch (e) {
      _log.e('User data location selection failed in wizard: $e');
    } finally {
      if (mounted) setState(() => _isSelectingUserDataFolder = false);
      _gamepadNav?.activate();
    }
  }

  /// Combined permissions step: All-Files (storage) access plus the optional
  /// accessibility (Screen Return) service, each with a live granted/pending
  /// status. The main action button grants the next pending one, then advances.
  Widget _buildPermissionStep(ThemeData theme) {
    final orientation = MediaQuery.of(context).orientation;
    final isLandscape = orientation == Orientation.landscape;

    return SingleChildScrollView(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildPermissionRow(
            theme,
            icon: Symbols.security_rounded,
            title: AppLocale.storagePermission.getString(context),
            description: AppLocale.storagePermissionDesc.getString(context),
            granted: _storageGranted,
            isLandscape: isLandscape,
          ),
          // Screen Return access only applies to dual-screen devices.
          if (_needsAccessibility) ...[
            SizedBox(height: isLandscape ? 12.r : 20.r),
            _buildPermissionRow(
              theme,
              icon: Symbols.settings_accessibility_rounded,
              title: AppLocale.screenReturnAccess.getString(context),
              description: AppLocale.screenReturnAccessDesc.getString(context),
              granted: _accessibilityGranted,
              isLandscape: isLandscape,
              hint: AppLocale.screenReturnAccessHint.getString(context),
            ),
          ],
        ],
      ),
    );
  }

  /// A single permission entry: leading semantic icon, title + description, and
  /// a trailing status indicator that turns into a green check once granted.
  Widget _buildPermissionRow(
    ThemeData theme, {
    required IconData icon,
    required String title,
    required String description,
    required bool granted,
    required bool isLandscape,
    String? hint,
  }) {
    final iconSize = isLandscape ? 28.r : 40.r;
    final titleSize = isLandscape ? 13.r : 18.r;
    final textSize = isLandscape ? 9.r : 13.r;

    return Container(
      padding: EdgeInsets.all(isLandscape ? 12.r : 16.r),
      decoration: BoxDecoration(
        color: theme.colorScheme.onSurface.withValues(alpha: 0.04),
        borderRadius: BorderRadius.circular(16.r),
        border: Border.all(
          color: granted
              ? Colors.green.withValues(alpha: 0.5)
              : theme.colorScheme.onSurface.withValues(alpha: 0.1),
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            icon,
            size: iconSize,
            color: granted ? Colors.green : theme.colorScheme.primary,
          ),
          SizedBox(width: isLandscape ? 12.r : 16.r),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    fontSize: titleSize,
                    fontWeight: FontWeight.bold,
                    color: theme.colorScheme.onSurface,
                  ),
                ),
                SizedBox(height: 4.r),
                Text(
                  granted ? AppLocale.enabled.getString(context) : description,
                  style: TextStyle(
                    fontSize: textSize,
                    color: granted
                        ? Colors.green
                        : theme.colorScheme.onSurface.withValues(alpha: 0.7),
                    height: 1.3,
                  ),
                ),
                if (!granted && hint != null) ...[
                  SizedBox(height: 6.r),
                  Text(
                    hint,
                    style: TextStyle(
                      fontSize: textSize,
                      fontWeight: FontWeight.w600,
                      color: theme.colorScheme.primary,
                      height: 1.3,
                    ),
                  ),
                ],
              ],
            ),
          ),
          SizedBox(width: isLandscape ? 8.r : 12.r),
          Icon(
            granted
                ? Symbols.check_circle_rounded
                : Symbols.radio_button_unchecked_rounded,
            size: isLandscape ? 20.r : 26.r,
            color: granted
                ? Colors.green
                : theme.colorScheme.onSurface.withValues(alpha: 0.3),
          ),
        ],
      ),
    );
  }

  Widget _buildFolderSelectionStep(ThemeData theme) {
    final orientation = MediaQuery.of(context).orientation;
    final isLandscape = orientation == Orientation.landscape;
    final iconSize = isLandscape ? 48.r : 80.r;
    final titleSize = isLandscape ? 14.r : 24.r;
    final textSize = isLandscape ? 10.r : 14.r;

    return SingleChildScrollView(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Symbols.folder_open_rounded,
            size: iconSize,
            color: _selectedFolder != null
                ? Colors.green
                : theme.colorScheme.primary,
          ),
          SizedBox(height: isLandscape ? 16.r : 24.r),

          Text(
            AppLocale.selectRomFolder.getString(context),
            style: TextStyle(
              fontSize: titleSize,
              fontWeight: FontWeight.bold,
              color: theme.colorScheme.onSurface,
            ),
          ),
          SizedBox(height: isLandscape ? 8.r : 16.r),

          Text(
            _selectedFolder != null
                ? '${AppLocale.romFolderSelected.getString(context)}\n\n$_selectedFolder'
                : AppLocale.chooseRomFolderDesc.getString(context),
            style: TextStyle(
              fontSize: textSize,
              color: theme.colorScheme.onSurface.withValues(alpha: 0.7),
              height: 1.3,
            ),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }

  Widget _buildScanningStep(ThemeData theme) {
    final orientation = MediaQuery.of(context).orientation;
    final isLandscape = orientation == Orientation.landscape;
    final containerSize = isLandscape ? 48.r : 80.r;
    final iconSize = isLandscape ? 24.r : 48.r;
    final titleSize = isLandscape ? 16.r : 24.r;
    final textSize = isLandscape ? 12.r : 14.r;

    return Consumer<SqliteConfigProvider>(
      builder: (context, provider, child) {
        return SingleChildScrollView(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              // Scanning icon
              Container(
                width: containerSize,
                height: containerSize,
                decoration: BoxDecoration(
                  color: theme.colorScheme.primary.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(containerSize / 2),
                ),
                child: Center(
                  child: provider.scanCompleted
                      ? Icon(
                          Symbols.check_circle_rounded,
                          color: Colors.green,
                          size: iconSize,
                        )
                      : SizedBox(
                          width: iconSize,
                          height: iconSize,
                          child: CircularProgressIndicator(
                            color: theme.colorScheme.primary,
                            strokeWidth: 3.r,
                          ),
                        ),
                ),
              ),
              SizedBox(height: isLandscape ? 4.r : 24.r),

              Text(
                provider.scanCompleted
                    ? AppLocale.wizardScanComplete.getString(context)
                    : AppLocale.scanningRoms.getString(context),
                style: TextStyle(
                  fontSize: titleSize,
                  fontWeight: FontWeight.bold,
                  color: theme.colorScheme.onSurface,
                ),
              ),
              SizedBox(height: isLandscape ? 4.r : 16.r),

              Text(
                provider.scanStatus.isNotEmpty
                    ? provider.scanStatus
                    : AppLocale.scanningSystemsRoms.getString(context),
                style: TextStyle(
                  fontSize: textSize,
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.7),
                  height: 1.3,
                ),
                textAlign: TextAlign.center,
              ),

              // Progress bar
              if (provider.totalSystemsToScan > 0 &&
                  !provider.scanCompleted) ...[
                SizedBox(height: isLandscape ? 4.r : 32.r),
                ClipRRect(
                  borderRadius: BorderRadius.circular(8.r),
                  child: LinearProgressIndicator(
                    value: provider.scanProgress,
                    minHeight: 8.r,
                    backgroundColor: theme.colorScheme.primary.withValues(
                      alpha: 0.1,
                    ),
                    valueColor: AlwaysStoppedAnimation<Color>(
                      theme.colorScheme.primary,
                    ),
                  ),
                ),
                SizedBox(height: 8.r),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      AppLocale.ofSystems
                          .getString(context)
                          .replaceFirst(
                            '{scanned}',
                            provider.scannedSystemsCount.toString(),
                          )
                          .replaceFirst(
                            '{total}',
                            provider.totalSystemsToScan.toString(),
                          ),
                      style: TextStyle(
                        fontSize: textSize - 2.r,
                        color: theme.colorScheme.onSurface.withValues(
                          alpha: 0.6,
                        ),
                      ),
                    ),
                    Text(
                      '${(provider.scanProgress * 100).toInt()}%',
                      style: TextStyle(
                        fontSize: textSize - 2.r,
                        color: theme.colorScheme.primary,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
              ],

              if (provider.scanCompleted) ...[
                SizedBox(height: isLandscape ? 4.r : 32.r),
                Container(
                  padding: EdgeInsets.all(isLandscape ? 12.r : 16.r),
                  decoration: BoxDecoration(
                    color: Colors.green.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(12.r),
                    border: Border.all(
                      color: Colors.green.withValues(alpha: 0.3),
                      width: 1.r,
                    ),
                  ),
                  child: Row(
                    children: [
                      Icon(
                        Symbols.check_circle_rounded,
                        color: Colors.green,
                        size: isLandscape ? 20.r : 24.r,
                      ),
                      SizedBox(width: 12.r),
                      Expanded(
                        child: Text(
                          '${AppLocale.foundSystemsWithGames.getString(context).replaceFirst('{count}', provider.detectedRealSystems.length.toString())}\n${AppLocale.wizardTapNextToContinue.getString(context)}',
                          style: TextStyle(
                            fontSize: textSize,
                            color: Colors.green[700],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ],
          ),
        );
      },
    );
  }

  // ---------------------------------------------------------------------------
  // ES-DE import step (optional)
  // ---------------------------------------------------------------------------

  Widget _buildEsdeStep(ThemeData theme) {
    final orientation = MediaQuery.of(context).orientation;
    final isLandscape = orientation == Orientation.landscape;
    final iconSize = isLandscape ? 48.r : 80.r;
    final titleSize = isLandscape ? 16.r : 24.r;
    final textSize = isLandscape ? 12.r : 14.r;
    final result = _esdeResult;

    return SingleChildScrollView(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            result != null
                ? Symbols.check_circle_rounded
                : Symbols.download_for_offline_rounded,
            size: iconSize,
            color: result != null ? Colors.green : theme.colorScheme.primary,
          ),
          SizedBox(height: isLandscape ? 16.r : 24.r),

          Text(
            AppLocale.wizardEsdeStepTitle.getString(context),
            style: TextStyle(
              fontSize: titleSize,
              fontWeight: FontWeight.bold,
              color: theme.colorScheme.onSurface,
            ),
            textAlign: TextAlign.center,
          ),
          SizedBox(height: isLandscape ? 8.r : 16.r),

          Text(
            AppLocale.wizardEsdeStepDesc.getString(context),
            style: TextStyle(
              fontSize: textSize,
              color: theme.colorScheme.onSurface.withValues(alpha: 0.7),
              height: 1.3,
            ),
            textAlign: TextAlign.center,
          ),

          // Live progress while importing.
          if (_isImportingEsde) ...[
            SizedBox(height: isLandscape ? 12.r : 28.r),
            SizedBox(
              width: 220.r,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(8.r),
                child: LinearProgressIndicator(
                  value: _esdeProgress > 0 ? _esdeProgress : null,
                  minHeight: 8.r,
                  backgroundColor: theme.colorScheme.primary.withValues(
                    alpha: 0.1,
                  ),
                  valueColor: AlwaysStoppedAnimation<Color>(
                    theme.colorScheme.primary,
                  ),
                ),
              ),
            ),
            if (_esdeLabel.isNotEmpty) ...[
              SizedBox(height: 8.r),
              Text(
                _esdeLabel,
                style: TextStyle(
                  fontSize: textSize - 2.r,
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
                ),
                textAlign: TextAlign.center,
              ),
            ],
          ],

          // Import result summary.
          if (result != null) ...[
            SizedBox(height: isLandscape ? 12.r : 28.r),
            Container(
              padding: EdgeInsets.all(isLandscape ? 12.r : 16.r),
              decoration: BoxDecoration(
                color: Colors.green.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(12.r),
                border: Border.all(
                  color: Colors.green.withValues(alpha: 0.3),
                  width: 1.r,
                ),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Symbols.check_circle_rounded,
                    color: Colors.green,
                    size: isLandscape ? 20.r : 24.r,
                  ),
                  SizedBox(width: 12.r),
                  Flexible(
                    child: Text(
                      '${AppLocale.esdeImportComplete.getString(context)}\n'
                      '${result.gamesImported} '
                      '${AppLocale.esdeSummaryGames.getString(context)}, '
                      '${result.systemsMatched} '
                      '${AppLocale.esdeSummarySystems.getString(context)}',
                      style: TextStyle(
                        fontSize: textSize,
                        color: Colors.green[700],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // System art pack step (optional, heavily recommended)
  // ---------------------------------------------------------------------------

  Widget _buildArtPackStep(ThemeData theme) {
    final orientation = MediaQuery.of(context).orientation;
    final isLandscape = orientation == Orientation.landscape;
    final iconSize = isLandscape ? 48.r : 80.r;
    final titleSize = isLandscape ? 16.r : 24.r;
    final textSize = isLandscape ? 12.r : 14.r;

    return Consumer<NeoAssetsProvider>(
      builder: (context, neoAssets, child) {
        final hasTheme = neoAssets.hasActiveTheme;
        final unavailable = neoAssets.themes.isEmpty;
        final themes = neoAssets.themes;
        // The selected pack: the user's choice, or the recommended (first
        // non-AI) pack until they pick one.
        final selectedFolder = _selectedArtPackFolder.isNotEmpty
            ? _selectedArtPackFolder
            : (themes.isEmpty
                  ? ''
                  : themes
                        .firstWhere((t) => !t.isAi, orElse: () => themes.first)
                        .folder);
        if (_artPackKeys.length != themes.length) {
          _artPackKeys
            ..clear()
            ..addAll(List.generate(themes.length, (_) => GlobalKey()));
        }
        return SingleChildScrollView(
          controller: _artPackScrollController,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              // Smaller icon + tighter spacing so the compact thumbnail below
              // fits without scrolling.
              Icon(
                hasTheme
                    ? Symbols.check_circle_rounded
                    : Symbols.palette_rounded,
                size: iconSize * 0.7,
                color: hasTheme ? Colors.green : theme.colorScheme.primary,
              ),
              SizedBox(height: isLandscape ? 10.r : 16.r),

              Text(
                AppLocale.wizardArtPackTitle.getString(context),
                style: TextStyle(
                  fontSize: titleSize,
                  fontWeight: FontWeight.bold,
                  color: theme.colorScheme.onSurface,
                ),
                textAlign: TextAlign.center,
              ),
              SizedBox(height: isLandscape ? 6.r : 12.r),

              Text(
                hasTheme
                    ? AppLocale.wizardArtPackInstalled.getString(context)
                    : unavailable
                    ? AppLocale.wizardArtPackUnavailable.getString(context)
                    : AppLocale.wizardArtPackDesc.getString(context),
                style: TextStyle(
                  fontSize: textSize,
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.7),
                  height: 1.3,
                ),
                textAlign: TextAlign.center,
              ),

              // The pack list. Tapping a row selects it; the main button
              // downloads the selected pack.
              if (!unavailable && !neoAssets.downloading) ...[
                SizedBox(height: isLandscape ? 10.r : 16.r),
                for (int i = 0; i < themes.length; i++)
                  SystemArtPackTile(
                    key: _artPackKeys[i],
                    pack: themes[i],
                    mosaicSize: isLandscape ? 48 : 56,
                    isSelected: themes[i].folder == selectedFolder,
                    isActive: neoAssets.isThemeActive(themes[i].folder),
                    onTap: () => setState(
                      () => _selectedArtPackFolder = themes[i].folder,
                    ),
                  ),
              ],

              // Live download progress.
              if (neoAssets.downloading) ...[
                SizedBox(height: isLandscape ? 12.r : 28.r),
                SizedBox(
                  width: 220.r,
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(8.r),
                    child: LinearProgressIndicator(
                      value: neoAssets.downloadProgress > 0
                          ? neoAssets.downloadProgress
                          : null,
                      minHeight: 8.r,
                      backgroundColor: theme.colorScheme.primary.withValues(
                        alpha: 0.1,
                      ),
                      valueColor: AlwaysStoppedAnimation<Color>(
                        theme.colorScheme.primary,
                      ),
                    ),
                  ),
                ),
                SizedBox(height: 8.r),
                Text(
                  '${(neoAssets.downloadProgress * 100).toInt()}%',
                  style: TextStyle(
                    fontSize: textSize,
                    color: theme.colorScheme.primary,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ],
          ),
        );
      },
    );
  }

  /// Combined ES-DE folder pick + import for the wizard step. Picks the ES-DE
  /// root, persists it, runs the import with progress, and surfaces the result.
  Future<void> _runWizardEsdeImport() async {
    if (_isImportingEsde) return;

    // Pick the ES-DE root folder (platform-branched, mirrors the Directories
    // settings picker).
    String? selected;
    _gamepadNav?.deactivate();
    try {
      if (Platform.isAndroid) {
        final isTV = await PermissionService.isTelevision();
        if (!mounted) return;
        if (isTV) {
          selected = await TvDirectoryPicker.show(context);
        } else {
          try {
            final uri = await PermissionService.requestFolderAccess();
            if (uri != null) {
              final uriStr = uri.toString();
              final hasFiles = await PermissionService.hasAllFilesAccess();
              selected =
                  await UserDataLocationService.resolveAndroidUserDataPath(
                    uriStr,
                    hasAllFilesAccess: hasFiles,
                  ) ??
                  UserDataLocationService.safUriToRealPath(uriStr);
            }
          } on PlatformException catch (e) {
            if (e.code == 'PICKER_FAILED' && mounted) {
              selected = await TvDirectoryPicker.show(context);
            }
          }
        }
      } else {
        selected = await TvDirectoryPicker.pickDirectory(
          context,
          dialogTitle: AppLocale.esdeSelectFolder.getString(context),
        );
      }
    } finally {
      _gamepadNav?.activate();
    }

    if (selected == null || !mounted) return;
    if (selected.endsWith(Platform.pathSeparator)) {
      selected = selected.substring(0, selected.length - 1);
    }

    // Resolve ES-DE strings before the async import so progress callbacks can
    // use them without a BuildContext.
    final localeEsdeImporting = AppLocale.esdeImporting.getString(context);
    final localeEsdeImportNotEsdeFolder = AppLocale.esdeImportNotEsdeFolder
        .getString(context);
    final localeEsdeImportNothingFound = AppLocale.esdeImportNothingFound
        .getString(context);
    final localeEsdeImportComplete = AppLocale.esdeImportComplete.getString(
      context,
    );
    final localeEsdeSummaryGames = AppLocale.esdeSummaryGames.getString(
      context,
    );
    final localeEsdeSummarySystems = AppLocale.esdeSummarySystems.getString(
      context,
    );

    await context.read<SqliteConfigProvider>().updateEsdeFolderPath(selected);

    setState(() {
      _isImportingEsde = true;
      _esdeProgress = 0.0;
      _esdeLabel = '';
    });

    const notificationId = 'esde_import_progress';
    GlobalNotificationService().show(
      id: notificationId,
      message: localeEsdeImporting,
      type: GlobalNotificationType.info,
      progress: 0,
      ongoing: true,
    );

    EsdeImportResult? result;
    String? error;
    try {
      result = await EsdeImportService.import(
        selected,
        onProgress: (p, label) {
          if (mounted) {
            setState(() {
              _esdeProgress = p;
              _esdeLabel = label;
            });
          }
          GlobalNotificationService().update(
            id: notificationId,
            message: label.isEmpty
                ? localeEsdeImporting
                : '$localeEsdeImporting: $label',
            type: GlobalNotificationType.info,
            progress: p,
            ongoing: true,
          );
        },
      );
      // Rebuild the artwork fallback map now esde_media_dir rows exist.
      if (mounted) await context.read<FileProvider>().refreshEsde();
    } catch (e) {
      error = e.toString();
      _log.e('Wizard ES-DE import failed: $e');
    }

    if (!mounted) return;

    final matched =
        error == null &&
        result != null &&
        result.gamelistsDirFound &&
        (result.gamesImported > 0 || result.systemsMatched > 0);

    setState(() {
      _isImportingEsde = false;
      _esdeResult = matched ? result : null;
    });

    if (error != null) {
      GlobalNotificationService().update(
        id: notificationId,
        message: error,
        type: GlobalNotificationType.error,
        progress: null,
      );
    } else if (result != null && !result.gamelistsDirFound) {
      GlobalNotificationService().update(
        id: notificationId,
        message: localeEsdeImportNotEsdeFolder,
        type: GlobalNotificationType.error,
        progress: null,
      );
    } else if (!matched) {
      GlobalNotificationService().update(
        id: notificationId,
        message: localeEsdeImportNothingFound,
        type: GlobalNotificationType.info,
        progress: null,
      );
    } else {
      final importResult = result;
      GlobalNotificationService().update(
        id: notificationId,
        message:
            '$localeEsdeImportComplete: '
            '${importResult.gamesImported} $localeEsdeSummaryGames, '
            '${importResult.systemsMatched} $localeEsdeSummarySystems',
        type: GlobalNotificationType.success,
        progress: null,
      );
    }
  }

  /// Downloads and applies the recommended NeoStation art pack (the first
  /// non-AI theme in the manifest) for the wizard's art-pack step.
  Future<void> _downloadWizardArtPack() async {
    if (_isDownloadingArt) return;
    final neoAssets = context.read<NeoAssetsProvider>();
    final themes = neoAssets.themes;
    if (themes.isEmpty) return;

    // The pack the user selected in the list, or the recommended (first non-AI)
    // pack until they pick one.
    final selectedFolder = _effectiveArtPackFolder(neoAssets);
    final selected = themes.firstWhere(
      (t) => t.folder == selectedFolder,
      orElse: () => themes.first,
    );

    final systemFolders = context
        .read<SqliteConfigProvider>()
        .availableSystems
        .where((s) => s.folderName != 'all-background')
        .map((s) => s.folderName)
        .toList();

    setState(() => _isDownloadingArt = true);
    bool applied = false;
    try {
      applied = await neoAssets.downloadAndApplyTheme(
        selected.folder,
        systemFolders,
      );
    } catch (e) {
      _log.e('Wizard art pack download failed: $e');
    }
    if (!mounted) return;
    setState(() => _isDownloadingArt = false);

    // A failed download leaves the step exactly as it was — the button reads
    // "Download Art Pack" again, so the user can retry or skip past it. Ending
    // setup here instead would drop them into an app whose art never arrived
    // with nothing said about it.
    if (!applied) {
      _log.w('Art pack was not applied; staying on the wizard art-pack step');
      return;
    }

    // Downloading the pack is the final action — finish setup directly instead
    // of making the user press Finish on a redundant "installed" screen.
    await _finishSetup();
  }

  Widget _buildNavigationButtons(ThemeData theme) {
    // The scanning step advances to the optional ES-DE step once complete.
    final isInScanningStep = _currentStep == _stepScanning;

    if (isInScanningStep) {
      return Consumer<SqliteConfigProvider>(
        builder: (context, provider, child) {
          return Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              // Next button only when scan completes
              GamepadControl(
                iconPath: 'assets/images/gamepad/Xbox_A_button.png',
                label: AppLocale.next.getString(context),
                onTap: provider.scanCompleted
                    ? () => _handleMainAction()
                    : null,
                backgroundColor: theme.colorScheme.primary,
                textColor: theme.colorScheme.onPrimary,
              ),
            ],
          );
        },
      );
    }

    // For other steps, use normal logic.
    // Skip is offered on the optional steps: the folder and permissions steps
    // (Android only), plus the two trailing optional steps (ES-DE import, art
    // pack) on every platform. The permissions step always offers it — see
    // _handleSkip for why it must never be gated on a grant succeeding.
    final showSkip =
        _currentStep == _stepEsde ||
        _currentStep == _stepArtPack ||
        (Platform.isAndroid &&
            (_currentStep == _stepFolder || _currentStep == _stepPermissions));
    // Wrapped in a NeoAssets consumer so the art-pack step's button label
    // (Download vs Finish) stays in sync with the live theme/download state —
    // otherwise a non-reactive read can show "Finish" while the action still
    // triggers a download.
    return Consumer<NeoAssetsProvider>(
      builder: (context, neoAssets, child) {
        // On the art-pack step, block the primary action while the theme
        // manifest is still loading: otherwise the button reads "Finish" (no
        // themes yet) and a press would silently complete setup with no art
        // pack even though one is about to become available.
        final artLoading =
            _currentStep == _stepArtPack &&
            !neoAssets.hasActiveTheme &&
            neoAssets.themes.isEmpty &&
            neoAssets.loading;
        return Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            if (showSkip)
              GamepadControl(
                iconPath: 'assets/images/gamepad/Xbox_B_button.png',
                label: AppLocale.skipForNow.getString(context),
                onTap: () => _handleSkip(),
                textColor: theme.colorScheme.onSurface.withValues(alpha: 0.6),
              )
            else
              SizedBox(width: 64.r),

            // Main action button
            GamepadControl(
              iconPath: 'assets/images/gamepad/Xbox_A_button.png',
              label: _getButtonText(),
              onTap:
                  (_isSelectingFolder ||
                      _isImportingEsde ||
                      _isDownloadingArt ||
                      artLoading)
                  ? null
                  : () => _handleMainAction(),
              busy: _isSelectingFolder || artLoading,
              backgroundColor: theme.colorScheme.primary,
              textColor: theme.colorScheme.onPrimary,
            ),
          ],
        );
      },
    );
  }

  String _getButtonText() {
    if (_currentStep == _stepUserData) return AppLocale.next.getString(context);
    if (_currentStep == _stepPermissions) {
      // Grant the next pending permission; once both are satisfied, advance.
      if (!_storageGranted || !_accessibilityDone) {
        return AppLocale.grantAccess.getString(context);
      }
      return AppLocale.next.getString(context);
    }
    if (_currentStep == _stepFolder) {
      return AppLocale.selectFolder.getString(context);
    }
    if (_currentStep == _stepEsde) {
      // Once an import has run, the primary action becomes "Next".
      return _esdeResult != null
          ? AppLocale.next.getString(context)
          : AppLocale.esdeRunImport.getString(context);
    }
    if (_currentStep == _stepArtPack) {
      // Offer download until the selected pack is installed (or none are
      // available), then the primary action finishes setup.
      final neoAssets = context.read<NeoAssetsProvider>();
      final canDownload =
          neoAssets.themes.isNotEmpty &&
          _effectiveArtPackFolder(neoAssets) != neoAssets.activeThemeFolder;
      return canDownload
          ? AppLocale.download.getString(context)
          : AppLocale.finish.getString(context);
    }
    return AppLocale.next.getString(context);
  }

  /// The pack the wizard would download: the user's selection, or the
  /// recommended (first non-AI) pack until they pick one.
  String _effectiveArtPackFolder(NeoAssetsProvider neoAssets) {
    final themes = neoAssets.themes;
    if (themes.isEmpty) return '';
    if (_selectedArtPackFolder.isNotEmpty) return _selectedArtPackFolder;
    return themes.firstWhere((t) => !t.isAi, orElse: () => themes.first).folder;
  }

  Future<void> _handleMainAction() async {
    // Step 0 (user data location): advance, then auto-skip the permissions step
    // if both permissions are already granted.
    if (_currentStep == _stepUserData) {
      setState(() => _currentStep = _currentStep + 1);
      if (Platform.isAndroid) {
        _refreshPermissionStates().then((_) {
          if (mounted &&
              _currentStep == _stepPermissions &&
              _storageGranted &&
              _accessibilityDone) {
            setState(() => _currentStep = _stepFolder);
          }
        });
      }
      return;
    }

    if (_currentStep == _stepPermissions) {
      await _handlePermissionAction();
      return;
    }

    if (_currentStep == _stepFolder) {
      await _selectFolder();
      return;
    }

    if (_currentStep == _stepScanning) {
      // Scan finished → advance to the optional ES-DE import step.
      setState(() => _currentStep = _stepEsde);
      return;
    }

    if (_currentStep == _stepEsde) {
      // Run the import, or advance once one has already been run.
      if (_esdeResult != null) {
        setState(() => _currentStep = _stepArtPack);
      } else {
        await _runWizardEsdeImport();
      }
      return;
    }

    if (_currentStep == _stepArtPack) {
      final neoAssets = context.read<NeoAssetsProvider>();
      final canDownload =
          neoAssets.themes.isNotEmpty &&
          _effectiveArtPackFolder(neoAssets) != neoAssets.activeThemeFolder;
      if (canDownload) {
        await _downloadWizardArtPack();
      } else {
        await _finishSetup();
      }
      return;
    }
  }

  /// Drives the combined permissions step: grants the next pending permission
  /// (storage first, then accessibility), or advances to folder once both are
  /// granted. Gamepad input is suspended around any trip to system Settings.
  Future<void> _handlePermissionAction() async {
    // Both satisfied → move on.
    if (_storageGranted && _accessibilityDone) {
      setState(() => _currentStep = _stepFolder);
      return;
    }

    // Deactivate gamepad before opening system settings to prevent key event
    // leakage when the app regains focus after the user grants the permission.
    _gamepadNav?.deactivate();
    // Safety re-arm. The request below can fail to open anything at all on
    // some ROMs, and with no Settings screen there is no resume to re-activate
    // on either — which left the wizard permanently deaf to the controller,
    // B (skip) included. Only fires while we still hold the foreground, so a
    // Settings screen that did open keeps input suspended as intended.
    _leftForegroundDuringGrant = false;
    // Deliberately not gated on still being the permissions step: a touch
    // user can tap Skip inside this window, and bailing out there would strand
    // the folder step with dead input. Holding the foreground is the only
    // condition that matters, and every route that opens another activity
    // (including the SAF picker) trips the flag first.
    Future.delayed(const Duration(seconds: 3), () {
      if (mounted && !_leftForegroundDuringGrant) _gamepadNav?.activate();
    });
    try {
      if (!_storageGranted) {
        final success = await PermissionService.requestAllFilesAccess();
        if (success && mounted) {
          context.read<SqliteConfigProvider>().refreshAllFilesAccess();
          setState(() => _storageGranted = true);
        }
      } else {
        // Accessibility can't be granted in-app — send the user to system
        // Settings. We re-check on resume (didChangeAppLifecycleState) and
        // light up the green check when they come back with it enabled.
        await ScreenshotService.openAccessSettings();
      }
    } catch (e) {
      _log.e('Error requesting permissions: $e');
    } finally {
      // Drain any pending key events before re-enabling gamepad input.
      await Future.delayed(const Duration(milliseconds: 600));
      if (mounted) _gamepadNav?.activate();
    }
  }

  Future<void> _selectFolder() async {
    if (_currentStep != _stepFolder) return;

    // Guard: prevent re-entry and stop gamepad from intercepting picker events
    setState(() {
      _isSelectingFolder = true;
    });
    _gamepadNav?.deactivate();

    try {
      final configProvider = Provider.of<SqliteConfigProvider>(
        context,
        listen: false,
      );

      String? result;

      if (Platform.isAndroid) {
        final isTV = await PermissionService.isTelevision();
        if (isTV) {
          // Android TV / Google TV: always use custom browser (SAF picker is unreliable on TV)
          if (mounted) result = await TvDirectoryPicker.show(context);
        } else {
          try {
            final uri = await PermissionService.requestFolderAccess();
            result = uri?.toString();
          } on PlatformException catch (e) {
            if (e.code == 'PICKER_FAILED' && mounted) {
              result = await TvDirectoryPicker.show(context);
            }
          }
        }

        if (result != null && mounted) {
          await configProvider.addRomFolder(result, scan: false);
        }
      } else {
        await configProvider.selectRomFolder(scan: false, context: context);
        // Provider already called addRomFolder internally; read back the path
        result = configProvider.config.romFolder;
      }

      if (result != null && mounted) {
        setState(() {
          _selectedFolder = result;
          _isSelectingFolder = false;
          _currentStep++;
        });
        WidgetsBinding.instance.addPostFrameCallback((_) {
          configProvider.scanSystems();
        });
      } else if (mounted) {
        setState(() {
          _isSelectingFolder = false;
        });
      }
    } catch (e) {
      _log.e('Error selecting folder: $e');
      if (mounted) {
        setState(() {
          _isSelectingFolder = false;
        });
      }
    } finally {
      _gamepadNav?.activate();
    }
  }

  Future<void> _finishSetup() async {
    // Stop pinning the secondary display's dock/launcher off-screen. Set before
    // any await so a rebuild racing the save can't re-assert the flag; the
    // wrapper pushes the clear once completeSetup() lands.
    _finishing = true;

    // Verificar que la configuración está guardada
    final configProvider = Provider.of<SqliteConfigProvider>(
      context,
      listen: false,
    );
    final savedFolder = configProvider.config.romFolder;

    if (savedFolder == null || savedFolder.isEmpty) {
      _log.w('Warning: ROM folder not saved in config!');
    }

    // Forzar guardado de la configuración
    await configProvider.saveConfig();

    // Llamar al callback de completado
    widget.onComplete();
  }
}
