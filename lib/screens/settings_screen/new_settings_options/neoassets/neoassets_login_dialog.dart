import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:neostation/l10n/app_locale.dart';
import 'package:neostation/models/neoassets_scrape_models.dart';
import 'package:neostation/services/game_service.dart'
    show GamepadNavigationManager;
import 'package:neostation/services/neoassets_scraper/neoassets_scrape_service.dart';
import 'package:neostation/utils/app_config.dart';
import 'package:neostation/utils/gamepad_nav.dart';
import 'package:neostation/utils/login_form_selection.dart';
import 'package:neostation/widgets/custom_notification.dart';
import 'package:url_launcher/url_launcher.dart';

import 'neoassets_brand.dart';

/// NeoAssets sign-in: a single personal API key, checked against the API
/// before it is stored, or a guest session with no key at all.
///
/// Slots, top to bottom: the key field, Paste, Sign in and, when
/// [allowGuest], Continue as guest. Owns its own gamepad layer while open; B
/// leaves the focused field first, then closes.
class NeoAssetsLoginDialog extends StatefulWidget {
  /// Offers a guest session; off when a guest is upgrading to a key.
  final bool allowGuest;

  const NeoAssetsLoginDialog({super.key, this.allowGuest = true});

  /// Resolves to true once a key was verified and saved, or a guest session
  /// started.
  static Future<bool> show(
    BuildContext context, {
    bool allowGuest = true,
  }) async {
    final result = await showDialog<bool>(
      context: context,
      builder: (_) => NeoAssetsLoginDialog(allowGuest: allowGuest),
    );
    return result ?? false;
  }

  @override
  State<NeoAssetsLoginDialog> createState() => _NeoAssetsLoginDialogState();
}

class _NeoAssetsLoginDialogState extends State<NeoAssetsLoginDialog>
    with LoginFormSelection<NeoAssetsLoginDialog> {
  static const String _layerId = 'neoassets_login_dialog';

  GamepadNavigation? _gamepadNav;
  final TextEditingController _keyController = TextEditingController();
  final FocusNode _keyFocus = FocusNode();
  bool _obscure = true;
  bool _isLoading = false;

  /// Whether the request in flight is the guest one, to spin its button.
  bool _guestLoading = false;

  static const int _pasteSlot = 1;
  static const int _loginSlot = 2;
  static const int _guestSlot = 3;

  @override
  List<FocusNode?> get selectionSlots => [
    _keyFocus,
    null,
    null,
    if (widget.allowGuest) null,
  ];

  @override
  void initState() {
    super.initState();
    attachFocusSelectionListeners();
    _gamepadNav = GamepadNavigation(
      onNavigateUp: () => moveSelection(-1),
      onNavigateDown: () => moveSelection(1),
      onSelectItem: _select,
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

  @override
  void dispose() {
    GamepadNavigationManager.popLayer(_layerId);
    _gamepadNav?.dispose();
    detachFocusSelectionListeners();
    _keyController.dispose();
    _keyFocus.dispose();
    super.dispose();
  }

  void _handleBack() {
    if (isAnyFieldFocused()) {
      exitTextEntry();
    } else if (!_isLoading) {
      Navigator.of(context).pop(false);
    }
  }

  void _select() {
    if (focusSelectedField()) return;
    if (isSelected(_pasteSlot)) {
      _paste();
    } else if (widget.allowGuest && isSelected(_guestSlot)) {
      _continueAsGuest();
    } else {
      _signIn();
    }
  }

  Future<void> _paste() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text?.trim() ?? '';
    if (text.isEmpty || !mounted) return;
    setState(() => _keyController.text = text);
  }

  Future<void> _signIn() async {
    final key = _keyController.text.trim();
    if (key.isEmpty) {
      AppNotification.showNotification(
        context,
        AppLocale.pleaseCompleteAllFields.getString(context),
        type: NotificationType.error,
      );
      return;
    }
    setState(() => _isLoading = true);
    try {
      await NeoAssetsScrapeService.signIn(key);
      if (!mounted) return;
      AppNotification.showNotification(
        context,
        AppLocale.loginSuccessful.getString(context),
        type: NotificationType.success,
      );
      Navigator.of(context).pop(true);
    } on NeoAssetsScrapeException catch (e) {
      if (!mounted) return;
      AppNotification.showNotification(
        context,
        neoAssetsFailureMessage(context, e.failure),
        type: NotificationType.error,
      );
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _continueAsGuest() async {
    setState(() {
      _isLoading = true;
      _guestLoading = true;
    });
    try {
      await NeoAssetsScrapeService.signInAsGuest();
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } on NeoAssetsScrapeException catch (e) {
      if (!mounted) return;
      AppNotification.showNotification(
        context,
        neoAssetsFailureMessage(context, e.failure),
        type: NotificationType.error,
      );
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
          _guestLoading = false;
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
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: 380.r),
        child: SingleChildScrollView(
          padding: EdgeInsets.all(18.r),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  const NeoAssetsBadge(size: 30),
                  SizedBox(width: 10.r),
                  Expanded(
                    child: Text(
                      AppLocale.neoAssetsLogin.getString(context),
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.bold,
                        fontSize: 14.r,
                      ),
                    ),
                  ),
                ],
              ),
              SizedBox(height: 10.r),
              _buildSteps(theme),
              SizedBox(height: 12.r),
              _buildKeyField(theme),
              SizedBox(height: 8.r),
              Row(
                children: [
                  Expanded(
                    child: _buildButton(
                      theme,
                      slot: _pasteSlot,
                      icon: Symbols.content_paste_rounded,
                      label: AppLocale.paste.getString(context),
                      onPressed: _paste,
                      primary: false,
                    ),
                  ),
                  SizedBox(width: 8.r),
                  Expanded(
                    flex: 2,
                    child: _buildButton(
                      theme,
                      slot: _loginSlot,
                      icon: Symbols.login_rounded,
                      label: AppLocale.login.getString(context),
                      onPressed: _signIn,
                      primary: true,
                    ),
                  ),
                ],
              ),
              if (widget.allowGuest) ...[
                SizedBox(height: 10.r),
                _buildGuestOption(theme),
              ],
            ],
          ),
        ),
      ),
    );
  }

  /// The way in without an account, set apart below the key form.
  Widget _buildGuestOption(ThemeData theme) {
    final onSurface = theme.colorScheme.onSurface;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Divider(height: 1.r, color: onSurface.withValues(alpha: 0.1)),
        SizedBox(height: 10.r),
        _buildButton(
          theme,
          slot: _guestSlot,
          icon: Symbols.person_outline_rounded,
          label: AppLocale.neoAssetsContinueAsGuest.getString(context),
          onPressed: _continueAsGuest,
          primary: false,
        ),
        SizedBox(height: 4.r),
        Text(
          AppLocale.neoAssetsGuestNote.getString(context),
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 8.r,
            color: onSurface.withValues(alpha: 0.55),
          ),
        ),
      ],
    );
  }

  Widget _buildSteps(ThemeData theme) {
    final muted = theme.colorScheme.onSurface.withValues(alpha: 0.7);
    Widget step(int n, String text) => Padding(
      padding: EdgeInsets.only(bottom: 4.r),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 14.r,
            height: 14.r,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: NeoAssetsBrand.accent(context).withValues(alpha: 0.18),
            ),
            child: Text(
              '$n',
              style: TextStyle(
                fontSize: 8.r,
                fontWeight: FontWeight.bold,
                color: NeoAssetsBrand.ink(context),
              ),
            ),
          ),
          SizedBox(width: 8.r),
          Expanded(
            child: Text(
              text,
              style: TextStyle(fontSize: 9.r, color: muted),
            ),
          ),
        ],
      ),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        step(1, AppLocale.neoAssetsKeyStep1.getString(context)),
        step(2, AppLocale.neoAssetsKeyStep2.getString(context)),
        step(3, AppLocale.neoAssetsKeyStep3.getString(context)),
        GestureDetector(
          onTap: () => launchUrl(
            Uri.parse(AppConfig.neoAssetsProfileUrl),
            mode: LaunchMode.externalApplication,
          ),
          child: Padding(
            padding: EdgeInsets.only(left: 22.r, top: 2.r),
            child: Text(
              'neoassets.dev/app/profile',
              style: TextStyle(
                fontSize: 9.r,
                color: NeoAssetsBrand.ink(context),
                decoration: TextDecoration.underline,
                decorationColor: NeoAssetsBrand.ink(context),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildKeyField(ThemeData theme) {
    final selected = isSelected(0);
    return Container(
      decoration: selected
          ? BoxDecoration(
              borderRadius: BorderRadius.circular(8.r),
              boxShadow: [
                BoxShadow(
                  color: NeoAssetsBrand.accent(context).withValues(alpha: 0.35),
                  blurRadius: 6.r,
                  spreadRadius: 1.r,
                ),
              ],
            )
          : null,
      child: SizedBox(
        height: 36.r,
        child: TextField(
          controller: _keyController,
          focusNode: _keyFocus,
          obscureText: _obscure,
          autocorrect: false,
          enableSuggestions: false,
          enabled: !_isLoading,
          style: TextStyle(fontSize: 11.r, fontFamily: 'monospace'),
          textInputAction: TextInputAction.done,
          onSubmitted: (_) => _signIn(),
          decoration: InputDecoration(
            labelText: AppLocale.neoAssetsApiKey.getString(context),
            hintText: 'ns_live_…',
            labelStyle: TextStyle(
              fontSize: 10.r,
              color: theme.colorScheme.onSurface.withValues(alpha: 0.7),
            ),
            hintStyle: TextStyle(
              fontSize: 10.r,
              color: theme.colorScheme.onSurface.withValues(alpha: 0.4),
            ),
            filled: true,
            fillColor: theme.colorScheme.onSurface.withValues(alpha: 0.05),
            prefixIcon: Icon(Symbols.key_rounded, size: 16.r),
            suffixIcon: IconButton(
              padding: EdgeInsets.zero,
              icon: Icon(
                _obscure
                    ? Symbols.visibility_rounded
                    : Symbols.visibility_off_rounded,
                size: 16.r,
              ),
              onPressed: () => setState(() => _obscure = !_obscure),
            ),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(8.r),
              borderSide: BorderSide.none,
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(8.r),
              borderSide: BorderSide(
                color: selected
                    ? NeoAssetsBrand.accent(context)
                    : theme.colorScheme.onSurface.withValues(alpha: 0.1),
                width: selected ? 2.r : 1.r,
              ),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(8.r),
              borderSide: BorderSide(
                color: NeoAssetsBrand.accent(context),
                width: 1.r,
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildButton(
    ThemeData theme, {
    required int slot,
    required IconData icon,
    required String label,
    required VoidCallback onPressed,
    required bool primary,
  }) {
    final selected = isSelected(slot);
    // The guest button spins for a guest request, Sign in for a key.
    final spinning =
        _isLoading &&
        (slot == _guestSlot ? _guestLoading : primary && !_guestLoading);
    return AnimatedContainer(
      duration: const Duration(milliseconds: 150),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(8.r),
        boxShadow: selected
            ? [
                BoxShadow(
                  color: NeoAssetsBrand.accent(context).withValues(alpha: 0.5),
                  blurRadius: 8.r,
                  spreadRadius: 1.r,
                ),
              ]
            : null,
      ),
      child: SizedBox(
        height: 32.r,
        child: ElevatedButton.icon(
          onPressed: _isLoading ? null : onPressed,
          icon: spinning
              ? SizedBox(
                  width: 14.r,
                  height: 14.r,
                  child: const CircularProgressIndicator(strokeWidth: 2),
                )
              : Icon(icon, size: 16.r),
          label: Text(
            label,
            style: TextStyle(fontSize: 11.r, fontWeight: FontWeight.bold),
          ),
          style: ElevatedButton.styleFrom(
            elevation: 0,
            padding: EdgeInsets.zero,
            backgroundColor: primary
                ? NeoAssetsBrand.accent(context)
                : theme.colorScheme.onSurface.withValues(
                    alpha: selected ? 0.9 : 0.08,
                  ),
            foregroundColor: primary
                ? NeoAssetsBrand.onAccent(context)
                : (selected
                      ? theme.colorScheme.surface
                      : theme.colorScheme.onSurface),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8.r),
            ),
          ),
        ),
      ),
    );
  }
}
