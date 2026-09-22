import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:neostation/utils/gamepad_nav.dart';
import 'package:neostation/services/screenscraper_service.dart';
import 'package:neostation/widgets/custom_notification.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:flutter/gestures.dart';
import 'package:neostation/services/game_service.dart'
    show GamepadNavigationManager;
import 'package:flutter_localization/flutter_localization.dart';
import 'package:neostation/l10n/app_locale.dart';
import 'package:neostation/utils/login_form_selection.dart';

/// ScreenScraper sign-in form, shown as a modal over the settings screen.
///
/// Owns its own gamepad layer while open. B leaves a focused text field first
/// and closes the dialog on the next press.
class ScreenScraperLoginDialog extends StatefulWidget {
  const ScreenScraperLoginDialog({super.key});

  /// Opens the dialog. Resolves to true once credentials were verified and
  /// saved, false if the user backed out.
  static Future<bool> show(BuildContext context) async {
    final result = await showDialog<bool>(
      context: context,
      builder: (_) => const ScreenScraperLoginDialog(),
    );
    return result ?? false;
  }

  @override
  State<ScreenScraperLoginDialog> createState() =>
      _ScreenScraperLoginDialogState();
}

class _ScreenScraperLoginDialogState extends State<ScreenScraperLoginDialog>
    with LoginFormSelection<ScreenScraperLoginDialog> {
  static const String _layerId = 'screenscraper_login_dialog';

  GamepadNavigation? _gamepadNav;

  final TextEditingController _usernameController = TextEditingController();
  final TextEditingController _passwordController = TextEditingController();
  final FocusNode _usernameFocus = FocusNode();
  final FocusNode _passwordFocus = FocusNode();

  bool _obscurePassword = true;
  bool _isLoading = false;

  @override
  List<FocusNode?> get selectionSlots => [_usernameFocus, _passwordFocus, null];

  @override
  void initState() {
    super.initState();
    attachFocusSelectionListeners();
    _initControllerNavigation();
  }

  void _initControllerNavigation() {
    _gamepadNav = GamepadNavigation(
      onNavigateUp: _navigateUp,
      onNavigateDown: _navigateDown,
      onSelectItem: _selectCurrentField,
      allowRepeat: false,
      isTextFieldFocused: isAnyFieldFocused,
      onBack: _handleBack,
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _gamepadNav!.initialize();
      GamepadNavigationManager.pushLayer(
        _layerId,
        onActivate: () => _gamepadNav?.activate(),
        onDeactivate: () => _gamepadNav?.deactivate(),
      );
    });
  }

  void _handleBack() {
    if (isAnyFieldFocused()) {
      exitTextEntry();
    } else if (!_isLoading) {
      Navigator.of(context).pop(false);
    }
  }

  @override
  void dispose() {
    GamepadNavigationManager.popLayer(_layerId);
    _gamepadNav?.dispose();
    detachFocusSelectionListeners();
    _usernameController.dispose();
    _passwordController.dispose();
    _usernameFocus.dispose();
    _passwordFocus.dispose();
    super.dispose();
  }

  bool _navigateUp() => moveSelection(-1);

  bool _navigateDown() => moveSelection(1);

  void _selectCurrentField() {
    if (focusSelectedField()) return;
    _performLogin();
  }

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

          if (mounted) Navigator.of(context).pop(true);
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
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Dialog(
      backgroundColor: theme.scaffoldBackgroundColor,
      insetPadding: EdgeInsets.all(16.r),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16.r)),
      child: SingleChildScrollView(
        padding: EdgeInsets.all(16.r),
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
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
            decoration: isSelected(0)
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
                      color: isSelected(0)
                          ? theme.colorScheme.primary
                          : theme.colorScheme.primary.withValues(alpha: 0.1),
                      width: isSelected(0) ? 2.r : 1.r,
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
            decoration: isSelected(1)
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
                      color: isSelected(1)
                          ? theme.colorScheme.primary
                          : theme.colorScheme.primary.withValues(alpha: 0.1),
                      width: isSelected(1) ? 2.r : 1.r,
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
            decoration: isSelected(submitSlot)
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
