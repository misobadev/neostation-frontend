import 'dart:io';

import 'package:neostation/widgets/wizard_frame.dart';
import 'package:neostation/widgets/wizard_language_picker.dart';
import 'package:neostation/widgets/splash_status_layout.dart';
import 'package:neostation/services/startup_language.dart';
import 'package:neostation/widgets/west_button_glyph.dart';
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
import '../widgets/info_dialog.dart';
import '../utils/rom_folder_path.dart';
import 'core_footer.dart';
import '../models/secondary_display_state.dart';

/// Initial configuration wizard for the first time the app is opened
class SetupWizard extends StatefulWidget {
  final Future<void> Function() onComplete;

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

  /// True while [_finishSetup] is saving or showing its failure, so a second
  /// press can't start another save.
  bool _saving = false;

  static final _log = LoggerService.instance;

  GamepadNavigation? _gamepadNav;

  // Step indices. Android has two extra steps (Permissions + Accessibility)
  // that don't exist on desktop; the getters resolve to -1 there so a
  // comparison against a real (>= 0) step never matches.
  //   Android: 0=Welcome, 1=Language, 2=UserData, 3=Permissions, 4=Folder,
  //            5=Scanning, 6=EsdeImport, 7=ArtPack
  //   Desktop: 0=Welcome, 1=Language, 2=UserData, 3=Folder, 4=Scanning,
  //            5=EsdeImport, 6=ArtPack
  // The Permissions step covers both All-Files access and the accessibility
  // (Screen Return) service.
  int get _stepWelcome => 0;
  int get _stepLanguage => 1;
  int get _stepUserData => 2;
  int get _stepPermissions => Platform.isAndroid ? 3 : -1;
  int get _stepFolder => Platform.isAndroid ? 4 : 3;
  int get _stepScanning => Platform.isAndroid ? 5 : 4;
  int get _stepEsde => Platform.isAndroid ? 6 : 5;
  int get _stepArtPack => Platform.isAndroid ? 7 : 6;

  /// The language shown selected on the first step.
  String _language = 'en';

  /// The art-pack step is always the final step of the wizard.
  bool get _isLastStep => _currentStep == _stepArtPack;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initLanguage();
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
          if (provider.scanCompleted || _scanFailed(provider)) {
            _handleMainAction();
          }
        } else {
          // Every step — including the final art-pack one — goes through the
          // same primary action as the on-screen button. Shortcutting the last
          // step to _finishSetup() here meant an A press completed setup
          // without ever downloading/applying the art pack.
          _handleMainAction();
        }
      },
      // B always goes back a step; the step's other action (another
      // user-data folder, or skipping an optional step) is on the West face
      // button, as in the beta import wizard.
      onBack: _handleBack,
      onWestButton: () {
        if (_currentStep == _stepUserData) {
          if (!_isSelectingUserDataFolder) _selectUserDataLocationWizard();
          return;
        }
        if (_canSkip) _handleSkip();
      },
      onNavigateUp: () => _currentStep == _stepLanguage
          ? _moveLanguage(-WizardLanguagePicker.columns)
          : _moveArtPackSelection(-1),
      onNavigateDown: () => _currentStep == _stepLanguage
          ? _moveLanguage(WizardLanguagePicker.columns)
          : _moveArtPackSelection(1),
      onNavigateLeft: () {
        if (_currentStep == _stepLanguage) _moveLanguage(-1);
      },
      onNavigateRight: () {
        if (_currentStep == _stepLanguage) _moveLanguage(1);
      },
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

  /// Whether the wizard is in the middle of something a step change would cut
  /// short: a picker, an ES-DE import or an art pack download.
  bool get _isBusy =>
      _isSelectingFolder ||
      _isSelectingUserDataFolder ||
      _isImportingEsde ||
      _isDownloadingArt;

  /// Whether this step offers Back: every step but the first, and not while
  /// it is busy or a scan is running (the scan would carry on behind the
  /// folder step and land its systems there).
  bool _canGoBack(SqliteConfigProvider provider) {
    if (_currentStep == _stepWelcome || _isBusy) return false;
    if (_currentStep == _stepScanning && provider.isScanning) return false;
    return true;
  }

  /// Back one step. The permissions step exists on Android only, and its
  /// index is skipped on the desktop by the step numbering itself.
  void _handleBack() {
    if (!_canGoBack(context.read<SqliteConfigProvider>())) return;
    setState(() => _currentStep = _currentStep - 1);
    if (_currentStep == _stepPermissions) _refreshPermissionStates();
  }

  /// The optional steps, whose other action is Skip: the folder and
  /// permissions steps (Android only), the two trailing ones (ES-DE import,
  /// art pack) everywhere, and a scan that stopped with an error.
  bool get _canSkip {
    if (_currentStep == _stepScanning) {
      return _scanFailed(context.read<SqliteConfigProvider>());
    }
    return _currentStep == _stepEsde ||
        _currentStep == _stepArtPack ||
        (Platform.isAndroid &&
            (_currentStep == _stepFolder || _currentStep == _stepPermissions));
  }

  void _handleSkip() {
    // A running ES-DE import reports its outcome on this step, and a running
    // art pack download finishes setup itself.
    if (_isImportingEsde || _isDownloadingArt) return;

    // A scan that stopped with an error can be skipped (the library is scanned
    // again on the next start, or from Settings).
    if (_currentStep == _stepScanning) {
      if (_scanFailed(context.read<SqliteConfigProvider>())) {
        setState(() => _currentStep = _stepEsde);
      }
      return;
    }
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
      // Start initial scan to detect available systems (e.g., Android apps).
      final provider = Provider.of<SqliteConfigProvider>(
        context,
        listen: false,
      );
      // A leftover error (say, from a folder that couldn't be added) would
      // read as a failed scan until the scan starts.
      provider.clearError();
      // Skip folder selection → Advance to Scanning step.
      setState(() => _currentStep = _stepScanning);

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
    // Load the current user-data path for display on the user-data step.
    _loadUserDataPath();
  }

  Future<void> _loadUserDataPath() async {
    try {
      await _resetUnwritableUserDataPath();
    } catch (e) {
      _log.e('Wizard: user-data path check failed: $e');
    }
    try {
      final p = await ConfigService.getUserDataPath();
      if (mounted) setState(() => _selectedUserDataPath = p);
    } catch (e) {
      // The folder went missing after the startup check: nothing to show.
      _log.e('Wizard: user-data path unavailable: $e');
    }
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
      await LoggerService.instance.reinitialize();
      if (!mounted) return;
      await context.read<FileProvider>().reinitialize();
    }
  }

  // Step layout:
  // Android: 0=UserData, 1=Permissions, 2=FolderSelect, 3=Scanning,
  //          4=EsdeImport, 5=ArtPack (6 steps)
  // Desktop: 0=UserData, 1=FolderSelect, 2=Scanning, 3=EsdeImport,
  //          4=ArtPack (5 steps)
  int get _totalSteps => Platform.isAndroid ? 8 : 7;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final themeProvider = Provider.of<ThemeProvider>(context);
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
          SafeArea(child: _buildLayout(theme)),
        ],
      ),
    );
  }

  /// The layout every wizard shares ([WizardFrame]): the logo and the step
  /// dots at fixed places, the step with its buttons centred under them.
  Widget _buildLayout(ThemeData theme) {
    final step = _currentStep + 1;
    return WizardFrame(
      step: step,
      total: _totalSteps,
      stepLabel: AppLocale.wizardStepOf
          .getString(context)
          .replaceAll('{step}', '$step')
          .replaceAll('{total}', '$_totalSteps'),
      color: theme.colorScheme.onSurface,
      content: _buildStepContent(theme),
      buttons: _buildNavigationButtons(theme),
    );
  }

  Widget _buildStepContent(ThemeData theme) {
    if (_currentStep == _stepWelcome) {
      return _buildWelcomeStep(theme);
    }
    if (_currentStep == _stepLanguage) {
      return _buildLanguageStep(theme);
    }
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

  /// The device's language is picked and applied straight away, so the
  /// wizard speaks it from its first screen; the language step can change it.
  void _initLanguage() {
    _language = supportedLanguageFor(
      WidgetsBinding.instance.platformDispatcher.locale,
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final provider = context.read<SqliteConfigProvider>();
      if (provider.config.appLanguage != _language) {
        provider.updateAppLanguage(_language);
      }
    });
  }

  void _selectLanguage(String code) {
    if (code == _language) return;
    setState(() => _language = code);
    context.read<SqliteConfigProvider>().updateAppLanguage(code);
  }

  void _moveLanguage(int delta) =>
      _selectLanguage(WizardLanguagePicker.move(_language, delta));

  /// The first step: what NeoStation is, and A to start.
  Widget _buildWelcomeStep(ThemeData theme) {
    // Sized as the beta import wizard's welcome, so the two read the same.
    final textScale = SplashStatusLayout.textScaleOf(context);
    return SingleChildScrollView(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(
            AppLocale.welcomeNeoStation.getString(context),
            style: TextStyle(
              fontSize: 19 * textScale,
              fontWeight: FontWeight.w600,
              color: theme.colorScheme.onSurface,
            ),
            textAlign: TextAlign.center,
          ),
          SizedBox(height: 12 * SplashStatusLayout.scaleOf(context)),
          Text(
            AppLocale.wizardWelcomeBody.getString(context),
            style: TextStyle(
              fontSize: 15 * textScale,
              height: 1.35,
              color: theme.colorScheme.onSurface.withValues(alpha: 0.75),
            ),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }

  Widget _buildLanguageStep(ThemeData theme) {
    // The welcome's text sizes: twelve languages have to fit under the
    // title on a handheld's short screen.
    final scale = SplashStatusLayout.scaleOf(context);
    final textScale = SplashStatusLayout.textScaleOf(context);

    return SingleChildScrollView(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          // The icon beside the title rather than above it, so the grid
          // keeps its room.
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Symbols.translate_rounded,
                size: 24 * textScale,
                color: theme.colorScheme.onSurface,
              ),
              SizedBox(width: 10 * scale),
              Flexible(
                child: Text(
                  AppLocale.wizardLanguageTitle.getString(context),
                  style: TextStyle(
                    fontSize: 19 * textScale,
                    fontWeight: FontWeight.w600,
                    color: theme.colorScheme.onSurface,
                  ),
                  textAlign: TextAlign.center,
                ),
              ),
            ],
          ),
          SizedBox(height: 8 * scale),
          Text(
            AppLocale.wizardLanguageBody.getString(context),
            style: TextStyle(
              fontSize: 13 * textScale,
              color: theme.colorScheme.onSurface.withValues(alpha: 0.55),
            ),
            textAlign: TextAlign.center,
          ),
          SizedBox(height: 20 * scale),
          WizardLanguagePicker(
            selected: _language,
            onSelected: _selectLanguage,
            unit: scale,
            fontSize: 14 * textScale / scale,
          ),
        ],
      ),
    );
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
        ],
      ),
    );
  }

  /// Shows [body] under [title] on screen.
  ///
  /// The app's header, and with it the notification bell, isn't shown during
  /// setup, so a message the user needs has to appear here. The wizard's
  /// navigation isn't a manager layer, so it is paused while the dialogue is
  /// open (or a press on it would also press the wizard's buttons), and only
  /// resumed if it was running: a flow that paused it resumes it itself.
  Future<void> _showWizardMessage(
    String title,
    String body, {
    IconData icon = Symbols.error_rounded,
  }) async {
    if (!mounted) return;
    final wasActive = _gamepadNav?.isActive ?? false;
    _gamepadNav?.deactivate();
    try {
      await InfoDialog.show(
        context,
        title: title,
        body: body,
        okLabel: AppLocale.ok.getString(context),
        icon: icon,
      );
    } finally {
      if (mounted && wasActive) _gamepadNav?.activate();
    }
  }

  String _userDataNotWritableMessage() {
    var message = AppLocale.userDataFolderNotWritable.getString(context);
    if (Platform.isAndroid) {
      message +=
          '\n${AppLocale.userDataFolderGrantAllFiles.getString(context)}';
    }
    return message;
  }

  /// Opens a folder picker, saves the new user-data path, and reinitialises
  /// the DB, then shows on screen why a picked folder can't be used.
  Future<void> _selectUserDataLocationWizard() async {
    final problem = await _changeUserDataLocation();
    if (problem != null && mounted) {
      await _showWizardMessage(
        AppLocale.userDataLocation.getString(context),
        problem,
      );
    }
  }

  /// [_selectUserDataLocationWizard]'s work: answers why the picked folder
  /// can't be used, or null.
  Future<String?> _changeUserDataLocation() async {
    String? problem;
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
              // A folder from another provider has no path SQLite can open.
              if (selected == null && mounted) {
                problem = AppLocale.wizardFolderNotUsable.getString(context);
              }
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

      if (selected == null || !mounted) return problem;

      // Normalize trailing separator.
      if (selected.endsWith(Platform.pathSeparator)) {
        selected = selected.substring(0, selected.length - 1);
      }

      if (selected == _selectedUserDataPath) return problem;

      // Refuse a folder the database can't be created in. On Android this
      // step runs before the permissions step, so without All-Files access a
      // folder like /storage/emulated/0/Emulation lists fine but can't be
      // written. Saving it anyway left SQLite failing with code 14 on every
      // launch, stuck on an empty library.
      if (!await UserDataLocationService.canWriteDirectory(selected)) {
        if (mounted) problem = _userDataNotWritableMessage();
        return problem;
      }

      // Warn if the chosen folder already contains files, so the user doesn't
      // unknowingly store NeoStation's data inside an existing library.
      final entryCount = await UserDataLocationService.countDirectoryEntries(
        selected,
      );
      if (!mounted) return problem;
      if (entryCount > 0) {
        final proceed = await FolderNotEmptyDialog.show(
          context,
          path: selected,
          itemCount: entryCount,
        );
        if (!proceed || !mounted) return problem;
      }

      final previousCustomPath = await UserDataLocationService.getCustomPath();
      await UserDataLocationService.setCustomPath(selected);

      // Reinitialize the DB at the new path (no data yet on first launch).
      if (!mounted) return problem;
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
        if (mounted) problem = _userDataNotWritableMessage();
        selected = await ConfigService.getUserDataPath();
      }

      // The database is now open at the new path, but this provider resolved
      // its cache directory and active theme against the old one at launch.
      // Without this the art pack downloaded on the final step lands in the
      // folder the app started in, and is gone on the next launch even though
      // System Art still shows the pack as applied.
      if (!mounted) return problem;
      await context.read<NeoAssetsProvider>().reinitialize();

      // Every art lookup goes through this provider, which resolved the media
      // folder at launch: without it the art scraped from here on lands in
      // the new folder but isn't found until the next launch. The log file
      // lives in the user-data folder too.
      await LoggerService.instance.reinitialize();
      if (!mounted) return problem;
      await context.read<FileProvider>().reinitialize();

      if (mounted) setState(() => _selectedUserDataPath = selected);
    } catch (e) {
      _log.e('User data location selection failed in wizard: $e');
    } finally {
      if (mounted) setState(() => _isSelectingUserDataFolder = false);
      _gamepadNav?.activate();
    }
    return problem;
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

  /// Whether the scan this step started stopped with an error. Without this
  /// the step waited for a completion that never came: Next stayed disabled
  /// and Skip did nothing.
  bool _scanFailed(SqliteConfigProvider provider) =>
      !provider.isScanning && !provider.scanCompleted && provider.error != null;

  Widget _buildScanningStep(ThemeData theme) {
    final orientation = MediaQuery.of(context).orientation;
    final isLandscape = orientation == Orientation.landscape;
    final containerSize = isLandscape ? 48.r : 80.r;
    final iconSize = isLandscape ? 24.r : 48.r;
    final titleSize = isLandscape ? 16.r : 24.r;
    final textSize = isLandscape ? 12.r : 14.r;

    return Consumer<SqliteConfigProvider>(
      builder: (context, provider, child) {
        final failed = _scanFailed(provider);
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
                      : failed
                      ? Icon(
                          Symbols.error_rounded,
                          color: theme.colorScheme.error,
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
                failed
                    ? AppLocale.wizardScanFailed
                          .getString(context)
                          .replaceFirst(
                            '{error}',
                            provider.error!.split('\n').first,
                          )
                    : provider.scanStatus.isNotEmpty
                    ? provider.scanStatus
                    : AppLocale.scanningSystemsRoms.getString(context),
                style: TextStyle(
                  fontSize: textSize,
                  color: failed
                      ? theme.colorScheme.error
                      : theme.colorScheme.onSurface.withValues(alpha: 0.7),
                  height: 1.3,
                ),
                textAlign: TextAlign.center,
              ),

              // Progress bar
              if (provider.totalSystemsToScan > 0 &&
                  !provider.scanCompleted &&
                  !failed) ...[
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
    // A folder from another provider has no path the import can read.
    var unusable = false;
    // Without All files access, a folder NeoStation can't read looks empty to
    // the import.
    var needsAllFilesAccess = false;
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
              // The folder as picked, never NeoStation's own storage.
              selected = UserDataLocationService.safUriToRealPath(
                uri.toString(),
              );
              unusable = selected == null;
              needsAllFilesAccess =
                  !unusable && !await PermissionService.hasAllFilesAccess();
            }
          } on PlatformException catch (e) {
            if (e.code == 'PICKER_FAILED' && mounted) {
              selected = await TvDirectoryPicker.show(context);
              // The in-app browser leaves no folder grant behind.
              needsAllFilesAccess =
                  selected != null &&
                  !await PermissionService.hasAllFilesAccess();
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

    if (selected == null || !mounted) {
      if (unusable && mounted) {
        await _showWizardMessage(
          AppLocale.wizardEsdeStepTitle.getString(context),
          AppLocale.wizardFolderNotUsable.getString(context),
        );
      }
      return;
    }
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
    final localeEsdeImportFailed = AppLocale.esdeImportFailed.getString(
      context,
    );
    final localeErrorConfiguringPath = AppLocale.errorConfiguringPath.getString(
      context,
    );
    final localeEsdeTitle = AppLocale.wizardEsdeStepTitle.getString(context);
    // Added to the not-found results when All files access is missing.
    final allFilesHint = needsAllFilesAccess
        ? '\n${AppLocale.userDataFolderGrantAllFiles.getString(context)}'
        : '';

    try {
      await context.read<SqliteConfigProvider>().updateEsdeFolderPath(selected);
    } catch (e) {
      _log.e('Wizard ES-DE folder save failed: $e');
      GlobalNotificationService().show(
        id: 'wizard_esde_folder_error',
        message: localeErrorConfiguringPath.replaceFirst('{error}', '$e'),
        type: GlobalNotificationType.error,
      );
      // The bell isn't on screen during setup.
      await _showWizardMessage(
        localeEsdeTitle,
        localeErrorConfiguringPath.replaceFirst(
          '{error}',
          '$e'.split('\n').first,
        ),
      );
      return;
    }
    GlobalNotificationService().dismiss('wizard_esde_folder_error');
    if (!mounted) return;

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
      error = localeEsdeImportFailed.replaceFirst('{error}', '$e');
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
      // The bell above is the record; it isn't on screen during setup.
      await _showWizardMessage(localeEsdeTitle, error);
    } else if (result != null && !result.gamelistsDirFound) {
      GlobalNotificationService().update(
        id: notificationId,
        message: '$localeEsdeImportNotEsdeFolder$allFilesHint',
        type: GlobalNotificationType.error,
        progress: null,
      );
      await _showWizardMessage(
        localeEsdeTitle,
        '$localeEsdeImportNotEsdeFolder$allFilesHint',
      );
    } else if (!matched) {
      GlobalNotificationService().update(
        id: notificationId,
        message: '$localeEsdeImportNothingFound$allFilesHint',
        type: GlobalNotificationType.info,
        progress: null,
      );
      await _showWizardMessage(
        localeEsdeTitle,
        '$localeEsdeImportNothingFound$allFilesHint',
        icon: Symbols.info_rounded,
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
      await _showWizardMessage(
        AppLocale.wizardArtPackTitle.getString(context),
        AppLocale.wizardArtPackFailed.getString(context),
      );
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
          final failed = _scanFailed(provider);
          return _buttonRow([
            if (_canGoBack(provider)) _backButton(theme),
            if (failed)
              _westButton(
                theme,
                AppLocale.skipForNow.getString(context),
                () => _handleSkip(),
              ),
            // Next once the scan completes; Retry if it stopped with an error
            GamepadControl(
              iconPath: 'assets/images/gamepad/Xbox_A_button.png',
              label: failed
                  ? AppLocale.retry.getString(context)
                  : AppLocale.next.getString(context),
              onTap: provider.scanCompleted || failed
                  ? () => _handleMainAction()
                  : null,
              backgroundColor: theme.colorScheme.tertiary,
              textColor: theme.colorScheme.onTertiary,
            ),
          ]);
        },
      );
    }

    // For other steps, use normal logic. Skip ([_canSkip]) is offered on the
    // optional steps. The permissions step always offers it: see _handleSkip
    // for why it must never be gated on a grant succeeding.
    final showSkip = _canSkip;
    final provider = context.watch<SqliteConfigProvider>();
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
        return _buttonRow([
          if (_canGoBack(provider)) _backButton(theme),
          if (_currentStep == _stepUserData)
            _westButton(
              theme,
              AppLocale.selectUserDataFolder.getString(context),
              _isSelectingUserDataFolder
                  ? null
                  : () => _selectUserDataLocationWizard(),
              busy: _isSelectingUserDataFolder,
            ),
          if (showSkip)
            _westButton(
              theme,
              AppLocale.skipForNow.getString(context),
              _isImportingEsde || _isDownloadingArt
                  ? null
                  : () => _handleSkip(),
            ),
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
            backgroundColor: theme.colorScheme.tertiary,
            textColor: theme.colorScheme.onTertiary,
          ),
        ]);
      },
    );
  }

  /// The step's buttons, centred, as in the beta import wizard: Back (B)
  /// first, then the step's other action (the West face button), then its
  /// main action (A).
  Widget _buttonRow(List<Widget> buttons) => Wrap(
    alignment: WrapAlignment.center,
    spacing: 12.r,
    runSpacing: 8.r,
    children: buttons,
  );

  /// The colours of the other buttons, as on the app's footers: the main
  /// action is tertiary, the rest tertiaryFixed.
  Color _secondaryButtonColor(ThemeData theme) =>
      theme.colorScheme.onTertiaryFixed;

  /// Back (B): to the previous step.
  Widget _backButton(ThemeData theme) => GamepadControl(
    iconPath: 'assets/images/gamepad/Xbox_B_button.png',
    label: AppLocale.back.getString(context),
    onTap: _handleBack,
    backgroundColor: theme.colorScheme.tertiaryFixed,
    textColor: _secondaryButtonColor(theme),
  );

  /// The step's other action, on the West face button (X on an Xbox
  /// layout, Y on a Nintendo one).
  Widget _westButton(
    ThemeData theme,
    String label,
    VoidCallback? onTap, {
    bool busy = false,
  }) => WestButtonGlyph(
    builder: (context, iconPath) => GamepadControl(
      iconPath: iconPath,
      label: label,
      onTap: onTap,
      busy: busy,
      backgroundColor: theme.colorScheme.tertiaryFixed,
      textColor: _secondaryButtonColor(theme),
    ),
  );

  String _getButtonText() {
    if (_currentStep == _stepWelcome) {
      return AppLocale.wizardStartSetup.getString(context);
    }
    if (_currentStep == _stepLanguage || _currentStep == _stepUserData) {
      return AppLocale.next.getString(context);
    }
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
    if (_currentStep == _stepWelcome) {
      setState(() => _currentStep = _stepLanguage);
      return;
    }
    if (_currentStep == _stepLanguage) {
      setState(() => _currentStep = _stepUserData);
      return;
    }

    // Step 1 (user data location): advance, then auto-skip the permissions step
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
      final provider = context.read<SqliteConfigProvider>();
      if (_scanFailed(provider)) {
        // The scan stopped with an error: try it again.
        provider.scanSystems();
        return;
      }
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
    // Back and Skip included. Only fires while we still hold the foreground, so a
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

    // Why a picked folder wasn't added, shown once the picker has closed.
    String? problem;
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
      } else if (mounted) {
        // Desktop: the platform picker, falling back to the in-app browser
        // where no XDG portal backend exists (SteamOS Game Mode). Picked here
        // rather than through the provider so the wizard knows which folder
        // was picked, and can tell a cancelled pick from one that failed.
        result = await TvDirectoryPicker.pickDirectory(
          context,
          dialogTitle: AppLocale.selectRomFolder.getString(context),
        );
      }

      final folders = configProvider.config.romFolders;
      // A library the user-data step opened can already have folders: a
      // cancelled pick (desktop has no Skip on this step) or a full list
      // moves on with them, as before.
      var keepFolders =
          result == null && folders.isNotEmpty && !Platform.isAndroid;
      if (result != null && mounted && !folders.contains(result)) {
        // addRomFolder refuses these only through the provider's error and the
        // notification bell; a failed save also throws.
        if (folders.length >= 5) {
          problem = AppLocale.maxRomFoldersReached.getString(context);
          keepFolders = true;
        } else if (isTransientPortalPath(result)) {
          problem = AppLocale.wizardRomFolderTemporary.getString(context);
        } else {
          final notAdded = AppLocale.wizardRomFolderNotAdded.getString(context);
          configProvider.clearError();
          try {
            await configProvider.addRomFolder(result, scan: false);
          } catch (_) {
            // Reported just below: the folder isn't in the list, and the
            // provider's error says why.
          }
          if (!configProvider.config.romFolders.contains(result)) {
            final reason = (configProvider.error ?? '').split('\n').first;
            problem = notAdded.replaceFirst('{error}', reason).trim();
          }
        }
      }

      final added =
          result != null && configProvider.config.romFolders.contains(result);
      if (mounted && (added || keepFolders)) {
        // A leftover error would read as a failed scan until the scan starts.
        configProvider.clearError();
        setState(() {
          _selectedFolder = added ? result : folders.first;
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

    if (problem != null && mounted) {
      await _showWizardMessage(
        AppLocale.selectRomFolder.getString(context),
        problem,
      );
    }
  }

  Future<void> _finishSetup() async {
    if (_saving) return;
    _saving = true;
    // The wizard's navigation isn't a manager layer: pause it while saving,
    // so presses during the save (or on the failure dialogue below) don't
    // press Finish or Skip again or pick another art pack.
    _gamepadNav?.deactivate();

    // Stop pinning the secondary display's dock/launcher off-screen. Set before
    // any await so a rebuild racing the save can't re-assert the flag; the
    // wrapper pushes the clear once completeSetup() lands.
    _finishing = true;

    final failedTitle = AppLocale.wizardSaveFailedTitle.getString(context);
    final failedBody = AppLocale.wizardSaveFailedBody.getString(context);
    final ok = AppLocale.ok.getString(context);

    // Warn if no ROM folder was saved
    final configProvider = Provider.of<SqliteConfigProvider>(
      context,
      listen: false,
    );
    final savedFolder = configProvider.config.romFolder;

    if (savedFolder == null || savedFolder.isEmpty) {
      _log.w('Warning: ROM folder not saved in config!');
    }

    // Save the configuration, then mark setup as completed.
    try {
      await configProvider.saveConfig();
      await widget.onComplete();
      return;
    } catch (e) {
      _log.e('Finishing setup failed: $e');
      if (!mounted) return;
      setState(() => _finishing = false);
      try {
        await InfoDialog.show(
          context,
          title: failedTitle,
          body: failedBody.replaceFirst('{error}', '$e'.split('\n').first),
          okLabel: ok,
          icon: Symbols.error_rounded,
        );
      } finally {
        _saving = false;
        if (mounted) _gamepadNav?.activate();
      }
    }
  }
}
