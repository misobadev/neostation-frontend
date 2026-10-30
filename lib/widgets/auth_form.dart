import 'dart:async';
import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:neostation/l10n/app_locale.dart';
import 'package:neostation/services/game_service.dart'
    show GamepadNavigationManager;
import 'package:neostation/services/neosync/auth_service.dart';
import 'package:neostation/utils/gamepad_nav.dart';
import 'package:neostation/utils/login_form_selection.dart';
import 'package:provider/provider.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:neostation/screens/app_screen.dart' show AppNavigation;
import 'package:neostation/services/logger_service.dart';

class AuthForm extends StatefulWidget {
  final VoidCallback onLoginSuccess;

  /// Where B goes from the sign-in view once no field is focused. Null on the
  /// NeoSync tab, where B there does nothing; the setup wizard uses it to close
  /// the page it opened the form on.
  final VoidCallback? onBack;

  const AuthForm({super.key, required this.onLoginSuccess, this.onBack});

  @override
  AuthFormState createState() => AuthFormState();
}

class AuthFormState extends State<AuthForm> with LoginFormSelection<AuthForm> {
  final _formKey = GlobalKey<FormState>();
  final _usernameController = TextEditingController();
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  final _verificationTokenController = TextEditingController();
  final _resetTokenController = TextEditingController();
  final _newPasswordController = TextEditingController();

  // Gamepad navigation focus nodes
  final _usernameFocus = FocusNode();
  final _emailFocus = FocusNode();
  final _passwordFocus = FocusNode();
  final _verificationTokenFocus = FocusNode();
  final _resetTokenFocus = FocusNode();
  final _newPasswordFocus = FocusNode();

  static final _log = LoggerService.instance;

  bool _isLogin = true;
  bool _isLoading = false;
  String? _message;
  bool _showVerification = false;
  bool _showEmailVerification = false;
  bool _showForgotPassword = false;
  bool _showResetPassword = false;
  bool _obscurePassword = true;
  bool _isPolling = false;
  Timer? _pollingTimer;
  String? _pendingVerificationEmail;

  GamepadNavigation? _gamepadNav;

  /// The slots the D-pad walks, which change with the form's mode: register
  /// carries a username that login doesn't, the verification step is a pair of
  /// buttons with no field, and the reset flow swaps in its own two fields.
  /// A null entry is an action button rather than something to focus.
  @override
  List<FocusNode?> get selectionSlots {
    if (_showResetPassword) {
      return [_resetTokenFocus, _newPasswordFocus, null, null]; // reset + back
    }
    if (_showForgotPassword) return [_emailFocus, null, null]; // send + back
    if (_showVerification && !_showEmailVerification) {
      return [_verificationTokenFocus, null];
    }
    if (_showEmailVerification) return [null, null]; // resend + back
    if (_isLogin) {
      // login + "sign up" + "forgot password"
      return [_emailFocus, _passwordFocus, null, null, null];
    }
    // sign up + "already have an account"
    return [_usernameFocus, _emailFocus, _passwordFocus, null, null];
  }

  /// Every node the form owns, not just the ones the current mode shows, so
  /// focus tracking survives a mode switch.
  @override
  List<FocusNode> get ownedFocusNodes => [
    _usernameFocus,
    _emailFocus,
    _passwordFocus,
    _verificationTokenFocus,
    _resetTokenFocus,
    _newPasswordFocus,
  ];

  @override
  void initState() {
    super.initState();
    attachFocusSelectionListeners();
    // Deferred by a frame because NeoSyncContent pushes its own layer in a
    // post-frame callback. This form has to land on top of it, and pushing
    // synchronously here would put it underneath.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _initControllerNavigation();
    });
  }

  /// Registers the form's own navigation layer.
  ///
  /// Not gated on Android TV: the form is the only thing on screen whenever it
  /// is shown, so the D-pad has to drive it on handhelds and the Deck too.
  /// Going through the manager rather than calling `activate()` directly is
  /// what stops this handler and NeoSyncContent's both seeing the same press.
  void _initControllerNavigation() {
    _gamepadNav = GamepadNavigation(
      onNavigateUp: () => moveSelection(-1),
      onNavigateDown: () => moveSelection(1),
      onSelectItem: _selectCurrent,
      onPreviousTab: AppNavigation.previousTab,
      onNextTab: AppNavigation.nextTab,
      onLeftBumper: AppNavigation.previousTab,
      onRightBumper: AppNavigation.nextTab,
      allowRepeat: false,
      isTextFieldFocused: isAnyFieldFocused,
      onBack: _handleBack,
    );
    _gamepadNav!.initialize();
    GamepadNavigationManager.pushLayer(
      'auth_form',
      onActivate: () => _gamepadNav?.activate(),
      onDeactivate: () => _gamepadNav?.deactivate(),
    );
  }

  void _selectCurrent() {
    if (focusSelectedField()) return;
    _handleAction();
  }

  void _handleAction() {
    if (_showEmailVerification) {
      if (isSelected(0)) {
        _resendVerification();
      } else {
        _goBackToLogin();
      }
      return;
    }
    if (_showResetPassword) {
      isSelected(3) ? _goBackToLogin() : _resetPassword();
      return;
    }
    if (_showForgotPassword) {
      isSelected(2) ? _goBackToLogin() : _sendForgotPasswordEmail();
      return;
    }
    if (_showVerification) {
      _verifyEmail();
      return;
    }
    // The mode-switch link trails the submit button, so it sits one slot later
    // in register, which carries a username field the login form doesn't.
    if (isSelected(_isLogin ? 3 : 4)) {
      _toggleMode();
      return;
    }
    if (_isLogin && isSelected(4)) {
      _openForgotPassword();
      return;
    }
    _submitForm();
  }

  /// Tapping a link and pressing A on it both land here, so the two paths
  /// can't drift on what a mode switch resets.
  void _toggleMode() {
    setState(() {
      _isLogin = !_isLogin;
      _message = null;
      resetSelectionInPlace();
    });
  }

  void _openForgotPassword() {
    setState(() {
      _showForgotPassword = true;
      _message = null;
      resetSelectionInPlace();
    });
  }

  /// B leaves a focused field first — that is what it does everywhere else in
  /// the app — and only steps back to the login form once nothing is focused.
  void _handleBack() {
    if (isAnyFieldFocused()) {
      exitTextEntry();
      return;
    }
    if (_showForgotPassword ||
        _showResetPassword ||
        _showVerification ||
        _showEmailVerification) {
      _goBackToLogin();
      return;
    }
    widget.onBack?.call();
  }

  void _goBackToLogin() {
    _pollingTimer?.cancel();
    setState(() {
      _showVerification = false;
      _showEmailVerification = false;
      _showForgotPassword = false;
      _showResetPassword = false;
      _isPolling = false;
      _message = null;
      resetSelectionInPlace();
    });
  }

  @override
  void dispose() {
    GamepadNavigationManager.popLayer('auth_form');
    _gamepadNav?.dispose();
    detachFocusSelectionListeners();
    _usernameFocus.dispose();
    _emailFocus.dispose();
    _passwordFocus.dispose();
    _verificationTokenFocus.dispose();
    _resetTokenFocus.dispose();
    _newPasswordFocus.dispose();
    _usernameController.dispose();
    _emailController.dispose();
    _passwordController.dispose();
    _verificationTokenController.dispose();
    _resetTokenController.dispose();
    _newPasswordController.dispose();
    _pollingTimer?.cancel();
    super.dispose();
  }

  Future<void> _submitForm() async {
    if (!_formKey.currentState!.validate()) return;

    setState(() {
      _isLoading = true;
      _message = null;
    });

    final authService = Provider.of<AuthService>(context, listen: false);

    try {
      Map<String, dynamic> result;

      if (_isLogin) {
        result = await authService.login(
          _emailController.text.trim(),
          _passwordController.text.trim(),
        );
      } else {
        result = await authService.register(
          _usernameController.text.trim(),
          _emailController.text.trim(),
          _passwordController.text.trim(),
        );
      }

      setState(() {
        // A login the device could not store still works until the app closes.
        // Say that instead of the backend's plain "Login successful", which the
        // next launch would contradict.
        _message = result['tokenPersisted'] == false
            ? AppLocale.credentialStorageUnavailable.getString(context)
            : result['message'];
      });

      // Handle email not verified case (can come as error from backend)
      if (_isLogin &&
          (result['emailNotVerified'] == true ||
              (result.containsKey('emailVerified') &&
                  !result['emailVerified']))) {
        _pendingVerificationEmail = _emailController.text.trim();
        _showEmailNotVerifiedForLogin();
        return;
      }

      if (result['success']) {
        if (_isLogin) {
          widget.onLoginSuccess();
        } else {
          // Registration successful - show resend button first
          _pendingVerificationEmail = _emailController.text.trim();
          _showEmailNotVerifiedForRegistration();
        }
      }
    } catch (e) {
      setState(() {
        _message = '${AppLocale.anErrorOccurred.getString(context)}: $e';
      });
    } finally {
      setState(() {
        _isLoading = false;
      });
    }
  }

  Future<void> _verifyEmail() async {
    if (_verificationTokenController.text.isEmpty) {
      setState(() {
        _message = AppLocale.enterTokenFromEmailShort.getString(context);
      });
      return;
    }

    setState(() {
      _isLoading = true;
      _message = null;
    });

    final authService = Provider.of<AuthService>(context, listen: false);

    try {
      final result = await authService.verifyEmail(
        _verificationTokenController.text.trim(),
      );

      setState(() {
        _message = result['message'];
      });

      if (result['success']) {
        // After successful verification, try to login
        final loginResult = await authService.login(
          _emailController.text.trim(),
          _passwordController.text.trim(),
        );

        if (loginResult['success']) {
          widget.onLoginSuccess();
        } else {
          setState(() {
            _message = loginResult['message'];
          });
        }
      }
    } catch (e) {
      setState(() {
        _message = '${AppLocale.anErrorOccurred.getString(context)}: $e';
      });
    } finally {
      setState(() {
        _isLoading = false;
      });
    }
  }

  Future<void> _resendVerification() async {
    if (_emailController.text.isEmpty) {
      setState(() {
        _message = AppLocale.pleaseEnterEmail.getString(context);
      });
      return;
    }

    setState(() {
      _isLoading = true;
      _message = null;
    });

    final authService = Provider.of<AuthService>(context, listen: false);

    try {
      final result = await authService.resendVerificationEmail(
        _emailController.text.trim(),
      );
      setState(() {
        _message = result['message'];
      });

      // If email was sent successfully, start polling for verification
      if (result['success'] == true) {
        _pendingVerificationEmail = _emailController.text.trim();
        _startEmailVerificationPolling();
      }
    } catch (e) {
      setState(() {
        _message = '${AppLocale.anErrorOccurred.getString(context)}: $e';
      });
    } finally {
      setState(() {
        _isLoading = false;
      });
    }
  }

  void _startEmailVerificationPolling() {
    setState(() {
      _isPolling = true;
      _message = AppLocale.checkEmailVerification.getString(context);
      _showEmailVerification = true;
      _showVerification = false;
    });

    // Start polling every 15 seconds to avoid rate limiting
    _pollingTimer = Timer.periodic(Duration(seconds: 15), (timer) async {
      await _checkEmailVerificationStatus();
    });

    // Wait 3 seconds before first check to give user time to switch to email
    Future.delayed(Duration(seconds: 3), () {
      if (_isPolling) {
        _checkEmailVerificationStatus();
      }
    });
  }

  Future<void> _checkEmailVerificationStatus() async {
    if (_pendingVerificationEmail == null) return;

    final authService = Provider.of<AuthService>(context, listen: false);

    try {
      String emailToCheck = _pendingVerificationEmail!;
      if (!emailToCheck.contains('@')) return;

      final result = await authService.checkEmailVerificationStatus(
        emailToCheck,
      );

      if (result['success'] && result['email_verified'] == true) {
        _pollingTimer?.cancel();
        setState(() {
          _isPolling = false;
          _showEmailVerification = false;
          _message = AppLocale.emailVerifiedSuccess.getString(context);
        });

        await Future.delayed(const Duration(seconds: 2));
        await _performAutoLoginAfterVerification();
      }
    } catch (e) {
      _log.e('Polling error: $e');
    }
  }

  Future<void> _performAutoLoginAfterVerification() async {
    final authService = Provider.of<AuthService>(context, listen: false);

    try {
      final loginResult = await authService.login(
        _pendingVerificationEmail!,
        _passwordController.text.trim(),
      );

      if (loginResult['success']) {
        widget.onLoginSuccess();
      } else {
        final errorMessage =
            loginResult['message']?.toString().toLowerCase() ?? '';

        if (errorMessage.contains('too many requests') ||
            errorMessage.contains('rate limit')) {
          setState(() {
            _message = AppLocale.emailVerifiedWait.getString(context);
            _showEmailVerification = false;
          });
        } else {
          setState(() {
            _message =
                '${AppLocale.emailVerifiedLoginFailed.getString(context)}: ${loginResult['message']}';
            _showEmailVerification = false;
          });
        }
      }
    } catch (e) {
      setState(() {
        _message =
            '${AppLocale.emailVerifiedLoginFailed.getString(context)}: $e';
        _showEmailVerification = false;
      });
    }
  }

  void _showEmailNotVerifiedForLogin() {
    setState(() {
      _message = AppLocale.emailNotVerified.getString(context);
      _showEmailVerification = true;
      _showVerification = false;
      resetSelectionInPlace();
    });
  }

  void _showEmailNotVerifiedForRegistration() {
    setState(() {
      _message = AppLocale.registrationSuccessCheckEmail.getString(context);
      _showEmailVerification = true;
      _showVerification = false;
      resetSelectionInPlace();
    });
    _startEmailVerificationPolling();
  }

  Future<void> _sendForgotPasswordEmail() async {
    if (_emailController.text.isEmpty) {
      setState(() {
        _message = AppLocale.pleaseEnterEmail.getString(context);
      });
      return;
    }

    setState(() {
      _isLoading = true;
      _message = null;
    });

    final authService = Provider.of<AuthService>(context, listen: false);

    try {
      final result = await authService.forgotPassword(
        _emailController.text.trim(),
      );

      setState(() {
        _message = result['message'];
        _isLoading = false;
      });

      if (result['success']) {
        setState(() {
          _showForgotPassword = false;
          _showResetPassword = true;
          resetSelectionInPlace();
        });
      }
    } catch (e) {
      setState(() {
        _message = '${AppLocale.anErrorOccurred.getString(context)}: $e';
        _isLoading = false;
      });
    }
  }

  Future<void> _resetPassword() async {
    if (_resetTokenController.text.isEmpty ||
        _newPasswordController.text.isEmpty) {
      setState(() {
        _message = AppLocale.pleaseEnterTokenAndPassword.getString(context);
      });
      return;
    }

    if (_newPasswordController.text.length < 8) {
      setState(() {
        _message = AppLocale.passwordTooShort.getString(context);
      });
      return;
    }

    setState(() {
      _isLoading = true;
      _message = null;
    });

    final authService = Provider.of<AuthService>(context, listen: false);

    try {
      final result = await authService.resetPassword(
        _resetTokenController.text.trim(),
        _newPasswordController.text.trim(),
      );

      setState(() {
        _message = result['message'];
        _isLoading = false;
      });

      if (result['success']) {
        Future.delayed(Duration(seconds: 2), () {
          setState(() {
            _showResetPassword = false;
            _showForgotPassword = false;
            _isLogin = true;
            _message = AppLocale.passwordResetSuccess.getString(context);
            _resetTokenController.clear();
            _newPasswordController.clear();
            resetSelectionInPlace();
          });
        });
      }
    } catch (e) {
      setState(() {
        _message = '${AppLocale.anErrorOccurred.getString(context)}: $e';
        _isLoading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      child: Column(
        children: [
          Center(
            child: Container(
              constraints: BoxConstraints(maxWidth: 260.r),
              child: _buildAuthForm(context),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildAuthForm(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: EdgeInsets.all(16.r),
      decoration: BoxDecoration(
        color: theme.scaffoldBackgroundColor,
        borderRadius: BorderRadius.circular(12.r),
        border: Border.all(
          color: theme.colorScheme.primary.withValues(alpha: 0.2),
          width: 1,
        ),
      ),
      child: Form(
        key: _formKey,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.center,
          mainAxisSize: MainAxisSize.min,
          children: [
            // Header
            Row(
              children: [
                Expanded(
                  child: Text(
                    _showVerification
                        ? AppLocale.verifyEmail.getString(context)
                        : _showForgotPassword
                        ? AppLocale.forgotPassword.getString(context)
                        : _showResetPassword
                        ? AppLocale.resetPassword.getString(context)
                        : (_isLogin
                              ? AppLocale.neoSyncLogin.getString(context)
                              : AppLocale.joinNeoSync.getString(context)),
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

            if (_showResetPassword) ...[
              _buildResetPasswordForm(context),
            ] else if (_showForgotPassword) ...[
              _buildForgotPasswordForm(context),
            ] else if (_showVerification || _showEmailVerification) ...[
              if (!_showEmailVerification) ...[
                _buildFieldHighlight(
                  slot: 0,
                  child: TextFormField(
                    controller: _verificationTokenController,
                    focusNode: _verificationTokenFocus,
                    style: TextStyle(fontSize: 11.r),
                    textInputAction: TextInputAction.done,
                    onFieldSubmitted: (_) => _verifyEmail(),
                    decoration: _buildInputDecoration(
                      context,
                      AppLocale.verificationToken.getString(context),
                      AppLocale.enterTokenFromEmail.getString(context),
                      Symbols.mark_email_read_rounded,
                      isHighlighted: isSelected(0),
                    ),
                    validator: (value) {
                      if (value == null || value.isEmpty) {
                        return AppLocale.enterTokenFromEmailShort.getString(
                          context,
                        );
                      }
                      return null;
                    },
                  ),
                ),
                SizedBox(height: 6.r),
              ],

              if (_message != null) ...[
                _buildMessageBox(context),
                SizedBox(height: 6.r),
              ],

              if (!_showEmailVerification)
                _buildActionButton(
                  context: context,
                  slot: 1,
                  onPressed: _isLoading ? null : _verifyEmail,
                  label: AppLocale.verifyEmail.getString(context),
                ),
              SizedBox(height: 8.r),

              // Email verification buttons
              _buildSecondaryButton(
                context: context,
                slot: _showEmailVerification ? 0 : -1,
                onPressed: _isLoading ? null : _resendVerification,
                label: AppLocale.resendVerificationEmail.getString(context),
                fontSize: 10.r,
              ),
              _buildSecondaryButton(
                context: context,
                slot: _showEmailVerification ? 1 : -1,
                onPressed: () => _goBackToLogin(),
                label: AppLocale.backToLogin.getString(context),
                fontSize: 10.r,
              ),
            ] else ...[
              // Login / Register Form
              if (!_isLogin) ...[
                SizedBox(
                  height: 32.r,
                  child: _buildFieldHighlight(
                    slot: 0,
                    child: TextFormField(
                      controller: _usernameController,
                      focusNode: _usernameFocus,
                      style: TextStyle(fontSize: 11.r),
                      textInputAction: TextInputAction.next,
                      onFieldSubmitted: (_) => _emailFocus.requestFocus(),
                      decoration: _buildInputDecoration(
                        context,
                        AppLocale.username.getString(context),
                        AppLocale.chooseUsername.getString(context),
                        Symbols.person_outline_rounded,
                        isHighlighted: isSelected(0),
                      ),
                      validator: (value) {
                        if (value == null || value.isEmpty) {
                          return AppLocale.pleaseEnterUsername.getString(
                            context,
                          );
                        }
                        return null;
                      },
                    ),
                  ),
                ),
                SizedBox(height: 6.r),
              ],
              SizedBox(
                height: 32.r,
                child: _buildFieldHighlight(
                  slot: _isLogin ? 0 : 1,
                  child: TextFormField(
                    controller: _emailController,
                    focusNode: _emailFocus,
                    style: TextStyle(fontSize: 11.r),
                    textInputAction: TextInputAction.next,
                    onFieldSubmitted: (_) => _passwordFocus.requestFocus(),
                    decoration: _buildInputDecoration(
                      context,
                      AppLocale.email.getString(context),
                      'you@example.com',
                      Symbols.email_rounded,
                      isHighlighted: isSelected(_isLogin ? 0 : 1),
                    ),
                    validator: (value) {
                      if (value == null || value.isEmpty) {
                        return AppLocale.pleaseEnterEmail.getString(context);
                      }
                      if (!value.contains('@')) {
                        return AppLocale.pleaseEnterValidEmail.getString(
                          context,
                        );
                      }
                      return null;
                    },
                  ),
                ),
              ),
              SizedBox(height: 6.r),
              SizedBox(
                height: 32.r,
                child: _buildFieldHighlight(
                  slot: _isLogin ? 1 : 2,
                  child: TextFormField(
                    controller: _passwordController,
                    focusNode: _passwordFocus,
                    style: TextStyle(fontSize: 11.r),
                    obscureText: _obscurePassword,
                    textInputAction: TextInputAction.done,
                    onFieldSubmitted: (_) => _submitForm(),
                    decoration:
                        _buildInputDecoration(
                          context,
                          AppLocale.password.getString(context),
                          AppLocale.enterPassword.getString(context),
                          Symbols.lock_outline_rounded,
                          isHighlighted: isSelected(_isLogin ? 1 : 2),
                        ).copyWith(
                          suffixIcon: IconButton(
                            icon: Icon(
                              _obscurePassword
                                  ? Symbols.visibility_rounded
                                  : Symbols.visibility_off_rounded,
                              size: 18.r,
                              color: theme.colorScheme.onSurface.withValues(
                                alpha: 0.5,
                              ),
                            ),
                            onPressed: () {
                              setState(() {
                                _obscurePassword = !_obscurePassword;
                              });
                            },
                          ),
                        ),
                    validator: (value) {
                      if (value == null || value.isEmpty) {
                        return AppLocale.pleaseEnterPassword.getString(context);
                      }
                      if (!_isLogin && value.length < 8) {
                        return AppLocale.passwordTooShort.getString(context);
                      }
                      return null;
                    },
                  ),
                ),
              ),
              SizedBox(height: 6.r),

              if (_message != null) ...[
                _buildMessageBox(context),
                SizedBox(height: 8.r),
              ],

              _buildActionButton(
                context: context,
                slot: _isLogin ? 2 : 3,
                onPressed: _isLoading ? null : _submitForm,
                label: _isLogin
                    ? AppLocale.login.getString(context)
                    : AppLocale.signUp.getString(context),
              ),
            ],

            SizedBox(height: 6.r),

            if (!_showVerification &&
                !_showForgotPassword &&
                !_showResetPassword &&
                !_showEmailVerification) ...[
              SizedBox(
                height: 24.r,
                child: _buildSecondaryButton(
                  context: context,
                  slot: _isLogin ? 3 : 4,
                  onPressed: _toggleMode,
                  label: _isLogin
                      ? AppLocale.dontHaveAccount.getString(context)
                      : AppLocale.alreadyHaveAccount.getString(context),
                  fontSize: 8.r,
                  color: theme.colorScheme.secondary.withValues(alpha: 0.9),
                ),
              ),
              SizedBox(height: 6.r),
              if (_isLogin)
                SizedBox(
                  height: 24.r,
                  child: _buildSecondaryButton(
                    context: context,
                    slot: 4,
                    onPressed: _openForgotPassword,
                    label: AppLocale.forgotPasswordQuestion.getString(context),
                    fontSize: 8.r,
                    color: theme.colorScheme.secondary.withValues(alpha: 0.9),
                  ),
                ),
            ] else if (_showForgotPassword || _showResetPassword) ...[
              SizedBox(
                height: 24.r,
                child: _buildSecondaryButton(
                  context: context,
                  slot: _showForgotPassword ? 2 : 3,
                  onPressed: _goBackToLogin,
                  label: AppLocale.backToLogin.getString(context),
                  fontSize: 8.r,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  // Wraps a field with the gamepad selection highlight border
  Widget _buildFieldHighlight({required int slot, required Widget child}) {
    // 220.r is the field width shared with the RetroAchievements, ScreenScraper
    // and RomM login forms, which constrain each field container individually.
    // Applying it here covers every field in this form from one place.
    final field = ConstrainedBox(
      constraints: BoxConstraints(maxWidth: 220.r),
      child: child,
    );
    if (!isSelected(slot)) return field;
    final theme = Theme.of(context);
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(8.r),
        boxShadow: [
          BoxShadow(
            color: theme.colorScheme.primary.withValues(alpha: 0.35),
            blurRadius: 6.r,
            spreadRadius: 1.r,
          ),
        ],
      ),
      child: field,
    );
  }

  // Submit button carrying the gamepad selection glow
  Widget _buildActionButton({
    required BuildContext context,
    required int slot,
    required VoidCallback? onPressed,
    required String label,
  }) {
    final theme = Theme.of(context);
    final selected = isSelected(slot);
    return Container(
      decoration: selected
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
          onPressed: onPressed,
          style: ElevatedButton.styleFrom(
            backgroundColor: theme.colorScheme.primary,
            foregroundColor: theme.colorScheme.onPrimary,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8.r),
            ),
            elevation: 0,
          ),
          child: _isLoading
              ? SizedBox(
                  width: 16.r,
                  height: 16.r,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    valueColor: AlwaysStoppedAnimation<Color>(
                      Colors.white.withValues(alpha: 0.8),
                    ),
                  ),
                )
              : Text(
                  label,
                  style: TextStyle(fontSize: 14.r, fontWeight: FontWeight.bold),
                ),
        ),
      ),
    );
  }

  // Secondary action button; slot = -1 means it is not gamepad-selectable
  Widget _buildSecondaryButton({
    required BuildContext context,
    required int slot,
    required VoidCallback? onPressed,
    required String label,
    required double fontSize,
    Color? color,
  }) {
    final theme = Theme.of(context);
    final selected = slot >= 0 && isSelected(slot);
    return Container(
      decoration: selected
          ? BoxDecoration(
              borderRadius: BorderRadius.circular(6.r),
              border: Border.all(
                color: theme.colorScheme.primary.withValues(alpha: 0.6),
                width: 1.r,
              ),
            )
          : null,
      child: TextButton(
        onPressed: onPressed,
        // Callers box these at 24.r. A TextButton's default 8+8 padding and
        // 36px minimum leave less than a line of room inside that at RG DS
        // scale (where .r is 1.0), which clipped the glyphs top and bottom;
        // the Thor's ~3x scale hid it. Shrink the chrome so the label fits at
        // every scale.
        style: TextButton.styleFrom(
          padding: EdgeInsets.zero,
          minimumSize: Size.zero,
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        ),
        child: Text(
          label,
          style: TextStyle(fontSize: fontSize, color: color),
        ),
      ),
    );
  }

  Widget _buildMessageBox(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      width: double.infinity,
      padding: EdgeInsets.all(10.r),
      decoration: BoxDecoration(
        color: theme.colorScheme.primary.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(8.r),
      ),
      child: Text(
        _message!,
        style: TextStyle(color: theme.colorScheme.primary, fontSize: 9.r),
        textAlign: TextAlign.center,
      ),
    );
  }

  InputDecoration _buildInputDecoration(
    BuildContext context,
    String label,
    String hint,
    IconData icon, {
    bool isHighlighted = false,
  }) {
    final theme = Theme.of(context);
    return InputDecoration(
      labelText: label,
      labelStyle: TextStyle(
        color: theme.colorScheme.onSurface.withValues(alpha: 0.7),
        fontSize: 10.r,
      ),
      floatingLabelStyle: TextStyle(
        color: theme.colorScheme.primary,
        fontWeight: FontWeight.bold,
        fontSize: 10.r,
      ),
      hintText: hint,
      hintStyle: TextStyle(
        color: theme.colorScheme.onSurface.withValues(alpha: 0.4),
        fontSize: 10.r,
      ),
      contentPadding: EdgeInsets.symmetric(horizontal: 12.r, vertical: 8.r),
      filled: true,
      fillColor: theme.colorScheme.onSurface.withValues(alpha: 0.05),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8.r),
        borderSide: BorderSide.none,
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8.r),
        borderSide: BorderSide(
          color: isHighlighted
              ? theme.colorScheme.primary
              : theme.colorScheme.primary.withValues(alpha: 0.1),
          width: isHighlighted ? 2.r : 1.r,
        ),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8.r),
        borderSide: BorderSide(color: theme.colorScheme.primary, width: 1.r),
      ),
    );
  }

  Widget _buildForgotPasswordForm(BuildContext context) {
    return Column(
      children: [
        _buildFieldHighlight(
          slot: 0,
          child: TextFormField(
            controller: _emailController,
            focusNode: _emailFocus,
            style: TextStyle(fontSize: 11.r),
            textInputAction: TextInputAction.done,
            onFieldSubmitted: (_) => _sendForgotPasswordEmail(),
            decoration: _buildInputDecoration(
              context,
              AppLocale.email.getString(context),
              AppLocale.enterRegisteredEmail.getString(context),
              Symbols.email_rounded,
              isHighlighted: isSelected(0),
            ),
            validator: (value) {
              if (value == null || value.isEmpty) {
                return AppLocale.pleaseEnterEmail.getString(context);
              }
              return null;
            },
          ),
        ),
        SizedBox(height: 16.r),
        if (_message != null) ...[
          _buildMessageBox(context),
          SizedBox(height: 12.r),
        ],
        _buildActionButton(
          context: context,
          slot: 1,
          onPressed: _isLoading ? null : _sendForgotPasswordEmail,
          label: AppLocale.sendResetToken.getString(context),
        ),
      ],
    );
  }

  Widget _buildResetPasswordForm(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      children: [
        _buildFieldHighlight(
          slot: 0,
          child: TextFormField(
            controller: _resetTokenController,
            focusNode: _resetTokenFocus,
            style: TextStyle(fontSize: 10.r),
            textInputAction: TextInputAction.next,
            onFieldSubmitted: (_) => _newPasswordFocus.requestFocus(),
            decoration: _buildInputDecoration(
              context,
              AppLocale.resetTokenLabel.getString(context),
              AppLocale.enterTokenFromEmail.getString(context),
              Symbols.vpn_key_rounded,
              isHighlighted: isSelected(0),
            ),
          ),
        ),
        SizedBox(height: 12.r),
        _buildFieldHighlight(
          slot: 1,
          child: TextFormField(
            controller: _newPasswordController,
            focusNode: _newPasswordFocus,
            style: TextStyle(fontSize: 11.r),
            obscureText: _obscurePassword,
            textInputAction: TextInputAction.done,
            onFieldSubmitted: (_) => _resetPassword(),
            decoration:
                _buildInputDecoration(
                  context,
                  AppLocale.newPassword.getString(context),
                  AppLocale.atLeast8Characters.getString(context),
                  Symbols.lock_outline_rounded,
                  isHighlighted: isSelected(1),
                ).copyWith(
                  suffixIcon: IconButton(
                    icon: Icon(
                      _obscurePassword
                          ? Symbols.visibility_rounded
                          : Symbols.visibility_off_rounded,
                      size: 18.r,
                      color: theme.colorScheme.onSurface.withValues(alpha: 0.5),
                    ),
                    onPressed: () {
                      setState(() {
                        _obscurePassword = !_obscurePassword;
                      });
                    },
                  ),
                ),
          ),
        ),
        SizedBox(height: 16.r),
        if (_message != null) ...[
          _buildMessageBox(context),
          SizedBox(height: 12.r),
        ],
        // No back link here: the shared one below the form covers both this
        // mode and the forgot-password one, and two of them rendered at once.
        _buildActionButton(
          context: context,
          slot: 2,
          onPressed: _isLoading ? null : _resetPassword,
          label: AppLocale.resetPassword.getString(context),
        ),
      ],
    );
  }
}
