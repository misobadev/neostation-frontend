import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:flutter/services.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:provider/provider.dart';
import 'package:neostation/services/logger_service.dart';
import 'package:neostation/services/permission_service.dart';
import 'package:neostation/services/config_service.dart';
import 'package:neostation/services/user_data_location_service.dart';
import 'package:neostation/providers/palette_provider.dart';
import '../providers/sqlite_config_provider.dart';
import '../utils/gamepad_nav.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:neostation/l10n/app_locale.dart';
import '../widgets/tv_directory_picker.dart';
import '../models/secondary_display_state.dart';

/// Initial configuration wizard for the first time the app is opened
class SetupWizard extends StatefulWidget {
  final VoidCallback onComplete;

  const SetupWizard({super.key, required this.onComplete});

  @override
  State<SetupWizard> createState() => _SetupWizardState();
}

class _SetupWizardState extends State<SetupWizard> {
  int _currentStep = 0;
  bool _isSelectingFolder = false;
  bool _isSelectingUserDataFolder = false;
  String? _selectedFolder;
  String? _selectedUserDataPath;
  SecondaryDisplayState? _secondaryDisplayState;

  static final _log = LoggerService.instance;

  GamepadNavigation? _gamepadNav;

  @override
  void initState() {
    super.initState();
    _initializeSteps();
    _initGamepad();
    if (Platform.isAndroid) {
      _secondaryDisplayState = SecondaryDisplayState();
    }
  }

  void _initGamepad() {
    _gamepadNav = GamepadNavigation(
      onSelectItem: () {
        if (_isSelectingFolder || _isSelectingUserDataFolder) return;

        final lastStep = Platform.isAndroid ? 3 : 2;

        if (_currentStep == lastStep) {
          // Last step: A finishes when scan is done.
          final provider = Provider.of<SqliteConfigProvider>(
            context,
            listen: false,
          );
          if (provider.scanCompleted) _finishSetup();
        } else {
          _handleMainAction();
        }
      },
      onBack: () {
        _handleSkip();
      },
    );
    _gamepadNav?.initialize();
    _gamepadNav?.activate();
  }

  @override
  void dispose() {
    _gamepadNav?.dispose();
    _secondaryDisplayState?.dispose();
    super.dispose();
  }

  void _updateSecondaryScreen(int bgColor, bool isOled) {
    if (_secondaryDisplayState == null) return;
    _secondaryDisplayState!.updateState(
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
    // Folder selection step: Android=2, Desktop=1
    final folderStep = Platform.isAndroid ? 2 : 1;

    if (_currentStep == folderStep) {
      // Skip folder selection → Advance to Scanning step.
      setState(() => _currentStep++);

      // Start initial scan to detect available systems (e.g., Android apps).
      final provider = Provider.of<SqliteConfigProvider>(
        context,
        listen: false,
      );
      WidgetsBinding.instance.addPostFrameCallback((_) {
        provider.scanSystems();
      });
    }
  }

  void _initializeSteps() {
    // Load the current user-data path for display in step 0.
    ConfigService.getUserDataPath().then((p) {
      if (mounted) setState(() => _selectedUserDataPath = p);
    });
  }

  // Step layout:
  // Android: 0=UserDataLocation, 1=Permissions, 2=FolderSelect, 3=Scanning (4 steps)
  // Desktop: 0=UserDataLocation, 1=FolderSelect, 2=Scanning (3 steps)
  int get _totalSteps => Platform.isAndroid ? 4 : 3;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final themeProvider = Provider.of<PaletteProvider>(context);
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

                  // Progress indicator vertical
                  _buildVerticalProgressIndicator(theme),
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
                    ? Icon(Symbols.check_rounded, color: Colors.white, size: 14.r)
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
    return Row(
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
                    ? Icon(Symbols.check_rounded, color: Colors.white, size: 24.r)
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
    );
  }

  Widget _buildStepContent(ThemeData theme) {
    if (_currentStep == 0) {
      return _buildUserDataLocationStep(theme);
    }

    if (Platform.isAndroid) {
      switch (_currentStep) {
        case 1:
          return _buildPermissionStep(theme);
        case 2:
          return _buildFolderSelectionStep(theme);
        case 3:
          return _buildScanningStep(theme);
        default:
          return Container();
      }
    } else {
      switch (_currentStep) {
        case 1:
          return _buildFolderSelectionStep(theme);
        case 2:
          return _buildScanningStep(theme);
        default:
          return Container();
      }
    }
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
          OutlinedButton(
            onPressed: _isSelectingUserDataFolder
                ? null
                : () => _selectUserDataLocationWizard(),
            style: OutlinedButton.styleFrom(
              padding: EdgeInsets.symmetric(horizontal: 16.r, vertical: 10.r),
              side: BorderSide(
                color: theme.colorScheme.primary.withValues(alpha: 0.5),
              ),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12.r),
              ),
            ),
            child: _isSelectingUserDataFolder
                ? SizedBox(
                    width: 18.r,
                    height: 18.r,
                    child: CircularProgressIndicator(
                      strokeWidth: 2.r,
                      color: theme.colorScheme.primary,
                    ),
                  )
                : Text(
                    AppLocale.selectUserDataFolder.getString(context),
                    style: TextStyle(
                      fontSize: textSize,
                      color: theme.colorScheme.primary,
                    ),
                  ),
          ),
        ],
      ),
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
        selected = await FilePicker.platform.getDirectoryPath(
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

      await UserDataLocationService.setCustomPath(selected);

      // Reinitialize the DB at the new path (no data yet on first launch).
      if (!mounted) return;
      final configProvider = Provider.of<SqliteConfigProvider>(
        context,
        listen: false,
      );
      await configProvider.reinitialize();

      if (mounted) setState(() => _selectedUserDataPath = selected);
    } catch (e) {
      _log.e('User data location selection failed in wizard: $e');
    } finally {
      if (mounted) setState(() => _isSelectingUserDataFolder = false);
      _gamepadNav?.activate();
    }
  }

  Widget _buildPermissionStep(ThemeData theme) {
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
            Symbols.security_rounded,
            size: iconSize,
            color: theme.colorScheme.primary,
          ),
          SizedBox(height: isLandscape ? 16.r : 24.r),
          Text(
            AppLocale.storagePermission.getString(context),
            style: TextStyle(
              fontSize: titleSize,
              fontWeight: FontWeight.bold,
              color: theme.colorScheme.onSurface,
            ),
          ),
          SizedBox(height: isLandscape ? 8.r : 16.r),
          Text(
            AppLocale.storagePermissionDesc.getString(context),
            style: TextStyle(
              fontSize: textSize,
              color: theme.colorScheme.onSurface.withValues(alpha: 0.7),
              height: 1.3,
            ),
            textAlign: TextAlign.center,
          ),
          if (isLandscape) SizedBox(height: 16.r),
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
                    ? AppLocale.setupComplete.getString(context)
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
                          '${AppLocale.foundSystemsWithGames.getString(context).replaceFirst('{count}', provider.detectedSystems.length.toString())}\n${AppLocale.tapFinishToStart.getString(context)}',
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

  Widget _buildNavigationButtons(ThemeData theme) {
    // The last step is always the scanning step
    final isInScanningStep = _currentStep == (Platform.isAndroid ? 3 : 2);

    if (isInScanningStep) {
      return Consumer<SqliteConfigProvider>(
        builder: (context, provider, child) {
          return Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              // Finish button only when scan completes
              ElevatedButton(
                onPressed: provider.scanCompleted ? () => _finishSetup() : null,
                style: ElevatedButton.styleFrom(
                  backgroundColor: theme.colorScheme.primary,
                  foregroundColor: theme.colorScheme.onPrimary,
                  padding: EdgeInsets.symmetric(
                    horizontal: 20.r,
                    vertical: 12.r,
                  ),
                  elevation: 4,
                  shadowColor: theme.colorScheme.primary.withValues(alpha: 0.4),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16.r),
                  ),
                  disabledBackgroundColor: theme.colorScheme.primary.withValues(
                    alpha: 0.3,
                  ),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Image.asset(
                      'assets/images/gamepad/Xbox_A_button.png',
                      width: 20.r,
                      height: 20.r,
                      color: theme.colorScheme.onPrimary,
                    ),
                    SizedBox(width: 8.r),
                    Text(
                      AppLocale.finish.getString(context),
                      style: TextStyle(
                        fontSize: 14.r,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          );
        },
      );
    }

    // For other steps, use normal logic
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        // Skip button (only in folder selection step)
        if (Platform.isAndroid && _currentStep == 2)
          TextButton(
            onPressed: () => _handleSkip(),
            style: TextButton.styleFrom(
              padding: EdgeInsets.symmetric(horizontal: 16.r, vertical: 8.r),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Image.asset(
                  'assets/images/gamepad/Xbox_B_button.png',
                  width: 20.r,
                  height: 20.r,
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
                ),
                SizedBox(width: 8.r),
                Text(
                  AppLocale.skipForNow.getString(context),
                  style: TextStyle(
                    fontSize: 12.r,
                    color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
                  ),
                ),
              ],
            ),
          )
        else
          SizedBox(width: 64.r),

        // Main action button
        ElevatedButton(
          onPressed: _isSelectingFolder ? null : () => _handleMainAction(),
          style: ElevatedButton.styleFrom(
            backgroundColor: theme.colorScheme.primary,
            foregroundColor: theme.colorScheme.onPrimary,
            padding: EdgeInsets.symmetric(horizontal: 20.r, vertical: 12.r),
            elevation: 4,
            shadowColor: theme.colorScheme.primary.withValues(alpha: 0.4),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16.r),
            ),
            disabledBackgroundColor: theme.colorScheme.primary.withValues(
              alpha: 0.3,
            ),
          ),
          child: _isSelectingFolder
              ? SizedBox(
                  width: 20.r,
                  height: 20.r,
                  child: CircularProgressIndicator(
                    strokeWidth: 2.r,
                    valueColor: AlwaysStoppedAnimation<Color>(
                      theme.colorScheme.onPrimary,
                    ),
                  ),
                )
              : Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Image.asset(
                      'assets/images/gamepad/Xbox_A_button.png',
                      width: 20.r,
                      height: 20.r,
                      color: theme.colorScheme.onPrimary,
                    ),
                    SizedBox(width: 8.r),
                    Text(
                      _getButtonText(),
                      style: TextStyle(
                        fontSize: 14.r,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
        ),
      ],
    );
  }

  String _getButtonText() {
    if (_currentStep == 0) return AppLocale.next.getString(context);
    if (Platform.isAndroid) {
      if (_currentStep == 1) return AppLocale.grantAccess.getString(context);
      if (_currentStep == 2) return AppLocale.selectFolder.getString(context);
    } else {
      if (_currentStep == 1) return AppLocale.selectFolder.getString(context);
    }
    return AppLocale.next.getString(context);
  }

  Future<void> _handleMainAction() async {
    // Step 0 (user data location): advance and auto-skip permission step if already granted.
    if (_currentStep == 0) {
      setState(() => _currentStep++);
      if (Platform.isAndroid) {
        PermissionService.hasAllFilesAccess().then((hasAccess) {
          if (hasAccess && mounted && _currentStep == 1) {
            setState(() => _currentStep = 2);
          }
        });
      }
      return;
    }

    if (Platform.isAndroid) {
      if (_currentStep == 1) {
        // Deactivate gamepad before opening system settings to prevent key event
        // leakage when the app regains focus after the user grants the permission.
        _gamepadNav?.deactivate();
        try {
          final success = await PermissionService.requestAllFilesAccess();
          if (success && mounted) {
            context.read<SqliteConfigProvider>().refreshAllFilesAccess();
            setState(() => _currentStep++);
            // Drain any pending key events before re-enabling gamepad input.
            await Future.delayed(const Duration(milliseconds: 600));
            if (mounted) _gamepadNav?.activate();
          } else if (mounted) {
            _gamepadNav?.activate();
          }
        } catch (e) {
          _log.e('Error requesting permissions: $e');
          if (mounted) _gamepadNav?.activate();
        }
      } else if (_currentStep == 2) {
        await _selectFolder();
      }
    } else {
      if (_currentStep == 1) {
        await _selectFolder();
      }
    }
  }

  Future<void> _selectFolder() async {
    final folderStep = Platform.isAndroid ? 2 : 1;
    if (_currentStep != folderStep) return;

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
        await configProvider.selectRomFolder(scan: false);
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
