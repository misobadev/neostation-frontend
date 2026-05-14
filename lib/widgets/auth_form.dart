import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:neostation/l10n/app_locale.dart';
import 'package:neostation/services/neosync/auth_service.dart';
import 'package:neostation/services/permission_service.dart';
import 'package:neostation/utils/gamepad_nav.dart';
import 'package:provider/provider.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:neostation/services/logger_service.dart';

class AuthForm extends StatefulWidget {
  final VoidCallback onLoginSuccess;

  const AuthForm({super.key, required this.onLoginSuccess});

  @override
  AuthFormState createState() => AuthFormState();
}

class AuthFormState extends State<AuthForm> {
  final _formKey = GlobalKey<FormState>();
  final _usernameController = TextEditingController();
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  final _verificationTokenController = TextEditingController();
  final _resetTokenController = TextEditingController();
  final _newPasswordController = TextEditingController();

  // TV navigation focus nodes
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

  // TV mode state
  bool _isTelevision = false;
  int _tvFieldIndex = 0;
  GamepadNavigation? _tvNav;

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
    _tvNav = GamepadNavigation(
      onNavigateUp: () => _tvMove(-1),
      onNavigateDown: () => _tvMove(1),
      onSelectItem: _tvSelect,
      onBack: _tvBack,
    );
    _tvNav!.initialize();
    _tvNav!.activate();
  }

  // Returns ordered list of FocusNodes (null = action button) for current state
  List<FocusNode?> _getCurrentTvFields() {
    if (_showResetPassword) return [_resetTokenFocus, _newPasswordFocus, null];
    if (_showForgotPassword) return [_emailFocus, null];
    if (_showVerification && !_showEmailVerification) {
      return [_verificationTokenFocus, null];
    }
    if (_showEmailVerification) return [null, null]; // resend + back
    if (_isLogin) return [_emailFocus, _passwordFocus, null];
    return [_usernameFocus, _emailFocus, _passwordFocus, null];
  }

  bool _isAnyFieldFocused() {
    return _usernameFocus.hasFocus ||
        _emailFocus.hasFocus ||
        _passwordFocus.hasFocus ||
        _verificationTokenFocus.hasFocus ||
        _resetTokenFocus.hasFocus ||
        _newPasswordFocus.hasFocus;
  }

  void _tvMove(int delta) {
    if (!_isTelevision || _isAnyFieldFocused()) return;
    final fields = _getCurrentTvFields();
    setState(() {
      _tvFieldIndex = (_tvFieldIndex + delta).clamp(0, fields.length - 1);
    });
  }

  void _tvSelect() {
    if (!_isTelevision) return;
    final fields = _getCurrentTvFields();
    if (_tvFieldIndex >= fields.length) return;
    final node = fields[_tvFieldIndex];
    if (node != null) {
      node.requestFocus();
    } else {
      _tvHandleAction();
    }
  }

  void _tvHandleAction() {
    if (_showEmailVerification) {
      if (_tvFieldIndex == 0) {
        _resendVerification();
      } else {
        _goBackToLogin();
      }
      return;
    }
    if (_showResetPassword) {
      _resetPassword();
      return;
    }
    if (_showForgotPassword) {
      _sendForgotPasswordEmail();
      return;
    }
    if (_showVerification) {
      _verifyEmail();
      return;
    }
    _submitForm();
  }

  void _tvBack() {
    if (_showForgotPassword ||
        _showResetPassword ||
        _showVerification ||
        _showEmailVerification) {
      _goBackToLogin();
    }
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
      _tvFieldIndex = 0;
    });
  }

  void _resetTvIndex() {
    if (_isTelevision) {
      _tvFieldIndex = 0;
    }
  }

  bool _isTvSelected(int slot) => _isTelevision && _tvFieldIndex == slot;

  @override
  void dispose() {
    _tvNav?.dispose();
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
        _message = result['message'];
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
      _tvFieldIndex = 0;
    });
  }

  void _showEmailNotVerifiedForRegistration() {
    setState(() {
      _message = AppLocale.registrationSuccessCheckEmail.getString(context);
      _showEmailVerification = true;
      _showVerification = false;
      _tvFieldIndex = 0;
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
          _tvFieldIndex = 0;
        });
        _resetTvIndex();
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
            _tvFieldIndex = 0;
          });
          _resetTvIndex();
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
        color: theme.cardColor.withValues(alpha: 0.25),
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
                              ? 'NeoSync'
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
            SizedBox(height: 6.r),

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
                      isTvHighlighted: _isTvSelected(0),
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
                _buildTvActionButton(
                  context: context,
                  slot: 1,
                  onPressed: _isLoading ? null : _verifyEmail,
                  label: AppLocale.verifyEmail.getString(context),
                ),
              SizedBox(height: 8.r),

              // Email verification buttons with TV highlight
              _buildTvTextButton(
                context: context,
                slot: _showEmailVerification ? 0 : -1,
                onPressed: _isLoading ? null : _resendVerification,
                label: AppLocale.resendVerificationEmail.getString(context),
                fontSize: 10.r,
              ),
              _buildTvTextButton(
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
                        isTvHighlighted: _isTvSelected(0),
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
                      isTvHighlighted: _isTvSelected(_isLogin ? 0 : 1),
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
                          isTvHighlighted: _isTvSelected(_isLogin ? 1 : 2),
                        ).copyWith(
                          suffixIcon: IconButton(
                            icon: Icon(
                              _obscurePassword
                                  ? Symbols.visibility_rounded
                                  : Symbols.visibility_off_rounded,
                              size: 16.r,
                              color: theme.colorScheme.primary.withValues(
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

              _buildTvActionButton(
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
                child: TextButton(
                  onPressed: () {
                    setState(() {
                      _isLogin = !_isLogin;
                      _message = null;
                      _tvFieldIndex = 0;
                    });
                    _resetTvIndex();
                  },
                  child: Text(
                    _isLogin
                        ? AppLocale.dontHaveAccount.getString(context)
                        : AppLocale.alreadyHaveAccount.getString(context),
                    style: TextStyle(
                      fontSize: 8.r,
                      color: theme.colorScheme.secondary.withValues(alpha: 0.9),
                    ),
                  ),
                ),
              ),
              SizedBox(height: 6.r),
              if (_isLogin)
                SizedBox(
                  height: 24.r,
                  child: TextButton(
                    onPressed: () {
                      setState(() {
                        _showForgotPassword = true;
                        _message = null;
                        _tvFieldIndex = 0;
                      });
                      _resetTvIndex();
                    },
                    child: Text(
                      AppLocale.forgotPasswordQuestion.getString(context),
                      style: TextStyle(
                        fontSize: 8.r,
                        color: theme.colorScheme.secondary.withValues(
                          alpha: 0.9,
                        ),
                      ),
                    ),
                  ),
                ),
            ] else if (_showForgotPassword || _showResetPassword) ...[
              SizedBox(
                height: 24.r,
                child: TextButton(
                  onPressed: () => _goBackToLogin(),
                  child: Text(
                    AppLocale.backToLogin.getString(context),
                    style: TextStyle(fontSize: 8.r),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  // Wraps a field with a TV selection highlight border
  Widget _buildFieldHighlight({required int slot, required Widget child}) {
    if (!_isTelevision || !_isTvSelected(slot)) return child;
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
      child: child,
    );
  }

  // TV-aware ElevatedButton for submit actions
  Widget _buildTvActionButton({
    required BuildContext context,
    required int slot,
    required VoidCallback? onPressed,
    required String label,
  }) {
    final theme = Theme.of(context);
    final isSelected = _isTvSelected(slot);
    return Container(
      decoration: isSelected
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

  // TV-aware TextButton for secondary actions (slot=-1 means no TV highlight)
  Widget _buildTvTextButton({
    required BuildContext context,
    required int slot,
    required VoidCallback? onPressed,
    required String label,
    required double fontSize,
  }) {
    final theme = Theme.of(context);
    final isSelected = slot >= 0 && _isTvSelected(slot);
    return Container(
      decoration: isSelected
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
        child: Text(label, style: TextStyle(fontSize: fontSize)),
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
    bool isTvHighlighted = false,
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
          color: isTvHighlighted
              ? theme.colorScheme.primary
              : theme.colorScheme.primary.withValues(alpha: 0.1),
          width: isTvHighlighted ? 2.r : 1.r,
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
              isTvHighlighted: _isTvSelected(0),
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
        _buildTvActionButton(
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
              isTvHighlighted: _isTvSelected(0),
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
                  isTvHighlighted: _isTvSelected(1),
                ).copyWith(
                  suffixIcon: IconButton(
                    icon: Icon(
                      _obscurePassword
                          ? Symbols.visibility_rounded
                          : Symbols.visibility_off_rounded,
                      size: 16.r,
                      color: theme.colorScheme.primary.withValues(alpha: 0.5),
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
        _buildTvActionButton(
          context: context,
          slot: 2,
          onPressed: _isLoading ? null : _resetPassword,
          label: AppLocale.resetPassword.getString(context),
        ),
        SizedBox(height: 6.r),
        TextButton(
          onPressed: () => _goBackToLogin(),
          child: Text(
            AppLocale.backToLogin.getString(context),
            style: TextStyle(fontSize: 10.r),
          ),
        ),
      ],
    );
  }
}
