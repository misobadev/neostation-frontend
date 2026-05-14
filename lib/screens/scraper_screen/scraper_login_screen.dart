import 'dart:io';
import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:neostation/utils/gamepad_nav.dart';
import 'package:neostation/services/permission_service.dart';
import 'package:neostation/services/screenscraper_service.dart';
import 'package:neostation/widgets/custom_notification.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:flutter/gestures.dart';
import '../../services/game_service.dart' show GamepadNavigationManager;
import '../app_screen.dart' show AppNavigation;
import 'package:flutter_localization/flutter_localization.dart';
import 'package:neostation/l10n/app_locale.dart';

class ScraperLoginScreen extends StatefulWidget {
  final VoidCallback? onLoginSuccess;

  const ScraperLoginScreen({super.key, this.onLoginSuccess});

  @override
  State<ScraperLoginScreen> createState() => _ScraperLoginScreenState();
}

class _ScraperLoginScreenState extends State<ScraperLoginScreen> {
  GamepadNavigation? _gamepadNav;
  int _selectedFieldIndex = 0; // 0: username, 1: password, 2: login button
  bool _isTelevision = false;

  final TextEditingController _usernameController = TextEditingController();
  final TextEditingController _passwordController = TextEditingController();
  final FocusNode _usernameFocus = FocusNode();
  final FocusNode _passwordFocus = FocusNode();

  bool _obscurePassword = true;
  bool _isLoading = false;

  @override
  void initState() {
    super.initState();
    _initTvMode();
  }

  Future<void> _initTvMode() async {
    if (!Platform.isAndroid) return;
    final isTV = await PermissionService.isTelevision();
    if (!mounted) return;
    setState(() => _isTelevision = isTV);
    if (!isTV) return;
    _gamepadNav = GamepadNavigation(
      onNavigateUp: _navigateUp,
      onNavigateDown: _navigateDown,
      onSelectItem: _selectCurrentField,
      onPreviousTab: AppNavigation.previousTab,
      onNextTab: AppNavigation.nextTab,
      onLeftBumper: AppNavigation.previousTab,
      onRightBumper: AppNavigation.nextTab,
    );
    _gamepadNav!.initialize();
    GamepadNavigationManager.pushLayer(
      'scraper_login_screen',
      onActivate: () => _gamepadNav?.activate(),
      onDeactivate: () => _gamepadNav?.deactivate(),
    );
  }

  @override
  void dispose() {
    GamepadNavigationManager.popLayer('scraper_login_screen');
    _gamepadNav?.dispose();
    _usernameController.dispose();
    _passwordController.dispose();
    _usernameFocus.dispose();
    _passwordFocus.dispose();
    super.dispose();
  }

  bool _isAnyFieldFocused() =>
      _usernameFocus.hasFocus || _passwordFocus.hasFocus;

  void _navigateUp() {
    if (_isAnyFieldFocused()) return;
    setState(() {
      _selectedFieldIndex = (_selectedFieldIndex - 1 + 3) % 3;
    });
  }

  void _navigateDown() {
    if (_isAnyFieldFocused()) return;
    setState(() {
      _selectedFieldIndex = (_selectedFieldIndex + 1) % 3;
    });
  }

  void _selectCurrentField() {
    switch (_selectedFieldIndex) {
      case 0:
        _usernameFocus.requestFocus();
        break;
      case 1:
        _passwordFocus.requestFocus();
        break;
      case 2:
        _performLogin();
        break;
    }
  }

  bool _isTvSelected(int slot) => _isTelevision && _selectedFieldIndex == slot;

  Future<void> _performLogin() async {
    if (_usernameController.text.isEmpty || _passwordController.text.isEmpty) {
      AppNotification.showNotification(
        context,
        AppLocale.pleaseCompleteAllFields.getString(context),
        type: NotificationType.error,
      );
      return;
    }

    setState(() {
      _isLoading = true;
    });

    try {
      // Verify credentials with ScreenScraper
      final result = await ScreenScraperService.verifyCredentials(
        _usernameController.text.trim(),
        _passwordController.text,
      );

      if (result != null) {
        // Valid credentials - save to DB with user information
        final userInfo = result['response']['ssuser'] as Map<String, dynamic>;

        final saved = await ScreenScraperService.saveCredentials(
          _usernameController.text.trim(),
          _passwordController.text,
          userInfo,
        );

        if (!mounted) return;

        if (saved) {
          AppNotification.showNotification(
            context,
            AppLocale.loginSuccessful.getString(context),
            type: NotificationType.success,
          );

          // Synchronize system IDs after successful login
          try {
            final syncSuccess = await ScreenScraperService.syncSystemIds();
            if (!mounted) return;
            if (syncSuccess) {
              AppNotification.showNotification(
                context,
                AppLocale.systemIdsSyncSuccess.getString(context),
                type: NotificationType.info,
              );
            } else {
              AppNotification.showNotification(
                context,
                AppLocale.systemIdsSyncWarning.getString(context),
                type: NotificationType.info,
              );
            }
          } catch (e) {
            AppNotification.showNotification(
              context,
              AppLocale.systemIdsSyncError
                  .getString(context)
                  .replaceFirst('{error}', e.toString()),
              type: NotificationType.info,
            );
          }

          // Notify parent to change view
          widget.onLoginSuccess?.call();
        } else {
          if (!mounted) return;
          AppNotification.showNotification(
            context,
            AppLocale.errorSavingCredentials.getString(context),
            type: NotificationType.error,
          );
        }
      } else {
        if (!mounted) return;
        // Invalid credentials
        AppNotification.showNotification(
          context,
          AppLocale.invalidCredentials.getString(context),
          type: NotificationType.error,
        );
      }
    } catch (e) {
      if (!mounted) return;
      AppNotification.showNotification(
        context,
        AppLocale.loginError
            .getString(context)
            .replaceFirst('{error}', e.toString()),
        type: NotificationType.error,
      );
    } finally {
      setState(() {
        _isLoading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors
          .transparent, // Transparent to show the shared background shader
      body: SafeArea(
        child: SingleChildScrollView(
          padding: EdgeInsets.symmetric(vertical: 64.r, horizontal: 16.r),
          child: Center(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Padding(
                padding: EdgeInsets.symmetric(horizontal: 16.r),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      constraints: BoxConstraints(maxWidth: 260.r),
                      child: _buildLoginForm(context),
                    ),
                    SizedBox(width: 16.r),
                    SizedBox(width: 300.r, child: _buildInfoBox(context)),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildInfoBox(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: EdgeInsets.all(16.r),
      decoration: BoxDecoration(
        color: theme.cardColor.withValues(alpha: 0.25),
        borderRadius: BorderRadius.circular(12.r),
        border: Border.all(
          color: theme.colorScheme.primary.withValues(alpha: 0.2),
          width: 1,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                Symbols.info_rounded,
                color: theme.colorScheme.primary,
                size: 24.r,
              ),
              SizedBox(width: 12.r),
              Expanded(
                child: Text(
                  AppLocale.whatIsScreenScraper.getString(context),
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                    color: theme.colorScheme.primary,
                    fontSize: 14.r,
                  ),
                ),
              ),
            ],
          ),
          SizedBox(height: 6.r),
          Text(
            AppLocale.screenScraperDescription.getString(context),
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurface.withValues(alpha: 0.9),
              fontSize: 8.r,
            ),
            softWrap: true,
          ),
          SizedBox(height: 6.r),
          _buildInfoItem(
            context,
            Symbols.auto_awesome_rounded,
            AppLocale.automaticMetadataMedia.getString(context),
          ),
          _buildInfoItem(
            context,
            Symbols.storage_rounded,
            AppLocale.massiveDatabase.getString(context),
          ),
          _buildInfoItem(
            context,
            Symbols.verified_user_rounded,
            AppLocale.requiresFreeAccount.getString(context),
          ),
          SizedBox(height: 6.r),
          RichText(
            softWrap: true,
            text: TextSpan(
              style: theme.textTheme.bodySmall?.copyWith(
                fontStyle: FontStyle.italic,
                color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
                fontSize: 8.r,
              ),
              children: [
                TextSpan(text: AppLocale.createAccountAt.getString(context)),
                TextSpan(
                  text: 'screenscraper.fr',
                  style: TextStyle(
                    color: theme.colorScheme.primary,
                    decoration: TextDecoration.underline,
                  ),
                  recognizer: TapGestureRecognizer()
                    ..onTap = () async {
                      final url = Uri.parse('https://www.screenscraper.fr');
                      if (await canLaunchUrl(url)) {
                        await launchUrl(
                          url,
                          mode: LaunchMode.externalApplication,
                        );
                      }
                    },
                ),
                TextSpan(text: AppLocale.toGetCredentials.getString(context)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildInfoItem(BuildContext context, IconData icon, String text) {
    final theme = Theme.of(context);
    return Padding(
      padding: EdgeInsets.only(bottom: 8.r),
      child: Row(
        children: [
          Icon(
            icon,
            size: 12.r,
            color: theme.colorScheme.primary.withValues(alpha: 0.7),
          ),
          SizedBox(width: 8.r),
          Expanded(
            child: Text(
              text,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurface.withValues(alpha: 0.8),
                fontSize: 8.r,
              ),
              softWrap: true,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildLoginForm(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: EdgeInsets.all(16.r),
      decoration: BoxDecoration(
        color: theme.cardColor.withValues(alpha: 0.25),
        borderRadius: BorderRadius.circular(12.r),
        border: Border.all(
          color: theme.colorScheme.primary.withValues(alpha: 0.2),
          width: 1,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          // Main header with logo and title
          Row(
            children: [
              Expanded(
                child: Text(
                  AppLocale.screenScraperLogin.getString(context),
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                    color: theme.colorScheme.primary,
                    fontSize: 14.r,
                  ),
                ),
              ),
            ],
          ),
          SizedBox(height: 12.r),

          // Username field
          Container(
            constraints: BoxConstraints(maxWidth: 220.r),
            decoration: _isTvSelected(0)
                ? BoxDecoration(
                    borderRadius: BorderRadius.circular(8.r),
                    boxShadow: [
                      BoxShadow(
                        color: theme.colorScheme.primary.withValues(
                          alpha: 0.35,
                        ),
                        blurRadius: 6.r,
                        spreadRadius: 1.r,
                      ),
                    ],
                  )
                : null,
            child: SizedBox(
              height: 32.r,
              child: TextField(
                controller: _usernameController,
                focusNode: _usernameFocus,
                decoration: InputDecoration(
                  labelText: AppLocale.username.getString(context),
                  labelStyle: TextStyle(
                    color: theme.colorScheme.onSurface.withValues(alpha: 0.7),
                    fontSize: 10.r,
                  ),
                  floatingLabelStyle: TextStyle(
                    color: theme.colorScheme.primary,
                    fontSize: 10.r,
                    fontWeight: FontWeight.bold,
                  ),
                  hintText: AppLocale.enterUsername.getString(context),
                  hintStyle: TextStyle(
                    color: theme.colorScheme.onSurface.withValues(alpha: 0.4),
                    fontSize: 10.r,
                  ),
                  filled: true,
                  fillColor: theme.colorScheme.onSurface.withValues(
                    alpha: 0.05,
                  ),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8.r),
                    borderSide: BorderSide.none,
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8.r),
                    borderSide: BorderSide(
                      color: _isTvSelected(0)
                          ? theme.colorScheme.primary
                          : theme.colorScheme.primary.withValues(alpha: 0.1),
                      width: _isTvSelected(0) ? 2.r : 1.r,
                    ),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8.r),
                    borderSide: BorderSide(
                      color: theme.colorScheme.primary,
                      width: 1.r,
                    ),
                  ),
                ),
                enabled: !_isLoading,
                style: TextStyle(fontSize: 11.r),
                textInputAction: TextInputAction.next,
                onSubmitted: (_) => _passwordFocus.requestFocus(),
              ),
            ),
          ),
          SizedBox(height: 6.r),

          // Password field
          Container(
            constraints: BoxConstraints(maxWidth: 220.r),
            decoration: _isTvSelected(1)
                ? BoxDecoration(
                    borderRadius: BorderRadius.circular(8.r),
                    boxShadow: [
                      BoxShadow(
                        color: theme.colorScheme.primary.withValues(
                          alpha: 0.35,
                        ),
                        blurRadius: 6.r,
                        spreadRadius: 1.r,
                      ),
                    ],
                  )
                : null,
            child: SizedBox(
              height: 32.r,
              child: TextFormField(
                style: TextStyle(fontSize: 10.r),
                controller: _passwordController,
                focusNode: _passwordFocus,
                obscureText: _obscurePassword,
                decoration: InputDecoration(
                  labelText: AppLocale.password.getString(context),
                  suffixStyle: TextStyle(
                    color: theme.colorScheme.primary.withValues(alpha: 0.7),
                    fontSize: 12.r,
                  ),
                  labelStyle: TextStyle(
                    color: theme.colorScheme.onSurface.withValues(alpha: 0.7),
                    fontSize: 10.r,
                  ),
                  floatingLabelStyle: TextStyle(
                    color: theme.colorScheme.primary,
                    fontSize: 10.r,
                    fontWeight: FontWeight.bold,
                  ),
                  hintText: AppLocale.enterPassword.getString(context),
                  hintStyle: TextStyle(
                    color: theme.colorScheme.onSurface.withValues(alpha: 0.4),
                    fontSize: 10.r,
                  ),
                  filled: true,
                  fillColor: theme.colorScheme.onSurface.withValues(
                    alpha: 0.05,
                  ),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8.r),
                    borderSide: BorderSide.none,
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8.r),
                    borderSide: BorderSide(
                      color: _isTvSelected(1)
                          ? theme.colorScheme.primary
                          : theme.colorScheme.primary.withValues(alpha: 0.1),
                      width: _isTvSelected(1) ? 2.r : 1.r,
                    ),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8.r),
                    borderSide: BorderSide(
                      color: theme.colorScheme.primary,
                      width: 1.r,
                    ),
                  ),
                  suffixIcon: IconButton(
                    padding: EdgeInsets.zero,
                    icon: Icon(
                      size: 18.r,
                      _obscurePassword
                          ? Symbols.visibility_rounded
                          : Symbols.visibility_off_rounded,
                      color: theme.colorScheme.onSurface.withValues(alpha: 0.5),
                    ),
                    onPressed: () {
                      setState(() {
                        _obscurePassword = !_obscurePassword;
                      });
                    },
                  ),
                ),
                enabled: !_isLoading,
                textInputAction: TextInputAction.done,
                onFieldSubmitted: (_) => _performLogin(),
              ),
            ),
          ),
          SizedBox(height: 6.r),

          // Login button
          Container(
            constraints: BoxConstraints(maxWidth: 320.r),
            decoration: _isTvSelected(2)
                ? BoxDecoration(
                    borderRadius: BorderRadius.circular(8.r),
                    boxShadow: [
                      BoxShadow(
                        color: theme.colorScheme.primary.withValues(alpha: 0.5),
                        blurRadius: 8.r,
                        spreadRadius: 2.r,
                      ),
                    ],
                  )
                : null,
            child: SizedBox(
              width: double.infinity,
              height: 32.r,
              child: ElevatedButton(
                onPressed: _isLoading ? null : _performLogin,
                style: ElevatedButton.styleFrom(
                  backgroundColor: theme.colorScheme.primary,
                  foregroundColor: theme.colorScheme.onPrimary,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8.r),
                  ),
                  elevation: 0,
                  padding: EdgeInsets.zero,
                ),
                child: _isLoading
                    ? SizedBox(
                        width: 16.r,
                        height: 16.r,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          valueColor: AlwaysStoppedAnimation<Color>(
                            theme.colorScheme.onPrimary,
                          ),
                        ),
                      )
                    : Text(
                        AppLocale.login.getString(context),
                        style: TextStyle(
                          fontSize: 14.r,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
